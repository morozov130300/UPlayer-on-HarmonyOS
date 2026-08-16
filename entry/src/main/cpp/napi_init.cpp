#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdint>
#include <cstring>
#include <deque>
#include <list>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>
#include <unistd.h>
#include "napi/native_api.h"
#include "hilog/log.h"
#include "multimedia/native_audio_channel_layout.h"
#include "multimedia/player_framework/native_avbuffer.h"
#include "multimedia/player_framework/native_avcodec_audiocodec.h"
#include "multimedia/player_framework/native_avcodec_base.h"
#include "multimedia/player_framework/native_avdemuxer.h"
#include "multimedia/player_framework/native_avformat.h"
#include "multimedia/player_framework/native_avsource.h"
#include "ohaudio/native_audiorenderer.h"
#include "ohaudio/native_audiostreambuilder.h"
#include "ohaudiosuite/native_audio_suite_base.h"
#include "ohaudiosuite/native_audio_suite_engine.h"

namespace {
constexpr unsigned int UPLAYER_LOG_DOMAIN = 0x0000;
constexpr const char* UPLAYER_LOG_TAG = "UPlayerNative";

std::mutex playerOperationMutex;
std::atomic<uint64_t> latestPlayRequest = 0;

struct PlayAsyncContext {
    napi_env env = nullptr;
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    int32_t fd = -1;
    int64_t size = 0;
    uint64_t requestId = 0;
    bool result = false;
};

struct PcmCallbackData {
    std::vector<uint8_t> pcm;
    int32_t sampleRate = 0;
    int32_t channelCount = 0;
};

struct CoverCacheEntry {
    std::vector<uint8_t> data;
    std::list<std::string>::iterator position;
};

class AlbumCoverCache {
public:
    static AlbumCoverCache& Instance()
    {
        static AlbumCoverCache instance;
        return instance;
    }

    bool Get(const std::string& key, std::vector<uint8_t>& data)
    {
        std::lock_guard<std::mutex> lock(mutex_);
        auto found = entries_.find(key);
        if (found == entries_.end()) {
            return false;
        }
        order_.erase(found->second.position);
        order_.push_front(key);
        found->second.position = order_.begin();
        data = found->second.data;
        return true;
    }

    void Put(const std::string& key, const std::vector<uint8_t>& data)
    {
        if (data.empty() || data.size() > MAX_COVER_BYTES) {
            return;
        }
        std::lock_guard<std::mutex> lock(mutex_);
        auto found = entries_.find(key);
        if (found != entries_.end()) {
            totalBytes_ -= found->second.data.size();
            order_.erase(found->second.position);
            entries_.erase(found);
        }
        order_.push_front(key);
        entries_.emplace(key, CoverCacheEntry { data, order_.begin() });
        totalBytes_ += data.size();
        while (entries_.size() > MAX_ENTRIES || totalBytes_ > MAX_CACHE_BYTES) {
            const std::string oldest = order_.back();
            order_.pop_back();
            totalBytes_ -= entries_.at(oldest).data.size();
            entries_.erase(oldest);
        }
    }

    void Clear()
    {
        std::lock_guard<std::mutex> lock(mutex_);
        entries_.clear();
        order_.clear();
        totalBytes_ = 0;
    }

    bool Extract(int32_t fd, int64_t fileSize, std::vector<uint8_t>& cover)
    {
        uint8_t header[10] = {};
        if (fd < 0 || fileSize < 10 || pread(fd, header, sizeof(header), 0) != sizeof(header) ||
            std::memcmp(header, "ID3", 3) != 0) {
            return false;
        }
        const uint8_t version = header[3];
        const uint32_t tagSize = SyncSafe(header + 6);
        if ((version != 2 && version != 3 && version != 4) || tagSize == 0 || tagSize > MAX_TAG_BYTES ||
            tagSize > static_cast<uint64_t>(fileSize - 10)) {
            return false;
        }
        std::vector<uint8_t> tag(tagSize);
        if (pread(fd, tag.data(), tag.size(), 10) != static_cast<ssize_t>(tag.size())) {
            return false;
        }
        size_t offset = 0;
        if ((header[5] & 0x40) != 0 && tag.size() >= 4) {
            const uint32_t extendedSize = version == 4 ? SyncSafe(tag.data()) :
                (static_cast<uint32_t>(tag[0]) << 24) | (static_cast<uint32_t>(tag[1]) << 16) |
                (static_cast<uint32_t>(tag[2]) << 8) | static_cast<uint32_t>(tag[3]);
            offset = version == 4 ? extendedSize : extendedSize + 4;
        }
        const size_t frameHeaderSize = version == 2 ? 6 : 10;
        while (offset + frameHeaderSize <= tag.size()) {
            const uint8_t* frame = tag.data() + offset;
            if (frame[0] == 0) {
                break;
            }
            const uint32_t frameSize = version == 2 ?
                (static_cast<uint32_t>(frame[3]) << 16) | (static_cast<uint32_t>(frame[4]) << 8) |
                    static_cast<uint32_t>(frame[5]) :
                (version == 4 ? SyncSafe(frame + 4) :
                    (static_cast<uint32_t>(frame[4]) << 24) | (static_cast<uint32_t>(frame[5]) << 16) |
                    (static_cast<uint32_t>(frame[6]) << 8) | static_cast<uint32_t>(frame[7]));
            if (frameSize == 0 || offset + frameHeaderSize + frameSize > tag.size()) {
                break;
            }
            if (version == 2 && std::memcmp(frame, "PIC", 3) == 0 && ExtractPic(frame + 6, frameSize, cover)) {
                return true;
            }
            if (version != 2 && std::memcmp(frame, "APIC", 4) == 0 &&
                ExtractApic(frame + 10, frameSize, cover)) {
                return true;
            }
            offset += frameHeaderSize + frameSize;
        }
        return false;
    }

private:
    static uint32_t SyncSafe(const uint8_t* value)
    {
        return (static_cast<uint32_t>(value[0]) << 21) | (static_cast<uint32_t>(value[1]) << 14) |
            (static_cast<uint32_t>(value[2]) << 7) | static_cast<uint32_t>(value[3]);
    }

    static bool ExtractApic(const uint8_t* payload, size_t size, std::vector<uint8_t>& cover)
    {
        if (size < 4) {
            return false;
        }
        size_t cursor = 1;
        while (cursor < size && payload[cursor] != 0) {
            cursor++;
        }
        if (cursor + 2 >= size) {
            return false;
        }
        cursor += 2;
        if (payload[0] == 1 || payload[0] == 2) {
            while (cursor + 1 < size && (payload[cursor] != 0 || payload[cursor + 1] != 0)) {
                cursor += 2;
            }
            cursor += 2;
        } else {
            while (cursor < size && payload[cursor] != 0) {
                cursor++;
            }
            cursor++;
        }
        if (cursor >= size) {
            return false;
        }
        cover.assign(payload + cursor, payload + size);
        return true;
    }

    static bool ExtractPic(const uint8_t* payload, size_t size, std::vector<uint8_t>& cover)
    {
        if (size < 6) {
            return false;
        }
        size_t cursor = 5;
        if (payload[0] == 1 || payload[0] == 2) {
            while (cursor + 1 < size && (payload[cursor] != 0 || payload[cursor + 1] != 0)) {
                cursor += 2;
            }
            cursor += 2;
        } else {
            while (cursor < size && payload[cursor] != 0) {
                cursor++;
            }
            cursor++;
        }
        if (cursor >= size) {
            return false;
        }
        cover.assign(payload + cursor, payload + size);
        return true;
    }

    static constexpr size_t MAX_ENTRIES = 32;
    static constexpr size_t MAX_COVER_BYTES = 16 * 1024 * 1024;
    static constexpr size_t MAX_CACHE_BYTES = 64 * 1024 * 1024;
    static constexpr uint32_t MAX_TAG_BYTES = 32 * 1024 * 1024;
    size_t totalBytes_ = 0;
    std::mutex mutex_;
    std::list<std::string> order_;
    std::unordered_map<std::string, CoverCacheEntry> entries_;
};

class NativeAudioPlayer {
public:
    static NativeAudioPlayer& Instance()
    {
        static NativeAudioPlayer instance;
        return instance;
    }

    bool IsEqualizerSupported()
    {
        bool supported = false;
        OH_AudioSuite_Result result = OH_AudioSuiteEngine_IsNodeTypeSupported(
            EFFECT_NODE_TYPE_EQUALIZER, &supported);
        return result == AUDIOSUITE_SUCCESS && supported;
    }

    bool Play(int32_t fd, int64_t size)
    {
        Stop();
        sourceFd_ = dup(fd);
        if (sourceFd_ < 0) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG, "dup fd failed");
            return false;
        }
        source_ = OH_AVSource_CreateWithFD(sourceFd_, 0, size);
        if (source_ == nullptr) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG, "create source failed");
            ReleaseSource();
            return false;
        }
        demuxer_ = OH_AVDemuxer_CreateWithSource(source_);
        if (demuxer_ == nullptr) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG, "create demuxer failed");
            Stop();
            return false;
        }
        if (!ConfigureTrack() || !ConfigureDecoder() || !ConfigureEffects() || !ConfigureRenderer()) {
            Stop();
            return false;
        }
        stopRequested_ = false;
        paused_ = false;
        completed_ = false;
        currentPositionMs_ = 0;
        firstPcmReady_ = false;
        decoderFailed_ = false;
        activeEqEnabled_ = requestedEqEnabled_.load();
        switchPhase_ = 0;
        decoderThread_ = std::thread(&NativeAudioPlayer::DecoderLoop, this);
        {
            std::unique_lock<std::mutex> lock(queueMutex_);
            bool ready = queueCondition_.wait_for(lock, std::chrono::milliseconds(1500), [this]() {
                return stopRequested_ || firstPcmReady_.load() || decoderFailed_.load();
            });
            if (!ready || !firstPcmReady_.load()) {
                OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                    "first PCM timeout or decoder failed");
                lock.unlock();
                Stop();
                return false;
            }
        }
        if (OH_AudioRenderer_Start(renderer_) != AUDIOSTREAM_SUCCESS) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG, "renderer start failed");
            Stop();
            return false;
        }
        return true;
    }

    bool Resume()
    {
        if (renderer_ == nullptr) {
            return false;
        }
        paused_ = false;
        return OH_AudioRenderer_Start(renderer_) == AUDIOSTREAM_SUCCESS;
    }

    bool Pause()
    {
        if (renderer_ == nullptr) {
            return false;
        }
        paused_ = true;
        return OH_AudioRenderer_Pause(renderer_) == AUDIOSTREAM_SUCCESS;
    }

    bool Seek(int64_t positionMs)
    {
        if (demuxer_ == nullptr || decoder_ == nullptr) {
            return false;
        }
        seekPositionMs_ = std::max<int64_t>(0, positionMs);
        seekRequested_ = true;
        return true;
    }

    void Stop()
    {
        stopRequested_ = true;
        {
            std::lock_guard<std::mutex> lock(queueMutex_);
            pcmQueue_.clear();
        }
        queueCondition_.notify_all();
        if (renderer_ != nullptr) {
            OH_AudioRenderer_Pause(renderer_);
            OH_AudioRenderer_Flush(renderer_);
            OH_AudioRenderer_Stop(renderer_);
        }
        if (decoderThread_.joinable()) {
            decoderThread_.join();
        }
        if (renderer_ != nullptr) {
            OH_AudioRenderer_Release(renderer_);
            renderer_ = nullptr;
        }
        if (pipeline_ != nullptr) {
            OH_AudioSuiteEngine_StopPipeline(pipeline_);
        }
        if (inputNode_ != nullptr) {
            OH_AudioSuiteEngine_DestroyNode(inputNode_);
            inputNode_ = nullptr;
        }
        if (eqNode_ != nullptr) {
            OH_AudioSuiteEngine_DestroyNode(eqNode_);
            eqNode_ = nullptr;
        }
        if (outputNode_ != nullptr) {
            OH_AudioSuiteEngine_DestroyNode(outputNode_);
            outputNode_ = nullptr;
        }
        if (pipeline_ != nullptr) {
            OH_AudioSuiteEngine_DestroyPipeline(pipeline_);
            pipeline_ = nullptr;
        }
        if (engine_ != nullptr) {
            OH_AudioSuiteEngine_Destroy(engine_);
            engine_ = nullptr;
        }
        if (decoder_ != nullptr) {
            OH_AudioCodec_Stop(decoder_);
            OH_AudioCodec_Destroy(decoder_);
            decoder_ = nullptr;
        }
        if (demuxer_ != nullptr) {
            OH_AVDemuxer_Destroy(demuxer_);
            demuxer_ = nullptr;
        }
        if (source_ != nullptr) {
            OH_AVSource_Destroy(source_);
            source_ = nullptr;
        }
        ReleaseSource();
        paused_ = false;
        completed_ = false;
        decodingEnded_ = false;
        decoderFailed_ = false;
        firstPcmReady_ = false;
        currentPositionMs_ = 0;
        durationMs_ = 0;
        measurementSquareSum_ = 0.0;
        measurementSampleCount_ = 0;
        measurementPeak_ = 0;
    }

    bool SetEnabled(bool enabled)
    {
        if (enabled && !IsEqualizerSupported()) {
            return false;
        }
        requestedEqEnabled_ = enabled;
        if (renderer_ == nullptr) {
            activeEqEnabled_ = enabled;
            switchPhase_ = 0;
        } else if (activeEqEnabled_ != enabled) {
            switchPhase_ = 1;
        }
        return true;
    }

    bool SetBands(const std::array<int32_t, EQUALIZER_BAND_NUM>& bands)
    {
        if (!requestedEqEnabled_) {
            return true;
        }
        bands_ = bands;
        if (eqNode_ == nullptr) {
            return IsEqualizerSupported();
        }
        OH_EqualizerFrequencyBandGains gains = {};
        for (size_t i = 0; i < bands.size(); i++) {
            gains.gains[i] = bands[i];
        }
        return OH_AudioSuiteEngine_SetEqualizerFrequencyBandGains(eqNode_, gains) == AUDIOSUITE_SUCCESS;
    }

    bool IsEqualizerEnabled() const
    {
        return requestedEqEnabled_;
    }

    bool SetPcmCaptureCallback(napi_env env, napi_value callback)
    {
        ClearPcmCaptureCallback();
        napi_valuetype valueType = napi_undefined;
        if (napi_typeof(env, callback, &valueType) != napi_ok || valueType != napi_function) {
            return false;
        }
        napi_value resourceName = nullptr;
        napi_create_string_utf8(env, "UPlayerRawPcmCapture", NAPI_AUTO_LENGTH, &resourceName);
        napi_threadsafe_function function = nullptr;
        napi_status status = napi_create_threadsafe_function(env, callback, nullptr, resourceName, 4, 1,
            nullptr, nullptr, nullptr, CallPcmCapture, &function);
        if (status != napi_ok) {
            return false;
        }
        std::lock_guard<std::mutex> lock(pcmCallbackMutex_);
        pcmCaptureFunction_ = function;
        return true;
    }

    void ClearPcmCaptureCallback()
    {
        std::lock_guard<std::mutex> lock(pcmCallbackMutex_);
        if (pcmCaptureFunction_ != nullptr) {
            napi_release_threadsafe_function(pcmCaptureFunction_, napi_tsfn_abort);
            pcmCaptureFunction_ = nullptr;
        }
    }

    bool SetSpeed(float speed)
    {
        playbackSpeed_ = speed;
        return renderer_ == nullptr || OH_AudioRenderer_SetSpeed(renderer_, speed) == AUDIOSTREAM_SUCCESS;
    }

    bool SetVolume(float volume)
    {
        volume_ = volume;
        return renderer_ == nullptr || OH_AudioRenderer_SetVolume(renderer_, volume) == AUDIOSTREAM_SUCCESS;
    }

    bool IsPlaying() const
    {
        return renderer_ != nullptr && !paused_ && !completed_;
    }

    bool IsCompleted() const
    {
        return completed_;
    }

    bool IsReady() const
    {
        return firstPcmReady_;
    }

    bool HasFailed() const
    {
        return decoderFailed_;
    }

    int64_t GetPosition() const
    {
        return currentPositionMs_;
    }

    int64_t GetDuration() const
    {
        return durationMs_;
    }

private:
    NativeAudioPlayer() = default;
    ~NativeAudioPlayer()
    {
        ClearPcmCaptureCallback();
        Stop();
    }

    void ReleaseSource()
    {
        if (sourceFd_ >= 0) {
            close(sourceFd_);
            sourceFd_ = -1;
        }
    }

    bool ConfigureTrack()
    {
        OH_AVFormat* sourceFormat = OH_AVSource_GetSourceFormat(source_);
        if (sourceFormat == nullptr) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG, "source format missing");
            return false;
        }
        int32_t trackCount = 0;
        OH_AVFormat_GetIntValue(sourceFormat, OH_MD_KEY_TRACK_COUNT, &trackCount);
        OH_AVFormat_GetLongValue(sourceFormat, OH_MD_KEY_DURATION, &durationUs_);
        durationMs_ = durationUs_ / 1000;
        OH_AVFormat_Destroy(sourceFormat);
        for (int32_t index = 0; index < trackCount; index++) {
            OH_AVFormat* format = OH_AVSource_GetTrackFormat(source_, static_cast<uint32_t>(index));
            if (format == nullptr) {
                continue;
            }
            int32_t trackType = -1;
            OH_AVFormat_GetIntValue(format, OH_MD_KEY_TRACK_TYPE, &trackType);
            if (trackType == MEDIA_TYPE_AUD) {
                trackIndex_ = static_cast<uint32_t>(index);
                OH_AVFormat_GetIntValue(format, OH_MD_KEY_AUD_SAMPLE_RATE, &sampleRate_);
                OH_AVFormat_GetIntValue(format, OH_MD_KEY_AUD_CHANNEL_COUNT, &channelCount_);
                const char* mime = nullptr;
                OH_AVFormat_GetStringValue(format, OH_MD_KEY_CODEC_MIME, &mime);
                if (mime != nullptr) {
                    mime_ = mime;
                }
                trackFormat_ = format;
                OH_AVErrCode result = OH_AVDemuxer_SelectTrackByID(demuxer_, trackIndex_);
                if (result != AV_ERR_OK) {
                    OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                        "select track failed code=%{public}d", result);
                }
                return result == AV_ERR_OK;
            }
            OH_AVFormat_Destroy(format);
        }
        OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG, "audio track not found");
        return false;
    }

    bool ConfigureDecoder()
    {
        if (trackFormat_ == nullptr || mime_.empty()) {
            return false;
        }
        decoder_ = OH_AudioCodec_CreateByMime(mime_.c_str(), false);
        if (decoder_ == nullptr) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                "create decoder failed mime=%{public}s", mime_.c_str());
            OH_AVFormat_Destroy(trackFormat_);
            trackFormat_ = nullptr;
            return false;
        }
        OH_AVFormat_SetIntValue(trackFormat_, OH_MD_KEY_AUDIO_SAMPLE_FORMAT, SAMPLE_S16LE);
        OH_AVErrCode configureResult = OH_AudioCodec_Configure(decoder_, trackFormat_);
        bool configured = configureResult == AV_ERR_OK;
        OH_AVFormat_Destroy(trackFormat_);
        trackFormat_ = nullptr;
        OH_AVErrCode prepareResult = configured ? OH_AudioCodec_Prepare(decoder_) : configureResult;
        OH_AVErrCode startResult = prepareResult == AV_ERR_OK ? OH_AudioCodec_Start(decoder_) : prepareResult;
        if (!configured || prepareResult != AV_ERR_OK || startResult != AV_ERR_OK) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                "decoder setup failed configure=%{public}d prepare=%{public}d start=%{public}d",
                configureResult, prepareResult, startResult);
        }
        return configured && prepareResult == AV_ERR_OK && startResult == AV_ERR_OK;
    }

    bool ConfigureEffects()
    {
        if (!IsEqualizerSupported() || OH_AudioSuiteEngine_Create(&engine_) != AUDIOSUITE_SUCCESS ||
            OH_AudioSuiteEngine_CreatePipeline(engine_, &pipeline_, AUDIOSUITE_PIPELINE_REALTIME_MODE) !=
                AUDIOSUITE_SUCCESS) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG, "effect engine setup failed");
            return false;
        }
        OH_AudioNodeBuilder* builder = nullptr;
        if (OH_AudioSuiteNodeBuilder_Create(&builder) != AUDIOSUITE_SUCCESS) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG, "effect node setup failed");
            return false;
        }
        OH_AudioFormat inputFormat = {};
        inputFormat.samplingRate = static_cast<OH_Audio_SampleRate>(sampleRate_);
        inputFormat.channelLayout = channelCount_ == 1 ? CH_LAYOUT_MONO : CH_LAYOUT_STEREO;
        inputFormat.channelCount = static_cast<uint32_t>(channelCount_);
        inputFormat.encodingType = AUDIO_ENCODING_TYPE_RAW;
        inputFormat.sampleFormat = AUDIO_SAMPLE_S16LE;
        OH_AudioSuiteNodeBuilder_SetNodeType(builder, INPUT_NODE_TYPE_DEFAULT);
        OH_AudioSuiteNodeBuilder_SetFormat(builder, inputFormat);
        OH_AudioSuiteNodeBuilder_SetRequestDataCallback(builder, InputDataCallback, this);
        bool success = OH_AudioSuiteEngine_CreateNode(pipeline_, builder, &inputNode_) == AUDIOSUITE_SUCCESS;
        OH_AudioSuiteNodeBuilder_Reset(builder);
        OH_AudioSuiteNodeBuilder_SetNodeType(builder, EFFECT_NODE_TYPE_EQUALIZER);
        success = success && OH_AudioSuiteEngine_CreateNode(pipeline_, builder, &eqNode_) == AUDIOSUITE_SUCCESS;
        OH_AudioSuiteNodeBuilder_Reset(builder);
        OH_AudioFormat outputFormat = {};
        outputFormat.samplingRate = SAMPLE_RATE_48000;
        outputFormat.channelLayout = CH_LAYOUT_STEREO;
        outputFormat.channelCount = 2;
        outputFormat.encodingType = AUDIO_ENCODING_TYPE_RAW;
        outputFormat.sampleFormat = AUDIO_SAMPLE_S16LE;
        OH_AudioSuiteNodeBuilder_SetNodeType(builder, OUTPUT_NODE_TYPE_DEFAULT);
        OH_AudioSuiteNodeBuilder_SetFormat(builder, outputFormat);
        success = success && OH_AudioSuiteEngine_CreateNode(pipeline_, builder, &outputNode_) == AUDIOSUITE_SUCCESS;
        OH_AudioSuiteNodeBuilder_Destroy(builder);
        if (!success || OH_AudioSuiteEngine_ConnectNodes(inputNode_, eqNode_) != AUDIOSUITE_SUCCESS ||
            OH_AudioSuiteEngine_ConnectNodes(eqNode_, outputNode_) != AUDIOSUITE_SUCCESS) {
            return false;
        }
        OH_EqualizerFrequencyBandGains gains = {};
        for (size_t i = 0; i < bands_.size(); i++) {
            gains.gains[i] = bands_[i];
        }
        OH_AudioSuiteEngine_SetEqualizerFrequencyBandGains(eqNode_, gains);
        return OH_AudioSuiteEngine_StartPipeline(pipeline_) == AUDIOSUITE_SUCCESS;
    }

    bool ConfigureRenderer()
    {
        OH_AudioStreamBuilder* builder = nullptr;
        if (OH_AudioStreamBuilder_Create(&builder, AUDIOSTREAM_TYPE_RENDERER) != AUDIOSTREAM_SUCCESS) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG, "renderer builder failed");
            return false;
        }
        OH_AudioStreamBuilder_SetSamplingRate(builder, 48000);
        OH_AudioStreamBuilder_SetChannelCount(builder, 2);
        OH_AudioStreamBuilder_SetSampleFormat(builder, AUDIOSTREAM_SAMPLE_S16LE);
        OH_AudioStreamBuilder_SetEncodingType(builder, AUDIOSTREAM_ENCODING_TYPE_RAW);
        OH_AudioStreamBuilder_SetRendererInfo(builder, AUDIOSTREAM_USAGE_MUSIC);
        OH_AudioStreamBuilder_SetRendererWriteDataCallback(builder, RendererDataCallback, this);
        bool success = OH_AudioStreamBuilder_GenerateRenderer(builder, &renderer_) == AUDIOSTREAM_SUCCESS;
        OH_AudioStreamBuilder_Destroy(builder);
        if (success) {
            OH_AudioRenderer_SetSpeed(renderer_, playbackSpeed_);
            OH_AudioRenderer_SetVolume(renderer_, volume_);
        }
        if (!success) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG, "generate renderer failed");
        }
        return success;
    }

    void DecoderLoop()
    {
        bool inputEnded = false;
        bool outputEnded = false;
        while (!stopRequested_ && !outputEnded) {
            if (seekRequested_) {
                OH_AudioCodec_Flush(decoder_);
                int64_t seekPosition = seekPositionMs_.load();
                OH_AVDemuxer_SeekToTime(demuxer_, seekPosition, SEEK_MODE_CLOSEST_SYNC);
                {
                    std::lock_guard<std::mutex> lock(queueMutex_);
                    pcmQueue_.clear();
                }
                currentPositionMs_ = seekPosition;
                inputEnded = false;
                completed_ = false;
                decodingEnded_ = false;
                seekRequested_ = false;
            }
            if (!inputEnded) {
                uint32_t inputIndex = 0;
                if (OH_AudioCodec_QueryInputBuffer(decoder_, &inputIndex, 20) == AV_ERR_OK) {
                    OH_AVBuffer* inputBuffer = OH_AudioCodec_GetInputBuffer(decoder_, inputIndex);
                    if (inputBuffer != nullptr && OH_AVDemuxer_ReadSampleBuffer(
                        demuxer_, trackIndex_, inputBuffer) == AV_ERR_OK) {
                        OH_AVCodecBufferAttr attr = {};
                        OH_AVBuffer_GetBufferAttr(inputBuffer, &attr);
                        inputEnded = (attr.flags & AVCODEC_BUFFER_FLAGS_EOS) != 0;
                        OH_AudioCodec_PushInputBuffer(decoder_, inputIndex);
                    }
                }
            }
            uint32_t outputIndex = 0;
            OH_AVErrCode outputResult = OH_AudioCodec_QueryOutputBuffer(decoder_, &outputIndex, 20);
            if (outputResult == AV_ERR_STREAM_CHANGED) {
                OH_AVFormat* outputFormat = OH_AudioCodec_GetOutputDescription(decoder_);
                if (outputFormat != nullptr) {
                    OH_AVFormat_GetIntValue(outputFormat, OH_MD_KEY_AUD_SAMPLE_RATE, &sampleRate_);
                    OH_AVFormat_GetIntValue(outputFormat, OH_MD_KEY_AUD_CHANNEL_COUNT, &channelCount_);
                    OH_AVFormat_Destroy(outputFormat);
                }
            } else if (outputResult == AV_ERR_OK) {
                OH_AVBuffer* outputBuffer = OH_AudioCodec_GetOutputBuffer(decoder_, outputIndex);
                if (outputBuffer != nullptr) {
                    OH_AVCodecBufferAttr attr = {};
                    OH_AVBuffer_GetBufferAttr(outputBuffer, &attr);
                    uint8_t* address = OH_AVBuffer_GetAddr(outputBuffer);
                    if (address != nullptr && attr.size > 0) {
                        uint8_t* begin = address + attr.offset;
                        PublishRawPcm(begin, attr.size);
                        std::unique_lock<std::mutex> lock(queueMutex_);
                        queueCondition_.wait(lock, [this]() {
                            return stopRequested_ || pcmQueue_.size() < maxQueueBytes_;
                        });
                        if (!stopRequested_) {
                            pcmQueue_.insert(pcmQueue_.end(), begin, begin + attr.size);
                            currentPositionMs_ = attr.pts / 1000;
                            firstPcmReady_ = true;
                            queueCondition_.notify_all();
                        }
                    }
                    outputEnded = (attr.flags & AVCODEC_BUFFER_FLAGS_EOS) != 0;
                    OH_AudioCodec_FreeOutputBuffer(decoder_, outputIndex);
                }
            }
        }
        if (!stopRequested_) {
            decodingEnded_ = true;
            decoderFailed_ = !firstPcmReady_.load();
            queueCondition_.notify_all();
        }
    }

    int32_t ReadPcm(void* audioData, int32_t audioDataSize, bool* finished)
    {
        if (audioData == nullptr || audioDataSize <= 0 || finished == nullptr) {
            return 0;
        }
        std::lock_guard<std::mutex> lock(queueMutex_);
        int32_t readSize = std::min<int32_t>(audioDataSize, static_cast<int32_t>(pcmQueue_.size()));
        uint8_t* destination = static_cast<uint8_t*>(audioData);
        for (int32_t i = 0; i < readSize; i++) {
            destination[i] = pcmQueue_.front();
            pcmQueue_.pop_front();
        }
        *finished = decodingEnded_.load() && pcmQueue_.empty();
        queueCondition_.notify_all();
        return readSize;
    }

    static int32_t InputDataCallback(OH_AudioNode*, void* userData, void* audioData,
        int32_t audioDataSize, bool* finished)
    {
        if (userData == nullptr) {
            return 0;
        }
        return static_cast<NativeAudioPlayer*>(userData)->ReadPcm(audioData, audioDataSize, finished);
    }

    static OH_AudioData_Callback_Result RendererDataCallback(
        OH_AudioRenderer*, void* userData, void* audioData, int32_t audioDataSize)
    {
        if (userData == nullptr || audioData == nullptr || audioDataSize <= 0) {
            return AUDIO_DATA_CALLBACK_RESULT_INVALID;
        }
        NativeAudioPlayer* player = static_cast<NativeAudioPlayer*>(userData);
        bool useEqualizer = player->activeEqEnabled_.load();
        if (!player->RenderAudio(audioData, audioDataSize, useEqualizer)) {
            std::memset(audioData, 0, static_cast<size_t>(audioDataSize));
            player->switchPhase_ = 0;
            OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                "render frame failed; returned silence and kept renderer alive");
            return AUDIO_DATA_CALLBACK_RESULT_VALID;
        }
        player->MeasureOutput(audioData, audioDataSize, useEqualizer);
        int32_t phase = player->switchPhase_.load();
        if (phase == 1) {
            player->ApplyGainRamp(audioData, audioDataSize, 1.0f, 0.0f);
            player->activeEqEnabled_ = player->requestedEqEnabled_.load();
            player->switchPhase_ = 2;
        } else if (phase == 2) {
            player->ApplyGainRamp(audioData, audioDataSize, 0.0f, 1.0f);
            player->switchPhase_ = 0;
        }
        return AUDIO_DATA_CALLBACK_RESULT_VALID;
    }

    bool RenderAudio(void* audioData, int32_t audioDataSize, bool useEqualizer)
    {
        if (!useEqualizer) {
            bool finished = false;
            int32_t readSize = ReadPcm(audioData, audioDataSize, &finished);
            if (readSize < audioDataSize) {
                std::memset(static_cast<uint8_t*>(audioData) + readSize, 0,
                    static_cast<size_t>(audioDataSize - readSize));
            }
            if (finished) {
                completed_ = true;
                paused_ = true;
            }
            return true;
        }
        bool finished = false;
        int32_t responseSize = 0;
        std::lock_guard<std::mutex> lock(effectMutex_);
        OH_AudioSuite_Result result = OH_AudioSuiteEngine_RenderFrame(
            pipeline_, audioData, audioDataSize, &responseSize, &finished);
        if (result != AUDIOSUITE_SUCCESS) {
            return false;
        }
        if (responseSize < audioDataSize) {
            std::memset(static_cast<uint8_t*>(audioData) + responseSize, 0,
                static_cast<size_t>(audioDataSize - responseSize));
        }
        if (finished) {
            completed_ = true;
            paused_ = true;
        }
        return true;
    }

    void MeasureOutput(void* audioData, int32_t audioDataSize, bool equalizerEnabled)
    {
        int16_t* samples = static_cast<int16_t*>(audioData);
        int32_t sampleCount = audioDataSize / static_cast<int32_t>(sizeof(int16_t));
        if (samples == nullptr || sampleCount <= 0) {
            return;
        }
        double squareSum = 0.0;
        int32_t peak = 0;
        for (int32_t i = 0; i < sampleCount; i++) {
            int32_t value = samples[i];
            peak = std::max(peak, std::abs(value));
            squareSum += static_cast<double>(value) * static_cast<double>(value);
        }
        measurementSquareSum_ += squareSum;
        measurementSampleCount_ += static_cast<uint64_t>(sampleCount);
        measurementPeak_ = std::max(measurementPeak_, peak);
        if (measurementSampleCount_ >= 48000 * 2) {
            double rms = std::sqrt(measurementSquareSum_ / static_cast<double>(measurementSampleCount_));
            OH_LOG_Print(LOG_APP, LOG_INFO, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                "output level eq=%{public}d peak=%{public}.1f rms=%{public}.1f samples=%{public}llu",
                equalizerEnabled ? 1 : 0, static_cast<double>(measurementPeak_), rms,
                static_cast<unsigned long long>(measurementSampleCount_));
            measurementSquareSum_ = 0.0;
            measurementSampleCount_ = 0;
            measurementPeak_ = 0;
        }
    }

    void ApplyGainRamp(void* audioData, int32_t audioDataSize, float startGain, float endGain)
    {
        int16_t* samples = static_cast<int16_t*>(audioData);
        int32_t sampleCount = audioDataSize / static_cast<int32_t>(sizeof(int16_t));
        if (sampleCount <= 0) {
            return;
        }
        for (int32_t i = 0; i < sampleCount; i++) {
            float progress = static_cast<float>(i) / static_cast<float>(sampleCount);
            float gain = startGain + (endGain - startGain) * progress;
            samples[i] = static_cast<int16_t>(static_cast<float>(samples[i]) * gain);
        }
    }

    void PublishRawPcm(const uint8_t* pcm, int32_t size)
    {
        napi_threadsafe_function function = nullptr;
        {
            std::lock_guard<std::mutex> lock(pcmCallbackMutex_);
            function = pcmCaptureFunction_;
            if (function != nullptr) {
                napi_acquire_threadsafe_function(function);
            }
        }
        if (function == nullptr || pcm == nullptr || size <= 0) {
            return;
        }
        PcmCallbackData* callbackData = new PcmCallbackData();
        callbackData->pcm.assign(pcm, pcm + size);
        callbackData->sampleRate = sampleRate_;
        callbackData->channelCount = channelCount_;
        napi_status status = napi_call_threadsafe_function(
            function, callbackData, napi_tsfn_nonblocking);
        if (status != napi_ok) {
            delete callbackData;
        }
        napi_release_threadsafe_function(function, napi_tsfn_release);
    }

    static void CallPcmCapture(napi_env env, napi_value callback, void*, void* data)
    {
        PcmCallbackData* callbackData = static_cast<PcmCallbackData*>(data);
        if (callbackData == nullptr) {
            return;
        }
        if (env != nullptr && callback != nullptr) {
            napi_value arrayBuffer = nullptr;
            void* destination = nullptr;
            napi_create_arraybuffer(env, callbackData->pcm.size(), &destination, &arrayBuffer);
            if (destination != nullptr && !callbackData->pcm.empty()) {
                std::memcpy(destination, callbackData->pcm.data(), callbackData->pcm.size());
            }
            napi_value sampleRate = nullptr;
            napi_value channelCount = nullptr;
            napi_create_int32(env, callbackData->sampleRate, &sampleRate);
            napi_create_int32(env, callbackData->channelCount, &channelCount);
            napi_value undefinedValue = nullptr;
            napi_get_undefined(env, &undefinedValue);
            napi_value args[3] = { arrayBuffer, sampleRate, channelCount };
            napi_call_function(env, undefinedValue, callback, 3, args, nullptr);
        }
        delete callbackData;
    }

    int32_t sourceFd_ = -1;
    OH_AVSource* source_ = nullptr;
    OH_AVDemuxer* demuxer_ = nullptr;
    OH_AVCodec* decoder_ = nullptr;
    OH_AVFormat* trackFormat_ = nullptr;
    OH_AudioRenderer* renderer_ = nullptr;
    OH_AudioSuiteEngine* engine_ = nullptr;
    OH_AudioSuitePipeline* pipeline_ = nullptr;
    OH_AudioNode* inputNode_ = nullptr;
    OH_AudioNode* eqNode_ = nullptr;
    OH_AudioNode* outputNode_ = nullptr;
    uint32_t trackIndex_ = 0;
    int32_t sampleRate_ = 48000;
    int32_t channelCount_ = 2;
    int64_t durationUs_ = 0;
    std::string mime_;
    std::thread decoderThread_;
    std::mutex queueMutex_;
    std::condition_variable queueCondition_;
    std::deque<uint8_t> pcmQueue_;
    const size_t maxQueueBytes_ = 48000 * 2 * 2 / 4;
    std::atomic<bool> stopRequested_ = true;
    std::atomic<bool> seekRequested_ = false;
    std::atomic<bool> paused_ = false;
    std::atomic<bool> completed_ = false;
    std::atomic<bool> decodingEnded_ = false;
    std::atomic<bool> decoderFailed_ = false;
    std::atomic<bool> firstPcmReady_ = false;
    std::atomic<int64_t> seekPositionMs_ = 0;
    std::atomic<int64_t> currentPositionMs_ = 0;
    std::atomic<int64_t> durationMs_ = 0;
    std::atomic<bool> requestedEqEnabled_ = false;
    std::atomic<bool> activeEqEnabled_ = false;
    std::atomic<int32_t> switchPhase_ = 0;
    float playbackSpeed_ = 1.0f;
    float volume_ = 1.0f;
    double measurementSquareSum_ = 0.0;
    uint64_t measurementSampleCount_ = 0;
    int32_t measurementPeak_ = 0;
    std::array<int32_t, EQUALIZER_BAND_NUM> bands_ = {};
    std::mutex pcmCallbackMutex_;
    std::mutex effectMutex_;
    napi_threadsafe_function pcmCaptureFunction_ = nullptr;
};

napi_value BooleanValue(napi_env env, bool value)
{
    napi_value result = nullptr;
    napi_get_boolean(env, value, &result);
    return result;
}

napi_value NumberValue(napi_env env, int64_t value)
{
    napi_value result = nullptr;
    napi_create_int64(env, value, &result);
    return result;
}

void ExecutePlay(napi_env, void* data)
{
    PlayAsyncContext* context = static_cast<PlayAsyncContext*>(data);
    if (context == nullptr) {
        return;
    }
    std::lock_guard<std::mutex> lock(playerOperationMutex);
    if (context->requestId != latestPlayRequest.load()) {
        return;
    }
    context->result = NativeAudioPlayer::Instance().Play(context->fd, context->size);
    if (context->result && context->requestId != latestPlayRequest.load()) {
        NativeAudioPlayer::Instance().Stop();
        context->result = false;
    }
}

void CompletePlay(napi_env env, napi_status status, void* data)
{
    PlayAsyncContext* context = static_cast<PlayAsyncContext*>(data);
    if (context == nullptr) {
        return;
    }
    napi_value result = BooleanValue(env, status == napi_ok && context->result);
    napi_resolve_deferred(env, context->deferred, result);
    napi_delete_async_work(env, context->work);
    delete context;
}

napi_value Play(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = { nullptr, nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t fd = -1;
    int64_t size = 0;
    if (argc != 2 || napi_get_value_int32(env, args[0], &fd) != napi_ok ||
        napi_get_value_int64(env, args[1], &size) != napi_ok) {
        napi_value promise = nullptr;
        napi_deferred deferred = nullptr;
        napi_create_promise(env, &deferred, &promise);
        napi_value result = BooleanValue(env, false);
        napi_resolve_deferred(env, deferred, result);
        return promise;
    }
    PlayAsyncContext* context = new PlayAsyncContext();
    context->env = env;
    context->fd = fd;
    context->size = size;
    context->requestId = latestPlayRequest.fetch_add(1) + 1;
    napi_value promise = nullptr;
    napi_create_promise(env, &context->deferred, &promise);
    napi_value resourceName = nullptr;
    napi_create_string_utf8(env, "UPlayerPlay", NAPI_AUTO_LENGTH, &resourceName);
    napi_status status = napi_create_async_work(
        env, nullptr, resourceName, ExecutePlay, CompletePlay, context, &context->work);
    if (status != napi_ok || napi_queue_async_work(env, context->work) != napi_ok) {
        napi_value result = BooleanValue(env, false);
        napi_resolve_deferred(env, context->deferred, result);
        if (context->work != nullptr) {
            napi_delete_async_work(env, context->work);
        }
        delete context;
    }
    return promise;
}

napi_value Resume(napi_env env, napi_callback_info)
{
    return BooleanValue(env, NativeAudioPlayer::Instance().Resume());
}

napi_value Pause(napi_env env, napi_callback_info)
{
    return BooleanValue(env, NativeAudioPlayer::Instance().Pause());
}

napi_value Stop(napi_env env, napi_callback_info)
{
    latestPlayRequest.fetch_add(1);
    std::lock_guard<std::mutex> lock(playerOperationMutex);
    NativeAudioPlayer::Instance().Stop();
    return BooleanValue(env, true);
}

napi_value Seek(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int64_t position = 0;
    if (argc != 1 || napi_get_value_int64(env, args[0], &position) != napi_ok) {
        return BooleanValue(env, false);
    }
    return BooleanValue(env, NativeAudioPlayer::Instance().Seek(position));
}

napi_value SetEnabled(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    bool enabled = false;
    if (argc != 1 || napi_get_value_bool(env, args[0], &enabled) != napi_ok) {
        return BooleanValue(env, false);
    }
    return BooleanValue(env, NativeAudioPlayer::Instance().SetEnabled(enabled));
}

napi_value IsEnabled(napi_env env, napi_callback_info)
{
    return BooleanValue(env, NativeAudioPlayer::Instance().IsEqualizerEnabled());
}

napi_value SetPcmCaptureCallback(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc != 1) {
        return BooleanValue(env, false);
    }
    return BooleanValue(env, NativeAudioPlayer::Instance().SetPcmCaptureCallback(env, args[0]));
}

napi_value ClearPcmCaptureCallback(napi_env env, napi_callback_info)
{
    NativeAudioPlayer::Instance().ClearPcmCaptureCallback();
    return BooleanValue(env, true);
}

napi_value SetBands(napi_env env, napi_callback_info info)
{
    if (!NativeAudioPlayer::Instance().IsEqualizerEnabled()) {
        return BooleanValue(env, true);
    }
    size_t argc = 1;
    napi_value args[1] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    bool isArray = false;
    if (argc != 1 || napi_is_array(env, args[0], &isArray) != napi_ok || !isArray) {
        return BooleanValue(env, false);
    }
    uint32_t length = 0;
    napi_get_array_length(env, args[0], &length);
    if (length != EQUALIZER_BAND_NUM) {
        return BooleanValue(env, false);
    }
    std::array<int32_t, EQUALIZER_BAND_NUM> bands = {};
    for (uint32_t i = 0; i < length; i++) {
        napi_value item = nullptr;
        double value = 0;
        if (napi_get_element(env, args[0], i, &item) != napi_ok ||
            napi_get_value_double(env, item, &value) != napi_ok) {
            return BooleanValue(env, false);
        }
        bands[i] = static_cast<int32_t>(std::clamp(value, -12.0, 12.0));
    }
    return BooleanValue(env, NativeAudioPlayer::Instance().SetBands(bands));
}

napi_value SetSpeed(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    double speed = 1;
    if (argc != 1 || napi_get_value_double(env, args[0], &speed) != napi_ok) {
        return BooleanValue(env, false);
    }
    return BooleanValue(env, NativeAudioPlayer::Instance().SetSpeed(static_cast<float>(speed)));
}

napi_value SetVolume(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    double volume = 1;
    if (argc != 1 || napi_get_value_double(env, args[0], &volume) != napi_ok) {
        return BooleanValue(env, false);
    }
    return BooleanValue(env, NativeAudioPlayer::Instance().SetVolume(static_cast<float>(volume)));
}

napi_value IsSupported(napi_env env, napi_callback_info)
{
    return BooleanValue(env, NativeAudioPlayer::Instance().IsEqualizerSupported());
}

napi_value IsPlaying(napi_env env, napi_callback_info)
{
    return BooleanValue(env, NativeAudioPlayer::Instance().IsPlaying());
}

napi_value IsCompleted(napi_env env, napi_callback_info)
{
    return BooleanValue(env, NativeAudioPlayer::Instance().IsCompleted());
}

napi_value IsReady(napi_env env, napi_callback_info)
{
    return BooleanValue(env, NativeAudioPlayer::Instance().IsReady());
}

napi_value HasFailed(napi_env env, napi_callback_info)
{
    return BooleanValue(env, NativeAudioPlayer::Instance().HasFailed());
}

napi_value GetPosition(napi_env env, napi_callback_info)
{
    return NumberValue(env, NativeAudioPlayer::Instance().GetPosition());
}

napi_value GetDuration(napi_env env, napi_callback_info)
{
    return NumberValue(env, NativeAudioPlayer::Instance().GetDuration());
}

napi_value GetAlbumCover(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value args[3] = { nullptr, nullptr, nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t fd = -1;
    int64_t size = 0;
    size_t keyLength = 0;
    if (argc != 3 || napi_get_value_int32(env, args[0], &fd) != napi_ok ||
        napi_get_value_int64(env, args[1], &size) != napi_ok ||
        napi_get_value_string_utf8(env, args[2], nullptr, 0, &keyLength) != napi_ok) {
        napi_value undefinedValue = nullptr;
        napi_get_undefined(env, &undefinedValue);
        return undefinedValue;
    }
    std::string key(keyLength + 1, '\0');
    napi_get_value_string_utf8(env, args[2], key.data(), key.size(), &keyLength);
    key.resize(keyLength);
    std::vector<uint8_t> cover;
    AlbumCoverCache& cache = AlbumCoverCache::Instance();
    if (!cache.Get(key, cover)) {
        if (!cache.Extract(fd, size, cover)) {
            napi_value undefinedValue = nullptr;
            napi_get_undefined(env, &undefinedValue);
            return undefinedValue;
        }
        cache.Put(key, cover);
    }
    napi_value result = nullptr;
    void* destination = nullptr;
    napi_create_arraybuffer(env, cover.size(), &destination, &result);
    if (destination != nullptr) {
        std::memcpy(destination, cover.data(), cover.size());
    }
    return result;
}

napi_value ClearAlbumCoverCache(napi_env env, napi_callback_info)
{
    AlbumCoverCache::Instance().Clear();
    return BooleanValue(env, true);
}

napi_value CacheAlbumCover(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = { nullptr, nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    size_t keyLength = 0;
    void* data = nullptr;
    size_t dataLength = 0;
    if (argc != 2 || napi_get_value_string_utf8(env, args[0], nullptr, 0, &keyLength) != napi_ok ||
        napi_get_arraybuffer_info(env, args[1], &data, &dataLength) != napi_ok || data == nullptr || dataLength == 0) {
        return BooleanValue(env, false);
    }
    std::string key(keyLength + 1, '\0');
    napi_get_value_string_utf8(env, args[0], key.data(), key.size(), &keyLength);
    key.resize(keyLength);
    const uint8_t* begin = static_cast<const uint8_t*>(data);
    std::vector<uint8_t> cover(begin, begin + dataLength);
    AlbumCoverCache::Instance().Put(key, cover);
    return BooleanValue(env, true);
}

napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor descriptors[] = {
        { "play", nullptr, Play, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "resume", nullptr, Resume, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "pause", nullptr, Pause, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "stop", nullptr, Stop, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "seek", nullptr, Seek, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "setEqualizerEnable", nullptr, SetEnabled, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "setEqualizerEnabled", nullptr, SetEnabled, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "isEqualizerEnabled", nullptr, IsEnabled, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "setEqualizerBands", nullptr, SetBands, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "setPcmCaptureCallback", nullptr, SetPcmCaptureCallback, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "clearPcmCaptureCallback", nullptr, ClearPcmCaptureCallback, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "setSpeed", nullptr, SetSpeed, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "setVolume", nullptr, SetVolume, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "isEqualizerSupported", nullptr, IsSupported, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "isPlaying", nullptr, IsPlaying, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "isCompleted", nullptr, IsCompleted, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "isReady", nullptr, IsReady, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "hasFailed", nullptr, HasFailed, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "getPosition", nullptr, GetPosition, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "getDuration", nullptr, GetDuration, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "getAlbumCover", nullptr, GetAlbumCover, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "cacheAlbumCover", nullptr, CacheAlbumCover, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "clearAlbumCoverCache", nullptr, ClearAlbumCoverCache, nullptr, nullptr, nullptr, napi_default, nullptr }
    };
    napi_define_properties(env, exports, sizeof(descriptors) / sizeof(descriptors[0]), descriptors);
    return exports;
}
}

static napi_module module = {
    1,
    0,
    nullptr,
    Init,
    "uplayer",
    nullptr,
    { 0 }
};

extern "C" __attribute__((constructor)) void RegisterUPlayerModule()
{
    napi_module_register(&module);
}

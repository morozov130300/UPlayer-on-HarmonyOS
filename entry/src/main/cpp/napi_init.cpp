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
constexpr double EQUALIZER_MIN_GAIN_DB = -10.0;
constexpr double EQUALIZER_MAX_GAIN_DB = 10.0;

std::mutex playerOperationMutex;
std::atomic<uint64_t> latestPlayRequest = 0;

struct PlayAsyncContext {
    napi_env env = nullptr;
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    int32_t fd = -1;
    int64_t size = 0;
    int64_t startPositionMs = 0;
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

    bool Play(int32_t fd, int64_t size, int64_t startPositionMs, uint64_t requestId)
    {
        Stop();
        if (requestId != latestPlayRequest.load()) {
            return false;
        }
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
        if (requestId != latestPlayRequest.load()) {
            Stop();
            return false;
        }
        demuxer_ = OH_AVDemuxer_CreateWithSource(source_);
        if (demuxer_ == nullptr) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG, "create demuxer failed");
            Stop();
            return false;
        }
        stopRequested_ = false;
        acceptingCodecCallbacks_ = true;
        codecGeneration_.fetch_add(1);
        startupStage_ = StartupStage::IDLE;
        if (!ConfigureTrack() || !ConfigureDecoder() || !ConfigureEffects() || !ConfigureRenderer()) {
            Stop();
            return false;
        }
        if (requestId != latestPlayRequest.load()) {
            Stop();
            return false;
        }
        paused_ = false;
        completed_ = false;
        currentPositionMs_ = 0;
        firstPcmReady_ = false;
        decoderFailed_ = false;
        if (startPositionMs > 0) {
            int64_t targetPositionMs = std::min(startPositionMs, durationMs_.load());
            OH_AVErrCode seekResult = OH_AVDemuxer_SeekToTime(demuxer_, targetPositionMs, SEEK_MODE_CLOSEST_SYNC);
            if (seekResult != AV_ERR_OK) {
                OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                    "initial seek failed code=%{public}d position=%{public}lld", seekResult,
                    static_cast<long long>(targetPositionMs));
                Stop();
                return false;
            }
            currentPositionMs_ = targetPositionMs;
        }
        activeEqEnabled_ = requestedEqEnabled_.load();
        decoderThread_ = std::thread(&NativeAudioPlayer::DecoderLoop, this);
        {
            std::unique_lock<std::mutex> lock(queueMutex_);
            bool ready = queueCondition_.wait_for(lock, std::chrono::milliseconds(3000), [this]() {
                return stopRequested_ || firstPcmReady_.load() || decoderFailed_.load();
            });
            if (!ready || !firstPcmReady_.load()) {
                StartupStage stage = startupStage_.load();
                OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                    "native startup failed stage=%{public}d timeout=%{public}d sampleRate=%{public}d channels=%{public}d",
                    static_cast<int32_t>(stage), ready ? 0 : 1, sampleRate_, channelCount_);
                lock.unlock();
                Stop();
                return false;
            }
        }
        if (rendererState_ != RendererState::CREATED ||
            OH_AudioRenderer_Start(renderer_) != AUDIOSTREAM_SUCCESS) {
            startupStage_ = StartupStage::FAILED;
            OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG, "renderer start failed");
            Stop();
            return false;
        }
        rendererState_ = RendererState::STARTED;
        startupStage_ = StartupStage::RENDERER_STARTED;
        return true;
    }

    bool Resume()
    {
        if (renderer_ == nullptr ||
            (rendererState_ != RendererState::PAUSED && rendererState_ != RendererState::STOPPED)) {
            return false;
        }
        if (OH_AudioRenderer_Start(renderer_) != AUDIOSTREAM_SUCCESS) {
            return false;
        }
        rendererState_ = RendererState::STARTED;
        paused_ = false;
        return true;
    }

    bool Pause()
    {
        if (renderer_ == nullptr || rendererState_ != RendererState::STARTED) {
            return rendererState_ == RendererState::PAUSED;
        }
        if (OH_AudioRenderer_Pause(renderer_) != AUDIOSTREAM_SUCCESS) {
            return false;
        }
        rendererState_ = RendererState::PAUSED;
        paused_ = true;
        return true;
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

    void RequestStop()
    {
        acceptingCodecCallbacks_ = false;
        stopRequested_ = true;
        codecGeneration_.fetch_add(1);
        queueCondition_.notify_all();
        codecQueueCondition_.notify_all();
    }

    void Stop()
    {
        RequestStop();
        {
            std::lock_guard<std::mutex> lock(codecQueueMutex_);
            inputBuffers_.clear();
            outputBuffers_.clear();
        }
        codecQueueCondition_.notify_all();
        if (decoderThread_.joinable()) {
            decoderThread_.join();
        }
        if (renderer_ != nullptr) {
            if (rendererState_ == RendererState::STARTED) {
                OH_AudioRenderer_Pause(renderer_);
                rendererState_ = RendererState::PAUSED;
            }
            if (rendererState_ == RendererState::PAUSED) {
                OH_AudioRenderer_Flush(renderer_);
            }
            if (rendererState_ == RendererState::STARTED || rendererState_ == RendererState::PAUSED) {
                OH_AudioRenderer_Stop(renderer_);
                rendererState_ = RendererState::STOPPED;
            }
            OH_AudioRenderer_Release(renderer_);
            renderer_ = nullptr;
            rendererState_ = RendererState::EMPTY;
        }
        {
            std::lock_guard<std::mutex> lock(queueMutex_);
            pcmQueue_.clear();
        }
        queueCondition_.notify_all();
        if (pipeline_ != nullptr && pipelineStarted_) {
            OH_AudioSuiteEngine_StopPipeline(pipeline_);
            pipelineStarted_ = false;
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
            if (codecState_ == CodecState::STARTED) {
                OH_AudioCodec_Stop(decoder_);
                codecState_ = CodecState::STOPPED;
            }
            OH_AudioCodec_Destroy(decoder_);
            decoder_ = nullptr;
            codecState_ = CodecState::EMPTY;
        }
        if (trackFormat_ != nullptr) {
            OH_AVFormat_Destroy(trackFormat_);
            trackFormat_ = nullptr;
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
        seekRequested_ = false;
        currentPositionMs_ = 0;
        durationMs_ = 0;
        startupStage_ = StartupStage::IDLE;
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
        }
        return true;
    }

    bool SetBands(const std::array<int32_t, EQUALIZER_BAND_NUM>& bands)
    {
        std::lock_guard<std::mutex> lock(effectMutex_);
        bands_ = bands;
        if (!requestedEqEnabled_ || eqNode_ == nullptr) {
            return true;
        }
        return ApplyBandsLocked(bands_, true);
    }

    std::array<int32_t, EQUALIZER_BAND_NUM> GetBands()
    {
        std::lock_guard<std::mutex> lock(effectMutex_);
        if (eqNode_ == nullptr) {
            return bands_;
        }
        OH_EqualizerFrequencyBandGains current = {};
        OH_AudioSuite_Result result = OH_AudioSuiteEngine_GetEqualizerFrequencyBandGains(eqNode_, &current);
        if (result != AUDIOSUITE_SUCCESS) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                "get equalizer bands failed code=%{public}d", result);
            return bands_;
        }
        std::array<int32_t, EQUALIZER_BAND_NUM> resultBands = {};
        for (size_t i = 0; i < resultBands.size(); i++) {
            resultBands[i] = current.gains[i];
        }
        return resultBands;
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
    enum class CodecState : uint8_t {
        EMPTY,
        CREATED,
        CONFIGURED,
        PREPARED,
        STARTED,
        STOPPED
    };

    enum class RendererState : uint8_t {
        EMPTY,
        CREATED,
        STARTED,
        PAUSED,
        STOPPED
    };

    enum class StartupStage : uint8_t {
        IDLE,
        DECODER_STARTED,
        INPUT_CALLBACK,
        OUTPUT_CALLBACK,
        FIRST_PCM,
        RENDERER_STARTED,
        FAILED
    };

    struct CodecBufferItem {
        uint32_t index = 0;
        OH_AVBuffer* buffer = nullptr;
        uint64_t generation = 0;
    };

    bool ApplyBandsLocked(const std::array<int32_t, EQUALIZER_BAND_NUM>& bands, bool verify)
    {
        if (eqNode_ == nullptr) {
            return false;
        }
        OH_AudioSuite_Result bypassResult = OH_AudioSuiteEngine_BypassEffectNode(eqNode_, false);
        if (bypassResult != AUDIOSUITE_SUCCESS) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                "enable equalizer processing failed code=%{public}d", bypassResult);
            return false;
        }
        bool bypassed = true;
        OH_AudioSuite_Result bypassStateResult = OH_AudioSuiteEngine_GetNodeBypassStatus(eqNode_, &bypassed);
        if (bypassStateResult != AUDIOSUITE_SUCCESS || bypassed) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                "equalizer bypass verify failed code=%{public}d bypassed=%{public}d",
                bypassStateResult, bypassed ? 1 : 0);
            return false;
        }
        OH_EqualizerFrequencyBandGains gains = {};
        for (size_t i = 0; i < bands.size(); i++) {
            gains.gains[i] = bands[i];
        }
        OH_AudioSuite_Result setResult = OH_AudioSuiteEngine_SetEqualizerFrequencyBandGains(eqNode_, gains);
        if (setResult != AUDIOSUITE_SUCCESS) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                "set equalizer bands failed code=%{public}d", setResult);
            return false;
        }
        if (!verify) {
            return true;
        }
        OH_EqualizerFrequencyBandGains current = {};
        OH_AudioSuite_Result getResult = OH_AudioSuiteEngine_GetEqualizerFrequencyBandGains(eqNode_, &current);
        if (getResult != AUDIOSUITE_SUCCESS) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                "verify equalizer bands failed code=%{public}d", getResult);
            return false;
        }
        bool matched = true;
        for (size_t i = 0; i < bands.size(); i++) {
            matched = matched && current.gains[i] == bands[i];
        }
        OH_LOG_Print(LOG_APP, matched ? LOG_INFO : LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
            "equalizer bands applied matched=%{public}d bypassed=%{public}d requested=%{public}d,%{public}d,"
            "%{public}d,%{public}d,%{public}d,%{public}d,%{public}d,%{public}d,%{public}d,%{public}d "
            "actual=%{public}d,%{public}d,%{public}d,%{public}d,%{public}d,%{public}d,%{public}d,%{public}d,"
            "%{public}d,%{public}d",
            matched ? 1 : 0, bypassed ? 1 : 0, bands[0], bands[1], bands[2], bands[3], bands[4], bands[5],
            bands[6], bands[7], bands[8], bands[9], current.gains[0], current.gains[1], current.gains[2],
            current.gains[3], current.gains[4], current.gains[5], current.gains[6], current.gains[7],
            current.gains[8], current.gains[9]);
        return matched;
    }

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
        codecState_ = CodecState::CREATED;
        OH_AVCodecCallback callback = {
            CodecErrorCallback,
            CodecStreamChangedCallback,
            CodecInputBufferCallback,
            CodecOutputBufferCallback
        };
        OH_AVErrCode callbackResult = OH_AudioCodec_RegisterCallback(decoder_, callback, this);
        OH_AVFormat_SetIntValue(trackFormat_, OH_MD_KEY_AUDIO_SAMPLE_FORMAT, SAMPLE_S16LE);
        OH_AVErrCode configureResult = callbackResult == AV_ERR_OK ?
            OH_AudioCodec_Configure(decoder_, trackFormat_) : callbackResult;
        bool configured = configureResult == AV_ERR_OK;
        if (configured) {
            codecState_ = CodecState::CONFIGURED;
        }
        OH_AVFormat_Destroy(trackFormat_);
        trackFormat_ = nullptr;
        OH_AVErrCode prepareResult = configured ? OH_AudioCodec_Prepare(decoder_) : configureResult;
        if (prepareResult == AV_ERR_OK) {
            codecState_ = CodecState::PREPARED;
        }
        OH_AVErrCode startResult = prepareResult == AV_ERR_OK ? OH_AudioCodec_Start(decoder_) : prepareResult;
        if (startResult == AV_ERR_OK) {
            codecState_ = CodecState::STARTED;
            startupStage_ = StartupStage::DECODER_STARTED;
        }
        if (callbackResult != AV_ERR_OK || !configured || prepareResult != AV_ERR_OK || startResult != AV_ERR_OK) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                "decoder setup failed callback=%{public}d configure=%{public}d prepare=%{public}d start=%{public}d",
                callbackResult, configureResult, prepareResult, startResult);
        }
        return callbackResult == AV_ERR_OK && configured && prepareResult == AV_ERR_OK && startResult == AV_ERR_OK;
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
        outputFormat.samplingRate = static_cast<OH_Audio_SampleRate>(sampleRate_);
        outputFormat.channelLayout = channelCount_ == 1 ? CH_LAYOUT_MONO : CH_LAYOUT_STEREO;
        outputFormat.channelCount = static_cast<uint32_t>(channelCount_);
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
        {
            std::lock_guard<std::mutex> lock(effectMutex_);
            if (!ApplyBandsLocked(bands_, true)) {
                return false;
            }
        }
        OH_AudioSuite_Result startResult = OH_AudioSuiteEngine_StartPipeline(pipeline_);
        pipelineStarted_ = startResult == AUDIOSUITE_SUCCESS;
        return pipelineStarted_;
    }

    bool ConfigureRenderer()
    {
        OH_AudioStreamBuilder* builder = nullptr;
        if (OH_AudioStreamBuilder_Create(&builder, AUDIOSTREAM_TYPE_RENDERER) != AUDIOSTREAM_SUCCESS) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG, "renderer builder failed");
            return false;
        }
        OH_AudioStreamBuilder_SetSamplingRate(builder, sampleRate_);
        OH_AudioStreamBuilder_SetChannelCount(builder, channelCount_);
        OH_AudioStreamBuilder_SetSampleFormat(builder, AUDIOSTREAM_SAMPLE_S16LE);
        OH_AudioStreamBuilder_SetEncodingType(builder, AUDIOSTREAM_ENCODING_TYPE_RAW);
        OH_AudioStreamBuilder_SetRendererInfo(builder, AUDIOSTREAM_USAGE_MUSIC);
        OH_AudioStreamBuilder_SetRendererWriteDataCallback(builder, RendererDataCallback, this);
        bool success = OH_AudioStreamBuilder_GenerateRenderer(builder, &renderer_) == AUDIOSTREAM_SUCCESS;
        OH_AudioStreamBuilder_Destroy(builder);
        if (success) {
            rendererState_ = RendererState::CREATED;
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
                uint64_t nextGeneration = codecGeneration_.fetch_add(1) + 1;
                {
                    std::lock_guard<std::mutex> lock(codecQueueMutex_);
                    inputBuffers_.clear();
                    outputBuffers_.clear();
                }
                OH_AVErrCode flushResult = codecState_ == CodecState::STARTED ?
                    OH_AudioCodec_Flush(decoder_) : static_cast<OH_AVErrCode>(-1);
                int64_t seekPosition = seekPositionMs_.load();
                OH_AVErrCode seekResult = flushResult == AV_ERR_OK ?
                    OH_AVDemuxer_SeekToTime(demuxer_, seekPosition, SEEK_MODE_CLOSEST_SYNC) : flushResult;
                if (flushResult != AV_ERR_OK || seekResult != AV_ERR_OK) {
                    FailDecoder("seek reset", flushResult, seekResult);
                    break;
                }
                OH_AVErrCode restartResult = OH_AudioCodec_Start(decoder_);
                if (restartResult != AV_ERR_OK) {
                    FailDecoder("seek restart", restartResult, AV_ERR_OK);
                    break;
                }
                codecState_ = CodecState::STARTED;
                {
                    std::lock_guard<std::mutex> lock(queueMutex_);
                    pcmQueue_.clear();
                }
                firstPcmReady_ = false;
                decoderFailed_ = false;
                currentPositionMs_ = seekPosition;
                inputEnded = false;
                outputEnded = false;
                completed_ = false;
                decodingEnded_ = false;
                seekRequested_ = false;
                OH_LOG_Print(LOG_APP, LOG_INFO, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                    "seek reset generation=%{public}llu position=%{public}lld",
                    static_cast<unsigned long long>(nextGeneration), static_cast<long long>(seekPosition));
                codecQueueCondition_.notify_all();
            }

            CodecBufferItem inputItem;
            CodecBufferItem outputItem;
            bool hasInput = false;
            bool hasOutput = false;
            {
                std::unique_lock<std::mutex> lock(codecQueueMutex_);
                codecQueueCondition_.wait_for(lock, std::chrono::milliseconds(20), [this, inputEnded]() {
                    return stopRequested_ || seekRequested_ || decoderFailed_ || !outputBuffers_.empty() ||
                        (!inputEnded && !inputBuffers_.empty());
                });
                if (!inputEnded && !inputBuffers_.empty()) {
                    inputItem = inputBuffers_.front();
                    inputBuffers_.pop_front();
                    hasInput = true;
                }
                if (!outputBuffers_.empty()) {
                    outputItem = outputBuffers_.front();
                    outputBuffers_.pop_front();
                    hasOutput = true;
                }
            }
            if (stopRequested_ || decoderFailed_) {
                break;
            }
            const uint64_t currentGeneration = codecGeneration_.load();
            if (hasInput && inputItem.generation != currentGeneration) {
                hasInput = false;
            }
            if (hasOutput && outputItem.generation != currentGeneration) {
                hasOutput = false;
            }
            if (hasInput && !seekRequested_) {
                OH_AVErrCode readResult = OH_AVDemuxer_ReadSampleBuffer(demuxer_, trackIndex_, inputItem.buffer);
                OH_AVCodecBufferAttr attr = {};
                OH_AVErrCode attrResult = readResult == AV_ERR_OK ?
                    OH_AVBuffer_GetBufferAttr(inputItem.buffer, &attr) : readResult;
                OH_AVErrCode pushResult = attrResult == AV_ERR_OK ?
                    OH_AudioCodec_PushInputBuffer(decoder_, inputItem.index) : attrResult;
                if (readResult != AV_ERR_OK || attrResult != AV_ERR_OK || pushResult != AV_ERR_OK) {
                    FailDecoder("decoder input", readResult, pushResult);
                    break;
                }
                inputEnded = (attr.flags & AVCODEC_BUFFER_FLAGS_EOS) != 0;
            }
            if (hasOutput && !seekRequested_) {
                OH_AVCodecBufferAttr attr = {};
                OH_AVErrCode attrResult = OH_AVBuffer_GetBufferAttr(outputItem.buffer, &attr);
                uint8_t* address = attrResult == AV_ERR_OK ? OH_AVBuffer_GetAddr(outputItem.buffer) : nullptr;
                if (attrResult == AV_ERR_OK && address != nullptr && attr.size > 0) {
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
                        startupStage_ = StartupStage::FIRST_PCM;
                        queueCondition_.notify_all();
                    }
                }
                outputEnded = attrResult == AV_ERR_OK && (attr.flags & AVCODEC_BUFFER_FLAGS_EOS) != 0;
                OH_AVErrCode freeResult = OH_AudioCodec_FreeOutputBuffer(decoder_, outputItem.index);
                if (attrResult != AV_ERR_OK || freeResult != AV_ERR_OK) {
                    FailDecoder("decoder output", attrResult, freeResult);
                    break;
                }
            }
        }
        if (!stopRequested_) {
            decodingEnded_ = outputEnded;
            decoderFailed_ = decoderFailed_.load() || !firstPcmReady_.load();
            queueCondition_.notify_all();
        }
    }

    void FailDecoder(const char* stage, int32_t primaryCode, int32_t secondaryCode)
    {
        bool alreadyFailed = decoderFailed_.exchange(true);
        startupStage_ = StartupStage::FAILED;
        queueCondition_.notify_all();
        codecQueueCondition_.notify_all();
        if (!alreadyFailed) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                "%{public}s failed primary=%{public}d secondary=%{public}d generation=%{public}llu",
                stage, primaryCode, secondaryCode,
                static_cast<unsigned long long>(codecGeneration_.load()));
        }
    }

    static void CodecErrorCallback(OH_AVCodec*, int32_t errorCode, void* userData)
    {
        if (userData == nullptr) {
            return;
        }
        NativeAudioPlayer* player = static_cast<NativeAudioPlayer*>(userData);
        player->FailDecoder("decoder callback", errorCode, 0);
    }

    static void CodecStreamChangedCallback(OH_AVCodec*, OH_AVFormat* format, void* userData)
    {
        if (userData == nullptr || format == nullptr) {
            return;
        }
        NativeAudioPlayer* player = static_cast<NativeAudioPlayer*>(userData);
        OH_AVFormat_GetIntValue(format, OH_MD_KEY_AUD_SAMPLE_RATE, &player->sampleRate_);
        OH_AVFormat_GetIntValue(format, OH_MD_KEY_AUD_CHANNEL_COUNT, &player->channelCount_);
    }

    static void CodecInputBufferCallback(OH_AVCodec*, uint32_t index, OH_AVBuffer* buffer, void* userData)
    {
        if (userData == nullptr || buffer == nullptr) {
            return;
        }
        NativeAudioPlayer* player = static_cast<NativeAudioPlayer*>(userData);
        {
            std::lock_guard<std::mutex> lock(player->codecQueueMutex_);
            if (player->stopRequested_ || !player->acceptingCodecCallbacks_ ||
                player->codecState_ != CodecState::STARTED) {
                return;
            }
            player->startupStage_ = StartupStage::INPUT_CALLBACK;
            player->inputBuffers_.push_back({ index, buffer, player->codecGeneration_.load() });
        }
        player->codecQueueCondition_.notify_one();
    }

    static void CodecOutputBufferCallback(OH_AVCodec*, uint32_t index, OH_AVBuffer* buffer, void* userData)
    {
        if (userData == nullptr || buffer == nullptr) {
            return;
        }
        NativeAudioPlayer* player = static_cast<NativeAudioPlayer*>(userData);
        {
            std::lock_guard<std::mutex> lock(player->codecQueueMutex_);
            if (player->stopRequested_ || !player->acceptingCodecCallbacks_ ||
                player->codecState_ != CodecState::STARTED) {
                return;
            }
            player->startupStage_ = StartupStage::OUTPUT_CALLBACK;
            player->outputBuffers_.push_back({ index, buffer, player->codecGeneration_.load() });
        }
        player->codecQueueCondition_.notify_one();
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
            player->decoderFailed_ = true;
            player->paused_ = true;
            OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                "render frame failed; marked native playback failed");
            return AUDIO_DATA_CALLBACK_RESULT_VALID;
        }
        player->MeasureOutput(audioData, audioDataSize, useEqualizer);
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
    std::mutex codecQueueMutex_;
    std::condition_variable codecQueueCondition_;
    std::deque<CodecBufferItem> inputBuffers_;
    std::deque<CodecBufferItem> outputBuffers_;
    std::atomic<uint64_t> codecGeneration_ = 0;
    std::atomic<bool> acceptingCodecCallbacks_ = false;
    std::atomic<CodecState> codecState_ = CodecState::EMPTY;
    std::atomic<RendererState> rendererState_ = RendererState::EMPTY;
    std::atomic<StartupStage> startupStage_ = StartupStage::IDLE;
    bool pipelineStarted_ = false;
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
    context->result = NativeAudioPlayer::Instance().Play(
        context->fd, context->size, context->startPositionMs, context->requestId);
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
    size_t argc = 3;
    napi_value args[3] = { nullptr, nullptr, nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t fd = -1;
    int64_t size = 0;
    int64_t startPositionMs = 0;
    if (argc < 2 || argc > 3 || napi_get_value_int32(env, args[0], &fd) != napi_ok ||
        napi_get_value_int64(env, args[1], &size) != napi_ok ||
        (argc == 3 && napi_get_value_int64(env, args[2], &startPositionMs) != napi_ok)) {
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
    context->startPositionMs = std::max<int64_t>(0, startPositionMs);
    context->requestId = latestPlayRequest.fetch_add(1) + 1;
    NativeAudioPlayer::Instance().RequestStop();
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
    NativeAudioPlayer::Instance().RequestStop();
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
        bands[i] = static_cast<int32_t>(
            std::clamp(value, EQUALIZER_MIN_GAIN_DB, EQUALIZER_MAX_GAIN_DB));
    }
    return BooleanValue(env, NativeAudioPlayer::Instance().SetBands(bands));
}

napi_value GetBands(napi_env env, napi_callback_info)
{
    std::array<int32_t, EQUALIZER_BAND_NUM> bands = NativeAudioPlayer::Instance().GetBands();
    napi_value result = nullptr;
    napi_create_array_with_length(env, bands.size(), &result);
    for (size_t i = 0; i < bands.size(); i++) {
        napi_value value = nullptr;
        napi_create_int32(env, bands[i], &value);
        napi_set_element(env, result, static_cast<uint32_t>(i), value);
    }
    return result;
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
        { "getEqualizerBands", nullptr, GetBands, nullptr, nullptr, nullptr, napi_default, nullptr },
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

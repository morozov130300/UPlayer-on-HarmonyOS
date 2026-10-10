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
#include <limits>
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
#include "ohaudio/native_audio_common.h"
#include "ohaudio/native_audio_manager.h"
#include "ohaudio/native_audio_stream_manager.h"
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

    static constexpr size_t MAX_ENTRIES = 256;
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
        OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
            "isEqualizerSupported result=%d supported=%d", static_cast<int>(result), supported ? 1 : 0);
        return result == AUDIOSUITE_SUCCESS && supported;
    }

    bool Play(int32_t fd, int64_t size, int64_t startPositionMs, uint64_t requestId)
    {
        const auto startedAt = std::chrono::steady_clock::now();
        auto elapsedMs = [&startedAt]() -> long long {
            return std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::steady_clock::now() - startedAt).count();
        };
        Stop();
        pipelineInputCalls_.store(0);
        pipelineInputBytes_.store(0);
        pipelineInputFirstLogged_.store(false);
        pipelineRenderCalls_ = 0;
        pipelineRenderReqBytes_ = 0;
        pipelineRenderRespBytes_ = 0;
        pipelineRenderFirstLogged_ = false;
        pipelineStatsBaseMs_ = 0;
        pipelineLastLogMs_ = 0;
        {
            std::lock_guard<std::mutex> lock(effectMutex_);
            activeEqEnabled_ = requestedEqEnabled_.load();
            baseHeadroomDb_ = activeEqEnabled_.load() ? std::max(0.0, maxPositiveGainDb_.load()) : 0.0;
            targetHeadroomDb_ = baseHeadroomDb_.load();
            headroomDb_ = baseHeadroomDb_.load();
        }
        OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
            "native startup stage=stop elapsedMs=%{public}lld", elapsedMs());
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
        OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
            "native startup stage=source elapsedMs=%{public}lld", elapsedMs());
        if (!ConfigureTrack()) {
            Stop();
            return false;
        }
        OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
            "native startup stage=track elapsedMs=%{public}lld", elapsedMs());
        if (!ConfigureDecoder()) {
            Stop();
            return false;
        }
        OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
            "native startup stage=decoder elapsedMs=%{public}lld", elapsedMs());
        if (!ConfigureEffects()) {
            Stop();
            return false;
        }
        OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
            "native startup stage=effects elapsedMs=%{public}lld", elapsedMs());
        if (!ConfigureRenderer()) {
            Stop();
            return false;
        }
        OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
            "native startup stage=renderer-config elapsedMs=%{public}lld", elapsedMs());
        if (requestId != latestPlayRequest.load()) {
            Stop();
            return false;
        }
        stopRequested_ = false;
        seekRequested_ = false;
        seekRequestSequence_ = 0;
        decoderFailureLogged_ = false;
        decoderLifecycle_ = DecoderLifecycle::STARTED;
        paused_ = false;
        completed_ = false;
        decoderEosReached_ = false;
        audioSuiteEofReached_ = false;
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
        resampleInputRate_ = sampleRate_;
        resamplePos_ = 0.0;
        resampleLeft_.clear();
        resampleRight_.clear();
        inputDensityFactor_ = 1;
        inputWindowFrames_ = 0;
        inputWindowStartMs_ = 0;
        OH_LOG_Print(LOG_APP, LOG_INFO, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
            "native track sampleRate=%{public}d channels=%{public}d resampleTo=%{public}d",
            sampleRate_, channelCount_, resampleOutputRate_);
        decoderThread_ = std::thread(&NativeAudioPlayer::DecoderLoop, this);
        if (OH_AudioRenderer_Start(renderer_) != AUDIOSTREAM_SUCCESS) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG, "renderer start failed");
            Stop();
            return false;
        }
        OH_LOG_Print(LOG_APP, LOG_INFO, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
            "native startup stage=started elapsedMs=%{public}lld", elapsedMs());
        return true;
    }

    bool Resume()
    {
        if (renderer_ == nullptr || completed_.load() || stopRequested_.load()) {
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
        if (demuxer_ == nullptr || decoder_ == nullptr || stopRequested_.load() || decodingEnded_.load() ||
            decoderLifecycle_.load() != DecoderLifecycle::STARTED) {
            return false;
        }
        seekPositionMs_ = std::max<int64_t>(0, positionMs);
        seekRequestSequence_.fetch_add(1);
        seekRequested_ = true;
        queueCondition_.notify_all();
        return true;
    }

    void RequestStop()
    {
        decoderLifecycle_ = DecoderLifecycle::STOPPING;
        stopRequested_ = true;
        seekRequested_ = false;
        queueCondition_.notify_all();
    }

    void Stop()
    {
        RequestStop();
        {
            std::lock_guard<std::mutex> lock(queueMutex_);
            pcmQueue_.clear();
        }
        queueCondition_.notify_all();
        // 先 join 解码线程，让它在 stopRequested_ 置位后自然退出（QueryInputBuffer/
        // QueryOutputBuffer 的 20ms 超时会让它快速返回并检查循环条件）。
        // 注意：不能在解码线程还在运行时调用 OH_AudioCodec_Stop，否则会与解码线程
        // 正在执行的 QueryInputBuffer/QueryOutputBuffer 并发，导致解码器进入非同步状态
        // 而解码线程仍在其内部访问，造成 "not in sync mode" 疯狂刷屏。
        if (decoderThread_.joinable()) {
            const auto joinStart = std::chrono::steady_clock::now();
            decoderThread_.join();
            const auto joinMs = std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::steady_clock::now() - joinStart).count();
            OH_LOG_Print(LOG_APP, LOG_INFO, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                "decoder thread joined elapsedMs=%{public}lld", static_cast<long long>(joinMs));
        }
        if (decoder_ != nullptr) {
            OH_AVErrCode stopResult = OH_AudioCodec_Stop(decoder_);
            OH_LOG_Print(LOG_APP, stopResult == AV_ERR_OK ? LOG_INFO : LOG_ERROR,
                UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG, "decoder stop result=%{public}d", static_cast<int>(stopResult));
        }
        if (renderer_ != nullptr) {
            OH_AudioStream_State rendererState = AUDIOSTREAM_STATE_INVALID;
            OH_AudioStream_Result stateResult = OH_AudioRenderer_GetCurrentState(renderer_, &rendererState);
            OH_LOG_Print(LOG_APP, LOG_INFO, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                "renderer get state result=%{public}d state=%{public}d",
                static_cast<int>(stateResult), static_cast<int>(rendererState));
            if (stateResult == AUDIOSTREAM_SUCCESS &&
                (rendererState == AUDIOSTREAM_STATE_RUNNING || rendererState == AUDIOSTREAM_STATE_PAUSED)) {
                OH_AudioStream_Result stopResult = OH_AudioRenderer_Stop(renderer_);
                OH_LOG_Print(LOG_APP, stopResult == AUDIOSTREAM_SUCCESS ? LOG_INFO : LOG_ERROR,
                    UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                    "renderer stop result=%{public}d state=%{public}d",
                    static_cast<int>(stopResult), static_cast<int>(rendererState));
            }
            if (stateResult != AUDIOSTREAM_SUCCESS || rendererState != AUDIOSTREAM_STATE_RELEASED) {
                OH_AudioStream_Result releaseResult = OH_AudioRenderer_Release(renderer_);
                OH_LOG_Print(LOG_APP, releaseResult == AUDIOSTREAM_SUCCESS ? LOG_INFO : LOG_ERROR,
                    UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                    "renderer release result=%{public}d state=%{public}d",
                    static_cast<int>(releaseResult), static_cast<int>(rendererState));
            }
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
        if (soundFieldNode_ != nullptr) {
            OH_AudioSuiteEngine_DestroyNode(soundFieldNode_);
            soundFieldNode_ = nullptr;
        }
        if (environmentNode_ != nullptr) {
            OH_AudioSuiteEngine_DestroyNode(environmentNode_);
            environmentNode_ = nullptr;
        }
        if (beautifierNode_ != nullptr) {
            OH_AudioSuiteEngine_DestroyNode(beautifierNode_);
            beautifierNode_ = nullptr;
        }
        if (spaceRenderNode_ != nullptr) {
            OH_AudioSuiteEngine_DestroyNode(spaceRenderNode_);
            spaceRenderNode_ = nullptr;
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
            OH_AVErrCode destroyResult = OH_AudioCodec_Destroy(decoder_);
            OH_LOG_Print(LOG_APP, destroyResult == AV_ERR_OK ? LOG_INFO : LOG_ERROR,
                UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG, "decoder destroy result=%{public}d",
                static_cast<int>(destroyResult));
            decoder_ = nullptr;
        }
        if (demuxer_ != nullptr) {
            OH_AVErrCode destroyResult = OH_AVDemuxer_Destroy(demuxer_);
            OH_LOG_Print(LOG_APP, destroyResult == AV_ERR_OK ? LOG_INFO : LOG_ERROR,
                UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG, "demuxer destroy result=%{public}d",
                static_cast<int>(destroyResult));
            demuxer_ = nullptr;
        }
        if (source_ != nullptr) {
            OH_AVErrCode destroyResult = OH_AVSource_Destroy(source_);
            OH_LOG_Print(LOG_APP, destroyResult == AV_ERR_OK ? LOG_INFO : LOG_ERROR,
                UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG, "source destroy result=%{public}d",
                static_cast<int>(destroyResult));
            source_ = nullptr;
        }
        ReleaseSource();
        paused_ = false;
        completed_ = false;
        decoderEosReached_ = false;
        audioSuiteEofReached_ = false;
        decodingEnded_ = false;
        decoderFailed_ = false;
        firstPcmReady_ = false;
        currentPositionMs_ = 0;
        durationMs_ = 0;
        seekRequestSequence_ = 0;
        decoderFailureLogged_ = false;
        decoderLifecycle_ = DecoderLifecycle::STOPPED;
        measurementSquareSum_ = 0.0;
        measurementSampleCount_ = 0;
        inputMeasurementSampleCount_ = 0;
        inputPositiveFullScaleCount_ = 0;
        inputNegativeFullScaleCount_ = 0;
        outputPositiveFullScaleCount_ = 0;
        outputNegativeFullScaleCount_ = 0;
        measurementPeak_ = 0;
        consecutiveClippingWindows_ = 0;
        cleanHeadroomWindows_ = 0;
        baseHeadroomDb_ = 0.0;
        targetHeadroomDb_ = 0.0;
        headroomDb_ = 0.0;
    }

    bool SetEnabled(bool enabled)
    {
        if (enabled && !IsEqualizerSupported()) {
            return false;
        }
        std::lock_guard<std::mutex> lock(effectMutex_);
        requestedEqEnabled_ = enabled;
        activeEqEnabled_ = enabled;
        OH_LOG_Print(LOG_APP, LOG_INFO, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
            "effect toggle eq=%{public}d", enabled ? 1 : 0);
        baseHeadroomDb_ = enabled ? std::max(0.0, maxPositiveGainDb_.load()) : 0.0;
        targetHeadroomDb_ = baseHeadroomDb_.load();
        if (!enabled) {
            headroomDb_ = 0.0;
            consecutiveClippingWindows_ = 0;
            cleanHeadroomWindows_ = 0;
        } else {
            headroomDb_ = std::max(headroomDb_.load(), baseHeadroomDb_.load());
        }
        // 管线可能被其他效果占用，EQ 节点旁路状态必须与开关同步，避免关闭 EQ 后残留处理
        if (eqNode_ == nullptr) {
            return true;
        }
        if (enabled) {
            return ApplyBandsLocked(bands_, false);
        }
        return BypassNodeLocked(eqNode_, true);
    }

    bool SetBands(const std::array<int32_t, EQUALIZER_BAND_NUM>& bands)
    {
        std::lock_guard<std::mutex> lock(effectMutex_);
        bands_ = bands;
        maxPositiveGainDb_ = static_cast<double>(*std::max_element(bands_.begin(), bands_.end()));
        const double baseHeadroom = requestedEqEnabled_.load() ? std::max(0.0, maxPositiveGainDb_.load()) : 0.0;
        baseHeadroomDb_ = baseHeadroom;
        targetHeadroomDb_ = baseHeadroom;
        headroomDb_ = std::max(headroomDb_.load(), baseHeadroom);
        cleanHeadroomWindows_ = 0;
        if (baseHeadroom <= 0.0) {
            targetHeadroomDb_ = 0.0;
            headroomDb_ = 0.0;
        }
        if (!requestedEqEnabled_ || eqNode_ == nullptr) {
            return true;
        }
        return ApplyBandsLocked(bands_, false);
    }

    std::array<int32_t, EQUALIZER_BAND_NUM> GetBands()
    {
        std::lock_guard<std::mutex> lock(effectMutex_);
        return bands_;
    }

    // 任一效果启用即需要走管线渲染：EQ 用 Play 时的 active 快照，
    // 4 类新效果节点全建 + Bypass 即时切换，直接用 requested 原子量
    bool IsPipelineActive() const
    {
        return activeEqEnabled_.load() || requestedSoundFieldEnabled_.load() ||
            requestedEnvironmentEnabled_.load() || requestedBeautifierEnabled_.load() ||
            requestedSpaceRenderEnabled_.load();
    }

    bool SetSoundFieldEnabled(bool enabled)
    {
        std::lock_guard<std::mutex> lock(effectMutex_);
        requestedSoundFieldEnabled_ = enabled;
        OH_LOG_Print(LOG_APP, LOG_INFO, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
            "effect toggle soundField=%{public}d", enabled ? 1 : 0);
        if (soundFieldNode_ == nullptr) {
            return true;
        }
        if (enabled) {
            return SetSoundFieldStateLocked();
        }
        return BypassNodeLocked(soundFieldNode_, true);
    }

    bool SetSoundFieldType(int32_t type)
    {
        if (type < 1 || type > 4) {
            return false;
        }
        soundFieldType_ = type;
        std::lock_guard<std::mutex> lock(effectMutex_);
        if (soundFieldNode_ == nullptr || !requestedSoundFieldEnabled_.load()) {
            return true;
        }
        OH_AudioSuite_Result result = OH_AudioSuiteEngine_SetSoundFieldType(
            soundFieldNode_, static_cast<OH_SoundFieldType>(type));
        if (result != AUDIOSUITE_SUCCESS) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                "set sound field type failed code=%{public}d type=%{public}d",
                static_cast<int>(result), type);
            return false;
        }
        return true;
    }

    bool SetEnvironmentEnabled(bool enabled)
    {
        std::lock_guard<std::mutex> lock(effectMutex_);
        requestedEnvironmentEnabled_ = enabled;
        OH_LOG_Print(LOG_APP, LOG_INFO, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
            "effect toggle environment=%{public}d", enabled ? 1 : 0);
        if (environmentNode_ == nullptr) {
            return true;
        }
        if (enabled) {
            return SetEnvironmentStateLocked();
        }
        return BypassNodeLocked(environmentNode_, true);
    }

    bool SetEnvironmentType(int32_t type)
    {
        if (type < 1 || type > 4) {
            return false;
        }
        environmentType_ = type;
        std::lock_guard<std::mutex> lock(effectMutex_);
        if (environmentNode_ == nullptr || !requestedEnvironmentEnabled_.load()) {
            return true;
        }
        OH_AudioSuite_Result result = OH_AudioSuiteEngine_SetEnvironmentType(
            environmentNode_, static_cast<OH_EnvironmentType>(type));
        if (result != AUDIOSUITE_SUCCESS) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                "set environment type failed code=%{public}d type=%{public}d",
                static_cast<int>(result), type);
            return false;
        }
        return true;
    }

    bool SetVoiceBeautifierEnabled(bool enabled)
    {
        std::lock_guard<std::mutex> lock(effectMutex_);
        requestedBeautifierEnabled_ = enabled;
        OH_LOG_Print(LOG_APP, LOG_INFO, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
            "effect toggle beautifier=%{public}d", enabled ? 1 : 0);
        if (beautifierNode_ == nullptr) {
            return true;
        }
        if (enabled) {
            return SetBeautifierStateLocked();
        }
        return BypassNodeLocked(beautifierNode_, true);
    }

    bool SetVoiceBeautifierType(int32_t type)
    {
        if (type < 1 || type > 4) {
            return false;
        }
        beautifierType_ = type;
        std::lock_guard<std::mutex> lock(effectMutex_);
        if (beautifierNode_ == nullptr || !requestedBeautifierEnabled_.load()) {
            return true;
        }
        OH_AudioSuite_Result result = OH_AudioSuiteEngine_SetVoiceBeautifierType(
            beautifierNode_, static_cast<OH_VoiceBeautifierType>(type));
        if (result != AUDIOSUITE_SUCCESS) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                "set voice beautifier type failed code=%{public}d type=%{public}d",
                static_cast<int>(result), type);
            return false;
        }
        return true;
    }

    bool SetSpaceRenderEnabled(bool enabled)
    {
        std::lock_guard<std::mutex> lock(effectMutex_);
        requestedSpaceRenderEnabled_ = enabled;
        OH_LOG_Print(LOG_APP, LOG_INFO, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
            "effect toggle spaceRender=%{public}d", enabled ? 1 : 0);
        if (spaceRenderNode_ == nullptr) {
            return true;
        }
        if (enabled) {
            return SetSpaceRenderStateLocked();
        }
        return BypassNodeLocked(spaceRenderNode_, true);
    }

    // mode: 0=固定摆位(values={x,y,z}) 1=旋转({x,y,z,surroundTime,surroundDirection}) 2=扩展({extRadius,extAngle})
    bool SetSpaceRenderConfig(int32_t mode, const std::vector<float>& values)
    {
        if (mode < 0 || mode > 2) {
            return false;
        }
        std::lock_guard<std::mutex> lock(effectMutex_);
        spaceRenderMode_ = mode;
        switch (mode) {
            case 0:
                if (values.size() != 3) {
                    return false;
                }
                spaceX_ = std::clamp(values[0], -5.0f, 5.0f);
                spaceY_ = std::clamp(values[1], -5.0f, 5.0f);
                spaceZ_ = std::clamp(values[2], -5.0f, 5.0f);
                break;
            case 1:
                if (values.size() != 5) {
                    return false;
                }
                spaceX_ = std::clamp(values[0], -5.0f, 5.0f);
                spaceY_ = std::clamp(values[1], -5.0f, 5.0f);
                spaceZ_ = std::clamp(values[2], -5.0f, 5.0f);
                spaceSurroundTime_ = static_cast<int32_t>(
                    std::lround(std::clamp(static_cast<double>(values[3]), 2.0, 40.0)));
                spaceSurroundDirection_ = values[4] >= 0.5f ? 1 : 0;
                break;
            default:
                if (values.size() != 2) {
                    return false;
                }
                spaceExtRadius_ = std::clamp(values[0], 1.0f, 5.0f);
                spaceExtAngle_ = static_cast<int32_t>(
                    std::lround(std::clamp(static_cast<double>(values[1]), 1.0, 359.0)));
                break;
        }
        if (spaceRenderNode_ == nullptr || !requestedSpaceRenderEnabled_.load()) {
            return true;
        }
        return ApplySpaceRenderParamsLocked();
    }

    bool IsEffectNodeSupported(int32_t nodeType)
    {
        bool supported = false;
        OH_AudioSuite_Result result = OH_AudioSuiteEngine_IsNodeTypeSupported(
            static_cast<OH_AudioNode_Type>(nodeType), &supported);
        OH_LOG_Print(LOG_APP, LOG_INFO, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
            "isEffectNodeSupported type=%{public}d result=%{public}d supported=%{public}d",
            nodeType, static_cast<int>(result), supported ? 1 : 0);
        return result == AUDIOSUITE_SUCCESS && supported;
    }

    bool IsEqualizerEnabled() const
    {
        return requestedEqEnabled_;
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
        OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
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

    bool BypassNodeLocked(OH_AudioNode* node, bool bypass)
    {
        OH_AudioSuite_Result result = OH_AudioSuiteEngine_BypassEffectNode(node, bypass);
        if (result != AUDIOSUITE_SUCCESS) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                "bypass effect node failed bypass=%{public}d code=%{public}d",
                bypass ? 1 : 0, static_cast<int>(result));
            return false;
        }
        return true;
    }

    bool SetSoundFieldStateLocked()
    {
        if (soundFieldNode_ == nullptr) {
            return true;
        }
        if (!BypassNodeLocked(soundFieldNode_, false)) {
            return false;
        }
        OH_AudioSuite_Result result = OH_AudioSuiteEngine_SetSoundFieldType(
            soundFieldNode_, static_cast<OH_SoundFieldType>(soundFieldType_.load()));
        if (result != AUDIOSUITE_SUCCESS) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                "set sound field type failed code=%{public}d type=%{public}d",
                static_cast<int>(result), soundFieldType_.load());
            return false;
        }
        return true;
    }

    bool SetEnvironmentStateLocked()
    {
        if (environmentNode_ == nullptr) {
            return true;
        }
        if (!BypassNodeLocked(environmentNode_, false)) {
            return false;
        }
        OH_AudioSuite_Result result = OH_AudioSuiteEngine_SetEnvironmentType(
            environmentNode_, static_cast<OH_EnvironmentType>(environmentType_.load()));
        if (result != AUDIOSUITE_SUCCESS) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                "set environment type failed code=%{public}d type=%{public}d",
                static_cast<int>(result), environmentType_.load());
            return false;
        }
        return true;
    }

    bool SetBeautifierStateLocked()
    {
        if (beautifierNode_ == nullptr) {
            return true;
        }
        if (!BypassNodeLocked(beautifierNode_, false)) {
            return false;
        }
        OH_AudioSuite_Result result = OH_AudioSuiteEngine_SetVoiceBeautifierType(
            beautifierNode_, static_cast<OH_VoiceBeautifierType>(beautifierType_.load()));
        if (result != AUDIOSUITE_SUCCESS) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                "set voice beautifier type failed code=%{public}d type=%{public}d",
                static_cast<int>(result), beautifierType_.load());
            return false;
        }
        return true;
    }

    bool ApplySpaceRenderParamsLocked()
    {
        if (spaceRenderNode_ == nullptr) {
            return true;
        }
        OH_AudioSuite_Result result = AUDIOSUITE_SUCCESS;
        switch (spaceRenderMode_.load()) {
            case 0: {
                OH_AudioSuite_SpaceRenderPositionParams position = {};
                position.x = spaceX_;
                position.y = spaceY_;
                position.z = spaceZ_;
                result = OH_AudioSuiteEngine_SetSpaceRenderPositionParams(spaceRenderNode_, position);
                break;
            }
            case 1: {
                OH_AudioSuite_SpaceRenderRotationParams rotation = {};
                rotation.x = spaceX_;
                rotation.y = spaceY_;
                rotation.z = spaceZ_;
                rotation.surroundTime = spaceSurroundTime_;
                rotation.surroundDirection =
                    static_cast<OH_AudioSuite_SurroundDirection>(spaceSurroundDirection_);
                result = OH_AudioSuiteEngine_SetSpaceRenderRotationParams(spaceRenderNode_, rotation);
                break;
            }
            default: {
                OH_AudioSuite_SpaceRenderExtensionParams extension = {};
                extension.extRadius = spaceExtRadius_;
                extension.extAngle = spaceExtAngle_;
                result = OH_AudioSuiteEngine_SetSpaceRenderExtensionParams(spaceRenderNode_, extension);
                break;
            }
        }
        if (result != AUDIOSUITE_SUCCESS) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                "set space render params failed mode=%{public}d code=%{public}d",
                spaceRenderMode_.load(), static_cast<int>(result));
            return false;
        }
        return true;
    }

    bool SetSpaceRenderStateLocked()
    {
        if (spaceRenderNode_ == nullptr) {
            return true;
        }
        if (!BypassNodeLocked(spaceRenderNode_, false)) {
            return false;
        }
        return ApplySpaceRenderParamsLocked();
    }

    // required=true 时节点创建失败视为致命错误（效果被请求），否则尽力而为跳过该节点
    bool CreateOptionalEffectNode(OH_AudioNodeBuilder* builder, OH_AudioNode_Type type, bool required,
        OH_AudioNode** node)
    {
        bool supported = false;
        OH_AudioSuite_Result probeResult = OH_AudioSuiteEngine_IsNodeTypeSupported(type, &supported);
        if (probeResult != AUDIOSUITE_SUCCESS || !supported) {
            OH_LOG_Print(LOG_APP, LOG_INFO, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                "effect node type=%{public}d unsupported code=%{public}d",
                static_cast<int>(type), static_cast<int>(probeResult));
            return !required;
        }
        OH_AudioSuite_Result createResult = OH_AudioSuiteEngine_CreateNode(pipeline_, builder, node);
        if (createResult != AUDIOSUITE_SUCCESS) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                "create effect node type=%{public}d failed code=%{public}d",
                static_cast<int>(type), static_cast<int>(createResult));
            return !required;
        }
        OH_LOG_Print(LOG_APP, LOG_INFO, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
            "effect node type=%{public}d created", static_cast<int>(type));
        return true;
    }

    // 动态串联存在的节点：input → eq → soundField → environment → beautifier → spaceRender → output
    bool ChainNodes()
    {
        std::vector<OH_AudioNode*> chain;
        chain.reserve(7);
        chain.push_back(inputNode_);
        OH_AudioNode* effectNodes[] = { eqNode_, soundFieldNode_, environmentNode_, beautifierNode_,
            spaceRenderNode_ };
        for (OH_AudioNode* node : effectNodes) {
            if (node != nullptr) {
                chain.push_back(node);
            }
        }
        chain.push_back(outputNode_);
        for (size_t i = 0; i + 1 < chain.size(); i++) {
            if (OH_AudioSuiteEngine_ConnectNodes(chain[i], chain[i + 1]) != AUDIOSUITE_SUCCESS) {
                OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                    "connect effect nodes failed index=%{public}zu", i);
                return false;
            }
        }
        return true;
    }

    bool ApplyEffectStatesLocked()
    {
        if (eqNode_ != nullptr) {
            if (activeEqEnabled_.load()) {
                if (!ApplyBandsLocked(bands_, true)) {
                    return false;
                }
            } else if (!BypassNodeLocked(eqNode_, true)) {
                return false;
            }
        }
        if (soundFieldNode_ != nullptr) {
            if (requestedSoundFieldEnabled_.load()) {
                if (!SetSoundFieldStateLocked()) {
                    return false;
                }
            } else if (!BypassNodeLocked(soundFieldNode_, true)) {
                return false;
            }
        }
        if (environmentNode_ != nullptr) {
            if (requestedEnvironmentEnabled_.load()) {
                if (!SetEnvironmentStateLocked()) {
                    return false;
                }
            } else if (!BypassNodeLocked(environmentNode_, true)) {
                return false;
            }
        }
        if (beautifierNode_ != nullptr) {
            if (requestedBeautifierEnabled_.load()) {
                if (!SetBeautifierStateLocked()) {
                    return false;
                }
            } else if (!BypassNodeLocked(beautifierNode_, true)) {
                return false;
            }
        }
        if (spaceRenderNode_ != nullptr) {
            if (requestedSpaceRenderEnabled_.load()) {
                if (!SetSpaceRenderStateLocked()) {
                    return false;
                }
            } else if (!BypassNodeLocked(spaceRenderNode_, true)) {
                return false;
            }
        }
        return true;
    }

    NativeAudioPlayer() = default;
    ~NativeAudioPlayer()
    {
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
        // QueryInputBuffer/QueryOutputBuffer 仅允许在同步模式使用。同步模式必须在
        // Configure 阶段通过 OH_MD_KEY_ENABLE_SYNC_MODE 显式启用，默认值 0 是异步模式。
        OH_AVFormat_SetIntValue(trackFormat_, OH_MD_KEY_ENABLE_SYNC_MODE, 1);
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
        inputFormat.samplingRate = SAMPLE_RATE_48000;
        inputFormat.channelLayout = CH_LAYOUT_STEREO;
        inputFormat.channelCount = 2;
        inputFormat.encodingType = AUDIO_ENCODING_TYPE_RAW;
        inputFormat.sampleFormat = AUDIO_SAMPLE_S16LE;
        OH_AudioSuiteNodeBuilder_SetNodeType(builder, INPUT_NODE_TYPE_DEFAULT);
        OH_AudioSuiteNodeBuilder_SetFormat(builder, inputFormat);
        OH_AudioSuiteNodeBuilder_SetRequestDataCallback(builder, InputDataCallback, this);
        bool success = OH_AudioSuiteEngine_CreateNode(pipeline_, builder, &inputNode_) == AUDIOSUITE_SUCCESS;
        OH_AudioSuiteNodeBuilder_Reset(builder);
        OH_AudioSuiteNodeBuilder_SetNodeType(builder, EFFECT_NODE_TYPE_EQUALIZER);
        success = success && CreateOptionalEffectNode(builder, EFFECT_NODE_TYPE_EQUALIZER,
            activeEqEnabled_.load(), &eqNode_);
        OH_AudioSuiteNodeBuilder_Reset(builder);
        OH_AudioSuiteNodeBuilder_SetNodeType(builder, EFFECT_NODE_TYPE_SOUND_FIELD);
        success = success && CreateOptionalEffectNode(builder, EFFECT_NODE_TYPE_SOUND_FIELD, false,
            &soundFieldNode_);
        OH_AudioSuiteNodeBuilder_Reset(builder);
        OH_AudioSuiteNodeBuilder_SetNodeType(builder, EFFECT_NODE_TYPE_ENVIRONMENT_EFFECT);
        success = success && CreateOptionalEffectNode(builder, EFFECT_NODE_TYPE_ENVIRONMENT_EFFECT, false,
            &environmentNode_);
        OH_AudioSuiteNodeBuilder_Reset(builder);
        OH_AudioSuiteNodeBuilder_SetNodeType(builder, EFFECT_NODE_TYPE_VOICE_BEAUTIFIER);
        success = success && CreateOptionalEffectNode(builder, EFFECT_NODE_TYPE_VOICE_BEAUTIFIER, false,
            &beautifierNode_);
        OH_AudioSuiteNodeBuilder_Reset(builder);
        OH_AudioSuiteNodeBuilder_SetNodeType(builder, EFFECT_NODE_TYPE_SPACE_RENDER);
        success = success && CreateOptionalEffectNode(builder, EFFECT_NODE_TYPE_SPACE_RENDER, false,
            &spaceRenderNode_);
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
        if (!success || !ChainNodes()) {
            return false;
        }
        {
            std::lock_guard<std::mutex> lock(effectMutex_);
            if (!ApplyEffectStatesLocked()) {
                return false;
            }
        }
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
        // 低时延播放：用系统接口探测当前设备对 48kHz/立体声/S16LE 音乐流是否支持 FAST 通路，
        // 支持则启用低时延模式并设置官方示例回调帧长；不支持时系统静默回落普通模式（官方文档行为）。
        // 注意：本机 SDK 头文件中 OH_AudioManager_GetAudioStreamManager 为单参签名，
        // OH_AudioStreamInfo（v19 布局）无 channels 字段，声道用 channelLayout 表达
        {
            OH_AudioStreamManager* streamManager = nullptr;
            if (OH_AudioManager_GetAudioStreamManager(&streamManager) == AUDIOCOMMON_RESULT_SUCCESS &&
                streamManager != nullptr) {
                OH_AudioStreamInfo streamInfo = {};
                streamInfo.samplingRate = 48000;
                streamInfo.channelLayout = CH_LAYOUT_STEREO;
                streamInfo.encodingType = AUDIOSTREAM_ENCODING_TYPE_RAW;
                streamInfo.sampleFormat = AUDIOSTREAM_SAMPLE_S16LE;
                if (OH_AudioStreamManager_IsFastPlaybackSupported(streamManager, &streamInfo,
                    AUDIOSTREAM_USAGE_MUSIC)) {
                    OH_AudioStreamBuilder_SetLatencyMode(builder, AUDIOSTREAM_LATENCY_MODE_FAST);
                    OH_AudioStreamBuilder_SetFrameSizeInCallback(builder, 2500);
                    OH_LOG_Print(LOG_APP, LOG_INFO, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                        "low-latency playback supported: FAST latency mode enabled");
                }
            }
        }
        bool success = OH_AudioStreamBuilder_GenerateRenderer(builder, &renderer_) == AUDIOSTREAM_SUCCESS;
        OH_AudioStreamBuilder_Destroy(builder);
        if (success) {
            OH_AudioRenderer_SetSpeed(renderer_, playbackSpeed_);
            OH_AudioRenderer_SetVolume(renderer_, volume_);
            int32_t actualRate = 0;
            int32_t actualChannels = 0;
            int32_t actualFrameSize = 0;
            float actualSpeed = 0.0f;
            OH_AudioStream_LatencyMode latencyMode = AUDIOSTREAM_LATENCY_MODE_NORMAL;
            OH_AudioRenderer_GetSamplingRate(renderer_, &actualRate);
            OH_AudioRenderer_GetChannelCount(renderer_, &actualChannels);
            OH_AudioRenderer_GetLatencyMode(renderer_, &latencyMode);
            OH_AudioRenderer_GetFrameSizeInCallback(renderer_, &actualFrameSize);
            OH_AudioRenderer_GetSpeed(renderer_, &actualSpeed);
            OH_LOG_Print(LOG_APP, LOG_INFO, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                "renderer actual rate=%{public}d channels=%{public}d latency=%{public}d "
                "frameSize=%{public}d speed=%{public}.3f",
                actualRate, actualChannels, static_cast<int>(latencyMode), actualFrameSize, actualSpeed);
        }
        if (!success) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG, "generate renderer failed");
        }
        return success;
    }

    bool RestoreDecoderAfterSeek(int64_t seekPosition, uint64_t requestSequence)
    {
        decoderLifecycle_ = DecoderLifecycle::SEEKING;
        OH_AVErrCode stopResult = OH_AudioCodec_Stop(decoder_);
        if (stopResult != AV_ERR_OK) {
            MarkDecoderTerminalFailure("SeekStop", stopResult);
            return false;
        }
        OH_AVErrCode seekResult = OH_AVDemuxer_SeekToTime(demuxer_, seekPosition, SEEK_MODE_CLOSEST_SYNC);
        if (seekResult != AV_ERR_OK) {
            MarkDecoderTerminalFailure("SeekDemux", seekResult);
            return false;
        }
        if (stopRequested_.load()) {
            return false;
        }
        OH_AVErrCode startResult = OH_AudioCodec_Start(decoder_);
        if (startResult != AV_ERR_OK) {
            MarkDecoderTerminalFailure("SeekRestart", startResult);
            return false;
        }
        {
            std::lock_guard<std::mutex> lock(queueMutex_);
            pcmQueue_.clear();
            resampleLeft_.clear();
            resampleRight_.clear();
            resamplePos_ = 0.0;
        }
        firstPcmReady_ = false;
        currentPositionMs_ = seekPosition;
        completed_ = false;
        decoderEosReached_ = false;
        audioSuiteEofReached_ = false;
        decodingEnded_ = false;
        decoderLifecycle_ = DecoderLifecycle::STARTED;
        queueCondition_.notify_all();
        OH_LOG_Print(LOG_APP, LOG_INFO, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
            "decoder seek restored position=%{public}lld sequence=%{public}llu",
            static_cast<long long>(seekPosition), static_cast<unsigned long long>(requestSequence));
        return true;
    }

    void MarkDecoderTerminalFailure(const char* operation, OH_AVErrCode result)
    {
        bool expected = false;
        if (decoderFailureLogged_.compare_exchange_strong(expected, true)) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                "decoder terminal failure operation=%{public}s code=%{public}d stop=%{public}d",
                operation, static_cast<int>(result), stopRequested_.load() ? 1 : 0);
        }
        decoderLifecycle_ = DecoderLifecycle::FAILED;
        decoderFailed_ = true;
        decodingEnded_ = true;
        queueCondition_.notify_all();
    }

    void DecoderLoop()
    {
        bool inputEnded = false;
        bool outputEnded = false;
        bool terminalFailure = false;
        decoderFailureLogged_ = false;
        while (!stopRequested_.load() && !outputEnded && !terminalFailure) {
            if (seekRequested_.exchange(false)) {
                const uint64_t requestSequence = seekRequestSequence_.load();
                const int64_t seekPosition = seekPositionMs_.load();
                if (!RestoreDecoderAfterSeek(seekPosition, requestSequence)) {
                    terminalFailure = !stopRequested_.load();
                    break;
                }
                inputEnded = false;
                outputEnded = false;
                if (requestSequence != seekRequestSequence_.load()) {
                    seekRequested_ = true;
                    continue;
                }
            }
            if (decoderLifecycle_.load() != DecoderLifecycle::STARTED) {
                MarkDecoderTerminalFailure("DecoderLifecycle", AV_ERR_INVALID_STATE);
                terminalFailure = true;
                break;
            }
            if (!inputEnded) {
                uint32_t inputIndex = 0;
                OH_AVErrCode inputResult = OH_AudioCodec_QueryInputBuffer(decoder_, &inputIndex, 20000);
                if (inputResult == AV_ERR_OK) {
                    OH_AVBuffer* inputBuffer = OH_AudioCodec_GetInputBuffer(decoder_, inputIndex);
                    if (inputBuffer == nullptr) {
                        MarkDecoderTerminalFailure("GetInputBuffer", AV_ERR_INVALID_VAL);
                        terminalFailure = true;
                    } else {
                        OH_AVErrCode readResult = OH_AVDemuxer_ReadSampleBuffer(demuxer_, trackIndex_, inputBuffer);
                        if (readResult != AV_ERR_OK) {
                            MarkDecoderTerminalFailure("ReadSampleBuffer", readResult);
                            terminalFailure = true;
                        } else {
                            OH_AVCodecBufferAttr attr = {};
                            OH_AVBuffer_GetBufferAttr(inputBuffer, &attr);
                            inputEnded = (attr.flags & AVCODEC_BUFFER_FLAGS_EOS) != 0;
                            OH_AVErrCode pushResult = OH_AudioCodec_PushInputBuffer(decoder_, inputIndex);
                            if (pushResult != AV_ERR_OK) {
                                MarkDecoderTerminalFailure("PushInputBuffer", pushResult);
                                terminalFailure = true;
                            }
                        }
                    }
                } else if (inputResult != AV_ERR_TRY_AGAIN_LATER) {
                    MarkDecoderTerminalFailure("QueryInputBuffer", inputResult);
                    terminalFailure = true;
                }
            }
            if (stopRequested_.load() || terminalFailure || seekRequested_.load()) {
                continue;
            }
            uint32_t outputIndex = 0;
            OH_AVErrCode outputResult = OH_AudioCodec_QueryOutputBuffer(decoder_, &outputIndex, 20000);
            if (outputResult == AV_ERR_STREAM_CHANGED) {
                OH_AVFormat* outputFormat = OH_AudioCodec_GetOutputDescription(decoder_);
                if (outputFormat == nullptr) {
                    MarkDecoderTerminalFailure("GetOutputDescription", AV_ERR_INVALID_STATE);
                    terminalFailure = true;
                } else {
                    OH_AVFormat_GetIntValue(outputFormat, OH_MD_KEY_AUD_SAMPLE_RATE, &sampleRate_);
                    OH_AVFormat_GetIntValue(outputFormat, OH_MD_KEY_AUD_CHANNEL_COUNT, &channelCount_);
                    OH_AVFormat_Destroy(outputFormat);
                    resampleInputRate_ = sampleRate_;
                }
            } else if (outputResult == AV_ERR_OK) {
                OH_AVBuffer* outputBuffer = OH_AudioCodec_GetOutputBuffer(decoder_, outputIndex);
                if (outputBuffer == nullptr) {
                    MarkDecoderTerminalFailure("GetOutputBuffer", AV_ERR_INVALID_VAL);
                    terminalFailure = true;
                } else {
                    OH_AVCodecBufferAttr attr = {};
                    OH_AVBuffer_GetBufferAttr(outputBuffer, &attr);
                    uint8_t* address = OH_AVBuffer_GetAddr(outputBuffer);
                    if (address != nullptr && attr.size > 0) {
                        uint8_t* begin = address + attr.offset;
                        std::unique_lock<std::mutex> lock(queueMutex_);
                        queueCondition_.wait(lock, [this]() {
                            return stopRequested_.load() || seekRequested_.load() || pcmQueue_.size() < maxQueueBytes_;
                        });
                        if (!stopRequested_.load() && !seekRequested_.load()) {
                            pcmQueue_.insert(pcmQueue_.end(), begin, begin + attr.size);
                            currentPositionMs_ = attr.pts / 1000;
                            firstPcmReady_ = true;
                            queueCondition_.notify_all();
                        }
                    }
                    outputEnded = (attr.flags & AVCODEC_BUFFER_FLAGS_EOS) != 0;
                    if (outputEnded) {
                        decoderEosReached_ = true;
                    }
                    OH_AVErrCode freeResult = OH_AudioCodec_FreeOutputBuffer(decoder_, outputIndex);
                    if (freeResult != AV_ERR_OK) {
                        MarkDecoderTerminalFailure("FreeOutputBuffer", freeResult);
                        terminalFailure = true;
                    }
                }
            } else if (outputResult != AV_ERR_TRY_AGAIN_LATER) {
                MarkDecoderTerminalFailure("QueryOutputBuffer", outputResult);
                terminalFailure = true;
            }
        }
        if (!stopRequested_.load()) {
            decodingEnded_ = true;
            if (terminalFailure) {
                decoderFailed_ = true;
            }
            queueCondition_.notify_all();
        }
    }

    int32_t ReadPcm(void* audioData, int32_t audioDataSize, bool* finished)
    {
        if (audioData == nullptr || audioDataSize <= 0 || finished == nullptr) {
            return 0;
        }
        int16_t* out = static_cast<int16_t*>(audioData);
        int32_t outSamples = audioDataSize / 4; // 立体声 S16LE，每采样点 4 字节
        int32_t written = 0;
        const int32_t effOutRate = resampleOutputRate_ * inputDensityFactor_;
        const double ratio = static_cast<double>(resampleInputRate_) / static_cast<double>(effOutRate);
        // 循环填充，直到写满请求的采样点数或解码结束。
        // 不能在持有 queueMutex_ 时等待，否则解码线程无法填充 pcmQueue_ 造成死锁。
        while (written < outSamples) {
            std::unique_lock<std::mutex> lock(queueMutex_);
            // 从 pcmQueue_ 读取源采样率 PCM（立体声 S16LE，每采样点 4 字节）到重采样缓冲
            while (pcmQueue_.size() >= 4 && resampleLeft_.size() < 4096) {
                int16_t left = static_cast<int16_t>((pcmQueue_[0] & 0xFF) | (pcmQueue_[1] << 8));
                int16_t right = static_cast<int16_t>((pcmQueue_[2] & 0xFF) | (pcmQueue_[3] << 8));
                resampleLeft_.push_back(left);
                resampleRight_.push_back(right);
                pcmQueue_.pop_front();
                pcmQueue_.pop_front();
                pcmQueue_.pop_front();
                pcmQueue_.pop_front();
            }
            // 数据不足且解码未结束：释放锁等待解码线程产出数据（带超时，防止偶发卡死）
            if (resampleLeft_.size() < 2 && !decodingEnded_.load()) {
                queueCondition_.wait_for(lock, std::chrono::milliseconds(50), [this]() {
                    return stopRequested_.load() || decodingEnded_.load() ||
                        resampleLeft_.size() >= 2 || pcmQueue_.size() >= 4;
                });
                if (stopRequested_.load()) {
                    *finished = true;
                    return written * 4;
                }
                continue;
            }
            // 线性插值重采样：源采样率 -> 48000
            while (written < outSamples && resampleLeft_.size() >= 2) {
                double pos = resamplePos_;
                int32_t idx = static_cast<int32_t>(pos);
                if (idx + 1 >= static_cast<int32_t>(resampleLeft_.size())) {
                    // resamplePos_ 已指向缓冲末尾，消费掉已越过的采样点后回到缓冲开头继续
                    int32_t skip = static_cast<int32_t>(resampleLeft_.size()) - 1;
                    for (int32_t i = 0; i < skip && !resampleLeft_.empty(); i++) {
                        resampleLeft_.pop_front();
                        resampleRight_.pop_front();
                    }
                    resamplePos_ -= skip;
                    continue;
                }
                double frac = pos - idx;
                int16_t l0 = resampleLeft_[idx];
                int16_t l1 = resampleLeft_[idx + 1];
                int16_t r0 = resampleRight_[idx];
                int16_t r1 = resampleRight_[idx + 1];
                out[written * 2] = static_cast<int16_t>(l0 + (l1 - l0) * frac);
                out[written * 2 + 1] = static_cast<int16_t>(r0 + (r1 - r0) * frac);
                written++;
                resamplePos_ += ratio;
                // 消费已越过的输入采样点
                int32_t consumed = static_cast<int32_t>(resamplePos_);
                if (consumed > 0) {
                    for (int32_t i = 0; i < consumed && !resampleLeft_.empty(); i++) {
                        resampleLeft_.pop_front();
                        resampleRight_.pop_front();
                    }
                    resamplePos_ -= consumed;
                }
            }
            // 解码结束且缓冲耗尽：标记 finished
            if (decodingEnded_.load() && pcmQueue_.empty() && resampleLeft_.size() < 2) {
                *finished = true;
                queueCondition_.notify_all();
                return written * 4;
            }
            // 若本次未写满但仍有数据可继续，回到循环顶部继续填充
            if (resampleLeft_.size() < 2 && decodingEnded_.load()) {
                *finished = true;
                queueCondition_.notify_all();
                return written * 4;
            }
            queueCondition_.notify_all();
        }
        *finished = false;
        queueCondition_.notify_all();
        return written * 4;
    }

    void MeasureInputDensity(int32_t audioDataSize)
    {
        if (audioDataSize <= 0) {
            return;
        }
        const int64_t nowMs = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now().time_since_epoch()).count();
        const uint64_t frames = static_cast<uint64_t>(audioDataSize) / 4;
        if (inputWindowStartMs_ == 0) {
            inputWindowStartMs_ = nowMs;
            inputWindowFrames_ = 0;
        }
        inputWindowFrames_ += frames;
        const int64_t winMs = nowMs - inputWindowStartMs_;
        if (winMs < 500) {
            return;
        }
        const uint64_t fps = inputWindowFrames_ * 1000 / static_cast<uint64_t>(winMs);
        int32_t n = static_cast<int32_t>((fps + 24000) / 48000);
        if (n < 1) {
            n = 1;
        }
        if (n > 3) {
            n = 3;
        }
        if (n != inputDensityFactor_) {
            inputDensityFactor_ = n;
            OH_LOG_Print(LOG_APP, LOG_INFO, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                "input density factor -> %{public}d (pullFps=%{public}llu)", n,
                static_cast<unsigned long long>(fps));
        }
        inputWindowFrames_ = 0;
        inputWindowStartMs_ = nowMs;
    }

    static int32_t InputDataCallback(OH_AudioNode*, void* userData, void* audioData,
        int32_t audioDataSize, bool* finished)
    {
        if (userData == nullptr) {
            return 0;
        }
        NativeAudioPlayer* player = static_cast<NativeAudioPlayer*>(userData);
        int32_t readSize = player->ReadPcm(audioData, audioDataSize, finished);
        player->pipelineInputCalls_.fetch_add(1, std::memory_order_relaxed);
        player->pipelineInputBytes_.fetch_add(readSize > 0 ? static_cast<uint64_t>(readSize) : 0,
            std::memory_order_relaxed);
        if (!player->pipelineInputFirstLogged_.exchange(true)) {
            OH_LOG_Print(LOG_APP, LOG_INFO, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                "pipeline input first pull size=%{public}d", audioDataSize);
        }
        player->MeasureInput(audioData, readSize);
        player->ApplyHeadroom(audioData, readSize);
        player->MeasureInputDensity(audioDataSize);
        return readSize;
    }

    static OH_AudioData_Callback_Result RendererDataCallback(
        OH_AudioRenderer*, void* userData, void* audioData, int32_t audioDataSize)
    {
        if (userData == nullptr || audioData == nullptr || audioDataSize <= 0) {
            return AUDIO_DATA_CALLBACK_RESULT_INVALID;
        }
        NativeAudioPlayer* player = static_cast<NativeAudioPlayer*>(userData);
        bool usePipeline = player->IsPipelineActive();
        if (!player->RenderAudio(audioData, audioDataSize, usePipeline)) {
            std::memset(audioData, 0, static_cast<size_t>(audioDataSize));
            player->decoderFailed_ = true;
            player->paused_ = true;
            OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                "render frame failed; marked native playback failed");
            return AUDIO_DATA_CALLBACK_RESULT_VALID;
        }
        player->MeasureOutput(audioData, audioDataSize, player->activeEqEnabled_.load());
        return AUDIO_DATA_CALLBACK_RESULT_VALID;
    }

    bool RenderAudio(void* audioData, int32_t audioDataSize, bool usePipeline)
    {
        if (!usePipeline) {
            bool finished = false;
            int32_t readSize = ReadPcm(audioData, audioDataSize, &finished);
            if (readSize < audioDataSize) {
                std::memset(static_cast<uint8_t*>(audioData) + readSize, 0,
                    static_cast<size_t>(audioDataSize - readSize));
            }
            if (finished) {
                audioSuiteEofReached_ = true;
                MarkPlaybackCompleted();
            }
            return true;
        }
        bool finished = false;
        int32_t responseSize = 0;
        std::lock_guard<std::mutex> lock(effectMutex_);
        OH_AudioSuite_Result result = OH_AudioSuiteEngine_RenderFrame(
            pipeline_, audioData, audioDataSize, &responseSize, &finished);
        if (result != AUDIOSUITE_SUCCESS) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                "RenderFrame failed result=%d responseSize=%d finished=%d inputSize=%d",
                static_cast<int>(result), responseSize, finished ? 1 : 0, audioDataSize);
            return false;
        }
        if (responseSize < audioDataSize) {
            std::memset(static_cast<uint8_t*>(audioData) + responseSize, 0,
                static_cast<size_t>(audioDataSize - responseSize));
        }
        pipelineRenderCalls_++;
        pipelineRenderReqBytes_ += static_cast<uint64_t>(audioDataSize);
        pipelineRenderRespBytes_ += responseSize > 0 ? static_cast<uint64_t>(responseSize) : 0;
        if (!pipelineRenderFirstLogged_) {
            pipelineRenderFirstLogged_ = true;
            OH_LOG_Print(LOG_APP, LOG_INFO, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                "pipeline render first req=%{public}d resp=%{public}d finished=%{public}d",
                audioDataSize, responseSize, finished ? 1 : 0);
        }
        const int64_t nowMs = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now().time_since_epoch()).count();
        if (pipelineStatsBaseMs_ == 0) {
            pipelineStatsBaseMs_ = nowMs;
        }
        if (nowMs - pipelineLastLogMs_ >= 1000) {
            pipelineLastLogMs_ = nowMs;
            OH_LOG_Print(LOG_APP, LOG_INFO, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                "pipeline flow elapsedMs=%{public}lld renderCalls=%{public}llu "
                "reqBytes=%{public}llu respBytes=%{public}llu inputCalls=%{public}llu "
                "inputBytes=%{public}llu",
                static_cast<long long>(nowMs - pipelineStatsBaseMs_),
                static_cast<unsigned long long>(pipelineRenderCalls_),
                static_cast<unsigned long long>(pipelineRenderReqBytes_),
                static_cast<unsigned long long>(pipelineRenderRespBytes_),
                static_cast<unsigned long long>(pipelineInputCalls_.load(
                    std::memory_order_relaxed)),
                static_cast<unsigned long long>(pipelineInputBytes_.load(
                    std::memory_order_relaxed)));
        }
        if (finished) {
            audioSuiteEofReached_ = true;
            MarkPlaybackCompleted();
        }
        return true;
    }

    void MarkPlaybackCompleted()
    {
        if (stopRequested_.load() || decoderFailed_.load() || !decodingEnded_.load()) {
            return;
        }
        bool expected = false;
        if (completed_.compare_exchange_strong(expected, true)) {
            paused_ = true;
            currentPositionMs_ = durationMs_.load();
            OH_LOG_Print(LOG_APP, LOG_INFO, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                "native playback completed decoderEos=%{public}d suiteEof=%{public}d",
                decoderEosReached_.load() ? 1 : 0, audioSuiteEofReached_.load() ? 1 : 0);
        }
    }

    void MeasureInput(void* audioData, int32_t audioDataSize)
    {
        const int16_t* samples = static_cast<const int16_t*>(audioData);
        int32_t sampleCount = audioDataSize / static_cast<int32_t>(sizeof(int16_t));
        if (samples == nullptr || sampleCount <= 0) {
            return;
        }
        for (int32_t i = 0; i < sampleCount; i++) {
            inputPositiveFullScaleCount_ += samples[i] == std::numeric_limits<int16_t>::max() ? 1 : 0;
            inputNegativeFullScaleCount_ += samples[i] == std::numeric_limits<int16_t>::min() ? 1 : 0;
        }
        inputMeasurementSampleCount_ += static_cast<uint64_t>(sampleCount);
    }

    void ApplyHeadroom(void* audioData, int32_t audioDataSize)
    {
        double currentDb = headroomDb_.load();
        const double targetDb = targetHeadroomDb_.load();
        if (currentDb < targetDb) {
            currentDb = std::min(targetDb, currentDb + 0.25);
        } else if (currentDb > targetDb) {
            currentDb = std::max(targetDb, currentDb - 0.10);
        }
        headroomDb_ = currentDb;
        double attenuationDb = currentDb;
        if (attenuationDb <= 0.0) {
            return;
        }
        int16_t* samples = static_cast<int16_t*>(audioData);
        int32_t sampleCount = audioDataSize / static_cast<int32_t>(sizeof(int16_t));
        if (samples == nullptr || sampleCount <= 0) {
            return;
        }
        const double scale = std::pow(10.0, -attenuationDb / 20.0);
        for (int32_t i = 0; i < sampleCount; i++) {
            const double scaled = static_cast<double>(samples[i]) * scale;
            const long converted = std::lround(scaled);
            samples[i] = static_cast<int16_t>(std::clamp<long>(converted,
                std::numeric_limits<int16_t>::min(), std::numeric_limits<int16_t>::max()));
        }
    }

    void MeasureOutput(void* audioData, int32_t audioDataSize, bool equalizerEnabled)
    {
        const int16_t* samples = static_cast<const int16_t*>(audioData);
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
            outputPositiveFullScaleCount_ += value == std::numeric_limits<int16_t>::max() ? 1 : 0;
            outputNegativeFullScaleCount_ += value == std::numeric_limits<int16_t>::min() ? 1 : 0;
        }
        measurementSquareSum_ += squareSum;
        measurementSampleCount_ += static_cast<uint64_t>(sampleCount);
        measurementPeak_ = std::max(measurementPeak_, peak);
        if (measurementSampleCount_ >= 48000 * 2) {
            const uint64_t inputClipped = inputPositiveFullScaleCount_ + inputNegativeFullScaleCount_;
            const uint64_t outputClipped = outputPositiveFullScaleCount_ + outputNegativeFullScaleCount_;
            const uint64_t addedFullScale = outputClipped > inputClipped ? outputClipped - inputClipped : 0;
            const double addedClipRatio = measurementSampleCount_ == 0 ? 0.0 :
                static_cast<double>(addedFullScale) / static_cast<double>(measurementSampleCount_);
            const bool addedClipping = equalizerEnabled && addedClipRatio > 0.00001;
            consecutiveClippingWindows_ = addedClipping ? consecutiveClippingWindows_ + 1 : 0;
            cleanHeadroomWindows_ = addedClipping ? 0 : cleanHeadroomWindows_ + 1;
            double targetDb = targetHeadroomDb_.load();
            if (consecutiveClippingWindows_ >= 2 && maxPositiveGainDb_.load() > 0.0) {
                const double previous = targetDb;
                targetDb = std::min(12.0, targetDb + 0.5);
                targetHeadroomDb_ = targetDb;
                if (targetDb != previous) {
                    OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                        "equalizer clipping feedback addedRatio=%{public}.6f targetHeadroomDb=%{public}.1f",
                        addedClipRatio, targetDb);
                }
                consecutiveClippingWindows_ = 0;
            } else if (cleanHeadroomWindows_ >= 8) {
                const double floorDb = baseHeadroomDb_.load();
                targetHeadroomDb_ = std::max(floorDb, targetDb - 0.25);
                cleanHeadroomWindows_ = 0;
            }
            const double rms = std::sqrt(
                measurementSquareSum_ / static_cast<double>(measurementSampleCount_));
            const double inputClipRatio = inputMeasurementSampleCount_ == 0 ? 0.0 :
                static_cast<double>(inputClipped) * 100.0 / static_cast<double>(inputMeasurementSampleCount_);
            const double outputClipRatio = static_cast<double>(outputClipped) * 100.0 /
                static_cast<double>(measurementSampleCount_);
            OH_LOG_Print(LOG_APP, LOG_INFO, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                "audio level eq=%{public}d peak=%{public}d rms=%{public}.1f "
                "inputClip=%{public}llu(%{public}.4f%%) outputClip=%{public}llu(%{public}.4f%%) "
                "headroomDb=%{public}.1f",
                equalizerEnabled ? 1 : 0, measurementPeak_, rms,
                static_cast<unsigned long long>(inputClipped), inputClipRatio,
                static_cast<unsigned long long>(outputClipped), outputClipRatio, headroomDb_.load());
            measurementSquareSum_ = 0.0;
            measurementSampleCount_ = 0;
            measurementPeak_ = 0;
            inputMeasurementSampleCount_ = 0;
            inputPositiveFullScaleCount_ = 0;
            inputNegativeFullScaleCount_ = 0;
            outputPositiveFullScaleCount_ = 0;
            outputNegativeFullScaleCount_ = 0;
        }
    }

    enum class DecoderLifecycle : int32_t {
        STOPPED = 0,
        STARTED = 1,
        SEEKING = 2,
        FAILED = 3,
        STOPPING = 4,
    };

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
    OH_AudioNode* soundFieldNode_ = nullptr;
    OH_AudioNode* environmentNode_ = nullptr;
    OH_AudioNode* beautifierNode_ = nullptr;
    OH_AudioNode* spaceRenderNode_ = nullptr;
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
    std::atomic<uint64_t> seekRequestSequence_ = 0;
    std::atomic<bool> decoderFailureLogged_ = false;
    std::atomic<DecoderLifecycle> decoderLifecycle_ = DecoderLifecycle::STOPPED;
    std::atomic<bool> paused_ = false;
    std::atomic<bool> completed_ = false;
    std::atomic<bool> decoderEosReached_ = false;
    std::atomic<bool> audioSuiteEofReached_ = false;
    std::atomic<bool> decodingEnded_ = false;
    std::atomic<bool> decoderFailed_ = false;
    std::atomic<bool> firstPcmReady_ = false;
    std::atomic<int64_t> seekPositionMs_ = 0;
    std::atomic<int64_t> currentPositionMs_ = 0;
    std::atomic<int64_t> durationMs_ = 0;
    std::atomic<bool> requestedEqEnabled_ = false;
    std::atomic<bool> activeEqEnabled_ = false;
    std::atomic<bool> requestedSoundFieldEnabled_ = false;
    std::atomic<bool> requestedEnvironmentEnabled_ = false;
    std::atomic<bool> requestedBeautifierEnabled_ = false;
    std::atomic<bool> requestedSpaceRenderEnabled_ = false;
    std::atomic<int32_t> soundFieldType_ = 1;
    std::atomic<int32_t> environmentType_ = 1;
    std::atomic<int32_t> beautifierType_ = 1;
    std::atomic<int32_t> spaceRenderMode_ = 0;
    float playbackSpeed_ = 1.0f;
    float volume_ = 1.0f;
    double measurementSquareSum_ = 0.0;
    uint64_t measurementSampleCount_ = 0;
    uint64_t inputMeasurementSampleCount_ = 0;
    uint64_t inputPositiveFullScaleCount_ = 0;
    uint64_t inputNegativeFullScaleCount_ = 0;
    uint64_t outputPositiveFullScaleCount_ = 0;
    uint64_t outputNegativeFullScaleCount_ = 0;
    int32_t measurementPeak_ = 0;
    int32_t consecutiveClippingWindows_ = 0;
    int32_t cleanHeadroomWindows_ = 0;
    // 管线数据流诊断：对比管线输入拉取量与 RenderFrame 输出量是否守恒（采样率错配定位）
    std::atomic<uint64_t> pipelineInputCalls_ = 0;
    std::atomic<uint64_t> pipelineInputBytes_ = 0;
    std::atomic<bool> pipelineInputFirstLogged_ = false;
    uint64_t pipelineRenderCalls_ = 0;
    uint64_t pipelineRenderReqBytes_ = 0;
    uint64_t pipelineRenderRespBytes_ = 0;
    bool pipelineRenderFirstLogged_ = false;
    int64_t pipelineStatsBaseMs_ = 0;
    int64_t pipelineLastLogMs_ = 0;
    std::atomic<double> maxPositiveGainDb_ = 0.0;
    std::atomic<double> baseHeadroomDb_ = 0.0;
    std::atomic<double> targetHeadroomDb_ = 0.0;
    std::atomic<double> headroomDb_ = 0.0;
    std::array<int32_t, EQUALIZER_BAND_NUM> bands_ = {};
    // 空间渲染参数（effectMutex_ 保护）：摆位/旋转共用 x/y/z，旋转另有环绕时间/方向，扩展另有半径/角度
    float spaceX_ = 0.0f;
    float spaceY_ = 0.0f;
    float spaceZ_ = 0.0f;
    int32_t spaceSurroundTime_ = 10;
    int32_t spaceSurroundDirection_ = 1;
    float spaceExtRadius_ = 2.0f;
    int32_t spaceExtAngle_ = 180;
    std::mutex effectMutex_;
    // 重采样状态：解码器输出源采样率 PCM，均衡器管线固定 48000
    double resamplePos_ = 0.0;
    int32_t resampleInputRate_ = 44100;
    int32_t resampleOutputRate_ = 48000;
    // 密度自适应：OHAudioSuite 管线对输入按 N 倍速率拉取（N 实时测量为 1 或 2）。
    // 拉取 N 倍时把源重采样到 48000×N，使源按实时速率推进，消除 2× 拉取导致的倍速/变调。
    int32_t inputDensityFactor_ = 1;
    uint64_t inputWindowFrames_ = 0;
    int64_t inputWindowStartMs_ = 0;
    std::deque<int16_t> resampleLeft_ = {};
    std::deque<int16_t> resampleRight_ = {};
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

napi_value SetSoundFieldEnable(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    bool enabled = false;
    if (argc != 1 || napi_get_value_bool(env, args[0], &enabled) != napi_ok) {
        return BooleanValue(env, false);
    }
    return BooleanValue(env, NativeAudioPlayer::Instance().SetSoundFieldEnabled(enabled));
}

napi_value SetSoundFieldType(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t type = 0;
    if (argc != 1 || napi_get_value_int32(env, args[0], &type) != napi_ok) {
        return BooleanValue(env, false);
    }
    return BooleanValue(env, NativeAudioPlayer::Instance().SetSoundFieldType(type));
}

napi_value SetEnvironmentEnable(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    bool enabled = false;
    if (argc != 1 || napi_get_value_bool(env, args[0], &enabled) != napi_ok) {
        return BooleanValue(env, false);
    }
    return BooleanValue(env, NativeAudioPlayer::Instance().SetEnvironmentEnabled(enabled));
}

napi_value SetEnvironmentType(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t type = 0;
    if (argc != 1 || napi_get_value_int32(env, args[0], &type) != napi_ok) {
        return BooleanValue(env, false);
    }
    return BooleanValue(env, NativeAudioPlayer::Instance().SetEnvironmentType(type));
}

napi_value SetVoiceBeautifierEnable(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    bool enabled = false;
    if (argc != 1 || napi_get_value_bool(env, args[0], &enabled) != napi_ok) {
        return BooleanValue(env, false);
    }
    return BooleanValue(env, NativeAudioPlayer::Instance().SetVoiceBeautifierEnabled(enabled));
}

napi_value SetVoiceBeautifierType(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t type = 0;
    if (argc != 1 || napi_get_value_int32(env, args[0], &type) != napi_ok) {
        return BooleanValue(env, false);
    }
    return BooleanValue(env, NativeAudioPlayer::Instance().SetVoiceBeautifierType(type));
}

napi_value SetSpaceRenderEnable(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    bool enabled = false;
    if (argc != 1 || napi_get_value_bool(env, args[0], &enabled) != napi_ok) {
        return BooleanValue(env, false);
    }
    return BooleanValue(env, NativeAudioPlayer::Instance().SetSpaceRenderEnabled(enabled));
}

napi_value SetSpaceRenderConfig(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = { nullptr, nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t mode = -1;
    bool isArray = false;
    if (argc != 2 || napi_get_value_int32(env, args[0], &mode) != napi_ok ||
        napi_is_array(env, args[1], &isArray) != napi_ok || !isArray) {
        return BooleanValue(env, false);
    }
    uint32_t length = 0;
    napi_get_array_length(env, args[1], &length);
    std::vector<float> values(length);
    for (uint32_t i = 0; i < length; i++) {
        napi_value item = nullptr;
        double value = 0;
        if (napi_get_element(env, args[1], i, &item) != napi_ok ||
            napi_get_value_double(env, item, &value) != napi_ok) {
            return BooleanValue(env, false);
        }
        values[i] = static_cast<float>(value);
    }
    return BooleanValue(env, NativeAudioPlayer::Instance().SetSpaceRenderConfig(mode, values));
}

napi_value IsEffectNodeSupported(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t nodeType = 0;
    if (argc != 1 || napi_get_value_int32(env, args[0], &nodeType) != napi_ok) {
        return BooleanValue(env, false);
    }
    return BooleanValue(env, NativeAudioPlayer::Instance().IsEffectNodeSupported(nodeType));
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
        { "setEqualizerBands", nullptr, SetBands, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "getEqualizerBands", nullptr, GetBands, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "setSoundFieldEnable", nullptr, SetSoundFieldEnable, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "setSoundFieldType", nullptr, SetSoundFieldType, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "setEnvironmentEnable", nullptr, SetEnvironmentEnable, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "setEnvironmentType", nullptr, SetEnvironmentType, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "setVoiceBeautifierEnable", nullptr, SetVoiceBeautifierEnable, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "setVoiceBeautifierType", nullptr, SetVoiceBeautifierType, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "setSpaceRenderEnable", nullptr, SetSpaceRenderEnable, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "setSpaceRenderConfig", nullptr, SetSpaceRenderConfig, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "isEffectNodeSupported", nullptr, IsEffectNodeSupported, nullptr, nullptr, nullptr, napi_default, nullptr },
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

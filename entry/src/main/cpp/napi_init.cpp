#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <list>
#include <limits>
#include <map>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>
#include <unistd.h>
#include <sys/stat.h>
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
#include "ohaudiosuite/native_audio_converter.h"
#include "ohaudiosuite/native_audio_suite_base.h"
#include "ohaudiosuite/native_audio_suite_engine.h"

namespace {
constexpr unsigned int UPLAYER_LOG_DOMAIN = 0x0000;
constexpr const char* UPLAYER_LOG_TAG = "UPlayerNative";
constexpr double EQUALIZER_MIN_GAIN_DB = -10.0;
constexpr double EQUALIZER_MAX_GAIN_DB = 10.0;

// 闭环响度补偿参数。AudioSuite 效果链会改变电平，而华为该套 API 未提供任何增益/音量接口
// （头文件仅有均衡器 gains[10]），只能在应用侧按「输入 RMS : 输出 RMS」反推补偿增益。
constexpr int64_t LOUDNESS_WINDOW_MS = 300;          // 测量窗口时长
constexpr double LOUDNESS_MIN_REFERENCE_RMS = 200.0; // 源过轻不补偿（≈ -44dBFS，避免抬噪底）
constexpr double LOUDNESS_MIN_GAIN = 0.25;           // 补偿下限 -12dB
constexpr double LOUDNESS_MAX_GAIN = 4.0;            // 补偿上限 +12dB
constexpr double LOUDNESS_WINDOW_SMOOTHING = 0.6;    // 窗口间的目标增益平滑系数
constexpr double LOUDNESS_GAIN_SMOOTHING = 0.0002;   // 逐采样增益平滑（时间常数 ≈100ms@48k）
constexpr double LOUDNESS_SOFT_KNEE_START = 24000.0; // 软限幅起控点（≈-2.7dBFS，以下完全透明）

// 管线直通保持：效果开关/管线激活瞬间，管线拉取模式突变，旧密度因子未收敛前按旧速率喂源
// 会产生倍速高音调/慢速低音调。保持期内可听输出走直通（音调恒定正确），管线喂静音完成密度
// 重测，收敛后与直通末段交叉淡化切回管线输出。
constexpr int64_t PIPELINE_HOLD_MS = 300;                // 保持时长（≥2 个密度窗口，保证滞回收敛）
constexpr int32_t PIPELINE_HOLD_CARRY_SAMPLES = 960;     // 释放交叉淡化长度（10ms@48k 立体声采样）
constexpr int32_t PIPELINE_HOLD_SCRATCH_SAMPLES = 96000; // 预热渲染暂存（0.5s 立体声，避免 RT 分配）
constexpr int32_t DENSITY_WINDOW_MS = 120;               // 拉取密度测量窗口（从 500ms 收窄以快速收敛）
constexpr double DENSITY_SWITCH_BAND = 0.15;             // 密度因子滞回带宽（±15% 内不切换）
constexpr int32_t DENSITY_PLAYBACK_CONFIRM_WINDOWS = 3;  // 播放中漂移确认窗口数（保守，防误触发）
constexpr int32_t DENSITY_HOLD_CONFIRM_WINDOWS = 2;      // 保持期内确认窗口数（300ms 内完成收敛）
constexpr int64_t DENSITY_HOLD_COOLDOWN_MS = 2000;       // 播放中自动保护切换冷却（防频繁直通闪断）
// 管线短响应补块：声场/环境音/美声/空间渲染经系统效果服务异步 IPC 分块交付，RenderFrame
// 请求整帧时服务块偶发未就绪 → responseSize 短于请求 → 帧内数据空洞即随机「沙沙」声
// （均衡器为内联同步 DSP 永不短响应，与「除均衡器外开任何音效都有沙声」现象吻合）。
// 短响应时在回调预算内重试拉取剩余字节，用真实数据补满帧，而非补零遮蔽。
constexpr int32_t PIPELINE_SHORTFALL_RETRY_MAX = 4;      // 短响应重试上限（单帧总调用 ≤5 次）
constexpr int32_t PIPELINE_SHORTFALL_RETRY_WAIT_MS = 1;  // 零产出时的微等待，给效果服务补块时间

// 渲染工作线程 + 环形缓冲解耦：官方文档明示 RenderFrame 处理时长与链上效果节点数相关（本
// 项目 7 节点），直接在 RT 回调内执行时效果服务 IPC 抖动会超出低时延回调预算（≈13ms），
// 造成随机欠载卡顿。渲染全部迁到专用工作线程，RT 回调退化为纯环形缓冲 memcpy 读取，
// IPC/参数调节抖动由环形缓冲吸收。
constexpr int32_t RING_CAPACITY_MS = 400;               // 环形缓冲容量（吸收 IPC/滑条调节抖动）
constexpr int32_t RING_CHUNK_MS = 10;                   // 工作线程单次渲染块时长
constexpr int32_t RING_PREFILL_MS = 40;                 // 启动 renderer 前的预填充时长
constexpr int32_t RING_PREFILL_TIMEOUT_MS = 200;        // 预填充等待超时（解码器出数据即可填满）
constexpr int64_t RING_UNDERRUN_LOG_INTERVAL_MS = 1000; // 欠载日志限速
constexpr int64_t RENDER_CHUNK_WARN_MS = 30;            // 单块渲染耗时告警阈值（工作线程）
constexpr int32_t RING_SAMPLES_PER_MS = 96;             // 48kHz 立体声 int16 每毫秒采样数

// 官方 OH_AudioConverter 单次输入回调允许返回的最大字节数（官方上限 400KB，留出余量）。
constexpr size_t CONVERTER_INPUT_MAX_BYTES = 256 * 1024;
// 官方 OH_AudioConverter 支持的采样率白名单（native_audio_converter.h 明确列举）。
constexpr int32_t CONVERTER_SUPPORTED_RATES[] = {
    8000, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000, 64000, 88200, 96000, 176400, 192000
};

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

// 音效管线分组。官方约束（native_audio_suite_base-h，API 23+ 实时预览支持所有效果节点）：
// - 均衡器/声场/美化/环境/空间渲染/通用变声输出均为 48000Hz/S16LE/2ch，可直接串联；
// - 降噪/传统变声输出 16000Hz/S16LE/1ch、变速变调输出 48000Hz/S16LE/1ch，与立体声链路
//   格式不一致，单独放「特殊管线」按需启动，启动失败可回退主管线，不破坏播放；
// - 音源分离为多输出节点（人声/伴奏两路，F32LE），且只能连接输出节点，单独放「分离管线」，
//   渲染走 MultiRenderFrame；该节点依赖 NPU，创建前必须 IsNodeTypeSupported 探测。
enum class ActivePipeline { NONE, MAIN, SPECIAL, SEP };

struct EffectNodeSet {
    OH_AudioNode* eq = nullptr;
    OH_AudioNode* soundField = nullptr;
    OH_AudioNode* environment = nullptr;
    OH_AudioNode* beautifier = nullptr;
    OH_AudioNode* spaceRender = nullptr;
    OH_AudioNode* generalVoiceChange = nullptr;
    OH_AudioNode* noiseReduction = nullptr;
    OH_AudioNode* pureVoiceChange = nullptr;
    OH_AudioNode* tempoPitch = nullptr;
};

struct PipelineGroup {
    OH_AudioSuitePipeline* pipeline = nullptr;
    OH_AudioNode* input = nullptr;
    OH_AudioNode* output = nullptr;
    EffectNodeSet effects;
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
        pipelineShortfallPrev_ = false;
        pipelineHoldActive_.store(false);
        pipelineHoldRequested_.store(false);
        holdCarrySamples_ = 0;
        densityPendingCandidate_ = 0;
        densityPendingCount_ = 0;
        densityRetarget_ = 0;
        densityHoldLastMs_ = 0;
        // 每次 Play 强制经历一次「激活翻转 → 直通保持」，首帧不直接用旧因子喂管线
        lastUsePipeline_ = false;
        if (holdScratch_.size() < static_cast<size_t>(PIPELINE_HOLD_SCRATCH_SAMPLES)) {
            holdScratch_.assign(static_cast<size_t>(PIPELINE_HOLD_SCRATCH_SAMPLES), 0);
        }
        if (holdCarry_.size() < static_cast<size_t>(PIPELINE_HOLD_CARRY_SAMPLES)) {
            holdCarry_.assign(static_cast<size_t>(PIPELINE_HOLD_CARRY_SAMPLES), 0);
        }
        pipelineStatsBaseMs_ = 0;
        pipelineLastLogMs_ = 0;
        {
            std::lock_guard<std::mutex> lock(effectMutex_);
            activeEqEnabled_ = requestedEqEnabled_.load();
        }
        ResetLoudnessCompensation();
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
        inputDensityFactor_.store(1);
        converterInputFinished_.store(false);
        inputWindowFrames_ = 0;
        inputWindowStartMs_ = 0;
        OH_LOG_Print(LOG_APP, LOG_INFO, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
            "native track sampleRate=%{public}d channels=%{public}d resampleTo=%{public}d",
            sampleRate_, channelCount_, resampleOutputRate_);
        decoderThread_ = std::thread(&NativeAudioPlayer::DecoderLoop, this);
        // 渲染架构：RenderFrame（含效果服务 IPC）、转换器、hold、响度补偿全部在工作线程执行；
        // RT 回调只做环形缓冲 memcpy。启动 renderer 前先预填充，消除起播欠载。
        RingReset();
        renderStopRequested_.store(false);
        ringUnderrunCount_.store(0);
        ringUnderrunLastLogMs_ = 0;
        ringUnderrunLastSample_ = 0;
        renderChunkSlowCount_ = 0;
        if (ringBuffer_.size() != static_cast<size_t>(RING_CAPACITY_MS) * RING_SAMPLES_PER_MS) {
            ringBuffer_.assign(static_cast<size_t>(RING_CAPACITY_MS) * RING_SAMPLES_PER_MS, 0);
        }
        if (renderChunkBuf_.size() != static_cast<size_t>(RING_CHUNK_MS) * RING_SAMPLES_PER_MS) {
            renderChunkBuf_.assign(static_cast<size_t>(RING_CHUNK_MS) * RING_SAMPLES_PER_MS, 0);
        }
        renderThread_ = std::thread(&NativeAudioPlayer::RenderLoop, this);
        {
            const size_t prefillSamples = static_cast<size_t>(RING_PREFILL_MS) * RING_SAMPLES_PER_MS;
            const auto prefillDeadline = std::chrono::steady_clock::now() +
                std::chrono::milliseconds(RING_PREFILL_TIMEOUT_MS);
            bool prefillReached = false;
            while (std::chrono::steady_clock::now() < prefillDeadline) {
                if (decoderFailed_.load() || renderStopRequested_.load()) {
                    break;
                }
                {
                    std::lock_guard<std::mutex> lock(ringMutex_);
                    prefillReached = ringFilled_ >= prefillSamples;
                }
                if (prefillReached) {
                    break;
                }
                std::this_thread::sleep_for(std::chrono::milliseconds(2));
            }
            OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                "native startup stage=render-thread elapsedMs=%{public}lld prefillReached=%{public}d",
                elapsedMs(), prefillReached ? 1 : 0);
        }
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
        // 冲刷环形缓冲：丢弃 seek 前已渲染的残留音频（最多 400ms），seek 后新音频即时起播
        RingReset();
        queueCondition_.notify_all();
        ringCondition_.notify_all();
        return true;
    }

    void RequestStop()
    {
        decoderLifecycle_ = DecoderLifecycle::STOPPING;
        stopRequested_ = true;
        seekRequested_ = false;
        // 必须持 ringMutex_ 置位：避免工作线程「谓词判定→阻塞」窗口内错过唤醒导致短暂挂起
        {
            std::lock_guard<std::mutex> lock(ringMutex_);
            renderStopRequested_ = true;
        }
        queueCondition_.notify_all();
        ringCondition_.notify_all();
    }

    void Stop()
    {
        RequestStop();
        {
            std::lock_guard<std::mutex> lock(queueMutex_);
            pcmQueue_.clear();
        }
        converterInputFinished_.store(true);
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
        // 渲染工作线程必须在销毁管线/节点前 join：它可能正在 RenderFrame（持 effectMutex_）
        if (renderThread_.joinable()) {
            const auto joinStart = std::chrono::steady_clock::now();
            renderThread_.join();
            const auto joinMs = std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::steady_clock::now() - joinStart).count();
            OH_LOG_Print(LOG_APP, LOG_INFO, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                "render thread joined elapsedMs=%{public}lld underruns=%{public}llu slowChunks=%{public}llu",
                static_cast<long long>(joinMs),
                static_cast<unsigned long long>(ringUnderrunCount_.load()),
                static_cast<unsigned long long>(renderChunkSlowCount_));
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
        DestroyPipelineGroups();
        DestroyConverter();
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
        ResetLoudnessCompensation();
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
        // 开关瞬间管线拉取模式可能变化：请求直通保持，密度因子重测收敛后再切入管线输出
        pipelineHoldRequested_.store(true);
        // 管线可能被其他效果占用，EQ 节点旁路状态必须与开关同步，避免关闭 EQ 后残留处理
        OH_AudioNode* node = ActiveEffectNodes().eq;
        if (node == nullptr) {
            return true;
        }
        if (enabled) {
            return ApplyBandsLocked(node, bands_, false);
        }
        return BypassNodeLocked(node, true);
    }

    bool SetBands(const std::array<int32_t, EQUALIZER_BAND_NUM>& bands)
    {
        std::lock_guard<std::mutex> lock(effectMutex_);
        bands_ = bands;
        OH_AudioNode* node = ActiveEffectNodes().eq;
        if (!requestedEqEnabled_ || node == nullptr) {
            return true;
        }
        return ApplyBandsLocked(node, bands_, false);
    }

    std::array<int32_t, EQUALIZER_BAND_NUM> GetBands()
    {
        std::lock_guard<std::mutex> lock(effectMutex_);
        return bands_;
    }

    // 任一效果启用即需要走管线渲染：EQ 用 Play 时的 active 快照，
    // 其余效果节点建管时全建 + Bypass 即时切换，直接用 requested 原子量
    bool IsPipelineActive() const
    {
        return activeEqEnabled_.load() || requestedSoundFieldEnabled_.load() ||
            requestedEnvironmentEnabled_.load() || requestedBeautifierEnabled_.load() ||
            requestedSpaceRenderEnabled_.load() || requestedGeneralVoiceChangeEnabled_.load() ||
            requestedNoiseReductionEnabled_.load() || requestedPureVoiceChangeEnabled_.load() ||
            requestedTempoPitchEnabled_.load() || requestedSeparationEnabled_.load();
    }

    bool SetSoundFieldEnabled(bool enabled)
    {
        std::lock_guard<std::mutex> lock(effectMutex_);
        requestedSoundFieldEnabled_ = enabled;
        OH_LOG_Print(LOG_APP, LOG_INFO, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
            "effect toggle soundField=%{public}d", enabled ? 1 : 0);
        pipelineHoldRequested_.store(true);
        OH_AudioNode* node = ActiveEffectNodes().soundField;
        if (node == nullptr) {
            return true;
        }
        if (enabled) {
            return SetSoundFieldStateLocked(node);
        }
        return BypassNodeLocked(node, true);
    }

    bool SetSoundFieldType(int32_t type)
    {
        if (type < 1 || type > 4) {
            return false;
        }
        soundFieldType_ = type;
        std::lock_guard<std::mutex> lock(effectMutex_);
        OH_AudioNode* node = ActiveEffectNodes().soundField;
        if (node == nullptr || !requestedSoundFieldEnabled_.load()) {
            return true;
        }
        OH_AudioSuite_Result result = OH_AudioSuiteEngine_SetSoundFieldType(
            node, static_cast<OH_SoundFieldType>(type));
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
        pipelineHoldRequested_.store(true);
        OH_AudioNode* node = ActiveEffectNodes().environment;
        if (node == nullptr) {
            return true;
        }
        if (enabled) {
            return SetEnvironmentStateLocked(node);
        }
        return BypassNodeLocked(node, true);
    }

    bool SetEnvironmentType(int32_t type)
    {
        if (type < 1 || type > 4) {
            return false;
        }
        environmentType_ = type;
        std::lock_guard<std::mutex> lock(effectMutex_);
        OH_AudioNode* node = ActiveEffectNodes().environment;
        if (node == nullptr || !requestedEnvironmentEnabled_.load()) {
            return true;
        }
        OH_AudioSuite_Result result = OH_AudioSuiteEngine_SetEnvironmentType(
            node, static_cast<OH_EnvironmentType>(type));
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
        pipelineHoldRequested_.store(true);
        OH_AudioNode* node = ActiveEffectNodes().beautifier;
        if (node == nullptr) {
            return true;
        }
        if (enabled) {
            return SetBeautifierStateLocked(node);
        }
        return BypassNodeLocked(node, true);
    }

    bool SetVoiceBeautifierType(int32_t type)
    {
        if (type < 1 || type > 4) {
            return false;
        }
        beautifierType_ = type;
        std::lock_guard<std::mutex> lock(effectMutex_);
        OH_AudioNode* node = ActiveEffectNodes().beautifier;
        if (node == nullptr || !requestedBeautifierEnabled_.load()) {
            return true;
        }
        OH_AudioSuite_Result result = OH_AudioSuiteEngine_SetVoiceBeautifierType(
            node, static_cast<OH_VoiceBeautifierType>(type));
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
        pipelineHoldRequested_.store(true);
        OH_AudioNode* node = ActiveEffectNodes().spaceRender;
        if (node == nullptr) {
            return true;
        }
        if (enabled) {
            return SetSpaceRenderStateLocked(node);
        }
        return BypassNodeLocked(node, true);
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
        OH_AudioNode* node = ActiveEffectNodes().spaceRender;
        if (node == nullptr || !requestedSpaceRenderEnabled_.load()) {
            return true;
        }
        return ApplySpaceRenderParamsLocked(node);
    }

    // ═══ 通用变声（210，主链内，48k/S16/2ch）═══
    bool SetGeneralVoiceChangeEnabled(bool enabled)
    {
        std::lock_guard<std::mutex> lock(effectMutex_);
        requestedGeneralVoiceChangeEnabled_ = enabled;
        OH_LOG_Print(LOG_APP, LOG_INFO, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
            "effect toggle generalVoiceChange=%{public}d", enabled ? 1 : 0);
        pipelineHoldRequested_.store(true);
        OH_AudioNode* node = ActiveEffectNodes().generalVoiceChange;
        if (node == nullptr) {
            return true;
        }
        if (enabled) {
            return SetGeneralVoiceChangeStateLocked(node);
        }
        return BypassNodeLocked(node, true);
    }

    bool SetGeneralVoiceChangeType(int32_t type)
    {
        if (type < 1 || type > 10) {
            return false;
        }
        generalVoiceChangeType_ = type;
        std::lock_guard<std::mutex> lock(effectMutex_);
        OH_AudioNode* node = ActiveEffectNodes().generalVoiceChange;
        if (node == nullptr || !requestedGeneralVoiceChangeEnabled_.load()) {
            return true;
        }
        OH_AudioSuite_Result result = OH_AudioSuiteEngine_SetGeneralVoiceChangeType(
            node, static_cast<OH_AudioSuite_GeneralVoiceChangeType>(type));
        if (result != AUDIOSUITE_SUCCESS) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                "set general voice change type failed code=%{public}d type=%{public}d",
                static_cast<int>(result), type);
            return false;
        }
        return true;
    }

    // ═══ 降噪（202，特殊管线，16k/S16/1ch 输出）═══
    bool SetNoiseReductionEnabled(bool enabled)
    {
        std::lock_guard<std::mutex> lock(effectMutex_);
        requestedNoiseReductionEnabled_ = enabled;
        OH_LOG_Print(LOG_APP, LOG_INFO, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
            "effect toggle noiseReduction=%{public}d", enabled ? 1 : 0);
        if (!SwitchPipelineLocked()) {
            return false;
        }
        OH_AudioNode* node = ActiveEffectNodes().noiseReduction;
        if (node == nullptr) {
            return true;
        }
        // 降噪无参数，仅旁路开关
        return BypassNodeLocked(node, !enabled);
    }

    // ═══ 传统变声（209，特殊管线，16k/S16/1ch 输出）═══
    bool SetPureVoiceChangeEnabled(bool enabled)
    {
        std::lock_guard<std::mutex> lock(effectMutex_);
        requestedPureVoiceChangeEnabled_ = enabled;
        OH_LOG_Print(LOG_APP, LOG_INFO, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
            "effect toggle pureVoiceChange=%{public}d", enabled ? 1 : 0);
        if (!SwitchPipelineLocked()) {
            return false;
        }
        OH_AudioNode* node = ActiveEffectNodes().pureVoiceChange;
        if (node == nullptr) {
            return true;
        }
        if (enabled) {
            return SetPureVoiceChangeStateLocked(node);
        }
        return BypassNodeLocked(node, true);
    }

    // gender: 1=女声 2=男声；type: 1..7；pitch: 0=系统推荐，自定义 [0.3, 3.0]
    bool SetPureVoiceChangeConfig(int32_t gender, int32_t type, float pitch)
    {
        if (gender < 1 || gender > 2 || type < 1 || type > 7) {
            return false;
        }
        const float clampedPitch = pitch <= 0.0f ? 0.0f : std::clamp(pitch, 0.3f, 3.0f);
        pureVoiceChangeGender_ = gender;
        pureVoiceChangeType_ = type;
        pureVoiceChangePitch_ = clampedPitch;
        std::lock_guard<std::mutex> lock(effectMutex_);
        OH_AudioNode* node = ActiveEffectNodes().pureVoiceChange;
        if (node == nullptr || !requestedPureVoiceChangeEnabled_.load()) {
            return true;
        }
        return SetPureVoiceChangeStateLocked(node);
    }

    // ═══ 变速变调（211，特殊管线，48k/S16/1ch 输出）═══
    bool SetTempoPitchEnabled(bool enabled)
    {
        std::lock_guard<std::mutex> lock(effectMutex_);
        requestedTempoPitchEnabled_ = enabled;
        OH_LOG_Print(LOG_APP, LOG_INFO, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
            "effect toggle tempoPitch=%{public}d", enabled ? 1 : 0);
        if (!SwitchPipelineLocked()) {
            return false;
        }
        OH_AudioNode* node = ActiveEffectNodes().tempoPitch;
        if (node == nullptr) {
            return true;
        }
        if (enabled) {
            return SetTempoPitchStateLocked(node);
        }
        return BypassNodeLocked(node, true);
    }

    // speed: [0.5, 10.0]；pitch: [0.1, 5.0]
    bool SetTempoPitchConfig(float speed, float pitch)
    {
        const float clampedSpeed = std::clamp(speed, 0.5f, 10.0f);
        const float clampedPitch = std::clamp(pitch, 0.1f, 5.0f);
        tempoSpeed_ = clampedSpeed;
        tempoPitch_ = clampedPitch;
        std::lock_guard<std::mutex> lock(effectMutex_);
        OH_AudioNode* node = ActiveEffectNodes().tempoPitch;
        if (node == nullptr || !requestedTempoPitchEnabled_.load()) {
            return true;
        }
        return SetTempoPitchStateLocked(node);
    }

    // ═══ 音源分离（204，分离管线，多输出人声/伴奏）═══
    bool SetSeparationEnabled(bool enabled)
    {
        std::lock_guard<std::mutex> lock(effectMutex_);
        requestedSeparationEnabled_ = enabled;
        OH_LOG_Print(LOG_APP, LOG_INFO, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
            "effect toggle separation=%{public}d usable=%{public}d",
            enabled ? 1 : 0, sepPipelineUsable_ ? 1 : 0);
        if (!SwitchPipelineLocked()) {
            return false;
        }
        return true;
    }

    // output: 1=仅人声 2=仅伴奏 3=人声+伴奏混合
    bool SetSeparationOutput(int32_t output)
    {
        if (output < 1 || output > 3) {
            return false;
        }
        std::lock_guard<std::mutex> lock(effectMutex_);
        separationOutput_ = output;
        OH_LOG_Print(LOG_APP, LOG_INFO, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
            "separation output=%{public}d", output);
        return true;
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
        playbackSpeed_.store(speed, std::memory_order_relaxed);
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
    bool ApplyBandsLocked(OH_AudioNode* eqNode, const std::array<int32_t, EQUALIZER_BAND_NUM>& bands, bool verify)
    {
        if (eqNode == nullptr) {
            return false;
        }
        OH_AudioSuite_Result bypassResult = OH_AudioSuiteEngine_BypassEffectNode(eqNode, false);
        if (bypassResult != AUDIOSUITE_SUCCESS) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                "enable equalizer processing failed code=%{public}d", bypassResult);
            return false;
        }
        bool bypassed = true;
        OH_AudioSuite_Result bypassStateResult = OH_AudioSuiteEngine_GetNodeBypassStatus(eqNode, &bypassed);
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
        OH_AudioSuite_Result setResult = OH_AudioSuiteEngine_SetEqualizerFrequencyBandGains(eqNode, gains);
        if (setResult != AUDIOSUITE_SUCCESS) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                "set equalizer bands failed code=%{public}d", setResult);
            return false;
        }
        if (!verify) {
            return true;
        }
        OH_EqualizerFrequencyBandGains current = {};
        OH_AudioSuite_Result getResult = OH_AudioSuiteEngine_GetEqualizerFrequencyBandGains(eqNode, &current);
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

    bool SetSoundFieldStateLocked(OH_AudioNode* node)
    {
        if (node == nullptr) {
            return true;
        }
        if (!BypassNodeLocked(node, false)) {
            return false;
        }
        OH_AudioSuite_Result result = OH_AudioSuiteEngine_SetSoundFieldType(
            node, static_cast<OH_SoundFieldType>(soundFieldType_.load()));
        if (result != AUDIOSUITE_SUCCESS) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                "set sound field type failed code=%{public}d type=%{public}d",
                static_cast<int>(result), soundFieldType_.load());
            return false;
        }
        return true;
    }

    bool SetEnvironmentStateLocked(OH_AudioNode* node)
    {
        if (node == nullptr) {
            return true;
        }
        if (!BypassNodeLocked(node, false)) {
            return false;
        }
        OH_AudioSuite_Result result = OH_AudioSuiteEngine_SetEnvironmentType(
            node, static_cast<OH_EnvironmentType>(environmentType_.load()));
        if (result != AUDIOSUITE_SUCCESS) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                "set environment type failed code=%{public}d type=%{public}d",
                static_cast<int>(result), environmentType_.load());
            return false;
        }
        return true;
    }

    bool SetBeautifierStateLocked(OH_AudioNode* node)
    {
        if (node == nullptr) {
            return true;
        }
        if (!BypassNodeLocked(node, false)) {
            return false;
        }
        OH_AudioSuite_Result result = OH_AudioSuiteEngine_SetVoiceBeautifierType(
            node, static_cast<OH_VoiceBeautifierType>(beautifierType_.load()));
        if (result != AUDIOSUITE_SUCCESS) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                "set voice beautifier type failed code=%{public}d type=%{public}d",
                static_cast<int>(result), beautifierType_.load());
            return false;
        }
        return true;
    }

    bool SetGeneralVoiceChangeStateLocked(OH_AudioNode* node)
    {
        if (node == nullptr) {
            return true;
        }
        if (!BypassNodeLocked(node, false)) {
            return false;
        }
        OH_AudioSuite_Result result = OH_AudioSuiteEngine_SetGeneralVoiceChangeType(
            node, static_cast<OH_AudioSuite_GeneralVoiceChangeType>(generalVoiceChangeType_.load()));
        if (result != AUDIOSUITE_SUCCESS) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                "set general voice change type failed code=%{public}d type=%{public}d",
                static_cast<int>(result), generalVoiceChangeType_.load());
            return false;
        }
        return true;
    }

    bool SetPureVoiceChangeStateLocked(OH_AudioNode* node)
    {
        if (node == nullptr) {
            return true;
        }
        if (!BypassNodeLocked(node, false)) {
            return false;
        }
        OH_AudioSuite_PureVoiceChangeOption option = {};
        option.optionGender = static_cast<OH_AudioSuite_PureVoiceChangeGenderOption>(
            pureVoiceChangeGender_.load());
        option.optionType = static_cast<OH_AudioSuite_PureVoiceChangeType>(pureVoiceChangeType_.load());
        option.pitch = pureVoiceChangePitch_.load();
        OH_AudioSuite_Result result = OH_AudioSuiteEngine_SetPureVoiceChangeOption(node, option);
        if (result != AUDIOSUITE_SUCCESS) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                "set pure voice change option failed code=%{public}d gender=%{public}d type=%{public}d",
                static_cast<int>(result), option.optionGender, option.optionType);
            return false;
        }
        return true;
    }

    bool SetTempoPitchStateLocked(OH_AudioNode* node)
    {
        if (node == nullptr) {
            return true;
        }
        if (!BypassNodeLocked(node, false)) {
            return false;
        }
        OH_AudioSuite_Result result = OH_AudioSuiteEngine_SetTempoAndPitch(
            node, tempoSpeed_.load(), tempoPitch_.load());
        if (result != AUDIOSUITE_SUCCESS) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                "set tempo and pitch failed code=%{public}d speed=%{public}.2f pitch=%{public}.2f",
                static_cast<int>(result), tempoSpeed_.load(), tempoPitch_.load());
            return false;
        }
        return true;
    }

    bool ApplySpaceRenderParamsLocked(OH_AudioNode* node)
    {
        if (node == nullptr) {
            return true;
        }
        OH_AudioSuite_Result result = AUDIOSUITE_SUCCESS;
        switch (spaceRenderMode_.load()) {
            case 0: {
                OH_AudioSuite_SpaceRenderPositionParams position = {};
                position.x = spaceX_;
                position.y = spaceY_;
                position.z = spaceZ_;
                result = OH_AudioSuiteEngine_SetSpaceRenderPositionParams(node, position);
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
                result = OH_AudioSuiteEngine_SetSpaceRenderRotationParams(node, rotation);
                break;
            }
            default: {
                OH_AudioSuite_SpaceRenderExtensionParams extension = {};
                extension.extRadius = spaceExtRadius_;
                extension.extAngle = spaceExtAngle_;
                result = OH_AudioSuiteEngine_SetSpaceRenderExtensionParams(node, extension);
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

    bool SetSpaceRenderStateLocked(OH_AudioNode* node)
    {
        if (node == nullptr) {
            return true;
        }
        if (!BypassNodeLocked(node, false)) {
            return false;
        }
        return ApplySpaceRenderParamsLocked(node);
    }

    // required=true 时节点创建失败视为致命错误（效果被请求），否则尽力而为跳过该节点
    bool CreateOptionalEffectNode(OH_AudioSuitePipeline* pipeline, OH_AudioNodeBuilder* builder,
        OH_AudioNode_Type type, bool required, OH_AudioNode** node)
    {
        bool supported = false;
        OH_AudioSuite_Result probeResult = OH_AudioSuiteEngine_IsNodeTypeSupported(type, &supported);
        if (probeResult != AUDIOSUITE_SUCCESS || !supported) {
            OH_LOG_Print(LOG_APP, LOG_INFO, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                "effect node type=%{public}d unsupported code=%{public}d",
                static_cast<int>(type), static_cast<int>(probeResult));
            return !required;
        }
        OH_AudioSuite_Result createResult = OH_AudioSuiteEngine_CreateNode(pipeline, builder, node);
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

    // 动态串联存在的节点：input → 主链效果（EQ/声场/环境/美化/空间渲染/通用变声）
    // → 特殊效果（降噪/传统变声/变速变调，仅特殊管线有）→ output
    bool ChainGroupNodes(PipelineGroup& group)
    {
        std::vector<OH_AudioNode*> chain;
        chain.reserve(12);
        chain.push_back(group.input);
        OH_AudioNode* effectNodes[] = {
            group.effects.eq, group.effects.soundField, group.effects.environment,
            group.effects.beautifier, group.effects.spaceRender, group.effects.generalVoiceChange,
            group.effects.noiseReduction, group.effects.pureVoiceChange, group.effects.tempoPitch
        };
        for (OH_AudioNode* node : effectNodes) {
            if (node != nullptr) {
                chain.push_back(node);
            }
        }
        chain.push_back(group.output);
        for (size_t i = 0; i + 1 < chain.size(); i++) {
            if (OH_AudioSuiteEngine_ConnectNodes(chain[i], chain[i + 1]) != AUDIOSUITE_SUCCESS) {
                OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                    "connect effect nodes failed index=%{public}zu", i);
                return false;
            }
        }
        return true;
    }

    // 当前活跃管线的效果节点组：分离管线无效果节点（返回空的 main 组，调用方判 activePipeline_）
    EffectNodeSet& ActiveEffectNodes()
    {
        if (activePipeline_ == ActivePipeline::SPECIAL) {
            return specialGroup_.effects;
        }
        return mainGroup_.effects;
    }

    OH_AudioSuitePipeline* ActivePipelineHandle()
    {
        switch (activePipeline_) {
            case ActivePipeline::MAIN:
                return mainGroup_.pipeline;
            case ActivePipeline::SPECIAL:
                return specialGroup_.pipeline;
            case ActivePipeline::SEP:
                return sepGroup_.pipeline;
            default:
                return nullptr;
        }
    }

    PipelineGroup& GroupFor(ActivePipeline pipeline)
    {
        switch (pipeline) {
            case ActivePipeline::SPECIAL:
                return specialGroup_;
            case ActivePipeline::SEP:
                return sepGroup_;
            default:
                return mainGroup_;
        }
    }

    bool NeedSpecialPipeline() const
    {
        return requestedNoiseReductionEnabled_.load() || requestedPureVoiceChangeEnabled_.load() ||
            requestedTempoPitchEnabled_.load();
    }

    // 按当前效果开关选择活跃管线：分离 > 特殊（降噪/传统变声/变速变调）> 主管线。
    // 切换 = 停旧管线 → 起新管线 → 全量重放状态 → 请求直通保持（密度因子重测）。
    // 失败时回退旧管线：目标效果不生效，但播放链路不被破坏。调用方须持有 effectMutex_。
    bool SwitchPipelineLocked()
    {
        if (mainGroup_.pipeline == nullptr) {
            return true; // 管线尚未创建（设置项在 Play 前下发）：仅记录状态，ConfigureEffects 按初始态选管线
        }
        ActivePipeline target = ActivePipeline::MAIN;
        if (requestedSeparationEnabled_.load() && sepPipelineUsable_) {
            target = ActivePipeline::SEP;
        } else if (NeedSpecialPipeline() && specialPipelineUsable_) {
            target = ActivePipeline::SPECIAL;
        }
        if (requestedSeparationEnabled_.load() && !sepPipelineUsable_) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                "separation requested but pipeline unavailable (NPU unsupported)");
        }
        if (NeedSpecialPipeline() && !specialPipelineUsable_) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                "special effects requested but pipeline unavailable");
        }
        if (target == activePipeline_) {
            return true;
        }
        OH_AudioSuitePipeline* oldPipeline = ActivePipelineHandle();
        if (oldPipeline != nullptr) {
            OH_AudioSuiteEngine_StopPipeline(oldPipeline);
        }
        PipelineGroup& nextGroup = GroupFor(target);
        if (nextGroup.pipeline == nullptr) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                "switch target pipeline missing target=%{public}d", static_cast<int>(target));
            if (oldPipeline != nullptr) {
                OH_AudioSuiteEngine_StartPipeline(oldPipeline);
            }
            return false;
        }
        OH_AudioSuite_Result startResult = OH_AudioSuiteEngine_StartPipeline(nextGroup.pipeline);
        if (startResult != AUDIOSUITE_SUCCESS) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                "switch start pipeline failed target=%{public}d code=%{public}d",
                static_cast<int>(target), static_cast<int>(startResult));
            if (oldPipeline != nullptr) {
                OH_AudioSuiteEngine_StartPipeline(oldPipeline);
            }
            return false;
        }
        activePipeline_ = target;
        ApplyEffectStatesLocked();
        // 新管线节点数不同 → 拉取密度可能变化，走直通保持重测，避免开关瞬间变调
        pipelineHoldRequested_.store(true);
        OH_LOG_Print(LOG_APP, LOG_INFO, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
            "active pipeline switched target=%{public}d", static_cast<int>(target));
        return true;
    }

    bool ApplyEffectStatesLocked()
    {
        if (activePipeline_ == ActivePipeline::SEP) {
            return true; // 分离管线仅有分离节点（无旁路参数）
        }
        EffectNodeSet& nodes = ActiveEffectNodes();
        if (nodes.eq != nullptr) {
            if (activeEqEnabled_.load()) {
                if (!ApplyBandsLocked(nodes.eq, bands_, true)) {
                    return false;
                }
            } else if (!BypassNodeLocked(nodes.eq, true)) {
                return false;
            }
        }
        if (nodes.soundField != nullptr) {
            if (requestedSoundFieldEnabled_.load()) {
                if (!SetSoundFieldStateLocked(nodes.soundField)) {
                    return false;
                }
            } else if (!BypassNodeLocked(nodes.soundField, true)) {
                return false;
            }
        }
        if (nodes.environment != nullptr) {
            if (requestedEnvironmentEnabled_.load()) {
                if (!SetEnvironmentStateLocked(nodes.environment)) {
                    return false;
                }
            } else if (!BypassNodeLocked(nodes.environment, true)) {
                return false;
            }
        }
        if (nodes.beautifier != nullptr) {
            if (requestedBeautifierEnabled_.load()) {
                if (!SetBeautifierStateLocked(nodes.beautifier)) {
                    return false;
                }
            } else if (!BypassNodeLocked(nodes.beautifier, true)) {
                return false;
            }
        }
        if (nodes.spaceRender != nullptr) {
            if (requestedSpaceRenderEnabled_.load()) {
                if (!SetSpaceRenderStateLocked(nodes.spaceRender)) {
                    return false;
                }
            } else if (!BypassNodeLocked(nodes.spaceRender, true)) {
                return false;
            }
        }
        if (nodes.generalVoiceChange != nullptr) {
            if (requestedGeneralVoiceChangeEnabled_.load()) {
                if (!SetGeneralVoiceChangeStateLocked(nodes.generalVoiceChange)) {
                    return false;
                }
            } else if (!BypassNodeLocked(nodes.generalVoiceChange, true)) {
                return false;
            }
        }
        if (nodes.noiseReduction != nullptr) {
            if (requestedNoiseReductionEnabled_.load()) {
                if (!BypassNodeLocked(nodes.noiseReduction, false)) {
                    return false;
                }
            } else if (!BypassNodeLocked(nodes.noiseReduction, true)) {
                return false;
            }
        }
        if (nodes.pureVoiceChange != nullptr) {
            if (requestedPureVoiceChangeEnabled_.load()) {
                if (!SetPureVoiceChangeStateLocked(nodes.pureVoiceChange)) {
                    return false;
                }
            } else if (!BypassNodeLocked(nodes.pureVoiceChange, true)) {
                return false;
            }
        }
        if (nodes.tempoPitch != nullptr) {
            if (requestedTempoPitchEnabled_.load()) {
                if (!SetTempoPitchStateLocked(nodes.tempoPitch)) {
                    return false;
                }
            } else if (!BypassNodeLocked(nodes.tempoPitch, true)) {
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

    // 停止并销毁三组管线的全部节点与管线（引擎由 Stop 在其后统一销毁）
    void DestroyPipelineGroups()
    {
        PipelineGroup* groups[] = { &mainGroup_, &specialGroup_, &sepGroup_ };
        for (PipelineGroup* group : groups) {
            if (group->pipeline != nullptr) {
                OH_AudioSuiteEngine_StopPipeline(group->pipeline);
            }
        }
        for (PipelineGroup* group : groups) {
            OH_AudioNode* nodes[] = {
                group->input, group->output, group->effects.eq, group->effects.soundField,
                group->effects.environment, group->effects.beautifier, group->effects.spaceRender,
                group->effects.generalVoiceChange, group->effects.noiseReduction,
                group->effects.pureVoiceChange, group->effects.tempoPitch
            };
            for (OH_AudioNode* node : nodes) {
                if (node != nullptr) {
                    OH_AudioSuiteEngine_DestroyNode(node);
                }
            }
            group->input = nullptr;
            group->output = nullptr;
            group->effects = EffectNodeSet();
        }
        if (sepNode_ != nullptr) {
            OH_AudioSuiteEngine_DestroyNode(sepNode_);
            sepNode_ = nullptr;
        }
        for (PipelineGroup* group : groups) {
            if (group->pipeline != nullptr) {
                OH_AudioSuiteEngine_DestroyPipeline(group->pipeline);
                group->pipeline = nullptr;
            }
        }
        activePipeline_ = ActivePipeline::NONE;
        specialPipelineUsable_ = false;
        sepPipelineUsable_ = false;
    }

    // 创建一组实时预览管线：input(48k/S16/2ch) → 效果节点 → output(48k/S16/2ch)。
    // withFormatChanging=true 时额外创建降噪/传统变声/变速变调（输出格式与立体声链路不一致，
    // 仅特殊管线使用）。创建完成后不启动，由 SwitchPipelineLocked 决定活跃组。
    bool BuildPipelineGroup(PipelineGroup& group, bool withFormatChanging)
    {
        if (OH_AudioSuiteEngine_CreatePipeline(engine_, &group.pipeline,
            AUDIOSUITE_PIPELINE_REALTIME_MODE) != AUDIOSUITE_SUCCESS) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                "create pipeline failed formatChanging=%{public}d", withFormatChanging ? 1 : 0);
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
        bool success = OH_AudioSuiteEngine_CreateNode(group.pipeline, builder, &group.input) == AUDIOSUITE_SUCCESS;
        OH_AudioSuiteNodeBuilder_Reset(builder);
        OH_AudioSuiteNodeBuilder_SetNodeType(builder, EFFECT_NODE_TYPE_EQUALIZER);
        success = success && CreateOptionalEffectNode(group.pipeline, builder, EFFECT_NODE_TYPE_EQUALIZER,
            false, &group.effects.eq);
        OH_AudioSuiteNodeBuilder_Reset(builder);
        OH_AudioSuiteNodeBuilder_SetNodeType(builder, EFFECT_NODE_TYPE_SOUND_FIELD);
        success = success && CreateOptionalEffectNode(group.pipeline, builder, EFFECT_NODE_TYPE_SOUND_FIELD,
            false, &group.effects.soundField);
        OH_AudioSuiteNodeBuilder_Reset(builder);
        OH_AudioSuiteNodeBuilder_SetNodeType(builder, EFFECT_NODE_TYPE_ENVIRONMENT_EFFECT);
        success = success && CreateOptionalEffectNode(group.pipeline, builder,
            EFFECT_NODE_TYPE_ENVIRONMENT_EFFECT, false, &group.effects.environment);
        OH_AudioSuiteNodeBuilder_Reset(builder);
        OH_AudioSuiteNodeBuilder_SetNodeType(builder, EFFECT_NODE_TYPE_VOICE_BEAUTIFIER);
        success = success && CreateOptionalEffectNode(group.pipeline, builder,
            EFFECT_NODE_TYPE_VOICE_BEAUTIFIER, false, &group.effects.beautifier);
        OH_AudioSuiteNodeBuilder_Reset(builder);
        OH_AudioSuiteNodeBuilder_SetNodeType(builder, EFFECT_NODE_TYPE_SPACE_RENDER);
        success = success && CreateOptionalEffectNode(group.pipeline, builder,
            EFFECT_NODE_TYPE_SPACE_RENDER, false, &group.effects.spaceRender);
        OH_AudioSuiteNodeBuilder_Reset(builder);
        OH_AudioSuiteNodeBuilder_SetNodeType(builder, EFFECT_NODE_TYPE_GENERAL_VOICE_CHANGE);
        success = success && CreateOptionalEffectNode(group.pipeline, builder,
            EFFECT_NODE_TYPE_GENERAL_VOICE_CHANGE, false, &group.effects.generalVoiceChange);
        if (withFormatChanging) {
            OH_AudioSuiteNodeBuilder_Reset(builder);
            OH_AudioSuiteNodeBuilder_SetNodeType(builder, EFFECT_NODE_TYPE_NOISE_REDUCTION);
            success = success && CreateOptionalEffectNode(group.pipeline, builder,
                EFFECT_NODE_TYPE_NOISE_REDUCTION, false, &group.effects.noiseReduction);
            OH_AudioSuiteNodeBuilder_Reset(builder);
            OH_AudioSuiteNodeBuilder_SetNodeType(builder, EFFECT_NODE_TYPE_PURE_VOICE_CHANGE);
            success = success && CreateOptionalEffectNode(group.pipeline, builder,
                EFFECT_NODE_TYPE_PURE_VOICE_CHANGE, false, &group.effects.pureVoiceChange);
            OH_AudioSuiteNodeBuilder_Reset(builder);
            OH_AudioSuiteNodeBuilder_SetNodeType(builder, EFFECT_NODE_TYPE_TEMPO_PITCH);
            success = success && CreateOptionalEffectNode(group.pipeline, builder,
                EFFECT_NODE_TYPE_TEMPO_PITCH, false, &group.effects.tempoPitch);
        }
        OH_AudioSuiteNodeBuilder_Reset(builder);
        OH_AudioFormat outputFormat = {};
        outputFormat.samplingRate = SAMPLE_RATE_48000;
        outputFormat.channelLayout = CH_LAYOUT_STEREO;
        outputFormat.channelCount = 2;
        outputFormat.encodingType = AUDIO_ENCODING_TYPE_RAW;
        outputFormat.sampleFormat = AUDIO_SAMPLE_S16LE;
        OH_AudioSuiteNodeBuilder_SetNodeType(builder, OUTPUT_NODE_TYPE_DEFAULT);
        OH_AudioSuiteNodeBuilder_SetFormat(builder, outputFormat);
        success = success &&
            OH_AudioSuiteEngine_CreateNode(group.pipeline, builder, &group.output) == AUDIOSUITE_SUCCESS;
        OH_AudioSuiteNodeBuilder_Destroy(builder);
        if (!success || !ChainGroupNodes(group)) {
            return false;
        }
        return true;
    }

    // 分离管线：input(48k/S16/2ch) → 音源分离(多输出) → output(48k/S16/2ch)。
    // 官方约束：音源分离节点只能连接输出节点，且每个管线不超过 1 个；依赖 NPU 需先探测。
    bool BuildSeparationPipeline()
    {
        bool supported = false;
        OH_AudioSuite_Result probeResult = OH_AudioSuiteEngine_IsNodeTypeSupported(
            EFFECT_MULTII_OUTPUT_NODE_TYPE_AUDIO_SEPARATION, &supported);
        if (probeResult != AUDIOSUITE_SUCCESS || !supported) {
            OH_LOG_Print(LOG_APP, LOG_INFO, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                "audio separation unsupported code=%{public}d", static_cast<int>(probeResult));
            return false;
        }
        if (OH_AudioSuiteEngine_CreatePipeline(engine_, &sepGroup_.pipeline,
            AUDIOSUITE_PIPELINE_REALTIME_MODE) != AUDIOSUITE_SUCCESS) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                "create separation pipeline failed");
            return false;
        }
        OH_AudioNodeBuilder* builder = nullptr;
        if (OH_AudioSuiteNodeBuilder_Create(&builder) != AUDIOSUITE_SUCCESS) {
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
        bool success = OH_AudioSuiteEngine_CreateNode(sepGroup_.pipeline, builder, &sepGroup_.input) ==
            AUDIOSUITE_SUCCESS;
        OH_AudioSuiteNodeBuilder_Reset(builder);
        OH_AudioSuiteNodeBuilder_SetNodeType(builder, EFFECT_MULTII_OUTPUT_NODE_TYPE_AUDIO_SEPARATION);
        success = success && OH_AudioSuiteEngine_CreateNode(sepGroup_.pipeline, builder, &sepNode_) ==
            AUDIOSUITE_SUCCESS;
        OH_AudioSuiteNodeBuilder_Reset(builder);
        OH_AudioFormat outputFormat = {};
        outputFormat.samplingRate = SAMPLE_RATE_48000;
        outputFormat.channelLayout = CH_LAYOUT_STEREO;
        outputFormat.channelCount = 2;
        outputFormat.encodingType = AUDIO_ENCODING_TYPE_RAW;
        outputFormat.sampleFormat = AUDIO_SAMPLE_S16LE;
        OH_AudioSuiteNodeBuilder_SetNodeType(builder, OUTPUT_NODE_TYPE_DEFAULT);
        OH_AudioSuiteNodeBuilder_SetFormat(builder, outputFormat);
        success = success && OH_AudioSuiteEngine_CreateNode(sepGroup_.pipeline, builder, &sepGroup_.output) ==
            AUDIOSUITE_SUCCESS;
        OH_AudioSuiteNodeBuilder_Destroy(builder);
        if (!success || sepNode_ == nullptr || sepGroup_.input == nullptr || sepGroup_.output == nullptr) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                "separation node chain setup failed");
            return false;
        }
        if (OH_AudioSuiteEngine_ConnectNodes(sepGroup_.input, sepNode_) != AUDIOSUITE_SUCCESS ||
            OH_AudioSuiteEngine_ConnectNodes(sepNode_, sepGroup_.output) != AUDIOSUITE_SUCCESS) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                "connect separation nodes failed");
            return false;
        }
        return true;
    }

    bool ConfigureEffects()
    {
        if (!IsEqualizerSupported() || OH_AudioSuiteEngine_Create(&engine_) != AUDIOSUITE_SUCCESS) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG, "effect engine setup failed");
            return false;
        }
        // 主管线为播放基本盘：创建失败视为致命（回归 AVPlayer 直通）
        if (!BuildPipelineGroup(mainGroup_, false)) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG, "main pipeline setup failed");
            return false;
        }
        // 特殊/分离管线尽力而为：设备不支持时置不可用，效果开关静默保持主管线
        specialPipelineUsable_ = BuildPipelineGroup(specialGroup_, true);
        sepPipelineUsable_ = BuildSeparationPipeline();
        OH_LOG_Print(LOG_APP, LOG_INFO, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
            "pipelines built main=1 special=%{public}d separation=%{public}d",
            specialPipelineUsable_ ? 1 : 0, sepPipelineUsable_ ? 1 : 0);
        {
            std::lock_guard<std::mutex> lock(effectMutex_);
            // 初始活跃管线按持久化设置选择（分离 > 特殊 > 主管线）
            ActivePipeline initial = ActivePipeline::MAIN;
            if (requestedSeparationEnabled_.load() && sepPipelineUsable_) {
                initial = ActivePipeline::SEP;
            } else if (NeedSpecialPipeline() && specialPipelineUsable_) {
                initial = ActivePipeline::SPECIAL;
            }
            activePipeline_ = initial;
            if (!ApplyEffectStatesLocked()) {
                OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                    "apply initial effect states failed");
                return false;
            }
            PipelineGroup& group = GroupFor(initial);
            if (OH_AudioSuiteEngine_StartPipeline(group.pipeline) != AUDIOSUITE_SUCCESS) {
                OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                    "start initial pipeline failed initial=%{public}d", static_cast<int>(initial));
                // 特殊/分离管线启动失败 → 回退主管线（主管线为基本盘）
                if (initial != ActivePipeline::MAIN) {
                    activePipeline_ = ActivePipeline::MAIN;
                    if (initial == ActivePipeline::SEP) {
                        sepPipelineUsable_ = false;
                    } else {
                        specialPipelineUsable_ = false;
                    }
                    ApplyEffectStatesLocked();
                    if (OH_AudioSuiteEngine_StartPipeline(mainGroup_.pipeline) != AUDIOSUITE_SUCCESS) {
                        return false;
                    }
                } else {
                    return false;
                }
            }
        }
        return true;
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
            OH_AudioRenderer_SetSpeed(renderer_, playbackSpeed_.load(std::memory_order_relaxed));
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
        }
        converterInputFinished_.store(false);
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

    // 官方 OH_AudioConverter 输入回调：按转换器的请求提供源采样率 PCM。
    static int32_t ConverterDataCallback(void* userData, const void** outInputData,
        OH_AudioConverter_InputStatus* outStatus)
    {
        if (userData == nullptr || outInputData == nullptr || outStatus == nullptr) {
            return 0;
        }
        return static_cast<NativeAudioPlayer*>(userData)->FillConverterInput(outInputData, outStatus);
    }

    // 从 pcmQueue_ 取一段连续源 PCM 交给转换器。官方要求 outInputData 指向的内存在 Process
    // 返回前保持有效，因此必须拷贝到常驻缓冲，不能直接指向队列内部节点。
    int32_t FillConverterInput(const void** outInputData, OH_AudioConverter_InputStatus* outStatus)
    {
        *outInputData = nullptr;
        std::unique_lock<std::mutex> lock(queueMutex_);
        // 数据不足一个采样点：短等解码线程（8ms，与 FAST 低时延回调期限匹配），
        // 不能在持锁状态下长阻塞，否则解码线程无法填充队列造成死锁。
        if (pcmQueue_.size() < 4 && !decodingEnded_.load() && !stopRequested_.load()) {
            queueCondition_.wait_for(lock, std::chrono::milliseconds(8), [this]() {
                return stopRequested_.load() || decodingEnded_.load() || pcmQueue_.size() >= 4;
            });
        }
        if (stopRequested_.load()) {
            converterInputFinished_.store(true);
            *outStatus = AUDIOCONVERTER_INPUT_DATA_FINISHED;
            return 0;
        }
        if (pcmQueue_.size() < 4) {
            if (decodingEnded_.load()) {
                converterInputFinished_.store(true);
                *outStatus = AUDIOCONVERTER_INPUT_DATA_FINISHED;
            } else {
                *outStatus = AUDIOCONVERTER_INPUT_NO_AVAILABLE_DATA;
            }
            return 0;
        }
        // 只按整采样点（立体声 S16LE，4 字节）交付，转换器不接受半个采样点
        size_t want = pcmQueue_.size() - (pcmQueue_.size() % 4);
        if (want > CONVERTER_INPUT_MAX_BYTES) {
            want = CONVERTER_INPUT_MAX_BYTES;
        }
        if (converterInputBuf_.size() < want) {
            converterInputBuf_.resize(want);
        }
        std::copy(pcmQueue_.begin(), pcmQueue_.begin() + static_cast<std::ptrdiff_t>(want),
            converterInputBuf_.begin());
        pcmQueue_.erase(pcmQueue_.begin(), pcmQueue_.begin() + static_cast<std::ptrdiff_t>(want));
        lock.unlock();
        queueCondition_.notify_all();
        *outInputData = converterInputBuf_.data();
        *outStatus = AUDIOCONVERTER_INPUT_HAVE_DATA;
        return static_cast<int32_t>(want);
    }

    static bool IsConverterRateSupported(int32_t rate)
    {
        for (int32_t supported : CONVERTER_SUPPORTED_RATES) {
            if (supported == rate) {
                return true;
            }
        }
        return false;
    }

    // 取最接近的受支持采样率，避免极少数非标采样率导致转换器创建失败而完全无声。
    static int32_t NearestConverterRate(int32_t rate)
    {
        int32_t best = CONVERTER_SUPPORTED_RATES[0];
        int64_t bestDiff = static_cast<int64_t>(rate) - best;
        if (bestDiff < 0) {
            bestDiff = -bestDiff;
        }
        for (int32_t supported : CONVERTER_SUPPORTED_RATES) {
            int64_t diff = static_cast<int64_t>(rate) - supported;
            if (diff < 0) {
                diff = -diff;
            }
            if (diff < bestDiff) {
                bestDiff = diff;
                best = supported;
            }
        }
        return best;
    }

    // 创建或复用「源采样率 -> 目标采样率」的官方格式转换器。目标采样率随 inputDensityFactor_
    // 变化，不匹配时重建；采样率变化只发生在切歌，重建成本可接受。
    bool EnsureConverter(int32_t outputRate)
    {
        if (!IsConverterRateSupported(outputRate)) {
            if (!converterRateWarned_) {
                converterRateWarned_ = true;
                OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                    "converter output rate unsupported=%{public}d", outputRate);
            }
            return false;
        }
        const int32_t inputRate = IsConverterRateSupported(resampleInputRate_)
            ? resampleInputRate_ : NearestConverterRate(resampleInputRate_);
        if (converter_ != nullptr && converterInputRate_ == inputRate && converterOutputRate_ == outputRate) {
            return true;
        }
        DestroyConverter();
        OH_AudioConverter_Format inputFormat = {};
        inputFormat.encodingType = AUDIO_ENCODING_TYPE_RAW;
        inputFormat.samplingRate = static_cast<OH_Audio_SampleRate>(inputRate);
        inputFormat.channelLayout = CH_LAYOUT_STEREO;
        inputFormat.sampleFormat = AUDIO_SAMPLE_S16LE;
        OH_AudioConverter_Format outputFormat = inputFormat;
        outputFormat.samplingRate = static_cast<OH_Audio_SampleRate>(outputRate);
        OH_AudioConverter* created = nullptr;
        OH_AudioConverter_Result createResult = OH_AudioConverter_Create(&inputFormat, &outputFormat, &created);
        if (createResult != AUDIOCONVERTER_SUCCESS || created == nullptr) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                "converter create failed code=%{public}d in=%{public}d out=%{public}d",
                static_cast<int>(createResult), inputRate, outputRate);
            return false;
        }
        OH_AudioConverter_Result callbackResult =
            OH_AudioConverter_SetInputCallback(created, ConverterDataCallback, this);
        if (callbackResult != AUDIOCONVERTER_SUCCESS) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                "converter set callback failed code=%{public}d", static_cast<int>(callbackResult));
            OH_AudioConverter_Destroy(created);
            return false;
        }
        converter_ = created;
        converterInputRate_ = inputRate;
        converterOutputRate_ = outputRate;
        converterInputFinished_.store(false);
        OH_LOG_Print(LOG_APP, LOG_INFO, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
            "audio converter ready in=%{public}d out=%{public}d", inputRate, outputRate);
        return true;
    }

    void DestroyConverter()
    {
        if (converter_ != nullptr) {
            OH_AudioConverter_Destroy(converter_);
            converter_ = nullptr;
        }
        converterInputRate_ = 0;
        converterOutputRate_ = 0;
        // 保留 converterInputBuf_ 容量：切歌/密度变化都会重建转换器，避免反复分配大缓冲
    }

    // 取源采样率 PCM 经官方 OH_AudioConverter 转成目标采样率写入 audioData。
    // usePipeline=true 时目标为 48000×inputDensityFactor_：AudioSuite 管线按 N 倍速率拉取输入，
    // 输出速率必须同步放大 N 倍，源才会按实时速率推进；直通渲染恒为 48000，否则会残留管线期倍率，
    // 导致播放速度减半、音调降低。
    int32_t ReadPcm(void* audioData, int32_t audioDataSize, bool* finished, bool usePipeline)
    {
        if (audioData == nullptr || audioDataSize <= 0 || finished == nullptr) {
            return 0;
        }
        *finished = false;
        const int32_t targetRate = usePipeline
            ? resampleOutputRate_ * inputDensityFactor_.load()
            : resampleOutputRate_;
        if (!EnsureConverter(targetRate)) {
            std::memset(audioData, 0, static_cast<size_t>(audioDataSize));
            return 0;
        }
        int32_t outputSize = 0;
        OH_AudioConverter_Result result =
            OH_AudioConverter_Process(converter_, audioData, audioDataSize, &outputSize);
        if (result != AUDIOCONVERTER_SUCCESS) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                "converter process failed code=%{public}d size=%{public}d",
                static_cast<int>(result), outputSize);
            std::memset(audioData, 0, static_cast<size_t>(audioDataSize));
            return 0;
        }
        if (outputSize < 0) {
            outputSize = 0;
        }
        if (outputSize > audioDataSize) {
            outputSize = audioDataSize;
        }
        if (outputSize < audioDataSize) {
            std::memset(static_cast<uint8_t*>(audioData) + outputSize, 0,
                static_cast<size_t>(audioDataSize - outputSize));
        }
        // 官方契约：输入回调报告 DATA_FINISHED 后仍需反复 Process，直到 outputSize 为 0
        // 才表示内部缓存（含重采样滤波尾巴）全部刷出，此时才可判定播放结束。
        if (converterInputFinished_.load() && outputSize == 0) {
            *finished = true;
            queueCondition_.notify_all();
        }
        return outputSize;
    }

    void MeasureInputDensity(int32_t audioDataSize)
    {
        if (audioDataSize <= 0) {
            return;
        }
        // 效果开关/保持期起点请求重测：丢弃陈旧窗口与滞回暂存，从干净窗口重新测量
        if (densityWindowResetRequested_.exchange(false)) {
            inputWindowStartMs_ = 0;
            inputWindowFrames_ = 0;
            densityPendingCandidate_ = 0;
            densityPendingCount_ = 0;
        }
        const int64_t nowMs = SteadyNowMs();
        const uint64_t frames = static_cast<uint64_t>(audioDataSize) / 4;
        if (inputWindowStartMs_ == 0) {
            inputWindowStartMs_ = nowMs;
            inputWindowFrames_ = 0;
        }
        inputWindowFrames_ += frames;
        const int64_t winMs = nowMs - inputWindowStartMs_;
        if (winMs < DENSITY_WINDOW_MS) {
            return;
        }
        // 倍速下渲染器排空加快，引擎拉取随之上等比：实测 fps = 密度 × 倍速 × 48000。
        // 必须剔除倍速分量后再与档位标称值比较——否则倍速会被密度修正环抵消：
        // 设 2× → 实测翻倍 → 因子上调 → 重采样比减半 → 源回到 1× 实时推进 → 倍速失效。
        // 密度因子只追踪引擎自身密度，与倍速无关（ReadPcm 仍按 48000×N 喂，源推进=倍速×实时）。
        const float rawSpeed = playbackSpeed_.load(std::memory_order_relaxed);
        const double speedNorm = rawSpeed > 0.05f ? static_cast<double>(rawSpeed) : 1.0;
        const double measuredFps = static_cast<double>(inputWindowFrames_) * 1000.0 /
            static_cast<double>(winMs) / speedNorm;
        const int32_t current = inputDensityFactor_.load();
        const double nominalFps = static_cast<double>(current) * 48000.0;
        // 滞回：仅在实测偏离当前档位标称值超过带宽、且连续 2 个窗口指向同一新档位时才切换，
        // 防止拉取抖动导致因子反复跳变（每次跳变都是一次音调阶跃）
        int32_t candidate = current;
        if (std::abs(measuredFps - nominalFps) > DENSITY_SWITCH_BAND * nominalFps) {
            // 上限 2：密度因子现在驱动官方 OH_AudioConverter 的输出采样率，必须是官方白名单内的值
            // （48000×2=96000 合法，×3=144000 不在白名单），且实测倍率恒为 1 或 2。
            candidate = std::clamp(
                static_cast<int32_t>(std::lround(measuredFps / 48000.0)), 1, 2);
        }
        // 滞回确认：密度因子绝不直接在播放路径上切换——直接切换会瞬间改变重采样比率，
        // 造成波形错位（沙声）与短促音调偏移。确认后的动作分两种：
        // 1) 保持期内确认（开关音效/激活保护中）：记录目标档，释放帧在直通保护下应用；
        // 2) 播放中确认（引擎拉取自行漂移）：只请求直通保护重测（带冷却防频繁闪断），
        //    确认与应用全部转移到保护期内完成，可听路径上永远不发生因子切换。
        if (candidate == current) {
            densityPendingCandidate_ = 0;
            densityPendingCount_ = 0;
        } else if (candidate == densityPendingCandidate_) {
            densityPendingCount_++;
            const bool inHold = pipelineHoldActive_.load();
            const int32_t required = inHold ? DENSITY_HOLD_CONFIRM_WINDOWS
                : DENSITY_PLAYBACK_CONFIRM_WINDOWS;
            if (densityPendingCount_ >= required) {
                densityPendingCandidate_ = 0;
                densityPendingCount_ = 0;
                if (inHold) {
                    densityRetarget_ = candidate;
                    OH_LOG_Print(LOG_APP, LOG_INFO, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                        "input density retarget=%{public}d confirmed in hold (measuredFps=%{public}.1f)",
                        candidate, measuredFps);
                } else if (densityHoldLastMs_ == 0 ||
                    SteadyNowMs() - densityHoldLastMs_ >= DENSITY_HOLD_COOLDOWN_MS) {
                    pipelineHoldRequested_.store(true);
                    OH_LOG_Print(LOG_APP, LOG_INFO, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                        "input density drift -> hold requested (candidate=%{public}d "
                        "measuredFps=%{public}.1f)", candidate, measuredFps);
                }
            }
        } else {
            densityPendingCandidate_ = candidate;
            densityPendingCount_ = 1;
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
        // 管线直通保持期：预热渲染喂静音（不消费源、不进响度输入参考），
        // 拉取节奏照常计入密度测量，保持期结束恢复真实拉取
        if (player->pipelineHoldActive_.load()) {
            if (audioData != nullptr && audioDataSize > 0) {
                std::memset(audioData, 0, static_cast<size_t>(audioDataSize));
            }
            if (finished != nullptr) {
                *finished = false;
            }
            player->pipelineInputCalls_.fetch_add(1, std::memory_order_relaxed);
            player->pipelineInputBytes_.fetch_add(audioDataSize > 0 ?
                static_cast<uint64_t>(audioDataSize) : 0, std::memory_order_relaxed);
            player->MeasureInputDensity(audioDataSize);
            return audioDataSize > 0 ? audioDataSize : 0;
        }
        int32_t readSize = player->ReadPcm(audioData, audioDataSize, finished, true);
        player->pipelineInputCalls_.fetch_add(1, std::memory_order_relaxed);
        player->pipelineInputBytes_.fetch_add(readSize > 0 ? static_cast<uint64_t>(readSize) : 0,
            std::memory_order_relaxed);
        if (!player->pipelineInputFirstLogged_.exchange(true)) {
            OH_LOG_Print(LOG_APP, LOG_INFO, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                "pipeline input first pull size=%{public}d", audioDataSize);
        }
        player->MeasureInput(audioData, readSize);
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
        // RT 回调退化为纯环形缓冲读取：不执行 RenderFrame/IPC、不持 effectMutex_，
        // 渲染失败语义由工作线程（RenderLoop）置 decoderFailed_ 处理
        player->ReadRingInto(audioData, audioDataSize);
        player->MeasureOutput(audioData, audioDataSize, player->activeEqEnabled_.load());
        return AUDIO_DATA_CALLBACK_RESULT_VALID;
    }

    // RT 回调专用：从环形缓冲读取，绝不阻塞；欠载时从最后真实采样线性衰减到 0，
    // 避免直接补零的静音爆点。欠载计数 + 每秒最多 1 条限速日志。
    void ReadRingInto(void* audioData, int32_t audioDataSize)
    {
        int16_t* outSamples = static_cast<int16_t*>(audioData);
        const int32_t totalSamples = audioDataSize / static_cast<int32_t>(sizeof(int16_t));
        size_t copied = 0;
        {
            std::lock_guard<std::mutex> lock(ringMutex_);
            copied = std::min(ringFilled_, static_cast<size_t>(totalSamples));
            const size_t capacity = ringBuffer_.size();
            for (size_t i = 0; i < copied; i++) {
                outSamples[i] = ringBuffer_[ringReadPos_];
                ringReadPos_ = (ringReadPos_ + 1) % capacity;
            }
            ringFilled_ -= copied;
            if (copied > 0) {
                ringUnderrunLastSample_ = outSamples[copied - 1];
            }
            // 释放了空间，唤醒工作线程继续渲染（wait morphing，开销极小）
            ringCondition_.notify_one();
        }
        if (copied < static_cast<size_t>(totalSamples)) {
            ringUnderrunCount_.fetch_add(1, std::memory_order_relaxed);
            const int32_t validSamples = static_cast<int32_t>(copied);
            const int16_t lastSample = validSamples > 0 ? outSamples[validSamples - 1] : ringUnderrunLastSample_;
            const int32_t missing = totalSamples - validSamples;
            for (int32_t i = 0; i < missing; i++) {
                const double fadeGain = static_cast<double>(missing - i) / static_cast<double>(missing);
                outSamples[validSamples + i] = static_cast<int16_t>(std::lround(
                    static_cast<double>(lastSample) * fadeGain));
            }
            const int64_t nowMs = SteadyNowMs();
            if (nowMs - ringUnderrunLastLogMs_ >= RING_UNDERRUN_LOG_INTERVAL_MS) {
                ringUnderrunLastLogMs_ = nowMs;
                OH_LOG_Print(LOG_APP, LOG_WARN, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                    "ring underrun (rt) valid=%{public}d total=%{public}d count=%{public}llu",
                    validSamples, totalSamples,
                    static_cast<unsigned long long>(ringUnderrunCount_.load()));
            }
        }
    }

    // 环形缓冲复位：Play 起播 / Seek 时丢弃残留音频
    void RingReset()
    {
        std::lock_guard<std::mutex> lock(ringMutex_);
        ringReadPos_ = 0;
        ringWritePos_ = 0;
        ringFilled_ = 0;
    }

    // 工作线程写入环形缓冲（持 ringMutex_ 仅做拷贝，绝不与 effectMutex_/queueMutex_ 嵌套）
    void RingWrite(const int16_t* data, size_t samples)
    {
        std::lock_guard<std::mutex> lock(ringMutex_);
        const size_t capacity = ringBuffer_.size();
        if (capacity == 0) {
            return;
        }
        const size_t writable = std::min(samples, capacity - ringFilled_);
        for (size_t i = 0; i < writable; i++) {
            ringBuffer_[ringWritePos_] = data[i];
            ringWritePos_ = (ringWritePos_ + 1) % capacity;
        }
        ringFilled_ += writable;
    }

    // 渲染工作线程主循环：环形缓冲有空位即按 10ms 块渲染写入。RenderAudio 全套逻辑
    // （RenderFrame 含效果服务 IPC、转换器、hold、密度、响度补偿、直通）在本线程执行，
    // 与 RT 回调无共享锁路径；效果参数 IPC（effectMutex_）只剩 NAPI 线程与本线程竞争。
    void RenderLoop()
    {
        const size_t chunkSamples = static_cast<size_t>(RING_CHUNK_MS) * RING_SAMPLES_PER_MS;
        const int32_t chunkBytes = static_cast<int32_t>(chunkSamples * sizeof(int16_t));
        OH_LOG_Print(LOG_APP, LOG_INFO, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
            "render worker started chunkSamples=%{public}zu", chunkSamples);
        while (true) {
            {
                std::unique_lock<std::mutex> lock(ringMutex_);
                // 20ms 超时兜底：任何一处无锁原子写 + 通知的丢唤醒窗口最多延迟一个周期自愈
                ringCondition_.wait_for(lock, std::chrono::milliseconds(20), [this, chunkSamples]() {
                    return renderStopRequested_.load() || decoderFailed_.load() ||
                        ringBuffer_.size() - ringFilled_ >= chunkSamples;
                });
                if (renderStopRequested_.load() || decoderFailed_.load()) {
                    break;
                }
            }
            const auto chunkStart = std::chrono::steady_clock::now();
            if (!RenderAudio(renderChunkBuf_.data(), chunkBytes, IsPipelineActive())) {
                decoderFailed_ = true;
                paused_ = true;
                OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                    "render frame failed; marked native playback failed");
                break;
            }
            RingWrite(renderChunkBuf_.data(), chunkSamples);
            const int64_t chunkMs = std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::steady_clock::now() - chunkStart).count();
            if (chunkMs > RENDER_CHUNK_WARN_MS) {
                renderChunkSlowCount_++;
                OH_LOG_Print(LOG_APP, LOG_WARN, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                    "render chunk slow elapsedMs=%{public}lld (worker)", static_cast<long long>(chunkMs));
            }
        }
        OH_LOG_Print(LOG_APP, LOG_INFO, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
            "render worker exiting stop=%{public}d failed=%{public}d",
            renderStopRequested_.load() ? 1 : 0, decoderFailed_.load() ? 1 : 0);
    }

    static int64_t SteadyNowMs()
    {
        return std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now().time_since_epoch()).count();
    }

    // 正常管线路径：RenderFrame + 响度补偿 + 欠载边缘淡变 + 流量统计（仅渲染线程调用）
    bool RenderPipelineFrame(void* audioData, int32_t audioDataSize)
    {
        // EOF 守卫：官方契约规定管线 finished 后再调 RenderFrame 返回
        // AUDIOSUITE_ERROR_UNSUPPORTED_OPERATION，会被下方误判为渲染失败并刷错误日志。
        // EOF 后（新播放/seek 会复位该标志）静音交付。
        if (audioSuiteEofReached_.load()) {
            std::memset(audioData, 0, static_cast<size_t>(audioDataSize));
            return true;
        }
        // 分离管线为多输出（人声/伴奏两路），必须走 MultiRenderFrame 并按输出模式选路/混合
        {
            std::lock_guard<std::mutex> lock(effectMutex_);
            if (activePipeline_ == ActivePipeline::SEP) {
                return RenderSeparationFrameLocked(audioData, audioDataSize);
            }
        }
        bool finished = false;
        int32_t produced = 0;
        {
            std::lock_guard<std::mutex> lock(effectMutex_);
            OH_AudioSuitePipeline* activePipeline = ActivePipelineHandle();
            int32_t attempt = 0;
            while (produced < audioDataSize) {
                int32_t responseSize = 0;
                bool partFinished = false;
                OH_AudioSuite_Result result = OH_AudioSuiteEngine_RenderFrame(
                    activePipeline, static_cast<uint8_t*>(audioData) + produced,
                    audioDataSize - produced, &responseSize, &partFinished);
                if (result != AUDIOSUITE_SUCCESS) {
                    OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                        "RenderFrame failed result=%d responseSize=%d finished=%d inputSize=%d",
                        static_cast<int>(result), responseSize, partFinished ? 1 : 0,
                        audioDataSize - produced);
                    if (produced == 0) {
                        return false;
                    }
                    break; // 已拉到部分数据：交付部分帧，尾部按短响应淡出处理
                }
                if (responseSize > audioDataSize - produced) {
                    responseSize = audioDataSize - produced;
                }
                if (responseSize > 0) {
                    produced += responseSize;
                }
                finished = finished || partFinished;
                if (partFinished || produced >= audioDataSize) {
                    break;
                }
                // 短响应：异步效果服务块未就绪，微等待后重试补满本帧（见常量区注释）
                attempt++;
                if (attempt > PIPELINE_SHORTFALL_RETRY_MAX) {
                    break;
                }
                if (responseSize == 0) {
                    std::this_thread::sleep_for(
                        std::chrono::milliseconds(PIPELINE_SHORTFALL_RETRY_WAIT_MS));
                }
            }
        }
        // 闭环响度补偿：只处理管线真正产出的有效数据
        ApplyLoudnessCompensation(audioData, produced);
        // 补块重试后仍不足（服务确实无数据/EOF）：末尾做 128 采样（≈2.7ms@48k）线性淡出，
        // 下一帧恢复时头部对称淡入，把补零造成的爆点遮蔽掉；重试已大幅降低此路径触发概率。
        const int32_t totalSamples = audioDataSize / static_cast<int32_t>(sizeof(int16_t));
        const int32_t validSamples = produced / static_cast<int32_t>(sizeof(int16_t));
        int16_t* outSamples = static_cast<int16_t*>(audioData);
        if (validSamples < totalSamples) {
            constexpr int32_t SHORTFALL_FADE_SAMPLES = 128;
            const int32_t fadeStart = std::max(0, validSamples - SHORTFALL_FADE_SAMPLES);
            for (int32_t i = fadeStart; i < validSamples; i++) {
                const double fadeGain = static_cast<double>(validSamples - i) /
                    static_cast<double>(validSamples - fadeStart);
                outSamples[i] = static_cast<int16_t>(std::lround(
                    static_cast<double>(outSamples[i]) * fadeGain));
            }
            std::memset(outSamples + validSamples, 0,
                static_cast<size_t>(totalSamples - validSamples) * sizeof(int16_t));
            pipelineShortfallPrev_ = true;
        } else if (pipelineShortfallPrev_) {
            constexpr int32_t SHORTFALL_FADE_SAMPLES = 128;
            const int32_t fadeSamples = std::min(SHORTFALL_FADE_SAMPLES, totalSamples);
            for (int32_t i = 0; i < fadeSamples; i++) {
                const double fadeGain = static_cast<double>(i + 1) / static_cast<double>(fadeSamples);
                outSamples[i] = static_cast<int16_t>(std::lround(
                    static_cast<double>(outSamples[i]) * fadeGain));
            }
            pipelineShortfallPrev_ = false;
        }
        pipelineRenderCalls_++;
        pipelineRenderReqBytes_ += static_cast<uint64_t>(audioDataSize);
        pipelineRenderRespBytes_ += static_cast<uint64_t>(produced);
        if (!pipelineRenderFirstLogged_) {
            pipelineRenderFirstLogged_ = true;
            OH_LOG_Print(LOG_APP, LOG_INFO, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                "pipeline render first req=%{public}d resp=%{public}d finished=%{public}d",
                audioDataSize, produced, finished ? 1 : 0);
        }
        const int64_t nowMs = SteadyNowMs();
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

    // 分离管线渲染：MultiRenderFrame 取人声/伴奏两路，按 separationOutput_ 选路或混合后交付。
    // 官方示例中两路输出缓冲与输出节点同格式（48k/S16/2ch），requestFrameSize 为单路字节数。
    // 调用方须已持有 effectMutex_（仅渲染线程调用）。
    bool RenderSeparationFrameLocked(void* audioData, int32_t audioDataSize)
    {
        const size_t requiredBytes = static_cast<size_t>(audioDataSize);
        if (sepScratchA_.size() * sizeof(int16_t) < requiredBytes ||
            sepScratchB_.size() * sizeof(int16_t) < requiredBytes) {
            const size_t samples = (requiredBytes + sizeof(int16_t) - 1) / sizeof(int16_t);
            sepScratchA_.assign(samples, 0);
            sepScratchB_.assign(samples, 0);
        }
        void* buffers[2] = { sepScratchA_.data(), sepScratchB_.data() };
        OH_AudioDataArray dataArray = {};
        dataArray.audioDataArray = buffers;
        dataArray.arraySize = 2;
        dataArray.requestFrameSize = audioDataSize;

        bool finished = false;
        int32_t produced = 0;
        int32_t attempt = 0;
        while (produced < audioDataSize) {
            int32_t responseSize = 0;
            bool partFinished = false;
            OH_AudioSuite_Result result = OH_AudioSuiteEngine_MultiRenderFrame(
                sepGroup_.pipeline, &dataArray, &responseSize, &partFinished);
            if (result != AUDIOSUITE_SUCCESS) {
                OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                    "MultiRenderFrame failed result=%{public}d responseSize=%{public}d inputSize=%{public}d",
                    static_cast<int>(result), responseSize, audioDataSize - produced);
                if (produced == 0) {
                    return false;
                }
                break;
            }
            if (responseSize > audioDataSize - produced) {
                responseSize = audioDataSize - produced;
            }
            if (responseSize > 0) {
                // 按输出模式合成：1=仅人声 2=仅伴奏 3=人声+伴奏等权平均
                const int32_t output = separationOutput_.load();
                const int16_t* vocal = static_cast<const int16_t*>(buffers[0]);
                const int16_t* accompaniment = static_cast<const int16_t*>(buffers[1]);
                int16_t* out = static_cast<int16_t*>(audioData) + produced / sizeof(int16_t);
                const int32_t samples = responseSize / static_cast<int32_t>(sizeof(int16_t));
                for (int32_t i = 0; i < samples; i++) {
                    if (output == 2) {
                        out[i] = accompaniment[i];
                    } else if (output == 3) {
                        const int32_t mixed = (static_cast<int32_t>(vocal[i]) +
                            static_cast<int32_t>(accompaniment[i])) / 2;
                        out[i] = static_cast<int16_t>(std::clamp(mixed, -32768, 32767));
                    } else {
                        out[i] = vocal[i];
                    }
                }
                produced += responseSize;
            }
            finished = finished || partFinished;
            if (partFinished || produced >= audioDataSize) {
                break;
            }
            attempt++;
            if (attempt > PIPELINE_SHORTFALL_RETRY_MAX) {
                break;
            }
            if (responseSize == 0) {
                std::this_thread::sleep_for(
                    std::chrono::milliseconds(PIPELINE_SHORTFALL_RETRY_WAIT_MS));
            }
        }
        ApplyLoudnessCompensation(audioData, produced);
        const int32_t totalSamples = audioDataSize / static_cast<int32_t>(sizeof(int16_t));
        const int32_t validSamples = produced / static_cast<int32_t>(sizeof(int16_t));
        int16_t* outSamples = static_cast<int16_t*>(audioData);
        if (validSamples < totalSamples) {
            constexpr int32_t SHORTFALL_FADE_SAMPLES = 128;
            const int32_t fadeStart = std::max(0, validSamples - SHORTFALL_FADE_SAMPLES);
            for (int32_t i = fadeStart; i < validSamples; i++) {
                const double fadeGain = static_cast<double>(validSamples - i) /
                    static_cast<double>(validSamples - fadeStart);
                outSamples[i] = static_cast<int16_t>(std::lround(
                    static_cast<double>(outSamples[i]) * fadeGain));
            }
            std::memset(outSamples + validSamples, 0,
                static_cast<size_t>(totalSamples - validSamples) * sizeof(int16_t));
            pipelineShortfallPrev_ = true;
        } else if (pipelineShortfallPrev_) {
            constexpr int32_t SHORTFALL_FADE_SAMPLES = 128;
            const int32_t fadeSamples = std::min(SHORTFALL_FADE_SAMPLES, totalSamples);
            for (int32_t i = 0; i < fadeSamples; i++) {
                const double fadeGain = static_cast<double>(i + 1) / static_cast<double>(fadeSamples);
                outSamples[i] = static_cast<int16_t>(std::lround(
                    static_cast<double>(outSamples[i]) * fadeGain));
            }
            pipelineShortfallPrev_ = false;
        }
        pipelineRenderCalls_++;
        pipelineRenderReqBytes_ += static_cast<uint64_t>(audioDataSize);
        pipelineRenderRespBytes_ += static_cast<uint64_t>(produced);
        if (finished) {
            audioSuiteEofReached_ = true;
            MarkPlaybackCompleted();
        }
        return true;
    }

    bool RenderAudio(void* audioData, int32_t audioDataSize, bool usePipeline)
    {
        const bool pipelineActivated = usePipeline && !lastUsePipeline_;
        if (usePipeline != lastUsePipeline_) {
            // 直通 <-> 音效管线 切换：重置响度补偿，让新路径重新测量并快速收敛
            lastUsePipeline_ = usePipeline;
            ResetLoudnessCompensation();
        }
        if (!usePipeline) {
            // 音效全关走直通渲染：清空密度测量窗口，避免切回管线时沿用陈旧窗口，
            // 也确保直通路径不受管线期补偿倍数影响（ReadPcm 传 usePipeline=false）。
            inputWindowStartMs_ = 0;
            inputWindowFrames_ = 0;
            // 直通无拉取音调问题，保持态作废（carry 已过时，不再参与后续交叉淡化）
            pipelineHoldActive_.store(false);
            holdCarrySamples_ = 0;
            densityRetarget_ = 0;
            bool finished = false;
            int32_t readSize = ReadPcm(audioData, audioDataSize, &finished, false);
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
        // 管线激活翻转或效果开关请求 → 进入/延长直通保持期：可听输出走直通（音调恒定正确），
        // 管线喂静音完成拉取密度重测，收敛后交叉淡化切回管线输出，
        // 消除开关瞬间按旧密度因子喂源导致的倍速高音调/慢速低音调。
        if (pipelineActivated || pipelineHoldRequested_.exchange(false)) {
            if (!pipelineHoldActive_.exchange(true)) {
                OH_LOG_Print(LOG_APP, LOG_INFO, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                    "pipeline hold start (activation=%{public}d)", pipelineActivated ? 1 : 0);
            }
            holdStartMs_ = SteadyNowMs();
            // 保持期起点重测密度：丢弃陈旧窗口、滞回暂存与上一次保持的未应用目标档
            densityWindowResetRequested_.store(true);
            densityRetarget_ = 0;
        }
        if (pipelineHoldActive_.load()) {
            if (SteadyNowMs() - holdStartMs_ < PIPELINE_HOLD_MS) {
                // 保持帧：可听输出走直通渲染（不经过 !usePipeline 分支，密度窗口存活），
                // 末段存入 carry 供释放帧交叉淡化；管线预热渲染由 InputDataCallback
                // 的 hold 分支喂静音，只用于维持拉取节奏供密度测量
                bool finished = false;
                int32_t readSize = ReadPcm(audioData, audioDataSize, &finished, false);
                if (readSize < audioDataSize) {
                    std::memset(static_cast<uint8_t*>(audioData) + readSize, 0,
                        static_cast<size_t>(audioDataSize - readSize));
                }
                const int32_t totalSamples =
                    audioDataSize / static_cast<int32_t>(sizeof(int16_t));
                const int32_t carrySamples =
                    std::min(totalSamples, PIPELINE_HOLD_CARRY_SAMPLES);
                if (carrySamples > 0) {
                    std::memcpy(holdCarry_.data(),
                        static_cast<const int16_t*>(audioData) + (totalSamples - carrySamples),
                        static_cast<size_t>(carrySamples) * sizeof(int16_t));
                    holdCarrySamples_ = carrySamples;
                }
                if (finished) {
                    audioSuiteEofReached_ = true;
                    MarkPlaybackCompleted();
                }
                if (static_cast<size_t>(audioDataSize) / sizeof(int16_t) <= holdScratch_.size() &&
                    !audioSuiteEofReached_.load()) {
                    int32_t responseSize = 0;
                    bool warmupFinished = false;
                    std::lock_guard<std::mutex> lock(effectMutex_);
                    OH_AudioSuite_Result warmupResult = AUDIOSUITE_SUCCESS;
                    if (activePipeline_ == ActivePipeline::SEP) {
                        // 分离管线为多输出：预热必须走 MultiRenderFrame，否则拉取节奏无法被测量
                        const size_t warmupSamples =
                            (static_cast<size_t>(audioDataSize) + sizeof(int16_t) - 1) / sizeof(int16_t);
                        if (sepScratchA_.size() < warmupSamples) {
                            sepScratchA_.assign(warmupSamples, 0);
                        }
                        if (sepScratchB_.size() < warmupSamples) {
                            sepScratchB_.assign(warmupSamples, 0);
                        }
                        void* warmupBuffers[2] = { sepScratchA_.data(), sepScratchB_.data() };
                        OH_AudioDataArray warmupArray = {};
                        warmupArray.audioDataArray = warmupBuffers;
                        warmupArray.arraySize = 2;
                        warmupArray.requestFrameSize = audioDataSize;
                        warmupResult = OH_AudioSuiteEngine_MultiRenderFrame(
                            sepGroup_.pipeline, &warmupArray, &responseSize, &warmupFinished);
                    } else {
                        warmupResult = OH_AudioSuiteEngine_RenderFrame(
                            ActivePipelineHandle(), holdScratch_.data(), audioDataSize,
                            &responseSize, &warmupFinished);
                    }
                    if (warmupResult != AUDIOSUITE_SUCCESS) {
                        OH_LOG_Print(LOG_APP, LOG_ERROR, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                            "hold warmup render failed result=%{public}d",
                            static_cast<int>(warmupResult));
                    }
                }
                return true;
            }
            // 释放帧：保持期满，密度因子已按新拉取模式收敛。先清 hold 再渲染
            // （InputDataCallback 据此恢复真实拉取），头部与直通末段做 10ms 交叉淡化
            // 遮蔽「未处理 ↔ 处理」波形的相位跳变
            pipelineHoldActive_.store(false);
            ResetLoudnessCompensation();
            // 应用保持期确认的密度目标档：切换发生在静音预热之后、释放渲染之前，
            // 可听端（直通）全程无感，可闻路径上不存在因子切换
            if (densityRetarget_ != 0) {
                inputDensityFactor_.store(densityRetarget_);
                OH_LOG_Print(LOG_APP, LOG_INFO, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                    "input density factor -> %{public}d (hold retarget applied)",
                    densityRetarget_);
                densityRetarget_ = 0;
            }
            densityHoldLastMs_ = SteadyNowMs();
            if (!RenderPipelineFrame(audioData, audioDataSize)) {
                return false;
            }
            int16_t* outSamples = static_cast<int16_t*>(audioData);
            const int32_t totalSamples =
                audioDataSize / static_cast<int32_t>(sizeof(int16_t));
            const int32_t fadeSamples = std::min(holdCarrySamples_,
                std::min(PIPELINE_HOLD_CARRY_SAMPLES, totalSamples));
            for (int32_t i = 0; i < fadeSamples; i++) {
                const double fadeGain =
                    static_cast<double>(i + 1) / static_cast<double>(fadeSamples);
                outSamples[i] = static_cast<int16_t>(std::lround(
                    static_cast<double>(holdCarry_[i]) * (1.0 - fadeGain) +
                    static_cast<double>(outSamples[i]) * fadeGain));
            }
            holdCarrySamples_ = 0;
            OH_LOG_Print(LOG_APP, LOG_INFO, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                "pipeline hold release");
            return true;
        }
        return RenderPipelineFrame(audioData, audioDataSize);
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
        double squareSum = 0.0;
        for (int32_t i = 0; i < sampleCount; i++) {
            const double value = static_cast<double>(samples[i]);
            squareSum += value * value;
            inputPositiveFullScaleCount_.fetch_add(
                samples[i] == std::numeric_limits<int16_t>::max() ? 1 : 0, std::memory_order_relaxed);
            inputNegativeFullScaleCount_.fetch_add(
                samples[i] == std::numeric_limits<int16_t>::min() ? 1 : 0, std::memory_order_relaxed);
        }
        inputMeasurementSampleCount_.fetch_add(static_cast<uint64_t>(sampleCount),
            std::memory_order_relaxed);
        // 闭环响度补偿的参考电平：重采样后、未做任何衰减的源电平
        loudnessInputSumSquares_ += squareSum;
        loudnessInputSampleCount_ += static_cast<uint64_t>(sampleCount);
    }

    void ResetLoudnessCompensation()
    {
        loudnessTargetGain_.store(1.0);
        loudnessAppliedGain_ = 1.0;
        loudnessInputSumSquares_ = 0.0;
        loudnessInputSampleCount_ = 0;
        loudnessRawOutputSumSquares_ = 0.0;
        loudnessRawOutputSampleCount_ = 0;
        loudnessWindowStartMs_ = 0;
    }

    // 闭环响度补偿：先测「管线原始输出」RMS（补偿前），按固定时间窗与「输入参考 RMS」比较，
    // 反推补偿增益并逐采样平滑应用，最后硬限幅兜底。使开/关音效时的响度保持一致。
    void ApplyLoudnessCompensation(void* audioData, int32_t audioDataSize)
    {
        int16_t* samples = static_cast<int16_t*>(audioData);
        const int32_t sampleCount = audioDataSize / static_cast<int32_t>(sizeof(int16_t));
        if (samples == nullptr || sampleCount <= 0) {
            return;
        }
        double squareSum = 0.0;
        for (int32_t i = 0; i < sampleCount; i++) {
            const double value = static_cast<double>(samples[i]);
            squareSum += value * value;
        }
        loudnessRawOutputSumSquares_ += squareSum;
        loudnessRawOutputSampleCount_ += static_cast<uint64_t>(sampleCount);

        const int64_t nowMs = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now().time_since_epoch()).count();
        if (loudnessWindowStartMs_ == 0) {
            loudnessWindowStartMs_ = nowMs;
        } else if (nowMs - loudnessWindowStartMs_ >= LOUDNESS_WINDOW_MS &&
            loudnessInputSampleCount_ > 0 && loudnessRawOutputSampleCount_ > 0) {
            const double inputRms = std::sqrt(
                loudnessInputSumSquares_ / static_cast<double>(loudnessInputSampleCount_));
            const double outputRms = std::sqrt(
                loudnessRawOutputSumSquares_ / static_cast<double>(loudnessRawOutputSampleCount_));
            if (inputRms > LOUDNESS_MIN_REFERENCE_RMS && outputRms > 1.0) {
                const double target = std::clamp(inputRms / outputRms, LOUDNESS_MIN_GAIN, LOUDNESS_MAX_GAIN);
                const double current = loudnessTargetGain_.load();
                loudnessTargetGain_.store(current + (target - current) * LOUDNESS_WINDOW_SMOOTHING);
                OH_LOG_Print(LOG_APP, LOG_INFO, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                    "loudness comp inputRms=%{public}.1f outputRms=%{public}.1f target=%{public}.3f",
                    inputRms, outputRms, loudnessTargetGain_.load());
            }
            loudnessInputSumSquares_ = 0.0;
            loudnessInputSampleCount_ = 0;
            loudnessRawOutputSumSquares_ = 0.0;
            loudnessRawOutputSampleCount_ = 0;
            loudnessWindowStartMs_ = nowMs;
        }

        const double targetGain = loudnessTargetGain_.load();
        double gain = loudnessAppliedGain_;
        // 软限幅：增益 >1 时满刻度音乐峰直接硬 clamp 到 int16 会平顶削波，本身就是
        // 可闻毛刺源。超过起控点后改走 tanh 软膝渐进逼近 ±32767：起控点以下完全透明，
        // 膝内斜率连续（无拐点爆音），渐近限幅永不削平顶。
        const double kneeSpan = static_cast<double>(std::numeric_limits<int16_t>::max()) -
            LOUDNESS_SOFT_KNEE_START;
        for (int32_t i = 0; i < sampleCount; i++) {
            gain += (targetGain - gain) * LOUDNESS_GAIN_SMOOTHING;
            const double scaled = static_cast<double>(samples[i]) * gain;
            double limited = scaled;
            if (scaled > LOUDNESS_SOFT_KNEE_START) {
                limited = LOUDNESS_SOFT_KNEE_START +
                    kneeSpan * std::tanh((scaled - LOUDNESS_SOFT_KNEE_START) / kneeSpan);
            } else if (scaled < -LOUDNESS_SOFT_KNEE_START) {
                limited = -(LOUDNESS_SOFT_KNEE_START +
                    kneeSpan * std::tanh((-scaled - LOUDNESS_SOFT_KNEE_START) / kneeSpan));
            }
            const long converted = std::lround(limited);
            samples[i] = static_cast<int16_t>(std::clamp<long>(converted,
                std::numeric_limits<int16_t>::min(), std::numeric_limits<int16_t>::max()));
        }
        loudnessAppliedGain_ = gain;
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
            const uint64_t inputClipped = inputPositiveFullScaleCount_.load(std::memory_order_relaxed) +
                inputNegativeFullScaleCount_.load(std::memory_order_relaxed);
            const uint64_t outputClipped = outputPositiveFullScaleCount_ + outputNegativeFullScaleCount_;
            const double rms = std::sqrt(
                measurementSquareSum_ / static_cast<double>(measurementSampleCount_));
            const uint64_t inputMeasured = inputMeasurementSampleCount_.load(std::memory_order_relaxed);
            const double inputClipRatio = inputMeasured == 0 ? 0.0 :
                static_cast<double>(inputClipped) * 100.0 / static_cast<double>(inputMeasured);
            const double outputClipRatio = static_cast<double>(outputClipped) * 100.0 /
                static_cast<double>(measurementSampleCount_);
            OH_LOG_Print(LOG_APP, LOG_INFO, UPLAYER_LOG_DOMAIN, UPLAYER_LOG_TAG,
                "audio level eq=%{public}d peak=%{public}d rms=%{public}.1f "
                "inputClip=%{public}llu(%{public}.4f%%) outputClip=%{public}llu(%{public}.4f%%) "
                "loudnessGain=%{public}.3f",
                equalizerEnabled ? 1 : 0, measurementPeak_, rms,
                static_cast<unsigned long long>(inputClipped), inputClipRatio,
                static_cast<unsigned long long>(outputClipped), outputClipRatio,
                loudnessTargetGain_.load());
            measurementSquareSum_ = 0.0;
            measurementSampleCount_ = 0;
            measurementPeak_ = 0;
            inputMeasurementSampleCount_.store(0, std::memory_order_relaxed);
            inputPositiveFullScaleCount_.store(0, std::memory_order_relaxed);
            inputNegativeFullScaleCount_.store(0, std::memory_order_relaxed);
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
    // 三组管线：主管线（6 个全格式兼容效果节点，始终可用）、
    // 特殊管线（主链 + 降噪/传统变声/变速变调，按需启动）、分离管线（音源分离多输出节点）。
    // activePipeline_ 标记当前活跃组，渲染线程与效果开关线程均在 effectMutex_ 保护下读写。
    PipelineGroup mainGroup_;
    PipelineGroup specialGroup_;
    PipelineGroup sepGroup_;
    OH_AudioNode* sepNode_ = nullptr;
    ActivePipeline activePipeline_ = ActivePipeline::NONE;
    // 特殊/分离管线是否创建成功（设备不支持对应节点时置 false，启用时静默保持主管线）
    bool specialPipelineUsable_ = false;
    bool sepPipelineUsable_ = false;
    // 音源分离双路输出暂存（MultiRenderFrame 的人声/伴奏缓冲，字节宽度同渲染帧）
    std::vector<int16_t> sepScratchA_;
    std::vector<int16_t> sepScratchB_;
    uint32_t trackIndex_ = 0;
    int32_t sampleRate_ = 48000;
    int32_t channelCount_ = 2;
    int64_t durationUs_ = 0;
    std::string mime_;
    std::thread decoderThread_;
    std::thread renderThread_;
    // 渲染工作线程 + 环形缓冲（SPSC：工作线程写、RT 回调读）。ringMutex_ 只保护指针
    // 移动与数据拷贝，绝不为等待 IPC/队列而持有，也绝不与 effectMutex_/queueMutex_ 嵌套。
    std::mutex ringMutex_;
    std::condition_variable ringCondition_;
    std::vector<int16_t> ringBuffer_;
    std::vector<int16_t> renderChunkBuf_;
    size_t ringWritePos_ = 0;
    size_t ringReadPos_ = 0;
    size_t ringFilled_ = 0;
    std::atomic<bool> renderStopRequested_ = true;
    std::atomic<uint64_t> ringUnderrunCount_ = 0;
    int64_t ringUnderrunLastLogMs_ = 0;
    int16_t ringUnderrunLastSample_ = 0;
    uint64_t renderChunkSlowCount_ = 0;
    std::mutex queueMutex_;
    std::condition_variable queueCondition_;
    std::deque<uint8_t> pcmQueue_;
    const size_t maxQueueBytes_ = 48000 * 2 * 2;
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
    // 新增效果节点状态（通用变声/降噪/传统变声/变速变调/音源分离）
    std::atomic<bool> requestedGeneralVoiceChangeEnabled_ = false;
    std::atomic<int32_t> generalVoiceChangeType_ = 1;      // 1..10，见 OH_AudioSuite_GeneralVoiceChangeType
    std::atomic<bool> requestedNoiseReductionEnabled_ = false;
    std::atomic<bool> requestedPureVoiceChangeEnabled_ = false;
    std::atomic<int32_t> pureVoiceChangeGender_ = 1;       // 1=女声 2=男声
    std::atomic<int32_t> pureVoiceChangeType_ = 1;         // 1..7，见 OH_AudioSuite_PureVoiceChangeType
    std::atomic<float> pureVoiceChangePitch_ = 0.0f;       // 0=系统推荐（OH_PURE_VOICE_DEFAULT_PITCH），自定义 [0.3,3.0]
    std::atomic<bool> requestedTempoPitchEnabled_ = false;
    std::atomic<float> tempoSpeed_ = 1.0f;                 // [0.5,10.0]
    std::atomic<float> tempoPitch_ = 1.0f;                 // [0.1,5.0]
    std::atomic<bool> requestedSeparationEnabled_ = false;
    std::atomic<int32_t> separationOutput_ = 1;            // 1=仅人声 2=仅伴奏 3=人声+伴奏混合
    // JS 线程 SetSpeed 写、渲染回调 MeasureInputDensity 读，必须原子
    std::atomic<float> playbackSpeed_ = 1.0f;
    float volume_ = 1.0f;
    double measurementSquareSum_ = 0.0;
    uint64_t measurementSampleCount_ = 0;
    // 输入测量由渲染工作线程写（InputDataCallback→MeasureInput），RT 回调读+复位
    // （MeasureOutput），跨线程必须原子；其余测量字段单线程私有
    std::atomic<uint64_t> inputMeasurementSampleCount_ = 0;
    std::atomic<uint64_t> inputPositiveFullScaleCount_ = 0;
    std::atomic<uint64_t> inputNegativeFullScaleCount_ = 0;
    uint64_t outputPositiveFullScaleCount_ = 0;
    uint64_t outputNegativeFullScaleCount_ = 0;
    int32_t measurementPeak_ = 0;
    // 管线数据流诊断：对比管线输入拉取量与 RenderFrame 输出量是否守恒（采样率错配定位）
    std::atomic<uint64_t> pipelineInputCalls_ = 0;
    std::atomic<uint64_t> pipelineInputBytes_ = 0;
    std::atomic<bool> pipelineInputFirstLogged_ = false;
    uint64_t pipelineRenderCalls_ = 0;
    uint64_t pipelineRenderReqBytes_ = 0;
    uint64_t pipelineRenderRespBytes_ = 0;
    bool pipelineRenderFirstLogged_ = false;
    bool pipelineShortfallPrev_ = false;
    int64_t pipelineStatsBaseMs_ = 0;
    int64_t pipelineLastLogMs_ = 0;
    // 闭环响度补偿状态：目标增益跨线程读写（原子），应用增益与窗口累加仅渲染线程访问
    std::atomic<double> loudnessTargetGain_ = 1.0;
    double loudnessAppliedGain_ = 1.0;
    double loudnessInputSumSquares_ = 0.0;
    uint64_t loudnessInputSampleCount_ = 0;
    double loudnessRawOutputSumSquares_ = 0.0;
    uint64_t loudnessRawOutputSampleCount_ = 0;
    int64_t loudnessWindowStartMs_ = 0;
    bool lastUsePipeline_ = false;
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
    // 采样率状态：解码器输出源采样率 PCM，均衡器管线固定 48000
    int32_t resampleInputRate_ = 44100;
    int32_t resampleOutputRate_ = 48000;
    // 密度自适应：OHAudioSuite 管线对输入按 N 倍速率拉取（实测为 1 或 2）。
    // 拉取 N 倍时把源转换到 48000×N，使源按实时速率推进，消除 2× 拉取导致的倍速/变调。
    // 仅在管线路径生效（ReadPcm 的 usePipeline 参数），直通渲染恒按 48000 推进。
    // 渲染线程与管线输入回调线程都会访问，必须原子。
    std::atomic<int32_t> inputDensityFactor_ = 1;
    uint64_t inputWindowFrames_ = 0;
    int64_t inputWindowStartMs_ = 0;
    // 管线直通保持状态：效果开关/管线激活瞬间拉取模式突变，旧密度因子未收敛前按旧速率
    // 喂源会产生倍速高音调/慢速低音调。holdActive 与请求位跨线程（NAPI 开关线程 ↔ 渲染
    // 线程）须原子；holdStartMs_/carry 为渲染线程私有。
    std::atomic<bool> pipelineHoldActive_ = false;
    std::atomic<bool> pipelineHoldRequested_ = false;
    std::atomic<bool> densityWindowResetRequested_ = false;
    int64_t holdStartMs_ = 0;
    int32_t holdCarrySamples_ = 0;
    std::vector<int16_t> holdScratch_;
    std::vector<int16_t> holdCarry_;
    int32_t densityPendingCandidate_ = 0;
    int32_t densityPendingCount_ = 0;
    // 密度目标档与自动保护冷却：retarget 仅在保持期内确认记录、释放帧应用（渲染线程私有）；
    // densityHoldLastMs_ 记录上次释放时刻，播放中漂移触发的自动保护受冷却限制防频繁闪断
    int32_t densityRetarget_ = 0;
    int64_t densityHoldLastMs_ = 0;
    // 官方 OH_AudioConverter 句柄（libohaudiosuite.so，API 26）：替代自写线性插值重采样。
    // 只在渲染线程 / 管线输入回调线程内由 ReadPcm 与 EnsureConverter 独占访问。
    OH_AudioConverter* converter_ = nullptr;
    int32_t converterInputRate_ = 0;
    int32_t converterOutputRate_ = 0;
    std::vector<uint8_t> converterInputBuf_ = {};
    std::atomic<bool> converterInputFinished_ = false;
    bool converterRateWarned_ = false;
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

napi_value SetGeneralVoiceChangeEnable(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    bool enabled = false;
    if (argc != 1 || napi_get_value_bool(env, args[0], &enabled) != napi_ok) {
        return BooleanValue(env, false);
    }
    return BooleanValue(env, NativeAudioPlayer::Instance().SetGeneralVoiceChangeEnabled(enabled));
}

napi_value SetGeneralVoiceChangeType(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t type = 0;
    if (argc != 1 || napi_get_value_int32(env, args[0], &type) != napi_ok) {
        return BooleanValue(env, false);
    }
    return BooleanValue(env, NativeAudioPlayer::Instance().SetGeneralVoiceChangeType(type));
}

napi_value SetNoiseReductionEnable(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    bool enabled = false;
    if (argc != 1 || napi_get_value_bool(env, args[0], &enabled) != napi_ok) {
        return BooleanValue(env, false);
    }
    return BooleanValue(env, NativeAudioPlayer::Instance().SetNoiseReductionEnabled(enabled));
}

napi_value SetPureVoiceChangeEnable(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    bool enabled = false;
    if (argc != 1 || napi_get_value_bool(env, args[0], &enabled) != napi_ok) {
        return BooleanValue(env, false);
    }
    return BooleanValue(env, NativeAudioPlayer::Instance().SetPureVoiceChangeEnabled(enabled));
}

napi_value SetPureVoiceChangeConfig(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value args[3] = { nullptr, nullptr, nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t gender = 0;
    int32_t type = 0;
    double pitch = 0;
    if (argc != 3 || napi_get_value_int32(env, args[0], &gender) != napi_ok ||
        napi_get_value_int32(env, args[1], &type) != napi_ok ||
        napi_get_value_double(env, args[2], &pitch) != napi_ok) {
        return BooleanValue(env, false);
    }
    return BooleanValue(env, NativeAudioPlayer::Instance().SetPureVoiceChangeConfig(
        gender, type, static_cast<float>(pitch)));
}

napi_value SetTempoPitchEnable(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    bool enabled = false;
    if (argc != 1 || napi_get_value_bool(env, args[0], &enabled) != napi_ok) {
        return BooleanValue(env, false);
    }
    return BooleanValue(env, NativeAudioPlayer::Instance().SetTempoPitchEnabled(enabled));
}

napi_value SetTempoPitchConfig(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = { nullptr, nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    double speed = 1;
    double pitch = 1;
    if (argc != 2 || napi_get_value_double(env, args[0], &speed) != napi_ok ||
        napi_get_value_double(env, args[1], &pitch) != napi_ok) {
        return BooleanValue(env, false);
    }
    return BooleanValue(env, NativeAudioPlayer::Instance().SetTempoPitchConfig(
        static_cast<float>(speed), static_cast<float>(pitch)));
}

napi_value SetSeparationEnable(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    bool enabled = false;
    if (argc != 1 || napi_get_value_bool(env, args[0], &enabled) != napi_ok) {
        return BooleanValue(env, false);
    }
    return BooleanValue(env, NativeAudioPlayer::Instance().SetSeparationEnabled(enabled));
}

napi_value SetSeparationOutput(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t output = 0;
    if (argc != 1 || napi_get_value_int32(env, args[0], &output) != napi_ok) {
        return BooleanValue(env, false);
    }
    return BooleanValue(env, NativeAudioPlayer::Instance().SetSeparationOutput(output));
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

// ===== ID3 标签写入：编辑歌曲信息时真实修改源 MP3 文件的 ID3v2 标签 =====
// 官方 AVMetadataExtractor 只读不写，故在 native 层实现 ID3v2 标签重建：
// 解析旧标签保留未编辑帧（含封面，v2.2 PIC 自动转 v2.3 APIC），
// 按 16 个可编辑字段重建 ID3v2.3 标签后整区域替换，音频数据按位移平。
constexpr uint32_t ID3_MAX_TAG_BYTES = 32 * 1024 * 1024;

struct Id3Frame {
    std::string id;
    std::vector<uint8_t> content;
};

struct Id3TagMapping {
    const char* key;
    const char* frameId;
    uint8_t kind; // 0=文本帧 1=COMM(空描述) 2=TXXX(固定描述 "description")
};

constexpr Id3TagMapping ID3_TAG_MAPPINGS[] = {
    { "title", "TIT2", 0 },    { "artist", "TPE1", 0 },    { "album", "TALB", 0 },
    { "genre", "TCON", 0 },    { "year", "TYER", 0 },      { "track", "TRCK", 0 },
    { "disc", "TPOS", 0 },     { "composer", "TCOM", 0 },  { "albumArtist", "TPE2", 0 },
    { "author", "TEXT", 0 },   { "language", "TLAN", 0 },  { "dateTime", "TDRC", 0 },
    { "encoder", "TSSE", 0 },  { "comment", "COMM", 1 },   { "conductor", "TPE3", 0 },
    { "description", "TXXX", 2 },
};

napi_value StringValue(napi_env env, const std::string& value)
{
    napi_value result = nullptr;
    napi_create_string_utf8(env, value.c_str(), value.size(), &result);
    return result;
}

static uint32_t Id3SyncSafeDecode(const uint8_t* value)
{
    return (static_cast<uint32_t>(value[0]) << 21) | (static_cast<uint32_t>(value[1]) << 14) |
        (static_cast<uint32_t>(value[2]) << 7) | static_cast<uint32_t>(value[3]);
}

static void AppendU32Be(std::vector<uint8_t>& out, uint32_t value)
{
    out.push_back(static_cast<uint8_t>((value >> 24) & 0xFF));
    out.push_back(static_cast<uint8_t>((value >> 16) & 0xFF));
    out.push_back(static_cast<uint8_t>((value >> 8) & 0xFF));
    out.push_back(static_cast<uint8_t>(value & 0xFF));
}

// UTF-8 → UTF-16LE（带 BOM）：完整处理代理对，非法序列替换 U+FFFD
static void AppendUtf16Le(std::vector<uint8_t>& out, const std::string& text)
{
    out.push_back(0xFF);
    out.push_back(0xFE);
    size_t i = 0;
    while (i < text.size()) {
        const unsigned char lead = static_cast<unsigned char>(text[i]);
        uint32_t codePoint = 0xFFFD;
        uint32_t extra = 0;
        if (lead < 0x80) {
            codePoint = lead;
        } else if ((lead & 0xE0) == 0xC0) {
            codePoint = lead & 0x1F;
            extra = 1;
        } else if ((lead & 0xF0) == 0xE0) {
            codePoint = lead & 0x0F;
            extra = 2;
        } else if ((lead & 0xF8) == 0xF0) {
            codePoint = lead & 0x07;
            extra = 3;
        }
        if (extra > 0) {
            if (i + extra >= text.size()) {
                codePoint = 0xFFFD;
                extra = 0;
            } else {
                for (uint32_t k = 1; k <= extra; k++) {
                    if ((static_cast<unsigned char>(text[i + k]) & 0xC0) != 0x80) {
                        codePoint = 0xFFFD;
                        extra = 0;
                        break;
                    }
                    codePoint = (codePoint << 6) | (static_cast<unsigned char>(text[i + k]) & 0x3F);
                }
            }
        }
        if (codePoint > 0x10FFFF || (codePoint >= 0xD800 && codePoint <= 0xDFFF)) {
            codePoint = 0xFFFD;
        }
        if (codePoint <= 0xFFFF) {
            out.push_back(static_cast<uint8_t>(codePoint & 0xFF));
            out.push_back(static_cast<uint8_t>((codePoint >> 8) & 0xFF));
        } else {
            const uint32_t offset = codePoint - 0x10000;
            const uint32_t high = 0xD800 + (offset >> 10);
            const uint32_t low = 0xDC00 + (offset & 0x3FF);
            out.push_back(static_cast<uint8_t>(high & 0xFF));
            out.push_back(static_cast<uint8_t>((high >> 8) & 0xFF));
            out.push_back(static_cast<uint8_t>(low & 0xFF));
            out.push_back(static_cast<uint8_t>((low >> 8) & 0xFF));
        }
        i += extra + 1;
    }
}

// 读取以编码对应终止符结尾的字符串（COMM/TXXX 描述字段），仅保留 ASCII 近似值用于比较
static bool ReadTerminatedStringAscii(const uint8_t* data, size_t size, size_t start, uint8_t encoding,
    std::string& out, size_t& endOffset)
{
    out.clear();
    if (start > size) {
        return false;
    }
    if (encoding == 0 || encoding == 3) {
        size_t cursor = start;
        while (cursor < size && data[cursor] != 0) {
            if (out.size() < 128) {
                out.push_back(static_cast<char>(data[cursor]));
            }
            cursor++;
        }
        if (cursor >= size) {
            return false;
        }
        endOffset = cursor + 1;
        return true;
    }
    if (encoding == 1 || encoding == 2) {
        size_t cursor = start;
        while (cursor + 1 < size && !(data[cursor] == 0 && data[cursor + 1] == 0)) {
            const uint16_t unit = encoding == 1
                ? static_cast<uint16_t>(data[cursor] | (static_cast<uint16_t>(data[cursor + 1]) << 8))
                : static_cast<uint16_t>((static_cast<uint16_t>(data[cursor]) << 8) | data[cursor + 1]);
            if (out.size() < 128) {
                out.push_back(unit < 0x80 ? static_cast<char>(unit) : '?');
            }
            cursor += 2;
        }
        if (cursor + 1 >= size) {
            return false;
        }
        endOffset = cursor + 2;
        return true;
    }
    return false;
}

// COMM 帧是否为空描述（语言 3 字节后的描述字段为空）
static bool CommentDescriptionEmpty(const uint8_t* content, uint32_t size)
{
    if (size < 4) {
        return false;
    }
    std::string description;
    size_t endOffset = 0;
    return ReadTerminatedStringAscii(content, size, 4, content[0], description, endOffset) &&
        description.empty();
}

// v2.2 PIC → v2.3 APIC：保留封面（图像格式 JPG/PNG → MIME）
static bool ConvertPicToApic(const uint8_t* frame, uint32_t frameSize, std::vector<uint8_t>& content)
{
    if (frameSize < 6) {
        return false;
    }
    const uint8_t* payload = frame + 6;
    const uint32_t size = frameSize - 6;
    if (size < 5) {
        return false;
    }
    const uint8_t encoding = payload[0];
    const std::string mime = (payload[1] == 'P' && payload[2] == 'N' && payload[3] == 'G')
        ? "image/png" : "image/jpeg";
    size_t cursor = 4; // encoding(1) + 图像格式(3)
    if (encoding == 1 || encoding == 2) {
        while (cursor + 1 < size && !(payload[cursor] == 0 && payload[cursor + 1] == 0)) {
            cursor += 2;
        }
        cursor += 2;
    } else {
        while (cursor < size && payload[cursor] != 0) {
            cursor++;
        }
        cursor++;
    }
    if (cursor > size) {
        return false;
    }
    content.push_back(encoding);
    content.insert(content.end(), mime.begin(), mime.end());
    content.push_back(0);
    content.push_back(payload[4]); // 图片类型
    content.insert(content.end(), payload + 5, payload + cursor); // 原描述（含终止符）
    content.insert(content.end(), payload + cursor, payload + size); // 图片数据
    return true;
}

// 按 delta 平移 [regionStart, fileSize) 音频数据（1MB 分块 pread/pwrite），调用方负责 ftruncate
static bool ShiftRegion(int32_t fd, uint64_t regionStart, uint64_t fileSize, int64_t delta)
{
    if (delta == 0 || regionStart >= fileSize) {
        return true;
    }
    constexpr size_t CHUNK_BYTES = 1024 * 1024;
    std::vector<uint8_t> buffer(CHUNK_BYTES);
    if (delta > 0) {
        uint64_t remaining = fileSize - regionStart;
        while (remaining > 0) {
            const size_t chunk = remaining < CHUNK_BYTES ? static_cast<size_t>(remaining) : CHUNK_BYTES;
            const uint64_t source = regionStart + remaining - chunk;
            if (pread(fd, buffer.data(), chunk, source) != static_cast<ssize_t>(chunk) ||
                pwrite(fd, buffer.data(), chunk, source + delta) != static_cast<ssize_t>(chunk)) {
                return false;
            }
            remaining -= chunk;
        }
        return true;
    }
    uint64_t remaining = fileSize - regionStart;
    uint64_t offset = regionStart;
    while (remaining > 0) {
        const size_t chunk = remaining < CHUNK_BYTES ? static_cast<size_t>(remaining) : CHUNK_BYTES;
        if (pread(fd, buffer.data(), chunk, offset) != static_cast<ssize_t>(chunk) ||
            pwrite(fd, buffer.data(), chunk, offset + delta) != static_cast<ssize_t>(chunk)) {
            return false;
        }
        remaining -= chunk;
        offset += chunk;
    }
    return true;
}

static void AppendFrameHeader(std::vector<uint8_t>& out, const char* frameId, size_t contentSize)
{
    for (const char* p = frameId; *p != '\0'; p++) {
        out.push_back(static_cast<uint8_t>(*p));
    }
    AppendU32Be(out, static_cast<uint32_t>(contentSize));
    out.push_back(0);
    out.push_back(0);
}

static void BuildTextFrame(std::vector<uint8_t>& out, const char* frameId, const std::string& value)
{
    std::vector<uint8_t> content;
    content.push_back(0x01); // UTF-16 编码
    AppendUtf16Le(content, value);
    content.push_back(0x00);
    content.push_back(0x00); // 文本终止符
    AppendFrameHeader(out, frameId, content.size());
    out.insert(out.end(), content.begin(), content.end());
}

static void BuildCommentFrame(std::vector<uint8_t>& out, const std::string& value)
{
    std::vector<uint8_t> content;
    content.push_back(0x01);
    content.push_back('e');
    content.push_back('n');
    content.push_back('g');
    content.push_back(0x00);
    content.push_back(0x00); // 空描述终止符
    AppendUtf16Le(content, value);
    AppendFrameHeader(out, "COMM", content.size());
    out.insert(out.end(), content.begin(), content.end());
}

static void BuildUserTextFrame(std::vector<uint8_t>& out, const std::string& description,
    const std::string& value)
{
    std::vector<uint8_t> content;
    content.push_back(0x01);
    AppendUtf16Le(content, description);
    content.push_back(0x00);
    content.push_back(0x00); // 描述终止符
    AppendUtf16Le(content, value);
    AppendFrameHeader(out, "TXXX", content.size());
    out.insert(out.end(), content.begin(), content.end());
}

// 核心写入：返回空串 = 成功；"unsupported" 开头 = 文件格式不支持；其他 = 错误描述
static std::string WriteId3TagsToFd(int32_t fd, const std::map<std::string, std::string>& tags)
{
    struct stat fileStat = {};
    if (fd < 0 || fstat(fd, &fileStat) != 0 || fileStat.st_size < 4) {
        return "stat failed";
    }
    const uint64_t fileSize = static_cast<uint64_t>(fileStat.st_size);
    uint8_t header[10] = {};
    const bool hasId3 = fileSize >= 10 && pread(fd, header, sizeof(header), 0) == sizeof(header) &&
        std::memcmp(header, "ID3", 3) == 0;
    uint64_t oldRegionEnd = 0;
    std::vector<Id3Frame> keptFrames;
    if (hasId3) {
        const uint8_t version = header[3];
        const uint8_t flags = header[5];
        const uint32_t tagSize = Id3SyncSafeDecode(header + 6);
        if (version != 2 && version != 3 && version != 4) {
            return "unsupported: id3v2." + std::to_string(version);
        }
        if (tagSize == 0 || tagSize > ID3_MAX_TAG_BYTES ||
            static_cast<uint64_t>(tagSize) + 10 > fileSize) {
            return "corrupt tag size";
        }
        if ((flags & 0x80) != 0) {
            return "unsupported: unsynchronized tag";
        }
        oldRegionEnd = 10 + tagSize + ((flags & 0x10) != 0 ? 10 : 0); // footer 计入旧区域
        if (oldRegionEnd > fileSize) {
            return "corrupt tag region";
        }
        std::vector<uint8_t> tag(tagSize);
        if (pread(fd, tag.data(), tag.size(), 10) != static_cast<ssize_t>(tag.size())) {
            return "read tag failed";
        }
        size_t offset = 0;
        if ((flags & 0x40) != 0 && tag.size() >= 4) {
            // 扩展头：跳过（重建后的标签不再生成）
            const uint32_t extendedSize = version == 4 ? Id3SyncSafeDecode(tag.data()) :
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
                (version == 4 ? Id3SyncSafeDecode(frame + 4) :
                    (static_cast<uint32_t>(frame[4]) << 24) | (static_cast<uint32_t>(frame[5]) << 16) |
                        (static_cast<uint32_t>(frame[6]) << 8) | static_cast<uint32_t>(frame[7]));
            if (frameSize == 0 || offset + frameHeaderSize + frameSize > tag.size()) {
                break;
            }
            if (version == 2) {
                // v2.2 仅保留封面（PIC → APIC），其余旧格式帧丢弃
                if (std::memcmp(frame, "PIC", 3) == 0) {
                    Id3Frame apic;
                    apic.id = "APIC";
                    if (ConvertPicToApic(frame, frameSize, apic.content)) {
                        keptFrames.push_back(apic);
                    }
                }
            } else {
                const std::string id(reinterpret_cast<const char*>(frame), 4);
                const uint8_t* content = frame + 10;
                bool replaced = false;
                for (const Id3TagMapping& mapping : ID3_TAG_MAPPINGS) {
                    if (std::memcmp(mapping.frameId, frame, 4) != 0) {
                        continue;
                    }
                    if (tags.find(mapping.key) == tags.end()) {
                        break; // 未提供的键不动旧帧
                    }
                    if (mapping.kind == 0) {
                        replaced = true;
                    } else if (mapping.kind == 1) {
                        replaced = CommentDescriptionEmpty(content, frameSize);
                    } else {
                        std::string description;
                        size_t endOffset = 0;
                        replaced = ReadTerminatedStringAscii(content, frameSize, 1, content[0],
                            description, endOffset) && description == "description";
                    }
                    break;
                }
                if (!replaced) {
                    keptFrames.push_back(
                        { id, std::vector<uint8_t>(content, content + frameSize) });
                }
            }
            offset += frameHeaderSize + frameSize;
        }
    } else {
        // 无 ID3 头：仅当疑似 MPEG 音频帧同步时前置新标签，避免误写 FLAC/M4A 等
        uint8_t probe[4] = {};
        const size_t probeSize = fileSize < 4 ? static_cast<size_t>(fileSize) : 4;
        if (pread(fd, probe, probeSize, 0) != static_cast<ssize_t>(probeSize)) {
            return "read file failed";
        }
        if (probe[0] != 0xFF || (probe[1] & 0xE0) != 0xE0) {
            return "unsupported: not mp3";
        }
    }

    // 重建 ID3v2.3 标签：保留帧在前，16 个编辑键按映射顺序追加
    std::vector<uint8_t> body;
    for (const Id3Frame& kept : keptFrames) {
        body.insert(body.end(), kept.id.begin(), kept.id.end());
        AppendU32Be(body, static_cast<uint32_t>(kept.content.size()));
        body.push_back(0);
        body.push_back(0);
        body.insert(body.end(), kept.content.begin(), kept.content.end());
    }
    for (const Id3TagMapping& mapping : ID3_TAG_MAPPINGS) {
        const auto found = tags.find(mapping.key);
        if (found == tags.end() || found->second.empty()) {
            continue; // 空值 = 删除对应帧
        }
        if (mapping.kind == 0) {
            BuildTextFrame(body, mapping.frameId, found->second);
        } else if (mapping.kind == 1) {
            BuildCommentFrame(body, found->second);
        } else {
            BuildUserTextFrame(body, "description", found->second);
        }
    }
    if (body.size() > 0x0FFFFFFF) {
        return "tag too large";
    }
    std::vector<uint8_t> newTag;
    newTag.push_back('I');
    newTag.push_back('D');
    newTag.push_back('3');
    newTag.push_back(3); // ID3v2.3
    newTag.push_back(0);
    newTag.push_back(0); // flags：无 unsync/扩展头/footer
    newTag.push_back(static_cast<uint8_t>((body.size() >> 21) & 0x7F));
    newTag.push_back(static_cast<uint8_t>((body.size() >> 14) & 0x7F));
    newTag.push_back(static_cast<uint8_t>((body.size() >> 7) & 0x7F));
    newTag.push_back(static_cast<uint8_t>(body.size() & 0x7F));
    newTag.insert(newTag.end(), body.begin(), body.end());

    const int64_t delta = static_cast<int64_t>(newTag.size()) - static_cast<int64_t>(oldRegionEnd);
    if (delta != 0) {
        if (!ShiftRegion(fd, oldRegionEnd, fileSize, delta)) {
            return "shift audio data failed";
        }
        if (ftruncate(fd, static_cast<off_t>(fileSize) + delta) != 0) {
            return "truncate failed";
        }
    }
    if (pwrite(fd, newTag.data(), newTag.size(), 0) != static_cast<ssize_t>(newTag.size())) {
        return "write tag failed";
    }
    if (fsync(fd) != 0) {
        return "fsync failed";
    }
    return "";
}

// ===== FLAC Vorbis Comment 写入 =====
// FLAC 结构：fLaC 魔数 + 元数据块序列（块头 1 字节 last/type + 24 位大端长度）。
// 重建：STREAMINFO 原样 + 新 VORBIS_COMMENT(4) + 其余块保留（PADDING(1)/旧 VORBIS_COMMENT 丢弃）
// + 尾部 PADDING 块（预留 4KB，降低下次编辑的平移量），整区域替换。

static void AppendU32Le(std::vector<uint8_t>& out, uint32_t value)
{
    out.push_back(static_cast<uint8_t>(value & 0xFF));
    out.push_back(static_cast<uint8_t>((value >> 8) & 0xFF));
    out.push_back(static_cast<uint8_t>((value >> 16) & 0xFF));
    out.push_back(static_cast<uint8_t>((value >> 24) & 0xFF));
}

static void FlacAppendComment(std::vector<uint8_t>& out, const std::string& key, const std::string& value)
{
    const std::string entry = key + "=" + value;
    AppendU32Le(out, static_cast<uint32_t>(entry.size()));
    out.insert(out.end(), entry.begin(), entry.end());
}

static std::string TagValue(const std::map<std::string, std::string>& tags, const char* key)
{
    const auto found = tags.find(key);
    return found == tags.end() ? std::string() : found->second;
}

static std::string WriteFlacTagsToFd(int32_t fd, const std::map<std::string, std::string>& tags)
{
    struct stat fileStat = {};
    if (fstat(fd, &fileStat) != 0 || fileStat.st_size < 8) {
        return "stat failed";
    }
    const uint64_t fileSize = static_cast<uint64_t>(fileStat.st_size);
    uint8_t magic[4] = {};
    if (pread(fd, magic, sizeof(magic), 0) != sizeof(magic) || std::memcmp(magic, "fLaC", 4) != 0) {
        return "unsupported: not flac";
    }
    uint64_t offset = 4;
    bool last = false;
    bool hasStreamInfo = false;
    std::vector<uint8_t> streamInfo;
    std::vector<std::pair<uint8_t, std::vector<uint8_t>>> otherBlocks;
    while (!last) {
        if (offset + 4 > fileSize || otherBlocks.size() > 64) {
            return "corrupt flac blocks";
        }
        uint8_t blockHeader[4] = {};
        if (pread(fd, blockHeader, sizeof(blockHeader), offset) != sizeof(blockHeader)) {
            return "read flac block failed";
        }
        last = (blockHeader[0] & 0x80) != 0;
        const uint8_t type = blockHeader[0] & 0x7F;
        const uint32_t size = (static_cast<uint32_t>(blockHeader[1]) << 16) |
            (static_cast<uint32_t>(blockHeader[2]) << 8) | static_cast<uint32_t>(blockHeader[3]);
        if (size > ID3_MAX_TAG_BYTES || offset + 4 + size > fileSize) {
            return "corrupt flac block size";
        }
        std::vector<uint8_t> data(size);
        if (size > 0 && pread(fd, data.data(), size, offset + 4) != static_cast<ssize_t>(size)) {
            return "read flac block failed";
        }
        if (type == 0) { // STREAMINFO
            streamInfo = data;
            hasStreamInfo = true;
        } else if (type != 1 && type != 4) { // PADDING / VORBIS_COMMENT 重建时丢弃
            otherBlocks.push_back({ type, data });
        }
        offset += 4 + size;
    }
    if (!hasStreamInfo || streamInfo.size() != 34) {
        return "corrupt flac: streaminfo";
    }
    const uint64_t oldRegionEnd = offset;

    // VORBIS_COMMENT 内容：厂商串 + 键值对（小端 u32 长度前缀，KEY=value UTF-8）
    std::vector<uint8_t> comment;
    const std::string vendor = "UPlayer";
    AppendU32Le(comment, static_cast<uint32_t>(vendor.size()));
    comment.insert(comment.end(), vendor.begin(), vendor.end());
    std::vector<std::pair<std::string, std::string>> entries;
    const std::string title = TagValue(tags, "title");
    if (!title.empty()) entries.push_back({ "TITLE", title });
    const std::string artist = TagValue(tags, "artist");
    if (!artist.empty()) entries.push_back({ "ARTIST", artist });
    const std::string album = TagValue(tags, "album");
    if (!album.empty()) entries.push_back({ "ALBUM", album });
    const std::string genre = TagValue(tags, "genre");
    if (!genre.empty()) entries.push_back({ "GENRE", genre });
    const std::string dateTime = TagValue(tags, "dateTime");
    const std::string year = TagValue(tags, "year");
    const std::string date = !dateTime.empty() ? dateTime : year;
    if (!date.empty()) entries.push_back({ "DATE", date });
    const std::string track = TagValue(tags, "track");
    if (!track.empty()) entries.push_back({ "TRACKNUMBER", track });
    const std::string disc = TagValue(tags, "disc");
    if (!disc.empty()) entries.push_back({ "DISCNUMBER", disc });
    const std::string composer = TagValue(tags, "composer");
    if (!composer.empty()) entries.push_back({ "COMPOSER", composer });
    const std::string albumArtist = TagValue(tags, "albumArtist");
    if (!albumArtist.empty()) entries.push_back({ "ALBUMARTIST", albumArtist });
    const std::string author = TagValue(tags, "author");
    if (!author.empty()) entries.push_back({ "AUTHOR", author });
    const std::string language = TagValue(tags, "language");
    if (!language.empty()) entries.push_back({ "LANGUAGE", language });
    const std::string encoder = TagValue(tags, "encoder");
    if (!encoder.empty()) entries.push_back({ "ENCODER", encoder });
    const std::string commentText = TagValue(tags, "comment");
    if (!commentText.empty()) entries.push_back({ "COMMENT", commentText });
    const std::string conductor = TagValue(tags, "conductor");
    if (!conductor.empty()) entries.push_back({ "CONDUCTOR", conductor });
    const std::string description = TagValue(tags, "description");
    if (!description.empty()) entries.push_back({ "DESCRIPTION", description });
    AppendU32Le(comment, static_cast<uint32_t>(entries.size()));
    for (const auto& entry : entries) {
        FlacAppendComment(comment, entry.first, entry.second);
    }
    if (comment.size() > 0xFFFFFF) {
        return "flac comment too large";
    }

    // 重建元数据区域 [4, oldRegionEnd)
    std::vector<uint8_t> region;
    auto appendBlock = [&region](uint8_t type, const std::vector<uint8_t>& data, bool lastFlag) {
        region.push_back(static_cast<uint8_t>(lastFlag ? (type | 0x80) : type));
        region.push_back(static_cast<uint8_t>((data.size() >> 16) & 0xFF));
        region.push_back(static_cast<uint8_t>((data.size() >> 8) & 0xFF));
        region.push_back(static_cast<uint8_t>(data.size() & 0xFF));
        region.insert(region.end(), data.begin(), data.end());
    };
    appendBlock(0, streamInfo, false);
    appendBlock(4, comment, false);
    for (const auto& block : otherBlocks) {
        appendBlock(block.first, block.second, false);
    }
    appendBlock(1, std::vector<uint8_t>(4096, 0), true); // 尾部 PADDING

    const int64_t delta = static_cast<int64_t>(region.size()) -
        static_cast<int64_t>(oldRegionEnd - 4);
    if (delta != 0) {
        if (!ShiftRegion(fd, oldRegionEnd, fileSize, delta)) {
            return "shift audio data failed";
        }
        if (ftruncate(fd, static_cast<off_t>(fileSize) + delta) != 0) {
            return "truncate failed";
        }
    }
    if (pwrite(fd, region.data(), region.size(), 4) != static_cast<ssize_t>(region.size())) {
        return "write flac blocks failed";
    }
    if (fsync(fd) != 0) {
        return "fsync failed";
    }
    return "";
}

// ===== MP4/M4A ilst 写入 =====
// 结构：moov > udta > meta（含 4 字节版本/标志）> ilst > 各标签盒。
// 重建 ilst（保留非受管条目如封面 covr），沿 udta/meta/moov 链重算尺寸后整 moov 区域替换。
constexpr uint32_t MP4_MAX_MOOV_BYTES = 64 * 1024 * 1024;

static uint32_t ReadBe32(const uint8_t* data)
{
    return (static_cast<uint32_t>(data[0]) << 24) | (static_cast<uint32_t>(data[1]) << 16) |
        (static_cast<uint32_t>(data[2]) << 8) | static_cast<uint32_t>(data[3]);
}

struct Mp4ChildBox {
    uint32_t type = 0;
    uint64_t offset = 0;
    uint64_t size = 0;
};

// 严格遍历 [start, end) 内的盒序列（要求恰好耗尽）
static bool Mp4CollectChildren(const std::vector<uint8_t>& buffer, uint64_t start, uint64_t end,
    std::vector<Mp4ChildBox>& children)
{
    uint64_t pos = start;
    while (pos + 8 <= end) {
        const uint32_t size = ReadBe32(buffer.data() + pos);
        const uint32_t type = ReadBe32(buffer.data() + pos + 4);
        if (size < 8 || pos + size > end) {
            return false;
        }
        Mp4ChildBox child;
        child.type = type;
        child.offset = pos;
        child.size = size;
        children.push_back(child);
        pos += size;
    }
    return pos == end;
}

static void Mp4AppendFourCC(std::vector<uint8_t>& out, const char* type)
{
    for (int i = 0; i < 4; i++) {
        out.push_back(static_cast<uint8_t>(type[i]));
    }
}

// 追加一个盒：8 字节头（大端尺寸 + FourCC）+ 载荷
static void Mp4AppendEntry(std::vector<uint8_t>& out, const char* type, const std::vector<uint8_t>& payload)
{
    AppendU32Be(out, static_cast<uint32_t>(payload.size() + 8));
    Mp4AppendFourCC(out, type);
    out.insert(out.end(), payload.begin(), payload.end());
}

// 文本标签盒：<type> > data（flags=1 UTF-8）
static void Mp4BuildTextEntry(std::vector<uint8_t>& out, const char* type, const std::string& value)
{
    std::vector<uint8_t> payload;
    AppendU32Be(payload, static_cast<uint32_t>(value.size() + 16));
    Mp4AppendFourCC(payload, "data");
    AppendU32Be(payload, 1); // 版本 0 + flags 1（UTF-8 文本）
    AppendU32Be(payload, 0); // 保留
    payload.insert(payload.end(), value.begin(), value.end());
    Mp4AppendEntry(out, type, payload);
}

// 自由格式标签盒：---- > mean(com.apple.iTunes) + name + data
static void Mp4BuildFreeformEntry(std::vector<uint8_t>& out, const std::string& name,
    const std::string& value)
{
    std::vector<uint8_t> payload;
    const std::string mean = "com.apple.iTunes";
    AppendU32Be(payload, static_cast<uint32_t>(mean.size() + 13));
    Mp4AppendFourCC(payload, "mean");
    AppendU32Be(payload, 0);
    payload.insert(payload.end(), mean.begin(), mean.end());
    payload.push_back(0);
    AppendU32Be(payload, static_cast<uint32_t>(name.size() + 13));
    Mp4AppendFourCC(payload, "name");
    AppendU32Be(payload, 0);
    payload.insert(payload.end(), name.begin(), name.end());
    payload.push_back(0);
    AppendU32Be(payload, static_cast<uint32_t>(value.size() + 16));
    Mp4AppendFourCC(payload, "data");
    AppendU32Be(payload, 1);
    AppendU32Be(payload, 0);
    payload.insert(payload.end(), value.begin(), value.end());
    Mp4AppendEntry(out, "----", payload);
}

// trkn/disk 数字对："3" 或 "3/12" → 8 字节二进制载荷（flags=0）
static bool ParseNumberPair(const std::string& text, uint16_t& first, uint16_t& second)
{
    first = 0;
    second = 0;
    const size_t slash = text.find('/');
    const std::string head = slash == std::string::npos ? text : text.substr(0, slash);
    const long headValue = strtol(head.c_str(), nullptr, 10);
    if (headValue > 0 && headValue <= 0xFFFF) {
        first = static_cast<uint16_t>(headValue);
    }
    if (slash != std::string::npos) {
        const long tailValue = strtol(text.c_str() + slash + 1, nullptr, 10);
        if (tailValue > 0 && tailValue <= 0xFFFF) {
            second = static_cast<uint16_t>(tailValue);
        }
    }
    return first != 0 || second != 0;
}

static void Mp4BuildNumberPairEntry(std::vector<uint8_t>& out, const char* type,
    uint16_t first, uint16_t second)
{
    std::vector<uint8_t> payload;
    AppendU32Be(payload, 8 + 8);
    Mp4AppendFourCC(payload, "data");
    AppendU32Be(payload, 0); // flags=0 二进制
    AppendU32Be(payload, 0);
    payload.push_back(0);
    payload.push_back(0);
    payload.push_back(static_cast<uint8_t>((first >> 8) & 0xFF));
    payload.push_back(static_cast<uint8_t>(first & 0xFF));
    payload.push_back(static_cast<uint8_t>((second >> 8) & 0xFF));
    payload.push_back(static_cast<uint8_t>(second & 0xFF));
    payload.push_back(0);
    payload.push_back(0);
    Mp4AppendEntry(out, type, payload);
}

// 新建 meta 时合成的 hdlr 盒（mdir）
static std::vector<uint8_t> Mp4BuildMetaHandler()
{
    std::vector<uint8_t> payload;
    AppendU32Be(payload, 0);
    AppendU32Be(payload, 0);
    Mp4AppendFourCC(payload, "mdir");
    for (int i = 0; i < 12; i++) {
        payload.push_back(0);
    }
    payload.push_back(0);
    std::vector<uint8_t> handler;
    Mp4AppendEntry(handler, "hdlr", payload);
    return handler;
}

// ilst 受管条目类型（编辑时整体重建；gnre 数字流派一并删除避免与 ©gen 冲突）
static bool Mp4IsManagedType(uint32_t type)
{
    switch (type) {
        case 0xA96E616D: // ©nam 标题
        case 0xA9415254: // ©ART 歌手
        case 0xA9616C62: // ©alb 专辑
        case 0xA967656E: // ©gen 流派
        case 0x676E7265: // gnre 数字流派
        case 0xA9646179: // ©day 年份/日期
        case 0x74726B6E: // trkn 音轨号
        case 0x6469736B: // disk 碟号
        case 0xA9777274: // ©wrt 作曲家
        case 0x61415254: // aART 专辑艺术家
        case 0xA9746F6F: // ©too 编码器
        case 0xA9636D74: // ©cmt 注释
        case 0x64657363: // desc 描述
        case 0xA96C616E: // ©lan 语言
        case 0x2D2D2D2D: // ----（按 name 再筛）
            return true;
        default:
            return false;
    }
}

// ---- 盒的 name 子盒内容（跳过 8 头 + 4 版本/标志，去尾部 NUL）
static std::string Mp4FreeformName(const uint8_t* box, uint64_t boxSize)
{
    std::string result;
    uint64_t pos = 8;
    while (pos + 8 <= boxSize) {
        const uint32_t size = ReadBe32(box + pos);
        const uint32_t type = ReadBe32(box + pos + 4);
        if (size < 8 || pos + size > boxSize) {
            break;
        }
        if (type == 0x6E616D65 && size >= 12 && size <= 128) { // name
            result.assign(reinterpret_cast<const char*>(box + pos + 12), size - 12);
            while (!result.empty() && result.back() == '\0') {
                result.pop_back();
            }
            break;
        }
        pos += size;
    }
    return result;
}

// 保留 ilst 中非受管条目的原始字节（含封面 covr 等）
static void Mp4CollectKeptIlstBoxes(const std::vector<uint8_t>& moov, const Mp4ChildBox& ilst,
    std::vector<uint8_t>& kept)
{
    uint64_t pos = ilst.offset + 8;
    const uint64_t end = ilst.offset + ilst.size;
    while (pos + 8 <= end) {
        const uint32_t size = ReadBe32(moov.data() + pos);
        const uint32_t type = ReadBe32(moov.data() + pos + 4);
        if (size < 8 || pos + size > end) {
            break;
        }
        bool managed = Mp4IsManagedType(type);
        if (managed && type == 0x2D2D2D2D) {
            const std::string name = Mp4FreeformName(moov.data() + pos, size);
            managed = name == "AUTHOR" || name == "LANGUAGE" || name == "CONDUCTOR";
        }
        if (!managed) {
            kept.insert(kept.end(), moov.begin() + pos, moov.begin() + pos + size);
        }
        pos += size;
    }
}

// 16 个编辑键 → ilst 条目（空值 = 删除对应条目）
static void Mp4AppendTagEntries(std::vector<uint8_t>& ilstContent,
    const std::map<std::string, std::string>& tags)
{
    const std::string title = TagValue(tags, "title");
    if (!title.empty()) {
        Mp4BuildTextEntry(ilstContent, "\xA9" "nam", title);
    }
    const std::string artist = TagValue(tags, "artist");
    if (!artist.empty()) {
        Mp4BuildTextEntry(ilstContent, "\xA9" "ART", artist);
    }
    const std::string album = TagValue(tags, "album");
    if (!album.empty()) {
        Mp4BuildTextEntry(ilstContent, "\xA9" "alb", album);
    }
    const std::string genre = TagValue(tags, "genre");
    if (!genre.empty()) {
        Mp4BuildTextEntry(ilstContent, "\xA9" "gen", genre);
    }
    const std::string dateTime = TagValue(tags, "dateTime");
    const std::string year = TagValue(tags, "year");
    const std::string day = !dateTime.empty() ? dateTime : year;
    if (!day.empty()) {
        Mp4BuildTextEntry(ilstContent, "\xA9" "day", day);
    }
    const std::string track = TagValue(tags, "track");
    uint16_t trackNumber = 0;
    uint16_t trackTotal = 0;
    if (!track.empty() && ParseNumberPair(track, trackNumber, trackTotal)) {
        Mp4BuildNumberPairEntry(ilstContent, "trkn", trackNumber, trackTotal);
    }
    const std::string disc = TagValue(tags, "disc");
    uint16_t discNumber = 0;
    uint16_t discTotal = 0;
    if (!disc.empty() && ParseNumberPair(disc, discNumber, discTotal)) {
        Mp4BuildNumberPairEntry(ilstContent, "disk", discNumber, discTotal);
    }
    const std::string composer = TagValue(tags, "composer");
    if (!composer.empty()) {
        Mp4BuildTextEntry(ilstContent, "\xA9" "wrt", composer);
    }
    const std::string albumArtist = TagValue(tags, "albumArtist");
    if (!albumArtist.empty()) {
        Mp4BuildTextEntry(ilstContent, "aART", albumArtist);
    }
    const std::string encoder = TagValue(tags, "encoder");
    if (!encoder.empty()) {
        Mp4BuildTextEntry(ilstContent, "\xA9" "too", encoder);
    }
    const std::string commentText = TagValue(tags, "comment");
    if (!commentText.empty()) {
        Mp4BuildTextEntry(ilstContent, "\xA9" "cmt", commentText);
    }
    const std::string description = TagValue(tags, "description");
    if (!description.empty()) {
        Mp4BuildTextEntry(ilstContent, "desc", description);
    }
    const std::string author = TagValue(tags, "author");
    if (!author.empty()) {
        Mp4BuildFreeformEntry(ilstContent, "AUTHOR", author);
    }
    const std::string language = TagValue(tags, "language");
    if (!language.empty()) {
        Mp4BuildFreeformEntry(ilstContent, "LANGUAGE", language);
    }
    const std::string conductor = TagValue(tags, "conductor");
    if (!conductor.empty()) {
        Mp4BuildFreeformEntry(ilstContent, "CONDUCTOR", conductor);
    }
}

static std::string WriteMp4TagsToFd(int32_t fd, const std::map<std::string, std::string>& tags)
{
    struct stat fileStat = {};
    if (fstat(fd, &fileStat) != 0 || fileStat.st_size < 8) {
        return "stat failed";
    }
    const uint64_t fileSize = static_cast<uint64_t>(fileStat.st_size);
    // 顶层盒遍历定位 moov
    uint64_t moovStart = 0;
    uint64_t moovSize = 0;
    bool moovFound = false;
    uint64_t offset = 0;
    while (offset + 8 <= fileSize) {
        uint8_t header[8] = {};
        if (pread(fd, header, sizeof(header), offset) != sizeof(header)) {
            return "read box header failed";
        }
        const uint64_t size = ReadBe32(header);
        const uint32_t type = ReadBe32(header + 4);
        if (size == 1) {
            return "unsupported: 64-bit box";
        }
        if (size < 8) {
            return "corrupt box size";
        }
        if (type == 0x6D6F6F76) { // moov
            moovStart = offset;
            moovSize = size;
            moovFound = true;
            break;
        }
        offset += size;
    }
    if (!moovFound || moovSize > MP4_MAX_MOOV_BYTES) {
        return "moov not found or oversized";
    }
    std::vector<uint8_t> moov(moovSize);
    if (pread(fd, moov.data(), moov.size(), moovStart) != static_cast<ssize_t>(moov.size())) {
        return "read moov failed";
    }
    std::vector<Mp4ChildBox> moovChildren;
    if (!Mp4CollectChildren(moov, 8, moov.size(), moovChildren)) {
        return "corrupt moov children";
    }
    const Mp4ChildBox* udta = nullptr;
    for (const Mp4ChildBox& child : moovChildren) {
        if (child.type == 0x75647461) { // udta
            udta = &child;
            break;
        }
    }
    std::vector<Mp4ChildBox> udtaChildren;
    if (udta != nullptr &&
        !Mp4CollectChildren(moov, udta->offset + 8, udta->offset + udta->size, udtaChildren)) {
        return "corrupt udta children";
    }
    std::vector<uint8_t> metaVersionFlags = { 0, 0, 0, 0 };
    std::vector<uint8_t> metaOthers; // meta 内除 ilst 外的子盒（hdlr 等）原始字节
    std::vector<uint8_t> udtaOthers; // udta 内除 meta 外的子盒原始字节
    bool haveHdlr = false;
    for (const Mp4ChildBox& child : udtaChildren) {
        if (child.type == 0x6D657461) { // meta
            continue;
        }
        udtaOthers.insert(udtaOthers.end(), moov.begin() + child.offset,
            moov.begin() + child.offset + child.size);
    }
    std::vector<uint8_t> ilstContent;
    for (const Mp4ChildBox& child : udtaChildren) {
        if (child.type != 0x6D657461 || child.size < 12) { // meta
            continue;
        }
        metaVersionFlags.assign(moov.begin() + child.offset + 8, moov.begin() + child.offset + 12);
        std::vector<Mp4ChildBox> metaChildren;
        if (!Mp4CollectChildren(moov, child.offset + 12, child.offset + child.size, metaChildren)) {
            return "corrupt meta children";
        }
        for (const Mp4ChildBox& metaChild : metaChildren) {
            if (metaChild.type == 0x696C7374) { // ilst
                Mp4CollectKeptIlstBoxes(moov, metaChild, ilstContent);
                continue;
            }
            metaOthers.insert(metaOthers.end(), moov.begin() + metaChild.offset,
                moov.begin() + metaChild.offset + metaChild.size);
            if (metaChild.type == 0x68646C72) { // hdlr
                haveHdlr = true;
            }
        }
    }
    if (!haveHdlr) {
        const std::vector<uint8_t> handler = Mp4BuildMetaHandler();
        metaOthers.insert(metaOthers.end(), handler.begin(), handler.end());
    }
    Mp4AppendTagEntries(ilstContent, tags);
    if (ilstContent.size() > 0xFFFFFFF0) {
        return "ilst too large";
    }
    // ilst > meta > udta > moov 逐级重建
    std::vector<uint8_t> ilstBox;
    Mp4AppendEntry(ilstBox, "ilst", ilstContent);
    std::vector<uint8_t> metaContent = metaVersionFlags;
    metaContent.insert(metaContent.end(), metaOthers.begin(), metaOthers.end());
    metaContent.insert(metaContent.end(), ilstBox.begin(), ilstBox.end());
    std::vector<uint8_t> metaBox;
    Mp4AppendEntry(metaBox, "meta", metaContent);
    std::vector<uint8_t> udtaContent = udtaOthers;
    udtaContent.insert(udtaContent.end(), metaBox.begin(), metaBox.end());
    std::vector<uint8_t> udtaBox;
    Mp4AppendEntry(udtaBox, "udta", udtaContent);
    std::vector<uint8_t> newMoovContent;
    for (const Mp4ChildBox& child : moovChildren) {
        if (child.type == 0x75647461) { // udta
            continue;
        }
        newMoovContent.insert(newMoovContent.end(), moov.begin() + child.offset,
            moov.begin() + child.offset + child.size);
    }
    newMoovContent.insert(newMoovContent.end(), udtaBox.begin(), udtaBox.end());
    std::vector<uint8_t> newMoov;
    Mp4AppendEntry(newMoov, "moov", newMoovContent);

    const int64_t delta = static_cast<int64_t>(newMoov.size()) - static_cast<int64_t>(moovSize);
    if (delta != 0) {
        if (!ShiftRegion(fd, moovStart + moovSize, fileSize, delta)) {
            return "shift audio data failed";
        }
        if (ftruncate(fd, static_cast<off_t>(fileSize) + delta) != 0) {
            return "truncate failed";
        }
    }
    if (pwrite(fd, newMoov.data(), newMoov.size(), moovStart) != static_cast<ssize_t>(newMoov.size())) {
        return "write moov failed";
    }
    if (fsync(fd) != 0) {
        return "fsync failed";
    }
    return "";
}

// 按文件魔数分发：ID3/MPEG 帧 → ID3v2；fLaC → Vorbis Comment；ftyp → MP4 ilst
static std::string WriteAudioTagsToFd(int32_t fd, const std::map<std::string, std::string>& tags)
{
    uint8_t magic[8] = {};
    struct stat fileStat = {};
    if (fstat(fd, &fileStat) != 0 || fileStat.st_size < 4) {
        return "stat failed";
    }
    const size_t magicSize = fileStat.st_size < 8 ? static_cast<size_t>(fileStat.st_size) : 8;
    if (pread(fd, magic, magicSize, 0) != static_cast<ssize_t>(magicSize)) {
        return "read file failed";
    }
    if (std::memcmp(magic, "ID3", 3) == 0) {
        return WriteId3TagsToFd(fd, tags);
    }
    if (std::memcmp(magic, "fLaC", 4) == 0) {
        return WriteFlacTagsToFd(fd, tags);
    }
    if (magic[0] == 0xFF && (magic[1] & 0xE0) == 0xE0) {
        return WriteId3TagsToFd(fd, tags);
    }
    if (fileStat.st_size >= 8 && std::memcmp(magic + 4, "ftyp", 4) == 0) {
        return WriteMp4TagsToFd(fd, tags);
    }
    return "unsupported: not mp3/flac/mp4";
}

// 写入音频标签：writeAudioTags(fd, tags) → 空串=成功；"unsupported"开头=格式不支持；其他=错误描述
napi_value WriteAudioTags(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = { nullptr, nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t fd = -1;
    napi_valuetype tagsType = napi_undefined;
    if (argc != 2 || napi_get_value_int32(env, args[0], &fd) != napi_ok || fd < 0 ||
        napi_typeof(env, args[1], &tagsType) != napi_ok || tagsType != napi_object) {
        return StringValue(env, "invalid arguments");
    }
    std::map<std::string, std::string> tags;
    for (const Id3TagMapping& mapping : ID3_TAG_MAPPINGS) {
        napi_value key = nullptr;
        napi_value value = nullptr;
        bool has = false;
        napi_valuetype valueType = napi_undefined;
        if (napi_create_string_utf8(env, mapping.key, NAPI_AUTO_LENGTH, &key) != napi_ok ||
            napi_has_own_property(env, args[1], key, &has) != napi_ok || !has ||
            napi_get_property(env, args[1], key, &value) != napi_ok ||
            napi_typeof(env, value, &valueType) != napi_ok || valueType != napi_string) {
            continue;
        }
        size_t length = 0;
        if (napi_get_value_string_utf8(env, value, nullptr, 0, &length) != napi_ok) {
            continue;
        }
        std::string text(length + 1, '\0');
        if (napi_get_value_string_utf8(env, value, text.data(), text.size(), &length) != napi_ok) {
            continue;
        }
        text.resize(length);
        tags[mapping.key] = text;
    }
    return StringValue(env, WriteAudioTagsToFd(fd, tags));
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
        { "setGeneralVoiceChangeEnable", nullptr, SetGeneralVoiceChangeEnable, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "setGeneralVoiceChangeType", nullptr, SetGeneralVoiceChangeType, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "setNoiseReductionEnable", nullptr, SetNoiseReductionEnable, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "setPureVoiceChangeEnable", nullptr, SetPureVoiceChangeEnable, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "setPureVoiceChangeConfig", nullptr, SetPureVoiceChangeConfig, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "setTempoPitchEnable", nullptr, SetTempoPitchEnable, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "setTempoPitchConfig", nullptr, SetTempoPitchConfig, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "setSeparationEnable", nullptr, SetSeparationEnable, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "setSeparationOutput", nullptr, SetSeparationOutput, nullptr, nullptr, nullptr, napi_default, nullptr },
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
        { "clearAlbumCoverCache", nullptr, ClearAlbumCoverCache, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "writeAudioTags", nullptr, WriteAudioTags, nullptr, nullptr, nullptr, napi_default, nullptr }
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

#include "engine.h"

#define LOG_TAG "[TimbravaNative][Engine]"
#include <hilog/log.h>

#include <algorithm>
#include <cmath>
#include <chrono>
#include <cstring>
#include "flac_decoder.h"
#include "wav_decoder.h"

namespace timbrava {

Engine &Engine::instance()
{
    static Engine inst;
    return inst;
}

void Engine::pushEvent(const std::string &json)
{
    std::lock_guard<std::mutex> lk(evM_);
    if (events_.size() > 64) {
        events_.pop_front(); // 防积压
    }
    events_.push_back(json);
}

void Engine::pollEvents(std::vector<std::string> &out)
{
    std::lock_guard<std::mutex> lk(evM_);
    while (!events_.empty()) {
        out.push_back(events_.front());
        events_.pop_front();
    }
}

void Engine::ensureThread()
{
    std::lock_guard<std::mutex> lk(wakeM_);
    if (threadStarted_) {
        return;
    }
    quit_ = false;
    threadStarted_ = true;
    decodeThread_ = std::thread([this] { decodeLoop(); });
    OH_LOG_Print(LOG_APP, LOG_INFO, 0, LOG_TAG, "decode thread started");
}

bool Engine::openTrack(int fd, std::string *errMsg, TrackInfo *outInfo)
{
    if (errMsg == nullptr || outInfo == nullptr) {
        return false;
    }
    ensureThread();
    stopTrack();

    std::lock_guard<std::mutex> lk(stateM_);
    // 试 FLAC,失败再试 WAV
    auto flac = std::make_unique<FlacDecoder>();
    if (flac->openFile(fd, TrackInfo{})) {
        decoder_ = std::move(flac);
    } else {
        auto wav = std::make_unique<WavDecoder>();
        if (wav->openFile(fd, TrackInfo{})) {
            decoder_ = std::move(wav);
        } else {
            *errMsg = "unsupported or corrupted file (flac/wav probe failed)";
            return false;
        }
    }

    info_ = decoder_->info();
    fmt_ = decoder_->outFormat();
    ring_.reset();
    framesConsumed_ = 0;
    eof_ = false;
    seeking_ = false;
    seekTargetFrames_ = -1;

    out_ = std::make_unique<AudioOutput>();
    int channels = info_.channels;
    OutputFormat fmtCopy = fmt_;
    bool ok = out_->create(
        info_, fmt_,
        [this, channels, fmtCopy](OH_AudioRenderer *, void *, void *buffer, int32_t length) -> OH_AudioData_Callback_Result {
            if (length <= 0) {
                return AUDIO_DATA_CALLBACK_RESULT_VALID;
            }
            int bytesPerSample = fmtCopy == OutputFormat::U8 ? 1 : fmtCopy == OutputFormat::S16LE ? 2 : 4;
            int frameBytes = channels * bytesPerSample;
            if (frameBytes <= 0) {
                return AUDIO_DATA_CALLBACK_RESULT_INVALID;
            }
            if (seeking_.load()) {
                std::memset(buffer, 0, static_cast<size_t>(length));
                return AUDIO_DATA_CALLBACK_RESULT_VALID;
            }
            size_t n = ring_.read(static_cast<uint8_t *>(buffer), static_cast<size_t>(length));
            if (n < static_cast<size_t>(length)) {
                std::memset(static_cast<uint8_t *>(buffer) + n, 0, static_cast<size_t>(length) - n);
                if (!eof_.load()) {
                    int64_t now = std::chrono::duration_cast<std::chrono::milliseconds>(
                                      std::chrono::steady_clock::now().time_since_epoch())
                                      .count();
                    int64_t last = lastUnderrunMs_;
                    if (now - last > 2000) {
                        lastUnderrunMs_ = now;
                        pushEvent("{\"ev\":\"underrun\"}");
                    }
                }
            }
            framesConsumed_ += static_cast<int64_t>(n / static_cast<size_t>(frameBytes));
            return AUDIO_DATA_CALLBACK_RESULT_VALID;
        },
        [this](int forceType, int hint) {
            OH_LOG_Print(LOG_APP, LOG_INFO, 0, LOG_TAG, "interrupt force=%{public}d hint=%{public}d", forceType, hint);
            pushEvent("{\"ev\":\"interrupt\",\"force\":" + std::to_string(forceType) +
                      ",\"hint\":" + std::to_string(hint) + "}");
        },
        [this](int code) { pushEvent("{\"ev\":\"error\",\"src\":\"renderer\",\"code\":" + std::to_string(code) + "}"); });

    if (!ok) {
        *errMsg = "audio renderer create failed(采样率/格式可能不被支持)";
        out_.reset();
        decoder_.reset();
        return false;
    }
    out_->setVolume(volume_.load());
    mode_ = EngineMode::READY;
    *outInfo = info_;
    OH_LOG_Print(LOG_APP, LOG_INFO, 0, LOG_TAG, "track opened codec=%{public}s rate=%{public}d ch=%{public}d "
                                                 "bits=%{public}d frames=%{public}lld",
                 info_.codec, info_.sampleRate, info_.channels, info_.bitsPerSample,
                 static_cast<long long>(info_.totalFrames));
    return true;
}

void Engine::play()
{
    std::lock_guard<std::mutex> lk(stateM_);
    EngineMode m = mode_.load();
    if (m != EngineMode::READY && m != EngineMode::PAUSED) {
        return;
    }
    if (out_ != nullptr && out_->start()) {
        mode_ = EngineMode::PLAYING;
        ring_.setWritable(true);
        wakeCv_.notify_all();
        OH_LOG_Print(LOG_APP, LOG_INFO, 0, LOG_TAG, "play");
    }
}

void Engine::pause()
{
    std::lock_guard<std::mutex> lk(stateM_);
    if (mode_.load() != EngineMode::PLAYING) {
        return;
    }
    if (out_ != nullptr && out_->pause()) {
        mode_ = EngineMode::PAUSED;
        ring_.setWritable(false);
        wakeCv_.notify_all();
        OH_LOG_Print(LOG_APP, LOG_INFO, 0, LOG_TAG, "pause");
    }
}

void Engine::stopTrack()
{
    std::lock_guard<std::mutex> lk(stateM_);
    if (mode_.load() == EngineMode::IDLE) {
        return;
    }
    mode_ = EngineMode::IDLE;
    ring_.abort(); // 解锁可能阻塞在 write 的解码线程
    wakeCv_.notify_all();
    if (out_ != nullptr) {
        out_->destroy();
        out_.reset();
    }
    decoder_.reset();
    framesConsumed_ = 0;
    eof_ = false;
    seeking_ = false;
    seekTargetFrames_ = -1;
    OH_LOG_Print(LOG_APP, LOG_INFO, 0, LOG_TAG, "track stopped");
}

bool Engine::seekMs(int64_t ms, std::string *errMsg)
{
    if (errMsg == nullptr) {
        return false;
    }
    std::lock_guard<std::mutex> lk(stateM_);
    if (mode_.load() == EngineMode::IDLE || decoder_ == nullptr || info_.sampleRate <= 0) {
        *errMsg = "no active track";
        return false;
    }
    int64_t target = ms * info_.sampleRate / 1000;
    int64_t maxFrame = info_.totalFrames;
    if (maxFrame > 0) {
        target = std::min(target, maxFrame);
    }
    if (target < 0) {
        target = 0;
    }
    seekTargetFrames_ = target;
    ring_.setWritable(false); // 让阻塞 write 尽快退出,解码线程统一 applySeek
    ring_.abort();
    if (mode_.load() == EngineMode::PLAYING) {
        ring_.setWritable(true);
    }
    wakeCv_.notify_all();
    OH_LOG_Print(LOG_APP, LOG_INFO, 0, LOG_TAG, "seek req ms=%{public}lld frame=%{public}lld",
                 static_cast<long long>(ms), static_cast<long long>(target));
    return true;
}

void Engine::applySeek()
{
    int64_t target = seekTargetFrames_.exchange(-1);
    if (target < 0) {
        return;
    }
    seeking_ = true; // 渲染回调置零、不消费
    ring_.setWritable(false);
    ring_.flushAll();
    bool ok = false;
    {
        std::lock_guard<std::mutex> lk(stateM_);
        if (decoder_ != nullptr) {
            ok = decoder_->seekToFrame(target);
        }
    }
    if (!ok) {
        pushEvent("{\"ev\":\"error\",\"src\":\"seek\"}");
    }
    framesConsumed_ = target;
    eof_ = false;
    ring_.reset();
    ring_.setWritable(mode_.load() == EngineMode::PLAYING);
    // 预填 256KB 或 1s 超时再放开渲染,避免 seek 后爆 underrun
    for (int i = 0; i < 100 && mode_.load() == EngineMode::PLAYING; i++) {
        if (ring_.sizeLocked() >= 256 * 1024) {
            break;
        }
        std::unique_lock<std::mutex> lk(wakeM_);
        wakeCv_.wait_for(lk, std::chrono::milliseconds(10));
    }
    seeking_ = false;
    int64_t ms = target * 1000 / (info_.sampleRate > 0 ? info_.sampleRate : 44100);
    pushEvent("{\"ev\":\"seekDone\",\"ms\":" + std::to_string(ms) + "}");
    OH_LOG_Print(LOG_APP, LOG_INFO, 0, LOG_TAG, "seek applied frame=%{public}lld ok=%{public}d",
                 static_cast<long long>(target), ok ? 1 : 0);
}

void Engine::decodeLoop()
{
    std::vector<uint8_t> chunk(64 * 1024);
    while (!quit_.load()) {
        EngineMode m = mode_.load();
        if (m == EngineMode::IDLE) {
            std::unique_lock<std::mutex> lk(wakeM_);
            wakeCv_.wait_for(lk, std::chrono::milliseconds(100));
            continue;
        }
        if (seekTargetFrames_.load() >= 0) {
            applySeek();
            continue;
        }
        if (m == EngineMode::READY || m == EngineMode::PAUSED) {
            std::unique_lock<std::mutex> lk(wakeM_);
            wakeCv_.wait_for(lk, std::chrono::milliseconds(50));
            continue;
        }
        if (eof_.load()) {
            if (ring_.sizeLocked() == 0) {
                std::lock_guard<std::mutex> lk(stateM_);
                if (mode_.load() == EngineMode::PLAYING) {
                    if (out_ != nullptr) {
                        out_->stop();
                    }
                    mode_ = EngineMode::READY;
                    pushEvent("{\"ev\":\"end\"}");
                    OH_LOG_Print(LOG_APP, LOG_INFO, 0, LOG_TAG, "track end");
                }
            } else {
                std::unique_lock<std::mutex> lk(wakeM_);
                wakeCv_.wait_for(lk, std::chrono::milliseconds(20));
            }
            continue;
        }
        int64_t got = 0;
        int channels = 0;
        OutputFormat fmtNow = fmt_;
        {
            std::lock_guard<std::mutex> lk(stateM_);
            if (decoder_ == nullptr) {
                continue;
            }
            channels = info_.channels;
            int bytesPerSample = fmt_ == OutputFormat::U8 ? 1 : fmt_ == OutputFormat::S16LE ? 2 : 4;
            int64_t maxFrames = static_cast<int64_t>(chunk.size()) / (bytesPerSample * channels);
            got = decoder_->readFrames(chunk.data(), maxFrames, chunk.size());
            fmtNow = fmt_;
        }
        if (got <= 0) {
            eof_ = true;
            continue;
        }
        int bytesPerSample = fmtNow == OutputFormat::U8 ? 1 : fmtNow == OutputFormat::S16LE ? 2 : 4;
        size_t bytes = static_cast<size_t>(got) * channels * bytesPerSample;
        size_t written = ring_.write(chunk.data(), bytes);
        if (written < bytes) {
            // 被暂停/中止打断:本段作废;P0 简化(暂停场景 write 不会被截断,只有 stop/seek)
            eof_ = false;
        }
        // 背压:缓冲 >90% 时小睡,降低空转
        if (ring_.sizeLocked() > ring_.capacity() * 9 / 10) {
            std::unique_lock<std::mutex> lk(wakeM_);
            wakeCv_.wait_for(lk, std::chrono::milliseconds(30));
        }
    }
}

void Engine::shutdown()
{
    stopTrack();
    quit_ = true;
    ring_.abort();
    wakeCv_.notify_all();
    if (threadStarted_ && decodeThread_.joinable()) {
        decodeThread_.join();
        threadStarted_ = false;
    }
}

EngineMode Engine::mode() const { return mode_.load(); }

bool Engine::hasTrack() const { return mode_.load() != EngineMode::IDLE; }

void Engine::setVolume(float vol)
{
    volume_ = std::max(0.0f, std::min(1.0f, vol));
    std::lock_guard<std::mutex> lk(stateM_);
    if (out_ != nullptr) {
        out_->setVolume(volume_.load());
    }
}

int64_t Engine::positionMs()
{
    if (info_.sampleRate <= 0) {
        return 0;
    }
    return framesConsumed_.load() * 1000 / info_.sampleRate;
}

int64_t Engine::durationMs() const
{
    if (info_.sampleRate <= 0 || info_.totalFrames <= 0) {
        return 0;
    }
    return info_.totalFrames * 1000 / info_.sampleRate;
}

} // namespace timbrava

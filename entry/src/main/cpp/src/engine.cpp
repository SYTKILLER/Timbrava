#include "engine.h"

#define LOG_TAG "[TimbravaNative][Engine]"
#include <hilog/log.h>

#include <algorithm>
#include <cmath>
#include <chrono>
#include <cstring>
#include "flac_decoder.h"
#include "wav_decoder.h"
#include "dsd_decoder.h"
#include "viz.h"

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

// gapless 预排:探测下一曲并与当前曲做格式一致性校验(不一致返回 false,ArkTS 走普通切曲)。
// 探测的 openFile 内部 dup fd,调用方可在返回后立即关 fd(与 openTrack 契约一致)。
// 探测(重活)在锁外做,最终锁内复核当前曲仍在播放且格式一致。
bool Engine::openNextTrack(int fd)
{
    if (fd < 0) {
        return false;
    }
    // 探测链与 openTrack 一致(DSD→FLAC→WAV)
    auto probe = [](int fdIn) -> std::unique_ptr<IDecoder> {
        auto dsd = std::make_unique<DsdDecoder>();
        if (dsd->openFile(fdIn, TrackInfo{})) {
            return dsd;
        }
        auto flac = std::make_unique<FlacDecoder>();
        if (flac->openFile(fdIn, TrackInfo{})) {
            return flac;
        }
        auto wav = std::make_unique<WavDecoder>();
        if (wav->openFile(fdIn, TrackInfo{})) {
            return wav;
        }
        return nullptr;
    };
    std::unique_ptr<IDecoder> dec = probe(fd);
    if (dec == nullptr) {
        return false;
    }
    std::lock_guard<std::mutex> lk(stateM_);
    if (mode_.load() == EngineMode::IDLE || decoder_ == nullptr) {
        return false;
    }
    const TrackInfo ni = dec->info();
    // 格式一致才可共用当前 renderer(采样率/通道/位深/DSD 率;codec 允许不同——同为 PCM 流)
    if (ni.sampleRate != info_.sampleRate || ni.channels != info_.channels ||
        ni.bitsPerSample != info_.bitsPerSample || ni.dsdRate != info_.dsdRate) {
        OH_LOG_Print(LOG_APP, LOG_INFO, 0, LOG_TAG,
                     "gapless prefetch rejected: %{public}d/%{public}d/%{public}d/%{public}lld vs "
                     "%{public}d/%{public}d/%{public}d/%{public}lld",
                     ni.sampleRate, ni.channels, ni.bitsPerSample, static_cast<long long>(ni.dsdRate),
                     info_.sampleRate, info_.channels, info_.bitsPerSample, static_cast<long long>(info_.dsdRate));
        return false;
    }
    nextDecoder_ = std::move(dec);
    nextInfo_ = nextDecoder_->info();
    hasNext_ = true;
    OH_LOG_Print(LOG_APP, LOG_INFO, 0, LOG_TAG, "gapless prefetch ok frames=%{public}lld",
                 static_cast<long long>(nextInfo_.totalFrames));
    return true;
}

void Engine::clearNextTrack()
{
    std::lock_guard<std::mutex> lk(stateM_);
    nextDecoder_.reset();
    hasNext_ = false;
}

// ---------------- crossfade(0.23.0) ----------------

void Engine::setCrossfade(bool on, int ms)
{
    xfEnabled_ = on && ms > 0;
    xfMs_ = xfEnabled_ ? std::min(12000, std::max(500, ms)) : 0;
    OH_LOG_Print(LOG_APP, LOG_INFO, 0, LOG_TAG, "crossfade %{public}d ms", xfMs_.load());
}

// 发起过渡:xf 线程解码新曲 → ring2_;渲染消费 xfStartIn_ 帧旧流后进入混音窗口。
// 必须持 stateM_ 调用(decoder 转移 + 账本清空均在其保护下)。
void Engine::engageCrossfadeLocked(std::unique_ptr<IDecoder> inc, int64_t fadeFrames)
{
    if (xfThread_.joinable()) {
        xfThread_.join(); // 上一轮 xf 线程必已退出(promote/abort 后),先收句柄防 terminate
    }
    xfFadeFrames_ = fadeFrames;
    xfConsumed_ = 0;
    xfTotal_ = inc->info().totalFrames;
    xfWritten_ = 0;
    // 注意:xfStartIn_ 由调用方在 engage 前算好(旧流余量-fade 窗口),此处不得重置
    // (0.23.0 实测:重置导致倒计=0、fade 起点提前到播放起点)
    xfPromoted_ = false;
    ring2_.reset();
    // 时间轴即刻切新曲(Spotify 语义:fade 开始=切曲;positionMs 由渲染线程在新曲流上累计)
    info_ = inc->info();
    framesConsumed_ = 0;
    curWrittenFrames_ = 0;
    {
        std::lock_guard<std::mutex> lk(boundsM_);
        gaplessBounds_.clear(); // 旧账本作废:本次交接不再发 gaplessNext
    }
    xfPending_ = true;
    xfActive_ = false;
    xfEngaged_ = true;
    hasNext_ = false;
    xfThreadLive_ = true;
    std::thread th([this](std::unique_ptr<IDecoder> dec) {
        const TrackInfo inf = dec->info();
        const OutputFormat f = dec->outFormat();
        const int ch = inf.channels > 0 ? inf.channels : 2;
        const int bps = f == OutputFormat::U8 ? 1 : f == OutputFormat::S16LE ? 2 : 4;
        const int64_t fadeF = xfFadeFrames_;
        const int64_t margin = inf.sampleRate; // 提前 1s 备量,保证 promote 时新流不断供
        std::vector<uint8_t> buf(64 * 1024);
        int64_t written = 0;
        bool eofHit = false;
        while (!quit_.load()) {
            if (xfPromoted_.load()) {
                break; // fade 结束/中止:停止供数(ring2 将被废弃)
            }
            if (written >= fadeF + margin) {
                // 超前一个 margin:等待 promote/abort 再继续(否则 promotion 后写入的数据会丢失)
                std::unique_lock<std::mutex> lk(wakeM_);
                wakeCv_.wait_for(lk, std::chrono::milliseconds(20));
                continue;
            }
            const int64_t maxFrames = static_cast<int64_t>(buf.size()) / (bps * ch);
            const int64_t got = dec->readFrames(buf.data(), maxFrames, buf.size());
            if (got <= 0) {
                eofHit = true;
                break;
            }
            const size_t bytes = static_cast<size_t>(got) * ch * bps;
            const size_t w = ring2_.write(buf.data(), bytes);
            written += static_cast<int64_t>(w / static_cast<size_t>(bps * ch));
            xfWritten_ = written;
            if (w < bytes) {
                break; // abort( promotion/stop/seek)或不可写:终止供数
            }
        }
        OH_LOG_Print(LOG_APP, LOG_INFO, 0, LOG_TAG, "xf feed done eof=%{public}d written=%{public}lld",
                     eofHit ? 1 : 0, static_cast<long long>(written));
        {
            std::lock_guard<std::mutex> lk(xfM_);
            xfDecoder_ = std::move(dec); // 归还解码器(主链 adopt 或丢弃)
            xfThreadLive_ = false;
        }
        wakeCv_.notify_all();
    }, std::move(inc));
    xfThread_.swap(th);
    OH_LOG_Print(LOG_APP, LOG_INFO, 0, LOG_TAG, "crossfade engaged fade_frames=%{public}lld total=%{public}lld",
                 static_cast<long long>(fadeFrames), static_cast<long long>(xfTotal_.load()));
}

// 中止过渡(持 stateM_ 调用)。adopt=true 且 xf 线程已退出时,把新曲解码器收编为主解码器,
// 并把 ring2_ 已解码头部搬运进 ring_ 续流(seek/倍速变更场景:时间轴已属新曲)。
bool Engine::abortFadeLocked(bool adopt)
{
    const bool wasActive = xfPending_.load() || xfActive_.load() || xfEngaged_.load();
    xfPending_ = false;
    xfActive_ = false;
    xfPromoted_ = true; // 通用"fade 结束"信号:xf 线程见之即退
    ring2_.abort();     // 解开可能阻塞在 write 的 xf 线程
    wakeCv_.notify_all();
    // 等 xf 线程退出(其退出路径只锁 xfM_,与 stateM_ 无交叉,无死锁)。
    // 兜底上限 3s:xf 线程停于 margin 等待时若因异常未观察到 promoted 信号,
    // 无上限等待会把 JS 线程冻死(THREAD_BLOCK_6S appfreeze,0.24.0 实测根因);
    // 超时 detach 保播放链路继续,泄漏容忍(正常路径 20ms 内必退)。
    {
        int waitedMs = 0;
        std::unique_lock<std::mutex> lk(wakeM_);
        while (xfThreadLive_.load() && waitedMs < 3000) {
            wakeCv_.wait_for(lk, std::chrono::milliseconds(10));
            waitedMs += 10;
        }
        if (xfThreadLive_.load()) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, 0, LOG_TAG, "xf thread stuck, detach(anti-freeze)");
            if (xfThread_.joinable()) {
                xfThread_.detach();
            }
            xfThreadLive_ = false;
        }
    }
    if (xfThread_.joinable()) {
        xfThread_.join(); // 收句柄(线程体已退出,立即返回)
    }
    bool adoptedOut = false;
    {
        std::lock_guard<std::mutex> lk(xfM_);
        if (adopt && xfDecoder_ != nullptr) {
            decoder_ = std::move(xfDecoder_);
            adoptedOut = true;
        }
        xfDecoder_.reset();
    }
    if (adoptedOut) {
        // 新曲已解码头部搬运进 ring_(xf 已停止写入,残余有界)
        ring_.flushAll();
        std::vector<uint8_t> bounce(256 * 1024);
        for (;;) {
            const size_t n = ring2_.read(bounce.data(), bounce.size());
            if (n == 0) {
                break;
            }
            ring_.write(bounce.data(), n);
        }
    }
    ring2_.reset();
    xfEngaged_ = false;
    if (wasActive) {
        OH_LOG_Print(LOG_APP, LOG_INFO, 0, LOG_TAG, "crossfade aborted adopt=%{public}d", adoptedOut ? 1 : 0);
    }
    return adoptedOut;
}

// 渲染回调混音读:旧 ring_(gOut 线性淡出)+ 新 ring2_(gIn 线性淡入)F32 加权合成。
// 返回本块计入新曲时间轴的帧数(= 请求帧数;缺失按静音处理并照常推进窗口)。
size_t Engine::xfMixRead(uint8_t *out, size_t frames, int channels, OutputFormat srcFmt)
{
    const int srcBps = srcFmt == OutputFormat::U8 ? 1 : srcFmt == OutputFormat::S16LE ? 2 : 4;
    const size_t frameBytes = static_cast<size_t>(channels * srcBps);
    const size_t need = frames * frameBytes;
    if (xfTmpA_.size() < need) {
        xfTmpA_.resize(need);
    }
    if (xfTmpB_.size() < need) {
        xfTmpB_.resize(need);
    }
    if (xfTmpF_.size() < frames * static_cast<size_t>(channels)) {
        xfTmpF_.resize(frames * static_cast<size_t>(channels));
    }
    const size_t nOld = ring_.read(xfTmpA_.data(), need);
    const size_t nNew = ring2_.read(xfTmpB_.data(), need);
    const size_t oldFrames = nOld / frameBytes;
    const size_t newFrames = nNew / frameBytes;
    const double t = xfFadeFrames_ > 0
                         ? std::min(1.0, static_cast<double>(xfConsumed_) / static_cast<double>(xfFadeFrames_))
                         : 1.0;
    const float gOut = static_cast<float>(1.0 - t);
    const float gIn = oldFrames < frames ? 1.0f : static_cast<float>(t); // 旧流提前干:新流直接全量
    float *dst = reinterpret_cast<float *>(out);
    std::memset(dst, 0, frames * static_cast<size_t>(channels) * 4); // 缺帧区静音(underrun 兜底)
    if (oldFrames > 0) {
        timbrava::convertToInterleavedF32(xfTmpA_.data(), oldFrames * frameBytes, srcFmt, dst);
        for (size_t i = 0; i < oldFrames * static_cast<size_t>(channels); i++) {
            dst[i] *= gOut;
        }
    }
    if (newFrames > 0) {
        timbrava::convertToInterleavedF32(xfTmpB_.data(), newFrames * frameBytes, srcFmt, xfTmpF_.data());
        for (size_t i = 0; i < newFrames * static_cast<size_t>(channels); i++) {
            xfTmpF_[i] *= gIn;
        }
        for (size_t i = 0; i < newFrames * static_cast<size_t>(channels); i++) {
            dst[i] += xfTmpF_[i];
        }
    }
    xfConsumed_ += static_cast<int64_t>(frames);
    // 窗口走完(或新曲短于窗口且已耗尽)→ promote:ring2 残余搬运进 ring_,主解码线程接手
    if (xfConsumed_ >= xfFadeFrames_ || (xfConsumed_ >= xfTotal_ && xfTotal_ > 0)) {
        ring_.flushAll(); // 旧流残余废弃
        if (xfTmpA_.size() < 256 * 1024) {
            xfTmpA_.resize(256 * 1024);
        }
        for (;;) {
            const size_t n = ring2_.read(xfTmpA_.data(), 256 * 1024);
            if (n == 0) {
                break;
            }
            ring_.write(xfTmpA_.data(), n);
        }
        ring2_.abort(); // 解开 xf 线程可能阻塞的 write;其见 promoted 即退
        xfPromoted_ = true;
        xfActive_ = false;
        wakeCv_.notify_all();
        OH_LOG_Print(LOG_APP, LOG_INFO, 0, LOG_TAG, "crossfade promoted consumed=%{public}lld",
                     static_cast<long long>(xfConsumed_));
    }
    return frames;
}

// 渲染回调消费 frames 帧后调用:扣减交接账本头,扣穿(播到交界)即通知上层。
// 事件与实际听感同步(解码器读尽≠播到交界);回调块 ~10ms,一次消费穿两界概率≈0,不循环。
void Engine::consumeGaplessFrames(int64_t frames)
{
    if (frames <= 0) {
        return;
    }
    std::lock_guard<std::mutex> lk(boundsM_);
    if (gaplessBounds_.empty()) {
        return;
    }
    gaplessBounds_.front() -= frames;
    if (gaplessBounds_.front() <= 0) {
        const int64_t spill = -gaplessBounds_.front(); // 本块跨入新曲的帧数
        gaplessBounds_.erase(gaplessBounds_.begin());
        // 位置归位:新曲从 spill 起计(帧计数此前连续跨曲累计,若在交换时清零会把旧曲
        // 尾部时长误计入新曲位置——必须在渲染真正播到交界时归位)
        framesConsumed_.store(spill);
        pushEvent("{\"ev\":\"gaplessNext\"}");
        OH_LOG_Print(LOG_APP, LOG_INFO, 0, LOG_TAG, "gapless reached, notified");
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
    // 探测链:DSD(magic 确定性,最先)→ FLAC → WAV
    auto dsd = std::make_unique<DsdDecoder>();
    if (dsd->openFile(fd, TrackInfo{})) {
        decoder_ = std::move(dsd);
    } else {
        auto flac = std::make_unique<FlacDecoder>();
        if (flac->openFile(fd, TrackInfo{})) {
            decoder_ = std::move(flac);
        } else {
            auto wav = std::make_unique<WavDecoder>();
            if (wav->openFile(fd, TrackInfo{})) {
                decoder_ = std::move(wav);
            } else {
                *errMsg = "unsupported or corrupted file (dsd/flac/wav probe failed)";
                return false;
            }
        }
    }

    info_ = decoder_->info();
    fmt_ = decoder_->outFormat();
    // 频谱表按新采样率重建(禁用态下仅重置窗口,开销极小)
    timbrava::vizPrepare(info_.sampleRate, info_.channels);
    ring_.reset();
    framesConsumed_ = 0;
    eof_ = false;
    seeking_ = false;
    seekTargetFrames_ = -1;
    // crossfade 状态清零(stopTrack 已 abort,此处兜底复位全部过渡态)
    xfPending_ = false;
    xfActive_ = false;
    xfPromoted_ = false;
    xfEngaged_ = false;
    ring2_.reset();

    // 重采样状态复位(倍速在切曲/seek 后从当前帧继续计位)
    resFifo_.clear();
    resBase_ = 0;
    resIdx_ = 0;
    resPhase_ = 0.0;
    resCarryBuf_.clear();
    resDrained_ = false;

    // DSP(PEQ/RG/跳过静音)或倍速启用时渲染走 F32 管线;关闭时保持整型直通(比特完美)
    // crossfade(0.23.0):混音需 F32 域,启用时恒走 F32(混音窗口外的恒等路径听感无差)
    bool useDsp = dspActive() || speed_.load() != 1.0f || (xfEnabled_.load() && xfMs_.load() > 0);
    OutputFormat renderFmt = fmt_;
    if (useDsp && renderFmt != OutputFormat::F32LE) {
        renderFmt = OutputFormat::F32LE;
    }
    f32Render_ = (renderFmt == OutputFormat::F32LE);
    // 恒 prepare:让声道数/采样率始终有效(否则全关路径下播放中启用平衡时,
    // dspSetBalance 发布的参数 channels=0 不生效);声明(频段/RG/平衡)保留并按新率重算
    timbrava::dspPrepare(info_.sampleRate, info_.channels);
    timbrava::dspSetReplayGain(lastTrackGain_.load(), lastTrackPeak_.load(),
                               lastAlbumGain_.load(), lastAlbumPeak_.load(), rgMode_.load());
    out_ = std::make_unique<AudioOutput>();
    int channels = info_.channels;
    OutputFormat fmtCopy = fmt_;
    bool ok = out_->createWithFormat(
        info_, renderFmt,
        [this, channels, fmtCopy, renderFmt](OH_AudioRenderer *, void *, void *buffer, int32_t length) -> OH_AudioData_Callback_Result {
            if (length <= 0) {
                return AUDIO_DATA_CALLBACK_RESULT_VALID;
            }
            int srcBps = fmtCopy == OutputFormat::U8 ? 1 : fmtCopy == OutputFormat::S16LE ? 2 : 4;
            int frameBytes = channels * srcBps;
            if (frameBytes <= 0) {
                return AUDIO_DATA_CALLBACK_RESULT_INVALID;
            }
            if (seeking_.load()) {
                std::memset(buffer, 0, static_cast<size_t>(length));
                return AUDIO_DATA_CALLBACK_RESULT_VALID;
            }
            const float speed = speed_.load();
            if (speed != 1.0f) {
                this->produceSpeeded(static_cast<uint8_t *>(buffer), static_cast<size_t>(length),
                                     channels, fmtCopy, renderFmt == OutputFormat::F32LE);
                return AUDIO_DATA_CALLBACK_RESULT_VALID;
            }
            size_t n;
            if (renderFmt == OutputFormat::F32LE) {
                // F32 渲染:按输出帧数反推源字节数再读(修复旧实现按 F32 字节数读整型源的错位)
                const size_t outFrames = static_cast<size_t>(length) / (static_cast<size_t>(channels) * 4);
                const size_t want = outFrames * static_cast<size_t>(frameBytes);
                if (xfPending_.load()) {
                    // crossfade 倒计时:旧流全量渲染,消费满 xfStartIn_ 后进入混音窗口。
                    // 整型源先读入暂存再转 F32(原地扩容转换会覆写未读源字节,0.24.0 修复)
                    if (renderTmp_.size() < want) {
                        renderTmp_.resize(want);
                    }
                    n = ring_.read(renderTmp_.data(), want);
                    if (n > 0) {
                        size_t frames = n / static_cast<size_t>(frameBytes);
                        size_t floatOut = frames * static_cast<size_t>(channels) * 4;
                        timbrava::convertToInterleavedF32(renderTmp_.data(),
                                                          frames * static_cast<size_t>(frameBytes), fmtCopy,
                                                          reinterpret_cast<float *>(buffer));
                        if (dspActive()) {
                            timbrava::dspProcessInterleavedF32(reinterpret_cast<float *>(buffer), frames);
                        }
                        timbrava::vizFeedF32(reinterpret_cast<float *>(buffer), frames, channels);
                        n = floatOut;
                        framesConsumed_ += static_cast<int64_t>(frames);
                        const int64_t after = xfStartIn_.fetch_sub(static_cast<int64_t>(frames)) -
                                              static_cast<int64_t>(frames);
                        if (after <= 0) {
                            xfPending_ = false;
                            xfActive_ = true;
                            framesConsumed_ = 0; // 新曲时间轴从混音起点起计
                            pushEvent("{\"ev\":\"gaplessNext\"}");
                            OH_LOG_Print(LOG_APP, LOG_INFO, 0, LOG_TAG, "crossfade fade start");
                        }
                    }
                } else if (xfActive_.load()) {
                    // 混音窗口:旧 ring_ 淡出 + 新 ring2_ 淡入;走完 promote(新曲接管 ring_)
                    const size_t frames = this->xfMixRead(static_cast<uint8_t *>(buffer), outFrames, channels, fmtCopy);
                    if (dspActive()) {
                        timbrava::dspProcessInterleavedF32(reinterpret_cast<float *>(buffer), frames);
                    }
                    timbrava::vizFeedF32(reinterpret_cast<float *>(buffer), frames, channels);
                    n = frames * static_cast<size_t>(channels) * 4;
                    framesConsumed_ += static_cast<int64_t>(frames);
                } else {
                    // 整型源先读入暂存再转 F32:原地扩容转换(S16/U8→F32 每样本 2/1 字节→4 字节)
                    // 的写入会覆盖尚未读取的源字节,样本 1 起全为垃圾——电子音根因(0.24.0 修复)。
                    // S32→F32 等宽原地虽恰好安全,统一走暂存消除隐式约束。
                    if (renderTmp_.size() < want) {
                        renderTmp_.resize(want);
                    }
                    n = ring_.read(renderTmp_.data(), want);
                    if (n > 0) {
                        size_t frames = n / static_cast<size_t>(frameBytes);
                        size_t floatOut = frames * static_cast<size_t>(channels) * 4;
                        timbrava::convertToInterleavedF32(renderTmp_.data(),
                                                          frames * static_cast<size_t>(frameBytes), fmtCopy,
                                                          reinterpret_cast<float *>(buffer));
                        if (dspActive()) {
                            timbrava::dspProcessInterleavedF32(reinterpret_cast<float *>(buffer), frames);
                        }
                        // 频谱采集:DSP 之后(听到的内容),仅启用态计算(feed 内部检查)
                        timbrava::vizFeedF32(reinterpret_cast<float *>(buffer), frames, channels);
                        n = floatOut;
                        framesConsumed_ += static_cast<int64_t>(frames);
                        consumeGaplessFrames(static_cast<int64_t>(frames));
                    }
                }
            } else {
                n = ring_.read(static_cast<uint8_t *>(buffer), static_cast<size_t>(length));
                const int64_t framesRead = static_cast<int64_t>(n / static_cast<size_t>(frameBytes));
                framesConsumed_ += framesRead;
                consumeGaplessFrames(framesRead);
                // 比特完美整型直通路径同样采集(只读源缓冲,不动音频数据)
                if (framesRead > 0) {
                    timbrava::vizFeedInt(static_cast<uint8_t *>(buffer),
                                         static_cast<size_t>(framesRead), channels, fmtCopy);
                }
            }
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
    nextDecoder_.reset(); // gapless 预排随当前曲一并废弃(含 IDLE 早退分支)
    hasNext_ = false;
    abortFadeLocked(false); // crossfade 过渡随 stop 一并中止(xf 线程 join、ring2 复位)
    {
        std::lock_guard<std::mutex> lk(boundsM_);
        gaplessBounds_.clear();
    }
    curWrittenFrames_ = 0;
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
    {
        // crossfade:seek 即中止过渡。fade 已发声(Active)→ 时间轴属新曲,收编新曲解码器;
        // 仅排程(Pending)→ 时间轴仍属旧曲,维持旧解码器。
        std::lock_guard<std::mutex> lk(stateM_);
        abortFadeLocked(xfActive_.load());
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
    {
        std::lock_guard<std::mutex> lk(boundsM_);
        gaplessBounds_.clear(); // seek 打乱时间轴:放弃挂起的交接通知,重新记账
    }
    curWrittenFrames_ = 0;
    ring_.reset();
    // 重采样游标对齐 seek 目标(fifo 由渲染线程在下次回调时惰性重建)
    resFifo_.clear();
    resBase_ = target;
    resIdx_ = target;
    resPhase_ = 0.0;
    resCarryBuf_.clear();
    resDrained_ = false;
    ring_.setWritable(mode_.load() == EngineMode::PLAYING);
    // 预填 96KB 或 500ms 超时再放开渲染(P2 seek 优化:256KB/1s → 96KB/0.5s,目标 <300ms)
    for (int i = 0; i < 50 && mode_.load() == EngineMode::PLAYING; i++) {
        if (ring_.sizeLocked() >= 96 * 1024) {
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
            // gapless(M3):当前曲解码尽且已预排下一曲 → 交换解码器无缝续填 ring。
            // ring 内剩余旧曲尾部照常渲染,新曲数据直接续写,renderer 无感——真无缝。
            // crossfade(0.23.0):启用且旧流余量足够时改走过渡——xf 线程解码新曲入 ring2_,
            // 渲染回调混音;窗口过小(<250ms)退回 gapless swap。倍速≠1 时两者均禁用。
            if (hasNext_.load()) {
                std::lock_guard<std::mutex> lk(stateM_);
                if (nextDecoder_ != nullptr && decoder_ != nullptr) {
                    if (speed_.load() == 1.0f) {
                        const int chL = info_.channels > 0 ? info_.channels : 2;
                        const int bpsL = fmt_ == OutputFormat::U8 ? 1 : fmt_ == OutputFormat::S16LE ? 2 : 4;
                        const int64_t remainFrames =
                            static_cast<int64_t>(ring_.sizeLocked() / static_cast<size_t>(bpsL * chL));
                        const int rateL = info_.sampleRate > 0 ? info_.sampleRate : 44100;
                        const int64_t wantFade = xfEnabled_.load()
                                                     ? static_cast<int64_t>(xfMs_.load()) * rateL / 1000
                                                     : 0;
                        const int64_t fadeFrames = std::min(wantFade, remainFrames);
                        if (wantFade > 0 && fadeFrames >= rateL / 4 && f32Render_.load()) {
                            // F32 渲染守卫:整型直通分支无混音支持,若设置晚到仍选了整型,
                            // 此处退回 gapless swap(否则 pending 永不被消费,decode 线程卡死 park)
                            // (0.23.0 实测:新进程首曲 open 先于 setCrossfade 时命中)
                            // 先算好倒计再发起(engage 内部置 pending,渲染线程立刻可见)
                            xfStartIn_ = remainFrames - fadeFrames;
                            engageCrossfadeLocked(std::move(nextDecoder_), fadeFrames);
                            nextDecoder_.reset();
                            continue;
                        }
                        // 记账:本曲实际写入 ring 的帧数 = 渲染到下曲交界的距离
                        {
                            std::lock_guard<std::mutex> lk(boundsM_);
                            gaplessBounds_.push_back(curWrittenFrames_);
                        }
                        curWrittenFrames_ = 0;
                        decoder_ = std::move(nextDecoder_);
                        info_ = nextInfo_;
                        eof_ = false;
                        hasNext_ = false;
                        OH_LOG_Print(LOG_APP, LOG_INFO, 0, LOG_TAG,
                                     "gapless decoder swapped next_frames=%{public}lld pending_bounds=%{public}zu",
                                     static_cast<long long>(info_.totalFrames), gaplessBounds_.size());
                        continue;
                    }
                    nextDecoder_.reset(); // 倍速:放弃无缝
                    hasNext_ = false;
                }
                continue;
            }
            // crossfade 已排程/进行中:park 至 promote/abort,再收编新曲解码器续写 ring_
            if (xfPending_.load() || xfActive_.load() || xfPromoted_.load()) {
                while (!quit_.load() && (xfPending_.load() || xfActive_.load()) && !xfPromoted_.load()
                       && seekTargetFrames_.load() < 0) {
                    std::unique_lock<std::mutex> wl(wakeM_);
                    wakeCv_.wait_for(wl, std::chrono::milliseconds(50));
                }
                if (xfPromoted_.load() && !xfActive_.load()) {
                    // 等 xf 线程真正退出再收编:解码器由 xf 线程退出路径放入 xfDecoder_,
                    // promote 瞬间线程可能还在收尾(此前竞态扑空→promote 复位→新曲解码器
                    // 永久漏收→旧曲时间轴已尽仍发 end,自动切歌连跳/卡死,0.24.0 修复)。
                    // 只等标志、绝不在此 join:xfThread_ 句柄归持 stateM_ 的
                    // abortFade/engage/shutdown 独占管理——本处 join 会与其 3s 兜底
                    // detach 并发操作同一句柄(join/detach 竞态 SIGSEGV,压测实锤)。
                    // 等待加 3s 上限:异常滞留时放弃收编走 end,绝不冻结解码线程。
                    int waitedMs = 0;
                    while (!quit_.load() && xfThreadLive_.load() && waitedMs < 3000) {
                        std::unique_lock<std::mutex> wl(wakeM_);
                        wakeCv_.wait_for(wl, std::chrono::milliseconds(10));
                        waitedMs += 10;
                    }
                    std::unique_ptr<IDecoder> inc;
                    {
                        std::lock_guard<std::mutex> lk(xfM_);
                        inc = std::move(xfDecoder_);
                    }
                    if (inc != nullptr) {
                        std::lock_guard<std::mutex> lk(stateM_);
                        if (mode_.load() != EngineMode::IDLE) {
                            decoder_ = std::move(inc);
                            info_ = decoder_->info();
                            curWrittenFrames_ = 0;
                            eof_ = false;
                            OH_LOG_Print(LOG_APP, LOG_INFO, 0, LOG_TAG, "crossfade adopted by decode thread");
                        }
                    }
                    xfEngaged_ = false;
                    // ★ 复位 promote 标记:否则新曲自身的 EOF 会再次误入本分支,
                    // end 事件永不发出(0.23.0 实测 crossfade 后队列卡死不推进的根因)
                    xfPromoted_ = false;
                }
                continue;
            }
            if (ring_.sizeLocked() == 0) {
                // 倍速时等渲染线程把重采样尾部播完再发 end(否则最多截尾 ~1s)
                if (speed_.load() != 1.0f && !resDrained_.load()) {
                    std::unique_lock<std::mutex> lk(wakeM_);
                    wakeCv_.wait_for(lk, std::chrono::milliseconds(20));
                    continue;
                }
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
        curWrittenFrames_ += got; // 交接账本:按解码产出帧数记(部分写仅发生于 stop/seek,届时账本已清)
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
    if (xfThread_.joinable()) {
        xfThread_.join(); // 防 joinable 线程析构 terminate
    }
}

EngineMode Engine::mode() const { return mode_.load(); }

bool Engine::hasTrack() const { return mode_.load() != EngineMode::IDLE; }

void Engine::setPeqEnabled(bool on)
{
    peqEnabled_ = on;
    if (on) {
        timbrava::dspPrepare(info_.sampleRate > 0 ? info_.sampleRate : 44100,
                             info_.channels > 0 ? info_.channels : 2);
    }
    OH_LOG_Print(LOG_APP, LOG_INFO, 0, LOG_TAG, "dsp peq %{public}s", on ? "on" : "off");
}

void Engine::setPeqBand(int index, int type, float freq, float gainDb, float q)
{
    timbrava::dspSetPeqBand(index, type, freq, gainDb, q);
}

void Engine::setReplayGain(float trackGainDb, float trackPeak, float albumGainDb, float albumPeak, int mode)
{
    lastTrackGain_ = trackGainDb;
    lastTrackPeak_ = trackPeak;
    lastAlbumGain_ = albumGainDb;
    lastAlbumPeak_ = albumPeak;
    rgMode_ = mode;
    timbrava::dspSetReplayGain(trackGainDb, trackPeak, albumGainDb, albumPeak, mode);
    OH_LOG_Print(LOG_APP, LOG_INFO, 0, LOG_TAG, "dsp rg mode=%{public}d track=%{public}s", mode, std::to_string(trackGainDb).c_str());
}

void Engine::setSkipSilence(bool on)
{
    skipSilence_ = on;
    timbrava::dspSetSkipSilence(on);
    if (on) {
        // 保证 DSP 配置已按当前曲目 prepare(否则门控无采样率可用)
        timbrava::dspPrepare(info_.sampleRate > 0 ? info_.sampleRate : 44100,
                             info_.channels > 0 ? info_.channels : 2);
    }
    OH_LOG_Print(LOG_APP, LOG_INFO, 0, LOG_TAG, "dsp skip silence %{public}s", on ? "on" : "off");
}

void Engine::setSpeed(float speed)
{
    if (!(speed > 0.0f)) {
        speed = 1.0f;
    }
    speed_ = std::min(3.0f, std::max(0.25f, speed));
    if (speed_.load() != 1.0f) {
        // 倍速≠1 与 crossfade 互斥:过渡中改速 → 中止(已发声则收编新曲解码器续播)
        std::lock_guard<std::mutex> lk(stateM_);
        if (abortFadeLocked(xfActive_.load())) {
            // 重采样游标对齐新曲时间轴(fifo 由渲染线程惰性重建)
            resFifo_.clear();
            resBase_ = framesConsumed_.load();
            resIdx_ = resBase_;
            resPhase_ = 0.0;
            resCarryBuf_.clear();
            resDrained_ = false;
        }
    }
    OH_LOG_Print(LOG_APP, LOG_INFO, 0, LOG_TAG, "speed %{public}s", std::to_string(speed_.load()).c_str());
}

void Engine::setBalance(float balance, bool mono)
{
    float b = std::max(-1.0f, std::min(1.0f, balance));
    balance_.store(b);
    mono_.store(mono);
    timbrava::dspSetBalance(b, mono);
    OH_LOG_Print(LOG_APP, LOG_INFO, 0, LOG_TAG, "balance %{public}s mono=%{public}d",
                 std::to_string(b).c_str(), mono ? 1 : 0);
}

void Engine::setVizEnabled(bool on)
{
    timbrava::vizSetEnabled(on);
    OH_LOG_Print(LOG_APP, LOG_INFO, 0, LOG_TAG, "viz %{public}s", on ? "on" : "off");
}

bool Engine::balanceActive() const
{
    const float b = balance_.load();
    return mono_.load() || b > 0.001f || b < -0.001f;
}

bool Engine::dspActive() const
{
    return peqEnabled_.load() || rgMode_.load() != 0 || skipSilence_.load() || balanceActive();
}

// ReplayGain 扫描:独立解码器全曲解码 → 50ms 块 RMS → 95 分位。
// 在 napi 异步工作线程运行;与播放管线共享的只有 dsp.cpp 的分析静态区
// (ArkTS 侧保证同一时间只有一次扫描)。
bool Engine::analyzeTrack(int fd, float *outRmsDb, float *outPeak, int64_t *outDurationMs, std::string *errMsg)
{
    if (outRmsDb == nullptr || outPeak == nullptr || outDurationMs == nullptr || errMsg == nullptr) {
        return false;
    }
    std::unique_ptr<IDecoder> dec;
    auto flac = std::make_unique<FlacDecoder>();
    if (flac->openFile(fd, TrackInfo{})) {
        dec = std::move(flac);
    } else {
        auto wav = std::make_unique<WavDecoder>();
        if (wav->openFile(fd, TrackInfo{})) {
            dec = std::move(wav);
        } else {
            *errMsg = "unsupported codec for rg scan (flac/wav only)";
            return false;
        }
    }
    const TrackInfo info = dec->info();
    const int ch = info.channels > 0 ? info.channels : 2;
    const OutputFormat fmt = dec->outFormat();
    const int bps = fmt == OutputFormat::U8 ? 1 : fmt == OutputFormat::S16LE ? 2 : 4;

    timbrava::dspAnalyzeReset();
    std::vector<uint8_t> buf(256 * 1024);
    int64_t totalFrames = 0;
    for (;;) {
        const int64_t maxFrames = static_cast<int64_t>(buf.size()) / (static_cast<int64_t>(bps) * ch);
        const int64_t got = dec->readFrames(buf.data(), maxFrames, buf.size());
        if (got <= 0) {
            break;
        }
        totalFrames += got;
        std::vector<float> fbuf(static_cast<size_t>(got) * ch);
        timbrava::convertToInterleavedF32(buf.data(), static_cast<size_t>(got) * ch * bps, fmt, fbuf.data());
        timbrava::dspAnalyzeBlock(fbuf.data(), static_cast<size_t>(got), ch);
    }
    float rms = 0.0f;
    float peak = 0.0f;
    timbrava::dspAnalyzeFinish(&rms, &peak);
    *outRmsDb = rms;
    *outPeak = peak;
    *outDurationMs = info.sampleRate > 0 ? totalFrames * 1000 / info.sampleRate : 0;
    OH_LOG_Print(LOG_APP, LOG_INFO, 0, LOG_TAG, "analyze done frames=%{public}lld rms=%{public}s peak=%{public}s",
                 static_cast<long long>(totalFrames), std::to_string(rms).c_str(),
                 std::to_string(peak).c_str());
    return true;
}

// 波形包络(0.19.0):独立解码器整曲读一遍,按桶取峰值,全局归一化。
// 与 analyzeTrack 同构:flac/wav;DSD 整曲解码代价过高,不纳入(波形条仅 PCM 无损)。
bool Engine::analyzeEnvelope(int fd, int buckets, std::vector<float> &out, std::string *errMsg)
{
    if (errMsg == nullptr) {
        return false;
    }
    if (buckets <= 0 || buckets > 4096) {
        buckets = 400;
    }
    std::unique_ptr<IDecoder> dec;
    auto flac = std::make_unique<FlacDecoder>();
    if (flac->openFile(fd, TrackInfo{})) {
        dec = std::move(flac);
    } else {
        auto wav = std::make_unique<WavDecoder>();
        if (wav->openFile(fd, TrackInfo{})) {
            dec = std::move(wav);
        } else {
            *errMsg = "unsupported codec for envelope (flac/wav only)";
            return false;
        }
    }
    const TrackInfo info = dec->info();
    const int ch = info.channels > 0 ? info.channels : 2;
    const OutputFormat fmt = dec->outFormat();
    const int bps = fmt == OutputFormat::U8 ? 1 : fmt == OutputFormat::S16LE ? 2 : 4;

    out.assign(static_cast<size_t>(buckets), 0.0f);
    std::vector<uint8_t> buf(256 * 1024);
    int64_t frameIdx = 0;
    const double invTotal = info.totalFrames > 0 ? static_cast<double>(buckets) / static_cast<double>(info.totalFrames) : 0.0;
    std::vector<float> fbuf;
    for (;;) {
        const int64_t maxFrames = static_cast<int64_t>(buf.size()) / (static_cast<int64_t>(bps) * ch);
        const int64_t got = dec->readFrames(buf.data(), maxFrames, buf.size());
        if (got <= 0) {
            break;
        }
        fbuf.resize(static_cast<size_t>(got) * ch);
        timbrava::convertToInterleavedF32(buf.data(), static_cast<size_t>(got) * ch * bps, fmt, fbuf.data());
        for (int64_t f = 0; f < got; f++) {
            const int64_t bi = static_cast<int64_t>(static_cast<double>(frameIdx + f) * invTotal);
            size_t b = (bi >= 0 && bi < buckets) ? static_cast<size_t>(bi) : static_cast<size_t>(buckets - 1);
            const float *frame = fbuf.data() + static_cast<size_t>(f) * ch;
            float peak = 0.0f;
            for (int c = 0; c < ch; c++) {
                const float a = frame[c] < 0.0f ? -frame[c] : frame[c];
                if (a > peak) {
                    peak = a;
                }
            }
            if (peak > out[b]) {
                out[b] = peak;
            }
        }
        frameIdx += got;
    }
    // 全局归一化到 [0,1]
    float gmax = 0.0f;
    for (const float v : out) {
        if (v > gmax) {
            gmax = v;
        }
    }
    if (gmax > 1e-6f) {
        for (float &v : out) {
            v /= gmax;
        }
    }
    OH_LOG_Print(LOG_APP, LOG_INFO, 0, LOG_TAG, "envelope done frames=%{public}lld buckets=%{public}d",
                 static_cast<long long>(frameIdx), buckets);
    return true;
}

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

// ---------------- 倍速重采样(渲染回调线程) ----------------

// 向 resFifo_ 补充输入帧:读 ring → 完整帧组装 → 转 F32 → DSP。
// 返回 resIdx_ 之后(含当前对)可用的帧数是否达到 need。
bool Engine::feedResampler(int64_t needFrames, int channels, OutputFormat srcFmt)
{
    const int srcBps = srcFmt == OutputFormat::U8 ? 1 : srcFmt == OutputFormat::S16LE ? 2 : 4;
    const size_t frameBytes = static_cast<size_t>(channels * srcBps);
    if (resTmpBuf_.empty()) {
        resTmpBuf_.resize(64 * 1024);
    }
    for (;;) {
        const int64_t avail = static_cast<int64_t>(resFifo_.size() / static_cast<size_t>(channels)) -
                              (resIdx_ - resBase_);
        if (avail >= needFrames) {
            return true;
        }
        size_t n = ring_.read(resTmpBuf_.data(), resTmpBuf_.size());
        if (n > 0) {
            resCarryBuf_.insert(resCarryBuf_.end(), resTmpBuf_.data(), resTmpBuf_.data() + n);
        }
        const size_t frames = resCarryBuf_.size() / frameBytes;
        if (frames == 0) {
            return false; // ring 空(未 EOF)或 EOF 且无残余
        }
        const size_t useBytes = frames * frameBytes;
        const size_t oldFloats = resFifo_.size();
        resFifo_.resize(oldFloats + frames * static_cast<size_t>(channels));
        timbrava::convertToInterleavedF32(resCarryBuf_.data(), useBytes, srcFmt,
                                          resFifo_.data() + oldFloats);
        if (dspActive()) {
            timbrava::dspProcessInterleavedF32(resFifo_.data() + oldFloats, frames);
        }
        const size_t rem = resCarryBuf_.size() - useBytes;
        if (rem > 0) {
            std::memmove(resCarryBuf_.data(), resCarryBuf_.data() + useBytes, rem);
        }
        resCarryBuf_.resize(rem);
        // 惰性压缩:已消费帧过多时丢弃前段
        const int64_t consumedOff = resIdx_ - resBase_;
        if (consumedOff > 16384) {
            resFifo_.erase(resFifo_.begin(),
                           resFifo_.begin() + static_cast<long>(consumedOff * static_cast<int64_t>(channels)));
            resBase_ = resIdx_;
        }
    }
}

void Engine::produceSpeeded(uint8_t *out, size_t outBytes, int channels, OutputFormat renderFmt, bool f32Render)
{
    const int srcBps = renderFmt == OutputFormat::U8 ? 1 : renderFmt == OutputFormat::S16LE ? 2 : 4;
    const size_t outBps = f32Render ? 4u : static_cast<size_t>(srcBps);
    const size_t outFramesWanted = outBytes / (static_cast<size_t>(channels) * outBps);
    const double speed = speed_.load();
    size_t produced = 0;
    while (produced < outFramesWanted) {
        feedResampler(2, channels, fmt_);
        const int64_t avail = static_cast<int64_t>(resFifo_.size() / static_cast<size_t>(channels)) -
                              (resIdx_ - resBase_);
        if (avail <= 0) {
            if (eof_.load()) {
                resDrained_ = true; // 输入耗尽且已消费完:解码线程可发 end
            }
            break; // ring 暂空或尾部播完:本轮剩余填零
        }
        const float *f0 = resFifo_.data() + static_cast<size_t>(resIdx_ - resBase_) * channels;
        const float *f1 = (avail >= 2) ? f0 + channels : f0; // EOF 末帧:保持最后样本
        const float frac = static_cast<float>(resPhase_);
        if (f32Render) {
            float *dst = reinterpret_cast<float *>(out) + produced * channels;
            for (int c = 0; c < channels; ++c) {
                dst[c] = f0[c] + (f1[c] - f0[c]) * frac;
            }
        } else {
            // 整型渲染流:插值结果量化回渲染格式(speed ≠ 1 本身有损,可接受)
            uint8_t *dst = out + produced * static_cast<size_t>(channels) * srcBps;
            for (int c = 0; c < channels; ++c) {
                const float v = f0[c] + (f1[c] - f0[c]) * frac;
                if (renderFmt == OutputFormat::S16LE) {
                    int s = static_cast<int>(v * 32768.0f);
                    s = std::max(-32768, std::min(32767, s));
                    const uint16_t u = static_cast<uint16_t>(s);
                    dst[c * 2] = static_cast<uint8_t>(u & 0xFF);
                    dst[c * 2 + 1] = static_cast<uint8_t>((u >> 8) & 0xFF);
                } else if (renderFmt == OutputFormat::U8) {
                    int s = static_cast<int>(v * 128.0f) + 128;
                    s = std::max(0, std::min(255, s));
                    dst[c] = static_cast<uint8_t>(s);
                } else {
                    double d = static_cast<double>(v) * 2147483648.0;
                    if (d > 2147483647.0) d = 2147483647.0;
                    if (d < -2147483648.0) d = -2147483648.0;
                    const uint32_t u = static_cast<uint32_t>(static_cast<int32_t>(d));
                    dst[c * 4] = static_cast<uint8_t>(u & 0xFF);
                    dst[c * 4 + 1] = static_cast<uint8_t>((u >> 8) & 0xFF);
                    dst[c * 4 + 2] = static_cast<uint8_t>((u >> 16) & 0xFF);
                    dst[c * 4 + 3] = static_cast<uint8_t>((u >> 24) & 0xFF);
                }
            }
        }
        ++produced;
        resPhase_ += speed;
        while (resPhase_ >= 1.0) {
            resPhase_ -= 1.0;
            ++resIdx_;
        }
    }
    // 倍速路径频谱采集(插值成品即所听内容)
    if (produced > 0) {
        if (f32Render) {
            timbrava::vizFeedF32(reinterpret_cast<float *>(out), produced, channels);
        } else {
            timbrava::vizFeedInt(out, produced, channels, renderFmt);
        }
    }
    // 剩余填零
    const size_t filled = produced * static_cast<size_t>(channels) * outBps;
    if (filled < outBytes) {
        std::memset(out + filled, 0, outBytes - filled);
    }
    framesConsumed_ = resIdx_;
}

} // namespace timbrava

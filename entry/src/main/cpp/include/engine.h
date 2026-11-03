// 无损引擎:解码线程 + SPSC 环形缓冲 + OHAudio 渲染。命令进(NAPI)/事件轮询出(Flick 契约)。
#ifndef TIMBRAVA_ENGINE_H
#define TIMBRAVA_ENGINE_H

#include <atomic>
#include <condition_variable>
#include <deque>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "audio_output.h"
#include "dsp.h"
#include "decoder.h"
#include "ring_buffer.h"

namespace timbrava {

enum class EngineMode { IDLE, READY, PLAYING, PAUSED };

class Engine {
public:
    static Engine &instance();

    // JS 线程命令
    bool openTrack(int fd, std::string *errMsg, TrackInfo *outInfo);
    // gapless(M3):预排下一曲(fd 生命周期同 openTrack:native dup)。采样率/通道/位深
    // (及 DSD 率)与当前曲一致才接受;解码线程在当前曲 EOF 后交换解码器无缝续填。
    bool openNextTrack(int fd);
    void clearNextTrack();
    void play();
    void pause();
    void stopTrack();
    bool seekMs(int64_t ms, std::string *errMsg);
    void setVolume(float vol);
    bool hasTrack() const;
    EngineMode mode() const;
    int64_t positionMs();
    int64_t durationMs() const;
    void setPeqEnabled(bool on);
    void setPeqBand(int index, int type, float freq, float gainDb, float q);
    void setReplayGain(float trackGainDb, float trackPeak, float albumGainDb, float albumPeak, int mode);
    void setSkipSilence(bool on);
    void setSpeed(float speed);
    bool dspActive() const;
    // ReplayGain 扫描(同步,重活;由 napi 异步工作线程调用,勿在 JS 线程调):
    // 整曲解码测 95 分位块 RMS 与峰值。与播放引擎互不干扰(独立解码器实例)。
    bool analyzeTrack(int fd, float *outRmsDb, float *outPeak, int64_t *outDurationMs, std::string *errMsg);
    void pollEvents(std::vector<std::string> &out);
    void shutdown();

private:
    Engine() = default;
    ~Engine() = default;

    void ensureThread();
    void decodeLoop();
    void pushEvent(const std::string &json);
    void applySeek();
    // 倍速输出:读 ring → F32 → DSP → 线性插值(speed 变速变调)→ 按渲染格式打包。
    // 仅渲染回调线程调用。f32Render=false 时输出打包回整型渲染格式。
    void produceSpeeded(uint8_t *out, size_t outBytes, int channels, OutputFormat srcFmt, bool f32Render);
    // 向重采样 FIFO 补充输入帧(读 ring → 组帧 → F32 → DSP);仅渲染回调线程调用。
    bool feedResampler(int64_t needFrames, int channels, OutputFormat srcFmt);

    std::mutex stateM_; // 保护 info_/fmt_/decoder_/out_ 生命周期
    std::atomic<EngineMode> mode_{EngineMode::IDLE};
    TrackInfo info_{};
    OutputFormat fmt_ = OutputFormat::S16LE;
    std::unique_ptr<IDecoder> decoder_;
    std::unique_ptr<AudioOutput> out_;

    RingBuffer ring_{8u * 1024u * 1024u}; // 8MB,24/192/S32 约 5.3s
    // gapless 预排(nextDecoder_ 本体 stateM_ 保护;hasNext_ 供解码线程无锁快查)
    std::unique_ptr<IDecoder> nextDecoder_;
    TrackInfo nextInfo_{};
    std::atomic<bool> hasNext_{false};
    std::thread decodeThread_;
    bool threadStarted_ = false;
    std::atomic<bool> quit_{false};
    std::condition_variable wakeCv_;
    std::mutex wakeM_;

    std::atomic<int64_t> framesConsumed_{0};
    std::atomic<bool> eof_{false};
    std::atomic<bool> seeking_{false};
    std::atomic<bool> underrunSinceSeek_{false};
    std::atomic<int64_t> seekTargetFrames_{-1};
    std::atomic<float> volume_{1.0f};
    std::atomic<bool> peqEnabled_{false};
    std::atomic<bool> skipSilence_{false};
    std::atomic<float> speed_{1.0f};
    std::atomic<int> rgMode_{0};
    std::atomic<float> lastTrackGain_{0.0f};
    std::atomic<float> lastTrackPeak_{1.0f};
    std::atomic<float> lastAlbumGain_{0.0f};
    std::atomic<float> lastAlbumPeak_{1.0f};

    // 倍速线性插值重采样(仅渲染回调线程访问;变速变调,源时间轴计位)
    std::vector<float> resFifo_;   // 待插值输入帧(交错 F32,自 resBase_ 起连续)
    int64_t resBase_ = 0;          // resFifo_[0] 对应的源帧号
    int64_t resIdx_ = 0;           // 已消耗源帧数(= 插值游标整部)
    double resPhase_ = 0.0;        // 插值小数相位
    std::vector<uint8_t> resCarryBuf_;
    std::vector<uint8_t> resTmpBuf_; // ring 读临时缓冲(复用,避免回调内分配)
    std::atomic<bool> resDrained_{false}; // eof 后重采样尾部播完(解码线程等它再发 end)

    std::mutex evM_;
    std::deque<std::string> events_;
    int64_t lastUnderrunMs_ = 0; // 限流,同 2s 内不重复发
};

} // namespace timbrava

#endif

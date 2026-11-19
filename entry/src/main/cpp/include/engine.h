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
    void setBalance(float balance, bool mono);
    void setVizEnabled(bool on); // 频谱可视化开关(仅开关;表随 openTrack 按 sampleRate 重建)
    // crossfade(0.23.0):两曲重叠渐变。on+ms>0 启用;仅在 无损引擎+倍速=1+预排格式一致 时生效,
    // 触发点=当前曲解码 EOF(旧流余量 ≥ fade 窗口才走 crossfade,否则退回 gapless swap)。
    void setCrossfade(bool on, int ms);
    bool dspActive() const;
    bool balanceActive() const;
    // ReplayGain 扫描(同步,重活;由 napi 异步工作线程调用,勿在 JS 线程调):
    // 整曲解码测 95 分位块 RMS 与峰值。与播放引擎互不干扰(独立解码器实例)。
    bool analyzeTrack(int fd, float *outRmsDb, float *outPeak, int64_t *outDurationMs, std::string *errMsg);
    // 波形包络(0.19.0,同步,重活;napi 异步工作线程调用):整曲解码取 buckets 个
    // 峰值桶(每桶内最大绝对样本),全局归一化到 [0,1]。flac/wav,独立解码器实例。
    bool analyzeEnvelope(int fd, int buckets, std::vector<float> &out, std::string *errMsg);
    void pollEvents(std::vector<std::string> &out);
    void shutdown();

private:
    Engine() = default;
    ~Engine() = default;

    void ensureThread();
    void decodeLoop();
    void consumeGaplessFrames(int64_t frames);
    void pushEvent(const std::string &json);
    void applySeek();
    // crossfade(0.23.0):xf 线程解码下一曲 → ring2_;渲染回调混音。必须持 stateM_ 调用。
    void engageCrossfadeLocked(std::unique_ptr<IDecoder> inc, int64_t fadeFrames);
    // 中止过渡(abortFade 后旧流/新流语义见实现);adoptDecoder=true 时把 xf 解码器收回主链
    // (seek 场景:UI 时间轴已切新曲)。返回是否回收了未用完的解码器。
    bool abortFadeLocked(bool adoptDecoder);
    // 渲染回调混音读:旧 ring_ + 新 ring2_ 各取 frames 帧,F32 加权合成。返回混音帧数。
    size_t xfMixRead(uint8_t *out, size_t frames, int channels, OutputFormat srcFmt);

    // crossfade 状态(xfM_ 保护可变体;atomic 供渲染/解码线程快查)。锁序:stateM_ → xfM_
    std::mutex xfM_;
    std::atomic<bool> xfEnabled_{false};
    std::atomic<int> xfMs_{0};
    std::atomic<bool> f32Render_{false}; // 当前渲染格式是否 F32(openTrack 决定;混音仅在 F32 域可行)
    std::atomic<bool> xfPending_{false};  // 已排程:渲染消费 xfStartIn_ 帧后进入混音
    std::atomic<bool> xfActive_{false};   // 混音窗口进行中
    std::atomic<bool> xfPromoted_{false}; // 新曲已接管 ring_(旧流废弃)
    std::atomic<bool> xfEngaged_{false};  // 本曲交接已改走 crossfade(压制旧曲 end 事件)
    std::atomic<int64_t> xfStartIn_{0};   // 距混音开始还需消费的旧流帧数
    int64_t xfFadeFrames_ = 0;            // 混音窗口帧数(xfM_ 保护;渲染线程消费用)
    int64_t xfConsumed_ = 0;              // 混音窗口已消费帧数(仅渲染线程)
    std::atomic<int64_t> xfWritten_{0};   // xf 线程已写入 ring2_ 帧数
    std::atomic<int64_t> xfTotal_{0};     // 新曲总帧数(fade 截断判定)
    std::unique_ptr<IDecoder> xfDecoder_; // xf 线程持有;promote/abort 时交还主链
    RingBuffer ring2_{4u * 1024u * 1024u}; // 新曲混入缓冲(4MB;背压自限,~10s@192k/24)
    std::thread xfThread_;
    std::atomic<bool> xfThreadLive_{false};
    std::vector<uint8_t> xfTmpA_; // 渲染线程草稿(混音旧流字节/搬运 bounce;仅回调线程访问)
    std::vector<uint8_t> xfTmpB_; // 混音新流字节
    std::vector<float> xfTmpF_;   // 混音新流 F32
    // ring 读出暂存(仅回调线程访问)。整型源→F32 输出为扩容转换(每样本 2/1 字节→4 字节),
    // 直接以渲染 buffer 兼作源与目的地会覆写尚未读取的源字节(样本 1 起全为垃圾——0.24.0
    // 实测"播放中切曲出电子音"根因);整型数据必须先读入本暂存,再转换到渲染 buffer。
    std::vector<uint8_t> renderTmp_;
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
    // gapless 交接账本:每项 = 到下一曲交界还剩多少帧(按"实际写入 ring 的帧数"记账)。
    // 解码线程换曲时 push,渲染回调消费后扣减,扣穿即发 gaplessNext——事件与听感同步,
    // 且天然支持多曲连环预缓冲(ring 内排多曲时逐界通知)。seek/stop 清空。
    std::mutex boundsM_;
    std::vector<int64_t> gaplessBounds_;
    int64_t curWrittenFrames_ = 0; // 本曲已写入 ring 帧数(仅解码线程维护)
    std::atomic<bool> eof_{false};
    std::atomic<bool> seeking_{false};
    std::atomic<bool> underrunSinceSeek_{false};
    std::atomic<int64_t> seekTargetFrames_{-1};
    std::atomic<float> volume_{1.0f};
    std::atomic<bool> peqEnabled_{false};
    std::atomic<bool> skipSilence_{false};
    std::atomic<float> speed_{1.0f};
    std::atomic<float> balance_{0.0f};
    std::atomic<bool> mono_{false};
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

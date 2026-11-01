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
#include "decoder.h"
#include "ring_buffer.h"

namespace timbrava {

enum class EngineMode { IDLE, READY, PLAYING, PAUSED };

class Engine {
public:
    static Engine &instance();

    // JS 线程命令
    bool openTrack(int fd, std::string *errMsg, TrackInfo *outInfo);
    void play();
    void pause();
    void stopTrack();
    bool seekMs(int64_t ms, std::string *errMsg);
    void setVolume(float vol);
    bool hasTrack() const;
    EngineMode mode() const;
    int64_t positionMs();
    int64_t durationMs() const;
    void pollEvents(std::vector<std::string> &out);
    void shutdown();

private:
    Engine() = default;
    ~Engine() = default;

    void ensureThread();
    void decodeLoop();
    void pushEvent(const std::string &json);
    void applySeek();

    std::mutex stateM_; // 保护 info_/fmt_/decoder_/out_ 生命周期
    std::atomic<EngineMode> mode_{EngineMode::IDLE};
    TrackInfo info_{};
    OutputFormat fmt_ = OutputFormat::S16LE;
    std::unique_ptr<IDecoder> decoder_;
    std::unique_ptr<AudioOutput> out_;

    RingBuffer ring_{8u * 1024u * 1024u}; // 8MB,24/192/S32 约 5.3s
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

    std::mutex evM_;
    std::deque<std::string> events_;
    int64_t lastUnderrunMs_ = 0; // 限流,同 2s 内不重复发
};

} // namespace timbrava

#endif

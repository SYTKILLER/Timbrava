#ifndef TIMBRAVA_WAV_DECODER_H
#define TIMBRAVA_WAV_DECODER_H

#include "decoder.h"

#include <unistd.h>
#include <cstdint>
#include <cstdio>
#include <vector>

namespace timbrava {

// WAV/RIFF 解码(自研):PCM 8/16/24/32bit 整型 + 32bit 浮点。
// 8→U8 透传,16→S16,24→S32(左移对齐),32int→S32 透传,32float→F32。
class WavDecoder : public IDecoder {
public:
    WavDecoder() = default;
    ~WavDecoder() override;

    bool openFile(int fd, const TrackInfo &hint);
    void close();

    const TrackInfo &info() const override;
    OutputFormat outFormat() const override;
    int64_t currentFrame() const override;
    bool seekToFrame(int64_t frame) override;
    int64_t readFrames(uint8_t *dst, int64_t maxFrames, size_t dstCap) override;

private:
    enum class SourceFmt { PCM_U8, PCM_S16, PCM_S24, PCM_S32, IEEE_F32 };

    FILE *file_ = nullptr;
    TrackInfo info_{};
    SourceFmt src_ = SourceFmt::PCM_S16;
    int frameBytes_ = 0;        // 源帧字节数
    int64_t dataOffset_ = 0;    // data chunk 起始
    int64_t dataBytes_ = 0;     // data chunk 长度
    int64_t framesRead_ = 0;    // 已读帧游标
    std::vector<uint8_t> conv_; // 格式转换临时缓冲
};

} // namespace timbrava

#endif

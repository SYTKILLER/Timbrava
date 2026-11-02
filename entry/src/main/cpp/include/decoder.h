// 解码器公共接口:文件句柄打开 / 逐帧读取 / 精确 seek。
// 输出 PCM 交错排布,格式由 outFormat() 决定(与 OHAudio 渲染流一致)。
#ifndef TIMBRAVA_DECODER_H
#define TIMBRAVA_DECODER_H

#include <cstdint>
#include <cstdio>

namespace timbrava {

enum class OutputFormat { U8, S16LE, S32LE, F32LE };

struct TrackInfo {
    int sampleRate = 0;
    int channels = 0;
    int bitsPerSample = 0;   // 源位深(展示/路由用)
    int64_t totalFrames = 0; // 采样帧数;未知为 -1
    const char *codec = "";  // flac / wav
};

class IDecoder {
public:
    virtual ~IDecoder() = default;
    virtual const TrackInfo &info() const = 0;
    virtual OutputFormat outFormat() const = 0;
    // 返回下一个读取帧的索引(0 基)
    virtual int64_t currentFrame() const = 0;
    // seek 到指定帧;成功返回 true
    virtual bool seekToFrame(int64_t frame) = 0;
    // 读最多 maxFrames 帧进 dst(容量 dstCap 字节);返回实际帧数,0 = EOF
    virtual int64_t readFrames(uint8_t *dst, int64_t maxFrames, size_t dstCap) = 0;
};

// 整型源格式 → 交错 F32(dst 容量需 ≥ 输出样本数×4;U8/S16/S32(左对齐)/F32 透传)
void convertToInterleavedF32(const uint8_t *src, size_t byteCount, OutputFormat fmt, float *dst);

} // namespace timbrava

#endif

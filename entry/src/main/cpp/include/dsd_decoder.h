// DSD 解码(DSF/DFF,未压缩 DSD;DST 不支持)→ PCM 抽取保底(开发文档 §4.6 降级链)。
// 抽取:固定输出 88.2kHz F32;降频因子 = DSD 速率 / 88200(DSD64=32/128=64/256=128)。
// 低通:2×factor 位盒车平均(滑动 popcount),抗混叠近似,保底听感可接受。
// 输出恒为 F32LE;TrackInfo.sampleRate = 输出 PCM 率,dsdRate 保存原始 DSD 速率供展示。
#ifndef TIMBRAVA_DSD_DECODER_H
#define TIMBRAVA_DSD_DECODER_H

#include <cstdint>
#include <cstdio>

#include "decoder.h"
#include "mmap_file.h"

namespace timbrava {

enum class DsdContainer { NONE, DSF, DFF };

class DsdDecoder : public IDecoder {
public:
    DsdDecoder() = default;
    ~DsdDecoder() override;

    bool openFile(int fd, const TrackInfo &hint);
    void close();

    const TrackInfo &info() const override { return info_; }
    OutputFormat outFormat() const override { return OutputFormat::F32LE; }
    int64_t currentFrame() const override { return framePos_; }
    bool seekToFrame(int64_t frame) override;
    int64_t readFrames(uint8_t *dst, int64_t maxFrames, size_t dstCap) override;

private:
    int readU8(uint8_t *v);
    int readU32le(uint32_t *v);
    int readU64le(uint64_t *v);
    int readU32be(uint32_t *v);
    int readU64be(uint64_t *v);
    bool parseDsf();
    bool parseDff();
    // 文件绝对偏移读 n 字节:26-3 mmap 直读优先,否则 FILE* seek+read(头解析/降级路径)
    bool readBytesAt(int64_t off, uint8_t *dst, size_t n);
    // 某通道 [bytePos, bytePos+len) 字节的 1-bit 计数(DSF 块交织 / DFF 字节交织)
    uint64_t countOnesAt(int ch, int64_t bytePos, size_t len);
    // 单字节 1-bit 计数表
    static const uint8_t *popTab();

    FILE *file_ = nullptr;
    MmapFile mmap_; // 26-3:DSD 热路径(每帧逐通道取窗)指针直读,免 fseek/fread syscall
    TrackInfo info_{};
    DsdContainer kind_ = DsdContainer::NONE;

    int64_t dataStart_ = 0;     // DSD 数据区文件偏移
    int64_t dataSize_ = 0;      // DSD 数据区字节数
    int chNum_ = 2;
    int64_t blockSize_ = 4096;  // DSF 专用
    int factor_ = 32;           // 每输出帧消耗的 DSD 字节/通道(factor_bits/8)
    int64_t framesTotal_ = 0;
    int64_t framePos_ = 0;
    int64_t dsdRate_ = 0;
};

} // namespace timbrava

#endif

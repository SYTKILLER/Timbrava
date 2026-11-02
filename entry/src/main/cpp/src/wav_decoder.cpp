#include "wav_decoder.h"

#define LOG_TAG "[TimbravaNative][Wav]"
#include <hilog/log.h>

#include <algorithm>
#include <cstring>
#include <vector>

namespace timbrava {

WavDecoder::~WavDecoder() { close(); }

static uint32_t rdU32(const uint8_t *p)
{
    return static_cast<uint32_t>(p[0]) | (static_cast<uint32_t>(p[1]) << 8) | (static_cast<uint32_t>(p[2]) << 16) |
           (static_cast<uint32_t>(p[3]) << 24);
}

static uint16_t rdU16(const uint8_t *p)
{
    return static_cast<uint16_t>(p[0]) | (static_cast<uint16_t>(p[1]) << 8);
}

bool WavDecoder::openFile(int fd, const TrackInfo &hint)
{
    (void)hint;
    close();
    int dupFd = dup(fd);
    if (dupFd < 0) {
        return false;
    }
    file_ = fdopen(dupFd, "rb");
    if (file_ == nullptr) {
        ::close(dupFd);
        return false;
    }

    // dup 共享文件偏移:前序探测可能已消费字节,统一回卷
    if (fseek(file_, 0, SEEK_SET) != 0) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, 0, LOG_TAG, "fseek rewind fail errno=%{public}d", errno);
    }
    uint8_t hdr[12];
    if (fread(hdr, 1, 12, file_) != 12 || std::memcmp(hdr, "RIFF", 4) != 0 || std::memcmp(hdr + 8, "WAVE", 4) != 0) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, 0, LOG_TAG, "非 RIFF/WAVE 头");
        return false;
    }

    bool haveFmt = false;
    bool haveData = false;
    uint16_t audioFormat = 0;
    uint16_t channels = 0;
    uint32_t sampleRate = 0;
    uint16_t bits = 0;
    std::vector<uint8_t> chunk;

    // 遍历 chunk。对 rf64 等超长 data 支持:本仓 P0 以常规 wav 为准。
    while (!haveFmt || !haveData) {
        uint8_t ch[8];
        if (fread(ch, 1, 8, file_) != 8) {
            break;
        }
        uint32_t sz = rdU32(ch + 4);
        if (std::memcmp(ch, "fmt ", 4) == 0) {
            chunk.assign(sz > 64 ? 64 : sz, 0);
            size_t got = fread(chunk.data(), 1, chunk.size(), file_);
            if (got < 16) {
                break;
            }
            audioFormat = rdU16(chunk.data());
            channels = rdU16(chunk.data() + 2);
            sampleRate = rdU32(chunk.data() + 4);
            bits = rdU16(chunk.data() + 14);
            if (audioFormat == 0xFFFE && got >= 40) {
                // WAVE_FORMAT_EXTENSIBLE:读 SubFormat GUID 前 2 字节
                audioFormat = rdU16(chunk.data() + 24);
            }
            haveFmt = true;
            sz = 0; // 已按 chunk.size() 消费
        } else if (std::memcmp(ch, "data", 4) == 0) {
            dataOffset_ = ftell(file_);
            dataBytes_ = sz;
            haveData = true;
            // data 后通常无 fmt;若 fmt 在 data 后(不规范),P0 不支持
        }
        // 跳过未消费部分
        if (sz > 0) {
            if (fseek(file_, static_cast<long>(sz) + (sz & 1), SEEK_CUR) != 0) {
                break;
            }
        } else if (std::memcmp(ch, "fmt ", 4) != 0 && std::memcmp(ch, "data", 4) != 0) {
            // sz==0 的其它 chunk 无需跳
        }
    }

    if (!haveFmt || !haveData || channels == 0 || sampleRate == 0) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, 0, LOG_TAG, "fmt/data 缺失 fmt=%{public}d data=%{public}d",
                     haveFmt ? 1 : 0, haveData ? 1 : 0);
        return false;
    }
    if (fseek(file_, static_cast<long>(dataOffset_), SEEK_SET) != 0) {
        return false;
    }

    switch (audioFormat) {
        case 1: // PCM
            switch (bits) {
                case 8:
                    src_ = SourceFmt::PCM_U8;
                    break;
                case 16:
                    src_ = SourceFmt::PCM_S16;
                    break;
                case 24:
                    src_ = SourceFmt::PCM_S24;
                    break;
                case 32:
                    src_ = SourceFmt::PCM_S32;
                    break;
                default:
                    OH_LOG_Print(LOG_APP, LOG_ERROR, 0, LOG_TAG, "不支持位深 %{public}d", bits);
                    return false;
            }
            break;
        case 3:
            if (bits != 32) {
                OH_LOG_Print(LOG_APP, LOG_ERROR, 0, LOG_TAG, "不支持 float 位深 %{public}d", bits);
                return false;
            }
            src_ = SourceFmt::IEEE_F32;
            break;
        default:
            OH_LOG_Print(LOG_APP, LOG_ERROR, 0, LOG_TAG, "不支持编码 %{public}d(仅 PCM/float)", audioFormat);
            return false;
    }

    info_.sampleRate = static_cast<int>(sampleRate);
    info_.channels = channels;
    info_.bitsPerSample = bits;
    info_.totalFrames = dataBytes_ / (bits / 8 * channels);
    info_.codec = "wav";
    frameBytes_ = bits / 8 * channels;
    if (dataBytes_ % frameBytes_ != 0) {
        dataBytes_ -= dataBytes_ % frameBytes_;
    }
    OH_LOG_Print(LOG_APP, LOG_INFO, 0, LOG_TAG, "open ok rate=%{public}u ch=%{public}d bits=%{public}d bytes=%{public}lld",
                 sampleRate, channels, bits, static_cast<long long>(dataBytes_));
    return true;
}

void WavDecoder::close()
{
    if (file_ != nullptr) {
        fclose(file_);
        file_ = nullptr;
    }
}

const TrackInfo &WavDecoder::info() const { return info_; }

OutputFormat WavDecoder::outFormat() const
{
    switch (src_) {
        case SourceFmt::PCM_U8:
            return OutputFormat::U8;
        case SourceFmt::PCM_S16:
            return OutputFormat::S16LE;
        case SourceFmt::PCM_S24:
        case SourceFmt::PCM_S32:
            return OutputFormat::S32LE;
        case SourceFmt::IEEE_F32:
            return OutputFormat::F32LE;
    }
    return OutputFormat::S16LE;
}

int64_t WavDecoder::currentFrame() const { return framesRead_; }

bool WavDecoder::seekToFrame(int64_t frame)
{
    if (file_ == nullptr || frame < 0) {
        return false;
    }
    int64_t maxFrame = info_.totalFrames;
    if (frame > maxFrame) {
        frame = maxFrame;
    }
    if (fseek(file_, static_cast<long>(dataOffset_ + frame * frameBytes_), SEEK_SET) != 0) {
        return false;
    }
    framesRead_ = frame;
    return true;
}

int64_t WavDecoder::readFrames(uint8_t *dst, int64_t maxFrames, size_t dstCap)
{
    if (file_ == nullptr || maxFrames <= 0) {
        return 0;
    }
    OutputFormat of = outFormat();
    int dstBytesPerSample = of == OutputFormat::U8 ? 1 : of == OutputFormat::S16LE ? 2 : of == OutputFormat::F32LE ? 4 : 4;
    size_t dstFrameBytes = static_cast<size_t>(dstBytesPerSample * info_.channels);
    int64_t canOut = std::min<int64_t>(maxFrames, static_cast<int64_t>(dstCap / dstFrameBytes));
    // 源剩余
    int64_t remain = (dataBytes_ / frameBytes_) - framesRead_;
    if (remain <= 0) {
        return 0;
    }
    int64_t want = std::min(canOut, remain);
    if (want <= 0) {
        return 0;
    }

    if (of == OutputFormat::S16LE || of == OutputFormat::U8) {
        // 源即目标布局,直读
        size_t got = fread(dst, 1, static_cast<size_t>(want * frameBytes_), file_);
        int64_t frames = static_cast<int64_t>(got) / frameBytes_;
        framesRead_ += frames;
        return frames;
    }

    // 需转换:24→S32<<8,32int→透传,32float→透传
    conv_.resize(static_cast<size_t>(want * frameBytes_));
    size_t got = fread(conv_.data(), 1, conv_.size(), file_);
    int64_t frames = static_cast<int64_t>(got) / frameBytes_;
    if (frames <= 0) {
        return 0;
    }
    const int ch = info_.channels;
    if (src_ == SourceFmt::PCM_S24) {
        for (int64_t i = 0; i < frames * ch; i++) {
            const uint8_t *s = conv_.data() + i * 3;
            int32_t v = static_cast<int32_t>(static_cast<uint32_t>(s[0]) | (static_cast<uint32_t>(s[1]) << 8) |
                                             (static_cast<uint32_t>(s[2]) << 16));
            // 符号扩展到 24 位再左移 8 位为 32bit 左对齐
            if (v & 0x800000) {
                v |= static_cast<int32_t>(0xFF000000u);
            }
            reinterpret_cast<int32_t *>(dst)[i] = v << 8;
        }
    } else if (src_ == SourceFmt::PCM_S32) {
        std::memcpy(dst, conv_.data(), static_cast<size_t>(frames * frameBytes_));
    } else { // IEEE_F32
        std::memcpy(dst, conv_.data(), static_cast<size_t>(frames * frameBytes_));
    }
    framesRead_ += frames;
    return frames;
}

} // namespace timbrava

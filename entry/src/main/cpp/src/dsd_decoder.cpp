#include "dsd_decoder.h"

#include <algorithm>
#include <array>
#include <cstring>
#include <unistd.h>

#define LOG_TAG "[TimbravaNative][Dsd]"
#include <hilog/log.h>

namespace timbrava {

namespace {
constexpr int kPcmOutRate = 88200; // DSD 抽取目标 PCM 率(DSD64/128/256 均整除)
} // namespace

DsdDecoder::~DsdDecoder()
{
    close();
}

const uint8_t *DsdDecoder::popTab()
{
    static const std::array<uint8_t, 256> kTab = [] {
        std::array<uint8_t, 256> a{};
        for (int i = 0; i < 256; ++i) {
            int c = 0;
            for (int b = 0; b < 8; ++b) {
                if ((i >> b) & 1) {
                    ++c;
                }
            }
            a[static_cast<size_t>(i)] = static_cast<uint8_t>(c);
        }
        return a;
    }();
    return kTab.data();
}

int DsdDecoder::readU8(uint8_t *v)
{
    return fread(v, 1, 1, file_) == 1 ? 0 : -1;
}

int DsdDecoder::readU32le(uint32_t *v)
{
    uint8_t b[4];
    if (fread(b, 1, 4, file_) != 4) {
        return -1;
    }
    *v = static_cast<uint32_t>(b[0]) | (static_cast<uint32_t>(b[1]) << 8) |
         (static_cast<uint32_t>(b[2]) << 16) | (static_cast<uint32_t>(b[3]) << 24);
    return 0;
}

int DsdDecoder::readU64le(uint64_t *v)
{
    uint8_t b[8];
    if (fread(b, 1, 8, file_) != 8) {
        return -1;
    }
    *v = 0;
    for (int i = 7; i >= 0; --i) {
        *v = (*v << 8) | b[i];
    }
    return 0;
}

int DsdDecoder::readU32be(uint32_t *v)
{
    uint8_t b[4];
    if (fread(b, 1, 4, file_) != 4) {
        return -1;
    }
    *v = (static_cast<uint32_t>(b[0]) << 24) | (static_cast<uint32_t>(b[1]) << 16) |
         (static_cast<uint32_t>(b[2]) << 8) | static_cast<uint32_t>(b[3]);
    return 0;
}

int DsdDecoder::readU64be(uint64_t *v)
{
    uint8_t b[8];
    if (fread(b, 1, 8, file_) != 8) {
        return -1;
    }
    *v = 0;
    for (int i = 0; i < 8; ++i) {
        *v = (*v << 8) | b[i];
    }
    return 0;
}

bool DsdDecoder::openFile(int fd, const TrackInfo &hint)
{
    (void)hint;
    close();
    const int dupFd = dup(fd);
    if (dupFd < 0) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, 0, LOG_TAG, "dup fd fail errno=%{public}d", errno);
        return false;
    }
    file_ = fdopen(dupFd, "rb");
    if (file_ == nullptr) {
        ::close(dupFd);
        return false;
    }
    if (fseek(file_, 0, SEEK_SET) != 0) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, 0, LOG_TAG, "fseek rewind fail");
    }

    uint8_t magic[4] = {0};
    if (fread(magic, 1, 4, file_) != 4) {
        return false;
    }
    if (std::memcmp(magic, "DSD ", 4) == 0) {
        kind_ = DsdContainer::DSF;
        if (!parseDsf()) {
            close();
            return false;
        }
    } else if (std::memcmp(magic, "FRM8", 4) == 0) {
        kind_ = DsdContainer::DFF;
        if (!parseDff()) {
            close();
            return false;
        }
    } else {
        close();
        return false;
    }

    info_.sampleRate = kPcmOutRate;
    info_.channels = chNum_;
    info_.bitsPerSample = 1; // DSD 语义位深(UI 显示 DSD 徽章)
    info_.totalFrames = framesTotal_;
    info_.codec = "dsd";
    info_.dsdRate = static_cast<int>(dsdRate_);
    OH_LOG_Print(LOG_APP, LOG_INFO, 0, LOG_TAG,
                 "open ok kind=%{public}s dsdRate=%{public}d ch=%{public}d outFrames=%{public}lld",
                 kind_ == DsdContainer::DSF ? "dsf" : "dff", static_cast<int>(dsdRate_), chNum_,
                 static_cast<long long>(framesTotal_));
    return true;
}

bool DsdDecoder::parseDsf()
{
    uint64_t chunkSize = 0;
    if (readU64le(&chunkSize) != 0) {
        return false;
    }
    uint64_t totalFileSize = 0;
    uint64_t metaPtr = 0;
    if (readU64le(&totalFileSize) != 0 || readU64le(&metaPtr) != 0) {
        return false;
    }
    uint8_t tag[4] = {0};
    if (fread(tag, 1, 4, file_) != 4 || std::memcmp(tag, "fmt ", 4) != 0) {
        return false;
    }
    uint64_t fmtSize = 0;
    if (readU64le(&fmtSize) != 0) {
        return false;
    }
    uint32_t fmtVersion = 0;
    uint32_t formatId = 0;
    uint32_t channelType = 0;
    uint32_t channelNum = 0;
    uint32_t rate = 0;
    uint32_t bits = 0;
    uint64_t sampleCount = 0;
    uint32_t blockSize = 0;
    uint32_t reserved = 0;
    if (readU32le(&fmtVersion) != 0 || readU32le(&formatId) != 0 || readU32le(&channelType) != 0 ||
        readU32le(&channelNum) != 0 || readU32le(&rate) != 0 || readU32le(&bits) != 0 ||
        readU64le(&sampleCount) != 0 || readU32le(&blockSize) != 0 || readU32le(&reserved) != 0) {
        return false;
    }
    if (channelNum < 1 || channelNum > 8) {
        OH_LOG_Print(LOG_APP, LOG_WARN, 0, LOG_TAG, "dsf bad channelNum %{public}d", channelNum);
        return false;
    }
    if (rate != 2822400 && rate != 5644800 && rate != 11353600) {
        OH_LOG_Print(LOG_APP, LOG_WARN, 0, LOG_TAG, "dsf unsupported rate %{public}d", rate);
        return false;
    }
    if (bits != 1) {
        OH_LOG_Print(LOG_APP, LOG_WARN, 0, LOG_TAG, "dsf unsupported bitsPerSample %{public}d", bits);
        return false;
    }
    if (fread(tag, 1, 4, file_) != 4 || std::memcmp(tag, "data", 4) != 0) {
        return false;
    }
    uint64_t dataSize = 0;
    if (readU64le(&dataSize) != 0) {
        return false;
    }
    dataStart_ = ftell(file_);
    dataSize_ = static_cast<int64_t>(dataSize);
    chNum_ = static_cast<int>(channelNum);
    blockSize_ = blockSize > 0 ? static_cast<int64_t>(blockSize) : 4096;
    dsdRate_ = static_cast<int64_t>(rate);
    if (rate % kPcmOutRate != 0) {
        return false;
    }
    const int factorBits = rate / kPcmOutRate; // 32/64/128 位每输出样本
    factor_ = factorBits / 8;                  // 每输出帧每通道消耗的 DSD 字节
    framesTotal_ = static_cast<int64_t>(sampleCount) / factorBits;
    return framesTotal_ > 0;
}

bool DsdDecoder::parseDff()
{
    uint64_t frmSize = 0;
    uint8_t form[4] = {0};
    if (readU64be(&frmSize) != 0 || fread(form, 1, 4, file_) != 4 || std::memcmp(form, "DSD ", 4) != 0) {
        return false;
    }
    uint32_t rate = 0;
    int channels = 0;
    bool haveRate = false;
    bool haveCh = false;
    bool haveData = false;
    int64_t end = -1;
    for (;;) {
        uint8_t id[4] = {0};
        if (fread(id, 1, 4, file_) != 4) {
            break;
        }
        uint64_t sz = 0;
        if (readU64be(&sz) != 0) {
            break;
        }
        const int64_t payload = ftell(file_);
        end = payload + static_cast<int64_t>(sz);
        if (std::memcmp(id, "FS  ", 4) == 0) {
            uint32_t r = 0;
            if (readU32be(&r) != 0) {
                return false;
            }
            rate = r;
            haveRate = true;
        } else if (std::memcmp(id, "CHNL", 4) == 0) {
            uint16_t n = 0;
            uint8_t b2[2];
            if (fread(b2, 1, 2, file_) != 2) {
                return false;
            }
            n = static_cast<uint16_t>((b2[0] << 8) | b2[1]);
            channels = n;
            haveCh = true;
        } else if (std::memcmp(id, "CMPR", 4) == 0) {
            uint8_t type[4] = {0};
            if (fread(type, 1, 4, file_) != 4) {
                return false;
            }
            if (std::memcmp(type, "DST ", 4) == 0) {
                OH_LOG_Print(LOG_APP, LOG_WARN, 0, LOG_TAG, "dff DST compression unsupported");
                return false;
            }
        } else if (std::memcmp(id, "DSD ", 4) == 0) {
            if (haveRate && haveCh && channels >= 1 && rate % kPcmOutRate == 0) {
                dataStart_ = payload;
                dataSize_ = static_cast<int64_t>(sz);
                haveData = true;
            }
        }
        if (end <= payload) {
            break; // 非法尺寸防护
        }
        if (fseek(file_, end, SEEK_SET) != 0) {
            break;
        }
        if (haveData) {
            break; // 首个 DSD 数据块即用(后续 DST/ID3 忽略)
        }
    }
    if (!haveRate || !haveCh || !haveData || channels < 1 || channels > 8) {
        OH_LOG_Print(LOG_APP, LOG_WARN, 0, LOG_TAG, "dff missing chunks rate=%{public}d ch=%{public}d",
                     rate, channels);
        return false;
    }
    if (rate != 2822400 && rate != 5644800 && rate != 11353600) {
        OH_LOG_Print(LOG_APP, LOG_WARN, 0, LOG_TAG, "dff unsupported rate %{public}d", rate);
        return false;
    }
    chNum_ = channels;
    dsdRate_ = static_cast<int64_t>(rate);
    const int factorBits = rate / kPcmOutRate;
    factor_ = factorBits / 8;
    const int64_t bytesPerCh = dataSize_ / chNum_;
    framesTotal_ = bytesPerCh * 8 / factorBits;
    return framesTotal_ > 0;
}

void DsdDecoder::close()
{
    if (file_ != nullptr) {
        fclose(file_);
        file_ = nullptr;
    }
    kind_ = DsdContainer::NONE;
    framesTotal_ = 0;
    framePos_ = 0;
    dataStart_ = 0;
    dataSize_ = 0;
}

uint64_t DsdDecoder::countOnesAt(int ch, int64_t bytePos, size_t len)
{
    if (len == 0) {
        return 0;
    }
    const uint8_t *tab = popTab();
    uint64_t ones = 0;
    if (kind_ == DsdContainer::DSF) {
        // 块交织:文件偏移 = dataStart + (block*chNum + ch) * blockSize + off
        size_t got = 0;
        std::array<uint8_t, 512> buf;
        while (got < len) {
            const int64_t p = bytePos + static_cast<int64_t>(got);
            const int64_t block = p / blockSize_;
            const int64_t off = p % blockSize_;
            size_t take = static_cast<size_t>(std::min<int64_t>(static_cast<int64_t>(len - got),
                                                                blockSize_ - off));
            take = std::min(take, buf.size());
            if (fseek(file_, dataStart_ + (block * chNum_ + ch) * blockSize_ + off, SEEK_SET) != 0) {
                break;
            }
            if (fread(buf.data(), 1, take, file_) != take) {
                break;
            }
            for (size_t i = 0; i < take; ++i) {
                ones += tab[buf[i]];
            }
            got += take;
        }
        return ones;
    }
    // DFF:字节交织(通道 c 的字节位于跨度内 idx ≡ c mod chNum_)
    std::array<uint8_t, 512> buf;
    const size_t span = len * static_cast<size_t>(chNum_);
    size_t got = 0;
    while (got < span) {
        const size_t take = std::min(span - got, buf.size());
        if (fseek(file_, dataStart_ + (bytePos * chNum_) + static_cast<int64_t>(got), SEEK_SET) != 0) {
            break;
        }
        if (fread(buf.data(), 1, take, file_) != take) {
            break;
        }
        for (size_t i = 0; i < take; ++i) {
            if ((got + i) % static_cast<size_t>(chNum_) == static_cast<size_t>(ch)) {
                ones += tab[buf[i]];
            }
        }
        got += take;
    }
    return ones;
}

bool DsdDecoder::seekToFrame(int64_t frame)
{
    if (kind_ == DsdContainer::NONE || file_ == nullptr) {
        return false;
    }
    if (frame < 0) {
        frame = 0;
    }
    if (frame > framesTotal_) {
        frame = framesTotal_;
    }
    framePos_ = frame;
    return true;
}

int64_t DsdDecoder::readFrames(uint8_t *dst, int64_t maxFrames, size_t dstCap)
{
    if (kind_ == DsdContainer::NONE || file_ == nullptr || maxFrames <= 0) {
        return 0;
    }
    const int64_t want = std::min<int64_t>(maxFrames, framesTotal_ - framePos_);
    if (want <= 0) {
        return 0;
    }
    // F32 输出:dst 容量校验
    const size_t needBytes = static_cast<size_t>(want) * chNum_ * 4;
    if (needBytes > dstCap) {
        const int64_t fit = static_cast<int64_t>(dstCap / (static_cast<size_t>(chNum_) * 4));
        return fit <= 0 ? 0 : readFrames(dst, fit, dstCap);
    }
    float *out = reinterpret_cast<float *>(dst);
    const size_t winBytes = static_cast<size_t>(2 * factor_); // 盒车窗口字节数
    const double totalBits = static_cast<double>(winBytes) * 8.0;
    for (int64_t f = 0; f < want; ++f) {
        const int64_t pos = (framePos_ + f) * factor_;
        for (int c = 0; c < chNum_; ++c) {
            const uint64_t ones = countOnesAt(c, pos, winBytes);
            out[static_cast<size_t>(f) * chNum_ + c] =
                static_cast<float>((static_cast<double>(ones) * 2.0 - totalBits) / totalBits);
        }
    }
    framePos_ += want;
    return want;
}

} // namespace timbrava

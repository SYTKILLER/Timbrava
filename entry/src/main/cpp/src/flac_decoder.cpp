// FLAC 解码:dr_flac(公有领域,第三方登记见开发文档 §13)。
// 经 FILE*(fd dup)流式读取;16bit→S16,其余→S32(dr_flac s32 左对齐,天然匹配 S32LE 容器)。
#define DR_FLAC_IMPLEMENTATION
#include "flac_decoder.h"

#include <algorithm>

#define LOG_TAG "[TimbravaNative][Flac]"
#include <hilog/log.h>

namespace timbrava {

FlacDecoder::FlacDecoder() = default;

FlacDecoder::~FlacDecoder()
{
    close();
}

static size_t FlacReadCb(void *userData, void *buffer, size_t bytesToRead)
{
    FILE *f = static_cast<FILE *>(userData);
    if (f == nullptr || bytesToRead == 0) {
        return 0;
    }
    return fread(buffer, 1, bytesToRead, f);
}

static drflac_bool32 FlacSeekCb(void *userData, int offset, drflac_seek_origin origin)
{
    FILE *f = static_cast<FILE *>(userData);
    if (f == nullptr) {
        return DRFLAC_FALSE;
    }
    return fseek(f, offset, origin == DRFLAC_SEEK_SET ? SEEK_SET : SEEK_CUR) == 0 ? DRFLAC_TRUE : DRFLAC_FALSE;
}

static drflac_bool32 FlacTellCb(void *userData, drflac_int64 *offset)
{
    FILE *f = static_cast<FILE *>(userData);
    if (f == nullptr) {
        return DRFLAC_FALSE;
    }
    *offset = ftell(f);
    return DRFLAC_TRUE;
}

bool FlacDecoder::openFile(int fd, const TrackInfo &hint)
{
    (void)hint;
    close();
    int dupFd = dup(fd);
    if (dupFd < 0) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, 0, LOG_TAG, "dup fd fail errno=%{public}d", errno);
        return false;
    }
    file_ = fdopen(dupFd, "rb");
    if (file_ == nullptr) {
        ::close(dupFd);
        OH_LOG_Print(LOG_APP, LOG_ERROR, 0, LOG_TAG, "fdopen fail errno=%{public}d", errno);
        return false;
    }
    flac_ = drflac_open(FlacReadCb, FlacSeekCb, FlacTellCb, file_, nullptr);
    if (flac_ == nullptr) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, 0, LOG_TAG, "drflac_open fail(非 FLAC 或头损坏)");
        return false;
    }
    info_.sampleRate = static_cast<int>(flac_->sampleRate);
    info_.channels = static_cast<int>(flac_->channels);
    info_.bitsPerSample = static_cast<int>(flac_->bitsPerSample);
    info_.totalFrames = static_cast<int64_t>(flac_->totalPCMFrameCount);
    info_.codec = "flac";
    OH_LOG_Print(LOG_APP, LOG_INFO, 0, LOG_TAG, "open ok rate=%{public}d ch=%{public}d bits=%{public}d frames=%{public}lld",
                 info_.sampleRate, info_.channels, info_.bitsPerSample, static_cast<long long>(info_.totalFrames));
    return true;
}

void FlacDecoder::close()
{
    if (flac_ != nullptr) {
        drflac_close(flac_);
        flac_ = nullptr;
    }
    if (file_ != nullptr) {
        fclose(file_);
        file_ = nullptr;
    }
}

const TrackInfo &FlacDecoder::info() const { return info_; }

OutputFormat FlacDecoder::outFormat() const
{
    return info_.bitsPerSample <= 16 ? OutputFormat::S16LE : OutputFormat::S32LE;
}

int64_t FlacDecoder::currentFrame() const
{
    return flac_ == nullptr ? 0 : static_cast<int64_t>(flac_->currentPCMFrame);
}

bool FlacDecoder::seekToFrame(int64_t frame)
{
    if (flac_ == nullptr) {
        return false;
    }
    // 优先 dr_flac 内部 seektable;无表则按平均码率估算 + 帧同步
    return drflac_seek_to_pcm_frame(flac_, static_cast<drflac_uint64>(frame)) == DRFLAC_TRUE;
}

int64_t FlacDecoder::readFrames(uint8_t *dst, int64_t maxFrames, size_t dstCap)
{
    if (flac_ == nullptr || maxFrames <= 0) {
        return 0;
    }
    int bytesPerSample = outFormat() == OutputFormat::S16LE ? 2 : 4;
    int frameBytes = bytesPerSample * info_.channels;
    // 分段填充,避免超 dstCap
    int64_t read = 0;
    while (read < maxFrames) {
        size_t remaining = dstCap - static_cast<size_t>(read * frameBytes);
        if (remaining < static_cast<size_t>(frameBytes)) {
            break;
        }
        int64_t batch = std::min<int64_t>(maxFrames - read, remaining / frameBytes);
        if (batch > 16384) {
            batch = 16384;
        }
        uint64_t got = 0;
        if (outFormat() == OutputFormat::S16LE) {
            got = drflac_read_pcm_frames_s16(flac_, static_cast<drflac_uint64>(batch),
                                             reinterpret_cast<drflac_int16 *>(dst + read * frameBytes));
        } else {
            got = drflac_read_pcm_frames_s32(flac_, static_cast<drflac_uint64>(batch),
                                             reinterpret_cast<drflac_int32 *>(dst + read * frameBytes));
        }
        if (got == 0) {
            break;
        }
        read += static_cast<int64_t>(got);
        if (got < static_cast<uint64_t>(batch)) {
            break; // 尾部不足一整批即认为到 EOF
        }
    }
    return read;
}

} // namespace timbrava

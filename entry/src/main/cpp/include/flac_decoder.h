#ifndef TIMBRAVA_FLAC_DECODER_H
#define TIMBRAVA_FLAC_DECODER_H

#include "decoder.h"
#include "mmap_file.h"
#include "third_party/dr_flac.h"

#include <unistd.h>
#include <cerrno>

namespace timbrava {

class FlacDecoder : public IDecoder {
public:
    FlacDecoder();
    ~FlacDecoder() override;

    bool openFile(int fd, const TrackInfo &hint);
    void close();

    const TrackInfo &info() const override;
    OutputFormat outFormat() const override;
    int64_t currentFrame() const override;
    bool seekToFrame(int64_t frame) override;
    int64_t readFrames(uint8_t *dst, int64_t maxFrames, size_t dstCap) override;

private:
    drflac *flac_ = nullptr;
    FILE *file_ = nullptr;
    MmapFile mmap_; // 26-3:大文件整映射(drflac_open_memory 直读,seek 免 read 拷贝)
    TrackInfo info_{};
};

} // namespace timbrava

#endif

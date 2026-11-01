#ifndef TIMBRAVA_FLAC_DECODER_H
#define TIMBRAVA_FLAC_DECODER_H

#include "decoder.h"
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
    TrackInfo info_{};
};

} // namespace timbrava

#endif

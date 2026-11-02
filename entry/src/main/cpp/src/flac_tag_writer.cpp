#include "flac_tag_writer.h"

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <string>
#include <unistd.h>
#include <utility>
#include <vector>

#include "flac_decoder.h"

#define LOG_TAG "[TimbravaNative][FlacTag]"
#include <hilog/log.h>

namespace timbrava {

namespace {

constexpr size_t kBlockSizeHeader = 4; // 1B(type|last) + 3B len
constexpr int kBlockStreaminfo = 0;
constexpr int kBlockPadding = 1;
constexpr int kBlockVorbisComment = 4;
constexpr int kCopyChunk = 256 * 1024;

void putU32le(std::vector<uint8_t> &out, uint32_t v)
{
    out.push_back(static_cast<uint8_t>(v & 0xFF));
    out.push_back(static_cast<uint8_t>((v >> 8) & 0xFF));
    out.push_back(static_cast<uint8_t>((v >> 16) & 0xFF));
    out.push_back(static_cast<uint8_t>((v >> 24) & 0xFF));
}

// 构造 VORBIS_COMMENT 块体(不含块头):vendor + [len][KEY=VALUE]...
std::vector<uint8_t> buildVorbisComment(const FlacTags &tags)
{
    std::vector<uint8_t> body;
    const std::string vendor = "Timbrava 0.4.0";
    putU32le(body, static_cast<uint32_t>(vendor.size()));
    body.insert(body.end(), vendor.begin(), vendor.end());

    std::vector<std::string> comments;
    auto add = [&comments](const char *key, const std::string &val) {
        if (val.empty()) {
            return; // 空值 = 移除该键
        }
        comments.push_back(std::string(key) + "=" + val);
    };
    add("TITLE", tags.title);
    add("ARTIST", tags.artist);
    add("ALBUM", tags.album);
    add("ALBUMARTIST", tags.albumArtist);
    add("GENRE", tags.genre);
    add("DATE", tags.year);
    add("TRACKNUMBER", tags.trackNo);
    add("DISCNUMBER", tags.discNo);

    putU32le(body, static_cast<uint32_t>(comments.size()));
    for (const std::string &c : comments) {
        putU32le(body, static_cast<uint32_t>(c.size()));
        body.insert(body.end(), c.begin(), c.end());
    }
    return body;
}

// 读取块头;返回 type,-1 = EOF/错误
int readBlockHeader(FILE *f, uint32_t *len, bool *last)
{
    uint8_t h[4];
    if (fread(h, 1, 4, f) != 4) {
        return -1;
    }
    *last = (h[0] & 0x80) != 0;
    const int type = h[0] & 0x7F;
    *len = (static_cast<uint32_t>(h[1]) << 16) | (static_cast<uint32_t>(h[2]) << 8) |
           static_cast<uint32_t>(h[3]);
    return type;
}

void writeBlockHeader(std::vector<uint8_t> &out, int type, uint32_t len, bool last)
{
    out.push_back(static_cast<uint8_t>((last ? 0x80 : 0) | (type & 0x7F)));
    out.push_back(static_cast<uint8_t>((len >> 16) & 0xFF));
    out.push_back(static_cast<uint8_t>((len >> 8) & 0xFF));
    out.push_back(static_cast<uint8_t>(len & 0xFF));
}

bool copyBytes(FILE *src, FILE *dst, int64_t bytes)
{
    std::vector<uint8_t> buf(static_cast<size_t>(std::min<int64_t>(kCopyChunk, bytes > 0 ? bytes : kCopyChunk)));
    int64_t remaining = bytes;
    while (remaining > 0) {
        const size_t take = static_cast<size_t>(std::min<int64_t>(static_cast<int64_t>(buf.size()), remaining));
        if (fread(buf.data(), 1, take, src) != take) {
            return false;
        }
        if (fwrite(buf.data(), 1, take, dst) != take) {
            return false;
        }
        remaining -= static_cast<int64_t>(take);
    }
    return true;
}

} // namespace

bool writeFlacTags(const std::string &srcPath, const std::string &tmpPath,
                   const FlacTags &tags, std::string *errMsg)
{
    if (errMsg == nullptr) {
        return false;
    }
    FILE *src = fopen(srcPath.c_str(), "rb");
    if (src == nullptr) {
        *errMsg = "open src fail";
        return false;
    }
    uint8_t magic[4];
    if (fread(magic, 1, 4, src) != 4 || std::memcmp(magic, "fLaC", 4) != 0) {
        fclose(src);
        *errMsg = "not a flac file";
        return false;
    }

    // 读取全部元数据块
    std::vector<std::pair<int, std::vector<uint8_t>>> blocks; // (type, body)
    bool haveStreaminfo = false;
    bool havePadding = false;
    int64_t audioStart = 4;
    for (int guard = 0; guard < 1024; guard++) {
        uint32_t len = 0;
        bool last = false;
        const int type = readBlockHeader(src, &len, &last);
        if (type < 0) {
            fclose(src);
            *errMsg = "bad metadata block";
            return false;
        }
        audioStart += kBlockSizeHeader + static_cast<int64_t>(len);
        if (type == kBlockVorbisComment) {
            if (fseek(src, len, SEEK_CUR) != 0) {
                fclose(src);
                *errMsg = "seek vorbis fail";
                return false;
            }
            continue; // 丢弃旧标签,后面重建
        }
        std::vector<uint8_t> body(len);
        if (len > 0 && fread(body.data(), 1, len, src) != len) {
            fclose(src);
            *errMsg = "read block fail";
            return false;
        }
        if (type == kBlockStreaminfo) {
            haveStreaminfo = body.size() == 34;
        }
        if (type == kBlockPadding) {
            havePadding = true;
        }
        blocks.emplace_back(type, std::move(body));
        if (last) {
            break;
        }
    }
    if (!haveStreaminfo) {
        fclose(src);
        *errMsg = "streaminfo missing";
        return false;
    }

    // 重组块:STREAMINFO 在首,VORBIS_COMMENT 次之,其余保持原序;无 PADDING 则补 4KB
    std::vector<uint8_t> meta;
    std::vector<uint8_t> vc = buildVorbisComment(tags);
    std::vector<std::pair<int, std::vector<uint8_t>>> ordered;
    for (const auto &b : blocks) {
        if (b.first == kBlockStreaminfo) {
            ordered.push_back(b);
        }
    }
    ordered.emplace_back(kBlockVorbisComment, std::move(vc));
    for (const auto &b : blocks) {
        if (b.first != kBlockStreaminfo) {
            ordered.push_back(b);
        }
    }
    if (!havePadding) {
        std::vector<uint8_t> pad(4096, 0);
        ordered.emplace_back(kBlockPadding, std::move(pad));
    }
    for (size_t i = 0; i < ordered.size(); ++i) {
        const bool last = i + 1 == ordered.size();
        writeBlockHeader(meta, ordered[i].first, static_cast<uint32_t>(ordered[i].second.size()), last);
        meta.insert(meta.end(), ordered[i].second.begin(), ordered[i].second.end());
    }

    FILE *dst = fopen(tmpPath.c_str(), "wb");
    if (dst == nullptr) {
        fclose(src);
        *errMsg = "open tmp fail";
        return false;
    }
    bool ok = fwrite("fLaC", 1, 4, dst) == 4 && fwrite(meta.data(), 1, meta.size(), dst) == meta.size();
    if (ok) {
        if (fseek(src, audioStart, SEEK_SET) != 0) {
            ok = false;
            *errMsg = "seek audio fail";
        } else if (fseek(src, 0, SEEK_END) == 0) {
            const int64_t fileSize = ftell(src);
            if (fileSize < audioStart) {
                ok = false;
                *errMsg = "audio region invalid";
            } else if (fseek(src, audioStart, SEEK_SET) == 0) {
                ok = copyBytes(src, dst, fileSize - audioStart);
                if (!ok) {
                    *errMsg = "copy audio fail";
                }
            } else {
                ok = false;
                *errMsg = "seek audio fail(2)";
            }
        } else {
            ok = false;
            *errMsg = "seek end fail";
        }
    }
    fclose(dst);
    fclose(src);
    if (!ok) {
        remove(tmpPath.c_str());
        return false;
    }

    // 校验:重开 tmp 必须是合法 FLAC,帧数与原文件一致
    int64_t origFrames = -1;
    {
        const int srcFd = open(srcPath.c_str(), O_RDONLY);
        if (srcFd >= 0) {
            FlacDecoder origProbe;
            if (origProbe.openFile(srcFd, TrackInfo{})) {
                origFrames = origProbe.info().totalFrames;
            }
            ::close(srcFd);
        }
    }
    {
        FlacDecoder probe;
        const int checkFd = open(tmpPath.c_str(), O_RDONLY);
        if (checkFd < 0) {
            remove(tmpPath.c_str());
            *errMsg = "reopen tmp fail";
            return false;
        }
        if (!probe.openFile(checkFd, TrackInfo{})) {
            ::close(checkFd);
            remove(tmpPath.c_str());
            *errMsg = "tmp validate fail";
            return false;
        }
        if (origFrames > 0 && probe.info().totalFrames > 0 && probe.info().totalFrames != origFrames) {
            ::close(checkFd);
            remove(tmpPath.c_str());
            *errMsg = "frame count mismatch";
            return false;
        }
        ::close(checkFd);
    }

    if (rename(tmpPath.c_str(), srcPath.c_str()) != 0) {
        remove(tmpPath.c_str());
        *errMsg = "rename fail";
        return false;
    }
    OH_LOG_Print(LOG_APP, LOG_INFO, 0, LOG_TAG, "tags written %{public}s", srcPath.c_str());
    return true;
}

} // namespace timbrava

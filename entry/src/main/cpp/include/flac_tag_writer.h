// FLAC 标签写回(#40):重写 VORBIS_COMMENT 块,其余元数据块与音频原样保留。
// 流程(开发文档:临时文件 → 校验 → 原子替换):写 tmp → dr_flac 重开校验 → rename 覆盖。
// 仅支持未加密原生 FLAC;音频区字节不动(比特完美)。
#ifndef TIMBRAVA_FLAC_TAG_WRITER_H
#define TIMBRAVA_FLAC_TAG_WRITER_H

#include <string>

namespace timbrava {

struct FlacTags {
    std::string title;
    std::string artist;
    std::string album;
    std::string albumArtist;
    std::string genre;
    std::string year;    // 空串 = 不写(清除该键)
    std::string trackNo;
    std::string discNo;
};

// srcPath 原文件;tmpPath 临时输出(同目录同文件系统,保证 rename 原子性)。
// 成功返回 true(此时 tmp 已 rename 覆盖 src)。
bool writeFlacTags(const std::string &srcPath, const std::string &tmpPath,
                   const FlacTags &tags, std::string *errMsg);

} // namespace timbrava

#endif

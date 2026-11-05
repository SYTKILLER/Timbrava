// 只读整文件 mmap(26-3):大文件(1GB+ 真无损)读流免 read 拷贝、seek 免 syscall。
// 低于阈值/映射失败时 open 返回 false,调用方回退原有 FILE* 流路径(小文件 stdio 缓冲足够)。
#ifndef TIMBRAVA_MMAP_FILE_H
#define TIMBRAVA_MMAP_FILE_H

#include <cstddef>
#include <cstdint>

namespace timbrava {

class MmapFile {
public:
    MmapFile() = default;
    ~MmapFile();
    MmapFile(const MmapFile &) = delete;
    MmapFile &operator=(const MmapFile &) = delete;

    // fd 仅用于取尺寸与映射,不接管所有权(映射在 fd 关闭后依然有效)。
    bool open(int fd);
    void close();
    bool valid() const { return data_ != nullptr; }
    const uint8_t *data() const { return data_; }
    size_t size() const { return size_; }

    // 大于该尺寸才值得映射(小文件 stdio 缓冲更省地址空间)
    static constexpr size_t kMinMmapSize = 16 * 1024 * 1024;

private:
    uint8_t *data_ = nullptr;
    size_t size_ = 0;
};

} // namespace timbrava

#endif

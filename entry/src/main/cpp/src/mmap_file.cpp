#include "mmap_file.h"

#include <sys/mman.h>
#include <unistd.h>
#include <cerrno>

#define LOG_TAG "[TimbravaNative][Mmap]"
#include <hilog/log.h>

namespace timbrava {

MmapFile::~MmapFile()
{
    close();
}

bool MmapFile::open(int fd)
{
    close();
    if (fd < 0) {
        return false;
    }
    const off_t end = ::lseek(fd, 0, SEEK_END);
    if (end <= 0 || static_cast<size_t>(end) < kMinMmapSize) {
        return false;
    }
    void *p = ::mmap(nullptr, static_cast<size_t>(end), PROT_READ, MAP_PRIVATE, fd, 0);
    if (p == MAP_FAILED) {
        OH_LOG_Print(LOG_APP, LOG_INFO, 0, LOG_TAG, "mmap fail errno=%{public}d size=%{public}lld",
                     errno, static_cast<long long>(end));
        return false;
    }
    // 预触首尾页,把页错误从解码热路径挪到打开时刻
    ::madvise(p, static_cast<size_t>(end), MADV_WILLNEED);
    data_ = static_cast<uint8_t *>(p);
    size_ = static_cast<size_t>(end);
    OH_LOG_Print(LOG_APP, LOG_INFO, 0, LOG_TAG, "mmap ok size=%{public}lld",
                 static_cast<long long>(size_));
    return true;
}

void MmapFile::close()
{
    if (data_ != nullptr) {
        ::munmap(data_, size_);
        data_ = nullptr;
        size_ = 0;
    }
}

} // namespace timbrava

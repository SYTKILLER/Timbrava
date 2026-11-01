// SPSC 环形字节缓冲:解码线程单写,渲染回调单读。
// 写侧阻塞(背压),读侧非阻塞(实时回调)。flush 由 seek 在互斥锁下执行。
#ifndef TIMBRAVA_RING_BUFFER_H
#define TIMBRAVA_RING_BUFFER_H

#include <algorithm>
#include <condition_variable>
#include <cstdint>
#include <cstring>
#include <mutex>
#include <vector>

namespace timbrava {

class RingBuffer {
public:
    explicit RingBuffer(size_t capacity) : buf_(capacity) {}

    // 阻塞写:直到 len 全部写入或 abortRequested()。返回实际写入字节数。
    size_t write(const uint8_t *data, size_t len) {
        std::unique_lock<std::mutex> lk(m_);
        size_t written = 0;
        while (written < len) {
            spaceCv_.wait(lk, [this, &written, &len] {
                return aborted_ || freeSpace() >= chunkAvail(written, len) || !writable_;
            });
            if (aborted_ || !writable_) {
                break;
            }
            size_t n = std::min({len - written, freeSpace(), contiguousTail()});
            if (n == 0) {
                // 环绕满读侧未追平:极小概率,短暂让出再试
                dataCv_.wait_for(lk, std::chrono::milliseconds(5));
                continue;
            }
            size_t tail = buf_.size() - (writePos_ % buf_.size());
            size_t first = std::min(n, tail);
            std::memcpy(buf_.data() + (writePos_ % buf_.size()), data + written, first);
            if (n > first) {
                std::memcpy(buf_.data(), data + written + first, n - first);
            }
            writePos_ += n;
            written += n;
            dataCv_.notify_all();
        }
        return written;
    }

    // 非阻塞读(渲染回调线程),返回实际读取字节数。
    size_t read(uint8_t *out, size_t len) {
        std::lock_guard<std::mutex> lk(m_);
            size_t n = std::min(len, writePos_ - readPos_);
        if (n == 0) {
            return 0;
        }
        size_t head = readPos_ % buf_.size();
        size_t tail = buf_.size() - head;
        size_t first = std::min(n, tail);
        std::memcpy(out, buf_.data() + head, first);
        if (n > first) {
            std::memcpy(out + first, buf_.data(), n - first);
        }
        readPos_ += n;
        spaceCv_.notify_all();
        return n;
    }

    // seek 时清空缓冲(内部加锁,渲染回调的读与它互斥)。
    void flushAll() {
        std::lock_guard<std::mutex> lk(m_);
        readPos_ = writePos_ = 0;
        spaceCv_.notify_all();
        dataCv_.notify_all();
    }

    size_t capacity() const { return buf_.size(); }

    void abort() {
        std::lock_guard<std::mutex> lk(m_);
        aborted_ = true;
        spaceCv_.notify_all();
        dataCv_.notify_all();
    }

    void reset() {
        std::lock_guard<std::mutex> lk(m_);
        aborted_ = false;
        writable_ = true;
        readPos_ = writePos_ = 0;
        spaceCv_.notify_all();
        dataCv_.notify_all();
    }

    // 解码线程在 pause / 停止时挂起写入
    void setWritable(bool w) {
        std::lock_guard<std::mutex> lk(m_);
        writable_ = w;
        spaceCv_.notify_all();
    }

    // 缓冲字节数(锁内精确)
    size_t sizeLocked() {
        std::lock_guard<std::mutex> lk(m_);
        return writePos_ - readPos_;
    }

    void waitDrainedOrSpace(int timeoutMs) {
        std::unique_lock<std::mutex> lk(m_);
        spaceCv_.wait_for(lk, std::chrono::milliseconds(timeoutMs));
    }

private:
    size_t freeSpace() const { return buf_.size() - (writePos_ - readPos_); }
    size_t contiguousTail() const {
        size_t mod = writePos_ % buf_.size();
        size_t head = readPos_ % buf_.size();
        if (writePos_ == readPos_) {
            return buf_.size() - head; // 空:可整段写
        }
        return mod >= head ? buf_.size() - mod : head - mod;
    }
    size_t chunkAvail(size_t written, size_t len) const { return std::min<size_t>(64 * 1024, len - written); }

    std::vector<uint8_t> buf_;
    mutable std::mutex m_;
    std::condition_variable spaceCv_;
    std::condition_variable dataCv_;
    uint64_t readPos_ = 0;
    uint64_t writePos_ = 0;
    bool aborted_ = false;
    bool writable_ = true;
};

} // namespace timbrava

#endif

// 频谱可视化实现:4096 点 FFT + 48 对数频段 + 4 槽无锁发布。
// 音频线程路径(feed→FFT→publish)零锁零分配;所有工作缓冲在 vizPrepare 预建。
#include "viz.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstring>
#include <vector>

namespace timbrava {

namespace {

// 窗长 4096(低频分辨率 10.8Hz@44.1k/12.2Hz@48k)+ 跳步 1024(约 21ms@48k,
// 每 2~4 个渲染回调产出一次新快照,30fps 轮询无空帧)。
constexpr int kFftSize = 4096;
constexpr int kHopSize = 1024;
constexpr int kHalfSize = kFftSize / 2;
// 频段范围与归一化:30Hz~20kHz;dB 地板 -84(全幅正弦单峰约 +66dBFS,
// 宽带能量按频段聚合后典型 -55~-30,取 -84 地板让常用音乐形态占满中高段)。
constexpr float kBandLoHz = 30.0f;
constexpr float kBandHiHz = 20000.0f;
constexpr float kNormFloorDb = -84.0f;
constexpr float kNormRangeDb = 84.0f;
constexpr double kPi = 3.14159265358979323846; // 与 dsp.cpp 同款,不依赖 M_PI 宏

std::atomic<bool> g_enabled{false};

// ---- 表与工作缓冲(vizPrepare 建,音频线程独占读写;poll 线程不触碰) ----
int g_sr = 48000;
float g_hann[kFftSize] = {0.0f};      // Hann 窗
int g_rev[kFftSize] = {0};            // 位反转表
float g_twRe[kHalfSize] = {0.0f};     // 旋转因子 cos
float g_twIm[kHalfSize] = {0.0f};     // 旋转因子 -sin
int g_bandBin[kVizBandCount + 1] = {0}; // 频段边界 bin(升序,首尾钳位)
float g_win[kFftSize] = {0.0f};       // 单声道滑动窗(环形)
int g_winPos = 0;                     // 下一写入下标
int g_pending = 0;                    // 自上次 FFT 累计的新样本数
float g_fftRe[kFftSize] = {0.0f};     // FFT 就地工作区
float g_fftIm[kFftSize] = {0.0f};

// ---- 4 槽发布(写者=音频线程,读者=JS) ----
VizSnapshot g_slots[4];
std::atomic<int> g_pub{0}; // 最近发布完成的槽
int g_frameId = 0;

void buildTables() {
    // Hann:0.5*(1-cos(2πn/(N-1)))
    for (int i = 0; i < kFftSize; i++) {
        g_hann[i] = 0.5f * (1.0f - std::cos(2.0f * static_cast<float>(kPi) *
                                            static_cast<float>(i) / static_cast<float>(kFftSize - 1)));
    }
    // 位反转
    int bits = 0;
    for (int t = kFftSize; t > 1; t >>= 1) {
        bits++;
    }
    for (int i = 0; i < kFftSize; i++) {
        int r = 0;
        for (int b = 0; b < bits; b++) {
            if (i & (1 << b)) {
                r |= 1 << (bits - 1 - b);
            }
        }
        g_rev[i] = r;
    }
    // 旋转因子 e^{-2πik/N}:re=cos,im=-sin
    for (int k = 0; k < kHalfSize; k++) {
        const double a = -2.0 * kPi * static_cast<double>(k) / static_cast<double>(kFftSize);
        g_twRe[k] = static_cast<float>(std::cos(a));
        g_twIm[k] = static_cast<float>(std::sin(a));
    }
    // 频段边界:30Hz~20kHz 对数均分,边界映射 bin 并保证严格递增
    const float nyqHz = g_sr * 0.5f;
    int prev = 1;
    g_bandBin[0] = 1;
    for (int b = 1; b <= kVizBandCount; b++) {
        const float f = kBandLoHz * std::pow(kBandHiHz / kBandLoHz,
                                             static_cast<float>(b) / static_cast<float>(kVizBandCount));
        int bin = static_cast<int>(f * kFftSize / (g_sr > 0 ? g_sr : 48000) + 0.5f);
        bin = std::max(prev + 1, bin);
        bin = std::min(bin, kHalfSize - 1);
        g_bandBin[b] = bin;
        prev = bin;
    }
}

// 就地迭代 radix-2 FFT(输入已按 g_rev 重排)
void runFft() {
    for (int len = 2; len <= kFftSize; len <<= 1) {
        const int half = len >> 1;
        const int step = kFftSize / len;
        for (int i = 0; i < kFftSize; i += len) {
            for (int j = 0; j < half; j++) {
                const int w = j * step;
                const float ur = g_fftRe[i + j];
                const float ui = g_fftIm[i + j];
                const float xr = g_fftRe[i + j + half];
                const float xi = g_fftIm[i + j + half];
                const float vr = xr * g_twRe[w] - xi * g_twIm[w];
                const float vi = xr * g_twIm[w] + xi * g_twRe[w];
                g_fftRe[i + j] = ur + vr;
                g_fftIm[i + j] = ui + vi;
                g_fftRe[i + j + half] = ur - vr;
                g_fftIm[i + j + half] = ui - vi;
            }
        }
    }
}

// 降混一帧并写入环形窗;返回该帧峰值
inline float appendMono(const float *frame, int ch) {
    float m = 0.0f;
    for (int c = 0; c < ch; c++) {
        m += frame[c];
    }
    m /= static_cast<float>(ch > 0 ? ch : 1);
    g_win[g_winPos] = m;
    g_winPos = (g_winPos + 1) % kFftSize;
    return m < 0.0f ? -m : m;
}

// 一次 FFT:取最近 kFftSize 个样本加窗变换 → 频段能量 → 发布
void processHop() {
    // 环形窗 → 线性 + 加窗(降混时已顺带跟踪峰值,RMS 由 FFT 均值另计)
    double sumSq = 0.0;
    for (int i = 0; i < kFftSize; i++) {
        const float s = g_win[(g_winPos + i) % kFftSize];
        sumSq += static_cast<double>(s) * static_cast<double>(s);
        g_fftRe[i] = s * g_hann[i];
        g_fftIm[i] = 0.0f;
    }
    // 位反转重排
    for (int i = 0; i < kFftSize; i++) {
        const int r = g_rev[i];
        if (r > i) {
            std::swap(g_fftRe[i], g_fftRe[r]);
            std::swap(g_fftIm[i], g_fftIm[r]);
        }
    }
    runFft();

    // 频段聚合 + RMS
    const int snapIdx = (g_pub.load(std::memory_order_relaxed) + 1) % 4;
    VizSnapshot &snap = g_slots[snapIdx];
    for (int b = 0; b < kVizBandCount; b++) {
        double energy = 0.0;
        for (int k = g_bandBin[b]; k < g_bandBin[b + 1]; k++) {
            energy += static_cast<double>(g_fftRe[k]) * g_fftRe[k] +
                      static_cast<double>(g_fftIm[k]) * g_fftIm[k];
        }
        const float db = 10.0f * static_cast<float>(std::log10(energy + 1e-12));
        float norm = (db - kNormFloorDb) / kNormRangeDb;
        norm = std::max(0.0f, std::min(1.0f, norm));
        snap.bands[b] = norm;
    }
    const float rms = std::sqrt(static_cast<float>(sumSq / kFftSize));
    snap.rmsDb = 10.0f * std::log10(rms + 1e-9f);
    snap.frameId = ++g_frameId;
    g_pub.store(snapIdx, std::memory_order_release);
}

} // namespace

void vizSetEnabled(bool on) {
    if (g_enabled.exchange(on) && !on) {
        // 关闭时清窗,避免再次开启时衔接旧数据尾巴
        g_winPos = 0;
        g_pending = 0;
        std::memset(g_win, 0, sizeof(g_win));
    }
}

bool vizEnabled() {
    return g_enabled.load(std::memory_order_relaxed);
}

void vizPrepare(int sampleRate, int channels) {
    (void)channels;
    g_sr = sampleRate > 0 ? sampleRate : 48000;
    buildTables();
    g_winPos = 0;
    g_pending = 0;
    std::memset(g_win, 0, sizeof(g_win));
}

void vizFeedF32(const float *data, size_t frameCount, int channels) {
    if (!g_enabled.load(std::memory_order_relaxed) || data == nullptr || frameCount == 0 || channels <= 0) {
        return;
    }
    const int ch = channels > 8 ? 8 : channels;
    for (size_t f = 0; f < frameCount; f++) {
        appendMono(data + f * static_cast<size_t>(ch), ch);
        if (++g_pending >= kHopSize) {
            g_pending = 0;
            processHop();
        }
    }
}

void vizFeedInt(const uint8_t *data, size_t frameCount, int channels, OutputFormat fmt) {
    if (!g_enabled.load(std::memory_order_relaxed) || data == nullptr || frameCount == 0 || channels <= 0) {
        return;
    }
    const int ch = channels > 8 ? 8 : channels;
    float frame[8];
    for (size_t f = 0; f < frameCount; f++) {
        const uint8_t *p = data + f * static_cast<size_t>(ch) *
                                     (fmt == OutputFormat::U8 ? 1u : fmt == OutputFormat::S16LE ? 2u : 4u);
        switch (fmt) {
            case OutputFormat::U8:
                for (int c = 0; c < ch; c++) {
                    frame[c] = (static_cast<float>(p[c]) - 128.0f) / 128.0f;
                }
                break;
            case OutputFormat::S16LE:
                for (int c = 0; c < ch; c++) {
                    const int16_t v = static_cast<int16_t>(p[2 * c] | (static_cast<uint16_t>(p[2 * c + 1]) << 8));
                    frame[c] = static_cast<float>(v) / 32768.0f;
                }
                break;
            default: // S32LE
                for (int c = 0; c < ch; c++) {
                    const int32_t v = static_cast<int32_t>(p[4 * c] | (static_cast<uint32_t>(p[4 * c + 1]) << 8) |
                                                           (static_cast<uint32_t>(p[4 * c + 2]) << 16) |
                                                           (static_cast<uint32_t>(p[4 * c + 3]) << 24));
                    frame[c] = static_cast<float>(static_cast<double>(v) / 2147483648.0);
                }
                break;
        }
        appendMono(frame, ch);
        if (++g_pending >= kHopSize) {
            g_pending = 0;
            processHop();
        }
    }
}

bool vizPoll(VizSnapshot *out) {
    if (out == nullptr) {
        return false;
    }
    const int idx = g_pub.load(std::memory_order_acquire);
    *out = g_slots[idx];
    return out->frameId > 0;
}

} // namespace timbrava

// Timbrava DSP 总链实现(ReplayGain → PEQ → 软限幅)。
//
// [参数发布:三槽轮换 —— “双缓冲 + 无锁切换”的加固版]
// Flick 的做法是双缓冲:UI 线程写影子系数组,atomic 序号交换,音频回调只读。
// 纯双缓冲存在一个已知竞态:若 UI 线程在音频回调尚在读取旧系数组时连续发布
// 两次,第二次会覆写音频线程正在读取的缓冲,音频线程可能读到半新半旧的系数
// (极端情况下滤波器瞬间不稳定)。本实现保留其全部核心思想(固定容量、
// atomic 序号交换、process() 零分配),把槽数升为 3,采用经典三槽轮换:
//   - writer 槽:控制线程独占持有,可随意覆写;
//   - reader 槽:音频线程独占持有,可随意读取;
//   - latest 槽:最近一次发布完成的参数组。
// 任一侧“发布/取用”都通过一次 atomic exchange 把自己持有的槽与 latest 互换。
// 不变式:任一时刻每槽至多被一方持有 ⇒ 音频线程取到的参数组在它下一次取用
// 之前绝不会被控制线程改写,全程无互斥锁。音频线程每次 process 仅做一次
// 原子下标交换(单条 CPU 指令,O(1),非系统调用),对系数数据本身只读。
//
// [处理链] data → RG 线性增益(10^(dB/20))→ PEQ 31×biquad 串联 → 软限幅(≤1.0)
// 全部为逐样本浮点运算;恒等路径逐位直通;状态与系数全部静态存储,零分配。

#include "dsp.h"
#include "decoder.h"

#include <array>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <mutex>

namespace timbrava {

namespace {

// ---------------- 常量 ----------------

constexpr double kPi = 3.14159265358979323846; // RBJ 公式用
// 31 段图示 EQ 常用带宽(约 1/6 倍频程)对应的 Q;仅作 flat 重置时的默认值,
// 0 dB 时 peak 为精确恒等,Q 不影响直通特性。
constexpr float kDefaultPeqQ = 4.318f;
// 低于约 -300 dBFS 视为静音,冲洗 denormal(见 biquadTick)。
constexpr float kDenormalFloor = 1e-30f;

// 默认 31 个中心频率:f(i) = 20·800^(i/30),即 20Hz~16kHz 几何均分。
const float *defaultPeqFreqs() {
    static const std::array<float, kPeqBandCount> kFreqs = [] {
        std::array<float, kPeqBandCount> a{};
        for (int i = 0; i < kPeqBandCount; ++i) {
            a[i] = 20.0f * std::pow(800.0f, static_cast<float>(i) /
                                               static_cast<float>(kPeqBandCount - 1));
        }
        return a;
    }();
    return kFreqs.data();
}

// ---------------- 控制线程主配置 ----------------

// 单个 PEQ 频段的“声明”(UI 视角)。系数按当前采样率即时计算,故只存声明,
// 采样率变化后无需 UI 重新下发即可得到正确系数。
struct BandSpec {
    int type = kPeqPeak;
    float freq = 1000.0f;
    float gainDb = 0.0f;
    float q = kDefaultPeqQ;
};

// 控制线程持有的总配置(仅控制线程读写,由 g_configMutex 保护)。
struct DspConfig {
    DspConfig() {
        const float *f = defaultPeqFreqs();
        for (int b = 0; b < kPeqBandCount; ++b) {
            bands[b] = BandSpec{kPeqPeak, f[b], 0.0f, kDefaultPeqQ}; // 默认全 flat
        }
    }

    int sampleRate = 48000;
    int channels = 0; // 0 = 尚未 prepare,process 直接返回
    bool peqEnabled = false;

    BandSpec bands[kPeqBandCount];

    // ReplayGain:存声明值,发布时按 mode 折算线性增益
    float rgTrackGainDb = 0.0f;
    float rgTrackPeak = 0.0f;
    float rgAlbumGainDb = 0.0f;
    float rgAlbumPeak = 0.0f;
    int rgMode = kReplayGainOff;

    // 状态代次:prepare / PEQ 开关切换时递增,音频线程据此自行清零滤波状态
    // (避免控制线程直接清零与音频线程产生数据竞争)。
    uint32_t stateEpoch = 1;
};

// ---------------- 音频线程参数组(不可变快照) ----------------

constexpr int kCoeffsPerBand = 5; // b0, b1, b2, a1, a2(a0 已归一化)

// 一次发布 = 全链参数的不可变快照。音频线程持有该槽期间内容绝不变更。
struct DspParams {
    DspParams() { // 初始即恒等:全段直通、增益 1,未配置时逐位透明
        for (int b = 0; b < kPeqBandCount; ++b) {
            identity[b] = true;
            coeffs[b][0] = 1.0f;
            coeffs[b][1] = coeffs[b][2] = coeffs[b][3] = coeffs[b][4] = 0.0f;
        }
    }

    int sampleRate = 48000;
    int channels = 0;
    bool peqEnabled = false;
    bool allIdentity = true; // 31 段全部恒等 → PEQ 整链直通
    uint32_t stateEpoch = 1;
    float rgGain = 1.0f; // 线性增益(= 10^(dB/20);mode==off 时为 1)

    bool identity[kPeqBandCount] = {};        // 该段是否恒等(可跳过)
    float coeffs[kPeqBandCount][kCoeffsPerBand] = {};
};

// ---------------- RBJ Audio EQ Cookbook 双二阶系数 ----------------

// 公式逐条抄录自:Robert Bristow-Johnson, "Cookbook formulae for audio EQ
// biquad filter coefficients"(Peaking EQ / LowShelf / HighShelf / LPF /
// HPF 各小节),输出按 a0 归一化。内部用 double 计算以压低低频 / 高 Q 段的
// 系数量化误差,再存为 float 供音频线程使用。
// out = {b0, b1, b2, a1, a2};参数越界一律钳位,保证系数有限、滤波器稳定。
void rbjBiquad(const BandSpec &s, int sampleRate, float out[kCoeffsPerBand]) {
    const double fs = (sampleRate >= 8000) ? static_cast<double>(sampleRate) : 48000.0;

    double f0 = static_cast<double>(s.freq);
    if (!(f0 > 0.0)) f0 = 1000.0;          // NaN / 非正防护
    const double nyq = 0.5 * fs;
    if (f0 < 10.0) f0 = 10.0;              // 频率下限
    if (f0 > nyq * 0.98) f0 = nyq * 0.98;  // 上限留 2% 余量,防近奈奎斯特失稳

    double q = static_cast<double>(s.q);
    if (!(q > 0.0)) q = 1.0;               // NaN / 非正防护
    if (q < 0.1) q = 0.1;
    if (q > 24.0) q = 24.0;

    double gainDb = static_cast<double>(s.gainDb);
    if (!(gainDb > -1.0e9 && gainDb < 1.0e9)) gainDb = 0.0; // NaN / Inf 防护
    if (gainDb < -30.0) gainDb = -30.0;    // 防御性钳位(正常 EQ 在 ±18 dB 内)
    if (gainDb > 30.0) gainDb = 30.0;

    // RBJ 公共项:w0 = 2π·f0/Fs;alpha = sin(w0)/(2Q);A = 10^(dBgain/40)
    const double w0 = 2.0 * kPi * f0 / fs;
    const double cosw0 = std::cos(w0);
    const double sinw0 = std::sin(w0);
    const double alpha = sinw0 / (2.0 * q);
    const double A = std::pow(10.0, gainDb / 40.0);

    double b0 = 1.0, b1 = 0.0, b2 = 0.0, a0 = 1.0, a1 = 0.0, a2 = 0.0;
    switch (s.type) {
    case kPeqPeak: // RBJ: Peaking EQ
        b0 = 1.0 + alpha * A;
        b1 = -2.0 * cosw0;
        b2 = 1.0 - alpha * A;
        a0 = 1.0 + alpha / A;
        a1 = -2.0 * cosw0;
        a2 = 1.0 - alpha / A;
        break;
    case kPeqLowShelf: { // RBJ: LowShelf
        const double sq = std::sqrt(A);
        b0 = A * ((A + 1.0) - (A - 1.0) * cosw0 + 2.0 * sq * alpha);
        b1 = 2.0 * A * ((A - 1.0) - (A + 1.0) * cosw0);
        b2 = A * ((A + 1.0) - (A - 1.0) * cosw0 - 2.0 * sq * alpha);
        a0 = (A + 1.0) + (A - 1.0) * cosw0 + 2.0 * sq * alpha;
        a1 = -2.0 * ((A - 1.0) + (A + 1.0) * cosw0);
        a2 = (A + 1.0) + (A - 1.0) * cosw0 - 2.0 * sq * alpha;
        break;
    }
    case kPeqHighShelf: { // RBJ: HighShelf
        const double sq = std::sqrt(A);
        b0 = A * ((A + 1.0) + (A - 1.0) * cosw0 + 2.0 * sq * alpha);
        b1 = -2.0 * A * ((A - 1.0) + (A + 1.0) * cosw0);
        b2 = A * ((A + 1.0) + (A - 1.0) * cosw0 - 2.0 * sq * alpha);
        a0 = (A + 1.0) - (A - 1.0) * cosw0 + 2.0 * sq * alpha;
        a1 = 2.0 * ((A - 1.0) - (A + 1.0) * cosw0);
        a2 = (A + 1.0) - (A - 1.0) * cosw0 - 2.0 * sq * alpha;
        break;
    }
    case kPeqLowPass: // RBJ: LPF(12 dB/oct)
        b0 = (1.0 - cosw0) / 2.0;
        b1 = 1.0 - cosw0;
        b2 = (1.0 - cosw0) / 2.0;
        a0 = 1.0 + alpha;
        a1 = -2.0 * cosw0;
        a2 = 1.0 - alpha;
        break;
    case kPeqHighPass: // RBJ: HPF(12 dB/oct)
        b0 = (1.0 + cosw0) / 2.0;
        b1 = -(1.0 + cosw0);
        b2 = (1.0 + cosw0) / 2.0;
        a0 = 1.0 + alpha;
        a1 = -2.0 * cosw0;
        a2 = 1.0 - alpha;
        break;
    default: // 未知类型:恒等直通(防御)
        out[0] = 1.0f;
        out[1] = out[2] = out[3] = out[4] = 0.0f;
        return;
    }

    out[0] = static_cast<float>(b0 / a0);
    out[1] = static_cast<float>(b1 / a0);
    out[2] = static_cast<float>(b2 / a0);
    out[3] = static_cast<float>(a1 / a0);
    out[4] = static_cast<float>(a2 / a0);
}

// 频段是否恒等(H(z) ≡ 1):b0==1 且分子分母逐项相同。peak/shelf 在 0 dB
// (A==1)时 RBJ 公式分子分母逐项相同,自然满足;LP/HP 永不恒等。
// 据此跳过该段的 biquad 运算,实现逐位直通(bypass 恒等保证)。
inline bool bandIsIdentity(const float c[kCoeffsPerBand]) {
    return c[0] == 1.0f && c[1] == c[3] && c[2] == c[4];
}

// ---------------- ReplayGain ----------------

// 线性增益 = 10^(dB/20);钳位 ±60 dB(正常 ReplayGain 在 ±20 dB 内,纯防御)。
inline float rgLinearGain(float db) {
    if (!(db > -1.0e9f && db < 1.0e9f)) return 1.0f; // NaN / Inf 防护
    if (db < -60.0f) db = -60.0f;
    if (db > 60.0f) db = 60.0f;
    return std::pow(10.0f, db / 20.0f);
}

// ---------------- 软限幅(链尾) ----------------

// 归一化 tanh 软拐点(任务在 tanh / 1.5 次幂之间二选一,选 tanh):
//   |x| ≤ 0.95:线性直通;
//   |x| > 0.95:y = 0.95 + 0.05·tanh((|x|-0.95)/0.05)(按符号展开),渐近上界 1.0。
// 选择理由:
//   1) 线性区逐位直通,未过冲样本零失真 —— HiFi 优先;
//   2) 拐点处 C1 连续(左右斜率均为 1),无斜率突变,压限启动瞬间不引入
//      额外谐波;
//   3) 输出上界严格 1.0 且渐近逼近,永不二次过冲;同为 C1、同拐点宽度时,
//      1.5 次幂曲线对满幅样本削减更大(≈ -0.27 dB @1.0,本方案 ≈ -0.10 dB),
//      对合法满幅素材的透明度略差;
//   4) tanh 仅对 |x| > 0.95 的过冲样本计算,常规信号零额外开销。
// 拐点取 0.95 而非 1.0:C1 连续要求压缩在硬上限前留出过渡带;0.95~1.0 区间
// 的合法满幅样本至多被压低约 0.10 dB,听感不可闻。
inline float softLimit(float x) {
    constexpr float kKnee = 0.95f;
    const float a = x < 0.0f ? -x : x;
    if (a <= kKnee) return x;
    const float y = kKnee + (1.0f - kKnee) * std::tanh((a - kKnee) / (1.0f - kKnee));
    return x < 0.0f ? -y : y;
}

// ---------------- 每声道滤波状态与双二阶运算 ----------------

// 双二阶状态:x1/x2 为输入历史,y1/y2 为输出历史(DF-I 直接型)。
struct BiquadState {
    float x1 = 0.0f, x2 = 0.0f, y1 = 0.0f, y2 = 0.0f;
};

// DF-I 双二阶差分方程(RBJ Cookbook 推荐实现形式):
//   y[n] = b0·x[n] + b1·x[n-1] + b2·x[n-2] - a1·y[n-1] - a2·y[n-2]
inline float biquadTick(float x, const float *c, BiquadState &st) {
    const float y = c[0] * x + c[1] * st.x1 + c[2] * st.x2 - c[3] * st.y1 - c[4] * st.y2;
    st.x2 = st.x1;
    st.x1 = x;
    st.y2 = st.y1;
    // denormal 冲洗:输出低于约 -300 dBFS 时把状态清零,防止浮点亚正常数
    // 触发微码慢路径导致音频回调超时(渐弱 / 淡出素材的现实风险)。
    if (y > kDenormalFloor || y < -kDenormalFloor) {
        st.y1 = y;
        return y;
    }
    st.y1 = 0.0f;
    return 0.0f;
}

// 单声道 PEQ 串联:恒等段跳过(逐位直通),其余段依序级联。
// 每声道独立状态(sts 指向该声道自己的 31 段状态),互不串扰。
inline float peqChain(float x, BiquadState *sts, const DspParams &p) {
    for (int b = 0; b < kPeqBandCount; ++b) {
        if (p.identity[b]) continue;
        x = biquadTick(x, p.coeffs[b], sts[b]);
    }
    return x;
}

// ---------------- 全局状态 ----------------

DspConfig g_config;       // 控制线程主配置
std::mutex g_configMutex; // 仅控制线程竞争(序列化多个 setter),音频线程绝不触碰

DspParams g_slots[3];             // 参数三槽(见文件头“三槽轮换”说明)
std::atomic<int> g_latestSlot{0}; // latest 槽下标(两侧 exchange)
unsigned g_writerSlot = 1;        // 控制线程独占
unsigned g_readerSlot = 2;        // 音频线程独占

BiquadState g_state[kDspMaxChannels][kPeqBandCount]; // 每声道状态,音频线程独占
uint32_t g_lastEpoch = 0;                            // 音频线程已应用的状态代次

// 由控制线程配置构建不可变参数快照(仅控制线程调用,系数计算集中在此)。
DspParams buildParams(const DspConfig &cfg) {
    DspParams p;
    p.sampleRate = cfg.sampleRate;
    p.channels = cfg.channels;
    p.peqEnabled = cfg.peqEnabled;
    p.stateEpoch = cfg.stateEpoch;
    p.rgGain = (cfg.rgMode == kReplayGainTrack) ? rgLinearGain(cfg.rgTrackGainDb)
               : (cfg.rgMode == kReplayGainAlbum) ? rgLinearGain(cfg.rgAlbumGainDb)
                                                  : 1.0f;

    bool all = true;
    for (int b = 0; b < kPeqBandCount; ++b) {
        float c[kCoeffsPerBand];
        rbjBiquad(cfg.bands[b], cfg.sampleRate, c);
        bool finite = true;
        for (int k = 0; k < kCoeffsPerBand; ++k) {
            finite = finite && std::isfinite(c[k]);
        }
        if (!finite) { // 极端参数兜底:恒等,保证音频线程永不发散
            c[0] = 1.0f;
            c[1] = c[2] = c[3] = c[4] = 0.0f;
        }
        for (int k = 0; k < kCoeffsPerBand; ++k) {
            p.coeffs[b][k] = c[k];
        }
        p.identity[b] = bandIsIdentity(c);
        all = all && p.identity[b];
    }
    p.allIdentity = all;
    return p;
}

// 发布:把当前配置写入 writer 槽并原子交换为 latest(持有 g_configMutex 时调用)。
void publishParams() {
    g_slots[g_writerSlot] = buildParams(g_config);
    const int prev = g_latestSlot.exchange(static_cast<int>(g_writerSlot),
                                           std::memory_order_acq_rel);
    g_writerSlot = static_cast<unsigned>(prev); // 旧 latest 归还为下一写槽
}

// 取用:音频线程用自己的 reader 槽换出最新完成的参数组(无锁,唯一原子操作)。
// 交换后旧 reader 槽经 latest 交还控制线程复用,因此本组参数在下次取用前
// 不会被改写(不变式见文件头)。
inline const DspParams *acquireParams() {
    const int fresh = g_latestSlot.exchange(static_cast<int>(g_readerSlot),
                                            std::memory_order_acq_rel);
    g_readerSlot = static_cast<unsigned>(fresh);
    return &g_slots[fresh];
}

} // namespace

// ---------------- 公开 API ----------------

void dspPrepare(int sampleRate, int channels) {
    std::lock_guard<std::mutex> lk(g_configMutex);
    int sr = sampleRate;
    if (sr < 8000) sr = 8000;      // 防御性钳位
    if (sr > 768000) sr = 768000;
    int ch = channels;
    if (ch < 1) ch = 1;
    if (ch > kDspMaxChannels) ch = kDspMaxChannels;
    g_config.sampleRate = sr;
    g_config.channels = ch;
    ++g_config.stateEpoch; // 推进状态代次 → 音频线程自行清零滤波状态
    publishParams();       // 按新采样率重算全部系数(已设置的频段 / RG 保留)
}

void dspProcessInterleavedF32(float *data, size_t frameCount) {
    if (data == nullptr || frameCount == 0) return;
    const DspParams &p = *acquireParams();

    // 状态代次变化(prepare / PEQ 开关)→ 由音频线程自行清零,避免跨线程竞争
    if (p.stateEpoch != g_lastEpoch) {
        for (int c = 0; c < kDspMaxChannels; ++c) {
            for (int b = 0; b < kPeqBandCount; ++b) {
                g_state[c][b] = BiquadState{};
            }
        }
        g_lastEpoch = p.stateEpoch;
    }

    const int ch = p.channels;
    if (ch <= 0) return; // 尚未 prepare

    const bool rgOn = (p.rgGain != 1.0f);
    const bool peqOn = (p.peqEnabled && !p.allIdentity);
    if (!rgOn && !peqOn) return; // DSP 全关:逐位直通(恒等保证)

    for (size_t f = 0; f < frameCount; ++f) {
        float *frame = data + f * static_cast<size_t>(ch);
        for (int c = 0; c < ch; ++c) {
            float x = frame[c];
            if (rgOn) {
                x *= p.rgGain; // RG:线性增益 = 10^(dB/20)(控制线程预算)
            }
            if (peqOn) {
                x = peqChain(x, g_state[c], p); // PEQ:31 段 biquad 串联
            }
            frame[c] = softLimit(x); // 软限幅:兜住 RG / PEQ 造成的 >1.0 过冲
        }
    }
}

void dspSetPeqBand(int index, int type, float freq, float gainDb, float q) {
    std::lock_guard<std::mutex> lk(g_configMutex);
    if (index == kPeqResetAllIndex) {
        const float *f = defaultPeqFreqs();
        for (int b = 0; b < kPeqBandCount; ++b) {
            g_config.bands[b] = BandSpec{kPeqPeak, f[b], 0.0f, kDefaultPeqQ};
        }
    } else if (index >= 0 && index < kPeqBandCount) {
        BandSpec s;
        s.type = (type >= kPeqPeak && type <= kPeqHighPass) ? type : kPeqPeak;
        s.freq = freq;
        s.gainDb = gainDb;
        s.q = q;
        g_config.bands[index] = s;
    } else {
        return; // 非法 index:静默忽略
    }
    publishParams();
}

void dspSetPeqEnabled(bool enabled) {
    std::lock_guard<std::mutex> lk(g_configMutex);
    if (g_config.peqEnabled != enabled) {
        g_config.peqEnabled = enabled;
        // 开关切换重置滤波状态,避免旧状态残留导致再开启瞬间的爆音
        ++g_config.stateEpoch;
    }
    publishParams();
}

void dspSetReplayGain(float trackGainDb, float trackPeak, float albumGainDb,
                      float albumPeak, int mode) {
    std::lock_guard<std::mutex> lk(g_configMutex);
    g_config.rgTrackGainDb = trackGainDb;
    g_config.rgTrackPeak = trackPeak;     // 峰值供上层显示 / 防削波预判;
    g_config.rgAlbumGainDb = albumGainDb; // DSP 端按规范直接应用增益,
    g_config.rgAlbumPeak = albumPeak;     // 超限样本由链尾软压限兜底
    g_config.rgMode = (mode == kReplayGainTrack || mode == kReplayGainAlbum)
                          ? mode
                          : kReplayGainOff;
    publishParams();
}

const float *dspPeqDefaultFreqs() {
    return defaultPeqFreqs();
}


// ---- 整型源格式 → 交错 F32(渲染回调内使用;dr_flac S32 为左对齐 24bit) ----
// U8(无符号)→[-1,1);S16→/32768;S32→/2147483648
void convertToInterleavedF32(const uint8_t *src, size_t byteCount, OutputFormat fmt, float *dst)
{
    switch (fmt) {
        case OutputFormat::U8: {
            const size_t n = byteCount;
            for (size_t i = 0; i < n; i++) {
                dst[i] = (static_cast<float>(src[i]) - 128.0f) / 128.0f;
            }
            break;
        }
        case OutputFormat::S16LE: {
            const size_t n = byteCount / 2;
            for (size_t i = 0; i < n; i++) {
                const int16_t v = static_cast<int16_t>(src[2 * i] | (static_cast<uint16_t>(src[2 * i + 1]) << 8));
                dst[i] = static_cast<float>(v) / 32768.0f;
            }
            break;
        }
        case OutputFormat::S32LE: {
            const size_t n = byteCount / 4;
            for (size_t i = 0; i < n; i++) {
                const int32_t v = static_cast<int32_t>(src[4 * i] | (static_cast<uint32_t>(src[4 * i + 1]) << 8) |
                                                       (static_cast<uint32_t>(src[4 * i + 2]) << 16) |
                                                       (static_cast<uint32_t>(src[4 * i + 3]) << 24));
                dst[i] = static_cast<float>(static_cast<double>(v) / 2147483648.0);
            }
            break;
        }
        case OutputFormat::F32LE:
            std::memcpy(dst, src, byteCount);
            break;
        default:
            break;
    }
}

} // namespace timbrava

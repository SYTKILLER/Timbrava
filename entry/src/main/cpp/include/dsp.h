// Timbrava DSP 总链:ReplayGain → 31 段参数均衡器(PEQ)→ 软限幅。
//
// 纯算法模块:仅依赖 C++ 标准库,不包含任何 OHOS/hilog 头,便于移植与单元
// 测试;诊断信息通过返回值/出参暴露,不做日志输出。
//
// 线程契约(借鉴 Flick 的 DSP 参数架构思想:固定容量 + 双缓冲 + 原子发布,
// 只借鉴思想不抄代码):
//   - dspPrepare / dspSetPeqBand / dspSetPeqEnabled / dspSetReplayGain:
//       控制线程(UI/JS 线程)调用;控制侧仅用互斥锁序列化多个 setter,
//       与音频线程完全解耦;
//   - dspProcessInterleavedF32:实时音频回调线程调用。
//       保证无锁、零内存分配、无系统调用;对参数(系数)数据只读;
//   - 系数发布采用“三槽轮换”的双缓冲加固方案(原理见 dsp.cpp 顶部说明),
//       彻底避免 UI 线程覆写音频线程正在读取的影子系数组。
#ifndef TIMBRAVA_DSP_H
#define TIMBRAVA_DSP_H

#include <cstddef>

namespace timbrava {

// ---------------- 常量 ----------------

// 固定 31 段:20Hz~16kHz 按几何级数均分,相邻频点比值 800^(1/30)≈1.2496,
// 近似 1/3 倍频程(精确 1/3 倍频程中心频率 20Hz~16kHz 恰为 30 点,为满足
// 31 段约定采用几何均分)。每段均可用 dspSetPeqBand 自定义类型与频点。
constexpr int kPeqBandCount = 31;

// dspSetPeqBand 的 index == 31:全部 31 段重置为 flat(peak / 默认频点 / 0 dB)。
constexpr int kPeqResetAllIndex = 31;

// dspPrepare 通道数上限(1~8,立体声为 2);实际通道数以 prepare 为准。
constexpr int kDspMaxChannels = 8;

// ---------------- 枚举 ----------------

// PEQ 频段类型(dspSetPeqBand 的 type 参数)
enum PeqBandType {
    kPeqPeak = 0,       // 峰值 / 钟形(RBJ Cookbook: Peaking EQ)
    kPeqLowShelf = 1,   // 低搁架(RBJ: LowShelf)
    kPeqHighShelf = 2,  // 高搁架(RBJ: HighShelf)
    kPeqLowPass = 3,    // 低通(RBJ: LPF)
    kPeqHighPass = 4,   // 高通(RBJ: HPF)
};

// ReplayGain 应用模式(dspSetReplayGain 的 mode 参数)
enum ReplayGainMode {
    kReplayGainOff = 0,    // 不应用
    kReplayGainTrack = 1,  // 使用曲目增益
    kReplayGainAlbum = 2,  // 使用专辑增益
};

// ---------------- 总链 API ----------------

// 重置总链并设定运行参数(打开新曲目 / 音频会话时调用)。
// 清零全部滤波器状态(通过状态代次由音频线程自行执行,无跨线程竞争);
// 已设置的 PEQ 频段与 ReplayGain 声明保留,并按新采样率重新计算系数。
// sampleRate 钳位到 [8000, 768000],channels 钳位到 [1, kDspMaxChannels]。
// 非音频回调线程调用。
void dspPrepare(int sampleRate, int channels);

// 原地处理交错 f32 采样,链路顺序固定:RG 增益 → PEQ 31 段串联 → 软限幅。
// 仅音频回调线程调用:无锁、零内存分配、无系统调用。
// DSP 完全关闭(RG 关且 PEQ 全恒等)时逐位直通(恒等保证)。
// frameCount 为帧数,缓冲区长度须为 frameCount * dspPrepare 的 channels。
void dspProcessInterleavedF32(float *data, size_t frameCount);

// 设置单个 PEQ 频段,index ∈ [0, 30]。
//   type: 0=peak 1=lowshelf 2=highshelf 3=lowpass 4=highpass(非法值回落 peak);
//   freq: Hz(内部钳位到 [10, 0.49·采样率]);
//   gainDb: 仅对 peak/shelf 生效(内部钳位到 ±30 dB);
//   q: 品质因数(内部钳位到 [0.1, 24])。
// index == kPeqResetAllIndex(31)时全部频段重置为 flat;非法 index 静默忽略。
// 系数在控制线程计算并原子发布,音频回调无感切换(系数切换保留滤波器状态,
// 拖动滑块不爆音)。
void dspSetPeqBand(int index, int type, float freq, float gainDb, float q);

// PEQ 总开关。关闭时 PEQ 段整体旁路(不影响 RG 与软限幅)。
void dspSetPeqEnabled(bool enabled);

// 设置 ReplayGain。线性增益 = 10^(gainDb/20):
//   mode=0 关闭;mode=1 使用 trackGainDb;mode=2 使用 albumGainDb(其余按 0 处理)。
// trackPeak/albumPeak 为对应模式的重放峰值,供上层显示与防削波预判;
// DSP 端按规范直接应用增益,超限样本(|sample|·gain > 1.0)由链尾软压限兜底。
void dspSetReplayGain(float trackGainDb, float trackPeak, float albumGainDb,
                      float albumPeak, int mode);

// ---------------- 辅助查询 ----------------

// 返回 31 个默认中心频率(Hz,20Hz~16kHz 几何均分),供 UI 绘制滑条。
// 返回静态存储指针,进程生命周期内有效;任意线程可调用。
const float *dspPeqDefaultFreqs();

} // namespace timbrava

#endif // TIMBRAVA_DSP_H

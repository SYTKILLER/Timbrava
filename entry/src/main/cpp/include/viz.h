// 频谱可视化(0.18.0):渲染回调侧 FFT 频谱分析,JS 轮询取最新频段数据。
// 数据流:engine 渲染回调(音频线程)在 DSP 之后、交给 renderer 之前把成品 PCM
// 喂给 vizFeed*;viz 内部降混单声道 → 4096 点 FFT(Hann 窗)→ 48 个对数频段
// 能量(dB 归一化)→ 4 槽无锁发布;JS 经 napi vizPoll 轮询最新快照。
//
// 线程契约:
//   - vizSetEnabled / vizPrepare:控制线程(JS/napi)调用;
//   - vizFeedF32 / vizFeedInt:仅音频回调线程调用,零锁零分配(启用检查为单次原子读);
//   - vizPoll:JS 线程调用,读最近一次发布完成的槽。
//     4 槽轮换:写入者只写 (latest+1)%4,发布后推进;读取者读 latest——该槽在
//     再过 2 次发布(~86ms)内绝不被写入,读取期间无被覆写风险。
#ifndef TIMBRAVA_VIZ_H
#define TIMBRAVA_VIZ_H

#include <cstddef>
#include "decoder.h"

namespace timbrava {

// 频段数(对数分布 30Hz~20kHz,JS 侧按此长度建 Float32Array)
constexpr int kVizBandCount = 48;

// 启用开关。关闭时 feed 直返(单次原子读开销),渲染路径零额外成本。
void vizSetEnabled(bool on);
bool vizEnabled();

// 采样率/通道变化时重置(建表/清窗);任意线程可调,开销极小。
void vizPrepare(int sampleRate, int channels);

// 喂入成品交错 PCM(渲染回调线程)。仅 enabled 时计算;内部自动降混单声道,
// 每累计 HOP 帧(约 21ms)做一次 FFT 并发布新快照。
void vizFeedF32(const float *data, size_t frameCount, int channels);
// 整型渲染流(比特完美直通路径)的重载:按格式就地转 float 降混,不改写源缓冲。
void vizFeedInt(const uint8_t *data, size_t frameCount, int channels, OutputFormat fmt);

// 快照(48 频段已归一化 0~1 + 全窗 RMS dBFS / 线性峰值)
struct VizSnapshot {
    int frameId = 0;       // 发布序号(每次 FFT +1;JS 侧据此判断是否有新帧)
    float rmsDb = -90.0f;  // 本窗 RMS(dBFS)
    float peak = 0.0f;     // 本窗线性峰值(0~1)
    float bands[kVizBandCount] = {0};
};

// 取最近一次发布完成的快照(复制语义;无数据时各字段为零值)。
bool vizPoll(VizSnapshot *out);

} // namespace timbrava

#endif // TIMBRAVA_VIZ_H

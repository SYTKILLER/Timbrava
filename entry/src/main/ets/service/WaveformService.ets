// 波形包络服务(0.19.0):波形进度条数据源。
// 缓存优先(waveform_cache BLOB)→ 未命中走 native envelopeFd 整曲解码取峰值桶(400 桶,
// flac/wav;DSD/mp3/ogg 不支持返回 null,波形条隐藏)→ 落库缓存。同曲在途请求去重。
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Db } from '../data/Db';
import { Song } from '../data/Model';
import { PlayerController } from './PlayerController';
import { openTargetOf } from '../common/PathUtil';

const TAG = '[Timbrava][Waveform]';
const DOMAIN = 0x0001;
const WAVE_BUCKETS = 400; // 峰值桶数(播放页波形条取样密度)

export class WaveformService {
  private static instance: WaveformService | null = null;
  static get(): WaveformService {
    if (WaveformService.instance === null) {
      WaveformService.instance = new WaveformService();
    }
    return WaveformService.instance;
  }

  private inflight: Map<number, Promise<Float32Array | null>> = new Map<number, Promise<Float32Array | null>>();

  // 支持格式:仅 native 解码器覆盖的 PCM 无损(flac/wav);DSD 整曲解码代价过高暂不纳入
  supported(codec: string): boolean {
    return codec === 'flac' || codec === 'wav';
  }

  async getFor(song: Song): Promise<Float32Array | null> {
    if (!this.supported(song.codec)) {
      return null;
    }
    const existing = this.inflight.get(song.id);
    if (existing !== undefined) {
      return existing;
    }
    const p = this.load(song);
    this.inflight.set(song.id, p);
    p.finally((): void => {
      this.inflight.delete(song.id);
    });
    return p;
  }

  private async load(song: Song): Promise<Float32Array | null> {
    try {
      const cached = await Db.get().getWaveform(song.id, WAVE_BUCKETS);
      if (cached !== null) {
        return cached;
      }
      // 解码整曲(native 异步工作线程;fd 在 promise 完成前保持打开)
      let f: fs.File | null = null;
      try {
        f = await fs.open(openTargetOf(song.path), fs.OpenMode.READ_ONLY);
        const data = await PlayerController.get().envelopeFor(f.fd, WAVE_BUCKETS);
        if (data !== null && data.length === WAVE_BUCKETS) {
          await Db.get().putWaveform(song.id, WAVE_BUCKETS, data);
          hilog.info(DOMAIN, TAG, 'waveform computed song=%{public}d buckets=%{public}d', song.id, WAVE_BUCKETS);
          return data;
        }
        return null;
      } finally {
        if (f !== null) {
          try {
            fs.closeSync(f);
          } catch (e) {
          }
        }
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'waveform load fail song=%{public}d %{public}s', song.id, (e as Error).message);
      return null;
    }
  }
}

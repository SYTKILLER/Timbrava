// ReplayGain 扫描器(#23):逐曲 native 异步分析 → 95 分位块 RMS + 峰值
// → track 增益/峰值逐曲写库;album 增益按专辑能量均值聚合后回填全组。
// 扫描在应用内后台串行执行;同一时间只允许一次(running 门闩)。
import { hilog } from '@kit.PerformanceAnalysisKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { PlayerController } from './PlayerController';
import { NativeAnalyzeResult } from './engine/LosslessEngine';
import { LibraryStore } from '../data/LibraryStore';
import { Db } from '../data/Db';
import { Song } from '../data/Model';

const TAG = '[Timbrava][RgScan]';
const DOMAIN = 0x0001;

// ReplayGain 2.0 参考响度(-18 LUFS)的简化:P2 分析未加等响权重,公式 gain = -18 - rms95dB
const RG_REF_DB = -18.0;
const RG_GAIN_LIMIT = 24.0;

export class RgScanState {
  running: boolean = false;
  current: number = 0;
  total: number = 0;
  albumLabel: string = '';
  done: boolean = false;
  failCount: number = 0;
}

export class RgScanner {
  private static instance: RgScanner | null = null;
  static get(): RgScanner {
    if (RgScanner.instance === null) {
      RgScanner.instance = new RgScanner();
    }
    return RgScanner.instance;
  }

  state: RgScanState = new RgScanState();
  private cancelRequested: boolean = false;

  isRunning(): boolean {
    return this.state.running;
  }

  cancel(): void {
    this.cancelRequested = true;
  }

  private bump(): void {
    AppStorage.setOrCreate('rgScanVer', (AppStorage.get<number>('rgScanVer') ?? 0) + 1);
  }

  // 按专辑分组扫描(组内聚合 album 增益);songs 须只含 flac/wav(其余自动跳过)
  async scan(songs: Song[]): Promise<void> {
    if (this.state.running) {
      hilog.warn(DOMAIN, TAG, 'scan already running, ignore');
      return;
    }
    const list = songs.filter((s: Song): boolean => s.codec === 'flac' || s.codec === 'wav');
    if (list.length === 0) {
      hilog.info(DOMAIN, TAG, 'no scannable tracks');
      return;
    }
    this.state = new RgScanState();
    this.state.running = true;
    this.state.total = list.length;
    this.cancelRequested = false;
    this.bump();
    hilog.info(DOMAIN, TAG, 'scan start n=%{public}d', list.length);

    // 专辑分组(保序)
    const groups: Map<string, Song[]> = new Map();
    for (const s of list) {
      const key = s.albumArtist + '\u0001' + s.displayAlbum();
      const g = groups.get(key);
      if (g !== undefined) {
        g.push(s);
      } else {
        groups.set(key, [s]);
      }
    }

    const keys: string[] = [];
    groups.forEach((_g: Song[], k: string): void => {
      keys.push(k);
    });
    for (const key of keys) {
      const group = groups.get(key) as Song[];
      if (this.cancelRequested) {
        break;
      }
      this.state.albumLabel = group.length > 0 ? group[0].displayAlbum() : '';
      this.bump();
      // 逐曲分析
      const gainsDb: number[] = [];
      let albumPeak = 0;
      const trackResults: Map<number, number[]> = new Map(); // songId → [trackGain, trackPeak]
      for (const s of group) {
        if (this.cancelRequested) {
          break;
        }
        this.state.current++;
        this.bump();
        let f: fs.File | null = null;
        try {
          f = await fs.open(s.path, fs.OpenMode.READ_ONLY);
          const r: NativeAnalyzeResult = await PlayerController.get().analyzeFdForScan(f.fd);
          if (r.ok) {
            const gain = Math.max(-RG_GAIN_LIMIT, Math.min(RG_GAIN_LIMIT, RG_REF_DB - r.rmsDb));
            gainsDb.push(r.rmsDb);
            albumPeak = Math.max(albumPeak, r.peak);
            trackResults.set(s.id, [gain, r.peak]);
            // 专辑聚合在组尾回填;先写 track 值
            await Db.get().updateSongRg(s.id, gain, r.peak, 0, 0);
            hilog.debug(DOMAIN, TAG, 'track analyzed id=%{public}d rms=%{public}d peak=%{public}d',
              s.id, Math.round(r.rmsDb * 100), Math.round(r.peak * 1000));
          } else {
            this.state.failCount++;
            hilog.warn(DOMAIN, TAG, 'analyze fail id=%{public}d %{public}s', s.id, r.msg);
          }
        } catch (e) {
          this.state.failCount++;
          hilog.warn(DOMAIN, TAG, 'scan io fail %{public}s', (e as Error).message);
        } finally {
          if (f !== null) {
            try {
              fs.closeSync(f);
            } catch (e2) {
            }
          }
        }
      }
      // 专辑聚合:能量均值 → album 增益,回填整组(用组内已分析的 track 结果,避免覆写旧值)
      if (gainsDb.length > 0) {
        let sumLin = 0;
        for (const db of gainsDb) {
          sumLin += Math.pow(10, db / 10);
        }
        const albumRmsDb = 10 * Math.log10(sumLin / gainsDb.length);
        const albumGain = Math.max(-RG_GAIN_LIMIT, Math.min(RG_GAIN_LIMIT, RG_REF_DB - albumRmsDb));
        const ids: number[] = [];
        trackResults.forEach((_tp: number[], sid: number): void => {
          ids.push(sid);
        });
        for (const songId of ids) {
          const tp = trackResults.get(songId) as number[];
          await Db.get().updateSongRg(songId, tp[0], tp[1], albumGain, albumPeak);
        }
      }
    }
    this.state.running = false;
    this.state.done = true;
    this.bump();
    hilog.info(DOMAIN, TAG, 'scan done fail=%{public}d cancel=%{public}s', this.state.failCount,
      String(this.cancelRequested));
    // 库缓存刷新(rg 字段变化)
    await LibraryStore.get().reload();
    AppStorage.setOrCreate('libVer', (AppStorage.get<number>('libVer') ?? 0) + 1);
    // 正在播放的曲目即时应用新增益
    PlayerController.get().reapplyCurrentDsp();
  }
}

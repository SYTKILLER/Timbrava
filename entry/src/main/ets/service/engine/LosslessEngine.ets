// LosslessEngine:Native 无损引擎桥(timbrava_core.so)。
// 命令同步下发 + 250ms 轮询事件(位深/采样率直通 OHAudio)。
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { IAudioEngine, EngineKind, EngineTrackInfo, EngineEventData, EngineEventKind, EngineEventCb } from './EngineTypes';
import timbravaCore from 'libtimbrava_core.so';
import { openTargetOf } from '../../common/PathUtil';

const TAG = '[Timbrava][Lossless]';
const DOMAIN = 0x0001;

interface NativeTrackInfo {
  ok: boolean;
  msg: string;
  sampleRate: number;
  channels: number;
  bitDepth: number;
  dsdRate: number;
  totalFrames: number;
  codec: string;
}

interface NativeModule {
  openFd(fd: number): NativeTrackInfo;
  openNextFd(fd: number): boolean;
  clearNextTrack(): void;
  play(): void;
  pause(): void;
  stop(): void;
  seek(ms: number): boolean;
  setVolume(v: number): void;
  getPosition(): number;
  getDuration(): number;
  getTrackInfo(): NativeTrackInfo;
  pollEvents(): Array<string>;
  shutdown(): void;
  setPeqEnabled(on: boolean): void;
  setPeqBand(index: number, type: number, freq: number, gainDb: number, q: number): void;
  setReplayGain(trackGainDb: number, trackPeak: number, albumGainDb: number, albumPeak: number, mode: number): void;
  setSpeed(speed: number): void;
  setSkipSilence(on: boolean): void;
  analyzeFd(fd: number): Promise<NativeAnalyzeResult>;
};

export interface NativeAnalyzeResult {
  ok: boolean;
  msg: string;
  rmsDb: number;
  peak: number;
  durationMs: number;
}

export class LosslessEngine implements IAudioEngine {
  private cb: EngineEventCb | null = null;
  private info: EngineTrackInfo = EngineTrackInfo.EMPTY();

  getKind(): EngineKind {
    return EngineKind.LOSSLESS;
  }

  setEventCb(cb: EngineEventCb): void {
    this.cb = cb;
  }

  available(): boolean {
    return true;
  }

  async open(uri: string): Promise<EngineTrackInfo> {
    uri = openTargetOf(uri); // 库键可能带 'uri:' 前缀(picker 授权根)
    const m: NativeModule = timbravaCore as NativeModule;
    let f: fs.File | null = null;
    try {
      f = await fs.open(uri, fs.OpenMode.READ_ONLY);
      const res = m.openFd(f.fd);
      if (!res.ok) {
        throw new Error(res.msg.length > 0 ? res.msg : 'openFd failed');
      }
      this.info = new EngineTrackInfo();
      this.info.sampleRate = res.sampleRate;
      this.info.channels = res.channels;
      this.info.bitDepth = res.bitDepth;
      this.info.codec = res.codec;
      this.info.dsdRate = res.dsdRate;
      this.info.durationMs = res.totalFrames > 0 && this.info.sampleRate > 0
        ? Math.round(res.totalFrames * 1000 / this.info.sampleRate) : 0;
      hilog.info(DOMAIN, TAG, 'open ok %{public}s %{public}dHz %{public}dch %{public}dbit dur=%{public}d',
        this.info.codec, this.info.sampleRate, this.info.channels, this.info.bitDepth, this.info.durationMs);
      return this.info;
    } finally {
      // native 已 dup fd,ArkTS 侧立即归还
      if (f !== null) {
        try {
          fs.closeSync(f);
        } catch (e) {
        }
      }
    }
  }

  play(): void {
    const m: NativeModule = timbravaCore as NativeModule;
    m.play();
  }

  // gapless(M3):预排下一曲(fd 打开→native 探测+格式校验→立即关;native 已 dup)。
  // 返回 false = 格式不一致/探测失败,上层走普通切曲路径。
  openNext(uri: string): boolean {
    uri = openTargetOf(uri);
    const m: NativeModule = timbravaCore as NativeModule;
    let f: fs.File | null = null;
    try {
      f = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      return m.openNextFd(f.fd);
    } catch (e) {
      return false;
    } finally {
      if (f !== null) {
        try {
          fs.closeSync(f);
        } catch (e2) {
        }
      }
    }
  }

  clearNext(): void {
    (timbravaCore as NativeModule).clearNextTrack();
  }

  pause(): void {
    const m: NativeModule = timbravaCore as NativeModule;
    m.pause();
  }

  stop(): void {
    const m: NativeModule = timbravaCore as NativeModule;
    m.stop();
  }

  seek(ms: number): void {
    const m: NativeModule = timbravaCore as NativeModule;
    const ok = m.seek(ms);
    if (!ok) {
      hilog.warn(DOMAIN, TAG, 'seek rejected at %{public}d', ms);
    }
  }

  getPositionMs(): number {
    const m: NativeModule = timbravaCore as NativeModule;
    return Math.round(m.getPosition());
  }

  getDurationMs(): number {
    return this.info.durationMs;
  }

  // 250ms 轮询:把 native 事件转为统一事件
  pollNativeEvents(): void {
    const m: NativeModule = timbravaCore as NativeModule;
    const rawEvents: Array<string> = m.pollEvents();
    for (const raw of rawEvents) {
      let ev: Record<string, Object> | null = null;
      try {
        ev = JSON.parse(raw) as Record<string, Object>;
      } catch (e) {
        continue;
      }
      if (ev === null) {
        continue;
      }
      const kind = String(ev['ev'] ?? '');
      if (kind === 'end') {
        this.emit(EngineEventKind.TRACK_END, 0, 'native end');
      } else if (kind === 'gaplessNext') {
        this.emit(EngineEventKind.GAPLESS_NEXT, 0, 'native gapless advanced');
      } else if (kind === 'error') {
        this.emit(EngineEventKind.ERROR, Number(ev['code'] ?? 0), `native error src=${String(ev['src'] ?? '')}`);
      } else if (kind === 'interrupt') {
        this.emit(EngineEventKind.INTERRUPT, Number(ev['hint'] ?? 0), 'native interrupt');
      } else if (kind === 'seekDone') {
        this.emit(EngineEventKind.SEEK_DONE, Number(ev['ms'] ?? 0), 'native seekDone');
      } else if (kind === 'underrun') {
        this.emit(EngineEventKind.UNDERRUN, 0, 'buffer underrun');
      }
    }
  }

  setPeq(on: boolean): void {
    (timbravaCore as NativeModule).setPeqEnabled(on);
  }

  setPeqBand(index: number, type: number, freq: number, gainDb: number, q: number): void {
    (timbravaCore as NativeModule).setPeqBand(index, type, freq, gainDb, q);
  }

  setReplayGain(trackGainDb: number, trackPeak: number, albumGainDb: number, albumPeak: number, mode: number): void {
    (timbravaCore as NativeModule).setReplayGain(trackGainDb, trackPeak, albumGainDb, albumPeak, mode);
  }

  setSpeed(speed: number): void {
    (timbravaCore as NativeModule).setSpeed(speed);
  }

  setSkipSilence(on: boolean): void {
    (timbravaCore as NativeModule).setSkipSilence(on);
  }

  // ReplayGain 扫描(native 异步工作线程;fd 在 promise 完成前保持有效)
  async analyzeFd(fd: number): Promise<NativeAnalyzeResult> {
    return (timbravaCore as NativeModule).analyzeFd(fd);
  }

  release(): void {
    const m: NativeModule = timbravaCore as NativeModule;
    m.shutdown();
  }

  private emit(kind: EngineEventKind, hint: number, msg: string): void {
    if (this.cb !== null) {
      this.cb(new EngineEventData(kind, hint, msg));
    }
  }
}

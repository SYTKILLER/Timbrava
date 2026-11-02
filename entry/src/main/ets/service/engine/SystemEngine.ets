// SystemEngine:AVPlayer 封装(兜底引擎,格式覆盖广)。
// 单实例复用:reset → url → prepared → play;completed 状态驱动下一曲。
import { media } from '@kit.MediaKit';
import { audio } from '@kit.AudioKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { IAudioEngine, EngineKind, EngineTrackInfo, EngineEventData, EngineEventKind, EngineEventCb } from './EngineTypes';

const TAG = '[Timbrava][SysEngine]';
const DOMAIN = 0x0001;

export class SystemEngine implements IAudioEngine {
  private player: media.AVPlayer | null = null;
  private fd: number = -1;
  private cb: EngineEventCb | null = null;
  private state: string = 'idle';
  private curUri: string = '';
  private durationMs: number = 0;
  private lastPosMs: number = 0;
  private seekTargetMs: number = -1;

  getKind(): EngineKind {
    return EngineKind.SYSTEM;
  }

  setEventCb(cb: EngineEventCb): void {
    this.cb = cb;
  }

  available(): boolean {
    return true;
  }

  private async ensurePlayer(): Promise<media.AVPlayer> {
    if (this.player !== null) {
      return this.player;
    }
    const p = await media.createAVPlayer();
    p.on('stateChange', (state: string, reason: media.StateChangeReason) => {
      hilog.info(DOMAIN, TAG, 'state %{public}s reason=%{public}d', state, reason);
      this.state = state;
      if (state === 'completed') {
        this.emit(EngineEventKind.TRACK_END, 0, 'completed');
      } else if (state === 'error') {
        this.emit(EngineEventKind.ERROR, 0, 'avplayer error state');
      } else if (state === 'prepared') {
        this.durationMs = p.duration > 0 ? p.duration : this.durationMs;
        if (this.seekTargetMs > 0) {
          try {
            p.seek(this.seekTargetMs, media.SeekMode.SEEK_PREV_SYNC);
          } catch (e) {
            hilog.warn(DOMAIN, TAG, 'pending seek fail %{public}s', (e as Error).message);
          }
          this.seekTargetMs = -1;
        }
      }
    });
    p.on('timeUpdate', (time: number) => {
      this.lastPosMs = time;
    });
    p.on('durationUpdate', (duration: number) => {
      this.durationMs = duration;
    });
    p.on('seekDone', (pos: number) => {
      this.lastPosMs = pos;
      this.emit(EngineEventKind.SEEK_DONE, pos, 'seekDone');
    });
    p.on('audioInterrupt', (event: audio.InterruptEvent) => {
      hilog.info(DOMAIN, TAG, 'interrupt type=%{public}d force=%{public}d hint=%{public}d',
        event.eventType, event.forceType, event.hintType);
      this.emit(EngineEventKind.INTERRUPT, event.hintType, 'avplayer interrupt');
    });
    p.on('error', (err: BusinessError) => {
      hilog.error(DOMAIN, TAG, 'avplayer error %{public}d %{public}s', err.code, err.message);
      this.emit(EngineEventKind.ERROR, err.code, err.message);
    });
    this.player = p;
    return p;
  }

  private emit(kind: EngineEventKind, hint: number, msg: string): void {
    if (this.cb !== null) {
      this.cb(new EngineEventData(kind, hint, msg));
    }
  }

  async open(uri: string): Promise<EngineTrackInfo> {
    const p = await this.ensurePlayer();
    // 复用实例:先 reset 回 idle
    if (this.state !== 'idle') {
      await p.reset();
      this.closeFd();
      this.state = 'idle';
    }
    this.curUri = uri;
    try {
      const f = await fs.open(uri, fs.OpenMode.READ_ONLY);
      this.fd = f.fd;
      p.url = `fd://${this.fd}`;
      // url 设置是异步迁移,必须等 initialized 事件再 prepare
      const waitInit = async (): Promise<void> => {
        for (let i = 0; i < 50; i++) {
          if (this.state === 'initialized') {
            return;
          }
          await new Promise<void>((r: () => void) => setTimeout(r, 20));
        }
        throw new Error('timeout waiting initialized state');
      };
      await waitInit();
      await p.prepare();
      this.durationMs = p.duration > 0 ? p.duration : 0;
      hilog.info(DOMAIN, TAG, 'open ok dur=%{public}d uri_len=%{public}d', this.durationMs, uri.length);
      const info = new EngineTrackInfo();
      info.durationMs = this.durationMs;
      info.codec = '';
      return info;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'open fail %{public}s', (e as Error).message);
      this.closeFd();
      throw e as Error;
    }
  }

  play(): void {
    if (this.player !== null && (this.state === 'prepared' || this.state === 'paused' || this.state === 'completed')) {
      this.player.play().then(() => {
        hilog.info(DOMAIN, TAG, 'play ok');
      }).catch((e: BusinessError) => {
        hilog.error(DOMAIN, TAG, 'play fail %{public}s', e.message);
      });
    }
  }

  pause(): void {
    if (this.player !== null && this.state === 'playing') {
      this.player.pause().catch((e: BusinessError) => {
        hilog.error(DOMAIN, TAG, 'pause fail %{public}s', e.message);
      });
    }
  }

  stop(): void {
    if (this.player !== null && (this.state === 'playing' || this.state === 'paused' || this.state === 'prepared')) {
      this.player.stop().catch((e: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'stop fail %{public}s', e.message);
      });
    }
  }

  seek(ms: number): void {
    if (this.player === null) {
      return;
    }
    if (this.state === 'prepared' || this.state === 'playing' || this.state === 'paused' || this.state === 'completed') {
      try {
        this.player.seek(ms, media.SeekMode.SEEK_PREV_SYNC);
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'seek fail %{public}s', (e as Error).message);
      }
    } else {
      this.seekTargetMs = ms; // prepared 后补
    }
  }

  getPositionMs(): number {
    return this.lastPosMs;
  }

  getDurationMs(): number {
    return this.durationMs;
  }

  release(): void {
    if (this.player !== null) {
      this.player.release().catch((e: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'release fail %{public}s', e.message);
      });
      this.player = null;
    }
    this.closeFd();
  }

  private closeFd(): void {
    if (this.fd >= 0) {
      try {
        fs.closeSync(this.fd);
      } catch (e) {
      }
      this.fd = -1;
    }
  }
}

// 播放控制器(单例):引擎选路 + AVSession + 后台连续任务 + 音频焦点 + 设备断开暂停 + 收藏 + 统计。
import { UIAbilityContext, wantAgent, WantAgent } from '@kit.AbilityKit';
import { avSession } from '@kit.AVSessionKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { audio } from '@kit.AudioKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Db } from '../data/Db';
import { LibraryStore } from '../data/LibraryStore';
import { ScanService } from '../data/ScanService';
import { SettingsService } from './SettingsService';
import { QueueService } from './QueueService';
import { Song, RepeatMode } from '../data/Model';
import { IAudioEngine, EngineKind, EngineEventData, EngineEventKind, EngineTrackInfo } from './engine/EngineTypes';
import { SystemEngine } from './engine/SystemEngine';
import { LosslessEngine } from './engine/LosslessEngine';

const TAG = '[Timbrava][Player]';
const DOMAIN = 0x0001;

const BT_OR_WIRED_TYPES: number[] = [3, 4, 8, 9, 22]; // wired headset/headphone, BT A2DP/Sco, USB headset

export class PlayerController {
  private static instance: PlayerController | null = null;
  static get(): PlayerController {
    if (PlayerController.instance === null) {
      PlayerController.instance = new PlayerController();
    }
    return PlayerController.instance;
  }

  private ctx: UIAbilityContext | null = null;
  private systemEngine: SystemEngine = new SystemEngine();
  private losslessEngine: LosslessEngine = new LosslessEngine();
  private engine: IAudioEngine | null = null;
  private queue: QueueService = QueueService.get();

  currentSong: Song | null = null;
  isPlaying: boolean = false;
  positionMs: number = 0;
  durationMs: number = 0;
  engineKind: EngineKind = EngineKind.SYSTEM;
  engineInfo: string = '';

  private session: avsession.AVSession | null = null;
  private ticker: number = -1;
  private pausedByInterrupt: boolean = false;
  private bgTaskRunning: boolean = false;
  private initDone: boolean = false;

  private bumpPlayer(): void {
    AppStorage.setOrCreate('playerVer', (AppStorage.get<number>('playerVer') ?? 0) + 1);
  }

  private bumpPos(): void {
    AppStorage.setOrCreate('posVer', (AppStorage.get<number>('posVer') ?? 0) + 1);
  }

  // ============ 初始化 ============

  async init(ctx: UIAbilityContext): Promise<void> {
    if (this.initDone) {
      return;
    }
    this.ctx = ctx;
    try {
      await Db.get().init(ctx);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'db init fail %{public}s', (e as Error).message);
      return;
    }
    await SettingsService.get().load();
    ScanService.get().init(ctx);
    await LibraryStore.get().reload();
    await this.queue.restore();
    this.initDone = true;
    hilog.info(DOMAIN, TAG, 'controller init done');

    this.systemEngine.setEventCb((ev: EngineEventData): void => this.onEngineEvent(ev));
    this.losslessEngine.setEventCb((ev: EngineEventData): void => this.onEngineEvent(ev));
    this.startTicker();
    await this.initAvSession(ctx);
    this.initAudioFocus();
    this.initDeviceListener(ctx);
    this.bumpPlayer();
  }

  private startTicker(): void {
    if (this.ticker >= 0) {
      return;
    }
    this.ticker = setInterval((): void => {
      if (this.engine !== null && this.isPlaying) {
        this.positionMs = this.engine.getPositionMs();
        this.bumpPos();
      }
      if (this.engineKind === EngineKind.LOSSLESS) {
        this.losslessEngine.pollNativeEvents();
      }
    }, 250) as number;
  }

  // ============ 引擎选路 ============

  private chooseEngine(song: Song): IAudioEngine {
    const losslessPref = SettingsService.get().losslessEngine;
    const isNativeCodec = song.codec === 'flac' || song.codec === 'wav';
    if (losslessPref && isNativeCodec && this.losslessEngine.available()) {
      return this.losslessEngine;
    }
    return this.systemEngine;
  }

  private stopEngine(): void {
    if (this.engine !== null) {
      this.engine.stop();
    }
  }

  // 打开并播放指定曲目
  async playSong(song: Song, resumeFromMs: number = 0): Promise<void> {
    if (!this.initDone) {
      hilog.warn(DOMAIN, TAG, 'controller 未就绪,忽略 playSong');
      return;
    }
    const prevSong = this.currentSong;
    const previousPlayedMs = prevSong !== null ? this.positionMs : 0;
    this.stopEngine();
    let target = this.chooseEngine(song);
    let info: EngineTrackInfo | null = null;
    try {
      info = await target.open(song.path);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'engine %{public}d open fail: %{public}s', target.getKind(), (e as Error).message);
      if (target.getKind() === EngineKind.LOSSLESS) {
        target = this.systemEngine;
        try {
          info = await target.open(song.path);
        } catch (e2) {
          hilog.error(DOMAIN, TAG, 'system engine fallback also fail %{public}s', (e2 as Error).message);
        }
      }
    }
    if (info === null) {
      this.isPlaying = false;
      this.bumpPlayer();
      return;
    }
    this.engine = target;
    this.engineKind = target.getKind();
    this.engineInfo = target.getKind() === EngineKind.LOSSLESS
      ? `无损引擎 ${info.codec.toUpperCase()} ${info.bitDepth}bit/${info.sampleRate}Hz`
      : '系统引擎';
    this.currentSong = song;
    this.durationMs = info.durationMs > 0 ? info.durationMs : song.durationMs;
    this.positionMs = 0;
    if (resumeFromMs > 0) {
      target.seek(resumeFromMs);
      this.positionMs = resumeFromMs;
    }
    target.play();
    this.isPlaying = true;
    if (prevSong !== null && previousPlayedMs > 10000 && prevSong.id !== song.id) {
      await Db.get().recordPlay(prevSong.id, previousPlayedMs);
    }
    this.ensureBgTask();
    this.syncSessionNowPlaying();
    this.syncSessionState();
    this.bumpPlayer();
    hilog.info(DOMAIN, TAG, 'playSong [%{public}s] %{public}s via %{public}s', song.codec, song.displayTitle(),
      this.engineInfo);
  }

  private async onEngineEvent(ev: EngineEventData): Promise<void> {
    if (ev.kind === EngineEventKind.TRACK_END) {
      hilog.info(DOMAIN, TAG, 'track end');
      if (this.currentSong !== null) {
        await Db.get().recordPlay(this.currentSong.id, this.durationMs);
      }
      await this.autoNext();
    } else if (ev.kind === EngineEventKind.INTERRUPT) {
      await this.onInterruptHint(ev.hint);
    } else if (ev.kind === EngineEventKind.ERROR) {
      hilog.error(DOMAIN, TAG, 'engine error %{public}s', ev.message);
      // 播放中错误:尝试系统引擎兜底续播
      if (this.engine !== null && this.engine.getKind() === EngineKind.LOSSLESS && this.currentSong !== null) {
        const resumeAt = this.positionMs;
        hilog.warn(DOMAIN, TAG, 'lossless error → fallback to system at %{public}dms', resumeAt);
        try {
          await this.systemEngine.open(this.currentSong.path);
          this.engine = this.systemEngine;
          this.engineKind = EngineKind.SYSTEM;
          this.engineInfo = '系统引擎(无损引擎错误回退)';
          if (resumeAt > 0) {
            this.systemEngine.seek(resumeAt);
          }
          this.systemEngine.play();
          this.isPlaying = true;
          this.bumpPlayer();
        } catch (e) {
          hilog.error(DOMAIN, TAG, 'fallback fail %{public}s', (e as Error).message);
          this.isPlaying = false;
          this.bumpPlayer();
        }
      }
    } else if (ev.kind === EngineEventKind.SEEK_DONE) {
      this.positionMs = ev.hint;
      this.bumpPos();
      this.syncSessionState();
    } else if (ev.kind === EngineEventKind.UNDERRUN) {
      hilog.warn(DOMAIN, TAG, 'underrun');
    }
  }

  private async autoNext(): Promise<void> {
    const next = this.queue.nextIndex(true);
    if (next < 0) {
      // 播完停止
      this.isPlaying = false;
      this.positionMs = this.durationMs;
      this.stopEngine();
      this.syncSessionState();
      this.bumpPlayer();
      hilog.info(DOMAIN, TAG, 'queue end, stop');
      return;
    }
    const song = this.queue.songAt(next);
    this.queue.jumpTo(next);
    if (song !== null) {
      await this.playSong(song, 0);
    }
  }

  // ============ 对外控制 ============

  async playPause(): Promise<void> {
    if (this.currentSong === null) {
      // 未选曲:尝试从队列恢复
      const song = this.queue.currentSong();
      if (song !== null) {
        this.queue.jumpTo(this.queue.locateCurrent());
        await this.playSong(song, 0);
      }
      return;
    }
    if (this.engine === null) {
      await this.playSong(this.currentSong, 0);
      return;
    }
    if (this.isPlaying) {
      this.engine.pause();
      this.isPlaying = false;
    } else {
      this.engine.play();
      this.isPlaying = true;
    }
    this.pausedByInterrupt = false;
    this.syncSessionState();
    this.bumpPlayer();
  }

  async playNext(): Promise<void> {
    const next = this.queue.nextIndex(false);
    if (next < 0) {
      return;
    }
    const song = this.queue.songAt(next);
    this.queue.jumpTo(next);
    if (song !== null) {
      await this.playSong(song, 0);
    }
  }

  async playPrev(): Promise<void> {
    // 播放超过 3s:回到本曲开头(主流行为)
    if (this.positionMs > 3000 && this.currentSong !== null) {
      this.seekTo(0);
      return;
    }
    const prev = this.queue.prevIndex();
    if (prev < 0) {
      return;
    }
    const song = this.queue.songAt(prev);
    this.queue.jumpTo(prev);
    if (song !== null) {
      await this.playSong(song, 0);
    }
  }

  async playQueueIndex(orderIndex: number): Promise<void> {
    const song = this.queue.songAt(orderIndex);
    if (song === null) {
      return;
    }
    this.queue.jumpTo(orderIndex);
    await this.playSong(song, 0);
  }

  seekTo(ms: number): void {
    if (this.engine !== null) {
      this.engine.seek(ms);
      this.positionMs = ms;
      this.bumpPos();
    }
  }

  setRepeat(mode: RepeatMode): void {
    this.queue.setRepeat(mode);
    this.syncSessionLoopMode();
  }

  toggleFavorite(): void {
    if (this.currentSong === null) {
      return;
    }
    this.toggleFavoriteFor(this.currentSong.id);
  }

  toggleFavoriteFor(songId: number): void {
    const fav = !LibraryStore.get().isFavorite(songId);
    LibraryStore.get().setFavorite(songId, fav).then((): void => {
      hilog.info(DOMAIN, TAG, 'favorite song=%{public}d -> %{public}s', songId, fav ? 'on' : 'off');
    });
  }

  // ============ AVSession ============

  private async initAvSession(ctx: UIAbilityContext): Promise<void> {
    try {
      this.session = await avsession.createAVSession(ctx, 'timbrava_player', 'audio');
      const s = this.session;
      s.on('play', (): void => {
        this.playPause();
      });
      s.on('pause', (): void => {
        if (this.isPlaying) {
          this.playPause();
        }
      });
      s.on('playNext', (): void => {
        this.playNext();
      });
      s.on('playPrevious', (): void => {
        this.playPrev();
      });
      s.on('seek', (time: number): void => {
        this.seekTo(time);
      });
      s.on('setLoopMode', (mode: avsession.LoopMode): void => {
        const map: RepeatMode = mode === avsession.LoopMode.LOOP_MODE_SINGLE ? RepeatMode.ONE
          : mode === avsession.LoopMode.LOOP_MODE_LIST ? RepeatMode.ALL : RepeatMode.OFF;
        this.setRepeat(map);
      });
      s.on('toggleFavorite', (assetId: string): void => {
        const id = parseInt(assetId, 10);
        if (!Number.isNaN(id)) {
          this.toggleFavoriteFor(id);
        }
      });
      await s.activate();
      hilog.info(DOMAIN, TAG, 'avsession activated');
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'avsession init fail %{public}s', (e as Error).message);
    }
  }

  private syncSessionNowPlaying(): void {
    const s = this.session;
    const song = this.currentSong;
    if (s === null || song === null) {
      return;
    }
    const meta: avsession.AVMetadata = {
      assetId: String(song.id),
      title: song.displayTitle(),
      artist: song.displayArtist(),
      album: song.displayAlbum(),
      duration: this.durationMs
    };
    if (song.artPath.length > 0) {
      meta.mediaImage = song.artPath;
    }
    s.setAVMetadata(meta).catch((e: Error): void => {
      hilog.warn(DOMAIN, TAG, 'setAVMetadata fail %{public}s', e.message);
    });
    // 队列(上限 30 条,锁屏展示)
    const items: avsession.AVQueueItem[] = [];
    const start = Math.max(0, this.queue.currentOrderIndex - 5);
    const end = Math.min(this.queue.list.length, start + 30);
    for (let i = start; i < end; i++) {
      const qSong = this.queue.songAt(i);
      if (qSong === null) {
        continue;
      }
      const desc: avsession.AVMediaDescription = {
        assetId: String(qSong.id),
        title: qSong.displayTitle(),
        artist: qSong.displayArtist()
      };
      const item: avsession.AVQueueItem = { description: desc };
      items.push(item);
    }
    if (items.length > 0) {
      s.setAVQueueTitle(song.displayAlbum());
      s.setAVQueueItems(items).catch((e: Error): void => {
        hilog.warn(DOMAIN, TAG, 'setAVQueueItems fail %{public}s', e.message);
      });
    }
  }

  private syncSessionState(): void {
    const s = this.session;
    if (s === null) {
      return;
    }
    const state: avsession.AVPlaybackState = {
      state: this.isPlaying ? avsession.PlaybackState.PLAYBACK_STATE_PLAY : avsession.PlaybackState.PLAYBACK_STATE_PAUSE,
      position: { position: this.positionMs, updateTime: Date.now() }
    };
    s.setAVPlaybackState(state).catch((e: Error): void => {
      hilog.warn(DOMAIN, TAG, 'setAVPlaybackState fail %{public}s', e.message);
    });
  }

  private syncSessionLoopMode(): void {
    const s = this.session;
    if (s === null) {
      return;
    }
    const loop: avsession.LoopMode = this.queue.repeat === RepeatMode.ONE ? avsession.LoopMode.LOOP_MODE_SINGLE
      : this.queue.repeat === RepeatMode.ALL ? avsession.LoopMode.LOOP_MODE_LIST : avsession.LoopMode.LOOP_MODE_SEQUENCE;
    const state: avsession.AVPlaybackState = { loopMode: loop };
    s.setAVPlaybackState(state).catch((e: Error): void => {
    });
  }

  // ============ 音频焦点 ============

  private initAudioFocus(): void {
    try {
      const audioManager = audio.getAudioManager();
      const sessionManager = audioManager.getSessionManager();
      sessionManager.on('audioInterrupt', (event: audio.InterruptEvent): void => {
        hilog.info(DOMAIN, TAG, 'audioInterrupt type=%{public}d force=%{public}d hint=%{public}d',
          event.eventType, event.forceType, event.hint);
        this.onInterruptHint(event.hint);
      });
      sessionManager.activateAudioSession({ concurrencyMode: audio.AudioConcurrencyMode.CONCURRENCY_DEFAULT })
        .then((): void => {
          hilog.info(DOMAIN, TAG, 'audio session activated');
        })
        .catch((e: Error): void => {
          hilog.warn(DOMAIN, TAG, 'activateAudioSession fail %{public}s', e.message);
        });
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'initAudioFocus fail %{public}s', (e as Error).message);
    }
  }

  private async onInterruptHint(hint: number): Promise<void> {
    // INTERRUPT_HINT: 0 NONE 1 RESUME 2 PAUSE 3 STOP 4 DUCK 5 UNDUCK
    if (hint === 2 || hint === 3) {
      if (this.isPlaying) {
        this.pausedByInterrupt = true;
        this.engine?.pause();
        this.isPlaying = false;
        this.syncSessionState();
        this.bumpPlayer();
        hilog.info(DOMAIN, TAG, 'interrupt pause');
      }
    } else if (hint === 1) {
      if (this.pausedByInterrupt && SettingsService.get().resumeAfterInterrupt) {
        this.engine?.play();
        this.isPlaying = true;
        this.pausedByInterrupt = false;
        this.syncSessionState();
        this.bumpPlayer();
        hilog.info(DOMAIN, TAG, 'interrupt resume');
      }
    }
    // DUCK/UNDUCK 由系统压音,不处理
  }

  // ============ 设备断开暂停 ============

  private initDeviceListener(ctx: UIAbilityContext): void {
    try {
      const routing = audio.getAudioManager().getRoutingManager();
      routing.on('deviceChange', audio.DeviceFlag.OUTPUT_DEVICES_FLAG,
        (action: audio.DeviceChangeAction): void => {
          if (action.change !== audio.DeviceChangeType.DISCONNECTED) {
            return;
          }
          let relevant = false;
          for (const d of action.deviceDescriptors) {
            if (BT_OR_WIRED_TYPES.indexOf(d.deviceType) >= 0) {
              relevant = true;
              hilog.info(DOMAIN, TAG, 'output device disconnected type=%{public}d', d.deviceType);
            }
          }
          if (!relevant || !this.isPlaying) {
            return;
          }
          const settings = SettingsService.get();
          // 粗分:蓝牙类(type 8/9)与有线类(3/4/22)
          const isBt = action.deviceDescriptors.some((d: audio.AudioDeviceDescriptor): boolean =>
            d.deviceType === 8 || d.deviceType === 9);
          if ((isBt && settings.pauseOnBtOff) || (!isBt && settings.pauseOnHeadphoneOff)) {
            this.engine?.pause();
            this.isPlaying = false;
            this.syncSessionState();
            this.bumpPlayer();
            hilog.info(DOMAIN, TAG, 'device disconnect → pause');
          }
        });
      hilog.info(DOMAIN, TAG, 'device listener ok');
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'initDeviceListener fail %{public}s', (e as Error).message);
    }
  }

  // ============ 后台连续任务 ============

  private async ensureBgTask(): Promise<void> {
    if (this.bgTaskRunning || this.ctx === null) {
      return;
    }
    try {
      const waParam: wantAgent.WantAgentInfo = {
        wants: [{ bundleName: 'com.march.timbrava', abilityName: 'EntryAbility' }],
        operationType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0
      };
      const wa: WantAgent = await wantAgent.getWantAgent(waParam);
      await backgroundTaskManager.startBackgroundRunning(this.ctx,
        backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK, wa);
      this.bgTaskRunning = true;
      hilog.info(DOMAIN, TAG, 'background task started');
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'startBackgroundRunning fail %{public}s', (e as Error).message);
    }
  }

  persistAll(): void {
    this.queue.persistNow();
  }

  async shutdown(): Promise<void> {
    if (this.ticker >= 0) {
      clearInterval(this.ticker);
      this.ticker = -1;
    }
    this.queue.persistNow();
    this.stopEngine();
    if (this.session !== null) {
      try {
        await this.session.destroy();
      } catch (e) {
      }
      this.session = null;
    }
    if (this.bgTaskRunning && this.ctx !== null) {
      try {
        await backgroundTaskManager.stopBackgroundRunning(this.ctx);
      } catch (e) {
      }
      this.bgTaskRunning = false;
    }
    this.systemEngine.release();
    this.losslessEngine.release();
    hilog.info(DOMAIN, TAG, 'shutdown done');
  }
}

// 设置服务:app_settings KV + AppStorage token 同步(页面 @StorageProp 绑定)。
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Db } from '../data/Db';

const TAG = '[Timbrava][Settings]';

// 设置变更 → 无损引擎 DSP 重应用(避免 SettingsService 反向依赖引擎层)
export class PlayerBridge {
  static onDspChanged: (() => void) | null = null;

  static notifyDspChanged(): void {
    if (PlayerBridge.onDspChanged !== null) {
      PlayerBridge.onDspChanged();
    }
  }
}
const DOMAIN = 0x0001;

export class ThemeMode {
  static readonly SYSTEM: string = 'system';
  static readonly LIGHT: string = 'light';
  static readonly DARK: string = 'dark';
}

export class SettingsService {
  private static instance: SettingsService | null = null;
  static get(): SettingsService {
    if (SettingsService.instance === null) {
      SettingsService.instance = new SettingsService();
    }
    return SettingsService.instance;
  }

  // 内存快照(权威)
  themeMode: string = ThemeMode.SYSTEM;
  losslessEngine: boolean = true;
  pauseOnHeadphoneOff: boolean = true;
  pauseOnBtOff: boolean = true;
  resumeAfterInterrupt: boolean = true;
  rgMode: number = 0;          // 0 off 1 track 2 album
  eqOn: boolean = false;
  eqPreset: string = 'flat';
  eqBands: number[] = [];      // 自定义 31 段增益(dB;空数组=全平)
  skipSilence: boolean = false;
  playSpeed: number = 1.0;     // 0.25~3.0
  onlineLyrics: boolean = false; // LRCLIB 联网歌词(默认关,#38 零联网定位)
  playerSkin: string = 'standard'; // standard 大封面 | minimal 极简(#53)

  private loaded: boolean = false;

  private token(name: string, value: string | number | boolean): void {
    AppStorage.setOrCreate(name, value);
  }

  async load(): Promise<void> {
    if (this.loaded || !Db.get().ready()) {
      return;
    }
    const db = Db.get();
    this.themeMode = await db.getSetting('themeMode', ThemeMode.SYSTEM);
    if (this.themeMode === 'black') {
      this.themeMode = ThemeMode.DARK; // 纯黑选项已移除,旧值迁移为深色
    }
    this.losslessEngine = (await db.getSetting('losslessEngine', '1')) === '1';
    this.pauseOnHeadphoneOff = (await db.getSetting('pauseOnHeadphoneOff', '1')) === '1';
    this.pauseOnBtOff = (await db.getSetting('pauseOnBtOff', '1')) === '1';
    this.resumeAfterInterrupt = (await db.getSetting('resumeAfterInterrupt', '1')) === '1';
    this.rgMode = parseInt(await db.getSetting('rgMode', '0'), 10);
    if (Number.isNaN(this.rgMode)) {
      this.rgMode = 0;
    }
    this.eqOn = (await db.getSetting('eqOn', '0')) === '1';
    this.eqPreset = await db.getSetting('eqPreset', 'flat');
    this.eqBands = Db.parseBands(await db.getSetting('eqBands', '[]'));
    this.skipSilence = (await db.getSetting('skipSilence', '0')) === '1';
    const sp = parseFloat(await db.getSetting('playSpeed', '1.0'));
    this.playSpeed = Number.isFinite(sp) && sp >= 0.25 && sp <= 3.0 ? sp : 1.0;
    this.onlineLyrics = (await db.getSetting('onlineLyrics', '0')) === '1';
    const skin = await db.getSetting('playerSkin', 'standard');
    this.playerSkin = skin === 'minimal' ? 'minimal' : 'standard';
    this.loaded = true;
    this.syncTokens();
    hilog.info(DOMAIN, TAG, 'settings loaded');
  }

  syncTokens(): void {
    this.token('prefThemeMode', this.themeMode);
    this.token('prefLossless', this.losslessEngine);
    this.token('prefPauseHeadphone', this.pauseOnHeadphoneOff);
    this.token('prefPauseBt', this.pauseOnBtOff);
    this.token('prefResumeInterrupt', this.resumeAfterInterrupt);
    this.token('prefRgMode', this.rgMode);
    this.token('prefEqOn', this.eqOn);
    this.token('prefEqPreset', this.eqPreset);
    this.token('prefEqBands', Db.stringifyBands(this.eqBands));
    this.token('prefSkipSilence', this.skipSilence);
    this.token('prefPlaySpeed', this.playSpeed);
    this.token('prefOnlineLyrics', this.onlineLyrics);
    this.token('prefPlayerSkin', this.playerSkin);
  }

  private async save(key: string, value: string): Promise<void> {
    await Db.get().setSetting(key, value);
  }

  async setThemeMode(mode: string): Promise<void> {
    this.themeMode = mode;
    this.syncTokens();
    AppStorage.setOrCreate('themeVer', (AppStorage.get<number>('themeVer') ?? 0) + 1);
    await this.save('themeMode', mode);
  }

  async setLosslessEngine(on: boolean): Promise<void> {
    this.losslessEngine = on;
    this.syncTokens();
    await this.save('losslessEngine', on ? '1' : '0');
  }

  async setPauseOnHeadphoneOff(on: boolean): Promise<void> {
    this.pauseOnHeadphoneOff = on;
    this.syncTokens();
    await this.save('pauseOnHeadphoneOff', on ? '1' : '0');
  }

  async setPauseOnBtOff(on: boolean): Promise<void> {
    this.pauseOnBtOff = on;
    this.syncTokens();
    await this.save('pauseOnBtOff', on ? '1' : '0');
  }

  async setRgMode(mode: number): Promise<void> {
    this.rgMode = mode;
    this.syncTokens();
    await this.save('rgMode', String(mode));
    PlayerBridge.notifyDspChanged();
  }

  async setEq(on: boolean, preset: string): Promise<void> {
    this.eqOn = on;
    this.eqPreset = preset;
    this.syncTokens();
    await this.save('eqOn', on ? '1' : '0');
    await this.save('eqPreset', preset);
    PlayerBridge.notifyDspChanged();
  }

  // 自定义 31 段(逐段编辑 UI / 预设 / AutoEq 导入共用的权威存储)
  async setEqBands(bands: number[]): Promise<void> {
    this.eqBands = bands;
    this.eqPreset = 'custom';
    this.syncTokens();
    await this.save('eqBands', Db.stringifyBands(bands));
    await this.save('eqPreset', 'custom');
    PlayerBridge.notifyDspChanged();
  }

  async setSkipSilence(on: boolean): Promise<void> {
    this.skipSilence = on;
    this.syncTokens();
    await this.save('skipSilence', on ? '1' : '0');
    PlayerBridge.notifyDspChanged();
  }

  async setPlaySpeed(v: number): Promise<void> {
    this.playSpeed = Math.min(3.0, Math.max(0.25, v));
    this.syncTokens();
    await this.save('playSpeed', String(this.playSpeed));
  }

  async setPlayerSkin(skin: string): Promise<void> {
    this.playerSkin = skin === 'minimal' ? 'minimal' : 'standard';
    this.syncTokens();
    await this.save('playerSkin', this.playerSkin);
  }

  async setOnlineLyrics(on: boolean): Promise<void> {
    this.onlineLyrics = on;
    this.syncTokens();
    await this.save('onlineLyrics', on ? '1' : '0');
    hilog.info(DOMAIN, TAG, 'online lyrics -> %{public}s', String(on));
  }

  async setResumeAfterInterrupt(on: boolean): Promise<void> {
    this.resumeAfterInterrupt = on;
    this.syncTokens();
    await this.save('resumeAfterInterrupt', on ? '1' : '0');
  }
}

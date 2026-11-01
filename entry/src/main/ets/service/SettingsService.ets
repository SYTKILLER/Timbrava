// 设置服务:app_settings KV + AppStorage token 同步(页面 @StorageProp 绑定)。
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Db } from '../data/Db';

const TAG = '[Timbrava][Settings]';
const DOMAIN = 0x0001;

export class ThemeMode {
  static readonly SYSTEM: string = 'system';
  static readonly LIGHT: string = 'light';
  static readonly DARK: string = 'dark';
  static readonly BLACK: string = 'black';
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
    this.losslessEngine = (await db.getSetting('losslessEngine', '1')) === '1';
    this.pauseOnHeadphoneOff = (await db.getSetting('pauseOnHeadphoneOff', '1')) === '1';
    this.pauseOnBtOff = (await db.getSetting('pauseOnBtOff', '1')) === '1';
    this.resumeAfterInterrupt = (await db.getSetting('resumeAfterInterrupt', '1')) === '1';
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

  async setResumeAfterInterrupt(on: boolean): Promise<void> {
    this.resumeAfterInterrupt = on;
    this.syncTokens();
    await this.save('resumeAfterInterrupt', on ? '1' : '0');
  }
}

// 设置页:扫描管理入口 / 引擎 / 播放行为 / 外观 / 关于。
// 开关行抽为子组件各自 @StorageProp 绑定(规避 @Builder 按值传参不刷新红线)。
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SettingsService, ThemeMode } from '../../service/SettingsService';
import { RgScanner, RgScanState } from '../../service/RgScanner';
import { BackupService } from '../../service/BackupService';
import { LibraryStore } from '../../data/LibraryStore';
import { AppTheme } from '../../common/Theme';
import { L } from '../../common/Lang';

const TAG = '[Timbrava][SettingsTab]';
const DOMAIN = 0x0001;

@Component
export struct CardSection {
  title: ResourceStr = '';
  @BuilderParam content: () => void = this.emptyContent;

  @Builder
  emptyContent() {
  }

  build() {
    Column({ space: 4 }) {
      Text(this.title)
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .padding({ left: 4, top: 4 })
      this.content()
    }
    .width('100%')
    .padding(12)
    .borderRadius(16)
    .backgroundColor($r('app.color.card_bg'))
  }
}

@Component
export struct PrefToggleRow {
  @StorageProp('prefLossless') prefLossless: boolean = true;
  @StorageProp('prefPauseHeadphone') prefPauseHeadphone: boolean = true;
  @StorageProp('prefPauseBt') prefPauseBt: boolean = true;
  @StorageProp('prefResumeInterrupt') prefResumeInterrupt: boolean = true;
  prefKey: string = 'lossless';
  title: ResourceStr = '';
  sub: ResourceStr = '';

  private current(on: boolean): boolean {
    return on;
  }

  private value(): boolean {
    if (this.prefKey === 'lossless') {
      return this.prefLossless;
    }
    if (this.prefKey === 'headphone') {
      return this.prefPauseHeadphone;
    }
    if (this.prefKey === 'bt') {
      return this.prefPauseBt;
    }
    return this.prefResumeInterrupt;
  }

  private apply(v: boolean): void {
    const s = SettingsService.get();
    if (this.prefKey === 'lossless') {
      s.setLosslessEngine(v);
    } else if (this.prefKey === 'headphone') {
      s.setPauseOnHeadphoneOff(v);
    } else if (this.prefKey === 'bt') {
      s.setPauseOnBtOff(v);
    } else {
      s.setResumeAfterInterrupt(v);
    }
    hilog.info(DOMAIN, TAG, '%{public}s -> %{public}s', this.prefKey, v ? 'on' : 'off');
  }

  build() {
    Row({ space: 12 }) {
      Column({ space: 2 }) {
        Text(this.title)
          .fontSize(15)
          .fontColor($r('app.color.text_primary'))
        Text(this.sub)
          .fontSize(11)
          .fontColor($r('app.color.text_secondary'))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: this.value() })
        .selectedColor($r('app.color.accent'))
        .onChange((v: boolean): void => {
          this.apply(v);
        })
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
  }
}

@Component
struct ThemeRow {
  @StorageProp('prefThemeMode') prefThemeMode: string = 'system';

  private themeLabel(mode: string): ResourceStr {
    if (mode === ThemeMode.LIGHT) {
      return $r('app.string.theme_light');
    }
    if (mode === ThemeMode.DARK) {
      return $r('app.string.theme_dark');
    }
    return $r('app.string.follow_system');
  }

  build() {
    Column({ space: 8 }) {
      Row({ space: 10 }) {
        SymbolGlyph($r('sys.symbol.moon'))
          .fontSize(18)
          .fontColor([$r('app.color.accent')])
        Text($r('app.string.theme'))
          .fontSize(15)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
      }
      .width('100%')
      Row({ space: 8 }) {
        ForEach(THEME_OPTIONS, (opt: ThemeOption) => {
          Button(this.themeLabel(opt.mode))
            .fontSize(13)
            .fontColor(this.prefThemeMode === opt.mode ? $r('app.color.on_accent') : $r('app.color.text_primary'))
            .backgroundColor(this.prefThemeMode === opt.mode ? $r('app.color.accent') : $r('app.color.badge_bg'))
            .borderRadius(10)
            .height(34)
            .layoutWeight(1)
            .onClick(() => {
              SettingsService.get().setThemeMode(opt.mode).then((): void => {
                const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
                AppTheme.apply(ctx);
              });
            })
        }, (opt: ThemeOption): string => opt.mode)
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 10, bottom: 10 })
  }
}

// 设置页主体(降级为"我的"页二级路由页,由 SettingsDest 包 NavDestination)
@Component
export struct SettingsTab {
  @StorageProp('themePageBg') themePageBg: string = '';

  private pageBg(): ResourceColor {
    return this.themePageBg.length > 0 ? this.themePageBg : $r('app.color.page_bg');
  }

  private nav(): NavPathStack {
    const stack = AppStorage.get<NavPathStack>('navStack');
    return stack !== undefined && stack !== null ? stack : new NavPathStack();
  }

  build() {
    Column() {
      Scroll() {
        Column({ space: 12 }) {
          // 媒体库
          CardSection({ title: $r('app.string.media_library') }) {
            Column() {
              this.NavItem($r('app.string.scan_manager'), $r('app.string.scan_manager_sub'), (): void => {
                this.nav().pushPathByName('ScanSettings', null);
              })
              Divider().color($r('app.color.divider')).margin({ left: 0 })
              this.NavItem($r('app.string.duplicates_title'), $r('app.string.duplicates_sub'), (): void => {
                this.nav().pushPathByName('Duplicates', null);
              })
            }
          }

          // 播放行为
          CardSection({ title: $r('app.string.playback_behavior') }) {
            Column() {
              PrefToggleRow({ prefKey: 'headphone', title: $r('app.string.pause_hp'), sub: $r('app.string.pause_hp_sub') })
              Divider().color($r('app.color.divider')).margin({ left: 0 })
              PrefToggleRow({ prefKey: 'bt', title: $r('app.string.pause_bt'), sub: $r('app.string.pause_bt_sub') })
              Divider().color($r('app.color.divider')).margin({ left: 0 })
              PrefToggleRow({ prefKey: 'resume', title: $r('app.string.auto_resume'), sub: $r('app.string.auto_resume_sub') })
              Divider().color($r('app.color.divider')).margin({ left: 0 })
              OnlineLyricsRow()
            }
          }

          // 外观
          CardSection({ title: $r('app.string.appearance') }) {
            Column() {
              ThemeRow()
              Divider().color($r('app.color.divider')).margin({ left: 0 })
              PlayerSkinRow()
            }
          }

          // 备份与恢复
          CardSection({ title: $r('app.string.backup_restore') }) {
            Column() {
              this.NavItem($r('app.string.export_backup'), $r('app.string.backup_desc'), (): void => {
                BackupService.exportAll().then((ok: boolean): void => {
                  this.getUIContext().getPromptAction().showToast({ message: ok ? $r('app.string.str_exported') : $r('app.string.export_cancelled') });
                });
              })
              Divider().color($r('app.color.divider')).margin({ left: 0 })
              this.NavItem($r('app.string.restore_backup'), $r('app.string.restore_desc'), (): void => {
                BackupService.importAll().then((ok: boolean): void => {
                  this.getUIContext().getPromptAction().showToast({ message: ok ? $r('app.string.str_restored') : $r('app.string.import_cancelled') });
                });
              })
            }
          }

          // 关于
          CardSection({ title: $r('app.string.str_about') }) {
            Column() {
              this.NavItem($r('app.string.about_entry'), $r('app.string.about_entry_sub'), (): void => {
                this.nav().pushPathByName('About', null);
              })
            }
          }

          Blank().height(120)
        }
        .width('100%')
        .padding({ left: 16, right: 16 })
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.pageBg())
  }

  @Builder
  NavItem(title: ResourceStr, sub: ResourceStr, onTap: () => void) {
    Row({ space: 12 }) {
      Column({ space: 2 }) {
        Text(title)
          .fontSize(15)
          .fontColor($r('app.color.text_primary'))
        Text(sub)
          .fontSize(11)
          .fontColor($r('app.color.text_secondary'))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(14)
        .fontColor([$r('app.color.text_secondary')])
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
    .onClick(() => {
      onTap();
    })
  }

  @Builder
  InfoItem(title: ResourceStr, sub: ResourceStr) {
    Row({ space: 12 }) {
      Column({ space: 2 }) {
        Text(title)
          .fontSize(15)
          .fontColor($r('app.color.text_primary'))
        Text(sub)
          .fontSize(11)
          .fontColor($r('app.color.text_secondary'))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
  }
}

class ThemeOption {
  mode: string;

  constructor(mode: string) {
    this.mode = mode;
  }
}

const THEME_OPTIONS: ThemeOption[] = [
  new ThemeOption('system'),
  new ThemeOption('light'),
  new ThemeOption('dark')
];

// 播放页皮肤(#53):标准(大封面)/极简
@Component
struct PlayerSkinRow {
  @StorageProp('prefPlayerSkin') prefPlayerSkin: string = 'standard';

  build() {
    Column({ space: 8 }) {
      Row({ space: 10 }) {
        SymbolGlyph($r('sys.symbol.paintpalette'))
          .fontSize(18)
          .fontColor([$r('app.color.accent')])
        Text($r('app.string.player_skin'))
          .fontSize(15)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
      }
      .width('100%')
      Row({ space: 8 }) {
        Button($r('app.string.skin_standard'))
          .fontSize(13)
          .fontColor(this.prefPlayerSkin === 'standard' ? $r('app.color.on_accent') : $r('app.color.text_primary'))
          .backgroundColor(this.prefPlayerSkin === 'standard' ? $r('app.color.accent') : $r('app.color.badge_bg'))
          .borderRadius(10)
          .height(34)
          .layoutWeight(1)
          .onClick(() => {
            SettingsService.get().setPlayerSkin('standard');
          })
        Button($r('app.string.skin_minimal'))
          .fontSize(13)
          .fontColor(this.prefPlayerSkin === 'minimal' ? $r('app.color.on_accent') : $r('app.color.text_primary'))
          .backgroundColor(this.prefPlayerSkin === 'minimal' ? $r('app.color.accent') : $r('app.color.badge_bg'))
          .borderRadius(10)
          .height(34)
          .layoutWeight(1)
          .onClick(() => {
            SettingsService.get().setPlayerSkin('minimal');
          })
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 10, bottom: 10 })
  }
}

// LRCLIB 联网歌词开关(默认关,零联网定位下显式开启)
@Component
struct OnlineLyricsRow {
  @StorageProp('prefOnlineLyrics') prefOnlineLyrics: boolean = false;

  build() {
    Row({ space: 12 }) {
      Column({ space: 2 }) {
        Text($r('app.string.lrclib_pref'))
          .fontSize(15)
          .fontColor($r('app.color.text_primary'))
        Text($r('app.string.lrclib_sub'))
          .fontSize(11)
          .fontColor($r('app.color.text_secondary'))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: this.prefOnlineLyrics })
        .selectedColor($r('app.color.accent'))
        .onChange((v: boolean): void => {
          SettingsService.get().setOnlineLyrics(v);
        })
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
  }
}

// ReplayGain 应用模式行(0 关 / 1 按曲目 / 2 按专辑)
@Component
export struct RgModeRow {
  @StorageProp('prefRgMode') prefRgMode: number = 0;

  private label(m: number): ResourceStr {
    if (m === 1) {
      return $r('app.string.by_track');
    }
    if (m === 2) {
      return $r('app.string.by_album');
    }
    return $r('app.string.str_off');
  }

  build() {
    Column({ space: 8 }) {
      Row({ space: 10 }) {
        SymbolGlyph($r('sys.symbol.waveform'))
          .fontSize(18)
          .fontColor([$r('app.color.accent')])
        Text('ReplayGain')
          .fontSize(15)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
      }
      .width('100%')
      Text($r('app.string.rg_hint'))
        .fontSize(11)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
      Row({ space: 8 }) {
        ForEach([0, 1, 2], (m: number) => {
          Button(this.label(m))
            .fontSize(13)
            .fontColor(this.prefRgMode === m ? $r('app.color.on_accent') : $r('app.color.text_primary'))
            .backgroundColor(this.prefRgMode === m ? $r('app.color.accent') : $r('app.color.badge_bg'))
            .borderRadius(10)
            .height(34)
            .layoutWeight(1)
            .onClick(() => {
              SettingsService.get().setRgMode(m);
            })
        }, (m: number): string => `rg_${m}`)
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 10, bottom: 10 })
  }
}

// 响度分析扫描区:全库扫描按钮 + 进度
@Component
export struct RgScanSection {
  @StorageProp('rgScanVer') rgScanVer: number = 0;

  private st(): RgScanState {
    return RgScanner.get().state;
  }

  build() {
    Column({ space: 8 }) {
      Row({ space: 10 }) {
        SymbolGlyph($r('sys.symbol.waveform'))
          .fontSize(18)
          .fontColor([$r('app.color.accent')])
        Column({ space: 2 }) {
          Text($r('app.string.rg_scan'))
            .fontSize(15)
            .fontColor($r('app.color.text_primary'))
          Text($r('app.string.rg_scan_sub'))
            .fontSize(11)
            .fontColor($r('app.color.text_secondary'))
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')

      if (this.rgScanVer < 0) {
        Text('')
      } else if (this.st().running) {
        Text(L($r('app.string.rg_scanning'), this.st().current, this.st().total, this.st().albumLabel.length > 0 ? ' · ' + this.st().albumLabel : ''))
          .fontSize(12)
          .fontColor($r('app.color.accent'))
          .width('100%')
        Button($r('app.string.cancel_scan'))
          .fontSize(12)
          .height(32)
          .fontColor($r('app.color.text_primary'))
          .backgroundColor($r('app.color.badge_bg'))
          .onClick(() => {
            RgScanner.get().cancel();
          })
      } else {
        if (this.st().done) {
          Text(this.st().failCount > 0 ? L($r('app.string.rg_done_fail'), this.st().failCount) : L($r('app.string.rg_done_ok')))
            .fontSize(11)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
        }
        Button($r('app.string.scan_library'))
          .fontSize(13)
          .height(36)
          .fontColor($r('app.color.on_accent'))
          .backgroundColor($r('app.color.accent'))
          .onClick(() => {
            RgScanner.get().scan(LibraryStore.get().songs);
          })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 10, bottom: 10 })
  }
}

// 设置二级路由壳:NavDestination 默认标题栏 + 状态栏避让(与 QueueBoard 同模式)
@Component
export struct SettingsDest {
  @StorageProp('topSafeVp') topSafeVp: number = 36;
  private pathStack: NavPathStack | null = null;

  build() {
    NavDestination() {
      SettingsTab()
    }
    .padding({ top: this.topSafeVp })
    .title($r('app.string.str_settings'))
    .onReady((ctx: NavDestinationContext): void => {
      this.pathStack = ctx.pathStack;
    })
  }
}

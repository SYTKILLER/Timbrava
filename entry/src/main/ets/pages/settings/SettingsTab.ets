// 设置页:扫描管理入口 / 引擎 / 播放行为 / 外观 / 关于。
// 开关行抽为子组件各自 @StorageProp 绑定(规避 @Builder 按值传参不刷新红线)。
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SettingsService, ThemeMode } from '../../service/SettingsService';
import { RgScanner, RgScanState } from '../../service/RgScanner';
import { LibraryStore } from '../../data/LibraryStore';
import { AppTheme, SafeAreaResult } from '../../common/Theme';

const TAG = '[Timbrava][SettingsTab]';
const DOMAIN = 0x0001;

@Component
struct CardSection {
  title: string = '';
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
struct PrefToggleRow {
  @StorageProp('prefLossless') prefLossless: boolean = true;
  @StorageProp('prefPauseHeadphone') prefPauseHeadphone: boolean = true;
  @StorageProp('prefPauseBt') prefPauseBt: boolean = true;
  @StorageProp('prefResumeInterrupt') prefResumeInterrupt: boolean = true;
  prefKey: string = 'lossless';
  title: string = '';
  sub: string = '';

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

  private themeLabel(mode: string): string {
    if (mode === ThemeMode.LIGHT) {
      return '浅色';
    }
    if (mode === ThemeMode.DARK) {
      return '深色';
    }
    if (mode === ThemeMode.BLACK) {
      return '纯黑';
    }
    return '跟随系统';
  }

  build() {
    Column({ space: 8 }) {
      Row({ space: 10 }) {
        SymbolGlyph($r('sys.symbol.moon'))
          .fontSize(18)
          .fontColor([$r('app.color.accent')])
        Text('主题')
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

@Component
export struct SettingsTab {
  @StorageProp('themePageBg') themePageBg: string = '';
  @State topSafe: number = 36;

  aboutToAppear(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    AppTheme.safeAreas(ctx).then((r: SafeAreaResult): void => {
      this.topSafe = r.topVp;
    });
  }

  private pageBg(): ResourceColor {
    return this.themePageBg.length > 0 ? this.themePageBg : $r('app.color.page_bg');
  }

  private nav(): NavPathStack {
    const stack = AppStorage.get<NavPathStack>('navStack');
    return stack !== undefined && stack !== null ? stack : new NavPathStack();
  }

  build() {
    Column() {
      Text('设置')
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
        .padding({ left: 16, right: 16, top: this.topSafe + 8, bottom: 8 })

      Scroll() {
        Column({ space: 12 }) {
          // 媒体库
          CardSection({ title: '媒体库' }) {
            Column() {
              this.NavItem('扫描文件夹管理', '选择音乐目录、开始扫描', (): void => {
                this.nav().pushPathByName('ScanSettings', null);
              })
              Divider().color($r('app.color.divider')).margin({ left: 0 })
              this.NavItem('重复清理', '检测同曲多份记录并从库移除', (): void => {
                this.nav().pushPathByName('Duplicates', null);
              })
            }
          }

          // 引擎
          CardSection({ title: '音频引擎' }) {
            Column() {
              PrefToggleRow({
                prefKey: 'lossless',
                title: '无损引擎(FLAC/WAV 直通)',
                sub: '按源采样率/位深建流;关闭后全部走系统引擎'
              })
              Divider().color($r('app.color.divider')).margin({ left: 0 })
              this.NavItem('均衡器(31 段 PEQ)', '预设 / 自定义曲线 / AutoEq 导入', (): void => {
                this.nav().pushPathByName('Equalizer', null);
              })
              Divider().color($r('app.color.divider')).margin({ left: 0 })
              RgModeRow()
              Divider().color($r('app.color.divider')).margin({ left: 0 })
              this.InfoItem('系统引擎兜底', 'MP3/OGG/M4A/APE 等由 AVPlayer 播放;无损引擎出错自动回退')
            }
          }

          // 响度分析(ReplayGain 扫描)
          CardSection({ title: '响度分析' }) {
            Column() {
              RgScanSection()
            }
          }

          // 播放行为
          CardSection({ title: '播放行为' }) {
            Column() {
              PrefToggleRow({ prefKey: 'headphone', title: '拔出耳机暂停', sub: '有线/USB 耳机断开时自动暂停' })
              Divider().color($r('app.color.divider')).margin({ left: 0 })
              PrefToggleRow({ prefKey: 'bt', title: '蓝牙断开暂停', sub: '蓝牙音频设备断开时自动暂停' })
              Divider().color($r('app.color.divider')).margin({ left: 0 })
              PrefToggleRow({ prefKey: 'resume', title: '打断后自动恢复', sub: '通话/导航结束后恢复播放' })
              Divider().color($r('app.color.divider')).margin({ left: 0 })
              OnlineLyricsRow()
            }
          }

          // 外观
          CardSection({ title: '外观' }) {
            Column() {
              ThemeRow()
            }
          }

          // 关于
          CardSection({ title: '关于' }) {
            Column() {
              this.NavItem('关于听韵 Timbrava', '版本、开源信息与隐私承诺', (): void => {
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
  NavItem(title: string, sub: string, onTap: () => void) {
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
  InfoItem(title: string, sub: string) {
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
  new ThemeOption('dark'),
  new ThemeOption('black')
];

// LRCLIB 联网歌词开关(默认关,零联网定位下显式开启)
@Component
struct OnlineLyricsRow {
  @StorageProp('prefOnlineLyrics') prefOnlineLyrics: boolean = false;

  build() {
    Row({ space: 12 }) {
      Column({ space: 2 }) {
        Text('LRCLIB 联网歌词')
          .fontSize(15)
          .fontColor($r('app.color.text_primary'))
        Text('默认关闭。开启后无内嵌歌词时联网查询 lrclib.net')
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
struct RgModeRow {
  @StorageProp('prefRgMode') prefRgMode: number = 0;

  private label(m: number): string {
    if (m === 1) {
      return '按曲目';
    }
    if (m === 2) {
      return '按专辑';
    }
    return '关闭';
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
      Text('先在「响度分析」里扫描曲库,再选择应用模式')
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
struct RgScanSection {
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
          Text('ReplayGain 扫描')
            .fontSize(15)
            .fontColor($r('app.color.text_primary'))
          Text('全曲解码测响度(仅 FLAC/WAV),耗时与曲库大小成正比')
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
        Text(`扫描中 ${this.st().current}/${this.st().total}${this.st().albumLabel.length > 0 ? ' · ' + this.st().albumLabel : ''}`)
          .fontSize(12)
          .fontColor($r('app.color.accent'))
          .width('100%')
        Button('取消扫描')
          .fontSize(12)
          .height(32)
          .fontColor($r('app.color.text_primary'))
          .backgroundColor($r('app.color.badge_bg'))
          .onClick(() => {
            RgScanner.get().cancel();
          })
      } else {
        if (this.st().done) {
          Text(`上次扫描完成${this.st().failCount > 0 ? ',失败 ' + this.st().failCount + ' 首' : ''}`)
            .fontSize(11)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
        }
        Button('扫描全库')
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

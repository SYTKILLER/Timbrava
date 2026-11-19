// 驾驶模式(0.22.0 车机适配预备,QQ 音乐驾驶模式/车机音乐应用大钮惯例):
// 横屏大封面 + 超大 上一首/播放/下一首 播控,支架/超级桌面车机屏/悬停态防误触场景通用。
// 锁横屏进入(EQ 页同款 setPreferredOrientation 模式),离页还原 UNSPECIFIED。
// 纯展示+播控,无列表交互——车机屏(超级桌面把本应用投上车机横屏)与手机支架场景共用。
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { window, display } from '@kit.ArkUI';
import { PlayerController } from '../../service/PlayerController';
import { formatDuration } from '../../data/Model';
import { AppTheme } from '../../common/Theme';

const TAG = '[Timbrava][DrivingMode]';
const DOMAIN = 0x0001;

@Component
export struct DrivingModeDest {
  @StorageProp('playerVer') @Watch('onPlayerChanged') playerVer: number = 0;
  @StorageProp('posVer') @Watch('onPosChanged') posVer: number = 0;
  // 横竖屏自适应(0.24.0 重排):winWVp/winHVp 由断点服务随 windowSizeChange/avoidAreaChange 刷新,
  // 旋转(含锁横屏成败两种结果)都会触发重算——旧实现写死横屏布局,竖屏锁定设备上大量元素重叠
  @StorageProp('winWVp') @Watch('onWinChanged') winWVp: number = 0;
  @StorageProp('winHVp') @Watch('onWinChanged') winHVp: number = 0;
  @State isLandscape: boolean = false;
  @State posMs: number = 0;
  @State songTitle: string = '';
  @State songSub: string = '';
  @State songArt: string = '';
  @State playingMirror: boolean = false;
  @State hasSong: boolean = false;
  @State topSafe: number = 36;
  @State bottomSafe: number = 28;
  @State pageBg: string = '';
  private pathStack: NavPathStack | null = null;
  private winRef: window.Window | null = null;

  aboutToAppear(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    AppTheme.safeAreas(ctx).then((r): void => {
      this.topSafe = r.topVp;
      this.bottomSafe = Math.max(r.bottomVp, 28);
    });
    this.syncOrientation();
    this.onPlayerChanged();
    this.onPosChanged();
  }

  onWinChanged(): void {
    this.syncOrientation();
    // 旋转后避让区随边换侧,重读一次(aboutToAppear 读的是旋转前旧值)
    AppTheme.safeAreas(this.getUIContext().getHostContext() as common.UIAbilityContext)
      .then((r): void => {
        this.topSafe = r.topVp;
        this.bottomSafe = Math.max(r.bottomVp, 28);
      });
  }

  private syncOrientation(): void {
    const land = this.winWVp > this.winHVp;
    if (land !== this.isLandscape) {
      this.isLandscape = land;
      hilog.info(DOMAIN, TAG, 'driving layout %{public}s w=%{public}d h=%{public}d',
        land ? 'landscape' : 'portrait', this.winWVp, this.winHVp);
    }
  }

  // 锁横屏:车机屏/支架均为横置,竖屏下同样强制横置保证按钮可达(EQ 页同款模式)
  onReady(ctx: NavDestinationContext): void {
    this.pathStack = ctx.pathStack;
    try {
      window.getLastWindow(this.getUIContext().getHostContext() as common.UIAbilityContext)
        .then((win: window.Window): void => {
          this.winRef = win;
          win.setPreferredOrientation(window.Orientation.LANDSCAPE).catch((): void => {
          });
        });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'lock landscape fail %{public}s', (e as Error).message);
    }
  }

  aboutToDisappear(): void {
    // 离页还原跟随系统(不锁定竖屏,尊重系统自动旋转设置;EQ 页同款)
    if (this.winRef !== null) {
      this.winRef.setPreferredOrientation(window.Orientation.UNSPECIFIED).catch((): void => {
      });
      this.winRef = null;
    }
  }

  onPlayerChanged(): void {
    const s = PlayerController.get().currentSong;
    this.hasSong = s !== null;
    this.songTitle = s !== null ? s.displayTitle() : '';
    this.songSub = s !== null ? s.displayArtist() : '';
    this.songArt = s !== null ? s.artPath : '';
    this.playingMirror = PlayerController.get().isPlaying;
  }

  onPosChanged(): void {
    this.posMs = Math.round(PlayerController.get().positionMs);
  }

  private pageBgColor(): ResourceColor {
    const override = AppStorage.get<string>('themePageBg') ?? '';
    return override.length > 0 ? override : $r('app.color.player_bg');
  }

  // ===== 0.24.0 响应式重排:横竖屏双形态,纯 flex 布局(元素不可能重叠) =====

  @Builder
  DrivingCover(sideVp: number) {
    if (this.songArt.length > 0) {
      Image(this.songArt)
        .width(sideVp)
        .height(sideVp)
        .borderRadius(24)
        .objectFit(ImageFit.Cover)
        .shadow({ radius: 40, color: '#33000000', offsetX: 0, offsetY: 10 })
    } else {
      Column() {
        SymbolGlyph($r('sys.symbol.music_note_list'))
          .fontSize(56)
          .fontColor([$r('app.color.accent')])
      }
      .width(sideVp)
      .height(sideVp)
      .borderRadius(24)
      .backgroundColor($r('app.color.badge_bg')
      )
      .justifyContent(FlexAlign.Center)
    }
  }

  @Builder
  DrivingMeta() {
    Text(this.songTitle)
      .fontSize(24)
      .fontWeight(FontWeight.Bold)
      .fontColor($r('app.color.text_primary'))
      .maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .width('100%')
    Text(this.songSub)
      .fontSize(15)
      .fontColor($r('app.color.text_secondary'))
      .maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .width('100%')
  }

  @Builder
  DrivingProgress() {
    Slider({
      value: this.posMs,
      min: 0,
      max: Math.max(1, PlayerController.get().durationMs),
      step: 1,
      style: SliderStyle.OutSet
    })
      .selectedColor($r('app.color.accent'))
      .trackColor($r('app.color.divider'))
      .blockColor($r('app.color.accent'))
      .width('100%')
      .height(36)
      .onChange((value: number, mode: SliderChangeMode): void => {
        if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
          PlayerController.get().seekTo(Math.round(value));
        }
      })
    Row() {
      Text(formatDuration(this.posMs))
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
      Blank()
      Text(formatDuration(PlayerController.get().durationMs))
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
    }
    .width('100%')
  }

  // 超大播控(尺寸按形态缩放;竖屏收窄防 360vp 宽溢出)
  @Builder
  DrivingControls(prevVp: number, playVp: number, iconScale: number) {
    Row({ space: prevVp * 0.3 }) {
      Button({ stateEffect: true }) {
        SymbolGlyph($r('sys.symbol.backward_end_fill'))
          .fontSize(44 * iconScale)
          .fontColor([$r('app.color.control_fg')])
      }
      .width(prevVp)
      .height(prevVp)
      .backgroundColor(Color.Transparent)
      .onClick(() => {
        PlayerController.get().playPrev();
      })

      Button({ stateEffect: false }) {
        SymbolGlyph(this.playingMirror ? $r('sys.symbol.pause_fill') : $r('sys.symbol.play_fill'))
          .fontSize(56 * iconScale)
          .fontColor([$r('app.color.on_accent')])
      }
      .width(playVp)
      .height(playVp)
      .borderRadius(playVp / 2)
      .backgroundColor($r('app.color.accent'))
      .onClick(() => {
        PlayerController.get().playPause();
      })

      Button({ stateEffect: true }) {
        SymbolGlyph($r('sys.symbol.forward_end_fill'))
          .fontSize(44 * iconScale)
          .fontColor([$r('app.color.control_fg')])
      }
      .width(prevVp)
      .height(prevVp)
      .backgroundColor(Color.Transparent)
      .onClick(() => {
        PlayerController.get().playNext();
      })
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  DrivingBody() {
    if (this.hasSong) {
      if (this.isLandscape) {
        // 横屏(车机/支架):左大封面 + 右信息/播控
        Row({ space: 28 }) {
          Column() {
            this.DrivingCover(Math.min(this.winHVp * 0.62, 320))
          }
          .width('34%')
          .height('100%')
          .justifyContent(FlexAlign.Center)

          Column({ space: 12 }) {
            this.DrivingMeta()
            this.DrivingProgress()
            this.DrivingControls(88, 116, 1)
          }
          .layoutWeight(1)
          .height('100%')
          .justifyContent(FlexAlign.Center)
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: 24, right: 24, top: 8, bottom: Math.max(this.bottomSafe, 28) + 8 })
      } else {
        // 竖屏(旋转锁定未生效等场景):纵向排布,播控收窄防溢出
        Column({ space: 12 }) {
          Column() {
            this.DrivingCover(Math.min(this.winWVp * 0.42, 240))
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)

          Column({ space: 10 }) {
            this.DrivingMeta()
            this.DrivingProgress()
            this.DrivingControls(72, 96, 0.85)
          }
          .width('100%')
          .padding({ bottom: Math.max(this.bottomSafe, 28) + 8 })
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: 24, right: 24, top: 8 })
      }
    } else {
      Column({ space: 10 }) {
        SymbolGlyph($r('sys.symbol.music_note_list'))
          .fontSize(48)
          .fontColor([$r('app.color.text_secondary')])
        Text($r('app.string.no_playing_song'))
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
      }
      .width('100%')
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
    }
  }

  build() {
    NavDestination() {
      Column() {
        // 顶栏:退出(左) | 驾驶模式 | 占位
        Row() {
          Button({ stateEffect: true }) {
            SymbolGlyph($r('sys.symbol.chevron_down'))
              .fontSize(26)
              .fontColor([$r('app.color.text_primary')])
          }
          .width(56)
          .height(56)
          .backgroundColor(Color.Transparent)
          .onClick(() => {
            if (this.pathStack !== null) {
              this.pathStack.pop();
            }
          })
          Text($r('app.string.driving_mode'))
            .fontSize(16)
            .fontColor($r('app.color.text_secondary'))
            .layoutWeight(1)
            .textAlign(TextAlign.Center)
          Blank().width(56)
        }
        .width('100%')
        .padding({ left: 8, right: 8, top: this.topSafe })

        this.DrivingBody()
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.pageBgColor())
    }
    .hideTitleBar(true)
    .backgroundColor(Color.Transparent)
    .onReady((ctx: NavDestinationContext): void => {
      this.onReady(ctx);
    })
    .onBackPressed((): boolean => {
      if (this.pathStack !== null) {
        this.pathStack.pop();
      }
      return true;
    })
  }
}

@Builder
export function DrivingModeBuilder() {
  DrivingModeDest()
}

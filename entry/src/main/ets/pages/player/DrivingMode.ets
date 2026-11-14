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
    this.onPlayerChanged();
    this.onPosChanged();
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

        if (this.hasSong) {
          Row({ space: 32 }) {
            // 大封面
            Column() {
              if (this.songArt.length > 0) {
                Image(this.songArt)
                  .height('82%')
                  .aspectRatio(1)
                  .borderRadius(24)
                  .objectFit(ImageFit.Cover)
                  .shadow({ radius: 40, color: '#33000000', offsetX: 0, offsetY: 10 })
              } else {
                Column() {
                  SymbolGlyph($r('sys.symbol.music_note_list'))
                    .fontSize(72)
                    .fontColor([$r('app.color.accent')])
                }
                .height('82%')
                .aspectRatio(1)
                .borderRadius(24)
                .backgroundColor($r('app.color.badge_bg'))
                .justifyContent(FlexAlign.Center)
              }
            }
            .width('32%')
            .height('100%')
            .justifyContent(FlexAlign.Center)

            // 曲目信息 + 超大播控
            Column({ space: 10 }) {
              Text(this.songTitle)
                .fontSize(26)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.text_primary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
              Text(this.songSub)
                .fontSize(16)
                .fontColor($r('app.color.text_secondary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')

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

              // 超大播控:上一曲 88 / 播放 120 / 下一曲 88(车机大钮规范,防误触)
              Row({ space: 28 }) {
                Button({ stateEffect: true }) {
                  SymbolGlyph($r('sys.symbol.backward_end_fill'))
                    .fontSize(44)
                    .fontColor([$r('app.color.control_fg')])
                }
                .width(88)
                .height(88)
                .backgroundColor(Color.Transparent)
                .onClick(() => {
                  PlayerController.get().playPrev();
                })

                Button({ stateEffect: false }) {
                  SymbolGlyph(this.playingMirror ? $r('sys.symbol.pause_fill') : $r('sys.symbol.play_fill'))
                    .fontSize(56)
                    .fontColor([$r('app.color.on_accent')])
                }
                .width(120)
                .height(120)
                .borderRadius(60)
                .backgroundColor($r('app.color.accent'))
                .onClick(() => {
                  PlayerController.get().playPause();
                })

                Button({ stateEffect: true }) {
                  SymbolGlyph($r('sys.symbol.forward_end_fill'))
                    .fontSize(44)
                    .fontColor([$r('app.color.control_fg')])
                }
                .width(88)
                .height(88)
                .backgroundColor(Color.Transparent)
                .onClick(() => {
                  PlayerController.get().playNext();
                })
              }
              .width('100%')
              .justifyContent(FlexAlign.Center)
            }
            .layoutWeight(1)
            .height('100%')
            .justifyContent(FlexAlign.Center)
          }
          .width('100%')
          .layoutWeight(1)
          .padding({ left: 24, right: 24, bottom: Math.max(this.bottomSafe, 28) + 8 })
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

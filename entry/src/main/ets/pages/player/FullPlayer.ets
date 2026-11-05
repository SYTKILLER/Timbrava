// 全屏播放页(对齐华为音乐/QQ音乐共识交互):
// - 封面⇄歌词左右 Swiper 切换(官方《多设备音乐界面》最佳实践:窄屏 Swiper 分页);
// - 控制区:左播放模式键(顺序→列表循环→单曲→随机,symbol 显示当前模式)+ 上一曲/播放暂停(缩放动画)/下一曲 + 右队列键;
// - 右上角"更多"入口 → bindSheet 菜单(收藏/编辑歌词/倍速/A-B/跳过静音/睡眠定时/查看队列);
// - 底部 ≥28vp 导航条避让。
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import { AppTheme, SafeAreaResult } from '../../common/Theme';
import { PlayerController } from '../../service/PlayerController';
import { QueueService, PlayMode } from '../../service/QueueService';
import { EngineKind } from '../../service/engine/EngineTypes';
import { LibraryStore } from '../../data/LibraryStore';
import { Song, RepeatMode, formatDuration } from '../../data/Model';
import { LyricsPanel } from '../../components/LyricsPanel';
import { CoverSuperRes } from '../../service/CoverSuperRes';
import { DesktopLyricsService } from '../../service/DesktopLyricsService';
import { L } from '../../common/Lang';

const TAG = '[Timbrava][FullPlayer]';
const DOMAIN = 0x0001;

@Component
export struct FullPlayerDest {
  @StorageProp('playerVer') @Watch('onPlayerChanged') playerVer: number = 0;
  @StorageProp('posVer') @Watch('onPosChanged') posVer: number = 0;
  @State posMs: number = 0;
  @StorageProp('queueVer') @Watch('onQueueChanged') queueVer: number = 0;
  @State modeMirror: PlayMode = 'order'; // 模式键图标镜像(经 @State 切换驱动刷新)
  @StorageProp('libVer') libVer: number = 0;
  @StorageProp('themePageBg') themePageBg: string = '';
  @StorageProp('prefPlayerSkin') playerSkin: string = 'standard';
  @State seeking: boolean = false;
  @State seekPreviewMs: number = 0;
  @State showQueue: boolean = false;
  @State showMoreSheet: boolean = false;
  @State pageIdx: number = 0; // Swiper 当前页:0 封面 / 1 歌词
  @State playingMirror: boolean = false; // 播放键动画镜像(经 @State 切换才触发过渡)
  @State playBounce: boolean = false; // 点击缩放弹跳
  @State topSafe: number = 36;
  @State bottomSafe: number = 28;
  @State srPm: image.PixelMap | null = null; // 26-5 超分封面(小封面实时超分,失败/不支持=null 原图)
  private srFor: string = '';
  private pathStack: NavPathStack | null = null;
  private swiperCtrl: SwiperController = new SwiperController();

  aboutToAppear(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    AppTheme.safeAreas(ctx).then((r: SafeAreaResult): void => {
      this.topSafe = r.topVp;
      this.bottomSafe = Math.max(r.bottomVp, 28);
    });
    this.posMs = Math.round(PlayerController.get().positionMs);
    this.playingMirror = PlayerController.get().isPlaying;
    this.modeMirror = QueueService.get().playMode();
    // 页面可能晚于播放打开:@Watch 不会补发,主动拉一次(歌词由控制器中心化加载)
    this.onPlayerChanged();
  }

  onPlayerChanged(): void {
    this.playingMirror = PlayerController.get().isPlaying;
    this.modeMirror = QueueService.get().playMode();
    this.loadCoverSr();
  }

  // 26-5:当前曲封面短边 <500px 时实时超分(26 设备),完成后回到本曲才上屏
  private loadCoverSr(): void {
    const s = this.song();
    if (s === null || s.artPath.length === 0) {
      this.srPm = null;
      this.srFor = '';
      return;
    }
    if (!CoverSuperRes.get().available()) {
      hilog.info(DOMAIN, TAG, 'sr unavailable(api/syscap)');
      return;
    }
    const key = String(s.id);
    if (this.srFor === key) {
      return;
    }
    this.srFor = key;
    CoverSuperRes.get().superRes(key, s.artPath).then((pm: image.PixelMap | null): void => {
      if (this.srFor === key) {
        this.srPm = pm;
      }
    });
  }

  onQueueChanged(): void {
    this.modeMirror = QueueService.get().playMode();
  }

  onPosChanged(): void {
    // KB 三规则:posVer 必须经 @Watch 落到 @State 才驱动进度文本/滑条(KB 红线:声明不读=零依赖)
    this.posMs = Math.round(PlayerController.get().positionMs);
  }

  private song(): Song | null {
    return PlayerController.get().currentSong;
  }

  private pageBg(): ResourceColor {
    return this.themePageBg.length > 0 ? this.themePageBg : $r('app.color.player_bg');
  }

  private queueItems(): Song[] {
    const q = QueueService.get();
    const arr: Song[] = [];
    for (let i = 0; i < q.list.length; i++) {
      const s = LibraryStore.get().song(q.list[i]);
      if (s !== null) {
        arr.push(s);
      }
    }
    return arr;
  }

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        // 顶栏:返回 | 正在播放 | 更多(右上角,bindSheet)
        Row() {
          Button({ stateEffect: true }) {
            SymbolGlyph($r('sys.symbol.chevron_left'))
              .fontSize(24)
              .fontColor([$r('app.color.text_primary')])
          }
          .width(40)
          .height(40)
          .backgroundColor(Color.Transparent)
          .onClick(() => {
            if (this.pathStack !== null) {
              this.pathStack.pop();
            }
          })
          Text($r('app.string.now_playing'))
            .fontSize(15)
            .fontColor($r('app.color.text_secondary'))
            .layoutWeight(1)
            .textAlign(TextAlign.Center)
          Button({ stateEffect: true }) {
            SymbolGlyph($r('sys.symbol.more'))
              .fontSize(20)
              .fontColor([$r('app.color.text_primary')])
          }
          .width(40)
          .height(40)
          .backgroundColor(Color.Transparent)
          .onClick(() => {
            this.showMoreSheet = true;
          })
        }
        .width('100%')
        .padding({ left: 8, right: 8, top: this.topSafe })

        if (this.song() !== null) {
          this.PlayerBody()
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
      .backgroundColor(this.pageBg())

      if (this.showQueue) {
        this.QueueDrawer()
      }
      }
      .width('100%')
      .height('100%')
      .bindSheet(this.showMoreSheet, this.MoreSheet(), {
        height: 440,
        showClose: true,
        dragBar: true,
        onDisappear: (): void => {
          this.showMoreSheet = false;
        }
      })
    }
    .hideTitleBar(true)
    .onReady((ctx: NavDestinationContext): void => {
      this.pathStack = ctx.pathStack;
    })
    .onBackPressed((): boolean => {
      if (this.showQueue) {
        this.showQueue = false;
        return true;
      }
      return false;
    })
  }

  @Builder
  PlayerBody() {
    Column() {
      Blank().height(8)

      // 封面⇄歌词:Swiper 左右滑动(封面向左滑→歌词;歌词向右滑→封面)
      Swiper(this.swiperCtrl) {
        // 第 1 页:大封面
        Column() {
          if (this.playerVer < 0) {
            Text('')
          } else if (this.srPm !== null) {
            Image(this.srPm)
              .width(this.playerSkin === 'minimal' ? '56%' : '78%')
              .aspectRatio(1)
              .borderRadius(24)
              .objectFit(ImageFit.Cover)
              .shadow({ radius: 48, color: '#33000000', offsetX: 0, offsetY: 12 })
          } else if ((this.song() as Song).artPath.length > 0) {
            Image((this.song() as Song).artPath)
              .width(this.playerSkin === 'minimal' ? '56%' : '78%')
              .aspectRatio(1)
              .borderRadius(24)
              .objectFit(ImageFit.Cover)
              .shadow({ radius: 48, color: '#33000000', offsetX: 0, offsetY: 12 })
          } else {
            Column({ space: 12 }) {
              SymbolGlyph($r('sys.symbol.music_note_list'))
                .fontSize(72)
                .fontColor([$r('app.color.accent')])
            }
            .width(this.playerSkin === 'minimal' ? '56%' : '78%')
            .aspectRatio(1)
            .borderRadius(24)
            .backgroundColor($r('app.color.badge_bg'))
            .justifyContent(FlexAlign.Center)
          }
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)

        // 第 2 页:歌词
        Column({ space: 6 }) {
          LyricsPanel({ lyricText: this.lyricsNow() })
            .width('100%')
            .layoutWeight(1)
          Button(this.editLabel())
            .fontSize(11)
            .height(26)
            .fontColor($r('app.color.text_secondary'))
            .backgroundColor($r('app.color.badge_bg'))
            .onClick(() => {
              const song = PlayerController.get().currentSong;
              const stack = this.pathStack;
              if (song !== null && stack !== null) {
                stack.pushPathByName('LyricsEditor', song.id);
              }
            })
        }
        .width('88%')
        .height('100%')
        .padding({ top: 8, bottom: 8 })
        .justifyContent(FlexAlign.Center)
      }
      .index(this.pageIdx)
      .loop(false)
      .indicator(false)
      .cachedCount(1)
      .width('100%')
      .layoutWeight(1)
      .onChange((i: number) => {
        this.pageIdx = i;
      })

      // 信息 + 引擎徽章(playerVer 条件读取驱动切曲刷新)
      Column({ space: 6 }) {
        if (this.playerVer < 0) {
          Text('')
        }
        Text((this.song() as Song).displayTitle())
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text((this.song() as Song).displayArtist() + ' — ' + (this.song() as Song).displayAlbum())
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Row({ space: 8 }) {
          Text(PlayerController.get().engineInfo)
            .fontSize(10)
            .fontColor($r('app.color.badge_text'))
            .backgroundColor($r('app.color.badge_bg'))
            .borderRadius(6)
            .padding({ left: 8, right: 8, top: 2, bottom: 2 })
          if ((this.song() as Song).specBadge().length > 0) {
            Text((this.song() as Song).specBadge())
              .fontSize(10)
              .fontColor($r('app.color.badge_text'))
              .backgroundColor($r('app.color.badge_bg'))
              .borderRadius(6)
              .padding({ left: 8, right: 8, top: 2, bottom: 2 })
          }
        }
        .justifyContent(FlexAlign.Center)
      }
      .width('100%')
      .padding({ left: 24, right: 24, top: 8 })
      .alignItems(HorizontalAlign.Center)

      // 进度条
      Column({ space: 4 }) {
        Slider({
          value: this.sliderValue(),
          min: 0,
          max: Math.max(1, this.durMs()),
          step: 1,
          style: SliderStyle.OutSet
        })
          .selectedColor($r('app.color.accent'))
          .trackColor($r('app.color.divider'))
          .blockColor($r('app.color.accent'))
          .width('88%')
          .onChange((value: number, mode: SliderChangeMode) => {
            if (mode === SliderChangeMode.Begin) {
              this.seeking = true;
              this.seekPreviewMs = value;
            } else if (mode === SliderChangeMode.Moving) {
              this.seekPreviewMs = value;
            } else if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
              PlayerController.get().seekTo(Math.round(value));
              this.seeking = false;
            }
          })
        Row() {
          Text(formatDuration(this.sliderValue()))
            .fontSize(11)
            .fontColor($r('app.color.text_secondary'))
          Blank()
          Text(formatDuration(this.durMs()))
            .fontSize(11)
            .fontColor($r('app.color.text_secondary'))
        }
        .width('88%')
      }
      .width('100%')
      .padding({ top: 4 })

      // 控制区:播放模式(左) | 上一曲/播放暂停(动画)/下一曲 | 队列(右)
      if (this.queueVer < 0) {
        Text('') // 注册 queueVer 依赖:模式切换/随机重排驱动控制区刷新
      }
      Row({ space: 8 }) {
        Button({ stateEffect: true }) {
          SymbolGlyph(this.modeIcon())
            .fontSize(20)
            .fontColor([this.modeAccent() ? $r('app.color.accent') : $r('app.color.text_primary')])
        }
        .width(46)
        .height(46)
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          const m = QueueService.get().cyclePlayMode();
          hilog.info(DOMAIN, TAG, 'play mode -> %{public}s', m);
        })

        Button({ stateEffect: true }) {
          SymbolGlyph($r('sys.symbol.backward_end_fill'))
            .fontSize(30)
            .fontColor([$r('app.color.control_fg')])
        }
        .width(52)
        .height(52)
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          PlayerController.get().playPrev();
        })

        // 播放/暂停:点击缩放弹跳动画 + symbol 切换(@State 镜像驱动过渡)
        Button({ stateEffect: false }) {
          SymbolGlyph(this.playingMirror ? $r('sys.symbol.pause_fill') : $r('sys.symbol.play_fill'))
            .fontSize(38)
            .fontColor([$r('app.color.on_accent')])
        }
        .width(76)
        .height(76)
        .borderRadius(38)
        .backgroundColor($r('app.color.accent'))
        .scale(this.playBounce ? { x: 0.82, y: 0.82 } : { x: 1, y: 1 })
        .animation({ duration: 160, curve: Curve.Friction })
        .onClick(() => {
          this.playBounce = true;
          PlayerController.get().playPause();
          // 下一帧回弹(等价按下-松开的弹性反馈)
          setTimeout((): void => {
            this.playBounce = false;
          }, 90);
        })

        Button({ stateEffect: true }) {
          SymbolGlyph($r('sys.symbol.forward_end_fill'))
            .fontSize(30)
            .fontColor([$r('app.color.control_fg')])
        }
        .width(52)
        .height(52)
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          PlayerController.get().playNext();
        })

        Button({ stateEffect: true }) {
          SymbolGlyph($r('sys.symbol.list_bullet'))
            .fontSize(20)
            .fontColor([$r('app.color.text_primary')])
        }
        .width(46)
        .height(46)
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          this.showQueue = !this.showQueue;
        })
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .padding({ top: 8, bottom: 8 })

      // 底部导航条避让(≥28vp)
      Blank().height(Math.max(this.bottomSafe, 28) + 8)
    }
    .width('100%')
    .layoutWeight(1) // 占顶栏以下剩余空间(height 100% 会把顶栏挤出视口致底部溢出)
  }

  // ===== 右上角"更多"bindSheet 菜单 =====

  @Builder
  MoreSheet() {
    Column() {
      Text($r('app.string.more_menu'))
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
        .padding({ left: 20, top: 12, bottom: 8 })
      List({ space: 0 }) {
        // 收藏
        ListItem() {
          this.SheetRow(this.isFav() ? $r('sys.symbol.heart_fill') : $r('sys.symbol.heart'),
            this.isFav() ? $r('app.string.str_favorited') : $r('app.string.str_favorites'),
            this.isFav(), (): void => {
              PlayerController.get().toggleFavorite();
            })
        }
        // 编辑歌词
        ListItem() {
          this.SheetRow($r('sys.symbol.pencil_line'), this.editLabel(), false, (): void => {
            this.showMoreSheet = false;
            const song = PlayerController.get().currentSong;
            const stack = this.pathStack;
            if (song !== null && stack !== null) {
              stack.pushPathByName('LyricsEditor', song.id);
            }
          })
        }
        // 倍速
        ListItem() {
          this.SheetRow($r('sys.symbol.speed_multiple'), this.speedLabel(),
            this.speedNow() !== 1.0, (): void => {
              // 循环切常用档:1.0 → 1.25 → 1.5 → 2.0 → 0.5 → 1.0
              const cur = this.speedNow();
              const next = cur === 1.0 ? 1.25 : cur === 1.25 ? 1.5 : cur === 1.5 ? 2.0 : cur === 2.0 ? 0.5 : 1.0;
              PlayerController.get().setSpeed(next);
            })
        }
        // A-B 重复
        ListItem() {
          this.SheetRow($r('sys.symbol.scope'), this.abLabel(),
            this.abStateNow() !== 'off', (): void => {
              PlayerController.get().setAbPoint();
            })
        }
        // 跳过静音
        ListItem() {
          this.SheetRow($r('sys.symbol.speaker_slash'), $r('app.string.skip_silence'),
            this.skipSilenceNow(), (): void => {
              PlayerController.get().toggleSkipSilence();
            })
        }
        // 睡眠定时器
        ListItem() {
          this.SheetRow($r('sys.symbol.timer'), this.sleepLabel(),
            PlayerController.get().sleepRemainMin() > 0, (): void => {
              this.cycleSleepTimer();
            })
        }
        // 桌面歌词(26-7,floatView;24 设备/权限未授时不显示入口)
        if (DesktopLyricsService.get().available()) {
          ListItem() {
            this.SheetRow($r('sys.symbol.music_note_list'), $r('app.string.desktop_lyrics'),
              DesktopLyricsService.get().isOn(), (): void => {
                this.toggleDesktopLyrics();
              })
          }
        }
        // 查看队列
        ListItem() {
          this.SheetRow($r('sys.symbol.list_bullet'), $r('app.string.view_queue'), false, (): void => {
            this.showMoreSheet = false;
            this.showQueue = true;
          })
        }
      }
      .width('100%')
      .padding({ bottom: 16 })
    }
    .width('100%')
    .backgroundColor($r('app.color.card_bg'))
  }

  @Builder
  SheetRow(icon: Resource, label: ResourceStr, accent: boolean, onTap: () => void) {
    Row({ space: 12 }) {
      SymbolGlyph(icon)
        .fontSize(18)
        .fontColor([accent ? $r('app.color.accent') : $r('app.color.text_primary')])
      Text(label)
        .fontSize(14)
        .fontColor(accent ? $r('app.color.accent') : $r('app.color.text_primary'))
        .layoutWeight(1)
    }
    .width('100%')
    .padding({ left: 20, right: 16, top: 12, bottom: 12 })
    .onClick(() => {
      onTap();
    })
  }

  @Builder
  QueueDrawer() {
    Column() {
      if (this.queueVer < 0) {
        Text('') // 注册 queueVer 依赖,队列变更驱动抽屉刷新
      }
      Row() {
        Text($r('app.string.current_queue'))
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
        // 多队列管理(原队列页签入口迁移至此)
        Button({ stateEffect: true }) {
          SymbolGlyph($r('sys.symbol.square_stack_3d'))
            .fontSize(16)
            .fontColor([$r('app.color.text_primary')])
        }
        .width(32)
        .height(32)
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          this.showQueue = false;
          this.pathStack?.pushPathByName('QueueBoard', null);
        })
        // 循环模式 + 播完停止 + 推进边界(原队列页签菜单迁移)
        Button({ stateEffect: true }) {
          SymbolGlyph(this.modeIcon())
            .fontSize(16)
            .fontColor([this.modeAccent() ? $r('app.color.accent') : $r('app.color.text_primary')])
        }
        .width(32)
        .height(32)
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          QueueService.get().cyclePlayMode();
        })
        // 睡眠定时器(原队列页签入口迁移)
        Button({ stateEffect: true }) {
          SymbolGlyph($r('sys.symbol.timer'))
            .fontSize(16)
            .fontColor([PlayerController.get().sleepRemainMin() > 0 ? $r('app.color.accent') : $r('app.color.text_primary')])
        }
        .width(32)
        .height(32)
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          this.cycleSleepTimer();
        })
        Button({ stateEffect: true }) {
          SymbolGlyph($r('sys.symbol.trash'))
            .fontSize(16)
            .fontColor([$r('app.color.text_secondary')])
        }
        .width(32)
        .height(32)
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          QueueService.get().clear();
        })
        Button({ stateEffect: true }) {
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(16)
            .fontColor([$r('app.color.text_secondary')])
        }
        .width(32)
        .height(32)
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          this.showQueue = false;
        })
      }
      .width('100%')
      .padding({ left: 16, right: 12, top: 12, bottom: 4 })

      List({ space: 0 }) {
        ForEach(this.queueItems(), (s: Song, i: number) => {
          ListItem() {
            Row({ space: 10 }) {
              Text(String(i + 1))
                .fontSize(11)
                .fontColor(i === QueueService.get().currentOrderIndex ? $r('app.color.accent') : $r('app.color.text_secondary'))
                .width(24)
                .textAlign(TextAlign.Center)
              Column({ space: 2 }) {
                Text(s.displayTitle())
                  .fontSize(14)
                  .fontColor(i === QueueService.get().currentOrderIndex ? $r('app.color.accent') : $r('app.color.text_primary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(s.displayArtist())
                  .fontSize(10)
                  .fontColor($r('app.color.text_secondary'))
                  .maxLines(1)
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              Text(formatDuration(s.durationMs))
                .fontSize(10)
                .fontColor($r('app.color.text_secondary'))
            }
            .width('100%')
            .padding({ left: 12, right: 12, top: 8, bottom: 8 })
            .onClick(() => {
              PlayerController.get().playQueueIndex(i);
            })
          }
        }, (s: Song, i: number): string => `qd_${i}_${s.id}`)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      .padding({ bottom: Math.max(this.bottomSafe, 28) + 8 })
    }
    .width('100%')
    .height('55%')
    .borderRadius({ topLeft: 24, topRight: 24 })
    .backgroundColor($r('app.color.card_bg'))
    .shadow({ radius: 32, color: '#33000000', offsetX: 0, offsetY: -6 })
  }

  // 桌面歌词开关:开→floatView 拉起浮窗页;失败提示(权限/设备不支持)
  private async toggleDesktopLyrics(): Promise<void> {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await DesktopLyricsService.get().toggle(ctx);
      this.showMoreSheet = false;
    } catch (e) {
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.float_lyrics_fail') });
    }
  }

  // ===== 辅助 =====

  private sliderValue(): number {
    if (this.seeking) {
      return Math.round(this.seekPreviewMs);
    }
    return this.posMs;
  }

  private durMs(): number {
    return Math.max(1, PlayerController.get().durationMs);
  }

  private isFav(): boolean {
    const s = this.song();
    return s !== null && LibraryStore.get().isFavorite(s.id);
  }

  private lyricsNow(): string {
    return PlayerController.get().currentLyrics;
  }

  private editLabel(): ResourceStr {
    return this.lyricsNow().length > 0 ? $r('app.string.edit_lyrics') : $r('app.string.add_lyrics');
  }

  private speedNow(): number {
    return PlayerController.get().speed;
  }

  private speedLabel(): ResourceStr {
    const v = this.speedNow();
    if (v === 1.0) {
      return $r('app.string.speed_label');
    }
    return `${v}x`;
  }

  private abStateNow(): string {
    return PlayerController.get().abState();
  }

  private abLabel(): ResourceStr {
    const st = this.abStateNow();
    if (st === 'a') {
      return $r('app.string.ab_set_a');
    }
    if (st === 'ab') {
      return $r('app.string.ab_looping');
    }
    return 'A-B';
  }

  private skipSilenceNow(): boolean {
    return PlayerController.get().currentSong !== null &&
      (PlayerController.get().engineKind === EngineKind.LOSSLESS) &&
      PlayerController.get().isSkipSilenceOn();
  }

  // 睡眠定时:菜单内点按循环 关→15→30→45→60→90→关
  private cycleSleepTimer(): void {
    const cur = PlayerController.get().sleepRemainMin();
    const next = cur <= 0 ? 15 : cur < 30 ? 30 : cur < 45 ? 45 : cur < 60 ? 60 : cur < 90 ? 90 : 0;
    PlayerController.get().setSleepTimer(next);
  }

  private sleepLabel(): ResourceStr {
    const cur = PlayerController.get().sleepRemainMin();
    if (cur <= 0) {
      return $r('app.string.sleep_timer');
    }
    return L($r('app.string.sleep_remain'), String(cur));
  }

  private modeIcon(): Resource {
    const m = this.modeMirror;
    if (m === 'shuffle') {
      return $r('sys.symbol.shuffle');
    }
    if (m === 'one') {
      return $r('sys.symbol.repeat_1');
    }
    if (m === 'loop') {
      return $r('sys.symbol.repeat');
    }
    return $r('sys.symbol.arrow_right');
  }

  private modeAccent(): boolean {
    return this.modeMirror !== 'order';
  }
}


@Builder
export function FullPlayerBuilder() {
  FullPlayerDest()
}

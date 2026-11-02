// 全屏播放页:大封面 + 进度条(Slider 拖动中忽略 timeUpdate)+ 全套控制 + 队列抽屉。
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { AppTheme, SafeAreaResult } from '../../common/Theme';
import { PlayerController } from '../../service/PlayerController';
import { QueueService } from '../../service/QueueService';
import { EngineKind } from '../../service/engine/EngineTypes';
import { LibraryStore } from '../../data/LibraryStore';
import { Song, RepeatMode, formatDuration } from '../../data/Model';
import { LyricsPanel } from '../../components/LyricsPanel';

const TAG = '[Timbrava][FullPlayer]';
const DOMAIN = 0x0001;

@Component
export struct FullPlayerDest {
  @StorageProp('playerVer') @Watch('onPlayerChanged') playerVer: number = 0;
  @StorageProp('posVer') posVer: number = 0;
  @StorageProp('queueVer') queueVer: number = 0;
  @StorageProp('libVer') libVer: number = 0;
  @StorageProp('themePageBg') themePageBg: string = '';
  @StorageProp('prefPlayerSkin') playerSkin: string = 'standard';
  @State seeking: boolean = false;
  @State seekPreviewMs: number = 0;
  @State showQueue: boolean = false;
  @State showLyrics: boolean = false;
  @State topSafe: number = 36;
  @State bottomSafe: number = 28;
  private pathStack: NavPathStack | null = null;

  aboutToAppear(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    AppTheme.safeAreas(ctx).then((r: SafeAreaResult): void => {
      this.topSafe = r.topVp;
      this.bottomSafe = r.bottomVp;
    });
    // 页面可能晚于播放打开:@Watch 不会补发,主动拉一次(歌词由控制器中心化加载)
    this.onPlayerChanged();
  }

  onPlayerChanged(): void {
    // playerVer bump 已驱动重渲染;歌词文本取 PlayerController.currentLyrics
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
        // 顶栏
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
          Text('正在播放')
            .fontSize(15)
            .fontColor($r('app.color.text_secondary'))
            .layoutWeight(1)
            .textAlign(TextAlign.Center)
          Button({ stateEffect: true }) {
            SymbolGlyph($r('sys.symbol.list_bullet'))
              .fontSize(20)
              .fontColor([$r('app.color.text_primary')])
          }
          .width(40)
          .height(40)
          .backgroundColor(Color.Transparent)
          .onClick(() => {
            this.showQueue = !this.showQueue;
          })
          Button({ stateEffect: true }) {
            SymbolGlyph($r('sys.symbol.book'))
              .fontSize(20)
              .fontColor([this.showLyrics ? $r('app.color.accent') : $r('app.color.text_primary')])
          }
          .width(40)
          .height(40)
          .backgroundColor(Color.Transparent)
          .margin({ left: 4 })
          .onClick(() => {
            this.showLyrics = !this.showLyrics;
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
            Text('还没有播放中的歌曲')
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
      Blank().height(12)

      // 大封面 / 歌词
      Stack({ alignContent: Alignment.Center }) {
        if (this.playerVer < 0) {
          Text('')
        } else if (this.showLyrics) {
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
          .height(this.playerSkin === 'minimal' ? '44%' : '56%')
        } else if ((this.song() as Song).artPath.length > 0) {
          Image((this.song() as Song).artPath)
            .width(this.playerSkin === 'minimal' ? '46%' : '78%')
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
          .width(this.playerSkin === 'minimal' ? '46%' : '78%')
          .aspectRatio(1)
          .borderRadius(24)
          .backgroundColor($r('app.color.badge_bg'))
          .justifyContent(FlexAlign.Center)
        }
      }
      .width('100%')
      .layoutWeight(1)

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

      // 控制区
      Row({ space: 8 }) {
        Button({ stateEffect: true }) {
          SymbolGlyph($r('sys.symbol.shuffle'))
            .fontSize(20)
            .fontColor([QueueService.get().shuffled ? $r('app.color.accent') : $r('app.color.text_primary')])
        }
        .width(46)
        .height(46)
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          QueueService.get().toggleShuffle();
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

        Button({ stateEffect: true }) {
          SymbolGlyph(this.isPlayingNow() ? $r('sys.symbol.pause_fill') : $r('sys.symbol.play_fill'))
            .fontSize(38)
            .fontColor([$r('app.color.on_accent')])
        }
        .width(76)
        .height(76)
        .borderRadius(38)
        .backgroundColor($r('app.color.accent'))
        .onClick(() => {
          PlayerController.get().playPause();
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
          SymbolGlyph(this.repeatIcon())
            .fontSize(20)
            .fontColor([QueueService.get().repeat === RepeatMode.OFF ? $r('app.color.text_primary') : $r('app.color.accent')])
        }
        .width(46)
        .height(46)
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          const mode = QueueService.get().cycleRepeat();
          PlayerController.get().setRepeat(mode);
        })
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .padding({ top: 8, bottom: 8 })

      // 功能行:倍速 / A-B 重复 / 跳过静音
      Row({ space: 6 }) {
        Button({ stateEffect: true }) {
          Row({ space: 4 }) {
            SymbolGlyph($r('sys.symbol.speed_multiple'))
              .fontSize(16)
              .fontColor([this.speedNow() === 1.0 ? $r('app.color.text_secondary') : $r('app.color.accent')])
            Text(this.speedLabel())
              .fontSize(11)
              .fontColor(this.speedNow() === 1.0 ? $r('app.color.text_secondary') : $r('app.color.accent'))
          }
        }
        .height(34)
        .backgroundColor(Color.Transparent)
        .bindMenu(this.speedMenu())

        Button({ stateEffect: true }) {
          Row({ space: 4 }) {
            SymbolGlyph($r('sys.symbol.scope'))
              .fontSize(16)
              .fontColor([this.abStateNow() === 'off' ? $r('app.color.text_secondary') : $r('app.color.accent')])
            Text(this.abLabel())
              .fontSize(11)
              .fontColor(this.abStateNow() === 'off' ? $r('app.color.text_secondary') : $r('app.color.accent'))
          }
        }
        .height(34)
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          PlayerController.get().setAbPoint();
        })

        Button({ stateEffect: true }) {
          Row({ space: 4 }) {
            SymbolGlyph($r('sys.symbol.speaker_slash'))
              .fontSize(16)
              .fontColor([this.skipSilenceNow() ? $r('app.color.accent') : $r('app.color.text_secondary')])
            Text('跳过静音')
              .fontSize(11)
              .fontColor(this.skipSilenceNow() ? $r('app.color.accent') : $r('app.color.text_secondary'))
          }
        }
        .height(34)
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          PlayerController.get().toggleSkipSilence();
        })
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)

      // 收藏行
      Button({ stateEffect: true }) {
        Row({ space: 6 }) {
          SymbolGlyph(this.isFav() ? $r('sys.symbol.heart_fill') : $r('sys.symbol.heart'))
            .fontSize(16)
            .fontColor([this.isFav() ? $r('app.color.accent') : $r('app.color.text_secondary')])
          Text(this.isFav() ? '已收藏' : '收藏')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
        }
      }
      .height(34)
      .backgroundColor(Color.Transparent)
      .onClick(() => {
        PlayerController.get().toggleFavorite();
      })

      Blank().height(this.bottomSafe + 8)
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  QueueDrawer() {
    Column() {
      Row() {
        Text('当前队列')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
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
      .padding({ bottom: this.bottomSafe + 8 })
    }
    .width('100%')
    .height('55%')
    .borderRadius({ topLeft: 24, topRight: 24 })
    .backgroundColor($r('app.color.card_bg'))
    .shadow({ radius: 32, color: '#33000000', offsetX: 0, offsetY: -6 })
  }

  private sliderValue(): number {
    if (this.seeking) {
      return Math.round(this.seekPreviewMs);
    }
    return Math.round(PlayerController.get().positionMs);
  }

  private isPlayingNow(): boolean {
    return PlayerController.get().isPlaying;
  }

  private durMs(): number {
    return Math.max(1, PlayerController.get().durationMs);
  }

  private isFav(): boolean {
    const s = this.song();
    return s !== null && LibraryStore.get().isFavorite(s.id);
  }

  private repeatIcon(): Resource {
    const r = QueueService.get().repeat;
    if (r === RepeatMode.ONE) {
      return $r('sys.symbol.repeat_1');
    }
    return $r('sys.symbol.repeat');
  }

  // ===== 功能行辅助(playerVer 驱动重渲染) =====

  private lyricsNow(): string {
    return PlayerController.get().currentLyrics;
  }

  private editLabel(): string {
    return this.lyricsNow().length > 0 ? '编辑歌词' : '添加歌词(打轴)';
  }

  private speedNow(): number {
    return PlayerController.get().speed;
  }

  private speedLabel(): string {
    const v = this.speedNow();
    if (v === 1.0) {
      return '倍速';
    }
    return `${v}x`;
  }

  private abStateNow(): string {
    return PlayerController.get().abState();
  }

  private abLabel(): string {
    const st = this.abStateNow();
    if (st === 'a') {
      return 'A-B:已设A';
    }
    if (st === 'ab') {
      return 'A-B:循环中';
    }
    return 'A-B';
  }

  private skipSilenceNow(): boolean {
    return PlayerController.get().currentSong !== null &&
      (PlayerController.get().engineKind === EngineKind.LOSSLESS) &&
      PlayerController.get().isSkipSilenceOn();
  }

  @Builder
  speedMenu() {
    Menu() {
      MenuItem({ content: '0.5x' })
        .onClick(() => {
          PlayerController.get().setSpeed(0.5);
        })
      MenuItem({ content: '0.75x' })
        .onClick(() => {
          PlayerController.get().setSpeed(0.75);
        })
      MenuItem({ content: '标准 1.0x' })
        .onClick(() => {
          PlayerController.get().setSpeed(1.0);
        })
      MenuItem({ content: '1.25x' })
        .onClick(() => {
          PlayerController.get().setSpeed(1.25);
        })
      MenuItem({ content: '1.5x' })
        .onClick(() => {
          PlayerController.get().setSpeed(1.5);
        })
      MenuItem({ content: '2.0x' })
        .onClick(() => {
          PlayerController.get().setSpeed(2.0);
        })
      MenuItem({ content: '3.0x' })
        .onClick(() => {
          PlayerController.get().setSpeed(3.0);
        })
    }
  }
}


@Builder
export function FullPlayerBuilder() {
  FullPlayerDest()
}

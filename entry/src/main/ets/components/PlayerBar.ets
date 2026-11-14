// 宽屏底部播放条(0.22.0 折叠屏 lg/xl + PC/2in1 专属;网易云/QQ PC 版惯例):
// 封面+歌名艺人+进度滑条+上一首/播放/下一首+队列——全宽浮于 Navigation 之上(Index 根 Stack 兄弟节点)。
// 与迷你条(HdsTabs miniBar,仅 sm/md 悬浮页签)互斥:侧边页签模式下 barFloatingStyle 不可用(官方约束
// barPosition(End)+vertical(false)),宽屏改由本组件接管底部播控。
import { PlayerController } from '../service/PlayerController';
import { formatDuration } from '../data/Model';

const DOMAIN = 0x0001;

@Component
export struct PlayerBar {
  @StorageProp('playerVer') @Watch('onChange') playerVer: number = 0;
  @StorageProp('posVer') @Watch('onChange') posVer: number = 0;
  @State visible: boolean = false;
  @State title: string = '';
  @State artist: string = '';
  @State art: string = '';
  @State playing: boolean = false;
  @State pos: number = 0;
  @State dur: number = 0;
  @State dragging: boolean = false; // 拖动中镜像不回写(防 seek 抖动)
  @State dragPos: number = 0;
  @State hoverRow: boolean = false;
  private posTimer: number = -1;

  onChange(): void {
    this.refresh();
  }

  aboutToAppear(): void {
    this.refresh();
    this.posTimer = setInterval((): void => {
      if (!this.dragging && PlayerController.get().isPlaying) {
        this.pos = PlayerController.get().positionMs;
      }
    }, 500) as number;
  }

  aboutToDisappear(): void {
    if (this.posTimer >= 0) {
      clearInterval(this.posTimer);
      this.posTimer = -1;
    }
  }

  private refresh(): void {
    const s = PlayerController.get().currentSong;
    this.visible = s !== null;
    this.title = s !== null ? s.displayTitle() : '';
    this.artist = s !== null ? s.displayArtist() : '';
    this.art = s !== null ? s.artPath : '';
    this.playing = PlayerController.get().isPlaying;
    this.pos = PlayerController.get().positionMs;
    this.dur = PlayerController.get().durationMs;
  }

  private navStack(): NavPathStack | null {
    return AppStorage.get<NavPathStack>('navStack') ?? null;
  }

  build() {
    if (!this.visible) {
      Blank().height(0)
    } else {
      Row({ space: 14 }) {
        if (this.art.length > 0) {
          Image(this.art)
            .width(42)
            .height(42)
            .borderRadius(8)
            .objectFit(ImageFit.Cover)
            .syncLoad(true)
        } else {
          Column() {
            SymbolGlyph($r('sys.symbol.music_note_list'))
              .fontSize(20)
              .fontColor([$r('app.color.accent')])
          }
          .width(42)
          .height(42)
          .borderRadius(8)
          .backgroundColor($r('app.color.badge_bg'))
          .justifyContent(FlexAlign.Center)
        }

        // 歌名/艺人:点击整条左侧区进播放页(PC 惯例:主信息区展开播放页)
        Column({ space: 2 }) {
          Text(this.title)
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.artist)
            .fontSize(11)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .onClick(() => {
          const stack = this.navStack();
          if (stack !== null) {
            stack.pushPathByName('FullPlayer', null);
          }
        })

        // 进度滑条+时间(PC 网易云/QQ 惯例;波形条留给播放页)
        Text(formatDuration(this.pos))
          .fontSize(10)
          .fontColor($r('app.color.text_secondary'))
        Slider({
          value: Math.round(this.dragging ? this.dragPos : this.pos),
          min: 0,
          max: Math.max(1, this.dur),
          step: 1,
          style: SliderStyle.OutSet
        })
          .width('22%')
          .height(28)
          .selectedColor($r('app.color.accent'))
          .trackColor($r('app.color.divider'))
          .blockColor($r('app.color.accent'))
          .onChange((value: number, mode: SliderChangeMode): void => {
            if (mode === SliderChangeMode.Begin) {
              this.dragging = true;
              this.dragPos = value;
            } else if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
              PlayerController.get().seekTo(Math.round(value));
              this.pos = Math.round(value);
              this.dragging = false;
            } else {
              this.dragPos = value;
            }
          })
        Text(formatDuration(this.dur))
          .fontSize(10)
          .fontColor($r('app.color.text_secondary'))

        // 播控组:上一首/播放/下一首/队列
        Button({ stateEffect: true }) {
          SymbolGlyph($r('sys.symbol.backward_end_fill'))
            .fontSize(20)
            .fontColor([$r('app.color.text_primary')])
        }
        .width(40)
        .height(40)
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          PlayerController.get().playPrev();
        })
        Button({ stateEffect: true }) {
          SymbolGlyph(this.playing ? $r('sys.symbol.pause_fill') : $r('sys.symbol.play_fill'))
            .fontSize(24)
            .fontColor([$r('app.color.on_accent')])
        }
        .width(44)
        .height(44)
        .borderRadius(22)
        .backgroundColor($r('app.color.accent'))
        .onClick(() => {
          PlayerController.get().playPause();
        })
        Button({ stateEffect: true }) {
          SymbolGlyph($r('sys.symbol.forward_end_fill'))
            .fontSize(20)
            .fontColor([$r('app.color.text_primary')])
        }
        .width(40)
        .height(40)
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          PlayerController.get().playNext();
        })
        Button({ stateEffect: true }) {
          SymbolGlyph($r('sys.symbol.music_note_list'))
            .fontSize(20)
            .fontColor([$r('app.color.text_primary')])
        }
        .width(40)
        .height(40)
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          const stack = this.navStack();
          if (stack !== null) {
            stack.pushPathByName('QueueBoard', null);
          }
        })
      }
      .width('100%')
      .height(60)
      .padding({ left: 16, right: 12 })
      .border({ width: { top: 0.5 }, color: $r('app.color.divider') })
      // PC hover:整条微亮(键鼠适配基础态)
      .onMouse((e?: MouseEvent): void => {
        if (e !== undefined && e !== null) {
          this.hoverRow = e.action === MouseAction.ENTER_WINDOW;
        }
      })
      .backgroundColor(this.hoverRow
        ? ($r('app.color.hover_bg') as ResourceColor)
        : ($r('app.color.mini_player_bg') as ResourceColor))
    }
  }
}

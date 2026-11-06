// 迷你播放条(独立组件:@StorageProp 绑定刷新依赖,build 内重求值)
// 经 HdsTabs barFloatingStyle.miniBar(6.1.0(23))挂载:与页签栏同高对齐、
// 背景材质/避让由 HdsTabs 统一管理,组件只负责内容(封面/标题/播控)。
// 空队列(无当前曲)渲染占位行,避免 HdsTabs 迷你栏露出空壳(0.15.0)。
import { PlayerController } from '../service/PlayerController';
import { formatDuration } from '../data/Model';

@Component
export struct MiniPlayer {
  @StorageProp('playerVer') @Watch('onChange') playerVer: number = 0;
  @StorageProp('posVer') @Watch('onChange') posVer: number = 0;
  @State visible: boolean = false;
  @State title: string = '';
  @State artist: string = '';
  @State art: string = '';
  @State playing: boolean = false;
  @State pos: number = 0;
  @State dur: number = 0;
  private posTimer: number = -1;

  onChange(): void {
    this.refresh();
  }

  aboutToAppear(): void {
    this.refresh();
    // 播放中秒级位置刷新(增量通道,250ms 粒度由控制器 posVer 提供,这里兜底拉取)
    this.posTimer = setInterval((): void => {
      if (PlayerController.get().isPlaying) {
        this.pos = PlayerController.get().positionMs;
      }
    }, 1000) as number;
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
    Column() {
      if (!this.visible) {
        // 空队列占位(不响应点击进播放页)
        Row({ space: 10 }) {
          SymbolGlyph($r('sys.symbol.music_note_list'))
            .fontSize(18)
            .fontColor([$r('app.color.text_secondary')])
          Text($r('app.string.mini_bar_empty'))
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .padding({ left: 12, right: 12 })
      } else {
        this.MiniBarContent()
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  MiniBarContent() {
    Row({ space: 12 }) {
      if (this.art.length > 0) {
        Image(this.art)
          .width(44)
          .height(44)
          .borderRadius(8)
          .objectFit(ImageFit.Cover)
      } else {
        Column() {
          SymbolGlyph($r('sys.symbol.music_note_list'))
            .fontSize(20)
            .fontColor([$r('app.color.accent')])
        }
        .width(44)
        .height(44)
        .borderRadius(8)
        .backgroundColor($r('app.color.badge_bg'))
        .justifyContent(FlexAlign.Center)
      }
      Column({ space: 2 }) {
        Text(this.title)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.artist + ' · ' + formatDuration(this.pos) + ' / ' + formatDuration(this.dur))
          .fontSize(11)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Button({ stateEffect: true }) {
        SymbolGlyph(this.playing ? $r('sys.symbol.pause_fill') : $r('sys.symbol.play_fill'))
          .fontSize(22)
          .fontColor([$r('app.color.on_accent')])
      }
      .width(40)
      .height(40)
      .borderRadius(20)
      .backgroundColor($r('app.color.accent'))
      .onClick(() => {
        PlayerController.get().playPause();
      })

      Button({ stateEffect: true }) {
        SymbolGlyph($r('sys.symbol.forward_end_fill'))
          .fontSize(20)
          .fontColor([$r('app.color.text_primary')])
      }
      .width(36)
      .height(36)
      .backgroundColor(Color.Transparent)
      .onClick(() => {
        PlayerController.get().playNext();
      })
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 4, bottom: 4 })
    .onClick(() => {
      const stack = this.navStack();
      if (stack !== null) {
        stack.pushPathByName('FullPlayer', null);
      }
    })
  }
}

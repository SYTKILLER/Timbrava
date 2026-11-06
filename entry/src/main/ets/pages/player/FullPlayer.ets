// 全屏播放页(对齐华为音乐/QQ音乐共识交互):
// - 封面⇄歌词左右 Swiper 切换(官方《多设备音乐界面》最佳实践:窄屏 Swiper 分页);
// - 下滑手势关闭(跟手位移+速度阈值;0.14.0) + 顶栏 chevron_down/红心收藏直达;
// - 音量条(双引擎;0.14.0)+ 沉浸皮肤(封面高斯模糊背景);
// - 控制区:左播放模式键(顺序→列表循环→单曲→随机,symbol 显示当前模式)+ 上一曲/播放暂停(缩放动画)/下一曲 + 右队列键;
// - 右上角"更多"入口 → bindSheet 菜单(收藏/均衡器/编辑歌词/倍速弹层/A-B/跳过静音/睡眠定时弹层/桌面歌词/查看队列);
// - 底部 ≥28vp 导航条避让。
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import { display } from '@kit.ArkUI';
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

// 倍速弹层档位(0.14.0:循环点击改离散选择)
const SPEED_OPTIONS: number[] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0];
// 睡眠定时弹层档位(分钟;0=关)
const SLEEP_OPTIONS: number[] = [0, 15, 30, 45, 60, 90];
const SLEEP_FADE_MS = 30000; // 到点前线性渐弱时长(与 PlayerController 一致)

@Component
export struct FullPlayerDest {
  @StorageProp('playerVer') @Watch('onPlayerChanged') playerVer: number = 0;
  @StorageProp('posVer') @Watch('onPosChanged') posVer: number = 0;
  @State posMs: number = 0;
  @StorageProp('queueVer') @Watch('onQueueChanged') queueVer: number = 0;
  @State modeMirror: PlayMode = 'order'; // 模式键图标镜像(经 @State 切换驱动刷新)
  @StorageProp('libVer') @Watch('onLibChanged') libVer: number = 0;
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
  @State dragY: number = 0;          // 下滑关闭跟手位移(0.14.0)
  @State volMirror: number = 100;    // 音量条镜像(拖动中本地值,End 才落库)
  @State sheetExpand: string = '';   // 更多菜单展开区:'' | 'speed' | 'sleep'
  // 曲目信息镜像(0.15.0 #20):playerVer 不经 @State 落地时 build 内节点零依赖不刷新,
  // "if (playerVer < 0)"注册依赖写法条件恒假不重评——切歌标题/艺人/专辑/封面纹丝不动的根因
  @State songTitle: string = '';
  @State songSub: string = '';
  @State songArt: string = '';
  @State songSpec: string = '';
  @State engineMirror: string = '';
  @State favMirror: boolean = false;
  @State hasSong: boolean = false;
  @State qIndexMirror: number = -1;  // 队列抽屉当前序高亮镜像
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
    this.volMirror = Math.round(PlayerController.get().volume * 100);
    // 页面可能晚于播放打开:@Watch 不会补发,主动拉一次(歌词由控制器中心化加载)
    this.onPlayerChanged();
  }

  aboutToDisappear(): void {
    // 0.15.0 下滑关闭:pop 前不再复位 dragY(保持离屏位,避免默认 pop 转场露馅),
    // 此处(转场结束组件销毁前)清零,实例复用/重进都从原位开始
    this.dragY = 0;
    this.dismissing = false;
  }

  onPlayerChanged(): void {
    this.playingMirror = PlayerController.get().isPlaying;
    this.modeMirror = QueueService.get().playMode();
    this.refreshSongMirrors();
    this.loadCoverSr();
  }

  // 曲目信息镜像刷新(切歌/收藏变化唯一入口;0.15.0)
  private refreshSongMirrors(): void {
    const s = PlayerController.get().currentSong;
    this.hasSong = s !== null;
    this.songTitle = s !== null ? s.displayTitle() : '';
    this.songSub = s !== null ? (s.displayArtist() + ' — ' + s.displayAlbum()) : '';
    this.songArt = s !== null ? s.artPath : '';
    this.songSpec = s !== null ? s.specBadge() : '';
    this.engineMirror = PlayerController.get().engineInfo;
    this.favMirror = s !== null && LibraryStore.get().isFavorite(s.id);
    this.qIndexMirror = QueueService.get().currentOrderIndex;
  }

  onLibChanged(): void {
    this.favMirror = this.hasSong && LibraryStore.get().isFavorite((PlayerController.get().currentSong as Song).id);
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
    this.qIndexMirror = QueueService.get().currentOrderIndex;
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
      // 沉浸皮肤背景层:当前封面高斯模糊 + 主题色蒙版(标准/极简皮肤不渲染,保持纯色底)
      if (this.playerSkin === 'immersive' && this.hasSong) {
        Stack() {
          // 基底垫色:无封面曲(既无超分又无原图)时保证皮肤层不透明(NavDestination 已透明化,见下)
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor(this.pageBg())
          if (this.srPm !== null) {
            Image(this.srPm)
              .width('100%')
              .height('100%')
              .objectFit(ImageFit.Cover)
              .blur(120)
          } else if (this.songArt.length > 0) {
            Image(this.songArt)
              .width('100%')
              .height('100%')
              .objectFit(ImageFit.Cover)
              .blur(120)
          }
        }
        .width('100%')
        .height('100%')
        // 主题色蒙版:保证 text token 在模糊图上可读;0.87 几乎盖死模糊层(用户感知"皮肤没生效"),
        // 降到 0.62 让封面色彩透出(0.15.0)
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(this.pageBg())
          .opacity(0.62)
      }
      Column() {
        // 顶栏:下滑关闭 | 正在播放 | 收藏 | 更多(右上角,bindSheet)
        Row() {
          Button({ stateEffect: true }) {
            SymbolGlyph($r('sys.symbol.chevron_down'))
              .fontSize(24)
              .fontColor([$r('app.color.text_primary')])
          }
          .width(40)
          .height(40)
          .backgroundColor(Color.Transparent)
          .onClick(() => {
            // 0.15.2:返回键与下滑手势同款纵向滑出(此前走默认 pop 横向转场,与操作直觉矛盾)
            this.dismissAnimated();
          })
          Text($r('app.string.now_playing'))
            .fontSize(15)
            .fontColor($r('app.color.text_secondary'))
            .layoutWeight(1)
            .textAlign(TextAlign.Center)
          Button({ stateEffect: true }) {
            SymbolGlyph(this.favMirror ? $r('sys.symbol.heart_fill') : $r('sys.symbol.heart'))
              .fontSize(20)
              .fontColor([this.favMirror ? $r('app.color.accent') : $r('app.color.text_primary')])
          }
          .width(40)
          .height(40)
          .backgroundColor(Color.Transparent)
          .onClick(() => {
            PlayerController.get().toggleFavorite();
          })
          Button({ stateEffect: true }) {
            // 四点钮(0.17.0):华为应用"展开更多选项"语义;原 more(方块)改 dot_grid_2x2
            SymbolGlyph($r('sys.symbol.dot_grid_2x2'))
              .fontSize(20)
              .fontColor([$r('app.color.text_primary')])
          }
          .width(40)
          .height(40)
          .backgroundColor(Color.Transparent)
          .onClick(() => {
            this.openMoreSheet();
          })
        }
        .width('100%')
        .padding({ left: 8, right: 8, top: this.topSafe })
        if (this.hasSong) {
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
      .backgroundColor(this.playerSkin === 'immersive' && this.hasSong
        ? Color.Transparent : this.pageBg())
      // 下滑关闭手势:绑在内容 Column(实证 Stack 级 .gesture 在本页不触发,Row/Column 级正常)。
      // 跟手位移削顶 55%vh:节点拖出屏后手势失灵(KB §9.4),松手动画收尾;抽屉/菜单展开时回调内守卫。
      // 注意 translate 挂在内层 Stack(含皮肤背景层整体下沉);挂本 Column 会让背景层滞留原地。
      .gesture(PanGesture({ fingers: 1, direction: PanDirection.Vertical, distance: 8 })
          .onActionUpdate((e: GestureEvent): void => {
            this.dragUpdate(e);
          })
          .onActionEnd((e: GestureEvent): void => {
            this.dragFinish(e);
          }))
      // 播放队列(0.15.2:自绘 Stack 条目改标准 bindSheet 半模态——标准上滑动画/下拉关闭;
      // 0.17.0 多档高度:默认中档,上滑展开大档)
      .bindSheet(this.showQueue, this.QueueDrawer(), {
        detents: [SheetSize.MEDIUM, SheetSize.LARGE],
        dragBar: false,
        showClose: false,
        onDisappear: (): void => {
          this.showQueue = false;
        }
      })

      }
      .width('100%')
      .height('100%')
      .backgroundColor(Color.Transparent)
      // 下滑位移挂整层:皮肤背景 + 内容一起跟手/下沉(NavDestination 已透明,露出下层页面)
      .translate({ y: this.dragY })
      .bindSheet(this.showMoreSheet, this.MoreSheet(), {
        height: 500,
        showClose: false,
        dragBar: true,
        onDisappear: (): void => {
          this.showMoreSheet = false;
        }
      })
    }
    .hideTitleBar(true)
    // 关键:NavDestination 默认底色不透明——内容下沉后露出"空背景",pop 默认横向转场再把它整体滑走
    // (0.16 实测"先下滑消失→空背景侧滑消失"双重动画)。透明化后:跟手阶段直见下层页,pop 转场全程不可见。
    .backgroundColor(Color.Transparent)
    .onReady((ctx: NavDestinationContext): void => {
      this.pathStack = ctx.pathStack;
    })
    .onBackPressed((): boolean => {
      if (this.showQueue) {
        this.showQueue = false;
        return true;
      }
      // 0.15.2:系统返回同样纵向滑出(默认 pop 横向转场已废弃)
      this.dismissAnimated();
      return true;
    })
  }

  // 下滑关闭:垂直下拉跟手,松手按位移/速度判定关闭或回弹(KB §9.4:手势对象必须 build 内构造)。
  // 位移出屏后 pop(页面已离屏,默认转场不可见)。 dismissing 防多手势实例重复触发。
  // 0.15.0 修复:此前 pop 前先 dragY=0 复位,页面瞬间回位再叠默认 pop 转场(整体右滑)——
  // 与下滑手势直觉矛盾;现在保持离屏位移直接 pop,复位延迟到转场后。
  // 0.15.2:返回键/系统返回也走同一纵向滑出动画(dismissAnimated),全页退出动作统一。
  private dismissing: boolean = false;

  private dismissAnimated(): void {
    if (this.dismissing) {
      return;
    }
    this.dismissing = true;
    const vh = px2vp(display.getDefaultDisplaySync().height);
    this.getUIContext().animateTo({ duration: 220, curve: Curve.Friction }, (): void => {
      this.dragY = vh + 60;
    });
    setTimeout((): void => {
      if (this.pathStack !== null) {
        this.pathStack.pop();
      }
    }, 230);
  }

  private dismissByGesture(vh: number): void {
    this.dismissAnimated();
  }

  // 下滑关闭跟手/判定(多手势实例共用:内容 Column + Swiper 两个页面容器)
  private dragUpdate(e: GestureEvent): void {
    if (this.showQueue || this.showMoreSheet || this.dismissing) {
      return;
    }
    const vh = px2vp(display.getDefaultDisplaySync().height);
    const dy = e.offsetY;
    // 仅向下滑跟手;削顶 55%vh——节点拖出屏后手势失灵(KB §9.4),松手动画收尾
    this.dragY = Math.min(Math.max(dy, 0), vh * 0.55);
  }

  private dragFinish(e: GestureEvent): void {
    if (this.showQueue || this.showMoreSheet || this.dismissing) {
      return;
    }
    const vh = px2vp(display.getDefaultDisplaySync().height);
    hilog.info(DOMAIN, TAG, 'dragFinish offsetY=%{public}d vel=%{public}d vh=%{public}d',
      Math.round(e.offsetY), Math.round(e.velocityY), Math.round(vh));
    if (e.offsetY > vh * 0.22 || e.velocityY > 900) {
      this.dismissByGesture(vh);
    } else {
      this.getUIContext().animateTo({ duration: 200, curve: Curve.Friction }, (): void => {
        this.dragY = 0;
      });
    }
  }

  @Builder
  PlayerBody() {
    Column() {
      Blank().height(8)

      // 封面⇄歌词:Swiper 左右滑动(封面向左滑→歌词;歌词向右滑→封面)
      Swiper(this.swiperCtrl) {
        // 第 1 页:大封面
        Column() {
          if (this.srPm !== null) {
            Image(this.srPm)
              .width(this.playerSkin === 'minimal' ? '52%' : '78%')
              .aspectRatio(1)
              .borderRadius(24)
              .objectFit(ImageFit.Cover)
              .shadow({ radius: 48, color: '#33000000', offsetX: 0, offsetY: 12 })
          } else if (this.songArt.length > 0) {
            Image(this.songArt)
              .width(this.playerSkin === 'minimal' ? '52%' : '78%')
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
            .width(this.playerSkin === 'minimal' ? '52%' : '78%')
            .aspectRatio(1)
            .borderRadius(24)
            .backgroundColor($r('app.color.badge_bg'))
            .justifyContent(FlexAlign.Center)
          }
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        // 子级垂直 pan:子手势优先于 Swiper 内建手势(方向正交),封面区下滑可关闭页面
.gesture(PanGesture({ fingers: 1, direction: PanDirection.Vertical, distance: 8 })
          .onActionUpdate((e: GestureEvent): void => {
            this.dragUpdate(e);
          })
          .onActionEnd((e: GestureEvent): void => {
            this.dragFinish(e);
          }))

        // 第 2 页:歌词
        Column({ space: 6 }) {
          LyricsPanel({ lyricText: this.lyricsNow() })
            .width('100%')
            .layoutWeight(1)
          Button(this.editLabel())
            .fontSize(11)
            .height(36)
            .fontColor($r('app.color.text_secondary'))
            .backgroundColor($r('app.color.badge_bg'))
            .responseRegion({ x: 0, y: -2, width: '100%', height: 40 }) // 最小可点目标 40vp(0.17.0)
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
        .justifyContent(FlexAlign.Center).gesture(PanGesture({ fingers: 1, direction: PanDirection.Vertical, distance: 8 })
          .onActionUpdate((e: GestureEvent): void => {
            this.dragUpdate(e);
          })
          .onActionEnd((e: GestureEvent): void => {
            this.dragFinish(e);
          }))
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

      // 信息 + 引擎徽章(全部走 @State 镜像:切歌经 onPlayerChanged 落镜像驱动刷新)
      Column({ space: 6 }) {
        Text(this.songTitle)
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.songSub)
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Row({ space: 8 }) {
          Text(this.engineMirror)
            .fontSize(10)
            .fontColor($r('app.color.badge_text'))
            .backgroundColor($r('app.color.badge_bg'))
            .borderRadius(6)
            .padding({ left: 8, right: 8, top: 2, bottom: 2 })
          if (this.songSpec.length > 0) {
            Text(this.songSpec)
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
      // 音量条 0.15.1 起收入「更多」菜单(用户约定)
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

  // 打开菜单:音量镜像对齐当前引擎值(0.15.1 音量条迁入菜单)
  private openMoreSheet(expand: string = ''): void {
    this.volMirror = Math.round(PlayerController.get().volume * 100);
    this.sheetExpand = expand;
    this.showMoreSheet = true;
  }

  @Builder
  MoreSheet() {
    Column() {
      // 自绘头部(0.17.0):系统 showClose 几何不可控——关闭钮与标题中心对齐、下方预留 8vp,全由本行决定
      Row({ space: 8 }) {
        Button({ stateEffect: true }) {
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(18)
            .fontColor([$r('app.color.text_primary')])
        }
        .width(48)
        .height(48)
        .borderRadius(24)
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          this.showMoreSheet = false;
        })
        Text($r('app.string.more_menu'))
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: 8, right: 16, top: 8 })
      List({ space: 0 }) {
        // 音量(0.15.1:自播放页主体收入此菜单;引擎流音量,无损=OHAudio 渲染流/系统=AVPlayer)
        // top 16 = 原行距 8 + 关闭钮下方预留 8vp(0.17.0)
        ListItem() {
          Row({ space: 12 }) {
            SymbolGlyph($r('sys.symbol.speaker_wave_2'))
              .fontSize(18)
              .fontColor([this.volMirror <= 0 ? $r('app.color.text_secondary') : $r('app.color.text_primary')])
            Slider({
              value: this.volMirror,
              min: 0,
              max: 100,
              step: 1,
              style: SliderStyle.OutSet
            })
              .selectedColor($r('app.color.accent'))
              .trackColor($r('app.color.divider'))
              .blockColor($r('app.color.accent'))
              .layoutWeight(1)
              .height(34)
              .onChange((value: number, mode: SliderChangeMode) => {
                this.volMirror = Math.round(value);
                if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                  PlayerController.get().setVolume(value / 100);
                }
              })
            Text(`${Math.round(this.volMirror)}%`)
              .fontSize(11)
              .fontColor($r('app.color.text_secondary'))
              .width(34)
              .textAlign(TextAlign.End)
          }
          .width('100%')
          .padding({ left: 20, right: 16, top: 16, bottom: 8 })
        }
        // 收藏
        ListItem() {
          this.SheetRow(this.favMirror ? $r('sys.symbol.heart_fill') : $r('sys.symbol.heart'),
            this.favMirror ? $r('app.string.str_favorited') : $r('app.string.str_favorites'),
            this.favMirror, (): void => {
              PlayerController.get().toggleFavorite();
            })
        }
        // 均衡器直达(0.14.0:全局 EQ,免专业页三级跳)
        ListItem() {
          this.SheetRow($r('sys.symbol.adjustment'), $r('app.string.eq_entry'), false, (): void => {
            this.showMoreSheet = false;
            const stack = this.pathStack;
            if (stack !== null) {
              stack.pushPathByName('Equalizer', null);
            }
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
        // 倍速(0.14.0:展开档位 chips,替代循环点击;label 走 SheetRow 体内直读避免快照不刷新)
        ListItem() {
          this.SheetRow($r('sys.symbol.speed_multiple'), this.speedLabel(),
            this.speedNow() !== 1.0, (): void => {
              this.sheetExpand = this.sheetExpand === 'speed' ? '' : 'speed';
            }, true, this.sheetExpand === 'speed', 'speed')
        }
        if (this.sheetExpand === 'speed') {
          ListItem() {
            Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
              ForEach(SPEED_OPTIONS, (v: number) => {
                Button(`${v}x`)
                  .fontSize(12)
                  .fontColor(this.speedNow() === v ? $r('app.color.on_accent') : $r('app.color.text_primary'))
                  .backgroundColor(this.speedNow() === v ? $r('app.color.accent') : $r('app.color.badge_bg'))
                  .borderRadius(14)
                  .height(36)
                  .margin({ right: 8, bottom: 8, left: 4 })
                  // 最小可点目标 40vp:视觉 36,热区纵向外扩(0.17.0)
                  .responseRegion({ x: 0, y: -2, width: '100%', height: 40 })
                  .onClick(() => {
                    PlayerController.get().setSpeed(v);
                    this.sheetExpand = '';
                  })
              }, (v: number): string => `spd_${v}`)
            }
            .width('100%')
            .padding({ left: 16, right: 16, bottom: 4 })
          }
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
        // 睡眠定时器(0.14.0:展开档位 chips;到点前 30s 渐弱;label 体内直读)
        ListItem() {
          this.SheetRow($r('sys.symbol.timer'), this.sleepLabel(),
            PlayerController.get().sleepRemainMin() > 0, (): void => {
              this.sheetExpand = this.sheetExpand === 'sleep' ? '' : 'sleep';
            }, true, this.sheetExpand === 'sleep', 'sleep')
        }
        if (this.sheetExpand === 'sleep') {
          ListItem() {
            Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
              ForEach(SLEEP_OPTIONS, (n: number) => {
                Button(this.sleepChipLabel(n))
                  .fontSize(12)
                  .fontColor(this.sleepChipActive(n) ? $r('app.color.on_accent') : $r('app.color.text_primary'))
                  .backgroundColor(this.sleepChipActive(n) ? $r('app.color.accent') : $r('app.color.badge_bg'))
                  .borderRadius(14)
                  .height(36)
                  .margin({ right: 8, bottom: 8, left: 4 })
                  // 最小可点目标 40vp:视觉 36,热区纵向外扩(0.17.0)
                  .responseRegion({ x: 0, y: -2, width: '100%', height: 40 })
                  .onClick(() => {
                    PlayerController.get().setSleepTimer(n);
                    this.sheetExpand = '';
                  })
              }, (n: number): string => `slp_${n}`)
            }
            .width('100%')
            .padding({ left: 16, right: 16, bottom: 4 })
          }
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

  // 展开指示:可展开行右侧 chevron(expanded 展开态朝上)。
  // labelKind 非空时 label/accent 在 builder 体内重新求值(@Builder 参数是快照,KB §8.2;
  // 倍速/睡眠档位选择后 playerVer/sleepVer bump 驱动 sheet 内容重跑,体内直读才能刷新)。
  @Builder
  SheetRow(icon: Resource, label: ResourceStr, accent: boolean, onTap: () => void,
    expandable: boolean = false, expanded: boolean = false, labelKind: string = '') {
    Row({ space: 12 }) {
      SymbolGlyph(icon)
        .fontSize(18)
        .fontColor([this.rowAccent(labelKind, accent) ? $r('app.color.accent') : $r('app.color.text_primary')])
      Text(this.rowLabel(labelKind, label))
        .fontSize(14)
        .fontColor(this.rowAccent(labelKind, accent) ? $r('app.color.accent') : $r('app.color.text_primary'))
        .layoutWeight(1)
      if (expandable) {
        SymbolGlyph(expanded ? $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_down'))
          .fontSize(13)
          .fontColor([$r('app.color.text_secondary')])
      }
    }
    .width('100%')
    .padding({ left: 20, right: 16, top: 12, bottom: 12 })
    .onClick(() => {
      onTap();
    })
  }

  // 播放队列(0.15.2 改 bindSheet 承载:高度/圆角/动画由 sheet 管理,内容只管列表)
  @Builder
  QueueDrawer() {
    Column() {
      Row() {
        Text($r('app.string.current_queue'))
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
          .padding({ left: 8 })
        // 多队列管理(原队列页签入口迁移至此);热区 40vp(0.17.0 最小可点目标)
        Button({ stateEffect: true }) {
          SymbolGlyph($r('sys.symbol.square_stack_3d'))
            .fontSize(18)
            .fontColor([$r('app.color.text_primary')])
        }
        .width(40)
        .height(40)
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          this.showQueue = false;
          this.pathStack?.pushPathByName('QueueBoard', null);
        })
        // 循环模式 + 播完停止 + 推进边界(原队列页签菜单迁移)
        Button({ stateEffect: true }) {
          SymbolGlyph(this.modeIcon())
            .fontSize(18)
            .fontColor([this.modeAccent() ? $r('app.color.accent') : $r('app.color.text_primary')])
        }
        .width(40)
        .height(40)
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          QueueService.get().cyclePlayMode();
        })
        // 睡眠定时器(原队列页签入口迁移;0.14.0 起档位选择在更多菜单弹层内)
        Button({ stateEffect: true }) {
          SymbolGlyph($r('sys.symbol.timer'))
            .fontSize(18)
            .fontColor([PlayerController.get().sleepRemainMin() > 0 ? $r('app.color.accent') : $r('app.color.text_primary')])
        }
        .width(40)
        .height(40)
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          this.showQueue = false;
          this.openMoreSheet('sleep');
        })
        Button({ stateEffect: true }) {
          SymbolGlyph($r('sys.symbol.trash'))
            .fontSize(18)
            .fontColor([$r('app.color.text_secondary')])
        }
        .width(40)
        .height(40)
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          QueueService.get().clear();
        })
        Button({ stateEffect: true }) {
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(18)
            .fontColor([$r('app.color.text_secondary')])
        }
        .width(40)
        .height(40)
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          this.showQueue = false;
        })
      }
      .width('100%')
      .padding({ left: 8, right: 8, top: 12, bottom: 4 })

      List({ space: 0 }) {
        ForEach(this.queueItems(), (s: Song, i: number) => {
          ListItem() {
            Row({ space: 10 }) {
              Text(String(i + 1))
                .fontSize(11)
                .fontColor(i === this.qIndexMirror ? $r('app.color.accent') : $r('app.color.text_secondary'))
                .width(24)
                .textAlign(TextAlign.Center)
              Column({ space: 2 }) {
                Text(s.displayTitle())
                  .fontSize(14)
                  .fontColor(i === this.qIndexMirror ? $r('app.color.accent') : $r('app.color.text_primary'))
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
    .height('100%')
    .backgroundColor($r('app.color.card_bg'))
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

  // SheetRow 动态 label/accent(体内直读入口)
  private rowLabel(kind: string, fallback: ResourceStr): ResourceStr {
    if (kind === 'speed') {
      return this.speedLabel();
    }
    if (kind === 'sleep') {
      return this.sleepLabel();
    }
    return fallback;
  }

  private rowAccent(kind: string, fallback: boolean): boolean {
    if (kind === 'speed') {
      return PlayerController.get().speed !== 1.0;
    }
    if (kind === 'sleep') {
      return PlayerController.get().sleepRemainMin() > 0;
    }
    return fallback;
  }

  private sliderValue(): number {
    if (this.seeking) {
      return Math.round(this.seekPreviewMs);
    }
    return this.posMs;
  }

  private durMs(): number {
    return Math.max(1, PlayerController.get().durationMs);
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

  // 睡眠定时档位文案(0.14.0 弹层)
  private sleepChipLabel(n: number): ResourceStr {
    if (n <= 0) {
      return $r('app.string.sleep_off');
    }
    return L($r('app.string.sleep_chip_min'), String(n));
  }

  private sleepChipActive(n: number): boolean {
    const cur = PlayerController.get().sleepRemainMin();
    if (n <= 0) {
      return cur <= 0;
    }
    // 当前剩余与档位同段视为选中(设置后分钟数递减)
    return cur > n - 15 && cur <= n;
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

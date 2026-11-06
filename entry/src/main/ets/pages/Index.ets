// 应用根:Navigation + 底部 HdsTabs(音乐库/队列/设置)+ 迷你播放条(悬浮)。
import { hilog } from '@kit.PerformanceAnalysisKit';
import { HdsTabs, HdsTabsFloatingStyle, hdsMaterial, HdsBarLayoutMode, HdsTabsController, HdsBarStyle } from '@kit.UIDesignKit';
import { SymbolGlyphModifier } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { PlayerController } from '../service/PlayerController';
import { SongRow } from '../components/SongRow';
import { AppTheme, SafeAreaResult } from '../common/Theme';
import { BarCollapse } from '../common/BarCollapse';
import { MiniPlayer } from '../components/MiniPlayer';
import { LibraryTab } from './library/LibraryTab';
import { ProTab } from './pro/ProTab';
import { MineTab } from './mine/MineTab';
import { SettingsDest } from './settings/SettingsTab';
import { FullPlayerDest } from './player/FullPlayer';
import { LyricsEditorDest } from './player/LyricsEditor';
import { SongListDest } from './detail/SongList';
import { EqualizerDest } from './settings/Equalizer';
import { AboutDest } from './settings/About';
import { SearchDest } from './detail/Search';
import { QueueBoardDest } from './queue/QueueBoard';
import { TagEditorDest } from './detail/TagEditor';
import { DuplicatesDest } from './library/Duplicates';

const TAG = '[Timbrava][Index]';
const DOMAIN = 0x0001;

// 26-2 全局复用池宿主:root 常驻,shared 池接收 SongRow(@Reusable)回收实例——
// 曲库/歌单/搜索/队列四处滚动节点跨页面互相复用(26 能力;24 运行时忽略未知 option)。
@Entry
@Component({ freezeWhenInactive: false, reusePool: 'shared', poolAccepts: [SongRow] })
struct Index {
  @Provide navStack: NavPathStack = new NavPathStack();
  @StorageProp('playerVer') playerVer: number = 0;
  @StorageProp('posVer') posVer: number = 0;
  @StorageProp('themeVer') themeVer: number = 0;
  @State activeTab: number = 0;
  @State topSafe: number = 36;
  @State bottomSafe: number = 28;
  private hdsController: HdsTabsController = new HdsTabsController();
  // barFloatingStyle 样式对象记忆化:每次 build 生成新对象会让 HdsTabs 重新初始化迷你栏
  // (回落官方默认折叠态)——切页签 activeTab 变化触发重建即复现"折叠态被重置"(0.15.0 修复)
  private floatingStyleCache: HdsTabsFloatingStyle | null = null;

  aboutToAppear(): void {
    AppStorage.setOrCreate('navStack', this.navStack);
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    AppTheme.safeAreas(ctx).then((r: SafeAreaResult): void => {
      this.topSafe = r.topVp;
      this.bottomSafe = r.bottomVp;
      hilog.info(DOMAIN, TAG, 'safe areas top=%{public}d bottom=%{public}d', Math.round(r.topVp), Math.round(r.bottomVp));
    });
    // 滚动折叠迷你条(华为音乐共识交互):页签内容滚动方向 → applyMiniBarStyle 带默认动效折叠/展开
    BarCollapse.bind((collapsed: boolean): void => {
      if (!this.hasSong()) {
        return; // 无播放内容时迷你条为空壳,不做折叠动画
      }
      hilog.info(DOMAIN, TAG, 'applyMiniBarStyle %{public}s', collapsed ? 'COLLAPSE' : 'EXPAND');
      this.hdsController.applyMiniBarStyle(collapsed ? HdsBarStyle.COLLAPSE : HdsBarStyle.EXPAND);
    });
  }

  pageBg(): ResourceColor {
    const override = AppStorage.get<string>('themePageBg') ?? '';
    return override.length > 0 ? override : $r('app.color.page_bg');
  }

  build() {
    Navigation(this.navStack) {
      Stack({ alignContent: Alignment.Bottom }) {
        HdsTabs({ barPosition: BarPosition.End, index: this.activeTab, controller: this.hdsController }) {
          TabContent() {
            LibraryTab()
          }
          .tabBar(this.tabIcon($r('sys.symbol.music_note_list'), $r('app.string.tab_library'), 0))

          TabContent() {
            ProTab()
          }
          .tabBar(this.tabIcon($r('sys.symbol.waveform'), $r('app.string.tab_pro'), 1))

          TabContent() {
            MineTab()
          }
          .tabBar(this.tabIcon($r('sys.symbol.person'), $r('app.string.tab_mine'), 2))
        }
        .vertical(false)
        .scrollable(true)
        .barOverlap(true) // 悬浮约束:页签栏叠加在内容之上,barFloatingStyle 生效前提
        .barFloatingStyle(this.ensureFloatingStyle())
        .onChange((index: number) => {
          this.activeTab = index;
          // 0.15.0 实测:HdsTabs 页签切换动画结束后会把迷你栏内部重置回 pill+圆钮形态,
  // 且经 onBarStyleChange 把折叠镜像回写(污染用户态)——切换前先记录,重置后恢复断言
          const keepCollapsed = BarCollapse.isCollapsed();
          setTimeout((): void => {
            if (PlayerController.get().currentSong === null) {
              return;
            }
            BarCollapse.sync(keepCollapsed, false);
            this.hdsController.applyMiniBarStyle(keepCollapsed ? HdsBarStyle.COLLAPSE : HdsBarStyle.EXPAND);
            hilog.info(DOMAIN, TAG, 'reassert miniBar %{public}s after tab switch',
              keepCollapsed ? 'COLLAPSE' : 'EXPAND');
          }, 900);
        })
        .width('100%')
        .height('100%')
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.pageBg())
    }
    .navDestination(this.pagesMap)
    .hideTitleBar(true)
    // 分栏(#54):宽屏(≥600vp)自动 Split(库列表 + 右侧详情),手机保持 Stack
    .mode(NavigationMode.Auto)
    .navBarWidth('46%')
    .minContentWidth(360)
  }

  // 首次构建生成并缓存;后续 rebuild 返回同一引用,避免迷你栏被重新初始化
  private ensureFloatingStyle(): HdsTabsFloatingStyle {
    if (this.floatingStyleCache !== null) {
      return this.floatingStyleCache;
    }
    const st: HdsTabsFloatingStyle = {
      barSideMargin: 16,
      barBottomMargin: 28, // 抬起高度 28vp
      // 半透明渐变蒙版(参考 PixLume):浅色/深色各一份 token,高度=栏高56+16
      gradientMask: { maskColor: $r('app.color.tab_bar_mask'), maskHeight: 72 },
      systemMaterialEffect: { // 沉浸光感材质
        materialType: hdsMaterial.MaterialType.IMMERSIVE,
        materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
      },
      // 迷你栏(HdsTabs 6.1.0(23) 能力):音乐迷你条悬浮于页签栏上方,VERTICAL 两行排布
      miniBar: {
        miniBarBuilder: (): void => {
          this.miniBarBuilder();
        },
        barLayoutMode: HdsBarLayoutMode.VERTICAL,
        // 初始展开(官方默认折叠);滚动折叠由 BarCollapse 驱动 applyMiniBarStyle
        miniBarStyle: HdsBarStyle.EXPAND,
        onBarStyleChange: (style: HdsBarStyle): void => {
          // 折叠态镜像回写(含 USER_CLICK 点击折叠条原生展开),仅同步不通知,避免 apply 回环
          BarCollapse.sync(style === HdsBarStyle.COLLAPSE, false);
        }
      }
    };
    this.floatingStyleCache = st;
    return st;
  }

  @Builder
  miniBarBuilder() {
    MiniPlayer()
  }

  @Builder
  tabIcon(res: Resource, label: ResourceStr, idx: number) {
    Column({ space: 3 }) {
      SymbolGlyph(res)
        .fontSize(22)
        .fontColor([this.activeTab === idx ? $r('app.color.accent') : $r('app.color.text_secondary')])
      Text(label)
        .fontSize(10)
        .fontColor(this.activeTab === idx ? $r('app.color.accent') : $r('app.color.text_secondary'))
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .height(52)
  }

  private hasSong(): boolean {
    return PlayerController.get().currentSong !== null;
  }

  private isPlayingNow(): boolean {
    return PlayerController.get().isPlaying;
  }

  private currentTitle(): string {
    const s = PlayerController.get().currentSong;
    return s !== null ? s.displayTitle() : '';
  }

  private currentArtist(): string {
    const s = PlayerController.get().currentSong;
    return s !== null ? s.displayArtist() : '';
  }

  private currentArt(): string {
    const s = PlayerController.get().currentSong;
    return s !== null ? s.artPath : '';
  }

  private posMs(): number {
    return PlayerController.get().positionMs;
  }

  private durMs(): number {
    return PlayerController.get().durationMs;
  }

  // 路由表(if/else if 链)
  @Builder
  pagesMap(name: string) {
    if (name === 'FullPlayer') {
      FullPlayerDest()
    } else if (name === 'LyricsEditor') {
      LyricsEditorDest()
    } else if (name === 'SongList') {
      SongListDest()
    } else if (name === 'Equalizer') {
      EqualizerDest()
    } else if (name === 'About') {
      AboutDest()
    } else if (name === 'Search') {
      SearchDest()
    } else if (name === 'QueueBoard') {
      QueueBoardDest()
    } else if (name === 'TagEditor') {
      TagEditorDest()
    } else if (name === 'Duplicates') {
      DuplicatesDest()
    } else if (name === 'Settings') {
      SettingsDest()
    }
  }
}

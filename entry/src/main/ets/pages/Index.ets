// 应用根:Navigation + 底部 HdsTabs(音乐库/队列/设置)+ 迷你播放条(悬浮)。
import { hilog } from '@kit.PerformanceAnalysisKit';
import { HdsTabs, HdsTabsFloatingStyle, hdsMaterial } from '@kit.UIDesignKit';
import { SymbolGlyphModifier } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { PlayerController } from '../service/PlayerController';
import { AppTheme, SafeAreaResult } from '../common/Theme';
import { MiniPlayer } from '../components/MiniPlayer';
import { LibraryTab } from './library/LibraryTab';
import { QueueTab } from './queue/QueueTab';
import { SettingsTab } from './settings/SettingsTab';
import { FullPlayerDest } from './player/FullPlayer';
import { LyricsEditorDest } from './player/LyricsEditor';
import { SongListDest } from './detail/SongList';
import { FolderTreeDest } from './detail/FolderTree';
import { ScanSettingsDest } from './settings/ScanSettings';
import { EqualizerDest } from './settings/Equalizer';
import { AboutDest } from './settings/About';
import { SearchDest } from './detail/Search';
import { QueueBoardDest } from './queue/QueueBoard';
import { TagEditorDest } from './detail/TagEditor';
import { DuplicatesDest } from './library/Duplicates';

const TAG = '[Timbrava][Index]';
const DOMAIN = 0x0001;

@Entry
@Component
struct Index {
  @Provide navStack: NavPathStack = new NavPathStack();
  @StorageProp('playerVer') playerVer: number = 0;
  @StorageProp('posVer') posVer: number = 0;
  @StorageProp('themeVer') themeVer: number = 0;
  @State activeTab: number = 0;
  @State topSafe: number = 36;
  @State bottomSafe: number = 28;

  aboutToAppear(): void {
    AppStorage.setOrCreate('navStack', this.navStack);
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    AppTheme.safeAreas(ctx).then((r: SafeAreaResult): void => {
      this.topSafe = r.topVp;
      this.bottomSafe = r.bottomVp;
      hilog.info(DOMAIN, TAG, 'safe areas top=%{public}d bottom=%{public}d', Math.round(r.topVp), Math.round(r.bottomVp));
    });
  }

  pageBg(): ResourceColor {
    const override = AppStorage.get<string>('themePageBg') ?? '';
    return override.length > 0 ? override : $r('app.color.page_bg');
  }

  build() {
    Navigation(this.navStack) {
      Stack({ alignContent: Alignment.Bottom }) {
        HdsTabs({ barPosition: BarPosition.End, index: this.activeTab }) {
          TabContent() {
            LibraryTab()
          }
          .tabBar(this.tabIcon($r('sys.symbol.music_note_list'), $r('app.string.tab_library'), 0))

          TabContent() {
            QueueTab()
          }
          .tabBar(this.tabIcon($r('sys.symbol.list_bullet'), $r('app.string.str_queue'), 1))

          TabContent() {
            SettingsTab()
          }
          .tabBar(this.tabIcon($r('sys.symbol.gearshape'), $r('app.string.str_settings'), 2))
        }
        .vertical(false)
        .scrollable(true)
        .barOverlap(true) // 悬浮约束:页签栏叠加在内容之上,barFloatingStyle 生效前提
        .barFloatingStyle(this.floatingStyle())
        .onChange((index: number) => {
          this.activeTab = index;
        })
        .width('100%')
        .height('100%')

        MiniPlayer()
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

  private floatingStyle(): HdsTabsFloatingStyle {
    const st: HdsTabsFloatingStyle = {
      barSideMargin: 16,
      barBottomMargin: 28, // 抬起高度 28vp
      // 半透明渐变蒙版(参考 PixLume):浅色/深色各一份 token,高度=栏高56+16
      gradientMask: { maskColor: $r('app.color.tab_bar_mask'), maskHeight: 72 },
      systemMaterialEffect: { // 沉浸光感材质
        materialType: hdsMaterial.MaterialType.IMMERSIVE,
        materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
      }
    };
    return st;
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
    } else if (name === 'FolderTree') {
      FolderTreeDest()
    } else if (name === 'ScanSettings') {
      ScanSettingsDest()
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
    }
  }
}

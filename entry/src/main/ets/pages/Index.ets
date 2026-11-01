// 应用根:Navigation + 底部 HdsTabs(音乐库/队列/设置)+ 迷你播放条(悬浮)。
import { hilog } from '@kit.PerformanceAnalysisKit';
import { HdsTabs } from '@kit.UIDesignKit';
import { SymbolGlyphModifier } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { PlayerController } from '../service/PlayerController';
import { AppTheme, SafeAreaResult } from '../common/Theme';
import { formatDuration } from '../data/Model';
import { LibraryTab } from './library/LibraryTab';
import { QueueTab } from './queue/QueueTab';
import { SettingsTab } from './settings/SettingsTab';
import { FullPlayerDest } from './player/FullPlayer';
import { SongListDest } from './detail/SongList';
import { FolderTreeDest } from './detail/FolderTree';
import { ScanSettingsDest } from './settings/ScanSettings';
import { AboutDest } from './settings/About';

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
          .tabBar(new BottomTabBarStyle(this.tabSymbol($r('sys.symbol.music_note_list')), '音乐库'))

          TabContent() {
            QueueTab()
          }
          .tabBar(new BottomTabBarStyle(this.tabSymbol($r('sys.symbol.list_bullet')), '队列'))

          TabContent() {
            SettingsTab()
          }
          .tabBar(new BottomTabBarStyle(this.tabSymbol($r('sys.symbol.gearshape')), '设置'))
        }
        .vertical(false)
        .scrollable(true)
        .onChange((index: number) => {
          this.activeTab = index;
        })
        .width('100%')
        .height('100%')

        this.MiniPlayer()
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.pageBg())
    }
    .navDestination(this.pagesMap)
    .hideTitleBar(true)
    .mode(NavigationMode.Stack)
  }

  @Builder
  MiniPlayer() {
    Row({ space: 12 }) {
      if (this.currentArt().length > 0) {
        Image(this.currentArt())
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
        Text(this.currentTitle())
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.currentArtist() + ' · ' + formatDuration(this.posMs()) + ' / ' + formatDuration(this.durMs()))
          .fontSize(11)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Button({ stateEffect: true }) {
        SymbolGlyph(this.isPlayingNow() ? $r('sys.symbol.pause_fill') : $r('sys.symbol.play_fill'))
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
    .width('96%')
    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
    .borderRadius(16)
    .backgroundColor($r('app.color.mini_player_bg'))
    .shadow({ radius: 24, color: '#22000000', offsetX: 0, offsetY: 4 })
    .margin({ bottom: this.bottomSafe + 66 })
    .visibility(this.hasSong() ? Visibility.Visible : Visibility.None)
    .onClick(() => {
      this.navStack.pushPathByName('FullPlayer', null);
    })
  }

  private tabSymbol(res: Resource): TabBarSymbol {
    const sym = new TabBarSymbol();
    sym.normal = new SymbolGlyphModifier(res);
    sym.selected = new SymbolGlyphModifier(res);
    return sym;
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
    } else if (name === 'SongList') {
      SongListDest()
    } else if (name === 'FolderTree') {
      FolderTreeDest()
    } else if (name === 'ScanSettings') {
      ScanSettingsDest()
    } else if (name === 'About') {
      AboutDest()
    }
  }
}

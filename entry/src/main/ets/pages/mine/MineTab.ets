// 我的页(0.17.0):统计四宫格 + 智能列表入口 + 添加歌曲|曲库管理并列 + 歌单卡片(延伸到屏幕底部)。
// 变更:设置入口收进右上角四点钮(华为"更多选项"语义),通用区移除(关于已在设置页内);
// 统计计数改走 @State + statsVer 广播(此前 build 直读且刷新只更新总时长,几乎不更新)。
import { common } from '@kit.AbilityKit';
import { picker } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Db } from '../../data/Db';
import { LibraryStore } from '../../data/LibraryStore';
import { ScanService } from '../../data/ScanService';
import { SongListParam } from '../../components/SongRow';
import { PlayHistoryParam } from '../detail/PlayHistory';
import { PlaylistsTab } from '../playlist/PlaylistsTab';
import { AppTheme, SafeAreaResult } from '../../common/Theme';
import { formatDuration } from '../../data/Model';
import { L } from '../../common/Lang';
import { BarCollapse } from '../../common/BarCollapse';

const TAG = '[Timbrava][MineTab]';
const DOMAIN = 0x0001;

@Component
export struct MineTab {
  @StorageProp('libVer') @Watch('onLibChanged') libVer: number = 0;
  @StorageProp('statsVer') @Watch('onStatsChanged') statsVer: number = 0;
  @StorageProp('themePageBg') themePageBg: string = '';
  @StorageProp('bottomSafeVp') bottomSafeVp: number = 28;
  @State topSafe: number = 36;
  // 统计必须落 @State(0.17.0 #3):@Builder 参数/直读非可观察,不落 @State 则导入/播放后纹丝不动
  @State songCount: number = 0;
  @State albumCount: number = 0;
  @State artistCount: number = 0;
  @State totalMs: number = 0;

  onLibChanged(): void {
    this.refresh();
  }

  onStatsChanged(): void {
    this.refresh();
  }

  aboutToAppear(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    AppTheme.safeAreas(ctx).then((r: SafeAreaResult): void => {
      this.topSafe = r.topVp;
    });
    this.refresh();
  }

  private refresh(): void {
    const lib = LibraryStore.get();
    this.songCount = lib.songs.length;
    this.albumCount = lib.albums.length;
    this.artistCount = lib.artists.length;
    Db.get().getPlayStatsTotal().then((ms: number): void => {
      this.totalMs = ms;
    });
  }

  private pageBg(): ResourceColor {
    return this.themePageBg.length > 0 ? this.themePageBg : $r('app.color.page_bg');
  }

  private nav(): NavPathStack {
    const stack = AppStorage.get<NavPathStack>('navStack');
    return stack !== undefined && stack !== null ? stack : new NavPathStack();
  }

  // 添加歌曲(华为音乐共识:我的页导入入口,选完即入库,无需扫描)
  private async addSongs(): Promise<void> {
    try {
      const audioPicker = new picker.AudioViewPicker();
      const opts = new picker.AudioSelectOptions();
      opts.maxSelectNumber = 500;
      const uris: Array<string> = await audioPicker.select(opts);
      if (uris.length === 0) {
        return;
      }
      const added = await ScanService.get().addPickedAudioUris(uris);
      this.getUIContext().getPromptAction().showToast({
        message: added > 0 ? L($r('app.string.import_added'), String(added)) : $r('app.string.import_none')
      });
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'addSongs fail %{public}s', (e as Error).message);
    }
  }

  private openFavorites(): void {
    this.nav().pushPathByName('SongList', SongListParam.favorites());
  }

  private totalLabel(): string {
    return formatDuration(this.totalMs);
  }

  build() {
    Column() {
      Row({ space: 8 }) {
        Text($r('app.string.tab_mine'))
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
        // 四点钮(0.17.0 #6):华为应用"展开更多选项"语义,直达设置页;尺寸对齐标准返回钮热区
        Button({ stateEffect: true }) {
          SymbolGlyph($r('sys.symbol.dot_grid_2x2'))
            .fontSize(20)
            .fontColor([$r('app.color.text_primary')])
        }
        .width(40)
        .height(40)
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          this.nav().pushPathByName('Settings', null);
        })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: this.topSafe + 8, bottom: 8 })

      Scroll() {
        Column({ space: 12 }) {
          // 曲库统计四宫格(0.17.0 内联:Stat 抽 @Builder 按值传参是快照,totalMs 异步落地后不刷新——KB §8.2)
          Row({ space: 8 }) {
            Column() {
              Text(this.songCount.toString())
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.accent'))
              Text($r('app.string.str_songs'))
                .fontSize(10)
                .fontColor($r('app.color.text_secondary'))
                .margin({ top: 2 })
            }
            .layoutWeight(1)
            .padding({ top: 10, bottom: 10 })
            .borderRadius(14)
            .backgroundColor($r('app.color.card_bg'))
            Column() {
              Text(this.albumCount.toString())
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.accent'))
              Text($r('app.string.str_albums'))
                .fontSize(10)
                .fontColor($r('app.color.text_secondary'))
                .margin({ top: 2 })
            }
            .layoutWeight(1)
            .padding({ top: 10, bottom: 10 })
            .borderRadius(14)
            .backgroundColor($r('app.color.card_bg'))
            Column() {
              Text(this.artistCount.toString())
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.accent'))
              Text($r('app.string.str_artists'))
                .fontSize(10)
                .fontColor($r('app.color.text_secondary'))
                .margin({ top: 2 })
            }
            .layoutWeight(1)
            .padding({ top: 10, bottom: 10 })
            .borderRadius(14)
            .backgroundColor($r('app.color.card_bg'))
            Column() {
              Text(this.totalLabel())
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.accent'))
              Text($r('app.string.mine_stats_total'))
                .fontSize(10)
                .fontColor($r('app.color.text_secondary'))
                .margin({ top: 2 })
            }
            .layoutWeight(1)
            .padding({ top: 10, bottom: 10 })
            .borderRadius(14)
            .backgroundColor($r('app.color.card_bg'))
          }
          .width('100%')
          .padding({ left: 16, right: 16 })

          // 统计回顾入口(最近/最常播放页)+收藏
          Row({ space: 8 }) {
            Button($r('app.string.history_recent'))
              .fontSize(12)
              .fontColor($r('app.color.text_primary'))
              .backgroundColor($r('app.color.badge_bg'))
              .borderRadius(20)
              .height(40)
              .layoutWeight(1)
              .onClick(() => {
                this.nav().pushPathByName('PlayHistory', new PlayHistoryParam(0));
              })
            Button($r('app.string.history_most'))
              .fontSize(12)
              .fontColor($r('app.color.text_primary'))
              .backgroundColor($r('app.color.badge_bg'))
              .borderRadius(20)
              .height(40)
              .layoutWeight(1)
              .onClick(() => {
                this.nav().pushPathByName('PlayHistory', new PlayHistoryParam(1));
              })
            Button($r('app.string.str_favorites'))
              .fontSize(12)
              .fontColor($r('app.color.text_primary'))
              .backgroundColor($r('app.color.badge_bg'))
              .borderRadius(20)
              .height(40)
              .layoutWeight(1)
              .onClick(() => {
                this.openFavorites();
              })
          }
          .width('100%')
          .padding({ left: 16, right: 16 })

          // 音乐库:添加歌曲 | 曲库管理(等宽并列,0.17.0 #5)
          Column({ space: 4 }) {
            Text($r('app.string.mine_library'))
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .padding({ left: 4, top: 4 })
            Row() {
              this.NavItemBtn($r('app.string.add_songs'), (): void => {
                this.addSongs();
              })
              Divider()
                .vertical(true)
                .height(24)
                .color($r('app.color.divider'))
              this.NavItemBtn($r('app.string.lib_manage'), (): void => {
                this.nav().pushPathByName('LibraryManage', null);
              })
            }
            .width('100%')
            .padding({ left: 4, right: 4, top: 4, bottom: 4 })
          }
          .width('100%')
          .padding({ left: 16, right: 16 })

          // 歌单卡片(0.17.0 #2):左上角"+"新建,容器延伸到屏幕最底部
          PlaylistsTab({ mode: 'card' })
            .padding({ left: 16, right: 16 })
        }
        .width('100%')
        .padding({ left: 0, right: 0 })
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      .align(Alignment.Top)
      // 滚动折叠迷你条:实测 SDK 26.0.0.105 模拟器 Scroll.onDidScroll 不触发,onWillScroll 每帧可达
      .onWillScroll((_x: number, y: number): void => {
        BarCollapse.feed(y);
      })
      .onScrollStop((): void => {
        BarCollapse.settle();
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.pageBg())
  }

  // 卡内等宽入口钮(添加歌曲 / 曲库管理)
  @Builder
  NavItemBtn(title: ResourceStr, onTap: () => void) {
    Row() {
      Text(title)
        .fontSize(15)
        .fontColor($r('app.color.text_primary'))
    }
    .layoutWeight(1)
    .height(40)
    .justifyContent(FlexAlign.Center)
    .borderRadius(12)
    .onClick(() => {
      onTap();
    })
  }
}

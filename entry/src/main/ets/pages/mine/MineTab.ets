// 我的页:曲库统计 + 智能列表入口 + 歌单 + 添加歌曲 + 通用入口(设置/关于)。设置降级为二级路由页。
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

const TAG = '[Timbrava][MineTab]';
const DOMAIN = 0x0001;

@Component
export struct MineTab {
  @StorageProp('libVer') @Watch('onLibChanged') libVer: number = 0;
  @StorageProp('themePageBg') themePageBg: string = '';
  @StorageProp('bottomSafeVp') bottomSafeVp: number = 28;
  @State topSafe: number = 36;
  @State totalMs: number = 0;

  onLibChanged(): void {
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
      Text($r('app.string.tab_mine'))
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
        .padding({ left: 16, right: 16, top: this.topSafe + 8, bottom: 8 })

      Scroll() {
        Column({ space: 12 }) {
          // 曲库统计四宫格
          Row({ space: 8 }) {
            this.Stat(LibraryStore.get().songs.length.toString(), $r('app.string.str_songs'))
            this.Stat(LibraryStore.get().albums.length.toString(), $r('app.string.str_albums'))
            this.Stat(LibraryStore.get().artists.length.toString(), $r('app.string.str_artists'))
            this.Stat(this.totalLabel(), $r('app.string.mine_stats_total'))
          }
          .width('100%')
          .padding({ left: 16, right: 16 })

          // 统计回顾入口(最近/最常播放页)+收藏
          Row({ space: 8 }) {
            Button($r('app.string.history_recent'))
              .fontSize(12)
              .fontColor($r('app.color.text_primary'))
              .backgroundColor($r('app.color.badge_bg'))
              .borderRadius(14)
              .height(32)
              .layoutWeight(1)
              .onClick(() => {
                this.nav().pushPathByName('PlayHistory', new PlayHistoryParam(0));
              })
            Button($r('app.string.history_most'))
              .fontSize(12)
              .fontColor($r('app.color.text_primary'))
              .backgroundColor($r('app.color.badge_bg'))
              .borderRadius(14)
              .height(32)
              .layoutWeight(1)
              .onClick(() => {
                this.nav().pushPathByName('PlayHistory', new PlayHistoryParam(1));
              })
            Button($r('app.string.str_favorites'))
              .fontSize(12)
              .fontColor($r('app.color.text_primary'))
              .backgroundColor($r('app.color.badge_bg'))
              .borderRadius(14)
              .height(32)
              .layoutWeight(1)
              .onClick(() => {
                this.openFavorites();
              })
          }
          .width('100%')
          .padding({ left: 16, right: 16 })

          // 音乐库(添加歌曲:即选即入库)
          Column({ space: 4 }) {
            Text($r('app.string.mine_library'))
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .padding({ left: 4, top: 4 })
            Column() {
              this.NavItem($r('app.string.add_songs'), '', (): void => {
                this.addSongs();
              })
            }
            .width('100%')
            .padding(12)
            .borderRadius(16)
            .backgroundColor($r('app.color.card_bg'))
          }
          .width('100%')
          .padding({ left: 16, right: 16 })

          // 歌单(嵌入模式:无页头,自适应高度)
          PlaylistsTab({ embed: true })

          // 通用
          Column({ space: 4 }) {
            Text($r('app.string.mine_general'))
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .padding({ left: 4, top: 4 })
            Column() {
              this.NavItem($r('app.string.str_settings'), '', (): void => {
                this.nav().pushPathByName('Settings', null);
              })
              Divider().color($r('app.color.divider')).margin({ left: 0 })
              this.NavItem($r('app.string.str_about'), '', (): void => {
                this.nav().pushPathByName('About', null);
              })
            }
            .width('100%')
            .padding(12)
            .borderRadius(16)
            .backgroundColor($r('app.color.card_bg'))
          }
          .width('100%')
          .padding({ left: 16, right: 16 })

          Blank().height(this.bottomSafeVp + 140)
        }
        .width('100%')
        .padding({ left: 0, right: 0 })
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.pageBg())
  }

  @Builder
  Stat(value: string, label: ResourceStr) {
    Column() {
      Text(value)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.accent'))
      Text(label)
        .fontSize(10)
        .fontColor($r('app.color.text_secondary'))
        .margin({ top: 2 })
    }
    .layoutWeight(1)
    .padding({ top: 10, bottom: 10 })
    .borderRadius(14)
    .backgroundColor($r('app.color.card_bg'))
  }

  @Builder
  NavItem(title: ResourceStr, sub: string, onTap: () => void) {
    Row({ space: 12 }) {
      Column({ space: 2 }) {
        Text(title)
          .fontSize(15)
          .fontColor($r('app.color.text_primary'))
        if (sub.length > 0) {
          Text(sub)
            .fontSize(11)
            .fontColor($r('app.color.text_secondary'))
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(14)
        .fontColor([$r('app.color.text_secondary')])
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
    .onClick(() => {
      onTap();
    })
  }
}

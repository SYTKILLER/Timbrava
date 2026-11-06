// 歌单(0.17.0 双形态):
// - mode 'page':曲库"歌单"分区内容(满高滚动列表,无页头,语境由分区页签提供);
// - mode 'card':"我的"页卡片容器——延伸到屏幕最底部,左上角"+"新建(弹窗输入歌单名)。
// 通用:点击歌单 → SongList(playlist 模式,页内"添加歌曲");长按菜单(导出 M3U/删除)。
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SongListParam } from '../../components/SongRow';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { PlaylistRepo, PlaylistInfo } from '../../data/PlaylistRepo';
import { M3UEntry, buildM3U } from '../../data/m3u/M3U';
import { AppTheme, SafeAreaResult } from '../../common/Theme';
import { L } from '../../common/Lang';
import { BarCollapse } from '../../common/BarCollapse';

const TAG = '[Timbrava][Playlists]';
const DOMAIN = 0x0001;

// 文件名安全化:替换文件系统非法字符
function safeFileName(name: string): string {
  const cleaned = name.replace(/[\\/:*?"<>|]/g, '_').trim();
  return cleaned.length > 0 ? cleaned : 'playlist';
}

// 新建歌单弹窗(0.17.0:替代常驻行内输入框,由"+"按钮唤起)
@CustomDialog
struct NewPlaylistDialog {
  controller?: CustomDialogController;
  onConfirm: (name: string) => void = (_n: string): void => {
  };
  @State name: string = '';

  build() {
    Column({ space: 14 }) {
      Text($r('app.string.str_new_playlist'))
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
      TextInput({ text: this.name, placeholder: $r('app.string.new_pl_name') })
        .height(44)
        .fontSize(14)
        .width('100%')
        .borderRadius(10)
        .backgroundColor($r('app.color.badge_bg'))
        .fontColor($r('app.color.text_primary'))
        .placeholderColor($r('app.color.text_secondary'))
        .maxLines(1)
        .enterKeyType(EnterKeyType.Done)
        .onChange((v: string): void => {
          this.name = v;
        })
        .onSubmit((): void => {
          this.tryConfirm();
        })
      Row({ space: 12 }) {
        Button($r('app.string.str_cancel'))
          .fontSize(14)
          .height(40)
          .layoutWeight(1)
          .fontColor($r('app.color.text_primary'))
          .backgroundColor($r('app.color.badge_bg'))
          .onClick(() => {
            this.controller?.close();
          })
        Button($r('app.string.str_ok'))
          .fontSize(14)
          .height(40)
          .layoutWeight(1)
          .fontColor($r('app.color.on_accent'))
          .backgroundColor($r('app.color.accent'))
          .onClick(() => {
            this.tryConfirm();
          })
      }
      .width('100%')
    }
    .padding(20)
    .borderRadius(16)
    .backgroundColor($r('app.color.card_bg'))
    .width('86%')
  }

  private tryConfirm(): void {
    const t = this.name.trim();
    if (t.length === 0) {
      return;
    }
    this.onConfirm(t);
    this.controller?.close();
  }
}

@Component
export struct PlaylistsTab {
  @StorageProp('libVer') @Watch('onLibChanged') libVer: number = 0;
  @StorageProp('themePageBg') themePageBg: string = '';
  @StorageProp('bottomSafeVp') bottomSafeVp: number = 28;
  @State playlists: PlaylistInfo[] = [];
  @Prop mode: string = 'page'; // 'page' 曲库分区(满高) | 'card' 我的页卡片(延伸到底)
  @State topSafe: number = 36;
  private newCtrl: CustomDialogController | null = null;

  aboutToAppear(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    AppTheme.safeAreas(ctx).then((r: SafeAreaResult): void => {
      this.topSafe = r.topVp;
    });
    this.initRepo();
  }

  onLibChanged(): void {
    this.reload();
  }

  private async initRepo(): Promise<void> {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      await PlaylistRepo.get().init(ctx);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'init fail %{public}s', (e as Error).message);
      return;
    }
    this.reload();
  }

  private reload(): void {
    PlaylistRepo.get().listPlaylists().then((list: PlaylistInfo[]): void => {
      this.playlists = list;
    });
  }

  private pageBg(): ResourceColor {
    return this.themePageBg.length > 0 ? this.themePageBg : $r('app.color.page_bg');
  }

  private cardBg(): ResourceColor {
    return $r('app.color.card_bg');
  }

  private toast(msg: ResourceStr): void {
    this.getUIContext().getPromptAction().showToast({ message: msg, duration: 2000 });
  }

  // "+"新建歌单:弹窗输入歌单名
  private openCreateDialog(): void {
    this.newCtrl = new CustomDialogController({
      builder: NewPlaylistDialog({
        onConfirm: (name: string): void => {
          this.createPlaylist(name);
        }
      }),
      autoCancel: true,
      customStyle: true
    });
    this.newCtrl.open();
  }

  private async createPlaylist(name: string): Promise<void> {
    if (name.trim().length === 0) {
      this.toast($r('app.string.pl_name_required'));
      return;
    }
    const id = await PlaylistRepo.get().createPlaylist(name.trim());
    if (id < 0) {
      this.toast($r('app.string.pl_name_exists'));
      return;
    }
    this.reload();
  }

  private openPlaylist(pl: PlaylistInfo): void {
    const stack = AppStorage.get<NavPathStack>('navStack');
    if (stack !== undefined && stack !== null) {
      stack.pushPathByName('SongList', SongListParam.playlist(pl.id, pl.name));
    }
  }

  private confirmDelete(pl: PlaylistInfo): void {
    this.getUIContext().showAlertDialog({
      title: $r('app.string.delete_pl'),
      message: L($r('app.string.pl_delete_confirm'), pl.name),
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: $r('app.string.str_cancel'),
        action: (): void => {
        }
      },
      secondaryButton: {
        value: $r('app.string.str_delete'),
        fontColor: $r('app.color.accent'),
        action: (): void => {
          this.doDelete(pl);
        }
      },
      cancel: (): void => {
      }
    });
  }

  private async doDelete(pl: PlaylistInfo): Promise<void> {
    await PlaylistRepo.get().deletePlaylist(pl.id);
    this.reload();
  }

  // 导出 M3U 到沙箱 files/exports/<名称>.m3u
  private async exportM3U(pl: PlaylistInfo): Promise<void> {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      const songs = await PlaylistRepo.get().getPlaylistSongs(pl.id);
      if (songs.length === 0) {
        this.toast($r('app.string.pl_empty_no_export'));
        return;
      }
      const items: M3UEntry[] = [];
      for (const s of songs) {
        const e = new M3UEntry();
        e.path = s.path;
        e.title = s.displayTitle();
        e.artist = s.displayArtist();
        e.durationMs = s.durationMs;
        items.push(e);
      }
      const text = buildM3U(pl.name, items);
      const dir = `${ctx.filesDir}/exports`;
      try {
        if (!fs.accessSync(dir)) {
          fs.mkdirSync(dir, true);
        }
      } catch (e2) {
        fs.mkdirSync(dir, true);
      }
      const path = `${dir}/${safeFileName(pl.name)}.m3u`;
      const f = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(f.fd, text);
      fs.closeSync(f);
      this.toast(L($r('app.string.m3u_exported'), path));
      hilog.info(DOMAIN, TAG, 'export %{public}d songs -> %{public}s', songs.length, path);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'export fail %{public}s', (e as Error).message);
      this.toast($r('app.string.str_export_failed'));
    }
  }

  build() {
    if (this.mode === 'card') {
      // "我的"页卡片:延伸到屏幕最底部(内部垫过迷你条高度的收尾空档),圆角只留顶部
      Column() {
        this.CardContent()
      }
      .width('100%')
      .borderRadius({ topLeft: 16, topRight: 16 })
      .backgroundColor(this.cardBg())
    } else {
      Column() {
        this.PageContent()
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.pageBg())
    }
  }

  // ===== 曲库分区形态:满高列表 =====
  @Builder
  PageContent() {
    if (this.playlists.length === 0) {
      Column({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.music_note_list'))
          .fontSize(42)
          .fontColor([$r('app.color.text_secondary')])
        Text($r('app.string.no_playlists'))
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
        Text($r('app.string.pl_create_hint'))
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
    } else {
      List({ space: 0 }) {
        ForEach(this.playlists, (pl: PlaylistInfo) => {
          ListItem() {
            this.PlaylistRow(pl)
          }
        }, (pl: PlaylistInfo): string => `${pl.id}_${pl.name}_${pl.songCount}`)
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Auto)
      .padding({ top: 4 })
      .contentEndOffset(this.bottomSafeVp + 140) // 视口全出血渲染到屏底,仅滚动终点避让(padding 会内缩视口裁行)
      .nestedScroll({ scrollForward: NestedScrollMode.PARENT_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
      .edgeEffect(EdgeEffect.None)
      .onWillScroll((offset: number): void => {
        BarCollapse.feed(offset);
      })
      .onScrollStop((): void => {
        BarCollapse.settle();
      })
    }
  }

  // ===== 我的页卡片形态:左上角"+"新建 + 歌单行,延伸到屏幕最底部 =====
  @Builder
  CardContent() {
    Row({ space: 8 }) {
      Button({ stateEffect: true }) {
        SymbolGlyph($r('sys.symbol.plus'))
          .fontSize(20)
          .fontColor([$r('app.color.on_accent')])
      }
      .width(40)
      .height(40)
      .borderRadius(20)
      .backgroundColor($r('app.color.accent'))
      .onClick(() => {
        this.openCreateDialog();
      })
      Text($r('app.string.str_playlists'))
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
      if (this.playlists.length > 0) {
        Text(String(this.playlists.length))
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
      }
    }
    .width('100%')
    .padding({ left: 12, right: 16, top: 12, bottom: 4 })

    if (this.playlists.length === 0) {
      Column({ space: 6 }) {
        Text($r('app.string.no_playlists'))
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
        Text($r('app.string.pl_create_hint'))
          .fontSize(11)
          .fontColor($r('app.color.text_secondary'))
      }
      .width('100%')
      .padding({ top: 20, bottom: 24 })
      .alignItems(HorizontalAlign.Center)
    } else {
      Column() {
        ForEach(this.playlists, (pl: PlaylistInfo) => {
          this.PlaylistRow(pl)
        }, (pl: PlaylistInfo): string => `${pl.id}_${pl.name}_${pl.songCount}`)
      }
      .width('100%')
    }

    // 延伸到屏幕最底部:垫过迷你条/导航条的收尾空档(滚动到底时卡片底边贴屏)
    Blank().height(this.bottomSafeVp + 140)
  }

  @Builder
  PlaylistRow(pl: PlaylistInfo) {
    Row({ space: 12 }) {
      Column() {
        SymbolGlyph($r('sys.symbol.music_note_list'))
          .fontSize(22)
          .fontColor([$r('app.color.accent')])
      }
      .width(46)
      .height(46)
      .borderRadius(8)
      .backgroundColor($r('app.color.badge_bg'))
      .justifyContent(FlexAlign.Center)

      Column({ space: 3 }) {
        Text(pl.name)
          .fontSize(16)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(L($r('app.string.count_songs'), pl.songCount))
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(14)
        .fontColor([$r('app.color.text_secondary')])
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 8 })
    .onClick(() => {
      this.openPlaylist(pl);
    })
    .bindContextMenu(this.rowMenu(pl), ResponseType.LongPress)
  }

  @Builder
  rowMenu(pl: PlaylistInfo) {
    Menu() {
      MenuItem({ content: $r('app.string.export_m3u') })
        .onClick(() => {
          this.exportM3U(pl);
        })
      MenuItem({ content: $r('app.string.str_delete') })
        .onClick(() => {
          this.confirmDelete(pl);
        })
    }
  }
}

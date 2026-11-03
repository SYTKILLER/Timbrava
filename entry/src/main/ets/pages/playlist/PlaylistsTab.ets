// 歌单页(预留为库页第六分区):新建(行内输入)/歌单列表/长按菜单(导出 M3U、删除)。
// P1 待接入:点击歌单 → SongList 路由需新增 playlist 模式,当前弹 Toast 提示。
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SongListParam } from '../../components/SongRow';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { PlaylistRepo, PlaylistInfo } from '../../data/PlaylistRepo';
import { M3UEntry, buildM3U } from '../../data/m3u/M3U';
import { AppTheme, SafeAreaResult } from '../../common/Theme';
import { L } from '../../common/Lang';

const TAG = '[Timbrava][Playlists]';
const DOMAIN = 0x0001;

// 文件名安全化:替换文件系统非法字符
function safeFileName(name: string): string {
  const cleaned = name.replace(/[\\/:*?"<>|]/g, '_').trim();
  return cleaned.length > 0 ? cleaned : 'playlist';
}

@Component
export struct PlaylistsTab {
  @StorageProp('libVer') @Watch('onLibChanged') libVer: number = 0;
  @StorageProp('themePageBg') themePageBg: string = '';
  @StorageProp('bottomSafeVp') bottomSafeVp: number = 28;
  @State topSafe: number = 36;
  @State playlists: PlaylistInfo[] = [];
  @State newName: string = '';

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

  private toast(msg: ResourceStr): void {
    this.getUIContext().getPromptAction().showToast({ message: msg, duration: 2000 });
  }

  private async createPlaylist(): Promise<void> {
    const name = this.newName.trim();
    if (name.length === 0) {
      this.toast($r('app.string.pl_name_required'));
      return;
    }
    const id = await PlaylistRepo.get().createPlaylist(name);
    if (id < 0) {
      this.toast($r('app.string.pl_name_exists'));
      return;
    }
    this.newName = '';
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
    Column() {
      Row() {
        Text($r('app.string.str_playlists'))
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: this.topSafe + 8, bottom: 8 })

      // 新建歌单:行内输入 + 确定
      Row({ space: 8 }) {
        TextInput({ text: this.newName, placeholder: $r('app.string.new_pl_name') })
          .height(38)
          .layoutWeight(1)
          .fontSize(14)
          .borderRadius(10)
          .backgroundColor($r('app.color.card_bg'))
          .fontColor($r('app.color.text_primary'))
          .placeholderColor($r('app.color.text_secondary'))
          .maxLines(1)
          .enterKeyType(EnterKeyType.Done)
          .onChange((v: string) => {
            this.newName = v;
          })
          .onSubmit(() => {
            this.createPlaylist();
          })
        Button($r('app.string.str_ok'))
          .fontSize(14)
          .fontColor($r('app.color.on_accent'))
          .backgroundColor($r('app.color.accent'))
          .height(38)
          .borderRadius(10)
          .onClick(() => {
            this.createPlaylist();
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 8 })

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
        .padding({ top: 80 })
      } else {
        List({ space: 0 }) {
          ForEach(this.playlists, (pl: PlaylistInfo) => {
            ListItem() {
              this.PlaylistRow(pl)
            }
          }, (pl: PlaylistInfo): string => `${pl.id}_${pl.name}_${pl.songCount}`)
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Auto)
        .padding({ bottom: this.bottomSafeVp + 140 })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.pageBg())
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

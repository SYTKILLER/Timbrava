// 通用歌曲列表页(专辑/艺人/流派/文件夹/收藏):NavDestination + 全部播放按钮。
import { hilog } from '@kit.PerformanceAnalysisKit';
import { LibraryStore } from '../../data/LibraryStore';
import { Song, Artist, Genre } from '../../data/Model';
import { SongRow, SongListParam } from '../../components/SongRow';
import { QueueService } from '../../service/QueueService';
import { PlaylistRepo } from '../../data/PlaylistRepo';
import { PlayerController } from '../../service/PlayerController';

const TAG = '[Timbrava][SongList]';
const DOMAIN = 0x0001;

@Component
export struct SongListDest {
  @StorageProp('libVer') @Watch('onLibChanged') libVer: number = 0;
  @State songs: Song[] = [];
  @State title: string = '';
  @State param: SongListParam = new SongListParam();
  private pathStack: NavPathStack | null = null;

  private async resolveSongs(p: SongListParam): Promise<Song[]> {
    const lib = LibraryStore.get();
    if (p.mode === 'album') {
      return lib.songs.filter((s: Song): boolean =>
        `${s.albumArtist}\u0001${s.displayAlbum()}` === `${p.key}\u0001${p.subKey}`)
        .sort((a: Song, b: Song): number => (a.discNo - b.discNo) || (a.trackNo - b.trackNo));
    }
    if (p.mode === 'artist') {
      const artist = lib.artists.find((a: Artist): boolean => a.key === p.key);
      const ids: number[] = artist !== undefined ? artist.songIds : [];
      const mapped: (Song | null)[] = ids.map((id: number): Song | null => lib.song(id));
      return mapped.filter((s: Song | null): boolean => s !== null) as Song[];
    }
    if (p.mode === 'genre') {
      const g = lib.genres.find((x: Genre): boolean => x.name === p.key);
      const ids: number[] = g !== undefined ? g.songIds : [];
      const mapped: (Song | null)[] = ids.map((id: number): Song | null => lib.song(id));
      return mapped.filter((s: Song | null): boolean => s !== null) as Song[];
    }
    if (p.mode === 'folder') {
      return lib.songs.filter((s: Song): boolean => s.path.startsWith(p.key + '/'));
    }
    if (p.mode === 'playlist') {
      const id = parseInt(p.key, 10);
      return PlaylistRepo.get().getPlaylistSongs(Number.isNaN(id) ? 0 : id);
    }
    if (p.mode === 'smart') {
      return PlaylistRepo.get().getSmartSongs(p.key);
    }
    if (p.mode === 'favorites') {
      const out: Song[] = [];
      for (const s of lib.songs) {
        if (lib.isFavorite(s.id)) {
          out.push(s);
        }
      }
      return out;
    }
    return lib.songs.slice().sort((a: Song, b: Song): number => a.displayTitle().localeCompare(b.displayTitle()));
  }

  onLibChanged(): void {
    if (this.param.mode.length > 0) {
      this.reload();
    }
  }

  private reload(): void {
    this.resolveSongs(this.param).then((songs: Song[]): void => {
      this.songs = songs;
      hilog.debug(DOMAIN, TAG, 'reload %{public}s -> %{public}d songs', this.param.mode, songs.length);
    });
    hilog.debug(DOMAIN, TAG, 'reload %{public}s -> %{public}d songs', this.param.mode, this.songs.length);
  }

  private saveAsPlaylist(): void {
    if (this.songs.length === 0) {
      return;
    }
    const base = this.title.length > 0 ? this.title : '歌单';
    const name = `${base} · ${new Date().getMonth() + 1}/${new Date().getDate()}`;
    const ids: number[] = this.songs.map((s: Song): number => s.id);
    PlaylistRepo.get().createPlaylist(name).then((id: number): void => {
      if (id > 0) {
        PlaylistRepo.get().addSongs(id, ids).then((): void => {
          this.getUIContext().getPromptAction().showToast({ message: `已保存歌单「${name}」` });
        });
      } else {
        this.getUIContext().getPromptAction().showToast({ message: '歌单重名,保存失败' });
      }
    });
  }

  private playAll(): void {
    if (this.songs.length === 0) {
      return;
    }
    const q = QueueService.get();
    const first = q.setQueueNow(this.songs, 0, this.title);
    PlayerController.get().playQueueIndex(q.locateCurrent());
  }

  build() {
    NavDestination() {
      Column() {
        Row({ space: 8 }) {
          Text(this.title)
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Button('存为歌单')
            .fontSize(13)
            .fontColor($r('app.color.text_primary'))
            .backgroundColor($r('app.color.badge_bg'))
            .height(34)
            .borderRadius(17)
            .onClick(() => {
              this.saveAsPlaylist();
            })
          Button(`全部播放 ${this.songs.length}`)
            .fontSize(13)
            .fontColor($r('app.color.on_accent'))
            .backgroundColor($r('app.color.accent'))
            .height(34)
            .borderRadius(17)
            .onClick(() => {
              this.playAll();
            })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 8 })

        if (this.songs.length === 0) {
          Column({ space: 8 }) {
            SymbolGlyph($r('sys.symbol.music_note_list'))
              .fontSize(42)
              .fontColor([$r('app.color.text_secondary')])
            Text('列表为空')
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
          }
          .width('100%')
          .padding({ top: 80 })
        } else {
          List({ space: 0 }) {
            ForEach(this.songs, (s: Song) => {
              ListItem() {
                SongRow({ song: s, showAlbum: this.param.mode !== 'album' })
              }
            }, (s: Song): string => `${s.id}_${this.param.mode}_${this.title}`)
          }
          .width('100%')
          .layoutWeight(1)
          .scrollBar(BarState.Auto)
          .padding({ bottom: 60 })
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.page_bg'))
    }
    .title(this.title)
    .onReady((ctx: NavDestinationContext): void => {
      this.pathStack = ctx.pathStack;
      const p: Object | undefined = ctx.pathInfo.param as Object | undefined;
      if (p !== null && p !== undefined && p instanceof SongListParam) {
        this.param = p as SongListParam;
        this.title = (p as SongListParam).title;
        this.reload();
      }
    })
    .onShown((): void => {
      // 收藏列表返回后可能变化
      if (this.param.mode === 'favorites') {
        this.reload();
      }
    })
  }
}


@Builder
export function SongListBuilder() {
  SongListDest()
}

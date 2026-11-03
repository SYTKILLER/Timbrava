// 音乐库页:顶部页签(TabSegmentButtonV2 + Swiper):歌曲/专辑/艺人/流派/文件夹。
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { TabSegmentButtonV2, SegmentButtonV2Items, SegmentButtonV2Item } from '@kit.ArkUI';
import { AppTheme, SafeAreaResult } from '../../common/Theme';
import { LibraryStore, DEFAULT_ORDER } from '../../data/LibraryStore';
import { Song, Album, Artist, Genre, FolderNode } from '../../data/Model';
import { SongRow, SongListParam } from '../../components/SongRow';
import { BasicDataSource } from '../../common/DataSource';
import { ScanService } from '../../data/ScanService';
import { PlaylistsTab } from '../playlist/PlaylistsTab';
import { L } from '../../common/Lang';

const TAG = '[Timbrava][Library]';
const DOMAIN = 0x0001;

class SongSource extends BasicDataSource<Song> {
}
class AlbumSource extends BasicDataSource<Album> {
}
class ArtistSource extends BasicDataSource<Artist> {
}
class GenreSource extends BasicDataSource<Genre> {
}

@Builder
export function AlbumCover(artPath: string, sizeVp: number) {
  if (artPath.length > 0) {
    Image(artPath)
      .width(sizeVp)
      .height(sizeVp)
      .borderRadius(10)
      .objectFit(ImageFit.Cover)
  } else {
    Column() {
      SymbolGlyph($r('sys.symbol.music_note_list'))
        .fontSize(Math.round(sizeVp * 0.4))
        .fontColor([$r('app.color.accent')])
    }
    .width(sizeVp)
    .height(sizeVp)
    .borderRadius(10)
    .backgroundColor($r('app.color.badge_bg'))
    .justifyContent(FlexAlign.Center)
  }
}

@Component
export struct LibraryTab {
  @StorageProp('libVer') @Watch('onLibChanged') libVer: number = 0;
  @StorageProp('scanVer') scanVer: number = 0;
  @StorageProp('themePageBg') themePageBg: string = '';
  @StorageProp('bottomSafeVp') bottomSafeVp: number = 28;
  @State segmentIndex: number = 0;
  @State topSafe: number = 36;
  private songSrc: SongSource = new SongSource();
  private albumSrc: AlbumSource = new AlbumSource();
  private artistSrc: ArtistSource = new ArtistSource();
  private genreSrc: GenreSource = new GenreSource();
  private swiper: SwiperController = new SwiperController();

  onLibChanged(): void {
    this.refreshAll();
  }

  aboutToAppear(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    AppTheme.safeAreas(ctx).then((r: SafeAreaResult): void => {
      this.topSafe = r.topVp;
    });
    this.refreshAll();
  }

  private refreshAll(): void {
    const lib = LibraryStore.get();
    const songs = lib.songs.slice().sort((a: Song, b: Song): number =>
      a.displayTitle().localeCompare(b.displayTitle()));
    this.songSrc.setData(songs);
    this.albumSrc.setData(lib.albums);
    this.artistSrc.setData(lib.artists);
    this.genreSrc.setData(lib.genres);
    hilog.debug(DOMAIN, TAG, 'refresh songs=%{public}d albums=%{public}d', songs.length, lib.albums.length);
  }

  private navStack(): NavPathStack | null {
    return AppStorage.get<NavPathStack>('navStack') ?? null;
  }

  build() {
    Column() {
      Row({ space: 8 }) {
        Text($r('app.string.app_name_display'))
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
        if (ScanService.get().isScanning()) {
          LoadingProgress().width(20).height(20).color($r('app.color.accent'))
        }
        Button({ stateEffect: true }) {
          SymbolGlyph($r('sys.symbol.magnifyingglass'))
            .fontSize(20)
            .fontColor([$r('app.color.text_primary')])
        }
        .width(36)
        .height(36)
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          const stack = AppStorage.get<NavPathStack>('navStack');
          if (stack !== undefined && stack !== null) {
            stack.pushPathByName('Search', null);
          }
        })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: this.topSafe + 8, bottom: 4 })

      Row() {
        TabSegmentButtonV2({
          items: SEG_ITEMS,
          selectedIndex: this.segmentIndex
        })
      }
      .padding({ left: 16, right: 16, bottom: 8 })
      .width('100%')

      Swiper(this.swiper) {
        this.SongsPage()
        this.AlbumsPage()
        this.ArtistsPage()
        this.GenresPage()
        this.FoldersPage()
        this.PlaylistsPage()
      }
      .index(this.segmentIndex)
      .onChange((i: number): void => {
        this.segmentIndex = i;
      })
      .layoutWeight(1)
      .width('100%')
      .indicator(false)
      .nestedScroll(SwiperNestedScrollMode.SELF_FIRST)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.pageBg())
    .onAppear((): void => {
      this.refreshAll();
    })
  }

  pageBg(): ResourceColor {
    return this.themePageBg.length > 0 ? this.themePageBg : $r('app.color.page_bg');
  }

  @Builder
  EmptyHint(text: ResourceStr) {
    Column({ space: 8 }) {
      SymbolGlyph($r('sys.symbol.music_note_list'))
        .fontSize(42)
        .fontColor([$r('app.color.text_secondary')])
      Text(text)
        .fontSize(14)
        .fontColor($r('app.color.text_secondary'))
    }
    .width('100%')
    .padding({ top: 80 })
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  SongsPage() {
    if (this.songSrc.totalCount() === 0) {
      this.EmptyHint($r('app.string.lib_empty_hint'))
    } else {
      List({ space: 0 }) {
        LazyForEach(this.songSrc, (s: Song) => {
          ListItem() {
            SongRow({ song: s, showAlbum: true })
          }
        }, (s: Song): string => `${s.id}_${s.title}`)
      }
      .width('100%')
      .height('100%')
      .cachedCount(8)
      .padding({ bottom: this.bottomSafeVp + 140 })
      .scrollBar(BarState.Auto)
    }
  }

  @Builder
  AlbumsPage() {
    if (this.albumSrc.totalCount() === 0) {
      this.EmptyHint($r('app.string.albums_empty'))
    } else {
      Grid() {
        LazyForEach(this.albumSrc, (a: Album) => {
          GridItem() {
            Column({ space: 6 }) {
              AlbumCover(a.artPath, 100)
              Text(a.name)
                .fontSize(13)
                .fontColor($r('app.color.text_primary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(a.artist)
                .fontSize(11)
                .fontColor($r('app.color.text_secondary'))
                .maxLines(1)
            }
            .width('100%')
            .alignItems(HorizontalAlign.Center)
            .onClick(() => {
              const stack = this.navStack();
              if (stack !== null) {
                stack.pushPathByName('SongList', SongListParam.album(a.artist, a.name));
              }
            })
          }
        }, (a: Album): string => a.key)
      }
      .columnsTemplate('1fr 1fr 1fr')
      .columnsGap(12)
      .rowsGap(16)
      .padding({ left: 16, right: 16, bottom: this.bottomSafeVp + 140 })
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Auto)
    }
  }

  @Builder
  ArtistsPage() {
    if (this.artistSrc.totalCount() === 0) {
      this.EmptyHint($r('app.string.artists_empty'))
    } else {
      List({ space: 2 }) {
        LazyForEach(this.artistSrc, (a: Artist) => {
          ListItem() {
            Row({ space: 12 }) {
              Column() {
                SymbolGlyph($r('sys.symbol.person'))
                  .fontSize(20)
                  .fontColor([$r('app.color.accent')])
              }
              .width(44)
              .height(44)
              .borderRadius(22)
              .backgroundColor($r('app.color.badge_bg'))
              .justifyContent(FlexAlign.Center)
              Text(a.name)
                .fontSize(15)
                .fontColor($r('app.color.text_primary'))
                .maxLines(1)
                .layoutWeight(1)
              Text(L($r('app.string.artist_stats'), a.albumCount, a.songCount))
                .fontSize(11)
                .fontColor($r('app.color.text_secondary'))
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 8, bottom: 8 })
            .onClick(() => {
              const stack = this.navStack();
              if (stack !== null) {
                stack.pushPathByName('SongList', SongListParam.artist(a.name));
              }
            })
          }
        }, (a: Artist): string => a.key)
      }
      .width('100%')
      .height('100%')
      .padding({ bottom: this.bottomSafeVp + 140 })
      .scrollBar(BarState.Auto)
    }
  }

  @Builder
  GenresPage() {
    if (this.genreSrc.totalCount() === 0) {
      this.EmptyHint($r('app.string.genres_empty'))
    } else {
      List({ space: 2 }) {
        LazyForEach(this.genreSrc, (g: Genre) => {
          ListItem() {
            Row() {
              Text(g.name)
                .fontSize(15)
                .fontColor($r('app.color.text_primary'))
                .layoutWeight(1)
              Text(L($r('app.string.count_songs'), g.songCount))
                .fontSize(11)
                .fontColor($r('app.color.text_secondary'))
              SymbolGlyph($r('sys.symbol.chevron_right'))
                .fontSize(14)
                .fontColor([$r('app.color.text_secondary')])
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 12, bottom: 12 })
            .onClick(() => {
              const stack = this.navStack();
              if (stack !== null) {
                stack.pushPathByName('SongList', SongListParam.genre(g.name));
              }
            })
          }
        }, (g: Genre): string => g.name)
      }
      .width('100%')
      .height('100%')
      .padding({ bottom: this.bottomSafeVp + 140 })
      .scrollBar(BarState.Auto)
    }
  }

  @Builder
  PlaylistsPage() {
    PlaylistsTab()
  }

  @Builder
  FoldersPage() {
    if (LibraryStore.get().folderRoot.children.length === 0) {
      this.EmptyHint($r('app.string.folder_empty'))
    } else {
      List({ space: 2 }) {
        ForEach(LibraryStore.get().folderRoot.children, (n: FolderNode) => {
          ListItem() {
            Row({ space: 10 }) {
              SymbolGlyph($r('sys.symbol.folder'))
                .fontSize(20)
                .fontColor([$r('app.color.accent')])
              Text(n.name)
                .fontSize(15)
                .fontColor($r('app.color.text_primary'))
                .maxLines(1)
                .layoutWeight(1)
              Text(L($r('app.string.count_songs'), n.countSongsRecursive()))
                .fontSize(11)
                .fontColor($r('app.color.text_secondary'))
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 12, bottom: 12 })
            .onClick(() => {
              const stack = this.navStack();
              if (stack !== null) {
                stack.pushPathByName('FolderTree', n.dirPath);
              }
            })
          }
        }, (n: FolderNode): string => n.dirPath)
      }
      .width('100%')
      .height('100%')
      .padding({ bottom: this.bottomSafeVp + 140 })
      .scrollBar(BarState.Auto)
    }
  }
}

const SEG_ITEMS: SegmentButtonV2Items = new SegmentButtonV2Items([
  new SegmentButtonV2Item({ text: $r('app.string.str_songs') }),
  new SegmentButtonV2Item({ text: $r('app.string.str_albums') }),
  new SegmentButtonV2Item({ text: $r('app.string.str_artists') }),
  new SegmentButtonV2Item({ text: $r('app.string.str_genres') }),
  new SegmentButtonV2Item({ text: $r('app.string.str_folder') }),
  new SegmentButtonV2Item({ text: $r('app.string.str_playlists') })
]);

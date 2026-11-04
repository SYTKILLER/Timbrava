// 音乐库页:顶部页签(TabSegmentButtonV2 + Swiper):歌曲/专辑/艺人/流派。
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { picker } from '@kit.CoreFileKit';
import { TabSegmentButtonV2, SegmentButtonV2Items, SegmentButtonV2Item } from '@kit.ArkUI';
import { AppTheme, SafeAreaResult } from '../../common/Theme';
import { LibraryStore, DEFAULT_ORDER } from '../../data/LibraryStore';
import { Song, Album, Artist, Genre } from '../../data/Model';
import { SongRow, SongListParam } from '../../components/SongRow';
import { BasicDataSource } from '../../common/DataSource';
import { ScanService } from '../../data/ScanService';
import { L, Ls } from '../../common/Lang';
import { BarCollapse } from '../../common/BarCollapse';

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

// 曲库首页横滑卡:最近添加专辑
class RecentAlbum {
  key: string;
  album: string;
  artist: string;
  artPath: string;

  constructor(key: string, album: string, artist: string, artPath: string) {
    this.key = key;
    this.album = album;
    this.artist = artist;
    this.artPath = artPath;
  }
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
  // 空态分支必须读 @State 计数:数据源方法非可观察,libVer 变更时分支不重估(导入/扫描后不即时刷新的根因)
  @State songCount: number = 0;
  @State albumCount: number = 0;
  @State artistCount: number = 0;
  @State genreCount: number = 0;
  @State topSafe: number = 36;
  @State recentAlbums: RecentAlbum[] = [];
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
    this.songCount = songs.length;
    this.albumCount = lib.albums.length;
    this.artistCount = lib.artists.length;
    this.genreCount = lib.genres.length;
    hilog.debug(DOMAIN, TAG, 'refresh songs=%{public}d albums=%{public}d', songs.length, lib.albums.length);
    this.rebuildRecent();
  }

  private navStack(): NavPathStack | null {
    return AppStorage.get<NavPathStack>('navStack') ?? null;
  }

  // 最近添加专辑:按入库时间去重取前 10 张(曲库首页横滑卡)
  private rebuildRecent(): void {
    const seen: Set<string> = new Set<string>();
    const list: RecentAlbum[] = [];
    const songs = LibraryStore.get().songs.slice().sort((a: Song, b: Song): number => b.dateAdded - a.dateAdded);
    for (const s of songs) {
      const key = `${s.albumArtist || s.artist}||${s.album}`;
      if (seen.has(key) || s.dateAdded <= 0) {
        continue;
      }
      seen.add(key);
      list.push(new RecentAlbum(key, s.album, s.displayArtist(), s.artPath));
      if (list.length >= 10) {
        break;
      }
    }
    this.recentAlbums = list;
  }

  private openSmart(kind: string, titleRes: Resource): void {
    const stack = this.navStack();
    if (stack !== null) {
      stack.pushPathByName('SongList', SongListParam.smart(kind, L(titleRes)));
    }
  }

  private openFavorites(): void {
    const stack = this.navStack();
    if (stack !== null) {
      stack.pushPathByName('SongList', SongListParam.favorites());
    }
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

      // 智能列表入口(最近播放/最常播放/收藏)
      Row({ space: 8 }) {
        Button($r('app.string.smart_recent'))
          .fontSize(12)
          .fontColor($r('app.color.text_primary'))
          .backgroundColor($r('app.color.badge_bg'))
          .borderRadius(14)
          .height(30)
          .layoutWeight(1)
          .onClick(() => {
            this.openSmart('recent', $r('app.string.smart_recent'));
          })
        Button($r('app.string.smart_most'))
          .fontSize(12)
          .fontColor($r('app.color.text_primary'))
          .backgroundColor($r('app.color.badge_bg'))
          .borderRadius(14)
          .height(30)
          .layoutWeight(1)
          .onClick(() => {
            this.openSmart('most', $r('app.string.smart_most'));
          })
        Button($r('app.string.str_favorites'))
          .fontSize(12)
          .fontColor($r('app.color.text_primary'))
          .backgroundColor($r('app.color.badge_bg'))
          .borderRadius(14)
          .height(30)
          .layoutWeight(1)
          .onClick(() => {
            this.openFavorites();
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 8 })

      // 最近添加专辑横滑卡
      if (this.recentAlbums.length > 0) {
        Text($r('app.string.recent_added'))
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .width('100%')
          .padding({ left: 16, right: 16, bottom: 4 })
        List({ space: 10 }) {
          ForEach(this.recentAlbums, (a: RecentAlbum) => {
            ListItem() {
              Column({ space: 4 }) {
                AlbumCover(a.artPath, 88)
                Text(a.album)
                  .fontSize(11)
                  .fontColor($r('app.color.text_primary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(a.artist)
                  .fontSize(10)
                  .fontColor($r('app.color.text_secondary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .width(88)
            }
              .onClick(() => {
                const parts = a.key.split('||');
                const stack = this.navStack();
                if (stack !== null) {
                  stack.pushPathByName('SongList', SongListParam.album(parts[0], parts.length > 1 ? parts[1] : a.album));
                }
              })
          }, (a: RecentAlbum): string => a.key)
        }
        .width('100%')
        .height(130)
        .padding({ left: 16, right: 16, bottom: 8 })
        .scrollBar(BarState.Off)
      }

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

  // 空态引导:直接给"添加歌曲"入口(免找设置)
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

  @Builder
  SongsPage() {
    if (this.songCount === 0) {
      Column({ space: 16 }) {
        this.EmptyHint($r('app.string.lib_empty_hint'))
        Button($r('app.string.add_songs'))
          .fontSize(14)
          .fontColor($r('app.color.on_accent'))
          .backgroundColor($r('app.color.accent'))
          .height(40)
          .borderRadius(20)
          .onClick(() => {
            this.addSongs();
          })
      }
      .width('100%')
    } else {
      List({ space: 0 }) {
        LazyForEach(this.songSrc, (s: Song) => {
          ListItem() {
            SongRow({ song: s, showAlbum: true, listIds: this.songSrc.snapshot().map((x: Song): number => x.id), listTitle: Ls($r('app.string.tab_library')) })
          }
        }, (s: Song): string => `${s.id}_${s.title}`)
      }
      .width('100%')
      .height('100%')
      .cachedCount(8)
      .padding({ bottom: this.bottomSafeVp + 140 })
      .scrollBar(BarState.Auto)
      .onWillScroll((offset: number): void => {
        BarCollapse.feed(offset);
      })
      .onScrollStop((): void => {
        BarCollapse.settle();
      })
    }
  }

  @Builder
  AlbumsPage() {
    if (this.albumCount === 0) {
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
      .onWillScroll((offset: number): void => {
        BarCollapse.feed(offset);
      })
      .onScrollStop((): void => {
        BarCollapse.settle();
      })
    }
  }

  @Builder
  ArtistsPage() {
    if (this.artistCount === 0) {
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
      .onWillScroll((offset: number): void => {
        BarCollapse.feed(offset);
      })
      .onScrollStop((): void => {
        BarCollapse.settle();
      })
    }
  }

  @Builder
  GenresPage() {
    if (this.genreCount === 0) {
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
      .onWillScroll((offset: number): void => {
        BarCollapse.feed(offset);
      })
      .onScrollStop((): void => {
        BarCollapse.settle();
      })
    }
  }
}

const SEG_ITEMS: SegmentButtonV2Items = new SegmentButtonV2Items([
  new SegmentButtonV2Item({ text: $r('app.string.str_songs') }),
  new SegmentButtonV2Item({ text: $r('app.string.str_albums') }),
  new SegmentButtonV2Item({ text: $r('app.string.str_artists') }),
  new SegmentButtonV2Item({ text: $r('app.string.str_genres') })
]);

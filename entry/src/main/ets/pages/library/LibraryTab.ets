// 音乐库页:顶部页签(TabSegmentButtonV2 + Swiper):歌曲/专辑/艺人/歌单(0.17.0:流派→歌单,实测流派标签长期为空)。
// 顶部智能列表 stack(我的收藏/播放历史/最常播放/最近添加):点击切换下方封面横滑行(0.17.0)。
// 0.14.0:分区排序菜单(持久化 app_settings)+ 歌曲/艺人分区字母索引条
// (i18n.Transliterator Any-Latin 汉字转拼音首字母,设备不支持时非拉丁退化 '#')。
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { picker } from '@kit.CoreFileKit';
import { i18n } from '@kit.LocalizationKit';
import { TabSegmentButtonV2, SegmentButtonV2Items, SegmentButtonV2Item } from '@kit.ArkUI';
import { AppTheme, SafeAreaResult } from '../../common/Theme';
import { LibraryStore, DEFAULT_ORDER } from '../../data/LibraryStore';
import { Song, Album, Artist } from '../../data/Model';
import { SongRow, SongListParam } from '../../components/SongRow';
import { BasicDataSource } from '../../common/DataSource';
import { ScanService } from '../../data/ScanService';
import { Db } from '../../data/Db';
import { PlaylistRepo } from '../../data/PlaylistRepo';
import { PlayerController } from '../../service/PlayerController';
import { QueueService } from '../../service/QueueService';
import { L, Ls } from '../../common/Lang';
import { BarCollapse } from '../../common/BarCollapse';
import { PlaylistsTab } from '../playlist/PlaylistsTab';

const TAG = '[Timbrava][Library]';
const DOMAIN = 0x0001;

const LETTERS: string[] = [
  'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M',
  'N', 'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z', '#'
];

class AlbumSource extends BasicDataSource<Album> {
}

// 拼音首字母:Transliterator 模块级单例(getInstance 较重,首用探测;Any-Latin 不支持退化 '#')
// + 逐字符缓存(滚动联动高频调用)
let pinyinTr: i18n.Transliterator | null = null;
let pinyinChecked: boolean = false;
const letterCache: Map<string, string> = new Map<string, string>();

function firstLetter(text: string): string {
  const t = text.trim();
  if (t.length === 0) {
    return '#';
  }
  const cached = letterCache.get(t);
  if (cached !== undefined) {
    return cached;
  }
  const out = computeFirstLetter(t);
  letterCache.set(t, out);
  return out;
}

function computeFirstLetter(t: string): string {
  const c0 = t.charAt(0).toUpperCase();
  if (c0 >= 'A' && c0 <= 'Z') {
    return c0;
  }
  if (!pinyinChecked) {
    pinyinChecked = true;
    try {
      const ids: string[] = i18n.Transliterator.getAvailableIDs();
      if (ids.indexOf('Any-Latin') >= 0) {
        pinyinTr = i18n.Transliterator.getInstance('Any-Latin');
      }
    } catch (e) {
      pinyinTr = null;
    }
  }
  if (pinyinTr !== null) {
    try {
      const latin = pinyinTr.transform(t.charAt(0)).trim();
      if (latin.length > 0) {
        const c = latin.charAt(0).toUpperCase();
        if (c >= 'A' && c <= 'Z') {
          return c;
        }
      }
    } catch (e) {
      // 退化 '#'
    }
  }
  return '#';
}

// 索引条跳转序:字母字符串序,'#'(非拉丁)排在 Z 之后
function letterOrderKey(letter: string): number {
  const idx = LETTERS.indexOf(letter);
  return idx >= 0 ? idx : LETTERS.length - 1;
}

// 统一行模型:字母分组头 + 内容行(歌曲/艺人);LazyForEach 数据源元素
class LibRow {
  kind: string = 's'; // 'h' 分组头 | 's' 歌曲 | 'a' 艺人
  letter: string = '';
  song: Song | null = null;
  artist: Artist | null = null;

  key(): string {
    if (this.kind === 'h') {
      return `h_${this.letter}`;
    }
    if (this.kind === 's') {
      return `s_${this.song !== null ? this.song.id : 0}`;
    }
    return `a_${this.artist !== null ? this.artist.key : ''}`;
  }
}

class SongRowSource extends BasicDataSource<LibRow> {
}
class ArtistRowSource extends BasicDataSource<LibRow> {
}

// 曲库首页横滑卡:最近添加歌曲封面(0.15.0:由专辑卡改为逐曲封面,
// 左边最新共 10 张,末尾「查看全部」占位封面跳转最近添加列表;点击封面即以最近添加队列起播)

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
  // 智能列表 stack(0.17.0):我的收藏/播放历史/最常播放/最近添加,切换下方封面横滑行
  @State smartIdx: number = 0;
  @State favSongs: Song[] = [];    // 收藏(按收藏时间倒序)
  @State hisSongs: Song[] = [];    // 播放历史(最近播放去重)
  @State mostSongs: Song[] = [];   // 最常播放
  @State topSafe: number = 36;
  @State addedSongs: Song[] = [];       // 横滑卡展示:最近入库 10 首(左=最新)
  private addedQueue: Song[] = [];      // 点击起播的「最近添加」队列(前 50,与查看全部列表一致)
  @State vpH: number = 0;   // 外层 Scroll 视口高(onAreaChange 实测)
  @State segH: number = 40; // 分段器行高(onAreaChange 实测)
  // 0.14.0 排序(持久化;索引条仅在按名称排序时显示)
  @State sortSongs: string = 'title';   // title|artist|album|added|duration
  @State sortAlbums: string = 'name';   // name|artist|added|songs
  @State sortArtists: string = 'name';  // name|songs
  @State songSel: number = 0;   // 歌曲分区索引条选中字母
  @State artistSel: number = 0; // 艺人分区索引条选中字母
  private albumSrc: AlbumSource = new AlbumSource();
  private songRows: SongRowSource = new SongRowSource();
  private artistRows: ArtistRowSource = new ArtistRowSource();
  private songIdCache: number[] = []; // SongRow listIds 快照(当前排序下的歌曲序)
  private artistIdCache: number[] = [];
  private swiper: SwiperController = new SwiperController();
  private songsScroller: Scroller = new Scroller();
  private artistsScroller: Scroller = new Scroller();
  private sortsLoaded: boolean = false;

  onLibChanged(): void {
    if (this.sortsLoaded) {
      this.refreshAll();
    }
  }

  aboutToAppear(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    AppTheme.safeAreas(ctx).then((r: SafeAreaResult): void => {
      this.topSafe = r.topVp;
    });
    this.loadSorts();
  }

  // 排序偏好异步加载(三项齐了再刷,避免默认序先渲染后跳变)
  private loadSorts(): void {
    const db = Db.get();
    let pending = 3;
    const done = (): void => {
      pending--;
      if (pending === 0) {
        this.sortsLoaded = true;
        this.refreshAll();
      }
    };
    db.getSetting('sortSongs', 'title').then((v: string): void => {
      if (['title', 'artist', 'album', 'added', 'duration'].indexOf(v) >= 0) {
        this.sortSongs = v;
      }
      done();
    });
    db.getSetting('sortAlbums', 'name').then((v: string): void => {
      if (['name', 'artist', 'added', 'songs'].indexOf(v) >= 0) {
        this.sortAlbums = v;
      }
      done();
    });
    db.getSetting('sortArtists', 'name').then((v: string): void => {
      if (['name', 'songs'].indexOf(v) >= 0) {
        this.sortArtists = v;
      }
      done();
    });
  }

  private refreshAll(): void {
    const lib = LibraryStore.get();
    const songs = this.sortSongList(lib.songs);
    this.rebuildSongRows(songs);
    this.songCount = songs.length;
    this.rebuildAlbums(lib);
    this.albumCount = lib.albums.length;
    this.rebuildArtistRows(lib.artists);
    this.artistCount = lib.artists.length;
    hilog.debug(DOMAIN, TAG, 'refresh songs=%{public}d albums=%{public}d sort=%{public}s/%{public}s/%{public}s',
      songs.length, lib.albums.length, this.sortSongs, this.sortAlbums, this.sortArtists);
    this.rebuildRecent();
    this.rebuildSmartLists();
  }

  // 智能列表数据:收藏(内存)/播放历史+最常播放(异步查询);libVer 变更即重算
  private rebuildSmartLists(): void {
    const lib = LibraryStore.get();
    // 收藏:getFavoriteIds 按收藏时间倒序,Set 保序遍历
    const favs: Song[] = [];
    lib.favoriteIds.forEach((id: number): void => {
      const s = lib.song(id);
      if (s !== null) {
        favs.push(s);
      }
    });
    this.favSongs = favs;
    PlaylistRepo.get().getSmartSongs('recent').then((list: Song[]): void => {
      this.hisSongs = list;
    });
    PlaylistRepo.get().getSmartSongs('most').then((list: Song[]): void => {
      this.mostSongs = list;
    });
  }

  private sortSongList(list: Song[]): Song[] {
    const arr = list.slice();
    if (this.sortSongs === 'artist') {
      arr.sort((a: Song, b: Song): number => a.displayArtist().localeCompare(b.displayArtist())
        || a.displayTitle().localeCompare(b.displayTitle()));
    } else if (this.sortSongs === 'album') {
      arr.sort((a: Song, b: Song): number => a.displayAlbum().localeCompare(b.displayAlbum())
        || (a.discNo - b.discNo) || (a.trackNo - b.trackNo));
    } else if (this.sortSongs === 'added') {
      arr.sort((a: Song, b: Song): number => b.dateAdded - a.dateAdded);
    } else if (this.sortSongs === 'duration') {
      arr.sort((a: Song, b: Song): number => b.durationMs - a.durationMs);
    } else {
      arr.sort((a: Song, b: Song): number => a.displayTitle().localeCompare(b.displayTitle()));
    }
    return arr;
  }

  // 歌曲行构建:按标题排序时插字母分组头;其余排序平铺(索引条隐藏)
  private rebuildSongRows(songs: Song[]): void {
    const rows: LibRow[] = [];
    const ids: number[] = [];
    const seen: Set<string> = new Set<string>();
    for (const s of songs) {
      if (this.sortSongs === 'title') {
        const letter = firstLetter(s.displayTitle());
        if (!seen.has(letter)) {
          seen.add(letter);
          const h = new LibRow();
          h.kind = 'h';
          h.letter = letter;
          rows.push(h);
        }
      }
      const r = new LibRow();
      r.kind = 's';
      r.song = s;
      rows.push(r);
      ids.push(s.id);
    }
    this.songIdCache = ids;
    this.songRows.setData(rows);
  }

  private rebuildAlbums(lib: LibraryStore): void {
    const arr = lib.albums.slice();
    if (this.sortAlbums === 'artist') {
      arr.sort((a: Album, b: Album): number => a.artist.localeCompare(b.artist) || a.name.localeCompare(b.name));
    } else if (this.sortAlbums === 'songs') {
      arr.sort((a: Album, b: Album): number => b.songIds.length - a.songIds.length);
    } else if (this.sortAlbums === 'added') {
      const addedOf = (a: Album): number => {
        let m = 0;
        for (const id of a.songIds) {
          const s = lib.song(id);
          if (s !== null && s.dateAdded > m) {
            m = s.dateAdded;
          }
        }
        return m;
      };
      arr.sort((a: Album, b: Album): number => addedOf(b) - addedOf(a));
    } else {
      arr.sort((a: Album, b: Album): number => a.name.localeCompare(b.name));
    }
    this.albumSrc.setData(arr);
  }

  // 艺人行构建:按名称排序时插字母分组头
  private rebuildArtistRows(artists: Artist[]): void {
    const rows: LibRow[] = [];
    const ids: number[] = [];
    const seen: Set<string> = new Set<string>();
    const arr = artists.slice();
    if (this.sortArtists === 'songs') {
      arr.sort((a: Artist, b: Artist): number => b.songCount - a.songCount || a.name.localeCompare(b.name));
    } else {
      arr.sort((a: Artist, b: Artist): number => a.name.localeCompare(b.name));
    }
    for (const a of arr) {
      if (this.sortArtists === 'name') {
        const letter = firstLetter(a.name);
        if (!seen.has(letter)) {
          seen.add(letter);
          const h = new LibRow();
          h.kind = 'h';
          h.letter = letter;
          rows.push(h);
        }
      }
      const r = new LibRow();
      r.kind = 'a';
      r.artist = a;
      rows.push(r);
      for (const id of a.songIds) {
        ids.push(id);
      }
    }
    this.artistIdCache = ids;
    this.artistRows.setData(rows);
  }

  // 排序变更:落库 + 重建对应分区 + 复位索引条
  private setSortSongs(v: string): void {
    this.sortSongs = v;
    Db.get().setSetting('sortSongs', v);
    this.songSel = 0;
    this.refreshAll();
  }

  private setSortAlbums(v: string): void {
    this.sortAlbums = v;
    Db.get().setSetting('sortAlbums', v);
    this.refreshAll();
  }

  private setSortArtists(v: string): void {
    this.sortArtists = v;
    Db.get().setSetting('sortArtists', v);
    this.artistSel = 0;
    this.refreshAll();
  }

  // 索引条点选:跳到首个序 >= 目标字母的行(跳过分组头;无匹配跳 '#')
  private jumpToLetter(rows: BasicDataSource<LibRow>, scroller: Scroller, targetIdx: number): void {
    const target = targetIdx >= 0 && targetIdx < LETTERS.length ? LETTERS[targetIdx] : '#';
    const items = rows.raw;
    for (let i = 0; i < items.length; i++) {
      const r = items[i];
      const letter = r.kind === 'h' ? r.letter : firstLetter(r.kind === 's'
        ? (r.song !== null ? r.song.displayTitle() : '') : (r.artist !== null ? r.artist.name : ''));
      if (letterOrderKey(letter) >= letterOrderKey(target)) {
        scroller.scrollToIndex(i);
        return;
      }
    }
    if (items.length > 0) {
      scroller.scrollToIndex(items.length - 1);
    }
  }

  // 滚动联动索引条高亮:首个可见内容行的字母
  private letterIndexAt(rows: BasicDataSource<LibRow>, firstVisible: number): number {
    const items = rows.raw;
    for (let i = Math.max(0, firstVisible); i < items.length; i++) {
      const r = items[i];
      if (r.kind === 'h') {
        continue;
      }
      const letter = firstLetter(r.kind === 's'
        ? (r.song !== null ? r.song.displayTitle() : '') : (r.artist !== null ? r.artist.name : ''));
      return letterOrderKey(letter);
    }
    return 0;
  }

  private navStack(): NavPathStack | null {
    return AppStorage.get<NavPathStack>('navStack') ?? null;
  }

  // 最近添加:按入库时间倒序;展示前 10 首封面,队列取前 50(与「查看全部」smart added 一致)
  private rebuildRecent(): void {
    const sorted = LibraryStore.get().songs.filter((s: Song): boolean => s.dateAdded > 0)
      .sort((a: Song, b: Song): number => b.dateAdded - a.dateAdded);
    this.addedQueue = sorted.slice(0, 50);
    this.addedSongs = sorted.slice(0, 10);
  }

  // 智能列表当前选中项(我的收藏/播放历史/最常播放/最近添加)
  private smartList(): Song[] {
    if (this.smartIdx === 0) {
      return this.favSongs;
    }
    if (this.smartIdx === 1) {
      return this.hisSongs;
    }
    if (this.smartIdx === 2) {
      return this.mostSongs;
    }
    return this.addedSongs;
  }

  // 点击封面:以对应智能列表为队列起播(队列取前 50,与查看全部一致)
  private playFromSmart(idx: number): void {
    const list = this.smartList();
    if (idx < 0 || idx >= list.length) {
      return;
    }
    const q = QueueService.get();
    q.setQueueNow(list.slice(0, 50), idx, this.smartTitleStr());
    PlayerController.get().playQueueIndex(idx);
  }

  private smartTitleStr(): string {
    if (this.smartIdx === 0) {
      return Ls($r('app.string.my_favs'));
    }
    if (this.smartIdx === 1) {
      return Ls($r('app.string.play_history'));
    }
    if (this.smartIdx === 2) {
      return Ls($r('app.string.smart_most'));
    }
    return Ls($r('app.string.recent_added'));
  }

  // 「查看全部」:跳对应列表页
  private openSmartAll(): void {
    const stack = this.navStack();
    if (stack === null) {
      return;
    }
    if (this.smartIdx === 0) {
      stack.pushPathByName('SongList', SongListParam.favorites());
    } else if (this.smartIdx === 1) {
      stack.pushPathByName('SongList', SongListParam.smart('recent', Ls($r('app.string.play_history'))));
    } else if (this.smartIdx === 2) {
      stack.pushPathByName('SongList', SongListParam.smart('most', Ls($r('app.string.smart_most'))));
    } else {
      stack.pushPathByName('SongList', SongListParam.smart('added', Ls($r('app.string.recent_added'))));
    }
  }

  // 播放全部(0.17.0 #11):清空队列后将曲库全部歌曲(当前排序)加入播放队列并从首曲起播
  private playAllSongs(): void {
    const songs = this.sortSongList(LibraryStore.get().songs);
    if (songs.length === 0) {
      return;
    }
    const q = QueueService.get();
    q.setQueueNow(songs, 0, Ls($r('app.string.tab_library')));
    PlayerController.get().playQueueIndex(0);
  }

  build() {
    Column() {
      // 24-1 页头联动收起:整页(页头+内容)装进外层 Scroll,Swiper 定高留出页头余量——
      // 内容 List 经 nestedScroll(PARENT_FIRST/SELF_FIRST) 链接:上滑先收页头再滚列表,
      // 回滚先到顶再展开页头。总内容高=视口高+页头高(可收起距离)。
      Scroll() {
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
            .width(40)
            .height(40)
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

          // 智能列表 stack(0.17.0):我的收藏/播放历史/最常播放/最近添加,下方封面横滑行随选中切换
          if (this.songCount > 0) {
            Row({ space: 8 }) {
              TabSegmentButtonV2({
                items: SMART_ITEMS,
                selectedIndex: this.smartIdx,
                $selectedIndex: (i: number): void => {
                  this.smartIdx = i;
                }
              })
            }
            .width('100%')
            .padding({ left: 16, right: 16, bottom: 8 })

            this.SmartCoverRow()
          }

          // 收起后分段器停在状态栏下方:页头与分段器之间垫 topSafe 空档(随内容滚走)
          Blank().height(this.topSafe)

          Row({ space: 8 }) {
            TabSegmentButtonV2({
              items: SEG_ITEMS,
              selectedIndex: this.segmentIndex,
              // 点页签直接翻页(既有缺陷修复:此前 $selectedIndex 未接线,分段器点击无响应,只能滑内容切页)
              $selectedIndex: (i: number): void => {
                this.swiper.changeIndex(i, true);
              }
            })
              .layoutWeight(1)
            // 排序菜单(按当前分区出选项;0.14.0)
            Button({ stateEffect: true }) {
              SymbolGlyph($r('sys.symbol.sort'))
                .fontSize(16)
                .fontColor([$r('app.color.text_primary')])
            }
            .width(40)
            .height(40)
            .borderRadius(20)
            .backgroundColor($r('app.color.badge_bg'))
            .bindMenu(this.sortMenu)
          }
          .padding({ left: 16, right: 16, bottom: 8 })
          .width('100%')
          .onAreaChange((_o: Area, n: Area): void => {
            this.segH = n.height as number;
          })

          // Swiper 定高:视口 - 状态栏垫 - 分段器行 → 收起到底时分段器贴状态栏、内容占满
          Swiper(this.swiper) {
            this.SongsPage()
            this.AlbumsPage()
            this.ArtistsPage()
            PlaylistsTab({ mode: 'page' })
          }
          .index(this.segmentIndex)
          .onChange((i: number): void => {
            this.segmentIndex = i;
          })
          .width('100%')
          .height(Math.max(300, this.vpH - this.topSafe - this.segH))
          .indicator(false)
          .nestedScroll(SwiperNestedScrollMode.SELF_FIRST)
        }
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.None)
      .onAreaChange((_o: Area, n: Area): void => {
        this.vpH = n.height as number;
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.pageBg())
    .onAppear((): void => {
      if (this.sortsLoaded) {
        this.refreshAll();
      }
    })
  }

  // 智能列表封面横滑行:随 smartIdx 切换数据源;末尾「查看全部」占位封面跳对应列表
  @Builder
  SmartCoverRow() {
    if (this.smartList().length === 0) {
      Text($r('app.string.list_empty'))
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: 10, bottom: 16 })
    } else {
      List({ space: 10 }) {
        ForEach(this.smartList(), (s: Song, i: number) => {
          ListItem() {
            Column({ space: 4 }) {
              AlbumCover(s.artPath, 88)
              Text(s.displayTitle())
                .fontSize(11)
                .fontColor($r('app.color.text_primary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .width(88)
          }
            .onClick(() => {
              this.playFromSmart(i);
            })
        }, (s: Song): string => `sm_${this.smartIdx}_${s.id}`)
        // 「查看全部」占位封面 → 对应列表页
        ListItem() {
          Column({ space: 4 }) {
            Column({ space: 6 }) {
              SymbolGlyph($r('sys.symbol.arrow_right'))
                .fontSize(22)
                .fontColor([$r('app.color.text_secondary')])
              Text($r('app.string.view_all'))
                .fontSize(11)
                .fontColor($r('app.color.text_secondary'))
            }
            .width(88)
            .height(88)
            .borderRadius(10)
            .backgroundColor($r('app.color.badge_bg'))
            .justifyContent(FlexAlign.Center)
          }
          .width(88)
        }
          .onClick(() => {
            this.openSmartAll();
          })
      }
      .width('100%')
      .height(118)
      .listDirection(Axis.Horizontal) // 默认纵向被 118 高裁剪只露 1 项(用户实测);横向滑查看全部
      .padding({ left: 16, right: 16, bottom: 8 })
      .scrollBar(BarState.Off)
    }
  }

  // 排序菜单:按当前分区出选项(Menu 子组件仅允许 MenuItem;选中态靠列表重排自证)
  @Builder
  sortMenu() {
    Menu() {
      if (this.segmentIndex === 0) {
        MenuItem({ content: $r('app.string.sort_title') })
          .onClick(() => this.setSortSongs('title'))
        MenuItem({ content: $r('app.string.sort_artist') })
          .onClick(() => this.setSortSongs('artist'))
        MenuItem({ content: $r('app.string.sort_album') })
          .onClick(() => this.setSortSongs('album'))
        MenuItem({ content: $r('app.string.sort_added') })
          .onClick(() => this.setSortSongs('added'))
        MenuItem({ content: $r('app.string.sort_duration') })
          .onClick(() => this.setSortSongs('duration'))
      } else if (this.segmentIndex === 1) {
        MenuItem({ content: $r('app.string.sort_name') })
          .onClick(() => this.setSortAlbums('name'))
        MenuItem({ content: $r('app.string.sort_artist') })
          .onClick(() => this.setSortAlbums('artist'))
        MenuItem({ content: $r('app.string.sort_added') })
          .onClick(() => this.setSortAlbums('added'))
        MenuItem({ content: $r('app.string.sort_songs') })
          .onClick(() => this.setSortAlbums('songs'))
      } else if (this.segmentIndex === 2) {
        MenuItem({ content: $r('app.string.sort_name') })
          .onClick(() => this.setSortArtists('name'))
        MenuItem({ content: $r('app.string.sort_songs') })
          .onClick(() => this.setSortArtists('songs'))
      }
    }
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

  // 字母索引条(歌曲/艺人分区按名称排序时显示):右缘悬浮,点选跳组,滚动反向高亮。
  // 注意:内联写死读取 @State(this.songSel/this.artistSel)——@Builder 按值传参是快照不刷新(KB §8.2)
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
      Column() {
        // 播放全部(0.17.0 #11):stack 下方左侧;清空队列后将曲库全部歌曲加入播放队列并起播
        Row() {
          Button(L($r('app.string.play_all_n'), this.songCount))
            .fontSize(13)
            .fontColor($r('app.color.text_primary'))
            .backgroundColor($r('app.color.badge_bg'))
            .height(40)
            .borderRadius(20)
            .padding({ left: 16, right: 16 })
            .onClick(() => {
              this.playAllSongs();
            })
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 4 })

        Stack({ alignContent: Alignment.End }) {
        List({ space: 0, scroller: this.songsScroller }) {
          LazyForEach(this.songRows, (r: LibRow) => {
            ListItem() {
              if (r.kind === 'h') {
                Text(r.letter)
                  .fontSize(13)
                  .fontWeight(FontWeight.Bold)
                  .fontColor($r('app.color.text_secondary'))
                  .width('100%')
                  .padding({ left: 16, top: 10, bottom: 4 })
                  .backgroundColor(this.pageBg())
              } else {
                SongRow({
                  song: r.song as Song,
                  showAlbum: true,
                  listIds: this.songIdCache,
                  listTitle: Ls($r('app.string.tab_library'))
                })
              }
            }
          }, (r: LibRow): string => r.key())
        }
        .width('100%')
        .height('100%')
        .cachedCount(8)
        // 索引条浮层占位:按名称排序(索引条显示)时行内容右移,避免压住行内徽章
        .padding({ right: this.sortSongs === 'title' ? 26 : 0 })
        .contentEndOffset(this.bottomSafeVp + 140) // 视口全出血渲染到屏底,仅滚动终点避让(padding 会内缩视口裁行)
        .scrollBar(this.sortSongs === 'title' ? BarState.Off : BarState.Auto)
        .nestedScroll({ scrollForward: NestedScrollMode.PARENT_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
        .edgeEffect(EdgeEffect.None) // 内容不足一屏时防 Spring 回弹负 offset 误触迷你条展开
        .onWillScroll((offset: number): void => {
          BarCollapse.feed(offset);
        })
        .onScrollStop((): void => {
          BarCollapse.settle();
        })
        .onScrollIndex((first: number, _last: number): void => {
          if (this.sortSongs === 'title') {
            this.songSel = this.letterIndexAt(this.songRows, first);
          }
        })

        if (this.sortSongs === 'title') {
          AlphabetIndexer({ arrayValue: LETTERS, selected: this.songSel })
            .width(24)
            .height('65%')
            .usingPopup(true)
            .font({ size: 10 })
            .color($r('app.color.text_secondary'))
            .selectedColor($r('app.color.on_accent'))
            .selectedBackgroundColor($r('app.color.accent'))
            .popupColor($r('app.color.badge_text')) // 气泡字色:深棕(气泡底 badge_bg 浅色,白字不可见)
            .popupBackground($r('app.color.badge_bg'))
            .popupItemBackgroundColor($r('app.color.badge_bg'))
            .onSelect((idx: number): void => {
              this.jumpToLetter(this.songRows, this.songsScroller, idx);
            })
        }
        }
        .width('100%')
        .layoutWeight(1)
      }
      .width('100%')
      .height('100%')
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
              Text(a.groupArtist.length > 0 ? a.groupArtist : a.artist)
                .fontSize(11)
                .fontColor($r('app.color.text_secondary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .width('100%')
            .alignItems(HorizontalAlign.Center)
            .onClick(() => {
              const stack = this.navStack();
              if (stack !== null) {
                // 传分组键原值(album_artist):与详情页过滤键一致——传首曲 artist 会在
                // album_artist≠artist(合辑等)时查出空列表,即"空专辑"(0.17.0 #1)
                stack.pushPathByName('SongList', SongListParam.album(a.groupArtist, a.name));
              }
            })
          }
        }, (a: Album): string => a.key)
      }
      .columnsTemplate('1fr 1fr 1fr')
      .columnsGap(12)
      .rowsGap(16)
      .padding({ left: 16, right: 16 })
      .contentEndOffset(this.bottomSafeVp + 140) // 视口全出血渲染到屏底,仅滚动终点避让
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Auto)
      .nestedScroll({ scrollForward: NestedScrollMode.PARENT_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
      .edgeEffect(EdgeEffect.None) // 内容不足一屏时防 Spring 回弹负 offset 误触迷你条展开
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
      Stack({ alignContent: Alignment.End }) {
        List({ space: 2, scroller: this.artistsScroller }) {
          LazyForEach(this.artistRows, (r: LibRow) => {
            ListItem() {
              if (r.kind === 'h') {
                Text(r.letter)
                  .fontSize(13)
                  .fontWeight(FontWeight.Bold)
                  .fontColor($r('app.color.text_secondary'))
                  .width('100%')
                  .padding({ left: 16, top: 10, bottom: 4 })
                  .backgroundColor(this.pageBg())
              } else {
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
                  Text((r.artist as Artist).name)
                    .fontSize(15)
                    .fontColor($r('app.color.text_primary'))
                    .maxLines(1)
                    .layoutWeight(1)
                  Text(L($r('app.string.artist_stats'), (r.artist as Artist).albumCount, (r.artist as Artist).songCount))
                    .fontSize(11)
                    .fontColor($r('app.color.text_secondary'))
                }
                .width('100%')
                .padding({ left: 16, right: 16, top: 8, bottom: 8 })
                .onClick(() => {
                  const stack = this.navStack();
                  if (stack !== null) {
                    stack.pushPathByName('SongList', SongListParam.artist((r.artist as Artist).name));
                  }
                })
              }
            }
          }, (r: LibRow): string => r.key())
        }
        .width('100%')
        .height('100%')
        .padding({ right: this.sortArtists === 'name' ? 26 : 0 }) // 索引条浮层占位
        .contentEndOffset(this.bottomSafeVp + 140) // 视口全出血渲染到屏底,仅滚动终点避让
        .scrollBar(this.sortArtists === 'name' ? BarState.Off : BarState.Auto)
        .nestedScroll({ scrollForward: NestedScrollMode.PARENT_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
        .edgeEffect(EdgeEffect.None) // 内容不足一屏时防 Spring 回弹负 offset 误触迷你条展开
        .onWillScroll((offset: number): void => {
          BarCollapse.feed(offset);
        })
        .onScrollStop((): void => {
          BarCollapse.settle();
        })
        .onScrollIndex((first: number, _last: number): void => {
          if (this.sortArtists === 'name') {
            this.artistSel = this.letterIndexAt(this.artistRows, first);
          }
        })

        if (this.sortArtists === 'name') {
          AlphabetIndexer({ arrayValue: LETTERS, selected: this.artistSel })
            .width(24)
            .height('65%')
            .usingPopup(true)
            .font({ size: 10 })
            .color($r('app.color.text_secondary'))
            .selectedColor($r('app.color.on_accent'))
            .selectedBackgroundColor($r('app.color.accent'))
            .popupColor($r('app.color.badge_text')) // 气泡字色:深棕(气泡底 badge_bg 浅色,白字不可见)
            .popupBackground($r('app.color.badge_bg'))
            .popupItemBackgroundColor($r('app.color.badge_bg'))
            .onSelect((idx: number): void => {
              this.jumpToLetter(this.artistRows, this.artistsScroller, idx);
            })
        }
      }
      .width('100%')
      .height('100%')
    }
  }
}

// 分区:歌曲/专辑/艺人/歌单(0.17.0:流派→歌单——实测流派标签长期为空,歌单更有价值)
const SEG_ITEMS: SegmentButtonV2Items = new SegmentButtonV2Items([
  new SegmentButtonV2Item({ text: $r('app.string.str_songs') }),
  new SegmentButtonV2Item({ text: $r('app.string.str_albums') }),
  new SegmentButtonV2Item({ text: $r('app.string.str_artists') }),
  new SegmentButtonV2Item({ text: $r('app.string.str_playlists') })
]);

// 顶部智能列表 stack:顺序按用户约定(我的收藏/播放历史/最常播放/最近添加)
const SMART_ITEMS: SegmentButtonV2Items = new SegmentButtonV2Items([
  new SegmentButtonV2Item({ text: $r('app.string.my_favs') }),
  new SegmentButtonV2Item({ text: $r('app.string.play_history') }),
  new SegmentButtonV2Item({ text: $r('app.string.smart_most') }),
  new SegmentButtonV2Item({ text: $r('app.string.recent_added') })
]);


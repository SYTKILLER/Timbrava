// 库内存聚合:一次全查 songs 表,内存构建 歌曲/专辑/艺人/流派/目录树(借鉴 Gramophone)。
// 列表页经 AppStorage 版本号(libVer)订阅刷新。
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Db } from './Db';
import { Song, Album, Artist, Genre, FolderNode } from './Model';
import { L } from '../common/Lang';

const TAG = '[Timbrava][Library]';
const DOMAIN = 0x0001;

export const DEFAULT_ORDER: string =
  'album_artist COLLATE NOCASE, album COLLATE NOCASE, disc_no, track_no, title COLLATE NOCASE';

export class LibraryStore {
  private static instance: LibraryStore | null = null;
  static get(): LibraryStore {
    if (LibraryStore.instance === null) {
      LibraryStore.instance = new LibraryStore();
    }
    return LibraryStore.instance;
  }

  songs: Song[] = [];
  albums: Album[] = [];
  artists: Artist[] = [];
  genres: Genre[] = [];
  folderRoot: FolderNode = new FolderNode();
  favoriteIds: Set<number> = new Set<number>();
  loaded: boolean = false;

  private songById: Map<number, Song> = new Map();

  bump(): void {
    AppStorage.setOrCreate('libVer', (AppStorage.get<number>('libVer') ?? 0) + 1);
  }

  async reload(): Promise<void> {
    if (!Db.get().ready()) {
      return;
    }
    try {
      this.songs = await Db.get().querySongs('', [], DEFAULT_ORDER, 1000000, 0);
      this.songById = new Map<number, Song>();
      for (const s of this.songs) {
        this.songById.set(s.id, s);
      }
      this.rebuildAggregates();
      this.favoriteIds = await Db.get().getFavoriteIds();
      this.loaded = true;
      this.bump();
      hilog.info(DOMAIN, TAG, 'loaded songs=%{public}d albums=%{public}d artists=%{public}d genres=%{public}d',
        this.songs.length, this.albums.length, this.artists.length, this.genres.length);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'reload fail %{public}s', (e as Error).message);
    }
  }

  song(id: number): Song | null {
    return this.songById.get(id) ?? null;
  }

  isFavorite(id: number): boolean {
    return this.favoriteIds.has(id);
  }

  async setFavorite(id: number, fav: boolean): Promise<void> {
    await Db.get().setFavorite(id, fav);
    if (fav) {
      this.favoriteIds.add(id);
    } else {
      this.favoriteIds.delete(id);
    }
    this.bump();
  }

  private static orderKey(s: Song): string {
    return `${s.albumArtist}\u0001${s.album}\u0001${s.discNo}\u0001${s.trackNo}\u0001${s.title}`;
  }

  rebuildAggregates(): void {
    // 专辑
    const albumMap = new Map<string, Album>();
    // 艺人(专辑艺人优先,回退艺人)
    const artistMap = new Map<string, Artist>();
    // 流派
    const genreMap = new Map<string, Genre>();
    // 目录树
    const dirMap = new Map<string, FolderNode>();

    this.albums = [];
    this.artists = [];
    this.genres = [];
    this.folderRoot = new FolderNode();

    for (const s of this.songs) {
      // 专辑
      const aKey = `${s.albumArtist}\u0001${s.album}`;
      let album = albumMap.get(aKey);
      if (album === undefined) {
        album = new Album();
        album.key = aKey;
        album.name = s.displayAlbum();
        album.artist = s.displayArtist();
        album.groupArtist = s.albumArtist; // 分组键原值:详情过滤/点击传参用它,用首曲 artist 会在 album_artist≠artist 时查出空列表
        album.artPath = s.artPath;
        album.year = s.year;
        albumMap.set(aKey, album);
      }
      album.songIds.push(s.id);
      if (album.artPath.length === 0 && s.artPath.length > 0) {
        album.artPath = s.artPath;
      }
      if (album.year === 0 && s.year > 0) {
        album.year = s.year;
      }
      // 艺人
      const arName = s.displayArtist();
      let artist = artistMap.get(arName);
      if (artist === undefined) {
        artist = new Artist();
        artist.key = arName;
        artist.name = arName;
        artistMap.set(arName, artist);
      }
      artist.songIds.push(s.id);
      // 流派
      const gName = s.genre.length > 0 ? s.genre : L($r('app.string.unknown_genre'));
      let genre = genreMap.get(gName);
      if (genre === undefined) {
        genre = new Genre();
        genre.name = gName;
        genreMap.set(gName, genre);
      }
      genre.songIds.push(s.id);
      // 目录
      const sep = s.path.lastIndexOf('/');
      const dir = sep > 0 ? s.path.substring(0, sep) : '/';
      let node = dirMap.get(dir);
      if (node === undefined) {
        node = new FolderNode();
        node.dirPath = dir;
        node.name = dir.substring(dir.lastIndexOf('/') + 1);
        dirMap.set(dir, node);
      }
      node.songIds.push(s.id);
    }

    this.albums = Array.from(albumMap.values());
    this.artists = Array.from(artistMap.values());
    this.genres = Array.from(genreMap.values());
    for (const a of this.artists) {
      a.songCount = a.songIds.length;
      const albumSet = new Set<string>();
      for (const id of a.songIds) {
        const s = this.songById.get(id);
        if (s !== undefined) {
          albumSet.add(`${s.albumArtist}\u0001${s.album}`);
        }
      }
      a.albumCount = albumSet.size;
    }
    for (const g of this.genres) {
      g.songCount = g.songIds.length;
    }
    this.albums.sort((x, y) => x.name.localeCompare(y.name));
    this.artists.sort((x, y) => x.name.localeCompare(y.name));
    this.genres.sort((x, y) => x.name.localeCompare(y.name));

    // 目录树
    const nodes = Array.from(dirMap.values()).sort((x, y) => x.dirPath.localeCompare(y.dirPath));
    for (const n of nodes) {
      if (n.dirPath === '/') {
        continue;
      }
      const parentDir = n.dirPath.substring(0, n.dirPath.lastIndexOf('/'));
      const parent = dirMap.get(parentDir);
      if (parent !== undefined && parent !== n) {
        parent.children.push(n);
      } else {
        this.folderRoot.children.push(n);
      }
    }
  }
}

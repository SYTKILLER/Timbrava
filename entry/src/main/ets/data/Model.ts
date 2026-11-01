// 数据模型(纯 .ts:可被 .ets 与 .ts 双向引用;不做任何 UI/系统调用)

export enum RepeatMode {
  OFF = 0,
  ALL = 1,
  ONE = 2,
}

export class Song {
  id: number = 0;
  path: string = '';
  fileSize: number = 0;
  mtime: number = 0;
  title: string = '';
  artist: string = '';
  album: string = '';
  albumArtist: string = '';
  genre: string = '';
  year: number = 0;
  trackNo: number = 0;
  discNo: number = 0;
  durationMs: number = 0;
  sampleRate: number = 0;
  bitDepth: number = 0;
  channels: number = 0;
  bitrateKbps: number = 0;
  codec: string = '';
  cueStartMs: number = 0;
  cueEndMs: number = -1;
  artPath: string = '';
  rgTrackGain: number = 0;
  rgTrackPeak: number = 0;
  rgAlbumGain: number = 0;
  rgAlbumPeak: number = 0;

  // 展示辅助
  specBadge(): string {
    if (this.sampleRate <= 0) {
      return '';
    }
    const khz = (Math.round(this.sampleRate / 100) / 10).toFixed(1);
    if (this.codec === 'dsd') {
      return `DSD`;
    }
    return `${this.bitDepth}bit/${khz}k`;
  }

  displayTitle(): string {
    return this.title.length > 0 ? this.title : this.path.substring(this.path.lastIndexOf('/') + 1);
  }

  displayArtist(): string {
    return this.artist.length > 0 ? this.artist : '未知艺人';
  }

  displayAlbum(): string {
    return this.album.length > 0 ? this.album : '未知专辑';
  }

  static fromJson(o: Record<string, Object | null>): Song {
    const s = new Song();
    s.id = Number(o['id'] ?? 0);
    s.path = String(o['path'] ?? '');
    s.fileSize = Number(o['file_size'] ?? 0);
    s.mtime = Number(o['mtime'] ?? 0);
    s.title = String(o['title'] ?? '');
    s.artist = String(o['artist'] ?? '');
    s.album = String(o['album'] ?? '');
    s.albumArtist = String(o['album_artist'] ?? '');
    s.genre = String(o['genre'] ?? '');
    s.year = Number(o['year'] ?? 0);
    s.trackNo = Number(o['track_no'] ?? 0);
    s.discNo = Number(o['disc_no'] ?? 0);
    s.durationMs = Number(o['duration_ms'] ?? 0);
    s.sampleRate = Number(o['sample_rate'] ?? 0);
    s.bitDepth = Number(o['bit_depth'] ?? 0);
    s.channels = Number(o['channels'] ?? 0);
    s.bitrateKbps = Number(o['bitrate_kbps'] ?? 0);
    s.codec = String(o['codec'] ?? '');
    s.cueStartMs = Number(o['cue_start_ms'] ?? 0);
    s.cueEndMs = Number(o['cue_end_ms'] ?? -1);
    s.artPath = String(o['art_path'] ?? '');
    s.rgTrackGain = Number(o['rg_track_gain'] ?? 0);
    s.rgTrackPeak = Number(o['rg_track_peak'] ?? 0);
    s.rgAlbumGain = Number(o['rg_album_gain'] ?? 0);
    s.rgAlbumPeak = Number(o['rg_album_peak'] ?? 0);
    return s;
  }
}

export class Album {
  key: string = '';
  name: string = '未知专辑';
  artist: string = '';
  artPath: string = '';
  year: number = 0;
  songIds: number[] = [];

  constructor() {
  }
}

export class Artist {
  key: string = '';
  name: string = '';
  albumCount: number = 0;
  songCount: number = 0;
  songIds: number[] = [];

  constructor() {
  }
}

export class Genre {
  name: string = '';
  songCount: number = 0;
  songIds: number[] = [];

  constructor() {
  }
}

// 目录树节点(内存构建)
export class FolderNode {
  name: string = '';
  dirPath: string = ''; // 完整目录路径
  songIds: number[] = []; // 直接位于本目录的歌曲
  children: FolderNode[] = [];

  constructor() {
  }

  countSongsRecursive(): number {
    let n = this.songIds.length;
    for (const c of this.children) {
      n += c.countSongsRecursive();
    }
    return n;
  }
}

export class ScanProgress {
  state: string = 'idle'; // idle | scanning | done | error
  current: number = 0;
  total: number = 0;
  added: number = 0;
  updated: number = 0;
  removed: number = 0;
  message: string = '';

  constructor() {
  }
}

export class RootFolder {
  type: string = 'path'; // path | uri
  value: string = '';

  constructor(type: string, value: string) {
    this.type = type;
    this.value = value;
  }

  static fromJson(o: Record<string, Object | null>): RootFolder | null {
    const t = String(o['type'] ?? '');
    const v = String(o['value'] ?? '');
    if ((t === 'path' || t === 'uri') && v.length > 0) {
      return new RootFolder(t, v);
    }
    return null;
  }
}

export function formatDuration(ms: number): string {
  const total = Math.max(0, Math.floor(ms / 1000));
  const m = Math.floor(total / 60);
  const s = total % 60;
  return `${m}:${s < 10 ? '0' : ''}${s}`;
}

export function formatSize(bytes: number): string {
  if (bytes >= 1024 * 1024 * 1024) {
    return `${(bytes / 1024 / 1024 / 1024).toFixed(2)} GB`;
  }
  if (bytes >= 1024 * 1024) {
    return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
  }
  if (bytes >= 1024) {
    return `${(bytes / 1024).toFixed(0)} KB`;
  }
  return `${bytes} B`;
}

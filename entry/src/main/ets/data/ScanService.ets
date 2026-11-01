// 媒体库扫描:根目录(路径/URI)递归遍历 → 扩展名过滤 → 标签解析 → 差分入库 → 封面缓存。
import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { relationalStore } from '@kit.ArkData';
import { Db } from './Db';
import { LibraryStore } from './LibraryStore';
import { Song, ScanProgress, RootFolder } from './Model';
import { isAudioExt, parseAudioMeta, SongMeta } from './tag/MetaParse';
import { fnv1a } from './tag/Bytes';

const TAG = '[Timbrava][Scan]';
const DOMAIN = 0x0001;

export class ScanService {
  private static instance: ScanService | null = null;
  static get(): ScanService {
    if (ScanService.instance === null) {
      ScanService.instance = new ScanService();
    }
    return ScanService.instance;
  }

  private progress: ScanProgress = new ScanProgress();
  private scanning: boolean = false;
  private context: common.Context | null = null;

  init(context: common.Context): void {
    this.context = context;
  }

  getProgress(): ScanProgress {
    return this.progress;
  }

  isScanning(): boolean {
    return this.scanning;
  }

  private bump(): void {
    AppStorage.setOrCreate('scanVer', (AppStorage.get<number>('scanVer') ?? 0) + 1);
  }

  // 全量重扫:遍历全部根目录;增量(按 mtime/size 差分)
  async rescan(): Promise<void> {
    if (this.scanning) {
      hilog.warn(DOMAIN, TAG, '已在扫描中,忽略');
      return;
    }
    if (this.context === null || !Db.get().ready()) {
      hilog.error(DOMAIN, TAG, '未初始化,拒绝扫描');
      return;
    }
    this.scanning = true;
    this.progress = new ScanProgress();
    this.progress.state = 'scanning';
    this.bump();
    const started = Date.now();
    hilog.info(DOMAIN, TAG, 'scan start');
    try {
      const roots = await Db.get().getRootFolders();
      let removed = 0;
      const candidates: FileCandidate[] = [];
      for (const root of roots) {
        const files: FileCandidate[] = await this.walkRoot(root);
        for (const f of files) {
          candidates.push(f);
        }
      }
      this.progress.total = candidates.length;
      this.bump();
      hilog.info(DOMAIN, TAG, 'candidates=%{public}d', candidates.length);

      // 差分:读库里同根目录已有记录(path→mtime/size)
      const seenPaths = new Set<string>();
      let idx = 0;
      for (const cand of candidates) {
        idx++;
        seenPaths.add(cand.path);
        let st: fs.Stat | null = null;
        try {
          st = await fs.stat(cand.uriOrPath);
          if (st !== null && !isAudioExt(cand.name)) {
            continue;
          }
          const mtime = st !== null ? Math.floor(st.mtime) : 0;
          const fsize = st !== null ? st.size : 0;
          const known = await Db.get().querySongs('path = ?', [cand.path], '', 1, 0);
          if (known.length === 1 && known[0].mtime === mtime && known[0].fileSize === fsize) {
            // 未变化
          } else {
            const ok = await this.parseAndStore(cand, mtime, fsize);
            if (ok) {
              if (known.length === 0) {
                this.progress.added++;
              } else {
                this.progress.updated++;
              }
            }
          }
        } catch (e) {
          hilog.warn(DOMAIN, TAG, 'stat/parse fail %{public}s %{public}s', cand.path, (e as Error).message);
        } finally {
          st = null;
        }
        this.progress.current = idx;
        if (idx % 5 === 0 || idx === candidates.length) {
          this.bump();
        }
      }

      // 清理:库中属于已扫根目录但本轮未见的记录
      for (const root of roots) {
        const prefix = root.type === 'path' ? root.value : `uri:${root.value}`;
        const dbPaths = await Db.get().getSongsByPathPrefix(prefix);
        for (const p of dbPaths) {
          if (!seenPaths.has(p)) {
            await Db.get().deleteSongsByPaths([p]);
            removed++;
          }
        }
      }
      this.progress.removed = removed;
      this.progress.state = 'done';
      this.progress.message = `新增 ${this.progress.added} · 更新 ${this.progress.updated} · 移除 ${removed}`;
      hilog.info(DOMAIN, TAG, 'scan done in %{public}dms added=%{public}d updated=%{public}d removed=%{public}d',
        Date.now() - started, this.progress.added, this.progress.updated, removed);
    } catch (e) {
      this.progress.state = 'error';
      this.progress.message = (e as Error).message;
      hilog.error(DOMAIN, TAG, 'scan fail %{public}s', (e as Error).message);
    } finally {
      this.scanning = false;
      this.bump();
      await LibraryStore.get().reload();
    }
  }

  // 解析单文件并入库(含封面缓存)
  async parseAndStore(cand: FileCandidate, mtime: number, fsize: number): Promise<boolean> {
    if (this.context === null) {
      return false;
    }
    let file: fs.File | null = null;
    try {
      file = await fs.open(cand.uriOrPath, fs.OpenMode.READ_ONLY);
      const fd = file.fd;
      const readAt = (off: number, len: number): Uint8Array => {
        const buf = new ArrayBuffer(len);
        const n = fs.readSync(fd, buf, { offset: off, length: len });
        return new Uint8Array(buf, 0, n);
      };
      const meta: SongMeta = parseAudioMeta(cand.name, fsize, readAt, readAt);
      if (!meta.ok) {
        hilog.warn(DOMAIN, TAG, 'parse fail(跳过) %{public}s', cand.path);
        return false;
      }
      const s = new Song();
      s.path = cand.path;
      s.fileSize = fsize;
      s.mtime = mtime;
      s.title = meta.title;
      s.artist = meta.artist;
      s.album = meta.album;
      s.albumArtist = meta.albumArtist.length > 0 ? meta.albumArtist : meta.artist;
      s.genre = meta.genre;
      s.year = meta.year;
      s.trackNo = meta.trackNo;
      s.discNo = meta.discNo;
      s.durationMs = meta.durationMs;
      s.sampleRate = meta.sampleRate;
      s.bitDepth = meta.bitDepth;
      s.channels = meta.channels;
      s.bitrateKbps = meta.bitrateKbps;
      s.codec = meta.codec;
      s.rgTrackGain = meta.rgTrackGain;
      s.rgTrackPeak = meta.rgTrackPeak;
      s.rgAlbumGain = meta.rgAlbumGain;
      s.rgAlbumPeak = meta.rgAlbumPeak;
      if (meta.coverData !== null && meta.coverData.length > 0) {
        s.artPath = await this.saveCover(meta.coverData, meta.coverMime, fsize, mtime);
      }
      const known = await Db.get().querySongs('path = ?', [cand.path], '', 1, 0);
      if (known.length > 0) {
        s.id = known[0].id;
        const bucket: relationalStore.ValuesBucket = {
          'title': s.title, 'artist': s.artist, 'album': s.album, 'album_artist': s.albumArtist,
          'genre': s.genre, 'year': s.year, 'track_no': s.trackNo, 'disc_no': s.discNo,
          'duration_ms': s.durationMs, 'sample_rate': s.sampleRate, 'bit_depth': s.bitDepth,
          'channels': s.channels, 'bitrate_kbps': s.bitrateKbps, 'codec': s.codec,
          'file_size': s.fileSize, 'mtime': s.mtime, 'art_path': s.artPath,
          'rg_track_gain': s.rgTrackGain, 'rg_track_peak': s.rgTrackPeak
        };
        await Db.get().updateSongFields(s.id, bucket);
      } else {
        s.id = await Db.get().upsertSong(s, false);
      }
      hilog.debug(DOMAIN, TAG, 'stored [%{public}s] %{public}s %{public}dms %{public}dbit/%{public}d',
        s.codec, s.title, s.durationMs, s.bitDepth, s.sampleRate);
      return true;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'parseAndStore fail %{public}s %{public}s', cand.path, (e as Error).message);
      return false;
    } finally {
      if (file !== null) {
        try {
          fs.closeSync(file);
        } catch (e) {
        }
      }
    }
  }

  private async saveCover(data: Uint8Array, mime: string, fsize: number, mtime: number): Promise<string> {
    if (this.context === null) {
      return '';
    }
    const dir = `${this.context.filesDir}/art`;
    try {
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir, true);
      }
    } catch (e) {
      try {
        fs.mkdirSync(dir, true);
      } catch (e2) {
        return '';
      }
    }
    const ext = mime.indexOf('png') >= 0 ? 'png' : 'jpg';
    const h1 = fnv1a(data.subarray(0, Math.min(data.length, 4096)));
    const name = `${h1.toString(16)}_${(fsize % 100000)}_${(mtime % 100000)}.${ext}`;
    const path = `${dir}/${name}`;
    try {
      if (fs.accessSync(path)) {
        return path;
      }
      const f = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      // subarray 共享底层 buffer,先拷贝成独立 ArrayBuffer 再写
      const standalone: ArrayBuffer = data.slice().buffer as ArrayBuffer;
      fs.writeSync(f.fd, standalone);
      fs.closeSync(f);
      return path;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'saveCover fail %{public}s', (e as Error).message);
      return '';
    }
  }

  // 遍历一个根目录(path 类型)
  private async walkRoot(root: RootFolder): Promise<FileCandidate[]> {
    const out: FileCandidate[] = [];
    if (root.type === 'path') {
      try {
        const names = await fs.listFile(root.value, { recursion: true });
        for (const rel of names) {
          // rel 以 '/' 开头:相对根的路径
          const name = rel.substring(rel.lastIndexOf('/') + 1);
          if (!isAudioExt(name)) {
            continue;
          }
          const dirPath = root.value.endsWith('/') ? root.value : `${root.value}/`;
          const fullPath = `${dirPath}${rel.startsWith('/') ? rel.substring(1) : rel}`;
          out.push(new FileCandidate(name, fullPath, fullPath));
        }
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'listFile fail %{public}s %{public}s', root.value, (e as Error).message);
      }
    } else {
      // URI 根:尝试直接 listFile(URI);失败则提示走路径模式
      try {
        const names = await fs.listFile(root.value, { recursion: true });
        for (const rel of names) {
          const name = rel.substring(rel.lastIndexOf('/') + 1);
          if (!isAudioExt(name)) {
            continue;
          }
          const childUri = `${root.value}${root.value.endsWith('/') ? '' : '/'}${rel.startsWith('/') ? rel.substring(1) : rel}`;
          out.push(new FileCandidate(name, `uri:${childUri}`, childUri));
        }
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'listFile(URI) fail %{public}s %{public}s', root.value, (e as Error).message);
      }
    }
    return out;
  }
}

export class FileCandidate {
  name: string;
  path: string;       // 库中稳定键(path 或 uri:xxx)
  uriOrPath: string;  // fs 打开用(URI 或真实路径)

  constructor(name: string, path: string, uriOrPath: string) {
    this.name = name;
    this.path = path;
    this.uriOrPath = uriOrPath;
  }
}

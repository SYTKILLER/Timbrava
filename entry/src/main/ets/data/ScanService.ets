// 媒体库扫描:根目录(路径/URI)递归遍历 → 扩展名过滤 → 标签解析 → 差分入库 → 封面缓存。
import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { relationalStore } from '@kit.ArkData';
import { Db } from './Db';
import { LibraryStore } from './LibraryStore';
import { Song, ScanProgress, RootFolder } from './Model';
import { isAudioExt, parseAudioMeta, SongMeta } from './tag/MetaParse';
import { parseCue, looksLikeCue, CueSheet } from './cue/CueParser';
import { ReadAt } from './tag/MetaParse';
import timbravaCore from 'libtimbrava_core.so';
import { fnv1a } from './tag/Bytes';
import { L } from '../common/Lang';

const TAG = '[Timbrava][Scan]';

class ManifestEntry {
  name: string = '';
  size: number = 0;
}
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
      const blacklist = await Db.get().getBlacklist();
      const isBlocked = (p: string): boolean => {
        for (const b of blacklist) {
          if (b.length > 0 && p.startsWith(b)) {
            return true;
          }
        }
        return false;
      };
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
        if (isBlocked(cand.path)) {
          continue;
        }
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
      this.progress.message = L($r('app.string.scan_progress_stats'), this.progress.added, this.progress.updated, removed);
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

  // 调试通道:确保沙箱语料根已注册(mkdir + chmod 宿主可写 + 登记)
  async ensureSandboxRoot(): Promise<void> {
    if (this.context === null) {
      return;
    }
    const dir = `${this.context.filesDir}/music`;
    try {
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir, true);
      }
    } catch (e) {
      try {
        fs.mkdirSync(dir, true);
      } catch (e2) {
        return;
      }
    }
    // 宿主 shell 写入授权(P0 验证通道同款)
    try {
      timbravaCore.chmodPath(this.context.filesDir, 0o775);
      timbravaCore.chmodPath(dir, 0o777);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'chmod fail %{public}s', (e as Error).message);
    }
    const roots = await Db.get().getRootFolders();
    const exists = roots.find((r: RootFolder): boolean => r.value === dir);
    if (exists === undefined) {
      roots.push(new RootFolder('path', dir));
      await Db.get().setRootFolders(roots);
      hilog.info(DOMAIN, TAG, 'sandbox root registered: %{public}s', dir);
    }
  }

  // ============ 调试导入通道(宿主机 HTTP,经 hdc rport 反向隧道) ============

  private importing: boolean = false;

  async importFromHost(): Promise<void> {
    if (this.importing) {
      return;
    }
    this.importing = true;
    if (this.context === null) {
      this.importing = false;
      return;
    }
    const dir = `${this.context.filesDir}/music`;
    try {
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir, true);
      }
    } catch (e) {
      this.importing = false;
      return;
    }
    const base = 'http://127.0.0.1:8100';
    try {
      const manifestBuf = await this.httpGetBuffer(`${base}/manifest.json`);
      const entries: ManifestEntry[] = JSON.parse(this.abToString(new Uint8Array(manifestBuf))) as ManifestEntry[];
      hilog.info(DOMAIN, TAG, 'import manifest n=%{public}d', entries.length);
      for (const ent of entries) {
        const dest = `${dir}/${ent.name}`;
        let existing = -1;
        try {
          if (fs.accessSync(dest)) {
            existing = fs.statSync(dest).size;
          }
        } catch (e) {
          existing = -1;
        }
        if (existing === ent.size) {
          hilog.info(DOMAIN, TAG, 'skip ok %{public}s size=%{public}d', ent.name, existing);
          continue;
        }
        hilog.info(DOMAIN, TAG, 'need %{public}s existing=%{public}d want=%{public}d', ent.name, existing, ent.size);
        let ok = false;
        for (let attempt = 0; attempt < 3 && !ok; attempt++) {
          try {
            await this.httpDownloadToFile(`${base}/${encodeURIComponent(ent.name)}`, dest, ent.size);
            ok = true;
          } catch (e) {
            hilog.warn(DOMAIN, TAG, 'attempt %{public}d fail %{public}s', attempt, (e as Error).message);
          }
        }
      }
      hilog.info(DOMAIN, TAG, 'import done');
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'importFromHost fail %{public}s', (e as Error).message);
    } finally {
      this.importing = false;
    }
  }

  private async httpGetBuffer(url: string): Promise<ArrayBuffer> {
    const req = http.createHttp();
    try {
      const resp = await req.request(url, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 5000,
        readTimeout: 10000
      });
      if (resp.responseCode >= 300) {
        throw new Error(`http ${resp.responseCode}`);
      }
      return resp.result as ArrayBuffer;
    } finally {
      req.destroy();
    }
  }

  // Range 分块下载:每 48KB 一条新连接(绕模拟器 rport 隧道 64KB 停摆问题)
  private async httpDownloadToFile(url: string, dest: string, wantSize: number): Promise<void> {
    const CHUNK = 48 * 1024;
    let file: fs.File | null = null;
    try {
      file = fs.openSync(dest, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      let pos = 0;
      while (pos < wantSize) {
        const end = Math.min(pos + CHUNK, wantSize) - 1;
        const buf = await this.httpGetRange(`${url}`, pos, end);
        if (buf.byteLength <= 0) {
          throw new Error(`empty chunk at ${pos}`);
        }
        const standalone: ArrayBuffer = buf.slice(0);
        fs.writeSync(file.fd, standalone, { offset: pos, length: buf.byteLength });
        pos += buf.byteLength;
      }
      hilog.info(DOMAIN, TAG, 'download done %{public}s bytes=%{public}d', dest, pos);
    } finally {
      if (file !== null) {
        try {
          fs.closeSync(file);
        } catch (e2) {
        }
      }
    }
  }

  private async httpGetRange(url: string, from: number, to: number): Promise<ArrayBuffer> {
    let lastErr: Error = new Error('range fetch failed');
    for (let attempt = 0; attempt < 4; attempt++) {
      const req = http.createHttp();
      try {
        const resp = await req.request(url, {
          method: http.RequestMethod.GET,
          expectDataType: http.HttpDataType.ARRAY_BUFFER,
          connectTimeout: 4000,
          readTimeout: 12000,
          header: { 'Range': `bytes=${from}-${to}` }
        });
        if (resp.responseCode === 206 || resp.responseCode === 200) {
          return resp.result as ArrayBuffer;
        }
        lastErr = new Error(`http ${resp.responseCode}`);
      } catch (e) {
        lastErr = e as Error;
      } finally {
        req.destroy();
      }
    }
    throw lastErr;
  }

  private abToString(u8: Uint8Array): string {
    let out = '';
    for (let i = 0; i < u8.length; i++) {
      out += String.fromCharCode(u8[i]);
    }
    return out;
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
      const readAt: ReadAt = (off: number, len: number): Uint8Array => {
        const buf = new ArrayBuffer(len);
        const n = fs.readSync(fd, buf, { offset: off, length: len });
        return new Uint8Array(buf, 0, n);
      };
      if (cand.name.toLowerCase().endsWith('.cue')) {
        return await this.parseCueFile(cand, fsize, mtime);
      }
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

  // CUE 分轨:cue 同目录音频文件 → 每轨一条记录(同 path 多行,cue_start_ms/cue_end_ms 裁剪)
  private async parseCueFile(cand: FileCandidate, fsize: number, mtime: number): Promise<boolean> {
    try {
      let cueFile: fs.File | null = null;
      let audioFile: fs.File | null = null;
      try {
        cueFile = await fs.open(cand.uriOrPath, fs.OpenMode.READ_ONLY);
        const cueFd = cueFile.fd;
        const readCue: ReadAt = (off: number, len: number): Uint8Array => {
          const buf = new ArrayBuffer(len);
          const n = fs.readSync(cueFd, buf, { offset: off, length: len });
          return new Uint8Array(buf, 0, n);
        };
        const text = this.abToString(readCue(0, Math.min(fsize, 512 * 1024)));
        if (!looksLikeCue(text)) {
          return false;
        }
        const sheet: CueSheet = parseCue(text);
        if (!sheet.valid()) {
          return false;
        }
        const dir = cand.path.substring(0, cand.path.lastIndexOf('/') + 1);
        const audioPath = `${dir}${sheet.audioFile.split('\\').join('/')}`;
        // 音频头解析(时长/编码/位深/封面)
        let audioDurMs = 0;
        let audioArt = '';
        let codec = '';
        let sr = 0;
        let bd = 0;
        const known = await Db.get().querySongs('path = ? AND cue_start_ms = 0', [audioPath], '', 1, 0);
        if (known.length > 0) {
          audioDurMs = known[0].durationMs;
          audioArt = known[0].artPath;
          codec = known[0].codec;
          sr = known[0].sampleRate;
          bd = known[0].bitDepth;
        } else {
          try {
            audioFile = await fs.open(audioPath, fs.OpenMode.READ_ONLY);
            const aFd = audioFile.fd;
            const readAudio: ReadAt = (off: number, len: number): Uint8Array => {
              const buf = new ArrayBuffer(len);
              const n = fs.readSync(aFd, buf, { offset: off, length: len });
              return new Uint8Array(buf, 0, n);
            };
            let aSize = 0;
            try {
              aSize = fs.statSync(audioPath).size;
            } catch (e) {
              aSize = 0;
            }
            const meta = parseAudioMeta(sheet.audioFile, aSize, readAudio, readAudio);
            codec = meta.codec;
            sr = meta.sampleRate;
            bd = meta.bitDepth;
            audioDurMs = meta.durationMs;
            if (meta.coverData !== null && meta.coverData.length > 0) {
              audioArt = await this.saveCover(meta.coverData, meta.coverMime, aSize, mtime);
            }
          } catch (e) {
            hilog.warn(DOMAIN, TAG, 'cue audio probe fail %{public}s', (e as Error).message);
          }
        }
        let added = 0;
        for (const t of sheet.tracks) {
          const song = new Song();
          song.path = audioPath;
          song.fileSize = fsize;
          song.mtime = mtime;
          song.title = t.title.length > 0 ? t.title : `${sheet.albumTitle} Track ${t.index}`;
          song.artist = t.performer.length > 0 ? t.performer : sheet.albumPerformer;
          song.album = sheet.albumTitle;
          song.albumArtist = sheet.albumPerformer;
          song.trackNo = t.index;
          song.durationMs = t.endMs > t.startMs ? t.endMs - t.startMs : Math.max(0, audioDurMs - t.startMs);
          song.sampleRate = sr;
          song.bitDepth = bd;
          song.codec = codec;
          song.cueStartMs = t.startMs;
          song.cueEndMs = t.endMs;
          song.artPath = audioArt;
          const dup = await Db.get().querySongs('path = ? AND cue_start_ms = ?', [audioPath, t.startMs], '', 1, 0);
          if (dup.length > 0) {
            if (dup[0].mtime === mtime && dup[0].fileSize === fsize && dup[0].title === song.title) {
              continue;
            }
            song.id = dup[0].id;
            const bucket: relationalStore.ValuesBucket = {
              'title': song.title, 'artist': song.artist, 'album': song.album, 'album_artist': song.albumArtist,
              'track_no': song.trackNo, 'duration_ms': song.durationMs, 'mtime': song.mtime,
              'cue_start_ms': song.cueStartMs, 'cue_end_ms': song.cueEndMs, 'art_path': song.artPath
            };
            await Db.get().updateSongFields(song.id, bucket);
            added++;
          } else {
            await Db.get().upsertSong(song, false);
            added++;
          }
        }
        hilog.info(DOMAIN, TAG, 'cue stored %{public}s tracks=%{public}d added=%{public}d',
          cand.name, sheet.tracks.length, added);
        return added > 0;
      } finally {
        if (cueFile !== null) {
          try {
            fs.closeSync(cueFile);
          } catch (e) {
          }
        }
        if (audioFile !== null) {
          try {
            fs.closeSync(audioFile);
          } catch (e) {
          }
        }
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'parseCueFile fail %{public}s %{public}s', cand.path, (e as Error).message);
      return false;
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
      return `file://${path}`; // Image 组件需要 file:// URI;AVSession mediaImage 同样兼容
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
          const isCue = name.toLowerCase().endsWith('.cue');
          if (!isAudioExt(name) && !isCue) {
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
          const isCue = name.toLowerCase().endsWith('.cue');
          if (!isAudioExt(name) && !isCue) {
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

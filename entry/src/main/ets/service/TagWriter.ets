// 标签写回服务(#40/#41):FLAC VorbisComment 原子重写(native 临时文件+校验+rename)
// → 重新解析元数据 → 更新库(同 path 的 CUE 分轨行同步刷新)。
import { common } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { parseAudioMeta, SongMeta, ReadAt } from '../data/tag/MetaParse';
import { LibraryStore } from '../data/LibraryStore';
import { Db } from '../data/Db';
import { Song } from '../data/Model';
import timbravaCore from 'libtimbrava_core.so';
import { openTargetOf } from '../common/PathUtil';

const TAG = '[Timbrava][TagWriter]';
const DOMAIN = 0x0001;

interface NativeTagResult {
  ok: boolean;
  msg: string;
}

interface NativeTagModule {
  writeFlacTags(srcPath: string, tmpPath: string, title: string, artist: string, album: string,
    albumArtist: string, genre: string, year: string, trackNo: string, discNo: string): Promise<NativeTagResult>;
}

export class TagFields {
  title: string = '';
  artist: string = '';
  album: string = '';
  albumArtist: string = '';
  genre: string = '';
  year: string = '';
  trackNo: string = '';
  discNo: string = '';
}

export class TagWriter {
  // 写回单曲;成功后重解析元数据并刷新库。仅支持 FLAC(其余返回 false)。
  static async write(song: Song, f: TagFields): Promise<boolean> {
    if (song.codec !== 'flac') {
      hilog.warn(DOMAIN, TAG, 'unsupported codec %{public}s for tag write', song.codec);
      return false;
    }
    if (song.path.startsWith('uri:')) {
      hilog.warn(DOMAIN, TAG, 'tag write not supported for picker-authorized URI files');
      return false;
    }
    const ctx = AppStorage.get<common.UIAbilityContext>('uiAbilityContext') ?? null;
    if (ctx === null) {
      hilog.error(DOMAIN, TAG, 'no uiAbilityContext');
      return false;
    }
    const tmpPath = `${ctx.cacheDir}/tagtmp_${Date.now()}.flac`;
    try {
      const m = timbravaCore as NativeTagModule;
      const r = await m.writeFlacTags(song.path, tmpPath, f.title, f.artist, f.album, f.albumArtist,
        f.genre, f.year, f.trackNo, f.discNo);
      if (!r.ok) {
        hilog.error(DOMAIN, TAG, 'write fail %{public}s', r.msg);
        return false;
      }
      await TagWriter.reindex(song.path);
      return true;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'write exception %{public}s', (e as Error).message);
      return false;
    }
  }

  // 重解析单个音频文件并刷新库(path 相同的行——含 CUE 分轨——同步更新基础字段)
  static async reindex(path: string): Promise<void> {
    let file: fs.File | null = null;
    let size = 0;
    try {
      size = fs.statSync(openTargetOf(path)).size;
    } catch (e) {
      return;
    }
    try {
      file = await fs.open(openTargetOf(path), fs.OpenMode.READ_ONLY);
      const fd = file.fd;
      const readAt: ReadAt = (off: number, len: number): Uint8Array => {
        const buf = new ArrayBuffer(len);
        const n = fs.readSync(fd, buf, { offset: off, length: len });
        return new Uint8Array(buf, 0, n);
      };
      const name = path.substring(path.lastIndexOf('/') + 1);
      const meta: SongMeta = parseAudioMeta(name, size, readAt, readAt);
      const rows = await Db.get().querySongs('path = ?', [path], '', 100, 0);
      for (const row of rows) {
        const bucket: relationalStore.ValuesBucket = {};
        if (meta.title.length > 0) {
          bucket['title'] = meta.title;
        }
        bucket['artist'] = meta.artist;
        bucket['album'] = meta.album;
        bucket['album_artist'] = meta.albumArtist;
        bucket['genre'] = meta.genre;
        if (meta.year > 0) {
          bucket['year'] = meta.year;
        }
        if (meta.trackNo > 0) {
          bucket['track_no'] = meta.trackNo;
        }
        if (meta.discNo > 0) {
          bucket['disc_no'] = meta.discNo;
        }
        if (meta.durationMs > 0 && row.cueStartMs === 0) {
          bucket['duration_ms'] = meta.durationMs;
          bucket['sample_rate'] = meta.sampleRate;
          bucket['bit_depth'] = meta.bitDepth;
          bucket['channels'] = meta.channels;
        }
        await Db.get().updateSongFields(row.id, bucket);
      }
      hilog.info(DOMAIN, TAG, 'reindexed %{public}s rows=%{public}d', name, rows.length);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'reindex fail %{public}s', (e as Error).message);
    } finally {
      if (file !== null) {
        try {
          fs.closeSync(file);
        } catch (e2) {
        }
      }
    }
    await LibraryStore.get().reload();
    AppStorage.setOrCreate('libVer', (AppStorage.get<number>('libVer') ?? 0) + 1);
  }
}

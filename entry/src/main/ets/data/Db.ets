// relationalStore 数据层:建表 + 歌曲/歌单/队列/收藏/设置 CRUD。
import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Song, RepeatMode, RootFolder } from './Model';

const TAG = '[Timbrava][Db]';
const DOMAIN = 0x0001;

const SQL_CREATE: string[] = [
  `CREATE TABLE IF NOT EXISTS songs(
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    path TEXT NOT NULL,
    hash TEXT NOT NULL DEFAULT '',
    file_size INTEGER DEFAULT 0, mtime INTEGER DEFAULT 0,
    title TEXT NOT NULL DEFAULT '', artist TEXT DEFAULT '', album TEXT DEFAULT '', album_artist TEXT DEFAULT '',
    genre TEXT DEFAULT '', year INTEGER DEFAULT 0, track_no INTEGER DEFAULT 0, disc_no INTEGER DEFAULT 0,
    duration_ms INTEGER DEFAULT 0,
    sample_rate INTEGER DEFAULT 0, bit_depth INTEGER DEFAULT 0, channels INTEGER DEFAULT 0,
    bitrate_kbps INTEGER DEFAULT 0, codec TEXT DEFAULT '',
    cue_start_ms INTEGER DEFAULT 0, cue_end_ms INTEGER DEFAULT -1,
    art_path TEXT DEFAULT '',
    rg_track_gain REAL DEFAULT 0, rg_track_peak REAL DEFAULT 0,
    rg_album_gain REAL DEFAULT 0, rg_album_peak REAL DEFAULT 0,
    date_added INTEGER DEFAULT 0, last_played INTEGER DEFAULT 0,
    UNIQUE(path, cue_start_ms)
  )`,
  `CREATE INDEX IF NOT EXISTS idx_songs_album ON songs(album_artist, album, disc_no, track_no)`,
  `CREATE INDEX IF NOT EXISTS idx_songs_artist ON songs(artist)`,
  `CREATE INDEX IF NOT EXISTS idx_songs_path ON songs(path)`,
  // idx_songs_hash 不在此处建:升级路径上须先走 migrateSongsHash 的 ALTER 挂列(见该方法注释)
  `CREATE TABLE IF NOT EXISTS playlists(
    id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT UNIQUE NOT NULL,
    created_at INTEGER DEFAULT 0, sort INTEGER DEFAULT 0)`,
  `CREATE TABLE IF NOT EXISTS playlist_songs(
    playlist_id INTEGER NOT NULL, song_id INTEGER NOT NULL, position INTEGER NOT NULL,
    UNIQUE(playlist_id, position))`,
  `CREATE TABLE IF NOT EXISTS queues(
    id TEXT PRIMARY KEY, title TEXT DEFAULT '', created_at INTEGER DEFAULT 0, last_active_at INTEGER DEFAULT 0,
    is_pinned INTEGER DEFAULT 0, is_original INTEGER DEFAULT 1,
    active_index INTEGER DEFAULT 0, active_pos_ms INTEGER DEFAULT 0,
    repeat_mode INTEGER DEFAULT 0, shuffle_order TEXT DEFAULT '', expiry_at INTEGER DEFAULT 0)`,
  `CREATE TABLE IF NOT EXISTS queue_items(
    queue_id TEXT NOT NULL, position INTEGER NOT NULL, song_id INTEGER NOT NULL,
    UNIQUE(queue_id, position))`,
  `CREATE TABLE IF NOT EXISTS history(
    id INTEGER PRIMARY KEY AUTOINCREMENT, song_id INTEGER NOT NULL, played_at INTEGER NOT NULL, ms_played INTEGER DEFAULT 0)`,
  `CREATE TABLE IF NOT EXISTS play_count(
    song_id INTEGER PRIMARY KEY, count INTEGER DEFAULT 0, total_ms INTEGER DEFAULT 0, last_played INTEGER DEFAULT 0)`,
  `CREATE TABLE IF NOT EXISTS favorites(
    song_id INTEGER PRIMARY KEY, created_at INTEGER DEFAULT 0)`,
  `CREATE TABLE IF NOT EXISTS incl_excl(
    id INTEGER PRIMARY KEY AUTOINCREMENT, type INTEGER NOT NULL, path TEXT UNIQUE NOT NULL)`,
  `CREATE TABLE IF NOT EXISTS lyrics_cache(
    song_id INTEGER PRIMARY KEY, lrc TEXT DEFAULT '', source INTEGER DEFAULT 0, offset_ms INTEGER DEFAULT 0)`,
  `CREATE TABLE IF NOT EXISTS eq_presets(
    id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT UNIQUE NOT NULL, bands TEXT DEFAULT '[]')`,
  // EQ 作用域覆盖(M3 批次):target = 'song:{id}' | 'album:{albumArtist}\u0001{album}'(与 LibraryStore 分组键一致)
  `CREATE TABLE IF NOT EXISTS eq_assign(
    target TEXT PRIMARY KEY, bands TEXT NOT NULL DEFAULT '[]')`,
  `CREATE TABLE IF NOT EXISTS app_settings(key TEXT PRIMARY KEY, value TEXT NOT NULL)`
];

export class QueueSnapshot {
  songIds: number[] = [];
  activeIndex: number = 0;
  posMs: number = 0;
  repeat: RepeatMode = RepeatMode.OFF;
  shuffled: boolean = false;
  title: string = '';
}

export class EqPresetRow {
  id: number = 0;
  name: string = '';
  bands: number[] = [];
}

// 播放统计行(M6 统计回顾)
export class HistoryRow {
  id: number = 0;        // history 行 id(滑动删除用)
  playedAt: number = 0;
  msPlayed: number = 0;
  song: Song = new Song();
}

export class MostRow {
  song: Song = new Song();
  count: number = 0;
  totalMs: number = 0;
  lastPlayed: number = 0;
}

export class Db {
  private static instance: Db | null = null;
  private store: relationalStore.RdbStore | null = null;

  static get(): Db {
    if (Db.instance === null) {
      Db.instance = new Db();
    }
    return Db.instance;
  }

  async init(context: common.Context): Promise<void> {
    if (this.store !== null) {
      return;
    }
    const cfg: relationalStore.StoreConfig = {
      name: 'timbrava.db',
      securityLevel: relationalStore.SecurityLevel.S1
    };
    try {
      // 24-4:同步建库,消除首页首帧与 RDB 初始化的异步竞态(CUE UNIQUE 迁移类场景前置保障)
      this.store = relationalStore.getRdbStoreSync(context, cfg);
      await this.migrateSongsUnique();
      for (const sql of SQL_CREATE) {
        await this.store.executeSql(sql);
      }
      await this.migrateSongsHash();
      hilog.info(DOMAIN, TAG, 'init ok, tables=%{public}d', SQL_CREATE.length);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'init fail %{public}s', (e as Error).message);
      throw e as Error;
    }
  }

  // 迁移:songs 唯一键 path -> (path, cue_start_ms)(CUE 分轨同 path 多行的前提;
  // 旧库重建表保数据,幂等由 app_settings 标记保证)
  private async migrateSongsUnique(): Promise<void> {
    const st = this.store;
    if (st === null) {
      return;
    }
    const mark = await this.getSetting('dbSongsUnique2', '0');
    if (mark === '1') {
      return;
    }
    try {
      const rs = await st.querySql(
        "SELECT sql FROM sqlite_master WHERE type='table' AND name='songs'");
      let ddl = '';
      if (rs.goToFirstRow()) {
        ddl = rs.getString(0);
      }
      rs.close();
      if (ddl.indexOf('UNIQUE(path, cue_start_ms)') < 0) {
        await st.executeSql('ALTER TABLE songs RENAME TO songs_old');
        await st.executeSql(`CREATE TABLE songs(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          path TEXT NOT NULL, file_size INTEGER DEFAULT 0, mtime INTEGER DEFAULT 0,
          title TEXT NOT NULL DEFAULT '', artist TEXT DEFAULT '', album TEXT DEFAULT '', album_artist TEXT DEFAULT '',
          genre TEXT DEFAULT '', year INTEGER DEFAULT 0, track_no INTEGER DEFAULT 0, disc_no INTEGER DEFAULT 0,
          duration_ms INTEGER DEFAULT 0,
          sample_rate INTEGER DEFAULT 0, bit_depth INTEGER DEFAULT 0, channels INTEGER DEFAULT 0,
          bitrate_kbps INTEGER DEFAULT 0, codec TEXT DEFAULT '',
          cue_start_ms INTEGER DEFAULT 0, cue_end_ms INTEGER DEFAULT -1,
          art_path TEXT DEFAULT '',
          rg_track_gain REAL DEFAULT 0, rg_track_peak REAL DEFAULT 0,
          rg_album_gain REAL DEFAULT 0, rg_album_peak REAL DEFAULT 0,
          date_added INTEGER DEFAULT 0, last_played INTEGER DEFAULT 0,
          UNIQUE(path, cue_start_ms))`);
        await st.executeSql('INSERT INTO songs SELECT * FROM songs_old');
        await st.executeSql('DROP TABLE songs_old');
        hilog.info(DOMAIN, TAG, 'songs unique migrated to (path,cue_start_ms)');
      }
      await this.setSetting('dbSongsUnique2', '1');
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'migrateSongsUnique fail %{public}s', (e as Error).message);
    }
  }

  ready(): boolean {
    return this.store !== null;
  }

  // 迁移(0.12.0):songs 增加 hash 内容身份列 + 索引(幂等,app_settings 标记)。
  // 必须在 SQL_CREATE 之后执行:老库先 ALTER 挂列再建 idx_songs_hash(索引放 SQL_CREATE 会因列未挂而失败);
  // 新装直建已含 hash,此处自动跳过 ALTER 只补索引。两条路径都收敛到本方法。
  private async migrateSongsHash(): Promise<void> {
    const st = this.store;
    if (st === null) {
      return;
    }
    const mark = await this.getSetting('dbSongsHash1', '0');
    if (mark === '1') {
      return;
    }
    try {
      const rs = await st.querySql(
        "SELECT sql FROM sqlite_master WHERE type='table' AND name='songs'");
      let ddl = '';
      if (rs.goToFirstRow()) {
        ddl = rs.getString(0);
      }
      rs.close();
      if (ddl.length > 0 && ddl.indexOf('hash') < 0) {
        await st.executeSql("ALTER TABLE songs ADD COLUMN hash TEXT NOT NULL DEFAULT ''");
        hilog.info(DOMAIN, TAG, 'songs hash column added');
      }
      await st.executeSql('CREATE INDEX IF NOT EXISTS idx_songs_hash ON songs(hash)');
      await this.setSetting('dbSongsHash1', '1');
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'migrateSongsHash fail %{public}s', (e as Error).message);
    }
  }

  storeOrNull(): relationalStore.RdbStore | null {
    return this.store;
  }

  private storeOrThrow(): relationalStore.RdbStore {
    if (this.store === null) {
      throw new Error('Db not initialized');
    }
    return this.store;
  }

  // ============ app_settings KV ============

  async getSetting(key: string, defVal: string): Promise<string> {
    const st = this.storeOrThrow();
    try {
      const rs = await st.querySql('SELECT value FROM app_settings WHERE key = ?', [key]);
      let out = defVal;
      if (rs.goToFirstRow()) {
        out = rs.getString(rs.getColumnIndex('value'));
      }
      rs.close();
      return out;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'getSetting %{public}s fail %{public}s', key, (e as Error).message);
      return defVal;
    }
  }

  async setSetting(key: string, value: string): Promise<void> {
    const st = this.storeOrThrow();
    try {
      const bucket: relationalStore.ValuesBucket = { 'key': key, 'value': value };
      await st.insert('app_settings', bucket, relationalStore.ConflictResolution.ON_CONFLICT_REPLACE);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'setSetting %{public}s fail %{public}s', key, (e as Error).message);
    }
  }

  // ============ songs ============

  private static readonly SONG_COLS = 'id, path, hash, file_size, mtime, title, artist, album, album_artist, genre, year, ' +
    'track_no, disc_no, duration_ms, sample_rate, bit_depth, channels, bitrate_kbps, codec, ' +
    'cue_start_ms, cue_end_ms, art_path, rg_track_gain, rg_track_peak, rg_album_gain, rg_album_peak';

  private static rowToSong(rs: relationalStore.ResultSet): Song {
    const o: Record<string, Object | null> = {};
    const cols = Db.SONG_COLS.split(', ');
    for (const c of cols) {
      const idx = rs.getColumnIndex(c);
      const type = rs.getColumnTypeSync(idx);
      if (type === relationalStore.ColumnType.TEXT) {
        o[c] = rs.getString(idx);
      } else if (type === relationalStore.ColumnType.REAL) {
        o[c] = rs.getDouble(idx);
      } else if (type === relationalStore.ColumnType.NULL) {
        o[c] = null;
      } else {
        o[c] = rs.getLong(idx);
      }
    }
    return Song.fromJson(o);
  }

  async upsertSong(s: Song, isReplace: boolean): Promise<number> {
    const st = this.storeOrThrow();
    const bucket: relationalStore.ValuesBucket = {
      'path': s.path,
      'hash': s.hash,
      'file_size': s.fileSize,
      'mtime': s.mtime,
      'title': s.title,
      'artist': s.artist,
      'album': s.album,
      'album_artist': s.albumArtist,
      'genre': s.genre,
      'year': s.year,
      'track_no': s.trackNo,
      'disc_no': s.discNo,
      'duration_ms': s.durationMs,
      'sample_rate': s.sampleRate,
      'bit_depth': s.bitDepth,
      'channels': s.channels,
      'bitrate_kbps': s.bitrateKbps,
      'codec': s.codec,
      'cue_start_ms': s.cueStartMs,
      'cue_end_ms': s.cueEndMs,
      'art_path': s.artPath,
      'rg_track_gain': s.rgTrackGain,
      'rg_track_peak': s.rgTrackPeak,
      'rg_album_gain': s.rgAlbumGain,
      'rg_album_peak': s.rgAlbumPeak
    };
    if (isReplace) {
      return st.insert('songs', bucket, relationalStore.ConflictResolution.ON_CONFLICT_REPLACE);
    }
    return st.insert('songs', bucket);
  }

  async updateSongFields(id: number, bucket: relationalStore.ValuesBucket): Promise<void> {
    const st = this.storeOrThrow();
    const pred = new relationalStore.RdbPredicates('songs');
    pred.equalTo('id', id);
    await st.update(bucket, pred);
  }

  // ReplayGain 扫描结果写回
  async updateSongRg(id: number, trackGain: number, trackPeak: number, albumGain: number, albumPeak: number): Promise<void> {
    const bucket: relationalStore.ValuesBucket = {
      'rg_track_gain': trackGain,
      'rg_track_peak': trackPeak,
      'rg_album_gain': albumGain,
      'rg_album_peak': albumPeak
    };
    await this.updateSongFields(id, bucket);
  }

  async getSongsByPathPrefix(prefix: string): Promise<string[]> {
    const st = this.storeOrThrow();
    const rs = await st.querySql('SELECT path FROM songs WHERE path LIKE ?', [`${prefix}%`]);
    const out: string[] = [];
    while (rs.goToNextRow()) {
      out.push(rs.getString(0));
    }
    rs.close();
    return out;
  }

  // hash 回填(0.12.0):尚未求值内容身份的物理文件路径(去重)
  async getUnhashedPaths(limit: number): Promise<string[]> {
    const st = this.storeOrThrow();
    const rs = await st.querySql("SELECT DISTINCT path FROM songs WHERE hash = '' LIMIT ?", [limit]);
    const out: string[] = [];
    while (rs.goToNextRow()) {
      out.push(rs.getString(0));
    }
    rs.close();
    return out;
  }

  // hash 回填写回:同物理文件所有行(整轨+CUE 分轨)统一身份
  async updateSongsHashByPath(path: string, hash: string): Promise<void> {
    const st = this.storeOrThrow();
    await st.executeSql('UPDATE songs SET hash = ? WHERE path = ?', [hash, path]);
  }

  // 从库完全移除单曲(songs + favorites;播放记录/队列行保留为孤儿,查询侧已判空)
  async removeSongCompletely(songId: number): Promise<void> {
    const st = this.storeOrThrow();
    const pred = new relationalStore.RdbPredicates('songs');
    pred.equalTo('id', songId);
    await st.delete(pred);
    const pred2 = new relationalStore.RdbPredicates('favorites');
    pred2.equalTo('song_id', songId);
    await st.delete(pred2);
  }

  async deleteSongsByPaths(paths: string[]): Promise<void> {
    const st = this.storeOrThrow();
    for (const p of paths) {
      const pred = new relationalStore.RdbPredicates('songs');
      pred.equalTo('path', p);
      await st.delete(pred);
    }
  }

  // 内容身份合并(0.12.0):src 的全部关系迁给 dst(id 保留 dst),src songs 行删除。
  // favorites/lyrics_cache 主键冲突时保 dst 已有;play_count 计数累加;queue_items 瞬态直接删。
  async mergeSongs(srcId: number, dstId: number): Promise<void> {
    if (srcId === dstId) {
      return;
    }
    const st = this.storeOrThrow();
    try {
      // favorites:dst 已有则丢弃 src 行,否则改挂
      const fav = await st.querySql('SELECT song_id FROM favorites WHERE song_id IN (?, ?)', [srcId, dstId]);
      let favSrc = false;
      let favDst = false;
      if (fav.goToFirstRow()) {
        do {
          const sid = fav.getLong(fav.getColumnIndex('song_id'));
          if (sid === srcId) {
            favSrc = true;
          }
          if (sid === dstId) {
            favDst = true;
          }
        } while (fav.goToNextRow());
      }
      fav.close();
      if (favSrc) {
        if (favDst) {
          await st.executeSql('DELETE FROM favorites WHERE song_id = ?', [srcId]);
        } else {
          await st.executeSql('UPDATE favorites SET song_id = ? WHERE song_id = ?', [dstId, srcId]);
        }
      }
      // history:全量改挂
      await st.executeSql('UPDATE history SET song_id = ? WHERE song_id = ?', [dstId, srcId]);
      // play_count:计数累加,last_played 取较大
      const pc = await st.querySql('SELECT song_id, count, total_ms, last_played FROM play_count WHERE song_id IN (?, ?)',
        [srcId, dstId]);
      const rows: number[][] = [];
      while (pc.goToNextRow()) {
        rows.push([pc.getLong(pc.getColumnIndex('song_id')), pc.getLong(pc.getColumnIndex('count')),
          pc.getLong(pc.getColumnIndex('total_ms')), pc.getLong(pc.getColumnIndex('last_played'))]);
      }
      pc.close();
      const srcPc = rows.find((r: number[]): boolean => r[0] === srcId);
      const dstPc = rows.find((r: number[]): boolean => r[0] === dstId);
      if (srcPc !== undefined) {
        if (dstPc !== undefined) {
          await st.executeSql('UPDATE play_count SET count = ?, total_ms = ?, last_played = ? WHERE song_id = ?',
            [dstPc[1] + srcPc[1], dstPc[2] + srcPc[2], Math.max(dstPc[3], srcPc[3]), dstId]);
          await st.executeSql('DELETE FROM play_count WHERE song_id = ?', [srcId]);
        } else {
          await st.executeSql('UPDATE play_count SET song_id = ? WHERE song_id = ?', [dstId, srcId]);
        }
      }
      // playlist_songs:逐 playlist 判重——dst 已在则删 src 行,否则改挂
      const ps = await st.querySql('SELECT playlist_id, position FROM playlist_songs WHERE song_id = ?', [srcId]);
      const psRows: number[][] = [];
      while (ps.goToNextRow()) {
        psRows.push([ps.getLong(ps.getColumnIndex('playlist_id')), ps.getLong(ps.getColumnIndex('position'))]);
      }
      ps.close();
      for (const r of psRows) {
        const dup = await st.querySql('SELECT 1 FROM playlist_songs WHERE playlist_id = ? AND song_id = ? LIMIT 1',
          [r[0], dstId]);
        const hasDup = dup.goToFirstRow();
        dup.close();
        if (hasDup) {
          await st.executeSql('DELETE FROM playlist_songs WHERE playlist_id = ? AND song_id = ?', [r[0], srcId]);
        } else {
          await st.executeSql('UPDATE playlist_songs SET song_id = ? WHERE playlist_id = ? AND song_id = ?',
            [dstId, r[0], srcId]);
        }
      }
      // lyrics_cache:dst 缺则改挂,已有则删 src
      const lc = await st.querySql('SELECT song_id FROM lyrics_cache WHERE song_id IN (?, ?)', [srcId, dstId]);
      let lcSrc = false;
      let lcDst = false;
      if (lc.goToFirstRow()) {
        do {
          const sid = lc.getLong(lc.getColumnIndex('song_id'));
          if (sid === srcId) {
            lcSrc = true;
          }
          if (sid === dstId) {
            lcDst = true;
          }
        } while (lc.goToNextRow());
      }
      lc.close();
      if (lcSrc) {
        if (lcDst) {
          await st.executeSql('DELETE FROM lyrics_cache WHERE song_id = ?', [srcId]);
        } else {
          await st.executeSql('UPDATE lyrics_cache SET song_id = ? WHERE song_id = ?', [dstId, srcId]);
        }
      }
      // queue_items:瞬态,不合并
      await st.executeSql('DELETE FROM queue_items WHERE song_id = ?', [srcId]);
      hilog.info(DOMAIN, TAG, 'songs merged src=%{public}d dst=%{public}d', srcId, dstId);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'mergeSongs fail %{public}s', (e as Error).message);
    }
  }

  // 内容身份感知的路径退役(0.12.0,rescan 清理段用):
  // 路径失联的行,若库内存在同 (hash, cueStartMs) 且不在本轮退役集的幸存行 → 关系并给幸存者再删行;
  // 否则按旧语义删除(songs + favorites,其余留孤儿)。返回退役行数。
  async retireSongsByPaths(paths: string[]): Promise<number> {
    const st = this.storeOrThrow();
    let retired = 0;
    // 两阶段:先收集全部待退役行,幸存者检索排除本轮退役集(防"两份都失联"时关系并进同批被删的行)
    const victims: Song[] = [];
    for (const p of paths) {
      const rows = await this.querySongs('path = ?', [p], '', 1000, 0);
      for (const r of rows) {
        victims.push(r);
      }
    }
    if (victims.length === 0) {
      return 0;
    }
    const victimIds = new Set<number>();
    for (const v of victims) {
      victimIds.add(v.id);
    }
    for (const v of victims) {
      let survivorId = 0;
      if (v.hash.length > 0) {
        const cands = await this.querySongs('hash = ? AND cue_start_ms = ? AND id != ?',
          [v.hash, v.cueStartMs, v.id], 'date_added DESC', 1, 0);
        if (cands.length > 0 && !victimIds.has(cands[0].id)) {
          survivorId = cands[0].id;
        }
      }
      if (survivorId > 0) {
        await this.mergeSongs(v.id, survivorId);
        const pred = new relationalStore.RdbPredicates('songs');
        pred.equalTo('id', v.id);
        await st.delete(pred);
        hilog.info(DOMAIN, TAG, 'retired path=%{public}s id=%{public}d -> merged into %{public}d', v.path, v.id, survivorId);
      } else {
        await this.removeSongCompletely(v.id);
        hilog.info(DOMAIN, TAG, 'retired path=%{public}s id=%{public}d (no survivor)', v.path, v.id);
      }
      retired++;
    }
    return retired;
  }

  async querySongs(where: string, args: Array<string | number>, orderBy: string, limit: number, offset: number): Promise<Song[]> {
    const st = this.storeOrThrow();
    let sql = `SELECT ${Db.SONG_COLS} FROM songs`;
    if (where.length > 0) {
      sql += ` WHERE ${where}`;
    }
    if (orderBy.length > 0) {
      sql += ` ORDER BY ${orderBy}`;
    }
    sql += ` LIMIT ${limit} OFFSET ${offset}`;
    const rs = await st.querySql(sql, args);
    const out: Song[] = [];
    while (rs.goToNextRow()) {
      out.push(Db.rowToSong(rs));
    }
    rs.close();
    return out;
  }

  async countSongs(): Promise<number> {
    const st = this.storeOrThrow();
    const rs = await st.querySql('SELECT COUNT(*) FROM songs');
    let n = 0;
    if (rs.goToFirstRow()) {
      n = rs.getLong(0);
    }
    rs.close();
    return n;
  }

  // ============ favorites ============

  async isFavorite(songId: number): Promise<boolean> {
    const st = this.storeOrThrow();
    const rs = await st.querySql('SELECT song_id FROM favorites WHERE song_id = ?', [songId]);
    const hit = rs.goToFirstRow();
    rs.close();
    return hit;
  }

  async getFavoriteIds(): Promise<Set<number>> {
    const st = this.storeOrThrow();
    const rs = await st.querySql('SELECT song_id FROM favorites ORDER BY created_at DESC');
    const out = new Set<number>();
    while (rs.goToNextRow()) {
      out.add(rs.getLong(0));
    }
    rs.close();
    return out;
  }

  async setFavorite(songId: number, fav: boolean): Promise<void> {
    const st = this.storeOrThrow();
    if (fav) {
      const bucket: relationalStore.ValuesBucket = { 'song_id': songId, 'created_at': Date.now() };
      await st.insert('favorites', bucket, relationalStore.ConflictResolution.ON_CONFLICT_IGNORE);
    } else {
      const pred = new relationalStore.RdbPredicates('favorites');
      pred.equalTo('song_id', songId);
      await st.delete(pred);
    }
  }

  async dumpArtPaths(): Promise<void> {
    const st = this.storeOrThrow();
    const rs = await st.querySql('SELECT title, art_path FROM songs LIMIT 12');
    while (rs.goToNextRow()) {
      hilog.info(DOMAIN, TAG, 'art[%{public}s] = %{public}s', rs.getString(0), rs.getString(1));
    }
    rs.close();
  }

  // 迁移:存量 art_path 补 file:// 前缀
  async migrateArtUri(): Promise<void> {
    const st = this.storeOrThrow();
    try {
      await st.executeSql(
        "UPDATE songs SET art_path = 'file://' || art_path WHERE art_path != '' AND art_path NOT LIKE 'file://%'");
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'migrateArtUri fail %{public}s', (e as Error).message);
    }
  }

  // ============ 队列持久化(双写:内存为权威) ============

  async saveQueue(queueId: string, title: string, songIds: number[], activeIndex: number, activePosMs: number,
    repeat: RepeatMode, shuffled: boolean): Promise<void> {
    const st = this.storeOrThrow();
    try {
      const now = Date.now();
      const qBucket: relationalStore.ValuesBucket = {
        'id': queueId,
        'title': title,
        'created_at': now,
        'last_active_at': now,
        'active_index': activeIndex,
        'active_pos_ms': activePosMs,
        'repeat_mode': repeat,
        'shuffle_order': shuffled ? '1' : ''
      };
      await st.insert('queues', qBucket, relationalStore.ConflictResolution.ON_CONFLICT_REPLACE);
      const delPred = new relationalStore.RdbPredicates('queue_items');
      delPred.equalTo('queue_id', queueId);
      await st.delete(delPred);
      for (let i = 0; i < songIds.length; i++) {
        const b: relationalStore.ValuesBucket = {
          'queue_id': queueId, 'position': i, 'song_id': songIds[i]
        };
        await st.insert('queue_items', b);
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'saveQueue fail %{public}s', (e as Error).message);
    }
  }

  async loadLastQueue(): Promise<QueueSnapshot | null> {
    const st = this.storeOrThrow();
    try {
      const rs = await st.querySql('SELECT id, title, active_index, active_pos_ms, repeat_mode, shuffle_order FROM queues ORDER BY last_active_at DESC LIMIT 1');
      if (!rs.goToFirstRow()) {
        rs.close();
        return null;
      }
      const id = rs.getString(rs.getColumnIndex('id'));
      const title = rs.getString(rs.getColumnIndex('title'));
      const activeIndex = rs.getLong(rs.getColumnIndex('active_index'));
      const posMs = rs.getLong(rs.getColumnIndex('active_pos_ms'));
      const repeat = rs.getLong(rs.getColumnIndex('repeat_mode')) as RepeatMode;
      const shuffled = rs.getString(rs.getColumnIndex('shuffle_order')).length > 0;
      rs.close();
      const rs2 = await st.querySql('SELECT song_id FROM queue_items WHERE queue_id = ? ORDER BY position', [id]);
      const songIds: number[] = [];
      while (rs2.goToNextRow()) {
        songIds.push(rs2.getLong(0));
      }
      rs2.close();
      if (songIds.length === 0) {
        return null;
      }
      const snap = new QueueSnapshot();
      snap.songIds = songIds;
      snap.activeIndex = activeIndex;
      snap.posMs = posMs;
      snap.repeat = repeat;
      snap.shuffled = shuffled;
      snap.title = title;
      return snap;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'loadLastQueue fail %{public}s', (e as Error).message);
      return null;
    }
  }

  // ============ 歌词缓存 ============

  async getLyricsCache(songId: number): Promise<string> {
    const st = this.storeOrThrow();
    const rs = await st.querySql('SELECT lrc FROM lyrics_cache WHERE song_id = ?', [songId]);
    let out = '';
    if (rs.goToFirstRow()) {
      out = rs.getString(0);
    }
    rs.close();
    return out;
  }

  async putLyricsCache(songId: number, lrc: string): Promise<void> {
    const st = this.storeOrThrow();
    const bucket: relationalStore.ValuesBucket = { 'song_id': songId, 'lrc': lrc, 'source': 0, 'offset_ms': 0 };
    await st.insert('lyrics_cache', bucket, relationalStore.ConflictResolution.ON_CONFLICT_REPLACE);
  }

  // ============ 黑名单(incl_excl type=1) ============

  async getBlacklist(): Promise<string[]> {
    const st = this.storeOrThrow();
    const rs = await st.querySql("SELECT path FROM incl_excl WHERE type = 1 ORDER BY path");
    const out: string[] = [];
    while (rs.goToNextRow()) {
      out.push(rs.getString(0));
    }
    rs.close();
    return out;
  }

  async addBlacklist(path: string): Promise<void> {
    const st = this.storeOrThrow();
    const bucket: relationalStore.ValuesBucket = { 'type': 1, 'path': path };
    await st.insert('incl_excl', bucket, relationalStore.ConflictResolution.ON_CONFLICT_IGNORE);
  }

  async removeBlacklist(path: string): Promise<void> {
    const st = this.storeOrThrow();
    const pred = new relationalStore.RdbPredicates('incl_excl');
    pred.equalTo('path', path).and().equalTo('type', 1);
    await st.delete(pred);
  }

  async loadQueueById(queueId: string): Promise<QueueSnapshot | null> {
    const st = this.storeOrThrow();
    try {
      const rs = await st.querySql('SELECT id, title, active_index, active_pos_ms, repeat_mode, shuffle_order FROM queues WHERE id = ?', [queueId]);
      if (!rs.goToFirstRow()) {
        rs.close();
        return null;
      }
      const title = rs.getString(rs.getColumnIndex('title'));
      const activeIndex = rs.getLong(rs.getColumnIndex('active_index'));
      const posMs = rs.getLong(rs.getColumnIndex('active_pos_ms'));
      const repeat = rs.getLong(rs.getColumnIndex('repeat_mode')) as RepeatMode;
      const shuffled = rs.getString(rs.getColumnIndex('shuffle_order')).length > 0;
      rs.close();
      const rs2 = await st.querySql('SELECT song_id FROM queue_items WHERE queue_id = ? ORDER BY position', [queueId]);
      const songIds: number[] = [];
      while (rs2.goToNextRow()) {
        songIds.push(rs2.getLong(0));
      }
      rs2.close();
      const snap = new QueueSnapshot();
      snap.songIds = songIds;
      snap.activeIndex = activeIndex;
      snap.posMs = posMs;
      snap.repeat = repeat;
      snap.shuffled = shuffled;
      snap.title = title;
      return snap;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'loadQueueById fail %{public}s', (e as Error).message);
      return null;
    }
  }

  async deleteQueueById(queueId: string): Promise<void> {
    const st = this.storeOrThrow();
    try {
      const pred = new relationalStore.RdbPredicates('queues');
      pred.equalTo('id', queueId);
      await st.delete(pred);
      const pred2 = new relationalStore.RdbPredicates('queue_items');
      pred2.equalTo('queue_id', queueId);
      await st.delete(pred2);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'deleteQueueById fail %{public}s', (e as Error).message);
    }
  }

  // ============ 播放统计 ============

  async recordPlay(songId: number, msPlayed: number): Promise<void> {
    const st = this.storeOrThrow();
    try {
      const now = Date.now();
      await st.executeSql('INSERT INTO history(song_id, played_at, ms_played) VALUES (?, ?, ?)', [songId, now, msPlayed]);
      await st.executeSql(
        `INSERT INTO play_count(song_id, count, total_ms, last_played) VALUES (?, 1, ?, ?)
         ON CONFLICT(song_id) DO UPDATE SET count = count + 1, total_ms = total_ms + ?, last_played = ?`,
        [songId, msPlayed, now, msPlayed, now]);
      await st.executeSql('UPDATE songs SET last_played = ? WHERE id = ?', [now, songId]);
      hilog.info(DOMAIN, TAG, 'recordPlay song=%{public}d ms=%{public}d', songId, msPlayed);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'recordPlay fail %{public}s', (e as Error).message);
    }
  }

  // 累计播放时长(ms):play_count.total_ms 求和,无记录返回 0
  async getPlayStatsTotal(): Promise<number> {
    const st = this.storeOrThrow();
    try {
      const pred = new relationalStore.RdbPredicates('play_count');
      const rs = await st.query(pred, ['SUM(total_ms) AS total']);
      if (rs.goToFirstRow()) {
        const idx = rs.getColumnIndex('total');
        return rs.isColumnNull(idx) ? 0 : rs.getLong(idx);
      }
      return 0;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'getPlayStatsTotal fail %{public}s', (e as Error).message);
      return 0;
    }
  }

  // ============ 播放统计(M6 统计回顾) ============

  // 最近播放:history JOIN songs(一条播放一条记录,可单删;hist_id 别名避免遮蔽 songs.id)
  async listRecentHistory(limit: number): Promise<HistoryRow[]> {
    const st = this.storeOrThrow();
    const out: HistoryRow[] = [];
    try {
      const rs = await st.querySql(
        `SELECT h.id AS hist_id, h.played_at, h.ms_played, s.* FROM history h
         JOIN songs s ON s.id = h.song_id ORDER BY h.played_at DESC LIMIT ${limit}`);
      while (rs.goToNextRow()) {
        const row = new HistoryRow();
        row.id = rs.getLong(rs.getColumnIndex('hist_id'));
        row.playedAt = rs.getLong(rs.getColumnIndex('played_at'));
        row.msPlayed = rs.getLong(rs.getColumnIndex('ms_played'));
        row.song = Db.rowToSong(rs);
        out.push(row);
      }
      rs.close();
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'listRecentHistory fail %{public}s', (e as Error).message);
    }
    return out;
  }

  // 最常播放:play_count JOIN songs(按次数降序;pc_* 别名避免遮蔽)
  async listMostPlayed(limit: number): Promise<MostRow[]> {
    const st = this.storeOrThrow();
    const out: MostRow[] = [];
    try {
      const rs = await st.querySql(
        `SELECT p.count AS pc_count, p.total_ms AS pc_total, p.last_played AS pc_last, s.*
         FROM play_count p JOIN songs s ON s.id = p.song_id
         ORDER BY p.count DESC, p.last_played DESC LIMIT ${limit}`);
      while (rs.goToNextRow()) {
        const row = new MostRow();
        row.count = rs.getLong(rs.getColumnIndex('pc_count'));
        row.totalMs = rs.getLong(rs.getColumnIndex('pc_total'));
        row.lastPlayed = rs.getLong(rs.getColumnIndex('pc_last'));
        row.song = Db.rowToSong(rs);
        out.push(row);
      }
      rs.close();
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'listMostPlayed fail %{public}s', (e as Error).message);
    }
    return out;
  }

  async deleteHistoryRow(id: number): Promise<void> {
    const st = this.storeOrThrow();
    const pred = new relationalStore.RdbPredicates('history');
    pred.equalTo('id', id);
    await st.delete(pred);
  }

  async deletePlayCountRow(songId: number): Promise<void> {
    const st = this.storeOrThrow();
    const pred = new relationalStore.RdbPredicates('play_count');
    pred.equalTo('song_id', songId);
    await st.delete(pred);
  }

  // ============ EQ 作用域覆盖(song:/album: target) ============

  async getEqAssign(target: string): Promise<number[] | null> {
    const st = this.storeOrThrow();
    try {
      const rs = await st.querySql('SELECT bands FROM eq_assign WHERE target = ?', [target]);
      let out: number[] | null = null;
      if (rs.goToFirstRow()) {
        const bands = Db.parseBands(rs.getString(0));
        out = bands.length === 31 ? bands : null;
      }
      rs.close();
      return out;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'getEqAssign fail %{public}s', (e as Error).message);
      return null;
    }
  }

  async setEqAssign(target: string, bands: number[]): Promise<void> {
    const st = this.storeOrThrow();
    const bucket: relationalStore.ValuesBucket = { 'target': target, 'bands': Db.stringifyBands(bands) };
    await st.insert('eq_assign', bucket, relationalStore.ConflictResolution.ON_CONFLICT_REPLACE);
  }

  async deleteEqAssign(target: string): Promise<void> {
    const st = this.storeOrThrow();
    const pred = new relationalStore.RdbPredicates('eq_assign');
    pred.equalTo('target', target);
    await st.delete(pred);
  }

  // ============ EQ 预设 / 频段 JSON 编解码 ============

  // bands JSON → 31 段增益数组(不足补 0,超出截断)
  static parseBands(json: string): number[] {
    const out: number[] = [];
    if (json.length === 0) {
      return out;
    }
    try {
      const arr = JSON.parse(json) as Array<number>;
      for (let i = 0; i < 31 && i < arr.length; i++) {
        const v = Number(arr[i]);
        out.push(Number.isFinite(v) ? Math.min(15, Math.max(-15, v)) : 0);
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'parseBands fail %{public}s', (e as Error).message);
    }
    return out;
  }

  static stringifyBands(bands: number[]): string {
    const arr: number[] = [];
    for (let i = 0; i < 31; i++) {
      const v = i < bands.length ? bands[i] : 0;
      const r = Math.round(v * 10) / 10;
      arr.push(Number.isFinite(r) ? r : 0);
    }
    return JSON.stringify(arr);
  }

  async listEqPresets(): Promise<Array<EqPresetRow>> {
    const st = this.storeOrThrow();
    const out: Array<EqPresetRow> = [];
    try {
      const rs = await st.querySql('SELECT id, name, bands FROM eq_presets ORDER BY id');
      while (rs.goToNextRow()) {
        const row = new EqPresetRow();
        row.id = rs.getLong(0);
        row.name = rs.getString(1);
        row.bands = Db.parseBands(rs.getString(2));
        out.push(row);
      }
      rs.close();
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'listEqPresets fail %{public}s', (e as Error).message);
    }
    return out;
  }

  async saveEqPreset(name: string, bands: number[]): Promise<number> {
    const st = this.storeOrThrow();
    const bucket: relationalStore.ValuesBucket = {
      'name': name, 'bands': Db.stringifyBands(bands)
    };
    return st.insert('eq_presets', bucket, relationalStore.ConflictResolution.ON_CONFLICT_REPLACE);
  }

  async deleteEqPreset(id: number): Promise<void> {
    const st = this.storeOrThrow();
    const pred = new relationalStore.RdbPredicates('eq_presets');
    pred.equalTo('id', id);
    await st.delete(pred);
  }

  // ============ 根目录 ============
  // 存储编码:type\u0001value\n...(路径安全、免 JSON 解析的 ArkTS 类型问题)

  async getRootFolders(): Promise<RootFolder[]> {
    const raw = await this.getSetting('scanRoots', '');
    const out: RootFolder[] = [];
    const lines = raw.split('\n');
    for (const line of lines) {
      if (line.length === 0) {
        continue;
      }
      const sep = line.indexOf('\u0001');
      if (sep <= 0) {
        continue;
      }
      const type = line.substring(0, sep);
      const value = line.substring(sep + 1);
      const rf = RootFolder.fromJson({ 'type': type, 'value': value } as Record<string, Object | null>);
      if (rf !== null) {
        out.push(rf);
      }
    }
    return out;
  }

  async setRootFolders(roots: RootFolder[]): Promise<void> {
    const lines: string[] = [];
    for (const r of roots) {
      lines.push(`${r.type}\u0001${r.value}`);
    }
    await this.setSetting('scanRoots', lines.join('\n'));
  }
}

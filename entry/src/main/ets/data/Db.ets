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
    path TEXT UNIQUE NOT NULL,
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
    date_added INTEGER DEFAULT 0, last_played INTEGER DEFAULT 0
  )`,
  `CREATE INDEX IF NOT EXISTS idx_songs_album ON songs(album_artist, album, disc_no, track_no)`,
  `CREATE INDEX IF NOT EXISTS idx_songs_artist ON songs(artist)`,
  `CREATE INDEX IF NOT EXISTS idx_songs_path ON songs(path)`,
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
      this.store = await relationalStore.getRdbStore(context, cfg);
      for (const sql of SQL_CREATE) {
        await this.store.executeSql(sql);
      }
      hilog.info(DOMAIN, TAG, 'init ok, tables=%{public}d', SQL_CREATE.length);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'init fail %{public}s', (e as Error).message);
      throw e as Error;
    }
  }

  ready(): boolean {
    return this.store !== null;
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

  private static readonly SONG_COLS = 'id, path, file_size, mtime, title, artist, album, album_artist, genre, year, ' +
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

  async deleteSongsByPaths(paths: string[]): Promise<void> {
    const st = this.storeOrThrow();
    for (const p of paths) {
      const pred = new relationalStore.RdbPredicates('songs');
      pred.equalTo('path', p);
      await st.delete(pred);
    }
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
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'recordPlay fail %{public}s', (e as Error).message);
    }
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

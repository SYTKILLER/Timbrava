// 歌单仓库:独立连接打开 timbrava.db(playlists / playlist_songs),并提供智能列表查询。
// P1 说明:与 Db.ets 各持一条连接(多连接读写在本场景可接受);方法内避免长事务。
// 变更后通过 AppStorage 'libVer' 广播刷新(歌单页 @StorageProp('libVer') 订阅)。
import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Song } from './Model';

const TAG = '[Timbrava][PlaylistRepo]';
const DOMAIN = 0x0001;

export class PlaylistInfo {
  id: number = 0;
  name: string = '';
  songCount: number = 0;
  createdAt: number = 0;
}

// ============ 规则式智能歌单(0.18.0) ============

// 规则字段:文本包含类 artist/album/genre/codec(value);
// 条件类 fav(收藏)/played(播放次数≥num)/addedDays(最近 num 天入库)/
// minRate(采样率≥num Hz)/minBits(位深≥num)/minYear/maxYear(年份区间)/minDur(时长≥num 秒)
export class SmartRule {
  field: string = 'genre';
  value: string = '';
  num: number = 0;

  static of(field: string): SmartRule {
    const r = new SmartRule();
    r.field = field;
    if (field === 'played') {
      r.num = 1;
    } else if (field === 'addedDays') {
      r.num = 30;
    } else if (field === 'minRate') {
      r.num = 96000;
    } else if (field === 'minBits') {
      r.num = 24;
    } else if (field === 'minYear') {
      r.num = 1980;
    } else if (field === 'maxYear') {
      r.num = 2030;
    } else if (field === 'minDur') {
      r.num = 180;
    } else if (field === 'codec') {
      r.value = 'flac';
    }
    return r;
  }
}

// 列表行(歌单页)
export class SmartPlInfo {
  id: number = 0;
  name: string = '';
  ruleCount: number = 0;
  sortBy: string = 'added';
  limitN: number = 0;
  createdAt: number = 0;
}

// 编辑页完整行
export class SmartPlFull {
  id: number = 0;
  name: string = '';
  rules: SmartRule[] = [];
  sortBy: string = 'added';
  limitN: number = 0;
}

// 规则 → SQL 片段(全部参数化,无拼接注入面)
class SmartQueryParts {
  from: string = 'FROM songs s';
  where: string = '';
  args: Array<string | number> = [];
  orderBy: string = 'ORDER BY s.date_added DESC';
  limitSql: string = '';
}

// 规则 JSON 序列化/反序列化(ArkTS 严格类型:逐字段手工映射)
export function smartRulesToJson(rules: SmartRule[]): string {
  const arr: Array<Record<string, Object>> = [];
  for (const r of rules) {
    arr.push({ 'f': r.field, 'v': r.value, 'n': r.num } as Record<string, Object>);
  }
  return JSON.stringify(arr);
}

export function smartRulesFromJson(json: string): SmartRule[] {
  const out: SmartRule[] = [];
  try {
    const arr = JSON.parse(json) as Array<Record<string, Object>>;
    for (const o of arr) {
      const r = new SmartRule();
      r.field = String(o['f'] ?? 'genre');
      r.value = String(o['v'] ?? '');
      r.num = Number(o['n'] ?? 0);
      out.push(r);
    }
  } catch (e) {
    return out;
  }
  return out;
}

export class PlaylistRepo {
  private static instance: PlaylistRepo | null = null;

  static get(): PlaylistRepo {
    if (PlaylistRepo.instance === null) {
      PlaylistRepo.instance = new PlaylistRepo();
    }
    return PlaylistRepo.instance;
  }

  private store: relationalStore.RdbStore | null = null;

  // 与 Db.ets 同款列清单(仅供 rowToSong 映射读取;不 import Db 的私有成员)
  private static readonly SONG_COLS: string = 'id, path, file_size, mtime, title, artist, album, album_artist, genre, year, ' +
    'track_no, disc_no, duration_ms, sample_rate, bit_depth, channels, bitrate_kbps, codec, ' +
    'cue_start_ms, cue_end_ms, art_path, rg_track_gain, rg_track_peak, rg_album_gain, rg_album_peak';

  // 打开同一 DB 文件;幂等(已初始化直接返回)
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
      // 防御性建表(与 Db.ets 定义一致,幂等;正常路径下 Db 已建好)
      await this.store.executeSql(
        `CREATE TABLE IF NOT EXISTS playlists(
        id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT UNIQUE NOT NULL,
        created_at INTEGER DEFAULT 0, sort INTEGER DEFAULT 0)`);
      await this.store.executeSql(
        `CREATE TABLE IF NOT EXISTS playlist_songs(
        playlist_id INTEGER NOT NULL, song_id INTEGER NOT NULL, position INTEGER NOT NULL,
        UNIQUE(playlist_id, position))`);
      await this.store.executeSql(
        `CREATE TABLE IF NOT EXISTS smart_playlists(
        id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT UNIQUE NOT NULL,
        rules TEXT NOT NULL DEFAULT '[]', sort_by TEXT DEFAULT 'added',
        limit_n INTEGER DEFAULT 0, created_at INTEGER DEFAULT 0)`);
      hilog.info(DOMAIN, TAG, 'init ok');
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'init fail %{public}s', (e as Error).message);
      throw e as Error;
    }
  }

  private storeOrThrow(): relationalStore.RdbStore {
    if (this.store === null) {
      throw new Error('PlaylistRepo not initialized');
    }
    return this.store;
  }

  // 变更广播:复用 libVer 作为统一刷新信号
  private bump(): void {
    AppStorage.setOrCreate('libVer', (AppStorage.get<number>('libVer') ?? 0) + 1);
  }

  private static rowToSong(rs: relationalStore.ResultSet): Song {
    const o: Record<string, Object | null> = {};
    const cols = PlaylistRepo.SONG_COLS.split(', ');
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

  // ============ 歌单 CRUD ============

  async listPlaylists(): Promise<PlaylistInfo[]> {
    const out: PlaylistInfo[] = [];
    try {
      const st = this.storeOrThrow();
      const rs = await st.querySql(
        `SELECT p.id, p.name, p.created_at,
          (SELECT COUNT(*) FROM playlist_songs ps WHERE ps.playlist_id = p.id) AS song_count
         FROM playlists p ORDER BY p.sort ASC, p.id ASC`);
      while (rs.goToNextRow()) {
        const info = new PlaylistInfo();
        info.id = rs.getLong(rs.getColumnIndex('id'));
        info.name = rs.getString(rs.getColumnIndex('name'));
        info.createdAt = rs.getLong(rs.getColumnIndex('created_at'));
        info.songCount = rs.getLong(rs.getColumnIndex('song_count'));
        out.push(info);
      }
      rs.close();
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'listPlaylists fail %{public}s', (e as Error).message);
    }
    return out;
  }

  // 重名(或空名)返回 -1
  async createPlaylist(name: string): Promise<number> {
    const trimmed = name.trim();
    if (trimmed.length === 0) {
      return -1;
    }
    try {
      const st = this.storeOrThrow();
      const dup = await st.querySql('SELECT id FROM playlists WHERE name = ?', [trimmed]);
      const exists = dup.goToFirstRow();
      dup.close();
      if (exists) {
        return -1;
      }
      const sortRs = await st.querySql('SELECT COALESCE(MAX(sort), 0) AS ms FROM playlists');
      let maxSort = 0;
      if (sortRs.goToFirstRow()) {
        maxSort = sortRs.getLong(sortRs.getColumnIndex('ms'));
      }
      sortRs.close();
      const bucket: relationalStore.ValuesBucket = {
        'name': trimmed, 'created_at': Date.now(), 'sort': maxSort + 1
      };
      const rowId = await st.insert('playlists', bucket);
      this.bump();
      hilog.info(DOMAIN, TAG, 'created %{public}s id=%{public}d', trimmed, rowId);
      return rowId;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'createPlaylist fail %{public}s', (e as Error).message);
      return -1;
    }
  }

  // 级联删除 playlist_songs
  async deletePlaylist(id: number): Promise<void> {
    try {
      const st = this.storeOrThrow();
      await st.executeSql('DELETE FROM playlist_songs WHERE playlist_id = ?', [id]);
      await st.executeSql('DELETE FROM playlists WHERE id = ?', [id]);
      this.bump();
      hilog.info(DOMAIN, TAG, 'deleted playlist %{public}d', id);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'deletePlaylist fail %{public}s', (e as Error).message);
    }
  }

  // 新名重复/为空返回 false
  async renamePlaylist(id: number, newName: string): Promise<boolean> {
    const trimmed = newName.trim();
    if (trimmed.length === 0) {
      return false;
    }
    try {
      const st = this.storeOrThrow();
      const dup = await st.querySql('SELECT id FROM playlists WHERE name = ? AND id != ?', [trimmed, id]);
      const exists = dup.goToFirstRow();
      dup.close();
      if (exists) {
        return false;
      }
      const pred = new relationalStore.RdbPredicates('playlists');
      pred.equalTo('id', id);
      const bucket: relationalStore.ValuesBucket = { 'name': trimmed };
      const n = await st.update(bucket, pred);
      if (n > 0) {
        this.bump();
      }
      return n > 0;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'renamePlaylist fail %{public}s', (e as Error).message);
      return false;
    }
  }

  // ============ 歌单内歌曲 ============

  // 追加到尾部(position = max + 1..)
  async addSongs(playlistId: number, songIds: number[]): Promise<void> {
    if (songIds.length === 0) {
      return;
    }
    try {
      const st = this.storeOrThrow();
      const rs = await st.querySql(
        'SELECT COALESCE(MAX(position), -1) AS mp FROM playlist_songs WHERE playlist_id = ?', [playlistId]);
      let maxPos = -1;
      if (rs.goToFirstRow()) {
        maxPos = rs.getLong(rs.getColumnIndex('mp'));
      }
      rs.close();
      let pos = maxPos;
      for (const sid of songIds) {
        pos += 1;
        const bucket: relationalStore.ValuesBucket = {
          'playlist_id': playlistId, 'song_id': sid, 'position': pos
        };
        await st.insert('playlist_songs', bucket, relationalStore.ConflictResolution.ON_CONFLICT_REPLACE);
      }
      this.bump();
      hilog.info(DOMAIN, TAG, 'addSongs pl=%{public}d n=%{public}d from=%{public}d', playlistId, songIds.length, maxPos + 1);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'addSongs fail %{public}s', (e as Error).message);
    }
  }

  // 移除指定位置,后续 position 前移
  async removeSongAt(playlistId: number, position: number): Promise<void> {
    try {
      const st = this.storeOrThrow();
      await st.executeSql('DELETE FROM playlist_songs WHERE playlist_id = ? AND position = ?', [playlistId, position]);
      await st.executeSql(
        'UPDATE playlist_songs SET position = position - 1 WHERE playlist_id = ? AND position > ?', [playlistId, position]);
      this.bump();
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'removeSongAt fail %{public}s', (e as Error).message);
    }
  }

  // JOIN songs 表按 position 排序
  async getPlaylistSongs(playlistId: number): Promise<Song[]> {
    const out: Song[] = [];
    try {
      const st = this.storeOrThrow();
      const rs = await st.querySql(
        'SELECT s.* FROM playlist_songs ps JOIN songs s ON s.id = ps.song_id WHERE ps.playlist_id = ? ORDER BY ps.position ASC',
        [playlistId]);
      while (rs.goToNextRow()) {
        out.push(PlaylistRepo.rowToSong(rs));
      }
      rs.close();
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'getPlaylistSongs fail %{public}s', (e as Error).message);
    }
    return out;
  }

  // ============ 规则式智能歌单(0.18.0) ============

  async listSmartPls(): Promise<SmartPlInfo[]> {
    const out: SmartPlInfo[] = [];
    try {
      const st = this.storeOrThrow();
      const rs = await st.querySql(
        'SELECT id, name, rules, sort_by, limit_n, created_at FROM smart_playlists ORDER BY created_at ASC');
      while (rs.goToNextRow()) {
        const info = new SmartPlInfo();
        info.id = rs.getLong(rs.getColumnIndex('id'));
        info.name = rs.getString(rs.getColumnIndex('name'));
        info.ruleCount = smartRulesFromJson(rs.getString(rs.getColumnIndex('rules'))).length;
        info.sortBy = rs.getString(rs.getColumnIndex('sort_by'));
        info.limitN = rs.getLong(rs.getColumnIndex('limit_n'));
        info.createdAt = rs.getLong(rs.getColumnIndex('created_at'));
        out.push(info);
      }
      rs.close();
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'listSmartPls fail %{public}s', (e as Error).message);
    }
    return out;
  }

  async getSmartPl(id: number): Promise<SmartPlFull | null> {
    try {
      const st = this.storeOrThrow();
      const rs = await st.querySql(
        'SELECT id, name, rules, sort_by, limit_n FROM smart_playlists WHERE id = ?', [id]);
      let full: SmartPlFull | null = null;
      if (rs.goToFirstRow()) {
        full = new SmartPlFull();
        full.id = rs.getLong(rs.getColumnIndex('id'));
        full.name = rs.getString(rs.getColumnIndex('name'));
        full.rules = smartRulesFromJson(rs.getString(rs.getColumnIndex('rules')));
        full.sortBy = rs.getString(rs.getColumnIndex('sort_by'));
        full.limitN = rs.getLong(rs.getColumnIndex('limit_n'));
      }
      rs.close();
      return full;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'getSmartPl %{public}d fail %{public}s', id, (e as Error).message);
      return null;
    }
  }

  // 重名/空名/无规则返回 -1
  async createSmartPl(name: string, rules: SmartRule[], sortBy: string, limitN: number): Promise<number> {
    const trimmed = name.trim();
    if (trimmed.length === 0 || rules.length === 0) {
      return -1;
    }
    try {
      const st = this.storeOrThrow();
      const dup = await st.querySql('SELECT id FROM smart_playlists WHERE name = ?', [trimmed]);
      const exists = dup.goToFirstRow();
      dup.close();
      if (exists) {
        return -1;
      }
      const bucket: relationalStore.ValuesBucket = {
        'name': trimmed, 'rules': smartRulesToJson(rules), 'sort_by': sortBy,
        'limit_n': limitN, 'created_at': Date.now()
      };
      const rowId = await st.insert('smart_playlists', bucket);
      this.bump();
      hilog.info(DOMAIN, TAG, 'smart pl created %{public}s rules=%{public}d', trimmed, rules.length);
      return rowId;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'createSmartPl fail %{public}s', (e as Error).message);
      return -1;
    }
  }

  async updateSmartPl(id: number, name: string, rules: SmartRule[], sortBy: string, limitN: number): Promise<boolean> {
    const trimmed = name.trim();
    if (trimmed.length === 0 || rules.length === 0) {
      return false;
    }
    try {
      const st = this.storeOrThrow();
      const dup = await st.querySql('SELECT id FROM smart_playlists WHERE name = ? AND id != ?', [trimmed, id]);
      const exists = dup.goToFirstRow();
      dup.close();
      if (exists) {
        return false;
      }
      const pred = new relationalStore.RdbPredicates('smart_playlists');
      pred.equalTo('id', id);
      const bucket: relationalStore.ValuesBucket = {
        'name': trimmed, 'rules': smartRulesToJson(rules), 'sort_by': sortBy, 'limit_n': limitN
      };
      const n = await st.update(bucket, pred);
      if (n > 0) {
        this.bump();
      }
      return n > 0;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'updateSmartPl fail %{public}s', (e as Error).message);
      return false;
    }
  }

  async deleteSmartPl(id: number): Promise<void> {
    try {
      const st = this.storeOrThrow();
      const pred = new relationalStore.RdbPredicates('smart_playlists');
      pred.equalTo('id', id);
      await st.delete(pred);
      this.bump();
      hilog.info(DOMAIN, TAG, 'smart pl deleted %{public}d', id);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'deleteSmartPl fail %{public}s', (e as Error).message);
    }
  }

  // 规则 → SQL 片段(全部参数化;文本包含 LIKE,数值/存在类为精确条件,多规则 AND 连接)
  private buildSmartQuery(rules: SmartRule[], sortBy: string, limitN: number): SmartQueryParts {
    const p = new SmartQueryParts();
    const conds: string[] = [];
    const args: Array<string | number> = [];
    for (const r of rules) {
      const v = r.value.trim();
      if ((r.field === 'artist' || r.field === 'album' || r.field === 'genre' || r.field === 'codec')
        && v.length === 0) {
        continue; // 空文本条件跳过(不构成过滤)
      }
      if (r.field === 'artist') {
        conds.push('(s.artist LIKE ? OR s.album_artist LIKE ?)');
        args.push(`%${v}%`, `%${v}%`);
      } else if (r.field === 'album') {
        conds.push('s.album LIKE ?');
        args.push(`%${v}%`);
      } else if (r.field === 'genre') {
        conds.push('s.genre LIKE ?');
        args.push(`%${v}%`);
      } else if (r.field === 'codec') {
        conds.push('s.codec = ?');
        args.push(v.toLowerCase());
      } else if (r.field === 'fav') {
        conds.push('EXISTS(SELECT 1 FROM favorites f WHERE f.song_id = s.id)');
      } else if (r.field === 'played') {
        if (r.num <= 0) {
          continue;
        }
        conds.push('EXISTS(SELECT 1 FROM play_count pc2 WHERE pc2.song_id = s.id AND pc2.count >= ?)');
        args.push(Math.round(r.num));
      } else if (r.field === 'addedDays') {
        if (r.num <= 0) {
          continue;
        }
        conds.push('s.date_added >= ?');
        args.push(Date.now() - Math.round(r.num) * 86400000);
      } else if (r.field === 'minRate') {
        if (r.num <= 0) {
          continue;
        }
        conds.push('s.sample_rate >= ?');
        args.push(Math.round(r.num));
      } else if (r.field === 'minBits') {
        if (r.num <= 0) {
          continue;
        }
        conds.push('s.bit_depth >= ?');
        args.push(Math.round(r.num));
      } else if (r.field === 'minYear') {
        if (r.num <= 0) {
          continue;
        }
        conds.push('s.year >= ?');
        args.push(Math.round(r.num));
      } else if (r.field === 'maxYear') {
        if (r.num <= 0) {
          continue;
        }
        conds.push('(s.year > 0 AND s.year <= ?)');
        args.push(Math.round(r.num));
      } else if (r.field === 'minDur') {
        if (r.num <= 0) {
          continue;
        }
        conds.push('s.duration_ms >= ?');
        args.push(Math.round(r.num) * 1000);
      }
    }
    if (conds.length > 0) {
      p.where = ' WHERE ' + conds.join(' AND ');
    }
    p.args = args;
    // 排序:播放次数排序需要 JOIN
    if (sortBy === 'plays') {
      p.from = 'FROM songs s LEFT JOIN play_count pc ON pc.song_id = s.id';
      p.orderBy = 'ORDER BY pc.count DESC, s.title COLLATE NOCASE ASC';
    } else {
      p.from = 'FROM songs s';
      if (sortBy === 'title') {
        p.orderBy = 'ORDER BY s.title COLLATE NOCASE ASC';
      } else if (sortBy === 'artist') {
        p.orderBy = 'ORDER BY s.artist COLLATE NOCASE ASC, s.title COLLATE NOCASE ASC';
      } else if (sortBy === 'album') {
        p.orderBy = 'ORDER BY s.album COLLATE NOCASE ASC, s.disc_no ASC, s.track_no ASC';
      } else if (sortBy === 'duration') {
        p.orderBy = 'ORDER BY s.duration_ms DESC';
      } else {
        p.orderBy = 'ORDER BY s.date_added DESC'; // 默认最近添加
      }
    }
    if (limitN > 0) {
      p.limitSql = ` LIMIT ${Math.round(limitN)}`;
    }
    return p;
  }

  // 智能歌单动态取曲:规则永远随曲库实时求值(无物化,无需刷新时机)
  async getSmartPlSongs(id: number): Promise<Song[]> {
    const out: Song[] = [];
    try {
      const full = await this.getSmartPl(id);
      if (full === null || full.rules.length === 0) {
        return out;
      }
      const q = this.buildSmartQuery(full.rules, full.sortBy, full.limitN);
      const st = this.storeOrThrow();
      const rs = await st.querySql(`SELECT s.* ${q.from} ${q.where} ${q.orderBy} ${q.limitSql}`, q.args);
      while (rs.goToNextRow()) {
        out.push(PlaylistRepo.rowToSong(rs));
      }
      rs.close();
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'getSmartPlSongs %{public}d fail %{public}s', id, (e as Error).message);
    }
    return out;
  }

  // 智能列表:recent = history 最近 20 首去重;added = date_added DESC 50;most = play_count count DESC 50
  async getSmartSongs(kind: string): Promise<Song[]> {
    const out: Song[] = [];
    let sql = '';
    if (kind === 'recent') {
      sql = 'SELECT s.* FROM songs s JOIN ' +
        '(SELECT song_id, MAX(played_at) AS latest FROM history GROUP BY song_id) h ON h.song_id = s.id ' +
        'ORDER BY h.latest DESC LIMIT 20';
    } else if (kind === 'added') {
      sql = 'SELECT s.* FROM songs s WHERE s.date_added > 0 ORDER BY s.date_added DESC LIMIT 50';
    } else if (kind === 'most') {
      sql = 'SELECT s.* FROM songs s JOIN play_count pc ON pc.song_id = s.id ORDER BY pc.count DESC LIMIT 50';
    } else {
      return out;
    }
    try {
      const st = this.storeOrThrow();
      const rs = await st.querySql(sql);
      while (rs.goToNextRow()) {
        out.push(PlaylistRepo.rowToSong(rs));
      }
      rs.close();
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'getSmartSongs %{public}s fail %{public}s', kind, (e as Error).message);
    }
    return out;
  }

  // 播放历史占位:统计已由 PlayerController → Db.recordPlay 落库,勿在此重复记录
  async recordPlayHistory(songId: number, msPlayed: number): Promise<void> {
    // TODO(P1): 当前经 Db.recordPlay(songId, msPlayed) 统一写 history + play_count。
    // 若后续要把统计入口迁到本仓库,再在此实现并移除 PlayerController 的直写。
    hilog.debug(DOMAIN, TAG, 'recordPlayHistory noop song=%{public}d ms=%{public}d', songId, msPlayed);
  }
}

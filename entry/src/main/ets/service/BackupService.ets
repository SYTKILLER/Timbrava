// 备份恢复(#50):设置/歌单/收藏/队列/EQ 预设/黑名单 → JSON。
// 导出经 DocumentViewPicker.save、导入经 select(零权限模式);歌曲本体不备份(重扫恢复),
// 歌单曲目按 path 映射(恢复时库内按 path 重挂 id);0.12.0 起附 hashByPath,path 失配时按内容 hash 重挂。
import { common } from '@kit.AbilityKit';
import { picker } from '@kit.CoreFileKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { relationalStore } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Db } from '../data/Db';
import { Song } from '../data/Model';
import { LibraryStore } from '../data/LibraryStore';
import { PlaylistRepo } from '../data/PlaylistRepo';
import { QueueService } from './QueueService';
import { SettingsService } from './SettingsService';
import { ScanService } from '../data/ScanService';

const TAG = '[Timbrava][Backup]';
const DOMAIN = 0x0001;
const BACKUP_VERSION = 1;

export class BackupService {
  static async exportAll(): Promise<boolean> {
    const ctx = AppStorage.get<common.UIAbilityContext>('uiAbilityContext');
    if (ctx === null || ctx === undefined) {
      return false;
    }
    try {
      const data = await BackupService.collect();
      const opts = new picker.DocumentSaveOptions();
      opts.newFileNames = [`timbrava_backup_${new Date().toISOString().substring(0, 10)}.json`];
      const docPicker = new picker.DocumentViewPicker(ctx as common.UIAbilityContext);
      const uris = await docPicker.save(opts);
      if (uris === undefined || uris.length === 0) {
        return false;
      }
      const enc = new util.TextEncoder();
      const bytes = enc.encodeInto(data);
      const f = fs.openSync(uris[0], fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      fs.writeSync(f.fd, bytes.buffer as ArrayBuffer);
      fs.closeSync(f);
      hilog.info(DOMAIN, TAG, 'exported %{public}d bytes', bytes.length);
      return true;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'export fail %{public}s', (e as Error).message);
      return false;
    }
  }

  private static async collect(): Promise<string> {
    const st = Db.get().storeOrNull();
    if (st === null) {
      throw new Error('db not ready');
    }
    const backup: Record<string, Object> = {};
    backup['kind'] = 'timbrava-backup';
    backup['version'] = BACKUP_VERSION;

    // app_settings 全量(含 scanRoots/eq/主题/播放行为)
    const settings: Array<[string, string]> = [];
    const rs = await st.querySql('SELECT key, value FROM app_settings');
    while (rs.goToNextRow()) {
      settings.push([rs.getString(0), rs.getString(1)]);
    }
    rs.close();
    const settingsArr: Array<Array<string>> = settings;
    backup['settings'] = settingsArr;

    // 歌单(song_id → path 映射)
    const playlists: Array<Record<string, Object>> = [];
    const rpl = await st.querySql('SELECT id, name FROM playlists ORDER BY id');
    while (rpl.goToNextRow()) {
      const pl: Record<string, Object> = {};
      const plId = rpl.getLong(0);
      pl['name'] = rpl.getString(1);
      const items: string[] = [];
      const rit = await st.querySql(
        'SELECT s.path FROM playlist_songs ps JOIN songs s ON s.id = ps.song_id ' +
        'WHERE ps.playlist_id = ? ORDER BY ps.position', [plId]);
      while (rit.goToNextRow()) {
        items.push(rit.getString(0));
      }
      rit.close();
      pl['songs'] = items;
      playlists.push(pl);
    }
    rpl.close();
    backup['playlists'] = playlists;

    // 收藏
    const favs: string[] = [];
    const rf = await st.querySql('SELECT s.path FROM favorites f JOIN songs s ON s.id = f.song_id ORDER BY f.created_at DESC');
    while (rf.goToNextRow()) {
      favs.push(rf.getString(0));
    }
    rf.close();
    backup['favorites'] = favs;

    // 队列(内容以 path 序列)
    const queues: Array<Record<string, Object>> = [];
    const rq = await st.querySql('SELECT id, title, active_index, repeat_mode, shuffle_order FROM queues');
    while (rq.goToNextRow()) {
      const q: Record<string, Object> = {};
      const qId = rq.getString(0);
      q['id'] = qId;
      q['title'] = rq.getString(1);
      q['activeIndex'] = rq.getLong(2);
      q['repeatMode'] = rq.getLong(3);
      q['shuffled'] = rq.getString(4).length > 0;
      const paths: string[] = [];
      const rqi = await st.querySql(
        'SELECT s.path FROM queue_items qi JOIN songs s ON s.id = qi.song_id WHERE qi.queue_id = ? ORDER BY qi.position',
        [qId]);
      while (rqi.goToNextRow()) {
        paths.push(rqi.getString(0));
      }
      rqi.close();
      q['songPaths'] = paths;
      queues.push(q);
    }
    rq.close();
    backup['queues'] = queues;

    // EQ 预设
    const eqPresets: Array<Record<string, Object>> = [];
    const re = await st.querySql('SELECT name, bands FROM eq_presets');
    while (re.goToNextRow()) {
      const e: Record<string, Object> = {};
      e['name'] = re.getString(0);
      e['bands'] = re.getString(1);
      eqPresets.push(e);
    }
    re.close();
    backup['eqPresets'] = eqPresets;

    // 黑名单
    const blacklist: string[] = [];
    const rb = await st.querySql("SELECT path FROM incl_excl WHERE type = 1");
    while (rb.goToNextRow()) {
      blacklist.push(rb.getString(0));
    }
    rb.close();
    backup['blacklist'] = blacklist;

    // 内容身份映射(0.12.0 hash / 0.13.0 fp):恢复时 path 失配(跨设备/换目录)按身份重挂,fp 优先
    const fpByPath: Record<string, string> = {};
    const rfp = await st.querySql("SELECT path, fp FROM songs WHERE fp != ''");
    while (rfp.goToNextRow()) {
      fpByPath[rfp.getString(0)] = rfp.getString(1);
    }
    rfp.close();
    backup['fpByPath'] = fpByPath;
    const hashByPath: Record<string, string> = {};
    const rh = await st.querySql("SELECT path, hash FROM songs WHERE hash != ''");
    while (rh.goToNextRow()) {
      hashByPath[rh.getString(0)] = rh.getString(1);
    }
    rh.close();
    backup['hashByPath'] = hashByPath;

    return JSON.stringify(backup);
  }

  static async importAll(): Promise<boolean> {
    const ctx = AppStorage.get<common.UIAbilityContext>('uiAbilityContext');
    if (ctx === null || ctx === undefined) {
      return false;
    }
    try {
      const opts = new picker.DocumentSelectOptions();
      const docPicker = new picker.DocumentViewPicker(ctx as common.UIAbilityContext);
      const uris = await docPicker.select(opts);
      if (uris === undefined || uris.length === 0) {
        return false;
      }
      const f = fs.openSync(uris[0], fs.OpenMode.READ_ONLY);
      const size = fs.statSync(uris[0]).size;
      const buf = new ArrayBuffer(size);
      fs.readSync(f.fd, buf);
      fs.closeSync(f);
      const dec = new util.TextDecoder('utf-8');
      const text = dec.decodeToString(new Uint8Array(buf));
      await BackupService.restore(text);
      return true;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'import fail %{public}s', (e as Error).message);
      return false;
    }
  }

  // 恢复重挂(0.13.0):path 命中优先;失配时按 fpByPath(操作身份)→ hashByPath(权威,旧备份兼容)重挂
  private static async resolveSong(p: string, fpByPath: Record<string, string>,
    hashByPath: Record<string, string>, wholeTrackOnly: boolean): Promise<Song[]> {
    const rows = wholeTrackOnly
      ? await Db.get().querySongs('path = ? AND cue_start_ms = 0', [p], '', 1, 0)
      : await Db.get().querySongs('path = ?', [p], '', 1, 0);
    if (rows.length > 0) {
      return rows;
    }
    const f = fpByPath[p];
    if (f !== undefined && f.length > 0) {
      return wholeTrackOnly
        ? await Db.get().querySongs('fp = ? AND cue_start_ms = 0', [f], '', 1, 0)
        : await Db.get().querySongs('fp = ?', [f], '', 1, 0);
    }
    const h = hashByPath[p];
    if (h !== undefined && h.length > 0) {
      return wholeTrackOnly
        ? await Db.get().querySongs('hash = ? AND cue_start_ms = 0', [h], '', 1, 0)
        : await Db.get().querySongs('hash = ?', [h], '', 1, 0);
    }
    return [];
  }

  static async restore(jsonText: string): Promise<void> {
    const obj = JSON.parse(jsonText) as Record<string, Object>;
    const kind = String(obj['kind'] ?? '');
    if (kind !== 'timbrava-backup') {
      throw new Error('not a timbrava backup');
    }
    const st = Db.get().storeOrNull();
    if (st === null) {
      throw new Error('db not ready');
    }
    const hashByPath: Record<string, string> = obj['hashByPath'] as Record<string, string> ?? {};
    const fpByPath: Record<string, string> = obj['fpByPath'] as Record<string, string> ?? {};
    // settings
    const settings = obj['settings'] as Array<Array<string>>;
    if (settings !== undefined && settings !== null) {
      for (const kv of settings) {
        if (kv.length >= 2) {
          await Db.get().setSetting(kv[0], kv[1]);
        }
      }
    }
    // 歌单(按 path 重建;不存在的 path 跳过)
    const playlists = obj['playlists'] as Array<Record<string, Object>>;
    if (playlists !== undefined && playlists !== null) {
      for (const pl of playlists) {
        const name = String(pl['name'] ?? '');
        const paths = pl['songs'] as Array<string>;
        if (name.length === 0 || paths === undefined) {
          continue;
        }
        const plId = await PlaylistRepo.get().createPlaylist(name);
        const ids: number[] = [];
        for (const p of paths) {
          const rows = await BackupService.resolveSong(p, fpByPath, hashByPath, true);
          if (rows.length > 0) {
            ids.push(rows[0].id);
          }
        }
        if (ids.length > 0) {
          await PlaylistRepo.get().addSongs(plId, ids);
        }
      }
    }
    // 收藏
    const favs = obj['favorites'] as Array<string>;
    if (favs !== undefined && favs !== null) {
      for (const p of favs) {
        const rows = await BackupService.resolveSong(p, fpByPath, hashByPath, false);
        if (rows.length > 0) {
          await Db.get().setFavorite(rows[0].id, true);
        }
      }
    }
    // 队列
    const queues = obj['queues'] as Array<Record<string, Object>>;
    if (queues !== undefined && queues !== null) {
      for (const q of queues) {
        const qId = String(q['id'] ?? '');
        if (qId.length === 0 || qId === 'main') {
          continue; // 活动队列运行时自有状态
        }
        const paths = q['songPaths'] as Array<string>;
        const ids: number[] = [];
        if (paths !== undefined) {
          for (const p of paths) {
            const rows = await BackupService.resolveSong(p, fpByPath, hashByPath, false);
            if (rows.length > 0) {
              ids.push(rows[0].id);
            }
          }
        }
        if (ids.length > 0) {
          const activeIndex = Number(q['activeIndex'] ?? 0);
          const repeat = Number(q['repeatMode'] ?? 0);
          const shuffled = Boolean(q['shuffled'] ?? false);
          await Db.get().saveQueue(qId, String(q['title'] ?? ''), ids, activeIndex, 0, repeat, shuffled);
        }
      }
    }
    // EQ 预设
    const eqPresets = obj['eqPresets'] as Array<Record<string, Object>>;
    if (eqPresets !== undefined && eqPresets !== null) {
      for (const e of eqPresets) {
        const name = String(e['name'] ?? '');
        const bands = String(e['bands'] ?? '[]');
        if (name.length > 0) {
          const bucket: relationalStore.ValuesBucket = { 'name': name, 'bands': bands };
          await st.insert('eq_presets', bucket, relationalStore.ConflictResolution.ON_CONFLICT_REPLACE);
        }
      }
    }
    // 黑名单
    const blacklist = obj['blacklist'] as Array<string>;
    if (blacklist !== undefined && blacklist !== null) {
      for (const p of blacklist) {
        await Db.get().addBlacklist(p);
      }
    }
    // 全量刷新
    await SettingsService.get().load();
    await LibraryStore.get().reload();
    await QueueService.get().restore();
    await ScanService.get().rescan();
    AppStorage.setOrCreate('libVer', (AppStorage.get<number>('libVer') ?? 0) + 1);
    AppStorage.setOrCreate('queueVer', (AppStorage.get<number>('queueVer') ?? 0) + 1);
    hilog.info(DOMAIN, TAG, 'restore done');
  }
}

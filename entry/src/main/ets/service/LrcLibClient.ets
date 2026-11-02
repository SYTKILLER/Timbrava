// LRCLIB 联网歌词(#38,默认关):https://lrclib.net/api
// KB 网络规范:maxLimit + 外层 deadline 竞速 + 锁 HTTP/1.1 + 诚实 UA + 不设代理。
import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = '[Timbrava][LrcLib]';
const DOMAIN = 0x0001;
const BASE = 'https://lrclib.net/api';
const UA = 'Timbrava/0.4.0 (offline music player; lrclib opt-in)';
const TIMEOUT_MS = 8000;

export class LrcLibClient {
  // 优先精确 get(带 duration),失败回退 search 取第一条有 syncedLyrics 的结果。
  // 返回同步歌词文本(空串=未找到/未启用/失败)。
  static async fetch(artist: string, track: string, album: string, durationMs: number): Promise<string> {
    if (artist.length === 0 || track.length === 0) {
      return '';
    }
    // 1) 精确接口
    const getParams: string[] = [
      `artist_name=${encodeURIComponent(artist)}`,
      `track_name=${encodeURIComponent(track)}`
    ];
    if (album.length > 0) {
      getParams.push(`album_name=${encodeURIComponent(album)}`);
    }
    if (durationMs > 0) {
      getParams.push(`duration=${String(Math.round(durationMs / 1000))}`);
    }
    const direct = await LrcLibClient.getJson(`${BASE}/get?${getParams.join('&')}`);
    const directObj = Array.isArray(direct) ? (direct.length > 0 ? direct[0] : null) : direct;
    const synced = LrcLibClient.pickSynced(directObj);
    if (synced.length > 0) {
      return synced;
    }
    // 2) 搜索接口
    const search = await LrcLibClient.getJson(
      `${BASE}/search?track_name=${encodeURIComponent(track)}&artist_name=${encodeURIComponent(artist)}`);
    if (Array.isArray(search)) {
      for (const item of search) {
        const s = LrcLibClient.pickSynced(item as Record<string, Object>);
        if (s.length > 0) {
          return s;
        }
      }
    }
    hilog.info(DOMAIN, TAG, 'no synced lyrics found');
    return '';
  }

  private static pickSynced(obj: Record<string, Object> | null): string {
    if (obj === null) {
      return '';
    }
    const v = obj['syncedLyrics'];
    if (typeof v === 'string' && v.length > 0) {
      return v;
    }
    return '';
  }

  private static async getJson(url: string): Promise<Record<string, Object> | Array<Record<string, Object>> | null> {
    const cli = http.createHttp();
    try {
      const p = cli.request(url, {
        method: http.RequestMethod.GET,
        header: { 'User-Agent': UA, 'Accept': 'application/json' },
        expectDataType: http.HttpDataType.STRING,
        usingProtocol: http.HttpProtocol.HTTP1_1,
        maxLimit: 2 * 1024 * 1024,
        readTimeout: TIMEOUT_MS,
        connectTimeout: TIMEOUT_MS
      });
      // 外层 deadline 竞速(connectTimeout 部分场景不触发)
      const deadline = new Promise<null>((resolve: (v: null) => void): void => {
        setTimeout((): void => resolve(null), TIMEOUT_MS + 2000);
      });
      const res = await Promise.race([p, deadline]);
      if (res === null) {
        hilog.warn(DOMAIN, TAG, 'deadline hit');
        return null;
      }
      if (res.responseCode !== 200) {
        hilog.info(DOMAIN, TAG, 'http %{public}d', res.responseCode);
        return null;
      }
      const text = res.result as string;
      try {
        const parsed = JSON.parse(text) as Record<string, Object>;
        return parsed;
      } catch (e) {
        try {
          const arr = JSON.parse(text) as Array<Record<string, Object>>;
          return arr;
        } catch (e2) {
          return null;
        }
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'request fail %{public}s', (e as Error).message);
      return null;
    } finally {
      cli.destroy();
    }
  }
}

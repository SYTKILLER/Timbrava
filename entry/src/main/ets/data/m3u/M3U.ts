// M3U 播放列表解析/生成(纯 TS:无系统调用、无 UI 依赖,可被 .ets 与 .ts 引用)。
// 支持标准扩展格式:#EXTM3U 头、#PLAYLIST: 标题、#EXTINF:秒数,标题 行 + 下一行路径。

export class M3UEntry {
  path: string = '';
  title: string = '';
  artist: string = '';
  durationMs: number = 0;
}

const MS_PER_SEC = 1000;

// 解析 M3U 文本 → 条目数组。过滤空行与注释;#EXTINF 元数据作用于其下一行的路径。
export function parseM3U(text: string): M3UEntry[] {
  const out: M3UEntry[] = [];
  if (text.length === 0) {
    return out;
  }
  let body = text;
  if (body.charCodeAt(0) === 0xFEFF) { // 去 BOM
    body = body.substring(1);
  }
  const lines = body.split(/\r?\n/);
  let pending: M3UEntry | null = null;
  for (const raw of lines) {
    const line = raw.trim();
    if (line.length === 0) {
      continue;
    }
    if (line.startsWith('#EXTINF:')) {
      pending = new M3UEntry();
      const payload = line.substring('#EXTINF:'.length);
      const comma = payload.indexOf(',');
      const durStr = comma >= 0 ? payload.substring(0, comma).trim() : payload.trim();
      const label = comma >= 0 ? payload.substring(comma + 1).trim() : '';
      const sec = Number.parseFloat(durStr);
      pending.durationMs = Number.isFinite(sec) && sec > 0 ? Math.round(sec * MS_PER_SEC) : 0;
      // 标签约定形如 'artist - title';无分隔符时整段记为标题
      const sep = label.indexOf(' - ');
      if (sep > 0) {
        pending.artist = label.substring(0, sep).trim();
        pending.title = label.substring(sep + 3).trim();
      } else {
        pending.title = label;
      }
      continue;
    }
    if (line.startsWith('#')) {
      continue; // #EXTM3U / #PLAYLIST: / 其它注释
    }
    // 路径行(相对或绝对路径、file:// URI 原样保留)
    const entry = pending !== null ? pending : new M3UEntry();
    entry.path = line;
    out.push(entry);
    pending = null;
  }
  return out;
}

// 生成 M3U 文本:#EXTM3U + #PLAYLIST:title + 每首 #EXTINF:秒,artist - title + 路径
export function buildM3U(title: string, items: M3UEntry[]): string {
  const lines: string[] = [];
  lines.push('#EXTM3U');
  if (title.length > 0) {
    lines.push(`#PLAYLIST:${title}`);
  }
  for (const it of items) {
    const sec = Math.round(it.durationMs / MS_PER_SEC);
    const label = it.artist.length > 0 ? `${it.artist} - ${it.title}` : it.title;
    lines.push(`#EXTINF:${sec},${label}`);
    lines.push(it.path);
  }
  return lines.join('\n') + '\n';
}

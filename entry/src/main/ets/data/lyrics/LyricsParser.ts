// LRC 歌词解析:行级 + A2 扩展逐词 + offset。纯 TS,零 UI 依赖。
import { utf8Decode } from '../tag/Bytes';

export class LyricWord {
  timeMs: number = 0;
  text: string = '';

  constructor(timeMs: number, text: string) {
    this.timeMs = timeMs;
    this.text = text;
  }
}

export class LyricLine {
  timeMs: number = 0;
  text: string = '';
  words: LyricWord[] | null = null; // 非空 = 逐词

  constructor(timeMs: number, text: string, words: LyricWord[] | null) {
    this.timeMs = timeMs;
    this.text = text;
    this.words = words;
  }
}

export class ParsedLyrics {
  lines: LyricLine[] = [];
  offsetMs: number = 0;
  isWordLevel: boolean = false;
}

const TIME_TAG = /^\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]/;
const OFFSET_TAG = /^\[offset:\s*([+-]?\d+)\s*\]/i;
const META_TAG = /^\[(ti|ar|al|by|length|re|ve|tool):/i;

function tagToMs(mi: string, si: string, fi: string | undefined): number {
  const m = parseInt(mi, 10);
  const s = parseInt(si, 10);
  let frac = 0;
  if (fi !== undefined) {
    if (fi.length === 1) {
      frac = parseInt(fi, 10) * 100;
    } else if (fi.length === 2) {
      frac = parseInt(fi, 10) * 10;
    } else {
      frac = parseInt(fi.substring(0, 3), 10);
    }
  }
  return m * 60000 + s * 1000 + frac;
}

export function parseLrc(rawText: string): ParsedLyrics {
  const out = new ParsedLyrics();
  let text = rawText;
  if (text.charCodeAt(0) === 0xFEFF) {
    text = text.substring(1);
  }
  const lines = text.replace(/\r\n/g, '\n').replace(/\r/g, '\n').split('\n');

  for (const raw of lines) {
    const line = raw.trim();
    if (line.length === 0) {
      continue;
    }
    const offMatch = OFFSET_TAG.exec(line);
    if (offMatch !== null) {
      out.offsetMs = parseInt(offMatch[1], 10);
      continue;
    }
    if (META_TAG.test(line)) {
      continue;
    }
    // 收集行首全部时间标签
    const times: number[] = [];
    let rest = line;
    let m = TIME_TAG.exec(rest);
    while (m !== null) {
      times.push(tagToMs(m[1], m[2], m[3]));
      rest = rest.substring(m[0].length);
      m = TIME_TAG.exec(rest);
    }
    if (times.length === 0 || rest.trim().length === 0) {
      continue;
    }
    // 逐词标签(每行新建正则:模块级 /g 正则 reset 后 while 重入会从 0 重复匹配,
    // 把首个时间标签当词文本——0.3.0 潜伏 bug,真语料(24-2)实证)
    const words: LyricWord[] = [];
    let wordText = rest;
    const wordTag = /<(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?>/g;
    let wm = wordTag.exec(rest);
    if (wm !== null) {
      let cursor = 0;
      let lastTime = -1;
      let pendingText = '';
      while (wm !== null) {
        const wTime = tagToMs(wm[1], wm[2], wm[3]);
        pendingText = rest.substring(cursor, wm.index);
        if (lastTime >= 0 && pendingText.length > 0) {
          words.push(new LyricWord(lastTime, pendingText));
        } else if (lastTime < 0 && pendingText.length > 0) {
          words.push(new LyricWord(times[0], pendingText));
        }
        lastTime = wTime;
        cursor = wm.index + wm[0].length;
        wm = wordTag.exec(rest);
      }
      const tailText = rest.substring(cursor);
      if (lastTime >= 0 && tailText.length > 0) {
        words.push(new LyricWord(lastTime, tailText));
      }
    }

    const plain = wordText.replace(wordTag, '').trim();
    if (plain.length === 0) {
      continue;
    }
    for (const t of times) {
      if (words.length > 0) {
        out.lines.push(new LyricLine(t, plain, words.slice()));
        out.isWordLevel = true;
      } else {
        out.lines.push(new LyricLine(t, plain, null));
      }
    }
  }
  out.lines.sort((a: LyricLine, b: LyricLine): number => a.timeMs - b.timeMs);
  return out;
}

// 二分:返回 posMs 应高亮的行索引;-1 = 前奏/间奏
export function findActiveLineIndex(lyrics: ParsedLyrics, posMs: number): number {
  const lines = lyrics.lines;
  if (lines.length === 0) {
    return -1;
  }
  let lo = 0;
  let hi = lines.length - 1;
  let ans = -1;
  while (lo <= hi) {
    const mid = (lo + hi) >> 1;
    if (lines[mid].timeMs <= posMs) {
      ans = mid;
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  return ans;
}

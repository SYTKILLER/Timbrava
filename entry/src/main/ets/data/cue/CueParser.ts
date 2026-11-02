// CUE 分轨解析(FILE/TRACK/INDEX/TITLE/PERFORMER,含 INDEX 00 pregap)。
// 设计参考 Flick cue_file_service(只借鉴语义,自研实现)。
// 输出:每个 TRACK 一条虚拟曲目(同一音频文件多行,cue_start_ms/cue_end_ms 裁剪播放区间)。

export class CueTrack {
  index: number = 0;        // 1 基曲号
  title: string = '';
  performer: string = '';
  startMs: number = 0;      // INDEX 01
  endMs: number = -1;       // 下一曲 INDEX 01(或 -1 = 文件末尾)
  pregapMs: number = 0;     // INDEX 00 与 01 差值(展示用,播放起点仍取 01)
}

export class CueSheet {
  audioFile: string = '';   // FILE 行的文件名(与 cue 同目录解析)
  fileType: string = '';    // WAVE/MP3/AIFF/FLAC
  albumTitle: string = '';
  albumPerformer: string = '';
  tracks: CueTrack[] = [];

  valid(): boolean {
    return this.audioFile.length > 0 && this.tracks.length > 0;
  }
}

function timeToMs(mm: number, ss: number, ff: number): number {
  // 75 frames/秒(CUE 标准)
  return Math.round((mm * 60 + ss) * 1000 + ff * 1000 / 75);
}

function parseTime(text: string): number {
  // "MM:SS:FF"
  const parts = text.split(':');
  if (parts.length !== 3) {
    return -1;
  }
  const mm = parseInt(parts[0], 10);
  const ss = parseInt(parts[1], 10);
  const ff = parseInt(parts[2], 10);
  if (Number.isNaN(mm) || Number.isNaN(ss) || Number.isNaN(ff)) {
    return -1;
  }
  return timeToMs(mm, ss, ff);
}

function stripQuotes(text: string): string {
  const t = text.trim();
  if (t.length >= 2 && t.startsWith('"') && t.endsWith('"')) {
    return t.substring(1, t.length - 1);
  }
  return t;
}

export function parseCue(text: string): CueSheet {
  const sheet = new CueSheet();
  const lines = text.replace(/\r\n/g, '\n').replace(/\r/g, '\n').split('\n');
  let cur: CueTrack | null = null;
  let idx00Ms = -1;
  let idx01Ms = -1;

  for (const raw of lines) {
    const line = raw.trim();
    if (line.length === 0) {
      continue;
    }
    const sp = line.indexOf(' ');
    const keyword = (sp < 0 ? line : line.substring(0, sp)).toUpperCase();
    const rest = sp < 0 ? '' : line.substring(sp + 1).trim();

    if (keyword === 'FILE') {
      // FILE "name.wav" WAVE
      const q1 = rest.indexOf('"');
      const q2 = rest.lastIndexOf('"');
      if (q1 >= 0 && q2 > q1) {
        sheet.audioFile = rest.substring(q1 + 1, q2);
        const tail = rest.substring(q2 + 1).trim();
        sheet.fileType = tail.length > 0 ? tail.toUpperCase() : '';
      } else {
        const parts = rest.split(/\s+/);
        sheet.audioFile = parts.length > 0 ? parts[0] : '';
        sheet.fileType = parts.length > 1 ? parts[1].toUpperCase() : '';
      }
    } else if (keyword === 'TRACK') {
      // TRACK 01 AUDIO
      cur = new CueTrack();
      const parts = rest.split(/\s+/);
      cur.index = parts.length > 0 ? parseInt(parts[0], 10) : sheet.tracks.length + 1;
      if (Number.isNaN(cur.index)) {
        cur.index = sheet.tracks.length + 1;
      }
      sheet.tracks.push(cur);
      idx00Ms = -1;
      idx01Ms = -1;
    } else if (keyword === 'INDEX' && cur !== null) {
      const parts = rest.split(/\s+/);
      if (parts.length >= 2) {
        const no = parts[0].trim();
        const ms = parseTime(parts[1].trim());
        if (ms >= 0) {
          if (no === '00') {
            idx00Ms = ms;
          } else if (no === '01') {
            idx01Ms = ms;
            cur.startMs = ms;
            if (idx00Ms >= 0 && ms > idx00Ms) {
              cur.pregapMs = ms - idx00Ms;
            }
          }
        }
      }
    } else if (keyword === 'TITLE') {
      const v = stripQuotes(rest);
      if (cur !== null) {
        cur.title = v;
      } else {
        sheet.albumTitle = v;
      }
    } else if (keyword === 'PERFORMER') {
      const v = stripQuotes(rest);
      if (cur !== null) {
        cur.performer = v;
      } else {
        sheet.albumPerformer = v;
      }
    }
  }

  // 计算 end:下一曲的 start(含 pregap 前的 00 点则用下一曲 00?主流行为:end = 下一曲 INDEX 01)
  for (let i = 0; i < sheet.tracks.length; i++) {
    const t = sheet.tracks[i];
    if (i + 1 < sheet.tracks.length) {
      t.endMs = sheet.tracks[i + 1].startMs;
    } else {
      t.endMs = -1;
    }
    if (t.startMs < 0) {
      t.startMs = 0;
    }
  }
  return sheet;
}

// 判断文件是否可能是 CUE(TEXT 且含 TRACK/INDEX 关键字)
export function looksLikeCue(text: string): boolean {
  const upper = text.toUpperCase();
  return upper.indexOf('TRACK ') >= 0 && upper.indexOf('INDEX ') >= 0 && upper.indexOf('FILE ') >= 0;
}

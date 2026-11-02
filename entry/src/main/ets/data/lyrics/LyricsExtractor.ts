// 内嵌歌词提取:ID3v2 USLT / MP4 ©lyr / FLAC VorbisComment LYRICS。输入文件头部字节。
import { ascii, matchTag, u32be, utf16Decode, utf8Decode } from '../tag/Bytes';

// ID3v2 USLT:enc(1) + lang(3) + descriptor(\0 或 \0\0) + 文本
function extractUslt(id3Body: Uint8Array): string {
  let p = 0;
  while (p + 10 <= id3Body.length) {
    if (id3Body[p] === 0) {
      break;
    }
    const fid = ascii(id3Body, p, 4);
    const size = u32be(id3Body, p + 4);
    if (size <= 0 || p + 10 + size > id3Body.length) {
      break;
    }
    if (fid === 'USLT' || fid === 'SYLT') {
      const content = id3Body.subarray(p + 10, p + 10 + size);
      if (content.length > 6) {
        const enc = content[0];
        let q = 4; // enc + lang
        // descriptor:enc==1/2 双字节终止
        if (enc === 1 || enc === 2) {
          while (q + 1 < content.length && !(content[q] === 0 && content[q + 1] === 0)) {
            q += 2;
          }
          q += 2;
        } else {
          while (q < content.length && content[q] !== 0) {
            q++;
          }
          q += 1;
        }
        const body = content.subarray(Math.min(q, content.length));
        let text = '';
        if (enc === 1) {
          text = utf16Decode(body, false);
        } else if (enc === 2) {
          text = utf16Decode(body, true);
        } else if (enc === 3) {
          text = utf8Decode(body);
        } else {
          text = latinToUtf(body);
        }
        text = text.replace(/\0/g, '').trim();
        if (text.length > 0) {
          return text;
        }
      }
    }
    p += 10 + size;
  }
  return '';
}

function latinToUtf(b: Uint8Array): string {
  let s = '';
  for (let i = 0; i < b.length; i++) {
    s += String.fromCharCode(b[i]);
  }
  return s;
}

export function extractId3Lyrics(bytes: Uint8Array): string {
  try {
    if (bytes.length < 10 || !matchTag(bytes, 0, 'ID3')) {
      return '';
    }
    const flags = bytes[5];
    const tagSize = ((bytes[6] & 0x7f) << 21) | ((bytes[7] & 0x7f) << 14) | ((bytes[8] & 0x7f) << 7) | (bytes[9] & 0x7f);
    const limit = Math.min(10 + tagSize, bytes.length);
    const body = bytes.subarray(10, limit);
    if ((flags & 0x80) !== 0) {
      // 整体 unsync:FF 00 -> FF
      const out: number[] = [];
      for (let i = 0; i < body.length; i++) {
        out.push(body[i]);
        if (body[i] === 0xFF && i + 1 < body.length && body[i + 1] === 0x00) {
          i++;
        }
      }
      return extractUslt(new Uint8Array(out));
    }
    return extractUslt(body);
  } catch (e) {
    return '';
  }
}

export function extractFlacLyrics(bytes: Uint8Array): string {
  try {
    if (bytes.length < 8 || !matchTag(bytes, 0, 'fLaC')) {
      return '';
    }
    let p = 4;
    for (let guard = 0; guard < 64; guard++) {
      if (p + 4 > bytes.length) {
        break;
      }
      const last = (bytes[p] & 0x80) !== 0;
      const type = bytes[p] & 0x7f;
      const len = (bytes[p + 1] << 16) | (bytes[p + 2] << 8) | bytes[p + 3];
      if (type === 4 && len > 8 && p + 4 + len <= bytes.length) {
        // VorbisComment:vendorLen + vendor + count + entries(KEY=value)
        const body = bytes.subarray(p + 4, p + 4 + len);
        let q = u32le(body, 0) + 4;
        if (q + 4 > body.length) {
          return '';
        }
        const count = Math.min(u32le(body, q), 512);
        q += 4;
        for (let i = 0; i < count && q + 4 <= body.length; i++) {
          const l = u32le(body, q);
          q += 4;
          if (l < 0 || q + l > body.length) {
            break;
          }
          const line = utf8Decode(body.subarray(q, q + l));
          q += l;
          const eq = line.indexOf('=');
          if (eq > 0) {
            const key = line.substring(0, eq).toUpperCase();
            const val = line.substring(eq + 1);
            if (key === 'LYRICS' || key === 'LYRIC' || key === 'UNSYNCEDLYRICS') {
              return val.trim();
            }
          }
        }
        return '';
      }
      p += 4 + len;
      if (last) {
        break;
      }
    }
    return '';
  } catch (e) {
    return '';
  }
}

function u32le(b: Uint8Array, o: number): number {
  return ((b[o + 3] << 24) | (b[o + 2] << 16) | (b[o + 1] << 8) | b[o]) >>> 0;
}

export function extractMp4Lyrics(bytes: Uint8Array): string {
  try {
    // 搜索 ilst 内 ©lyr atom:0xA9 'l' 'y' 'r'
    const pat: number[] = [0xA9, 0x6C, 0x79, 0x72];
    outer: for (let i = 0; i + 8 < bytes.length; i++) {
      for (let j = 0; j < 4; j++) {
        if (bytes[i + j] !== pat[j]) {
          continue outer;
        }
      }
      // atom size 在前 4 字节;data 子 atom: size,type'data',ver/flags,locale,payload
      const atomSize = u32be(bytes, i - 4);
      const scanEnd = atomSize > 8 && i - 4 + atomSize <= bytes.length ? i - 4 + atomSize : Math.min(i + 4096, bytes.length);
      for (let q = i + 4; q + 16 <= scanEnd; q++) {
        if (bytes[q] === 0x64 && bytes[q + 1] === 0x61 && bytes[q + 2] === 0x74 && bytes[q + 3] === 0x61) {
          const dataSize = u32be(bytes, q - 4);
          const payloadStart = q + 8;
          const payloadLen = dataSize > 16 ? dataSize - 16 : 0;
          if (payloadLen > 0 && payloadStart + payloadLen <= bytes.length) {
            const text = utf8Decode(bytes.subarray(payloadStart, payloadStart + payloadLen)).replace(/\0/g, '').trim();
            if (text.length > 0) {
              return text;
            }
          }
          break;
        }
      }
    }
    return '';
  } catch (e) {
    return '';
  }
}

// 统一入口:按魔数分发
export function extractLyricsFromHead(bytes: Uint8Array): string {
  if (bytes.length >= 3 && matchTag(bytes, 0, 'ID3')) {
    const id3 = extractId3Lyrics(bytes);
    if (id3.length > 0) {
      return id3;
    }
  }
  if (bytes.length >= 4 && matchTag(bytes, 0, 'fLaC')) {
    return extractFlacLyrics(bytes);
  }
  return extractMp4Lyrics(bytes);
}

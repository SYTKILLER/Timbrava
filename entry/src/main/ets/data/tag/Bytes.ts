// 字节工具:无损音乐文件头部/标签解析共用。
import { util } from '@kit.ArkTS';

export function ascii(bytes: Uint8Array, off: number, len: number): string {
  let s = '';
  const end = Math.min(bytes.length, off + len);
  for (let i = off; i < end; i++) {
    s += String.fromCharCode(bytes[i]);
  }
  return s;
}

export function matchTag(bytes: Uint8Array, off: number, tag: string): boolean {
  if (off + tag.length > bytes.length) {
    return false;
  }
  for (let i = 0; i < tag.length; i++) {
    if (bytes[off + i] !== tag.charCodeAt(i)) {
      return false;
    }
  }
  return true;
}

export function u16be(b: Uint8Array, o: number): number {
  return (b[o] << 8) | b[o + 1];
}

export function u24be(b: Uint8Array, o: number): number {
  return (b[o] << 16) | (b[o + 1] << 8) | b[o + 2];
}

export function u32be(b: Uint8Array, o: number): number {
  return ((b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3]) >>> 0;
}

export function u32le(b: Uint8Array, o: number): number {
  return ((b[o + 3] << 24) | (b[o + 2] << 16) | (b[o + 1] << 8) | b[o]) >>> 0;
}

export function u16le(b: Uint8Array, o: number): number {
  return b[o] | (b[o + 1] << 8);
}

// UTF-8 解码
export function utf8Decode(b: Uint8Array): string {
  return tdDecode(b, 'utf-8');
}

// UTF-16(带 BOM);be=true 强制大端
export function utf16Decode(b: Uint8Array, be: boolean): string {
  if (b.length < 2) {
    return '';
  }
  let little = !be;
  let start = 0;
  if (b[0] === 0xFF && b[1] === 0xFE) {
    little = true;
    start = 2;
  } else if (b[0] === 0xFE && b[1] === 0xFF) {
    little = false;
    start = 2;
  }
  const pairs = new Uint8Array(b.length - start);
  pairs.set(b.subarray(start));
  return tdDecode(pairs, little ? 'utf-16le' : 'utf-16be');
}

// ISO-8859-1(latin1)逐字节
export function latin1Decode(b: Uint8Array): string {
  let s = '';
  for (let i = 0; i < b.length; i++) {
    s += String.fromCharCode(b[i]);
  }
  return s;
}

function tdDecode(b: Uint8Array, enc: string): string {
  try {
    const td = util.TextDecoder.create(enc);
    return td.decodeToString(b);
  } catch (e) {
    return latin1Decode(b);
  }
}

// FNV-1a 32bit(文件名去重用)
export function fnv1a(b: Uint8Array): number {
  let h = 0x811c9dc5;
  for (let i = 0; i < b.length; i++) {
    h ^= b[i];
    h = (h + ((h << 1) + (h << 4) + (h << 7) + (h << 8) + (h << 24))) >>> 0;
  }
  return h;
}

export function fnv1aStr(s: string): number {
  const out: number[] = [];
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i);
    if (c < 0x80) {
      out.push(c);
    } else if (c < 0x800) {
      out.push(0xc0 | (c >> 6), 0x80 | (c & 0x3f));
    } else {
      out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 0x3f), 0x80 | (c & 0x3f));
    }
  }
  return fnv1a(new Uint8Array(out));
}

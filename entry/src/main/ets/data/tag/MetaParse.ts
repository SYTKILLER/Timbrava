// 音频文件元数据解析(自研,零依赖):
// MP3/ID3v2.2-2.4、FLAC(STREAMINFO/VorbisComment/PICTURE)、Ogg(Vorbis/Opus)、
// M4A(MP4 atom ilst)、WAV(fmt/LIST INFO)、APE(v3.98+ 头 + APEv2)、AAC(ADTS 探测)。
// 输入:readAt(offset, length) 闭包(由 ScanService 提供,内部处理 URI/路径读取)。
import { ascii, fnv1a, latin1Decode, matchTag, u16be, u16le, u24be, u32be, u32le, utf16Decode, utf8Decode } from './Bytes';

export class SongMeta {
  title: string = '';
  artist: string = '';
  album: string = '';
  albumArtist: string = '';
  genre: string = '';
  year: number = 0;
  trackNo: number = 0;
  discNo: number = 0;
  durationMs: number = 0;
  sampleRate: number = 0;
  bitDepth: number = 0;
  channels: number = 0;
  bitrateKbps: number = 0;
  codec: string = '';
  rgTrackGain: number = 0;
  rgTrackPeak: number = 0;
  rgAlbumGain: number = 0;
  rgAlbumPeak: number = 0;
  coverData: Uint8Array | null = null;
  coverMime: string = '';
  pcmMd5: string = ''; // FLAC STREAMINFO 自带 PCM MD5(仅 flac 有,音频内容身份/tag 免疫)
  ok: boolean = false;
}

export type ReadAt = (offset: number, length: number) => Uint8Array;

const AUDIO_EXTS: string[] = ['mp3', 'flac', 'wav', 'ogg', 'oga', 'opus', 'm4a', 'aac', 'ape', 'wma', 'wv', 'dsf', 'dff'];

export function isAudioExt(name: string): boolean {
  const dot = name.lastIndexOf('.');
  if (dot < 0) {
    return false;
  }
  const ext = name.substring(dot + 1).toLowerCase();
  return AUDIO_EXTS.indexOf(ext) >= 0;
}

export function extOf(name: string): string {
  const dot = name.lastIndexOf('.');
  return dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
}

function clampRead(readAt: ReadAt, size: number, off: number, len: number): Uint8Array {
  if (off < 0 || off >= size) {
    return new Uint8Array(0);
  }
  const want = Math.min(len, size - off);
  return readAt(off, want);
}

function hexOf(u8: Uint8Array): string {
  const kHex = '0123456789abcdef';
  let out = '';
  for (let i = 0; i < u8.length; i++) {
    out += kHex[(u8[i] >> 4) & 0xF] + kHex[u8[i] & 0xF];
  }
  return out;
}

function setBitrate(meta: SongMeta, fileSize: number): void {
  if (meta.bitrateKbps <= 0 && meta.durationMs > 0 && fileSize > 0) {
    meta.bitrateKbps = Math.round(fileSize * 8 / (meta.durationMs / 1000) / 1000);
  }
}

function normInt(s: string): number {
  const digits = s.replace(/[^0-9]/g, '');
  return digits.length > 0 ? parseInt(digits, 10) : 0;
}

// ============ ID3v2 ============

function parseId3v2(head: ReadAt, size: number, meta: SongMeta): number {
  const h = clampRead(head, size, 0, 10);
  if (h.length < 10 || !matchTag(h, 0, 'ID3')) {
    return 0;
  }
  const verMajor = h[3];
  const flags = h[5];
  const tagSize = ((h[6] & 0x7f) << 21) | ((h[7] & 0x7f) << 14) | ((h[8] & 0x7f) << 7) | (h[9] & 0x7f);
  const unsync = (flags & 0x80) !== 0;
  const body = clampRead(head, size, 10, Math.min(tagSize, 4 * 1024 * 1024));
  if (body.length === 0) {
    return 10 + tagSize;
  }
  let data: Uint8Array = body;
  if (unsync && verMajor <= 3) {
    // 整体去 unsync:FF 00 -> FF
    const out: number[] = [];
    for (let i = 0; i < body.length; i++) {
      out.push(body[i]);
      if (body[i] === 0xFF && i + 1 < body.length && body[i + 1] === 0x00) {
        i++;
      }
    }
    data = new Uint8Array(out);
  }
  const idLen = verMajor === 2 ? 3 : 4;
  const szLen = verMajor === 2 ? 3 : 4;
  let p = 0;
  while (p + idLen + szLen <= data.length) {
    if (data[p] === 0) {
      break; // padding
    }
    const frameId = ascii(data, p, idLen);
    let frameSize = 0;
    if (verMajor === 2) {
      frameSize = (data[p + 3] << 16) | (data[p + 4] << 8) | data[p + 5];
      p += 6;
    } else if (verMajor === 4) {
      frameSize = ((data[p + 4] & 0x7f) << 21) | ((data[p + 5] & 0x7f) << 14) | ((data[p + 6] & 0x7f) << 7) | (data[p + 7] & 0x7f);
      p += 10; // id+size+flags2
    } else {
      frameSize = u32be(data, p + 4);
      p += 10;
    }
    if (frameSize <= 0 || p + frameSize > data.length) {
      break;
    }
    const content = data.subarray(p, p + frameSize);
    p += frameSize;
    parseId3Frame(frameId, content, meta, verMajor);
  }
  return 10 + tagSize;
}

function decodeId3Text(content: Uint8Array): string {
  if (content.length === 0) {
    return '';
  }
  const enc = content[0];
  const body = content.subarray(1);
  if (enc === 0) {
    return latin1Decode(body).replace(/\0/g, '').trim();
  }
  if (enc === 1) {
    return utf16Decode(body, false).replace(/\0/g, '').trim();
  }
  if (enc === 2) {
    return utf16Decode(body, true).replace(/\0/g, '').trim();
  }
  return utf8Decode(body).replace(/\0/g, '').trim();
}

function parseId3Frame(frameId: string, content: Uint8Array, meta: SongMeta, ver: number): void {
  switch (frameId) {
    case 'TIT2':
    case 'TT2':
      meta.title = decodeId3Text(content);
      break;
    case 'TPE1':
    case 'TP1':
      meta.artist = decodeId3Text(content);
      break;
    case 'TALB':
    case 'TAL':
      meta.album = decodeId3Text(content);
      break;
    case 'TPE2':
    case 'TP2':
      meta.albumArtist = decodeId3Text(content);
      break;
    case 'TCON':
    case 'TCO':
      meta.genre = decodeId3Text(content).replace(/^\((\d+)\)/, '');
      break;
    case 'TYER':
    case 'TDRC':
    case 'TYE':
      meta.year = normInt(decodeId3Text(content).substring(0, 4));
      break;
    case 'TRCK':
    case 'TRK':
      meta.trackNo = normInt(decodeId3Text(content).split('/')[0]);
      break;
    case 'TPOS':
    case 'TPA':
      meta.discNo = normInt(decodeId3Text(content).split('/')[0]);
      break;
    case 'APIC':
    case 'PIC':
      parseApic(content, meta, ver);
      break;
    default:
      break;
  }
}

function parseApic(content: Uint8Array, meta: SongMeta, ver: number): void {
  try {
    let p = 1; // encoding
    let mime = '';
    if (ver === 2) {
      mime = ascii(content, p, 3);
      p += 3;
      mime = mime === 'JPG' ? 'image/jpeg' : mime === 'PNG' ? 'image/png' : 'image/jpeg';
    } else {
      let e = p;
      while (e < content.length && content[e] !== 0) {
        e++;
      }
      mime = ascii(content, p, e - p);
      p = e + 1;
    }
    p += 1; // picture type
    const enc = content[0];
    // description: enc==1/2 -> utf16 null-term (00 00)
    if (enc === 1 || enc === 2) {
      while (p + 1 < content.length && !(content[p] === 0 && content[p + 1] === 0)) {
        p += 2;
      }
      p += 2;
    } else {
      while (p < content.length && content[p] !== 0) {
        p++;
      }
      p += 1;
    }
    if (p < content.length && content.length - p > 128) {
      meta.coverData = content.subarray(p);
      meta.coverMime = mime.startsWith('image/') ? mime : 'image/jpeg';
    }
  } catch (e) {
    // 封面解析失败不影响主信息
  }
}

function parseMp3FrameHeader(head: ReadAt, size: number, meta: SongMeta, audioStart: number, fileSize: number): void {
  const probe = clampRead(head, size, audioStart, 64 * 1024);
  for (let i = 0; i + 4 < probe.length; i++) {
    if (probe[i] === 0xFF && (probe[i + 1] & 0xE0) === 0xE0) {
      const verBits = (probe[i + 1] >> 3) & 0x03;
      const layer = (probe[i + 1] >> 1) & 0x03;
      if (layer === 0 || verBits === 1) {
        continue;
      }
      const brIdx = (probe[i + 2] >> 4) & 0x0F;
      const srIdx = (probe[i + 2] >> 2) & 0x03;
      if (brIdx === 0 || brIdx === 15 || srIdx === 3) {
        continue;
      }
      const mpeg1 = verBits === 3;
      // layer bits: 01=Layer III(mp3) 10=Layer II 11=Layer I
      const brTable = mpeg1 && layer === 1 ? [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
        : mpeg1 && layer === 2 ? [0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384]
          : [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160];
      meta.bitrateKbps = brTable[brIdx];
      const srTable = mpeg1 ? [44100, 48000, 32000] : verBits === 0 ? [11025, 12000, 8000] : [22050, 24000, 16000];
      meta.sampleRate = srTable[srIdx];
      meta.channels = (probe[i + 3] >> 6) === 3 ? 1 : 2;
      if (meta.bitrateKbps > 0) {
        meta.durationMs = Math.round((fileSize - audioStart) * 8 / (meta.bitrateKbps * 1000) * 1000);
      }
      return;
    }
  }
}

// ============ FLAC ============

function parseFlac(head: ReadAt, size: number, meta: SongMeta, fileSize: number): void {
  const head4 = clampRead(head, size, 0, 4);
  if (head4.length < 4 || !matchTag(head4, 0, 'fLaC')) {
    return;
  }
  meta.codec = 'flac';
  let p = 4;
  let last = false;
  for (let guard = 0; guard < 128 && !last; guard++) {
    const bh = clampRead(head, size, p, 4);
    if (bh.length < 4) {
      break;
    }
    last = (bh[0] & 0x80) !== 0;
    const type = bh[0] & 0x7f;
    const len = (bh[1] << 16) | (bh[2] << 8) | bh[3];
    const bodyOff = p + 4;
    if (type === 0 && len >= 34) {
      const si = clampRead(head, size, bodyOff, 34);
      if (si.length >= 18) {
        meta.sampleRate = (si[10] << 12) | (si[11] << 4) | (si[12] >> 4);
        meta.channels = ((si[12] >> 1) & 0x07) + 1;
        meta.bitDepth = (((si[12] & 0x01) << 4) | (si[13] >> 4)) + 1;
        const hi = (si[13] & 0x0F);
        const total = (hi * 4294967296) + u32be(si, 14);
        meta.durationMs = meta.sampleRate > 0 ? Math.round(total * 1000 / meta.sampleRate) : 0;
        // 音频内容身份(0.13.0):STREAMINFO 自带未压缩 PCM 的 MD5(块体 18-33 字节,已在缓冲区)——tag 改动免疫
        if (si.length >= 34) {
          meta.pcmMd5 = hexOf(si.subarray(18, 34));
        }
      }
    } else if (type === 4) {
      const vc = clampRead(head, size, bodyOff, Math.min(len, 2 * 1024 * 1024));
      parseVorbisComments(vc, meta);
    } else if (type === 6) {
      const pic = clampRead(head, size, bodyOff, Math.min(len, 8 * 1024 * 1024));
      parseFlacPicture(pic, meta);
    }
    p = bodyOff + len;
  }
  setBitrate(meta, fileSize);
}

function parseFlacPicture(pic: Uint8Array, meta: SongMeta): void {
  try {
    let p = 4; // type
    const mimeLen = u32be(pic, p);
    p += 4;
    const mime = ascii(pic, p, mimeLen);
    p += mimeLen;
    const descLen = u32be(pic, p);
    p += 4 + descLen;
    p += 16; // w/h/depth/colors
    const dataLen = u32be(pic, p);
    p += 4;
    if (dataLen > 0 && p + dataLen <= pic.length) {
      meta.coverData = pic.subarray(p, p + dataLen);
      meta.coverMime = mime.length > 0 ? mime : 'image/jpeg';
    }
  } catch (e) {
  }
}

// ============ Vorbis Comment(FLAC / Ogg 共用) ============

function parseVorbisComments(vc: Uint8Array, meta: SongMeta): void {
  try {
    if (vc.length < 8) {
      return;
    }
    let p = u32le(vc, 0) + 4; // vendor
    const count = Math.min(u32le(vc, p), 256);
    p += 4;
    for (let i = 0; i < count && p + 4 <= vc.length; i++) {
      const len = u32le(vc, p);
      p += 4;
      if (len < 0 || p + len > vc.length) {
        break;
      }
      const line = utf8Decode(vc.subarray(p, p + len));
      p += len;
      const eq = line.indexOf('=');
      if (eq <= 0) {
        continue;
      }
      const key = line.substring(0, eq).toUpperCase();
      const val = line.substring(eq + 1);
      applyVorbisField(key, val, meta);
    }
  } catch (e) {
  }
}

function applyVorbisField(key: string, val: string, meta: SongMeta): void {
  switch (key) {
    case 'TITLE':
      meta.title = val;
      break;
    case 'ARTIST':
      if (meta.artist.length === 0) {
        meta.artist = val;
      }
      break;
    case 'ALBUM':
      meta.album = val;
      break;
    case 'ALBUMARTIST':
    case 'ALBUM ARTIST':
      meta.albumArtist = val;
      break;
    case 'GENRE':
      meta.genre = val;
      break;
    case 'DATE':
    case 'YEAR':
      if (meta.year === 0) {
        meta.year = normInt(val.substring(0, 4));
      }
      break;
    case 'TRACKNUMBER':
      meta.trackNo = normInt(val.split('/')[0]);
      break;
    case 'DISCNUMBER':
      meta.discNo = normInt(val.split('/')[0]);
      break;
    case 'REPLAYGAIN_TRACK_GAIN':
      meta.rgTrackGain = parseFloat(val.replace(' dB', ''));
      break;
    case 'REPLAYGAIN_TRACK_PEAK':
      meta.rgTrackPeak = parseFloat(val);
      break;
    case 'REPLAYGAIN_ALBUM_GAIN':
      meta.rgAlbumGain = parseFloat(val.replace(' dB', ''));
      break;
    case 'REPLAYGAIN_ALBUM_PEAK':
      meta.rgAlbumPeak = parseFloat(val);
      break;
    case 'METADATA_BLOCK_PICTURE': {
      // base64 -> flac picture 结构
      try {
        const helper = new utilBase64();
        const bin = helper.decode(val);
        parseFlacPicture(bin, meta);
      } catch (e) {
      }
      break;
    }
    default:
      break;
  }
}

// ============ Ogg ============

function parseOgg(head: ReadAt, size: number, tail: ReadAt, fileSize: number, meta: SongMeta): void {
  const pg = clampRead(head, size, 0, 128 * 1024);
  if (pg.length < 27 || !matchTag(pg, 0, 'OggS')) {
    return;
  }
  // 找到第一个包
  const segCount = pg[26];
  let bodyOff = 27 + segCount;
  let firstPacketLen = 0;
  for (let i = 0; i < segCount && 27 + i < pg.length; i++) {
    firstPacketLen += pg[27 + i];
  }
  const packet = clampRead(head, size, bodyOff, firstPacketLen);
  if (packet.length > 8 && matchTag(packet, 0, '\x01vorbis')) {
    meta.codec = 'ogg';
    meta.channels = packet[11];
    meta.sampleRate = u32le(packet, 12);
    meta.bitDepth = 16;
  } else if (packet.length > 19 && matchTag(packet, 0, 'OpusHead')) {
    meta.codec = 'opus';
    meta.channels = packet[9];
    meta.sampleRate = 48000; // Opus 输出恒 48k
    meta.bitDepth = 16;
  } else {
    // Ogg FLAC(oga)
    if (packet.length > 4 && matchTag(packet, 0, 'fLaC')) {
      meta.codec = 'flac';
      // 内嵌 STREAMINFO:跳过 Ogg 重建过于复杂,P0 借助后续包探测;退化处理:仅标记
    } else {
      return;
    }
  }
  // 注释包(第二个包):vorbis -> 0x03vorbis;opus -> OpusTags
  // 简化:从 bodyOff+firstPacketLen 起找 27..128KB 内的注释头
  const cStart = bodyOff + firstPacketLen;
  const cZone = clampRead(head, size, cStart, 512 * 1024);
  if (meta.codec === 'ogg') {
    const off = findSub(cZone, '\x03vorbis');
    if (off >= 0) {
      parseVorbisComments(cZone.subarray(off + 7), meta);
    }
  } else if (meta.codec === 'opus') {
    const off = findSub(cZone, 'OpusTags');
    if (off >= 0) {
      parseVorbisComments(cZone.subarray(off + 8), meta);
    }
  }
  // 时长:文件尾部最后 granule
  const tailZone = clampRead(tail, size, Math.max(0, size - 64 * 1024), 64 * 1024);
  const lastPage = findLastOggPage(tailZone);
  if (lastPage >= 0 && meta.sampleRate > 0) {
    const granule = u32le(tailZone, lastPage + 6) + u32le(tailZone, lastPage + 10) * 4294967296;
    if (granule > 0) {
      meta.durationMs = Math.round(granule * 1000 / meta.sampleRate);
    }
  }
  setBitrate(meta, fileSize);
}

function findSub(zone: Uint8Array, pat: string): number {
  if (pat.length === 0) {
    return -1;
  }
  const first = pat.charCodeAt(0);
  outer: for (let i = 0; i + pat.length <= zone.length; i++) {
    if (zone[i] !== first) {
      continue;
    }
    for (let j = 1; j < pat.length; j++) {
      if (zone[i + j] !== pat.charCodeAt(j)) {
        continue outer;
      }
    }
    return i;
  }
  return -1;
}

function findLastOggPage(zone: Uint8Array): number {
  let last = -1;
  for (let i = 0; i + 27 <= zone.length; i++) {
    if (zone[i] === 0x4F && zone[i + 1] === 0x67 && zone[i + 2] === 0x67 && zone[i + 3] === 0x53) {
      last = i;
    }
  }
  return last;
}

// ============ MP4 / M4A ============

function parseMp4(head: ReadAt, size: number, meta: SongMeta, fileSize: number): void {
  const h = clampRead(head, size, 4, 8);
  if (h.length < 8 || !matchTag(h, 0, 'ftyp')) {
    return;
  }
  meta.codec = 'm4a';
  walkMp4Atoms(head, size, 0, Math.min(size, 64 * 1024 * 1024), meta, 0);
  setBitrate(meta, fileSize);
}

function walkMp4Atoms(head: ReadAt, size: number, start: number, end: number, meta: SongMeta, depth: number): void {
  let p = start;
  while (p + 8 <= end && depth < 8) {
    const zone = readZone(head, size, p, Math.min(8, end - p));
    if (zone.length < 8) {
      break;
    }
    const szv = u32be(zone, 0);
    const type = ascii(zone, 4, 4);
    let atomSize = szv;
    if (szv === 1) {
      // 64位 size:读高 32 位(足够)
      const ext = readZone(head, size, p + 8, 8);
      if (ext.length >= 8) {
        atomSize = u32be(ext, 0) * 4294967296 + u32be(ext, 4);
      }
    }
    if (atomSize < 8 || p + atomSize > end) {
      atomSize = end - p; // 截断保护
    }
    if (type === 'moov' || type === 'udta' || type === 'meta' || type === 'ilst' || type === 'trak' || type === 'mdia') {
      const skip = type === 'meta' ? 4 : 0; // meta 有 4 字节 version/flags
      walkMp4Atoms(head, size, p + 8 + skip, p + atomSize, meta, depth + 1);
    } else if (type === 'mvhd') {
      const mv = readZone(head, size, p + 8, 32);
      if (mv.length >= 20) {
        const ver = mv[0];
        if (ver === 0) {
          const ts = u32be(mv, 12);
          const dur = u32be(mv, 16);
          if (ts > 0) {
            meta.durationMs = Math.round(dur * 1000 / ts);
          }
        } else {
          const ts = u32be(mv, 20);
          const hi = u32be(mv, 24);
          const lo = u32be(mv, 28);
          if (ts > 0) {
            meta.durationMs = Math.round((hi * 4294967296 + lo) * 1000 / ts);
          }
        }
      }
    } else if (type === '©nam' || type === '©ART' || type === '©alb' || type === 'aART' || type === '©gen'
      || type === '©day' || type === 'trkn' || type === 'disk' || type === 'covr' || type === 'gnre') {
      parseMp4IlstValue(head, size, p + 8, p + atomSize, type, meta);
    }
    p += atomSize;
  }
}

function parseMp4IlstValue(head: ReadAt, size: number, start: number, end: number, type: string, meta: SongMeta): void {
  // 值在子 atom 'data' 中
  let p = start;
  while (p + 8 <= end) {
    const zone = readZone(head, size, p, 8);
    if (zone.length < 8) {
      break;
    }
    const sz = u32be(zone, 0);
    const t = ascii(zone, 4, 4);
    if (t === 'data' && p + sz <= end && sz >= 16) {
      const body = readZone(head, size, p + 8, Math.min(sz - 8, 8 * 1024 * 1024));
      if (body.length >= 8) {
        const textType = u32be(body, 0);
        const val = body.subarray(8);
        if (type === '©nam') {
          meta.title = utf8Decode(val);
        } else if (type === '©ART') {
          meta.artist = utf8Decode(val);
        } else if (type === '©alb') {
          meta.album = utf8Decode(val);
        } else if (type === 'aART') {
          meta.albumArtist = utf8Decode(val);
        } else if (type === '©gen' || type === 'gnre') {
          meta.genre = type === '©gen' ? utf8Decode(val) : '';
        } else if (type === '©day') {
          meta.year = normInt(utf8Decode(val).substring(0, 4));
        } else if (type === 'trkn' && val.length >= 4) {
          meta.trackNo = u16be(val, 2);
        } else if (type === 'disk' && val.length >= 4) {
          meta.discNo = u16be(val, 2);
        } else if (type === 'covr') {
          if (val.length > 128) {
            meta.coverData = val;
            const jpegMagic = val[0] === 0xFF && val[1] === 0xD8;
            meta.coverMime = jpegMagic ? 'image/jpeg' : 'image/png';
          }
        }
      }
      break;
    }
    if (sz < 8) {
      break;
    }
    p += sz;
  }
}

// ============ WAV ============

function parseWav(head: ReadAt, size: number, meta: SongMeta, fileSize: number): void {
  const h = clampRead(head, size, 0, 12);
  if (h.length < 12 || !matchTag(h, 0, 'RIFF') || !matchTag(h, 8, 'WAVE')) {
    return;
  }
  meta.codec = 'wav';
  let p = 12;
  let fmtOk = false;
  let dataBytes = 0;
  let blockAlign = 0;
  for (let guard = 0; guard < 64; guard++) {
    const ch = clampRead(head, size, p, 8);
    if (ch.length < 8) {
      break;
    }
    const cid = ascii(ch, 0, 4);
    const sz = u32le(ch, 4);
    if (cid === 'fmt ' && sz >= 16) {
      const f = clampRead(head, size, p + 8, Math.min(sz, 40));
      if (f.length >= 16) {
        const fmtId = u16le(f, 0);
        meta.channels = u16le(f, 2);
        meta.sampleRate = u32le(f, 4);
        blockAlign = u16le(f, 12);
        meta.bitDepth = u16le(f, 14);
        if (fmtId === 1 && meta.bitDepth === 8) {
          // U8 也是 PCM
        }
        fmtOk = fmtId === 1 || fmtId === 3 || fmtId === 0xFFFE;
      }
    } else if (cid === 'data') {
      dataBytes = sz;
      if (sz === 0 || p + 8 + sz > size) {
        dataBytes = Math.max(0, size - p - 8);
      }
      break;
    } else if (cid === 'LIST' && sz > 8) {
      const l = clampRead(head, size, p + 8, Math.min(sz, 64 * 1024));
      if (l.length > 4 && matchTag(l, 0, 'INFO')) {
        let q = 4;
        while (q + 8 <= l.length) {
          const sid = ascii(l, q, 4);
          const sl = u32le(l, q + 4);
          if (q + 8 + sl > l.length) {
            break;
          }
          const val = utf8Decode(l.subarray(q + 8, q + 8 + sl)).replace(/\0/g, '').trim();
          if (sid === 'INAM') {
            meta.title = val;
          } else if (sid === 'IART') {
            meta.artist = val;
          } else if (sid === 'IPRD') {
            meta.album = val;
          } else if (sid === 'IGNR') {
            meta.genre = val;
          } else if (sid === 'ICRD') {
            meta.year = normInt(val.substring(0, 4));
          } else if (sid === 'ITRK') {
            meta.trackNo = normInt(val);
          }
          q += 8 + sl + (sl & 1);
        }
      }
    }
    p += 8 + sz + (sz & 1);
    if (sz === 0 && cid !== 'data') {
      break;
    }
  }
  if (fmtOk && meta.sampleRate > 0 && blockAlign > 0 && dataBytes > 0) {
    const frames = Math.floor(dataBytes / blockAlign);
    meta.durationMs = Math.round(frames * 1000 / meta.sampleRate);
  }
  setBitrate(meta, fileSize);
}

// ============ APE(Monkey's Audio) ============

function parseApe(head: ReadAt, size: number, tail: ReadAt, fileSize: number, meta: SongMeta): void {
  const h = clampRead(head, size, 0, 76);
  if (h.length < 8 || !matchTag(h, 0, 'MAC ')) {
    return;
  }
  meta.codec = 'ape';
  const version = u16le(h, 4);
  if (version >= 3980 && h.length >= 76) {
    // descriptor: nDescriptorBytes@8
    const descBytes = u32le(h, 8);
    const headerStart = 8 + descBytes;
    const hd = clampRead(head, size, headerStart, 44);
    if (hd.length >= 44) {
      // header: [0-3]'MAC ' [4-5]version [6-7]skip [8-11]blocksPerFrame [12-15]finalBlocks [16-19]totalFrames
      // [20-21]bits [22-23]channels [24-27]sampleRate
      const blocksPerFrame = u32le(hd, 8);
      const finalBlocks = u32le(hd, 12);
      const totalFrames = u32le(hd, 16);
      meta.bitDepth = u16le(hd, 20);
      meta.channels = u16le(hd, 22);
      meta.sampleRate = u32le(hd, 24);
      if (blocksPerFrame > 0 && meta.sampleRate > 0 && totalFrames > 0) {
        const blocks = (totalFrames - 1) * blocksPerFrame + finalBlocks;
        meta.durationMs = Math.round(blocks * 1000 / meta.sampleRate);
      }
    }
  } else if (version >= 3900 && h.length >= 34) {
    // <3980 旧头
    const blocksPerFrame = u32le(h, 12);
    const finalBlocks = u32le(h, 16);
    const totalFrames = u32le(h, 20);
    meta.channels = u16le(h, 26);
    meta.sampleRate = u32le(h, 28);
    if (blocksPerFrame > 0 && meta.sampleRate > 0 && totalFrames > 0) {
      const blocks = (totalFrames - 1) * blocksPerFrame + finalBlocks;
      meta.durationMs = Math.round(blocks * 1000 / meta.sampleRate);
    }
  }
  // APEv2 标签(尾部)
  const tailZone = clampRead(tail, size, Math.max(0, size - 128 * 1024), 128 * 1024);
  const tagOff = findApeTag(tailZone);
  if (tagOff >= 0) {
    parseApeTag(tailZone.subarray(tagOff), meta);
  }
  setBitrate(meta, fileSize);
}

function findApeTag(zone: Uint8Array): number {
  const pat = 'APETAGEX';
  for (let i = zone.length - 32; i >= 0; i--) {
    if (matchTag(zone, i, pat)) {
      return i;
    }
  }
  return -1;
}

function parseApeTag(tag: Uint8Array, meta: SongMeta): void {
  try {
    const tagSize = u32le(tag, 12);
    const count = Math.min(u32le(tag, 16), 512);
    let p = 32;
    const itemsEnd = Math.min(tagSize - 32, tag.length);
    for (let i = 0; i < count && p + 8 < itemsEnd; i++) {
      const valLen = u32le(tag, p);
      p += 4;
      p += 4; // flags
      let e = p;
      while (e < itemsEnd && tag[e] !== 0) {
        e++;
      }
      const key = ascii(tag, p, e - p).toUpperCase();
      p = e + 1;
      if (p + valLen > tag.length) {
        break;
      }
      const val = utf8Decode(tag.subarray(p, p + valLen));
      p += valLen;
      applyVorbisField(key === 'TRACK' ? 'TRACKNUMBER' : key, val, meta);
    }
  } catch (e) {
  }
}

// ============ AAC(ADTS) ============

function parseAac(head: ReadAt, size: number, meta: SongMeta, fileSize: number): void {
  const h = clampRead(head, size, 0, 16);
  if (h.length < 7 || h[0] !== 0xFF || (h[1] & 0xF6) !== 0xF0) {
    return;
  }
  meta.codec = 'aac';
  const srIdx = (h[2] >> 2) & 0x0F;
  const srTable = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350];
  meta.sampleRate = srIdx < srTable.length ? srTable[srIdx] : 44100;
  meta.channels = (((h[2] & 0x01) << 2) | (h[3] >> 6)) === 0 ? 2 : (((h[2] & 0x01) << 2) | (h[3] >> 6)); // channel_config
  meta.bitDepth = 16;
  meta.bitrateKbps = 128;
  if (meta.bitrateKbps > 0) {
    meta.durationMs = Math.round(fileSize * 8 / (meta.bitrateKbps * 1000) * 1000);
  }
}

// ============ 入口 ============

class utilBase64 {
  decode(s: string): Uint8Array {
    // 借助 util.Base64Helper 的 TS 侧等价实现由调用方注入;此处手写 base64 解码避免依赖
    const table = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    const clean: number[] = [];
    for (let i = 0; i < s.length; i++) {
      const ch = s.charAt(i);
      if (ch !== '=' && ch !== '\n' && ch !== '\r' && table.indexOf(ch) >= 0) {
        clean.push(table.indexOf(ch));
      }
    }
    const out = new Uint8Array(Math.floor(clean.length * 3 / 4));
    let o = 0;
    for (let i = 0; i + 3 < clean.length + 1; i += 4) {
      if (i + 3 >= clean.length + 1) {
        break;
      }
      const a = clean[i];
      const b = i + 1 < clean.length ? clean[i + 1] : 0;
      const c = i + 2 < clean.length ? clean[i + 2] : 0;
      const d = i + 3 < clean.length ? clean[i + 3] : 0;
      const n = (a << 18) | (b << 12) | (c << 6) | d;
      if (o < out.length) {
        out[o++] = (n >> 16) & 0xFF;
      }
      if (o < out.length && i + 2 < clean.length) {
        out[o++] = (n >> 8) & 0xFF;
      }
      if (o < out.length && i + 3 < clean.length) {
        out[o++] = n & 0xFF;
      }
    }
    return out.subarray(0, o);
  }
}

function readZone(head: ReadAt, size: number, off: number, len: number): Uint8Array {
  return clampRead(head, size, off, len);
}

// ---------------- DSD(DSF/DFF)头探测(P2:登记时长/采样率;解码在 native 引擎) ----------------

// DSF:'DSD '(28B) + 'fmt '(52B) + 'data';小端。
function parseDsfHead(head: ReadAt, fileSize: number, meta: SongMeta): void {
  const z = readZone(head, fileSize, 28, 60);
  if (z.length < 60 || !matchTag(z, 0, 'fmt ')) {
    return;
  }
  // fmt 内偏移:formatVersion(12) formatId(16) channelType(20) channelNum(24)
  //            samplingRate(28) bitsPerSample(32) sampleCount(36..44) blockSize(44)
  const chNum = u32le(z, 24);
  const rate = u32le(z, 28);
  const bits = u32le(z, 32);
  const sampleCount = Number(u64leFrom(z, 36));
  const blockSize = u32le(z, 44);
  if (rate < 1000000 || bits !== 1 || sampleCount <= 0 || blockSize !== 4096) {
    return;
  }
  // 'data' 块:偏移 28+52=80 起(4B 'data' + 8B size)
  const dz = readZone(head, fileSize, 80, 12);
  if (dz.length >= 12 && matchTag(dz, 0, 'data')) {
    const dataSize = Number(u64leFrom(dz, 4));
    if (dataSize > 0 && chNum > 0) {
      const bytesPerCh = Math.floor(dataSize / chNum);
      meta.durationMs = Math.round(bytesPerCh * 8 * 1000 / rate);
    }
  }
  meta.sampleRate = rate;
  meta.bitDepth = 1;
  meta.channels = chNum;
  meta.ok = true;
}

// DFF(DSDIFF):FRM8 容器,大端;FS(采样率)/CHNL(声道)/DSD(数据)。
function parseDffHead(head: ReadAt, fileSize: number, meta: SongMeta): void {
  let off = 16; // FRM8(4) + size(8) + form type 'DSD '(4),块从 16 起
  let rate = 0;
  let chNum = 0;
  let dsdStart = -1;
  let dsdSize = 0;
  for (let guard = 0; guard < 64; guard++) {
    const hz = readZone(head, fileSize, off, 12);
    if (hz.length < 12) {
      break;
    }
    const id = latin1Decode(hz.subarray(0, 4));
    const sz = Number(u64beFrom(hz, 4));
    if (sz <= 0 || sz > 0x7fffffff) {
      break;
    }
    if (id === 'FS  ') {
      const z = readZone(head, fileSize, off + 12, 4);
      if (z.length >= 4) {
        rate = u32be(z, 0);
      }
    } else if (id === 'CHNL') {
      const z = readZone(head, fileSize, off + 12, 2);
      if (z.length >= 2) {
        chNum = u16be(z, 0);
      }
    } else if (id === 'CMPR') {
      const z = readZone(head, fileSize, off + 12, 4);
      if (z.length >= 4 && latin1Decode(z.subarray(0, 4)) === 'DST ') {
        return; // DST 压缩:P2 不支持
      }
    } else if (id === 'DSD ') {
      dsdStart = off + 12;
      dsdSize = sz;
    }
    off += 12 + sz + (sz % 2 === 1 ? 1 : 0);
    if (dsdStart >= 0 && rate > 0 && chNum > 0) {
      break;
    }
  }
  if (dsdStart < 0 || rate < 1000000 || chNum < 1) {
    return;
  }
  const bytesPerCh = Math.floor(dsdSize / chNum);
  meta.durationMs = Math.round(bytesPerCh * 8 * 1000 / rate);
  meta.sampleRate = rate;
  meta.bitDepth = 1;
  meta.channels = chNum;
  meta.ok = true;
}

function u64leFrom(z: Uint8Array, off: number): bigint {
  let v = BigInt(0);
  for (let i = 7; i >= 0; i--) {
    v = (v << BigInt(8)) | BigInt(z[off + i] ?? 0);
  }
  return v;
}

function u64beFrom(z: Uint8Array, off: number): bigint {
  let v = BigInt(0);
  for (let i = 0; i < 8; i++) {
    v = (v << BigInt(8)) | BigInt(z[off + i] ?? 0);
  }
  return v;
}

export function parseAudioMeta(fileName: string, fileSize: number,
  head: ReadAt, tail: ReadAt): SongMeta {
  const meta = new SongMeta();
  const ext = extOf(fileName);
  const codecGuess: Record<string, string> = {
    'mp3': 'mp3', 'flac': 'flac', 'wav': 'wav', 'ogg': 'ogg', 'oga': 'ogg', 'opus': 'opus',
    'm4a': 'm4a', 'aac': 'aac', 'ape': 'ape', 'wv': 'wv', 'dsf': 'dsd', 'dff': 'dsd'
  };
  meta.codec = codecGuess[ext] ?? '';
  try {
    if (ext === 'mp3') {
      meta.codec = 'mp3';
      const id3End = parseId3v2(head, fileSize, meta);
      parseMp3FrameHeader(head, fileSize, meta, id3End > 0 ? id3End : 0, fileSize);
      setBitrate(meta, fileSize);
      meta.ok = meta.durationMs > 0 || meta.title.length > 0;
    } else if (ext === 'flac') {
      parseFlac(head, fileSize, meta, fileSize);
      meta.ok = meta.sampleRate > 0;
    } else if (ext === 'ogg' || ext === 'oga' || ext === 'opus') {
      parseOgg(head, fileSize, tail, fileSize, meta);
      meta.ok = meta.sampleRate > 0;
    } else if (ext === 'm4a' || ext === 'mp4' || ext === 'm4b') {
      parseMp4(head, fileSize, meta, fileSize);
      meta.ok = meta.durationMs > 0;
    } else if (ext === 'wav') {
      parseWav(head, fileSize, meta, fileSize);
      meta.ok = meta.sampleRate > 0;
    } else if (ext === 'ape') {
      parseApe(head, fileSize, tail, fileSize, meta);
      meta.ok = meta.sampleRate > 0;
    } else if (ext === 'aac') {
      parseAac(head, fileSize, meta, fileSize);
      meta.ok = meta.sampleRate > 0;
    } else if (ext === 'dsf') {
      parseDsfHead(head, fileSize, meta);
    } else if (ext === 'dff') {
      parseDffHead(head, fileSize, meta);
    } else if (ext === 'wv' || ext === 'wma') {
      // 不支持的容器:仅登记文件名
      meta.ok = true;
    }
  } catch (e) {
    meta.ok = false;
  }
  if (meta.title.length === 0) {
    meta.title = fileName.substring(0, fileName.lastIndexOf('.') > 0 ? fileName.lastIndexOf('.') : fileName.length);
  }
  return meta;
}

// 供测试/探测:magic 校验
export function probeCodec(head4: Uint8Array, ext: string): string {
  if (head4.length >= 4 && matchTag(head4, 0, 'fLaC')) {
    return 'flac';
  }
  if (head4.length >= 4 && matchTag(head4, 0, 'RIFF')) {
    return 'wav';
  }
  if (head4.length >= 4 && matchTag(head4, 0, 'OggS')) {
    return 'ogg';
  }
  if (head4.length >= 8 && matchTag(head4, 4, 'ftyp')) {
    return 'm4a';
  }
  if (head4.length >= 4 && matchTag(head4, 0, 'MAC ')) {
    return 'ape';
  }
  if (head4.length >= 3 && matchTag(head4, 0, 'ID3')) {
    return 'mp3';
  }
  if (head4.length >= 2 && head4[0] === 0xFF && (head4[1] & 0xE0) === 0xE0) {
    return 'mp3';
  }
  if (head4.length >= 2 && head4[0] === 0xFF && (head4[1] & 0xF6) === 0xF0) {
    return 'aac';
  }
  return ext;
}

export { u24be, fnv1a };

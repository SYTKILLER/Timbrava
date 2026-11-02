// EQ 频段与预设(纯 .ts:UI 与服务层共用;频点公式与 native dspPeqDefaultFreqs 一致)
// 31 段:f(i) = 20·800^(i/30),即 20Hz~16kHz 几何均分(近似 1/3 倍频程)。

export const PEQ_BAND_COUNT = 31;

export function peqBandFreq(i: number): number {
  return 20.0 * Math.pow(800.0, i / (PEQ_BAND_COUNT - 1));
}

export const PEQ_FREQS: number[] = buildFreqs();

function buildFreqs(): number[] {
  const a: number[] = [];
  for (let i = 0; i < PEQ_BAND_COUNT; i++) {
    a.push(peqBandFreq(i));
  }
  return a;
}

export function flatBands(): number[] {
  const a: number[] = [];
  for (let i = 0; i < PEQ_BAND_COUNT; i++) {
    a.push(0);
  }
  return a;
}

// 内置预设(名称 → 31 段增益 dB);与设置页选择器、applyEqToEngine 共用
function buildBuiltinPresets(): Record<string, number[]> {
  const map: Record<string, number[]> = {};
  map['flat'] = flatBands();
  const bass = flatBands();
  for (let i = 0; i < 10; i++) {
    bass[i] = 6 - i * 0.5;
  }
  map['bass'] = bass;
  const vocal = flatBands();
  for (let i = 8; i < 18; i++) {
    vocal[i] = 3.5;
  }
  map['vocal'] = vocal;
  const treble = flatBands();
  for (let i = 20; i < 31; i++) {
    treble[i] = 4;
  }
  map['treble'] = treble;
  const rock = flatBands();
  for (let i = 0; i < 6; i++) {
    rock[i] = 4;
  }
  for (let i = 22; i < 31; i++) {
    rock[i] = 3;
  }
  map['rock'] = rock;
  const electronic = flatBands();
  for (let i = 0; i < 8; i++) {
    electronic[i] = 5;
  }
  for (let i = 24; i < 31; i++) {
    electronic[i] = 3.5;
  }
  map['electronic'] = electronic;
  return map;
}

export const BUILTIN_PRESETS: Record<string, number[]> = buildBuiltinPresets();

export function presetBands(name: string): number[] {
  const b = BUILTIN_PRESETS[name];
  return b !== undefined ? b : flatBands();
}

export function isBuiltinPreset(name: string): boolean {
  return BUILTIN_PRESETS[name] !== undefined;
}

// AutoEq「GraphicEq:」文本导入(标准格式:`GraphicEq: 20-3.0;25-2.5;...;20000-1.0`,
// 频点-增益对,分号分隔;增益范围约 ±13.6)。按频点线性插值映射到 31 段固定频点。
// 也兼容纯 `f-g` 对列表(无前缀)。
export function parseAutoEq(text: string): number[] | null {
  if (text === null || text === undefined) {
    return null;
  }
  let t = text.trim();
  const gi = t.indexOf('GraphicEq:');
  if (gi >= 0) {
    t = t.substring(gi + 'GraphicEq:'.length).trim();
  }
  // 逐对解析:频点支持 1.5k/2.5k 缩写
  const parseFreq = (s: string): number => {
    const v = s.trim().toLowerCase();
    if (v.endsWith('k')) {
      return parseFloat(v.substring(0, v.length - 1)) * 1000;
    }
    return parseFloat(v);
  };
  const pairs = t.split(';');
  const freqs: number[] = [];
  const gains: number[] = [];
  for (const p of pairs) {
    const seg = p.trim();
    if (seg.length === 0) {
      continue;
    }
    const dash = seg.indexOf('-');
    // 频点本身不含负号;增益可能为负 → 取第一个 '-' 之后可能紧跟数字
    let fStr = '';
    let gStr = '';
    if (dash > 0) {
      fStr = seg.substring(0, dash);
      gStr = seg.substring(dash + 1);
    } else {
      // 空格分隔:`20 -3.0`
      const parts = seg.split(/\s+/);
      if (parts.length >= 2) {
        fStr = parts[0];
        gStr = parts[1];
      } else {
        continue;
      }
    }
    const f = parseFreq(fStr);
    const g = parseFloat(gStr);
    if (Number.isFinite(f) && Number.isFinite(g) && f > 0) {
      freqs.push(f);
      gains.push(Math.min(15, Math.max(-15, g)));
    }
  }
  if (freqs.length < 3) {
    return null;
  }
  // 升序排列(允许乱序输入)
  for (let i = 0; i < freqs.length; i++) {
    for (let j = i + 1; j < freqs.length; j++) {
      if (freqs[j] < freqs[i]) {
        const tf = freqs[i]; freqs[i] = freqs[j]; freqs[j] = tf;
        const tg = gains[i]; gains[i] = gains[j]; gains[j] = tg;
      }
    }
  }
  // 31 段固定频点插值(两端外推取端点值)
  const out: number[] = [];
  for (let b = 0; b < PEQ_BAND_COUNT; b++) {
    const f = PEQ_FREQS[b];
    if (f <= freqs[0]) {
      out.push(gains[0]);
      continue;
    }
    if (f >= freqs[freqs.length - 1]) {
      out.push(gains[gains.length - 1]);
      continue;
    }
    let k = 0;
    while (k < freqs.length - 1 && freqs[k + 1] < f) {
      k++;
    }
    const t = (f - freqs[k]) / Math.max(1e-6, freqs[k + 1] - freqs[k]);
    out.push(gains[k] + (gains[k + 1] - gains[k]) * t);
  }
  return out;
}

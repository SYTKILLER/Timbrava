// 歌词渲染面板(24-2 逐字卡拉OK底座):
// - 行级歌词:当前行高亮 + 自动居中滚动;
// - 逐词歌词(A2 扩展 <mm:ss.xx> 标签):活动行按词染色(已唱=主色/正在唱=强调色/未唱=次色);
// - 点词跳播:TextController 布局管理器 getCharacterPositionAtCoordinate(API 24)把点击坐标(px)
//   映射到字符偏移 → 定位所属词 → seek 该词起点(歌词点击校时链路);行级歌词点击 seek 行首;
// - 长行多行缩略:EllipsisMode.MULTILINE_CENTER(API 24)。
import { findActiveLineIndex, LyricWord, ParsedLyrics, parseLrc } from '../data/lyrics/LyricsParser';
import { PlayerController } from '../service/PlayerController';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { display } from '@kit.ArkUI';

const TAG = '[Timbrava][LyricsPanel]';
const DOMAIN = 0x0001;

@Component
export struct LyricsPanel {
  @Prop lyricText: string = '';
  @StorageProp('posVer') @Watch('onPosChanged') posVer: number = 0;
  @State posMs: number = 0;
  @State lines: string[] = [];
  @State times: number[] = [];
  @State activeIdx: number = -1;
  @State wordTick: number = 0; // 活动行逐词染色刷新位(位置 tick 自增驱动 Span 重估)
  private scroller: Scroller = new Scroller();
  private txtCtrl: TextController = new TextController();
  private parsed: ParsedLyrics | null = null;
  private parsedFor: string = '';
  private density: number = 3.25; // px per vp(aboutToAppear 实测)

  onPosChanged(): void {
    this.posMs = Math.round(PlayerController.get().positionMs);
    this.wordTick++;
    this.updateActive(this.posMs);
  }

  private ensureParsed(): void {
    if (this.parsedFor !== this.lyricText) {
      try {
        this.parsed = parseLrc(this.lyricText);
        const texts: string[] = [];
        const times: number[] = [];
        for (const l of this.parsed.lines) {
          texts.push(l.text);
          times.push(l.timeMs);
        }
        this.lines = texts;
        this.times = times;
        this.activeIdx = -1;
        hilog.info(DOMAIN, TAG, 'parsed lines=%{public}d wordLevel=%{public}d',
          texts.length, this.parsed.isWordLevel ? 1 : 0);
      } catch (e) {
        hilog.error(DOMAIN, TAG, 'parse fail %{public}s', (e as Error).message);
      }
      this.parsedFor = this.lyricText;
    }
  }

  aboutToAppear(): void {
    try {
      this.density = display.getDefaultDisplaySync().densityPixels;
    } catch (e) {
    }
    this.posMs = Math.round(PlayerController.get().positionMs);
    this.updateActive(this.posMs);
  }

  build() {
    if (this.lyricText.length === 0) {
      Column({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.music_note_list'))
          .fontSize(36)
          .fontColor([$r('app.color.text_secondary')])
        Text($r('app.string.lyrics_none'))
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .padding({ top: 60, bottom: 60 })
    } else {
      List({ scroller: this.scroller, space: 14 }) {
        // 顶部留白,让首行也能居中
        ListItem() {
          Column().height(120).width('100%')
        }
        ForEach(this.lines, (line: string, i: number) => {
          ListItem() {
            this.LyricLineItem(line, i)
          }
        }, (line: string, i: number): string => `${i}_${this.activeIdx === i ? 'a' : 'n'}`)
        ListItem() {
          Column().height(160).width('100%')
        }
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .onAppear((): void => {
        // 首帧定位
      })
    }
  }

  // 单行渲染:活动行且逐词 → 卡拉OK Text(字符定位点词);否则普通 Text(点行 seek 行首)
  @Builder
  LyricLineItem(line: string, i: number) {
    if (this.activeIdx === i && this.activeWords() !== null) {
      Text('', { controller: this.txtCtrl }) {
        ForEach(this.activeWords() as LyricWord[], (w: LyricWord, wi: number) => {
          Span(w.text)
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.wordColor(w, wi))
        }, (w: LyricWord, wi: number): string => `${wi}_${this.wordState(w, wi)}`)
      }
      .width('100%')
      .textAlign(TextAlign.Center)
      .maxLines(2)
      .ellipsisMode(EllipsisMode.MULTILINE_CENTER)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .lineHeight(26)
      .onClick((e: ClickEvent): void => {
        this.onKaraokeTap(e, i);
      })
    } else {
      Text(line)
        .fontSize(this.activeIdx === i ? 18 : 14)
        .fontWeight(this.activeIdx === i ? FontWeight.Bold : FontWeight.Normal)
        .fontColor(this.activeIdx === i ? $r('app.color.accent') : $r('app.color.text_secondary'))
        .width('100%')
        .textAlign(TextAlign.Center)
        .maxLines(2)
        .ellipsisMode(EllipsisMode.MULTILINE_CENTER)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .onClick((): void => {
          hilog.info(DOMAIN, TAG, 'line tap i=%{public}d -> %{public}dms', i,
            i >= 0 && i < this.times.length ? Math.round(this.times[i]) : -1);
          if (i >= 0 && i < this.times.length) {
            PlayerController.get().seekTo(this.times[i]);
          }
        })
    }
  }

  // ===== 逐词卡拉OK辅助 =====

  private activeWords(): LyricWord[] | null {
    if (this.parsed === null || this.activeIdx < 0 || this.activeIdx >= this.parsed.lines.length) {
      return null;
    }
    return this.parsed.lines[this.activeIdx].words;
  }

  // 词状态:0 未唱 / 1 正在唱 / 2 已唱(末词无后继边界:到点即判已唱)
  private wordState(w: LyricWord, wi: number): number {
    if (this.parsed === null) {
      return 0;
    }
    const pos = this.posMs - this.parsed.offsetMs;
    const words = this.activeWords();
    if (words === null) {
      return 0;
    }
    const start = w.timeMs;
    if (wi + 1 >= words.length) {
      return pos >= start ? 2 : 0;
    }
    const end = words[wi + 1].timeMs;
    if (pos >= end) {
      return 2;
    }
    if (pos >= start) {
      return 1;
    }
    return 0;
  }

  private wordColor(w: LyricWord, wi: number): ResourceColor {
    const st = this.wordState(w, wi);
    if (st === 2) {
      return $r('app.color.text_primary');
    }
    if (st === 1) {
      return $r('app.color.accent');
    }
    return $r('app.color.text_secondary');
  }

  // 点词跳播:点击坐标(vp→px)→ 字符偏移 → 所属词起点 seek。
  // position 编码不确定(JS UTF-16 或 UTF-8 字节),按长度特征双轨换算。
  private onKaraokeTap(e: ClickEvent, lineIdx: number): void {
    const words = this.activeWords();
    if (words === null || words.length === 0) {
      return;
    }
    const full = words.map((w: LyricWord): string => w.text).join('');
    let charPos = -1;
    try {
      const lm: LayoutManager = this.txtCtrl.getLayoutManager();
      const p = lm.getCharacterPositionAtCoordinate(e.x * this.density, e.y * this.density);
      if (p !== undefined) {
        charPos = this.toCharIndex(p.position, full);
      }
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'charPosition fail %{public}s', (err as Error).message);
    }
    // 字符定位失败 → 退化为整行 seek(仍有"点歌词跳播"价值)
    let wordIdx = words.length - 1;
    if (charPos >= 0) {
      let acc = 0;
      wordIdx = words.length - 1;
      for (let i = 0; i < words.length; i++) {
        acc += words[i].text.length;
        if (charPos < acc) {
          wordIdx = i;
          break;
        }
      }
    } else {
      wordIdx = -1;
    }
    const seekToMs = wordIdx >= 0 ? words[wordIdx].timeMs : this.times[lineIdx];
    hilog.info(DOMAIN, TAG, 'karaoke tap line=%{public}d char=%{public}d word=%{public}d -> %{public}dms',
      lineIdx, charPos, wordIdx, Math.round(seekToMs));
    PlayerController.get().seekTo(seekToMs);
  }

  // 把布局管理器返回的字符位置换算为 JS 字符串下标:UTF-8 字节偏移(含 CJK 时>长度)→ 逐字符按字节宽回推
  private toCharIndex(pos: number, text: string): number {
    if (pos <= 0) {
      return 0;
    }
    if (pos <= text.length) {
      return Math.min(pos, text.length); // UTF-16 码元口径
    }
    // UTF-8 字节口径:遍历字符累计字节宽,定位字节偏移所在 JS 下标
    let bytes = 0;
    for (let i = 0; i < text.length; i++) {
      const c = text.charCodeAt(i);
      if (c < 0x80) {
        bytes += 1;
      } else if (c < 0x800) {
        bytes += 2;
      } else if (c >= 0xD800 && c <= 0xDBFF) {
        bytes += 4; // 代理对整体 4 字节
      } else if (c >= 0xDC00 && c <= 0xDFFF) {
        bytes += 0; // 已并入代理对
      } else {
        bytes += 3;
      }
      if (bytes >= pos) {
        return i + 1;
      }
    }
    return text.length;
  }

  // 父组件位置更新后调用(onPosUpdate),避免 @Prop posMs 大频率 diff
  updateActive(posMs: number): void {
    this.ensureParsed();
    if (this.parsed === null || this.parsed.lines.length === 0) {
      return;
    }
    const eff = posMs - this.parsed.offsetMs;
    const idx = findActiveLineIndex(this.parsed, eff);
    if (idx !== this.activeIdx) {
      this.activeIdx = idx;
      if (idx >= 0 && idx < this.lines.length) {
        // 目标行滚到中部:索引 + 顶部留白补偿
        this.scroller.scrollToIndex(idx + 1, true, ScrollAlign.CENTER);
      }
    }
  }
}

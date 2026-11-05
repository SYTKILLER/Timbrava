// 桌面歌词浮窗页(26-7,floatView 承载):仅渲染当前行——词级歌词按已唱/未唱双色,行级整行白字。
// 无任何交互元素;经 AppStorage(playerVer/posVer)与播放器共享状态,浮窗内独立 UI 实例。
import { findActiveLineIndex, LyricWord, ParsedLyrics, parseLrc } from '../../data/lyrics/LyricsParser';
import { PlayerController } from '../../service/PlayerController';

interface WordSpan {
  text: string;
  sung: boolean;
}

@Entry
@Component
struct DesktopLyricsPage {
  @StorageProp('playerVer') @Watch('onTick') playerVer: number = 0;
  @StorageProp('posVer') @Watch('onTick') posVer: number = 0;
  @State spans: WordSpan[] = [];
  private parsed: ParsedLyrics | null = null;
  private parsedFor: string = '';

  aboutToAppear(): void {
    this.onTick();
  }

  private onTick(): void {
    const text = PlayerController.get().currentLyrics;
    if (text.length === 0) {
      this.spans = [];
      return;
    }
    if (this.parsedFor !== text) {
      try {
        this.parsed = parseLrc(text);
      } catch (e) {
        this.parsed = null;
      }
      this.parsedFor = text;
    }
    const p = this.parsed;
    if (p === null || p.lines.length === 0) {
      return;
    }
    const eff = Math.round(PlayerController.get().positionMs) - p.offsetMs;
    const idx = findActiveLineIndex(p, eff);
    if (idx < 0) {
      this.spans = [];
      return;
    }
    const line = p.lines[idx];
    const words = line.words;
    if (words === null || words.length === 0) {
      this.spans = [{ text: line.text, sung: false }];
      return;
    }
    // 词级:当前词及之前=已唱(亮),之后=未唱(淡)
    const out: WordSpan[] = [];
    let reached = false;
    for (const w of words as LyricWord[]) {
      const sung = !reached;
      if (!reached && w.timeMs > eff) {
        reached = true;
        out.push({ text: w.text, sung: false });
        continue;
      }
      out.push({ text: w.text, sung: sung });
    }
    this.spans = out;
  }

  build() {
    Stack() {
      Text() {
        ForEach(this.spans, (s: WordSpan) => {
          Span(s.text)
            .fontSize(22)
            .fontWeight(FontWeight.Bold)
            .fontColor(s.sung ? '#FF6BD5FF' : '#B3FFFFFF')
        }, (s: WordSpan, i: number): string => `${i}_${s.sung ? 1 : 0}`)
      }
      .maxLines(1)
      .textOverflow({ overflow: TextOverflow.MARQUEE })
      .textAlign(TextAlign.Center)
      .width('100%')
      .textShadow({ radius: 6, color: '#99000000', offsetX: 0, offsetY: 2 })
    }
    .width('100%')
    .height('100%')
    .alignContent(Alignment.Center)
    .backgroundColor(Color.Transparent)
  }
}

// 同步歌词渲染面板:当前行高亮 + 自动居中滚动(仅活动行变化时滚动)。
import { findActiveLineIndex, ParsedLyrics, parseLrc } from '../data/lyrics/LyricsParser';
import { PlayerController } from '../service/PlayerController';
import { hilog } from '@kit.PerformanceAnalysisKit';

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
  private scroller: Scroller = new Scroller();
  private parsed: ParsedLyrics | null = null;
  private parsedFor: string = '';

  onPosChanged(): void {
    this.posMs = Math.round(PlayerController.get().positionMs);
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
        hilog.info(DOMAIN, TAG, 'parsed lines=%{public}d textLen=%{public}d', texts.length, this.lyricText.length);
      } catch (e) {
        hilog.error(DOMAIN, TAG, 'parse fail %{public}s', (e as Error).message);
      }
      this.parsedFor = this.lyricText;
    }
  }

  aboutToAppear(): void {
    this.posMs = Math.round(PlayerController.get().positionMs);
    this.updateActive(this.posMs);
  }

  build() {
    if (this.lyricText.length === 0) {
      Column({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.music_note_list'))
          .fontSize(36)
          .fontColor([$r('app.color.text_secondary')])
        Text('暂无歌词')
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
            Text(line)
              .fontSize(this.activeIdx === i ? 18 : 14)
              .fontWeight(this.activeIdx === i ? FontWeight.Bold : FontWeight.Normal)
              .fontColor(this.activeIdx === i ? $r('app.color.accent') : $r('app.color.text_secondary'))
              .width('100%')
              .textAlign(TextAlign.Center)
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

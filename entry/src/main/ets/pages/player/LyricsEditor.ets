// 歌词编辑器(打轴,#37):播放中逐行标记时间戳 → LRC;存 lyrics_cache + 可导出 .lrc 文件。
// 数据源:lyrics_cache / 文件头内嵌;每行可标记/清除时间,文本可改。
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { picker } from '@kit.CoreFileKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { PlayerController } from '../../service/PlayerController';
import { LibraryStore } from '../../data/LibraryStore';
import { Db } from '../../data/Db';
import { Song, formatDuration } from '../../data/Model';
import { extractLyricsFromHead } from '../../data/lyrics/LyricsExtractor';

const TAG = '[Timbrava][LrcEditor]';
const DOMAIN = 0x0001;

class EditorLine {
  text: string = '';
  timeMs: number = -1; // -1 未打轴

  constructor(text: string, timeMs: number) {
    this.text = text;
    this.timeMs = timeMs;
  }
}

function fmtLrcTime(ms: number): string {
  const total = Math.max(0, ms);
  const m = Math.floor(total / 60000);
  const s = Math.floor((total % 60000) / 1000);
  const cs = Math.floor((total % 1000) / 10);
  return `${m < 10 ? '0' : ''}${m}:${s < 10 ? '0' : ''}${s}.${cs < 10 ? '0' : ''}${cs}`;
}

@Component
export struct LyricsEditorDest {
  @StorageProp('playerVer') playerVer: number = 0;
  @StorageProp('posVer') posVer: number = 0;
  @State lines: EditorLine[] = [];
  @State songId: number = -1;
  @State loaded: boolean = false;
  @State savedTip: string = '';
  private pathStack: NavPathStack | null = null;

  aboutToAppear(): void {
    // onReady 之前先尝试从控制器当前曲取
    const cur = PlayerController.get().currentSong;
    if (cur !== null) {
      this.songId = cur.id;
    }
    this.loadAsync(this.songId);
  }

  private song(): Song | null {
    if (this.songId >= 0) {
      return LibraryStore.get().song(this.songId);
    }
    return PlayerController.get().currentSong;
  }

  private async loadAsync(id: number): Promise<void> {
    if (id < 0) {
      return;
    }
    let text = PlayerController.get().currentLyrics;
    if (text.length === 0) {
      text = await Db.get().getLyricsCache(id);
    }
    const song = this.song();
    if (text.length === 0 && song !== null) {
      let file: fs.File | null = null;
      try {
        file = fs.openSync(song.path, fs.OpenMode.READ_ONLY);
        const buf = new ArrayBuffer(4 * 1024 * 1024);
        const n = fs.readSync(file.fd, buf);
        text = extractLyricsFromHead(new Uint8Array(buf, 0, n));
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'head extract fail %{public}s', (e as Error).message);
      } finally {
        if (file !== null) {
          try {
            fs.closeSync(file);
          } catch (e2) {
          }
        }
      }
    }
    const arr: EditorLine[] = [];
    if (text.length > 0) {
      // 已有时间戳的行保留;无时间戳行 timeMs=-1(可打轴)
      for (const raw of text.split('\n')) {
        const line = raw.replace(/\r$/, '');
        const m = line.match(/^\s*\[(\d{1,2}):(\d{1,2})(?:\.(\d{1,3}))?\](.*)$/);
        if (m !== null) {
          const mm = parseInt(m[1], 10);
          const ss = parseInt(m[2], 10);
          const fracStr = m[3] ?? '0';
          const frac = parseInt(fracStr.padEnd(3, '0').substring(0, 3), 10);
          const rest = m[4] ?? '';
          if (rest.trim().length > 0) {
            arr.push(new EditorLine(rest, (mm * 60 + ss) * 1000 + frac));
          }
        } else if (line.trim().length > 0 && !line.startsWith('[')) {
          arr.push(new EditorLine(line, -1));
        }
      }
    }
    this.lines = arr;
    this.loaded = true;
  }

  private markLine(i: number): void {
    const pos = Math.round(PlayerController.get().positionMs);
    const next = this.lines.slice();
    next[i] = new EditorLine(this.lines[i].text, pos);
    this.lines = next;
    // 打轴后自动播放下一未打轴行提示(不强制)
    hilog.info(DOMAIN, TAG, 'mark line %{public}d -> %{public}dms', i, pos);
  }

  private clearLine(i: number): void {
    const next = this.lines.slice();
    next[i] = new EditorLine(this.lines[i].text, -1);
    this.lines = next;
  }

  private updateText(i: number, t: string): void {
    const next = this.lines.slice();
    next[i] = new EditorLine(t, this.lines[i].timeMs);
    this.lines = next;
  }

  // 排序生成 LRC(未打轴行跳过)
  private buildLrc(): string {
    const marked = this.lines.filter((l: EditorLine): boolean => l.timeMs >= 0);
    const sorted = marked.slice().sort((a: EditorLine, b: EditorLine): number => a.timeMs - b.timeMs);
    const out: string[] = [];
    for (const l of sorted) {
      out.push(`[${fmtLrcTime(l.timeMs)}]${l.text}`);
    }
    return out.join('\n');
  }

  private async save(): Promise<void> {
    const lrc = this.buildLrc();
    if (lrc.length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: '还没有打轴的行' });
      return;
    }
    await Db.get().putLyricsCache(this.songId, lrc);
    PlayerController.get().currentLyrics = lrc;
    this.savedTip = '已保存';
    this.getUIContext().getPromptAction().showToast({ message: '歌词已保存' });
    hilog.info(DOMAIN, TAG, 'saved song=%{public}d lines=%{public}d', this.songId, this.lines.length);
  }

  // 导出 .lrc(零权限 DocumentViewPicker;模拟器保存键缺陷留真机验证)
  private async exportLrc(): Promise<void> {
    const lrc = this.buildLrc();
    if (lrc.length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: '还没有打轴的行' });
      return;
    }
    const song = this.song();
    const baseName = song !== null ? song.displayTitle().replace(/[\\/:*?"<>|]/g, '_') : 'lyrics';
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const opts = new picker.DocumentSaveOptions();
      opts.newFileNames = [`${baseName}.lrc`];
      const docPicker = new picker.DocumentViewPicker(ctx);
      const uris = await docPicker.save(opts);
      if (uris === undefined || uris.length === 0) {
        return;
      }
      const enc = new util.TextEncoder();
      const bytes = enc.encodeInto(lrc);
      const f = fs.openSync(uris[0], fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      fs.writeSync(f.fd, bytes.buffer as ArrayBuffer);
      fs.closeSync(f);
      this.getUIContext().getPromptAction().showToast({ message: '已导出 .lrc' });
      hilog.info(DOMAIN, TAG, 'exported %{public}d bytes', bytes.length);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'export fail %{public}s', (e as Error).message);
      this.getUIContext().getPromptAction().showToast({ message: '导出失败' });
    }
  }

  build() {
    NavDestination() {
      Column() {
        // 顶部:歌曲 + 播放位置
        Row({ space: 10 }) {
          Column({ space: 2 }) {
            Text(this.song() !== null ? (this.song() as Song).displayTitle() : '未在播放')
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(`当前位置 ${formatDuration(Math.round(PlayerController.get().positionMs))} · 点「打轴」标记该时间`)
              .fontSize(11)
              .fontColor($r('app.color.text_secondary'))
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          Button({ stateEffect: true }) {
            SymbolGlyph(PlayerController.get().isPlaying ? $r('sys.symbol.pause_fill') : $r('sys.symbol.play_fill'))
              .fontSize(20)
              .fontColor([$r('app.color.on_accent')])
          }
          .width(40)
          .height(40)
          .borderRadius(20)
          .backgroundColor($r('app.color.accent'))
          .onClick(() => {
            PlayerController.get().playPause();
          })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 10, bottom: 8 })

        if (!this.loaded) {
          Column({ space: 8 }) {
            LoadingProgress().width(28).height(28).color($r('app.color.accent'))
            Text('读取歌词文本…')
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else if (this.lines.length === 0) {
          Column({ space: 8 }) {
            SymbolGlyph($r('sys.symbol.doc_plaintext'))
              .fontSize(40)
              .fontColor([$r('app.color.text_secondary')])
            Text('没有歌词文本。可先在文件里内嵌歌词,或用 LRCLIB 下载')
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
              .textAlign(TextAlign.Center)
              .padding({ left: 24, right: 24 })
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          List({ space: 0 }) {
            ForEach(this.lines, (l: EditorLine, i: number) => {
              ListItem() {
                Row({ space: 8 }) {
                  Text(l.timeMs >= 0 ? fmtLrcTime(l.timeMs) : '--:--.--')
                    .fontSize(11)
                    .fontColor(l.timeMs >= 0 ? $r('app.color.accent') : $r('app.color.text_secondary'))
                    .width(64)
                  TextInput({ text: l.text })
                    .fontSize(13)
                    .height(36)
                    .layoutWeight(1)
                    .backgroundColor(Color.Transparent)
                    .onChange((v: string): void => {
                      this.updateText(i, v);
                    })
                  if (l.timeMs >= 0) {
                    Button({ stateEffect: true }) {
                      SymbolGlyph($r('sys.symbol.minus_circle'))
                        .fontSize(15)
                        .fontColor([$r('app.color.text_secondary')])
                    }
                    .width(28)
                    .height(28)
                    .backgroundColor(Color.Transparent)
                    .onClick(() => {
                      this.clearLine(i);
                    })
                  }
                  Button('打轴')
                    .fontSize(11)
                    .height(28)
                    .fontColor($r('app.color.on_accent'))
                    .backgroundColor($r('app.color.accent'))
                    .onClick(() => {
                      this.markLine(i);
                    })
                }
                .width('100%')
                .padding({ left: 16, right: 12, top: 3, bottom: 3 })
              }
            }, (l: EditorLine, i: number): string => `${i}_${l.timeMs}_${l.text.length}`)
          }
          .width('100%')
          .layoutWeight(1)
          .scrollBar(BarState.Auto)
        }

        // 底部操作
        Row({ space: 10 }) {
          Text(this.savedTip)
            .fontSize(11)
            .fontColor($r('app.color.text_secondary'))
          Blank()
          Button('导出 .lrc')
            .fontSize(12)
            .height(36)
            .fontColor($r('app.color.text_primary'))
            .backgroundColor($r('app.color.badge_bg'))
            .onClick(() => {
              this.exportLrc();
            })
          Button('保存歌词')
            .fontSize(12)
            .height(36)
            .fontColor($r('app.color.on_accent'))
            .backgroundColor($r('app.color.accent'))
            .onClick(() => {
              this.save();
            })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: 16 })
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.page_bg'))
    }
    .title('歌词打轴')
    .onReady((ctx: NavDestinationContext): void => {
      this.pathStack = ctx.pathStack;
      const p: Object | undefined = ctx.pathInfo.param as Object | undefined;
      if (p !== null && p !== undefined && typeof p === 'number') {
        const id = p as number;
        if (id !== this.songId) {
          this.songId = id;
          this.loadAsync(id);
        }
      }
    })
  }
}

@Builder
export function LyricsEditorBuilder() {
  LyricsEditorDest()
}

// 重复清理(#9):同标题+艺人且时长±2s、或同体积同时长的跨路径重复检测
// → 分组报告;每组默认保留首条,其余可从库移除(不删文件)。
import { hilog } from '@kit.PerformanceAnalysisKit';
import { LibraryStore } from '../../data/LibraryStore';
import { Db } from '../../data/Db';
import { Song, formatDuration, formatSize } from '../../data/Model';
import { L } from '../../common/Lang';

const TAG = '[Timbrava][Duplicates]';
const DOMAIN = 0x0001;

class DupGroup {
  label: string = '';
  songs: Song[] = [];
}

function normKey(s: string): string {
  return s.trim().toLowerCase().replace(/\s+/g, ' ');
}

@Component
export struct DuplicatesDest {
  @StorageProp('libVer') libVer: number = 0;
  @StorageProp('topSafeVp') topSafeVp: number = 36; // 全屏沉浸后手动避让状态栏
  @State groups: DupGroup[] = [];
  private pathStack: NavPathStack | null = null;

  aboutToAppear(): void {
    this.rebuild();
  }

  private rebuild(): void {
    const songs = LibraryStore.get().songs;
    const groups: DupGroup[] = [];
    const used: boolean[] = new Array<boolean>(songs.length).fill(false);
    for (let i = 0; i < songs.length; i++) {
      if (used[i]) {
        continue;
      }
      const a = songs[i];
      const group = new DupGroup();
      group.songs.push(a);
      used[i] = true;
      for (let j = i + 1; j < songs.length; j++) {
        if (used[j]) {
          continue;
        }
        const b = songs[j];
        if (b.path === a.path) {
          continue; // CUE 分轨同文件不算重复
        }
        const sameMeta = normKey(a.displayTitle()) === normKey(b.displayTitle()) &&
          normKey(a.displayArtist()) === normKey(b.displayArtist()) &&
          Math.abs(a.durationMs - b.durationMs) <= 2000;
        const sameFile = a.fileSize === b.fileSize && a.fileSize > 0 && Math.abs(a.durationMs - b.durationMs) <= 2000;
        if (sameMeta || sameFile) {
          group.songs.push(b);
          used[j] = true;
        }
      }
      if (group.songs.length > 1) {
        group.label = `${a.displayTitle()} — ${a.displayArtist()}`;
        groups.push(group);
      }
    }
    this.groups = groups;
    hilog.info(DOMAIN, TAG, 'dup groups=%{public}d', groups.length);
  }

  private async removeFromLibrary(songId: number): Promise<void> {
    await Db.get().removeSongCompletely(songId);
    await LibraryStore.get().reload();
    AppStorage.setOrCreate('libVer', (AppStorage.get<number>('libVer') ?? 0) + 1);
    this.rebuild();
    hilog.info(DOMAIN, TAG, 'removed from library song=%{public}d', songId);
  }

  build() {
    NavDestination() {
      Column() {
        Text($r('app.string.dup_note'))
          .fontSize(11)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .padding({ left: 16, right: 16, top: 8 })
        if (this.groups.length === 0) {
          Column({ space: 8 }) {
            SymbolGlyph($r('sys.symbol.checkmark'))
              .fontSize(40)
              .fontColor([$r('app.color.accent')])
            Text($r('app.string.dup_none'))
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          List({ space: 8 }) {
            ForEach(this.groups, (g: DupGroup, gi: number) => {
              ListItem() {
                Column({ space: 4 }) {
                  Text(L($r('app.string.dup_group'), g.label, g.songs.length))
                    .fontSize(13)
                    .fontWeight(FontWeight.Bold)
                    .fontColor($r('app.color.text_primary'))
                    .width('100%')
                  ForEach(g.songs, (s: Song, si: number) => {
                    Row({ space: 8 }) {
                      Column({ space: 2 }) {
                        Text(si === 0 ? $r('app.string.str_keep') : formatDuration(s.durationMs) + ' · ' + formatSize(s.fileSize))
                          .fontSize(10)
                          .fontColor(si === 0 ? $r('app.color.accent') : $r('app.color.text_secondary'))
                        Text(s.path)
                          .fontSize(10)
                          .fontColor($r('app.color.text_secondary'))
                          .maxLines(1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                      }
                      .alignItems(HorizontalAlign.Start)
                      .layoutWeight(1)
                      if (si > 0) {
                        Button($r('app.string.str_remove'))
                          .fontSize(11)
                          .height(26)
                          .fontColor($r('app.color.text_primary'))
                          .backgroundColor($r('app.color.badge_bg'))
                          .onClick(() => {
                            this.removeFromLibrary(s.id);
                          })
                      }
                    }
                    .width('100%')
                    .padding({ top: 4, bottom: 4 })
                  }, (s: Song): string => `dup_${gi}_${s.id}`)
                }
                .width('100%')
                .padding(12)
                .borderRadius(12)
                .backgroundColor($r('app.color.card_bg'))
              }
            }, (g: DupGroup): string => `dupg_${g.label}_${g.songs.length}_${this.libVer}`)
          }
          .width('100%')
          .layoutWeight(1)
          .scrollBar(BarState.Auto)
          .padding({ left: 16, right: 16, bottom: 40 })
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.page_bg'))
    }
    .padding({ top: this.topSafeVp })
    .title($r('app.string.duplicates_title'))
    .onReady((ctx: NavDestinationContext): void => {
      this.pathStack = ctx.pathStack;
    })
  }
}

@Builder
export function DuplicatesBuilder() {
  DuplicatesDest()
}

// 重复清理(#9 + 0.12.0/0.15.0 改造):身份状态两个列表 + 重复分组。
// - 待分析曲目:尚未完成 SHA-256 权威收敛的曲目(按路径聚合;后台收敛/「立即分析」驱动);
// - 已去重曲目:内容身份已确认(hash 唯一)的曲目;
// - 重复分组:优先内容指纹精确分组,启发式「疑似」兜底;每组默认保留最早入库的一首(0.15.0 #11)。
import { hilog } from '@kit.PerformanceAnalysisKit';
import { LibraryStore } from '../../data/LibraryStore';
import { Db } from '../../data/Db';
import { ScanService } from '../../data/ScanService';
import { Song, formatDuration, formatSize } from '../../data/Model';
import { L } from '../../common/Lang';

const TAG = '[Timbrava][Duplicates]';
const DOMAIN = 0x0001;

class DupGroup {
  label: string = '';
  exact: boolean = false; // true=内容指纹完全相同;false=启发式疑似
  songs: Song[] = [];
}

// 身份列表行:同 path 多行(CUE 分轨)聚合为一行,tracks 记行数
class PathRow {
  title: string = '';
  path: string = '';
  tracks: number = 1;
  size: number = 0;
  durationMs: number = 0;
}

function groupByPath(songs: Song[]): PathRow[] {
  const map: Map<string, PathRow> = new Map<string, PathRow>();
  for (const s of songs) {
    const r = map.get(s.path);
    if (r === undefined) {
      const row = new PathRow();
      row.title = s.displayTitle();
      row.path = s.path;
      row.size = s.fileSize;
      row.durationMs = s.durationMs;
      map.set(s.path, row);
    } else {
      r.tracks++;
    }
  }
  return Array.from(map.values()).sort((a: PathRow, b: PathRow): number =>
    a.title.localeCompare(b.title));
}

function normKey(s: string): string {
  return s.trim().toLowerCase().replace(/\s+/g, ' ');
}

@Component
export struct DuplicatesDest {
  @StorageProp('libVer') libVer: number = 0;
  @StorageProp('topSafeVp') topSafeVp: number = 36; // 全屏沉浸后手动避让状态栏
  @StorageProp('bottomSafeVp') bottomSafeVp: number = 28;
  @StorageProp('hashVer') @Watch('onHashProgress') hashVer: number = 0; // 收敛进度驱动计数/列表刷新
  @State dupTabIndex: number = 0;
  @State convergingMirror: boolean = false;
  @State groups: DupGroup[] = [];
  @State pendingRows: PathRow[] = [];
  @State doneRows: PathRow[] = [];
  private pathStack: NavPathStack | null = null;

  aboutToAppear(): void {
    this.convergingMirror = ScanService.get().isConverging();
    this.rebuild();
  }

  onHashProgress(): void {
    this.convergingMirror = ScanService.get().isConverging();
    this.rebuildIdentity();
  }

  private rebuild(): void {
    this.rebuildIdentity();
    this.rebuildGroups();
  }

  // 身份两列表:直接查库(LibraryStore 缓存不随收敛更新;hashVer 逐路径 bump 驱动重查)
  private rebuildIdentity(): void {
    Db.get().querySongs("hash = ''", [], 'title COLLATE NOCASE', 100000, 0).then((rows: Song[]): void => {
      this.pendingRows = groupByPath(rows);
      hilog.info(DOMAIN, TAG, 'pending rows=%{public}d (raw %{public}d)', this.pendingRows.length, rows.length);
    });
    Db.get().querySongs("hash != ''", [], 'title COLLATE NOCASE', 100000, 0).then((rows: Song[]): void => {
      this.doneRows = groupByPath(rows);
      hilog.info(DOMAIN, TAG, 'done rows=%{public}d (raw %{public}d)', this.doneRows.length, rows.length);
    });
  }

  private rebuildGroups(): void {
    const songs = LibraryStore.get().songs;
    const groups: DupGroup[] = [];
    const used: Set<number> = new Set<number>();
    // 第一优先:fp 快速指纹精确分组(键 = (fp, cueStartMs),CUE 分轨按轨对轨比较,防整组混轨;fp 秒级收敛全库覆盖)
    const byFp: Map<string, Song[]> = new Map();
    for (const s of songs) {
      if (s.fp.length === 0) {
        continue;
      }
      const k = `${s.fp}\u0001${s.cueStartMs}`;
      const arr = byFp.get(k);
      if (arr === undefined) {
        byFp.set(k, [s]);
      } else {
        arr.push(s);
      }
    }
    byFp.forEach((arr: Song[]): void => {
      if (arr.length <= 1) {
        return;
      }
      groups.push(this.makeGroup(arr, true));
      for (const s of arr) {
        used.add(s.id);
      }
    });
    // 兜底:启发式分组(fp 未回填的存量行)
    for (let i = 0; i < songs.length; i++) {
      if (used.has(songs[i].id)) {
        continue;
      }
      const a = songs[i];
      const group = new DupGroup();
      group.songs.push(a);
      used.add(a.id);
      for (let j = i + 1; j < songs.length; j++) {
        if (used.has(songs[j].id)) {
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
          used.add(b.id);
        }
      }
      if (group.songs.length > 1) {
        groups.push(this.makeGroup(group.songs, false));
      }
    }
    this.groups = groups;
    hilog.info(DOMAIN, TAG, 'dup groups=%{public}d', groups.length);
  }

  // 组内排序:保留最早入库的一首(#11:两曲一致默认去新的留旧的,避免无谓的重新收敛/关系迁移)
  private makeGroup(arr: Song[], exact: boolean): DupGroup {
    const g = new DupGroup();
    g.exact = exact;
    g.songs = arr.slice().sort((x: Song, y: Song): number => {
      if (x.dateAdded !== y.dateAdded) {
        return x.dateAdded - y.dateAdded;
      }
      return x.id - y.id;
    });
    g.label = `${g.songs[0].displayTitle()} — ${g.songs[0].displayArtist()}`;
    return g;
  }

  private async removeFromLibrary(songId: number): Promise<void> {
    await Db.get().removeSongCompletely(songId);
    await LibraryStore.get().reload();
    AppStorage.setOrCreate('libVer', (AppStorage.get<number>('libVer') ?? 0) + 1);
    this.rebuild();
    hilog.info(DOMAIN, TAG, 'removed from library song=%{public}d', songId);
  }

  @Builder
  IdentityList(kind: string) {
    Column() {
      Row({ space: 8 }) {
        Text(kind === 'pending' ? $r('app.string.dup_pending_sub') : $r('app.string.dup_done_sub'))
          .fontSize(11)
          .fontColor($r('app.color.text_secondary'))
          .layoutWeight(1)
        if (kind === 'pending' && this.pendingRows.length > 0) {
          Button(this.convergingMirror ? $r('app.string.dup_analyzing') : $r('app.string.dup_analyze_now'))
            .fontSize(11)
            .height(26)
            .fontColor(this.convergingMirror ? $r('app.color.text_secondary') : $r('app.color.on_accent'))
            .backgroundColor($r('app.color.badge_bg'))
            .enabled(!this.convergingMirror)
            .onClick(() => {
              ScanService.get().convergeIdentities();
            })
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8 })

      if (this.rowsOf(kind).length === 0) {
        Column({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.checkmark'))
            .fontSize(36)
            .fontColor([$r('app.color.accent')])
          Text($r('app.string.dup_none'))
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: 2 }) {
          ForEach(this.rowsOf(kind), (r: PathRow) => {
            ListItem() {
              Row({ space: 10 }) {
                Column({ space: 2 }) {
                  Text(r.title)
                    .fontSize(14)
                    .fontColor($r('app.color.text_primary'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(r.path)
                    .fontSize(10)
                    .fontColor($r('app.color.text_secondary'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                if (r.tracks > 1) {
                  Text(L($r('app.string.dup_tracks'), r.tracks))
                    .fontSize(10)
                    .fontColor($r('app.color.badge_text'))
                    .backgroundColor($r('app.color.badge_bg'))
                    .borderRadius(6)
                    .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                }
                Text(formatSize(r.size))
                  .fontSize(10)
                  .fontColor($r('app.color.text_secondary'))
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 8, bottom: 8 })
            }
          }, (r: PathRow): string => `idt_${r.path}`)
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Auto)
        .padding({ bottom: Math.max(this.bottomSafeVp, 28) })
      }
    }
    .width('100%')
    .height('100%')
  }

  private rowsOf(kind: string): PathRow[] {
    return kind === 'pending' ? this.pendingRows : this.doneRows;
  }

  private countOf(kind: string): number {
    if (kind === 'pending') {
      return this.pendingRows.length;
    }
    if (kind === 'done') {
      return this.doneRows.length;
    }
    return this.groups.length;
  }

  @Builder
  GroupsTab() {
    if (this.groups.length === 0) {
      Column({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.checkmark'))
          .fontSize(40)
          .fontColor([$r('app.color.accent')])
        Text($r('app.string.dup_none'))
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
        Text($r('app.string.dup_keep_hint'))
          .fontSize(11)
          .fontColor($r('app.color.text_secondary'))
      }
      .width('100%')
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
    } else {
      List({ space: 8 }) {
        ListItem() {
          Text($r('app.string.dup_keep_hint'))
            .fontSize(11)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .padding({ left: 4, top: 4 })
        }
        ForEach(this.groups, (g: DupGroup, gi: number) => {
          ListItem() {
            Column({ space: 4 }) {
              Row({ space: 8 }) {
                Text(L($r('app.string.dup_group'), g.label, g.songs.length))
                  .fontSize(13)
                  .fontWeight(FontWeight.Bold)
                  .fontColor($r('app.color.text_primary'))
                  .layoutWeight(1)
                Text(g.exact ? $r('app.string.dup_tag_exact') : $r('app.string.dup_tag_guess'))
                  .fontSize(10)
                  .fontColor(g.exact ? $r('app.color.accent') : $r('app.color.text_secondary'))
              }
              .width('100%')
              ForEach(g.songs, (s: Song, si: number) => {
                Row({ space: 8 }) {
                  Column({ space: 2 }) {
                    Text(si === 0 ? $r('app.string.str_keep') :
                      `${formatDuration(s.durationMs)} · ${formatSize(s.fileSize)}`)
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
        }, (g: DupGroup): string => `dupg_${g.exact}_${g.label}_${g.songs.length}_${this.libVer}`)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      .padding({ left: 16, right: 16, bottom: 40 })
    }
  }

  build() {
    NavDestination() {
      Column() {
        Tabs({ index: this.dupTabIndex, barPosition: BarPosition.Start }) {
          TabContent() {
            this.IdentityList('pending')
          }
          .tabBar(this.tabLabel($r('app.string.dup_tab_pending'), 'pending'))

          TabContent() {
            this.IdentityList('done')
          }
          .tabBar(this.tabLabel($r('app.string.dup_tab_done'), 'done'))

          TabContent() {
            this.GroupsTab()
          }
          .tabBar(this.tabLabel($r('app.string.dup_tab_groups'), 'groups'))
        }
        .barMode(BarMode.Fixed)
        .layoutWeight(1)
        .onChange((i: number): void => {
          this.dupTabIndex = i;
        })
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

  // 页签文案体内直读计数(@Builder 参数快照不刷新,KB §8.2)
  @Builder
  tabLabel(res: Resource, kind: string) {
    Text(`${L(res)}(${this.countOf(kind)})`)
      .fontSize(13)
      .fontColor($r('app.color.text_primary'))
      .padding({ top: 8, bottom: 8 })
  }
}

@Builder
export function DuplicatesBuilder() {
  DuplicatesDest()
}

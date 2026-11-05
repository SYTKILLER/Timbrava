// 统计回顾页(M6):最近播放(history 单条记录,可滑删)/最常播放(play_count)。
// 行内播放按钮 = 以当前列表为队列从该曲起播;ListItem 左滑露出 16vp 圆形红底白 symbol 删除钮(左右 8vp 留白)。
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Db, HistoryRow, MostRow } from '../../data/Db';
import { Song, formatDuration } from '../../data/Model';
import { PlayerController } from '../../service/PlayerController';
import { QueueService } from '../../service/QueueService';

const TAG = '[Timbrava][PlayHistory]';
const DOMAIN = 0x0001;
const PAGE_SIZE = 100;

// 路由参数:初始分段(0 最近播放/1 最常播放)
export class PlayHistoryParam {
  tab: number = 0;

  constructor(tab: number) {
    this.tab = tab;
  }
}

@Component
export struct PlayHistoryDest {
  @StorageProp('topSafeVp') topSafeVp: number = 36;
  @StorageProp('bottomSafeVp') bottomSafeVp: number = 28;
  @State tab: number = 0;
  @State recent: HistoryRow[] = [];
  @State most: MostRow[] = [];
  @State loading: boolean = true;
  private pathStack: NavPathStack | null = null;

  aboutToAppear(): void {
    this.reload();
  }

  private reload(): void {
    this.loading = true;
    Db.get().listRecentHistory(PAGE_SIZE).then((rows: HistoryRow[]): void => {
      this.recent = rows;
      this.loading = false;
    });
    Db.get().listMostPlayed(PAGE_SIZE).then((rows: MostRow[]): void => {
      this.most = rows;
    });
  }

  // 从该曲起播:以当前分段的列表为队列
  private playFrom(tab: number, songs: Song[], songId: number): void {
    if (songs.length === 0) {
      return;
    }
    let start = 0;
    for (let i = 0; i < songs.length; i++) {
      if (songs[i].id === songId) {
        start = i;
        break;
      }
    }
    QueueService.get().setQueueNow(songs, start, tab === 0 ? $r('app.string.history_recent').toString()
      : $r('app.string.history_most').toString());
    PlayerController.get().playQueueIndex(QueueService.get().locateCurrent());
    hilog.info(DOMAIN, TAG, 'play from history tab=%{public}d song=%{public}d', tab, songId);
  }

  private deleteRecent(row: HistoryRow): void {
    Db.get().deleteHistoryRow(row.id).then((): void => {
      this.recent = this.recent.filter((r: HistoryRow): boolean => r.id !== row.id);
      hilog.info(DOMAIN, TAG, 'history row deleted %{public}d', row.id);
    });
  }

  private deleteMost(row: MostRow): void {
    Db.get().deletePlayCountRow(row.song.id).then((): void => {
      this.most = this.most.filter((r: MostRow): boolean => r.song.id !== row.song.id);
      hilog.info(DOMAIN, TAG, 'play_count deleted song=%{public}d', row.song.id);
    });
  }

  private fmtTime(ts: number): string {
    if (ts <= 0) {
      return '';
    }
    const d = new Date(ts);
    const pad = (n: number): string => (n < 10 ? `0${n}` : `${n}`);
    return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
  }

  @Builder
  tabBtn(idx: number, label: ResourceStr) {
    Text(label)
      .fontSize(13)
      .fontWeight(this.tab === idx ? FontWeight.Bold : FontWeight.Normal)
      .fontColor(this.tab === idx ? $r('app.color.accent') : $r('app.color.text_secondary'))
      .padding({ left: 14, right: 14, top: 6, bottom: 6 })
      .borderRadius(14)
      .backgroundColor(this.tab === idx ? $r('app.color.badge_bg') : Color.Transparent)
      .onClick(() => {
        this.tab = idx;
      })
  }

  @Builder
  emptyHint(text: ResourceStr) {
    Column({ space: 8 }) {
      SymbolGlyph($r('sys.symbol.music_note_list'))
        .fontSize(36)
        .fontColor([$r('app.color.text_secondary')])
      Text(text)
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
    }
    .width('100%')
    .padding({ top: 80 })
    .justifyContent(FlexAlign.Center)
  }

  // 滑动删除按钮区:16vp 圆形红底白 symbol,左右各 8vp 留白(总宽 32vp)
  @Builder
  swipeDelete(onDelete: () => void) {
    Row() {
      Button({ type: ButtonType.Circle, stateEffect: true }) {
        SymbolGlyph($r('sys.symbol.trash'))
          .fontSize(10)
          .fontColor([Color.White])
      }
      .width(16)
      .height(16)
      .borderRadius(8)
      .backgroundColor($r('app.color.danger'))
      .padding(0)
      // V2(26 行为变更):视觉 16 保留,热区扩到 40vp ≥32vp 最小热区
      .responseRegion({ x: -12, y: -12, width: 40, height: 40 })
      .onClick(() => {
        onDelete();
      })
    }
    .padding({ left: 8, right: 8 })
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .align(Alignment.Center)
  }

  build() {
    NavDestination() {
      Column() {
        // 分段切换
        Row({ space: 4 }) {
          this.tabBtn(0, $r('app.string.history_recent'))
          this.tabBtn(1, $r('app.string.history_most'))
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: 8 })

        if (this.loading) {
          LoadingProgress()
            .width(32)
            .height(32)
            .margin({ top: 60 })
        } else if (this.tab === 0) {
          if (this.recent.length === 0) {
            this.emptyHint($r('app.string.history_empty'))
          } else {
            List({ space: 0 }) {
              ForEach(this.recent, (row: HistoryRow) => {
                ListItem() {
                  Row({ space: 12 }) {
                    Column() {
                      SymbolGlyph($r('sys.symbol.clock'))
                        .fontSize(20)
                        .fontColor([$r('app.color.text_secondary')])
                    }
                    .width(40)
                    .height(40)
                    .borderRadius(8)
                    .backgroundColor($r('app.color.badge_bg'))
                    .justifyContent(FlexAlign.Center)

                    Column({ space: 3 }) {
                      Text(row.song.displayTitle())
                        .fontSize(15)
                        .fontColor($r('app.color.text_primary'))
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                      Text(`${row.song.displayArtist()} · ${this.fmtTime(row.playedAt)}`)
                        .fontSize(11)
                        .fontColor($r('app.color.text_secondary'))
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                    }
                    .layoutWeight(1)
                    .alignItems(HorizontalAlign.Start)

                    Text(formatDuration(row.msPlayed))
                      .fontSize(11)
                      .fontColor($r('app.color.text_secondary'))

                    // 行内播放按钮:从该曲起播(以最近播放列表为队列)
                    Button({ type: ButtonType.Circle, stateEffect: true }) {
                      SymbolGlyph($r('sys.symbol.play_fill'))
                        .fontSize(16)
                        .fontColor([$r('app.color.accent')])
                    }
                    .width(34)
                    .height(34)
                    .backgroundColor($r('app.color.badge_bg'))
                    .onClick(() => {
                      this.playFrom(0, this.recent.map((r: HistoryRow): Song => r.song), row.song.id);
                    })
                  }
                  .width('100%')
                  .padding({ left: 16, right: 16, top: 8, bottom: 8 })
                }
                .swipeAction({ end: this.swipeDelete((): void => {
                  this.deleteRecent(row);
                }) })
              }, (row: HistoryRow): string => `h_${row.id}`)
            }
            .width('100%')
            .layoutWeight(1)
            .scrollBar(BarState.Auto)
            .divider({ strokeWidth: 0.5, color: $r('app.color.divider'), startMargin: 68, endMargin: 16 })
          }
        } else {
          if (this.most.length === 0) {
            this.emptyHint($r('app.string.history_empty'))
          } else {
            List({ space: 0 }) {
              ForEach(this.most, (row: MostRow, idx: number) => {
                ListItem() {
                  Row({ space: 12 }) {
                    Text(`${idx + 1}`)
                      .fontSize(14)
                      .fontWeight(FontWeight.Bold)
                      .fontColor(idx < 3 ? $r('app.color.accent') : $r('app.color.text_secondary'))
                      .width(28)
                      .textAlign(TextAlign.Center)

                    Column({ space: 3 }) {
                      Text(row.song.displayTitle())
                        .fontSize(15)
                        .fontColor($r('app.color.text_primary'))
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                      Text(`${row.song.displayArtist()} · ${row.song.displayAlbum()}`)
                        .fontSize(11)
                        .fontColor($r('app.color.text_secondary'))
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                    }
                    .layoutWeight(1)
                    .alignItems(HorizontalAlign.Start)

                    Text($r('app.string.history_plays', row.count))
                      .fontSize(11)
                      .fontColor($r('app.color.text_secondary'))

                    // 行内播放按钮:从该曲起播(以最常播放列表为队列)
                    Button({ type: ButtonType.Circle, stateEffect: true }) {
                      SymbolGlyph($r('sys.symbol.play_fill'))
                        .fontSize(16)
                        .fontColor([$r('app.color.accent')])
                    }
                    .width(34)
                    .height(34)
                    .backgroundColor($r('app.color.badge_bg'))
                    .onClick(() => {
                      this.playFrom(1, this.most.map((r: MostRow): Song => r.song), row.song.id);
                    })
                  }
                  .width('100%')
                  .padding({ left: 16, right: 16, top: 8, bottom: 8 })
                }
                .swipeAction({ end: this.swipeDelete((): void => {
                  this.deleteMost(row);
                }) })
              }, (row: MostRow): string => `m_${row.song.id}`)
            }
            .width('100%')
            .layoutWeight(1)
            .scrollBar(BarState.Auto)
            .divider({ strokeWidth: 0.5, color: $r('app.color.divider'), startMargin: 56, endMargin: 16 })
          }
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.page_bg'))
    }
    .padding({ top: this.topSafeVp })
    .title($r('app.string.history_title'))
    .onReady((ctx: NavDestinationContext): void => {
      this.pathStack = ctx.pathStack;
      const p = ctx.pathInfo.param as PlayHistoryParam;
      if (p !== null && p !== undefined && p instanceof PlayHistoryParam) {
        this.tab = p.tab === 1 ? 1 : 0;
      }
    })
  }
}

@Builder
export function PlayHistoryBuilder() {
  PlayHistoryDest()
}

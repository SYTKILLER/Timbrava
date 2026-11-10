// 统计回顾页(M6+0.19.0):最近播放(history 单条记录,可滑删)/最常播放(play_count)/图表(热图+每日曲线)。
// 行内播放按钮 = 以当前列表为队列从该曲起播;ListItem 左滑露出 16vp 圆形红底白 symbol 删除钮(左右 8vp 留白)。
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Db, HistoryRow, MostRow, DayAgg } from '../../data/Db';
import { Song, formatDuration } from '../../data/Model';
import { PlayerController } from '../../service/PlayerController';
import { QueueService } from '../../service/QueueService';
import { L } from '../../common/Lang';

const TAG = '[Timbrava][PlayHistory]';
const DOMAIN = 0x0001;
const PAGE_SIZE = 100;
const HEAT_DAYS = 84; // 热图窗口:12 周
const BAR_DAYS = 14;  // 每日曲线窗口

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
  @State agg: DayAgg[] = [];
  @State loading: boolean = true;
  private aggMap: Map<number, DayAgg> = new Map<number, DayAgg>();
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
    Db.get().listPlayAggByDay(HEAT_DAYS).then((rows: DayAgg[]): void => {
      this.aggMap = new Map<number, DayAgg>();
      for (const r of rows) {
        this.aggMap.set(r.day, r);
      }
      this.agg = rows; // 触发图表分支重估
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

  // ===== 图表分段(0.19.0) =====

  private todayIdx(): number {
    return Math.floor(Date.now() / 86400000);
  }

  private dayMs(day: number): number {
    const r = this.aggMap.get(day);
    return r !== undefined ? r.ms : 0;
  }

  // 近 84 天汇总
  private sumMs(): number {
    let s = 0;
    for (const r of this.agg) {
      s += r.ms;
    }
    return s;
  }

  private sumPlays(): number {
    let s = 0;
    for (const r of this.agg) {
      s += r.plays;
    }
    return s;
  }

  private activeDays(): number {
    let s = 0;
    for (const r of this.agg) {
      if (r.ms > 0) {
        s++;
      }
    }
    return s;
  }

  private fmtH(ms: number): string {
    const min = Math.round(ms / 60000);
    if (min >= 60) {
      const h = Math.floor(min / 60);
      const m = min % 60;
      return m > 0 ? L($r('app.string.stat_hours_f'), String(h), String(m))
        : L($r('app.string.stat_hours_exact'), String(h));
    }
    return L($r('app.string.stat_minutes_f'), String(min));
  }

  @Builder
  statCell(label: ResourceStr, value: string) {
    Column({ space: 3 }) {
      Text(value)
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
      Text(label)
        .fontSize(11)
        .fontColor($r('app.color.text_secondary'))
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  ChartsPage() {
    Scroll() {
      Column({ space: 12 }) {
        // 汇总行(近 12 周)
        Row() {
          this.statCell($r('app.string.chart_total'), this.fmtH(this.sumMs()))
          this.statCell($r('app.string.chart_plays'), String(this.sumPlays()))
          this.statCell($r('app.string.chart_active'), L($r('app.string.chart_days'), String(this.activeDays())))
        }
        .width('100%')
        .padding(14)
        .borderRadius(16)
        .backgroundColor($r('app.color.card_bg'))

        // 听歌热图:12 周 × 7 日,格深浅 = 当日播放时长
        Column({ space: 8 }) {
          Text($r('app.string.chart_heatmap'))
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .width('100%')
          Row({ space: 2 }) {
            ForEach(Array.from({ length: 12 }, (_v: undefined, wk: number) => wk), (wk: number) => {
              Column({ space: 2 }) {
                ForEach(Array.from({ length: 7 }, (_v: undefined, dy: number) => dy), (dy: number) => {
                  Column()
                    .width(13)
                    .height(13)
                    .borderRadius(3)
                    .backgroundColor(this.heatBg(wk, dy))
                    .opacity(this.heatOpacity(wk, dy))
                }, (dy: number): string => `hd_${wk}_${dy}`)
              }
            }, (wk: number): string => `hw_${wk}`)
          }
          .justifyContent(FlexAlign.Center)
          Row() {
            Text($r('app.string.chart_heat_light'))
              .fontSize(10)
              .fontColor($r('app.color.text_secondary'))
            Row({ space: 2 }) {
              ForEach([0.3, 0.55, 0.8, 1.0], (o: number) => {
                Column()
                  .width(10)
                  .height(10)
                  .borderRadius(2)
                  .backgroundColor($r('app.color.accent'))
                  .opacity(o)
              }, (o: number): string => `lg_${o}`)
            }
            .margin({ left: 8 })
            Text($r('app.string.chart_heat_heavy'))
              .fontSize(10)
              .fontColor($r('app.color.text_secondary'))
              .margin({ left: 4 })
          }
        }
        .width('100%')
        .padding(14)
        .borderRadius(16)
        .backgroundColor($r('app.color.card_bg'))
        .alignItems(HorizontalAlign.Start)

        // 近 14 天每日时长柱
        Column({ space: 8 }) {
          Text($r('app.string.chart_daily'))
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .width('100%')
          Row({ space: 3 }) {
            ForEach(Array.from({ length: BAR_DAYS }, (_v: undefined, i: number) => i), (i: number) => {
              Column() {
                Column()
                  .layoutWeight(1)
                  .width('100%')
                  .borderRadius({ topLeft: 3, topRight: 3 })
                  .backgroundColor($r('app.color.accent'))
                  .opacity(this.barOpacity(i))
              }
              .width('100%')
              .height(72)
              .justifyContent(FlexAlign.End)
            }, (i: number): string => `bd_${i}`)
          }
          .width('100%')
          .alignItems(VerticalAlign.Bottom)
          Row() {
            Text(this.barDayLabel(0))
              .fontSize(10)
              .fontColor($r('app.color.text_secondary'))
            Blank()
            Text(this.barDayLabel(BAR_DAYS - 1))
              .fontSize(10)
              .fontColor($r('app.color.text_secondary'))
          }
          .width('100%')
        }
        .width('100%')
        .padding(14)
        .borderRadius(16)
        .backgroundColor($r('app.color.card_bg'))
        .alignItems(HorizontalAlign.Start)

        Blank().height(Math.max(this.bottomSafeVp, 28) + 8)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 4 })
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Auto)
    .align(Alignment.Top)
  }

  // 热图格:idx = 距今天数(0=最旧,83=今天);无数据 badge_bg 全透明度
  private heatBg(wk: number, dy: number): ResourceColor {
    const idx = wk * 7 + dy;
    const day = this.todayIdx() - (HEAT_DAYS - 1) + idx;
    return this.dayMs(day) > 0 ? $r('app.color.accent') : $r('app.color.badge_bg');
  }

  private heatOpacity(wk: number, dy: number): number {
    const idx = wk * 7 + dy;
    const day = this.todayIdx() - (HEAT_DAYS - 1) + idx;
    const ms = this.dayMs(day);
    if (ms <= 0) {
      return 1;
    }
    let maxMs = 0;
    for (const r of this.agg) {
      if (r.ms > maxMs) {
        maxMs = r.ms;
      }
    }
    return 0.25 + 0.75 * Math.min(1, ms / Math.max(1, maxMs));
  }

  private barOpacity(i: number): number {
    const day = this.todayIdx() - (BAR_DAYS - 1) + i;
    const ms = this.dayMs(day);
    let maxMs = 0;
    for (const r of this.agg) {
      if (r.ms > maxMs) {
        maxMs = r.ms;
      }
    }
    if (ms <= 0 || maxMs <= 0) {
      return 0.12;
    }
    return Math.max(0.18, 0.25 + 0.75 * (ms / maxMs));
  }

  private barDayLabel(i: number): string {
    const day = this.todayIdx() - (BAR_DAYS - 1) + i;
    const d = new Date(day * 86400000);
    const pad = (n: number): string => (n < 10 ? `0${n}` : `${n}`);
    return `${d.getMonth() + 1}/${d.getDate()}`;
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
          .fontSize(14)
          .fontColor([Color.White])
      }
      .width(36)
      .height(36)
      .borderRadius(18)
      .backgroundColor($r('app.color.danger'))
      // 最小可点目标 40vp:视觉 36,热区外扩(0.17.0)
      .responseRegion({ x: -2, y: -2, width: 40, height: 40 })
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
          this.tabBtn(2, $r('app.string.chart_tab'))
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
                    .width(40)
                    .height(40)
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
            .contentEndOffset(Math.max(this.bottomSafeVp, 28)) // 底部手势条避让(0.16.0)
            .divider({ strokeWidth: 0.5, color: $r('app.color.divider'), startMargin: 68, endMargin: 16 })
          }
        } else if (this.tab === 1) {
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
                    .width(40)
                    .height(40)
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
            .contentEndOffset(Math.max(this.bottomSafeVp, 28)) // 底部手势条避让(0.16.0)
            .divider({ strokeWidth: 0.5, color: $r('app.color.divider'), startMargin: 56, endMargin: 16 })
          }
        } else {
          // 图表分段(0.19.0):热图 + 每日曲线 + 汇总
          this.ChartsPage()
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

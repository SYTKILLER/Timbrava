// 全局搜索:歌名/艺人/专辑模糊匹配(LIKE),防抖 300ms,结果即点即播。
// 0.14.0:搜索历史(最近 10 条,可单删/清空)+ 歌曲/专辑/艺人分类 chips(结果聚合点击跳详情)。
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Db } from '../../data/Db';
import { Song } from '../../data/Model';
import { SongRow, SongListParam } from '../../components/SongRow';
import { AlbumCover } from '../library/LibraryTab';
import { QueueService } from '../../service/QueueService';
import { PlayerController } from '../../service/PlayerController';
import { L } from '../../common/Lang';

const TAG = '[Timbrava][Search]';
const DOMAIN = 0x0001;

const HISTORY_KEY = 'searchHistory';
const HISTORY_MAX = 10;

// 派生聚合项(从命中的歌曲集合归组;按命中数排序)
class AlbumHit {
  key: string = '';      // albumArtist\u0001album(SongListParam.album 键)
  name: string = '';
  artist: string = '';
  artPath: string = '';
  count: number = 0;
}

class ArtistHit {
  name: string = '';
  count: number = 0;
}

@Component
export struct SearchDest {
  @StorageProp('topSafeVp') topSafeVp: number = 36; // 全屏沉浸后手动避让状态栏
  @State keyword: string = '';
  @State results: Song[] = [];
  @State albumHits: AlbumHit[] = [];
  @State artistHits: ArtistHit[] = [];
  @State searched: boolean = false;
  @State resultTab: number = 0; // 0 歌曲 1 专辑 2 艺人
  @State history: string[] = [];
  private pathStack: NavPathStack | null = null;
  private debounce: number = -1;
  private lastGen: number = 0;

  aboutToAppear(): void {
    this.loadHistory();
  }

  // ===== 搜索历史(app_settings JSON;0.14.0) =====

  private loadHistory(): void {
    Db.get().getSetting(HISTORY_KEY, '[]').then((v: string): void => {
      try {
        const arr: Array<string> = JSON.parse(v) as Array<string>;
        const out: string[] = [];
        for (const s of arr) {
          if (typeof s === 'string' && s.length > 0) {
            out.push(s);
          }
        }
        this.history = out;
      } catch (e) {
        this.history = [];
      }
    });
  }

  private persistHistory(): void {
    Db.get().setSetting(HISTORY_KEY, JSON.stringify(this.history));
  }

  private commitHistory(kw: string): void {
    const t = kw.trim();
    if (t.length === 0) {
      return;
    }
    const lower = t.toLowerCase();
    const rest: string[] = [];
    for (const h of this.history) {
      if (h.toLowerCase() !== lower) {
        rest.push(h);
      }
    }
    rest.unshift(t);
    if (rest.length > HISTORY_MAX) {
      rest.splice(HISTORY_MAX);
    }
    this.history = rest;
    this.persistHistory();
  }

  private removeHistory(index: number): void {
    this.history.splice(index, 1);
    this.history = this.history.slice(); // 触发刷新(下标删不触发)
    this.persistHistory();
  }

  private clearHistory(): void {
    this.history = [];
    this.persistHistory();
  }

  private tapHistory(kw: string): void {
    this.keyword = kw;
    this.doSearch(kw);
  }

  // ===== 搜索 =====

  private doSearch(kw: string): void {
    const gen = ++this.lastGen;
    const trimmed = kw.trim();
    if (trimmed.length === 0) {
      this.results = [];
      this.albumHits = [];
      this.artistHits = [];
      this.searched = false;
      return;
    }
    Db.get().querySongs(
      'title LIKE ? OR artist LIKE ? OR album LIKE ?',
      [`%${trimmed}%`, `%${trimmed}%`, `%${trimmed}%`],
      'title COLLATE NOCASE', 300, 0).then((songs: Song[]): void => {
      if (gen !== this.lastGen) {
        return; // 过期响应丢弃(代次)
      }
      this.results = songs.length > 100 ? songs.slice(0, 100) : songs;
      this.deriveAggregates(songs);
      this.resultTab = 0;
      this.searched = true;
      hilog.debug(DOMAIN, TAG, 'search %{public}s -> %{public}d songs / %{public}d albums / %{public}d artists',
        trimmed, songs.length, this.albumHits.length, this.artistHits.length);
    });
  }

  // 从命中歌曲归组专辑/艺人(按命中数降序)
  private deriveAggregates(songs: Song[]): void {
    const albumMap: Map<string, AlbumHit> = new Map<string, AlbumHit>();
    const artistMap: Map<string, ArtistHit> = new Map<string, ArtistHit>();
    for (const s of songs) {
      const ak = `${s.albumArtist}\u0001${s.displayAlbum()}`;
      const a = albumMap.get(ak);
      if (a !== undefined) {
        a.count++;
      } else {
        const hit = new AlbumHit();
        hit.key = ak;
        hit.name = s.displayAlbum();
        hit.artist = s.displayArtist();
        hit.artPath = s.artPath;
        hit.count = 1;
        albumMap.set(ak, hit);
      }
      const rk = s.displayArtist();
      const r = artistMap.get(rk);
      if (r !== undefined) {
        r.count++;
      } else {
        const hit = new ArtistHit();
        hit.name = rk;
        hit.count = 1;
        artistMap.set(rk, hit);
      }
    }
    const albums: AlbumHit[] = [];
    albumMap.forEach((v: AlbumHit): void => {
      albums.push(v);
    });
    albums.sort((x: AlbumHit, y: AlbumHit): number => y.count - x.count);
    this.albumHits = albums;
    const artists: ArtistHit[] = [];
    artistMap.forEach((v: ArtistHit): void => {
      artists.push(v);
    });
    artists.sort((x: ArtistHit, y: ArtistHit): number => y.count - x.count);
    this.artistHits = artists;
  }

  private onInputChanged(v: string): void {
    this.keyword = v;
    if (this.debounce >= 0) {
      clearTimeout(this.debounce);
    }
    this.debounce = setTimeout((): void => {
      this.debounce = -1;
      this.doSearch(this.keyword);
    }, 300) as number;
  }

  private playFrom(index: number): void {
    const q = QueueService.get();
    q.setQueueNow(this.results, index, L($r('app.string.search_title'), this.keyword));
    PlayerController.get().playQueueIndex(q.locateCurrent());
    this.commitHistory(this.keyword);
  }

  private openAlbum(hit: AlbumHit): void {
    const parts = hit.key.split('\u0001');
    const stack = this.pathStack;
    if (stack !== null) {
      stack.pushPathByName('SongList', SongListParam.album(parts[0], parts.length > 1 ? parts[1] : hit.name));
    }
  }

  private openArtist(hit: ArtistHit): void {
    const stack = this.pathStack;
    if (stack !== null) {
      stack.pushPathByName('SongList', SongListParam.artist(hit.name));
    }
  }

  @Builder
  HistorySection() {
    Column() {
      Row() {
        Text($r('app.string.search_history'))
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_secondary'))
          .layoutWeight(1)
        Text($r('app.string.search_clear'))
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .onClick(() => {
            this.clearHistory();
          })
      }
      .width('100%')
      .padding({ left: 16, right: 8, top: 4 })

      List({ space: 0 }) {
        ForEach(this.history, (h: string, i: number) => {
          ListItem() {
            Row({ space: 10 }) {
              SymbolGlyph($r('sys.symbol.clock'))
                .fontSize(14)
                .fontColor([$r('app.color.text_secondary')])
              Text(h)
                .fontSize(14)
                .fontColor($r('app.color.text_primary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
              Button({ stateEffect: true }) {
                SymbolGlyph($r('sys.symbol.xmark'))
                  .fontSize(12)
                  .fontColor([$r('app.color.text_secondary')])
              }
              .width(28)
              .height(28)
              .backgroundColor(Color.Transparent)
              // 最小可点目标 40vp:视觉 28,热区外扩(0.17.0)
              .responseRegion({ x: -6, y: -6, width: 40, height: 40 })
              .onClick(() => {
                this.removeHistory(i);
              })
            }
            .width('100%')
            .padding({ left: 16, right: 8, top: 9, bottom: 9 })
            .onClick(() => {
              this.tapHistory(h);
            })
          }
        }, (h: string): string => `his_${h}`)
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
  }

  // 分类 chips:歌曲/专辑/艺人命中数,切换结果页
  @Builder
  ResultTabs() {
    Row({ space: 8 }) {
      Button(L($r('app.string.chip_songs'), String(this.results.length)))
        .fontSize(12)
        .fontColor(this.resultTab === 0 ? $r('app.color.on_accent') : $r('app.color.text_primary'))
        .backgroundColor(this.resultTab === 0 ? $r('app.color.accent') : $r('app.color.badge_bg'))
        .borderRadius(14)
        .height(36)
        .responseRegion({ x: 0, y: -2, width: '100%', height: 40 }) // 最小可点目标 40vp(0.17.0)
        .onClick(() => {
          this.resultTab = 0;
        })
      Button(L($r('app.string.chip_albums'), String(this.albumHits.length)))
        .fontSize(12)
        .fontColor(this.resultTab === 1 ? $r('app.color.on_accent') : $r('app.color.text_primary'))
        .backgroundColor(this.resultTab === 1 ? $r('app.color.accent') : $r('app.color.badge_bg'))
        .borderRadius(14)
        .height(36)
        .responseRegion({ x: 0, y: -2, width: '100%', height: 40 }) // 最小可点目标 40vp(0.17.0)
        .onClick(() => {
          this.resultTab = 1;
        })
      Button(L($r('app.string.chip_artists'), String(this.artistHits.length)))
        .fontSize(12)
        .fontColor(this.resultTab === 2 ? $r('app.color.on_accent') : $r('app.color.text_primary'))
        .backgroundColor(this.resultTab === 2 ? $r('app.color.accent') : $r('app.color.badge_bg'))
        .borderRadius(14)
        .height(36)
        .responseRegion({ x: 0, y: -2, width: '100%', height: 40 }) // 最小可点目标 40vp(0.17.0)
        .onClick(() => {
          this.resultTab = 2;
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 10, bottom: 6 })
  }

  build() {
    NavDestination() {
      Column() {
        TextInput({ text: this.keyword, placeholder: $r('app.string.search_hint') })
          .type(InputType.Normal)
          .enterKeyType(EnterKeyType.Search)
          .height(44)
          .borderRadius(12)
          .backgroundColor($r('app.color.card_bg'))
          .fontSize(15)
          .margin({ left: 16, right: 16, top: 8 })
          .onChange((v: string): void => {
            this.onInputChanged(v);
          })
          .onSubmit((_enterKey: EnterKeyType, _event: SubmitEvent): void => {
            this.commitHistory(this.keyword);
            this.doSearch(this.keyword);
          })

        if (this.keyword.trim().length === 0) {
          if (this.history.length > 0) {
            this.HistorySection()
          } else {
            Column({ space: 8 }) {
              SymbolGlyph($r('sys.symbol.magnifyingglass'))
                .fontSize(40)
                .fontColor([$r('app.color.text_secondary')])
              Text($r('app.string.search_empty_hint'))
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'))
            }
            .width('100%')
            .padding({ top: 80 })
          }
        } else if (!this.searched || this.results.length === 0) {
          Column({ space: 8 }) {
            SymbolGlyph($r('sys.symbol.magnifyingglass'))
              .fontSize(40)
              .fontColor([$r('app.color.text_secondary')])
            Text(this.searched ? $r('app.string.search_no_match') : $r('app.string.search_empty_hint'))
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
          }
          .width('100%')
          .padding({ top: 80 })
        } else {
          this.ResultTabs()
          if (this.resultTab === 0) {
            List({ space: 0 }) {
              ForEach(this.results, (s: Song, i: number) => {
                ListItem() {
                  Column() {
                    SongRow({ song: s, showAlbum: true,
                      listIds: this.results.map((x: Song): number => x.id), listTitle: L($r('app.string.search_title'), this.keyword) })
                  }
                }
              }, (s: Song): string => `${s.id}_${s.title}`)
            }
            .width('100%')
            .layoutWeight(1)
            .scrollBar(BarState.Auto)
            .padding({ bottom: 40 })
          } else if (this.resultTab === 1) {
            List({ space: 0 }) {
              ForEach(this.albumHits, (a: AlbumHit) => {
                ListItem() {
                  Row({ space: 12 }) {
                    AlbumCover(a.artPath, 44)
                    Column({ space: 2 }) {
                      Text(a.name)
                        .fontSize(14)
                        .fontColor($r('app.color.text_primary'))
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                      Text(a.artist)
                        .fontSize(11)
                        .fontColor($r('app.color.text_secondary'))
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                    }
                    .alignItems(HorizontalAlign.Start)
                    .layoutWeight(1)
                    Text(L($r('app.string.count_songs'), a.count))
                      .fontSize(11)
                      .fontColor($r('app.color.text_secondary'))
                    SymbolGlyph($r('sys.symbol.chevron_right'))
                      .fontSize(14)
                      .fontColor([$r('app.color.text_secondary')])
                  }
                  .width('100%')
                  .padding({ left: 16, right: 16, top: 8, bottom: 8 })
                  .onClick(() => {
                    this.openAlbum(a);
                  })
                }
              }, (a: AlbumHit): string => `sa_${a.key}`)
            }
            .width('100%')
            .layoutWeight(1)
            .scrollBar(BarState.Auto)
            .padding({ bottom: 40 })
          } else {
            List({ space: 0 }) {
              ForEach(this.artistHits, (r: ArtistHit) => {
                ListItem() {
                  Row({ space: 12 }) {
                    Column() {
                      SymbolGlyph($r('sys.symbol.person'))
                        .fontSize(18)
                        .fontColor([$r('app.color.accent')])
                    }
                    .width(44)
                    .height(44)
                    .borderRadius(22)
                    .backgroundColor($r('app.color.badge_bg'))
                    .justifyContent(FlexAlign.Center)
                    Text(r.name)
                      .fontSize(14)
                      .fontColor($r('app.color.text_primary'))
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .layoutWeight(1)
                    Text(L($r('app.string.count_songs'), r.count))
                      .fontSize(11)
                      .fontColor($r('app.color.text_secondary'))
                    SymbolGlyph($r('sys.symbol.chevron_right'))
                      .fontSize(14)
                      .fontColor([$r('app.color.text_secondary')])
                  }
                  .width('100%')
                  .padding({ left: 16, right: 16, top: 8, bottom: 8 })
                  .onClick(() => {
                    this.openArtist(r);
                  })
                }
              }, (r: ArtistHit): string => `sr_${r.name}`)
            }
            .width('100%')
            .layoutWeight(1)
            .scrollBar(BarState.Auto)
            .padding({ bottom: 40 })
          }
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.page_bg'))
    }
    .padding({ top: this.topSafeVp })
    .title($r('app.string.str_search'))
    .onReady((ctx: NavDestinationContext): void => {
      this.pathStack = ctx.pathStack;
    })
    .onDisAppear((): void => {
      if (this.debounce >= 0) {
        clearTimeout(this.debounce);
        this.debounce = -1;
      }
    })
  }
}

@Builder
export function SearchBuilder() {
  SearchDest()
}

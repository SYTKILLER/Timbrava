// 全局搜索:歌名/艺人/专辑模糊匹配(LIKE),防抖 300ms,结果即点即播。
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Db } from '../../data/Db';
import { Song } from '../../data/Model';
import { SongRow } from '../../components/SongRow';
import { QueueService } from '../../service/QueueService';
import { PlayerController } from '../../service/PlayerController';
import { L } from '../../common/Lang';

const TAG = '[Timbrava][Search]';
const DOMAIN = 0x0001;

@Component
export struct SearchDest {
  @StorageProp('topSafeVp') topSafeVp: number = 36; // 全屏沉浸后手动避让状态栏
  @State keyword: string = '';
  @State results: Song[] = [];
  @State searched: boolean = false;
  private pathStack: NavPathStack | null = null;
  private debounce: number = -1;
  private lastGen: number = 0;

  private doSearch(kw: string): void {
    const gen = ++this.lastGen;
    const trimmed = kw.trim();
    if (trimmed.length === 0) {
      this.results = [];
      this.searched = false;
      return;
    }
    Db.get().querySongs(
      'title LIKE ? OR artist LIKE ? OR album LIKE ?',
      [`%${trimmed}%`, `%${trimmed}%`, `%${trimmed}%`],
      'title COLLATE NOCASE', 100, 0).then((songs: Song[]): void => {
      if (gen !== this.lastGen) {
        return; // 过期响应丢弃(代次)
      }
      this.results = songs;
      this.searched = true;
      hilog.debug(DOMAIN, TAG, 'search %{public}s -> %{public}d', trimmed, songs.length);
    });
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
  }

  build() {
    NavDestination() {
      Column() {
        TextInput({ text: this.keyword, placeholder: $r('app.string.search_hint') })
          .type(InputType.Normal)
          .height(44)
          .borderRadius(12)
          .backgroundColor($r('app.color.card_bg'))
          .fontSize(15)
          .margin({ left: 16, right: 16, top: 8 })
          .onChange((v: string): void => {
            this.onInputChanged(v);
          })

        if (this.results.length === 0) {
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
          List({ space: 0 }) {
            ForEach(this.results, (s: Song, i: number) => {
              ListItem() {
                Column() {
                  SongRow({ song: s, showAlbum: true })
                }
              }
            }, (s: Song): string => `${s.id}_${s.title}`)
          }
          .width('100%')
          .layoutWeight(1)
          .scrollBar(BarState.Auto)
          .padding({ bottom: 40 })
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

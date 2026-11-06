// 通用歌曲列表页(专辑/艺人/流派/文件夹/收藏):NavDestination + 头部卡(封面/统计+播放全部/随机,0.14.0)。
import { hilog } from '@kit.PerformanceAnalysisKit';
import { LibraryStore } from '../../data/LibraryStore';
import { Song, Artist, Genre } from '../../data/Model';
import { SongRow, SongListParam } from '../../components/SongRow';
import { AlbumCover } from '../library/LibraryTab';
import { RgScanner } from '../../service/RgScanner';
import { TagEditorParam } from './TagEditor';
import { QueueService } from '../../service/QueueService';
import { PlaylistRepo } from '../../data/PlaylistRepo';
import { PlayerController } from '../../service/PlayerController';
import { EqScopeParam } from '../settings/Equalizer';
import { L, Ls } from '../../common/Lang';

const TAG = '[Timbrava][SongList]';
const DOMAIN = 0x0001;

@Component
export struct SongListDest {
  @StorageProp('libVer') @Watch('onLibChanged') libVer: number = 0;
  @StorageProp('topSafeVp') topSafeVp: number = 36; // 全屏沉浸后手动避让状态栏
  @StorageProp('bottomSafeVp') bottomSafeVp: number = 28;
  @State songs: Song[] = [];
  @State title: ResourceStr = '';
  @State param: SongListParam = new SongListParam();
  // 添加歌曲半模态(歌单模式;0.17.0):可选范围 = 已入库全部歌曲
  @State showAddSheet: boolean = false;
  @State addSearch: string = '';
  @State memberIds: number[] = []; // 歌单现有曲目 id(勾选态)
  private addChain: Promise<void> = Promise.resolve(); // 串行化追加:并发 max(position) 会撞 UNIQUE 冲突
  private pathStack: NavPathStack | null = null;

  private async resolveSongs(p: SongListParam): Promise<Song[]> {
    const lib = LibraryStore.get();
    if (p.mode === 'album') {
      return lib.songs.filter((s: Song): boolean =>
        `${s.albumArtist}\u0001${s.displayAlbum()}` === `${p.key}\u0001${p.subKey}`)
        .sort((a: Song, b: Song): number => (a.discNo - b.discNo) || (a.trackNo - b.trackNo));
    }
    if (p.mode === 'artist') {
      const artist = lib.artists.find((a: Artist): boolean => a.key === p.key);
      const ids: number[] = artist !== undefined ? artist.songIds : [];
      const mapped: (Song | null)[] = ids.map((id: number): Song | null => lib.song(id));
      return mapped.filter((s: Song | null): boolean => s !== null) as Song[];
    }
    if (p.mode === 'genre') {
      const g = lib.genres.find((x: Genre): boolean => x.name === p.key);
      const ids: number[] = g !== undefined ? g.songIds : [];
      const mapped: (Song | null)[] = ids.map((id: number): Song | null => lib.song(id));
      return mapped.filter((s: Song | null): boolean => s !== null) as Song[];
    }
    if (p.mode === 'folder') {
      return lib.songs.filter((s: Song): boolean => s.path.startsWith(p.key + '/'));
    }
    if (p.mode === 'playlist') {
      const id = parseInt(p.key, 10);
      return PlaylistRepo.get().getPlaylistSongs(Number.isNaN(id) ? 0 : id);
    }
    if (p.mode === 'smart') {
      return PlaylistRepo.get().getSmartSongs(p.key);
    }
    if (p.mode === 'favorites') {
      const out: Song[] = [];
      for (const s of lib.songs) {
        if (lib.isFavorite(s.id)) {
          out.push(s);
        }
      }
      return out;
    }
    return lib.songs.slice().sort((a: Song, b: Song): number => a.displayTitle().localeCompare(b.displayTitle()));
  }

  onLibChanged(): void {
    if (this.param.mode.length > 0) {
      this.reload();
    }
  }

  private reload(): void {
    this.resolveSongs(this.param).then((songs: Song[]): void => {
      this.songs = songs;
      if (this.param.mode === 'playlist') {
        this.memberIds = songs.map((s: Song): number => s.id);
      }
      hilog.debug(DOMAIN, TAG, 'reload %{public}s -> %{public}d songs', this.param.mode, songs.length);
    });
    hilog.debug(DOMAIN, TAG, 'reload %{public}s -> %{public}d songs', this.param.mode, this.songs.length);
  }

  // ===== 添加歌曲半模态(歌单模式;0.17.0) =====

  private openAddSheet(): void {
    this.memberIds = this.songs.map((s: Song): number => s.id);
    this.addSearch = '';
    this.showAddSheet = true;
  }

  // 候选 = 已入库全部歌曲(搜索过滤;上限 200 防全量长列表)
  private addCandidates(): Song[] {
    const kw = this.addSearch.trim().toLowerCase();
    let all = LibraryStore.get().songs;
    if (kw.length > 0) {
      all = all.filter((s: Song): boolean =>
        s.displayTitle().toLowerCase().indexOf(kw) >= 0 ||
        s.displayArtist().toLowerCase().indexOf(kw) >= 0 ||
        s.displayAlbum().toLowerCase().indexOf(kw) >= 0);
    }
    return all.slice(0, 200);
  }

  private addSongToPlaylist(s: Song): void {
    if (this.memberIds.indexOf(s.id) >= 0) {
      return;
    }
    const plId = parseInt(this.param.key, 10);
    if (Number.isNaN(plId)) {
      return;
    }
    // 串行追加:每次 addSongs 独立取 max(position),并发会写入同位互相顶掉
    this.memberIds = this.memberIds.concat([s.id]); // 即时反馈;libVer 广播随后 reload 对账
    this.addChain = this.addChain.then((): Promise<void> => PlaylistRepo.get().addSongs(plId, [s.id]));
  }

  private saveAsPlaylist(): void {
    if (this.songs.length === 0) {
      return;
    }
    const t = Ls(this.title);
    const base = t.length > 0 ? t : L($r('app.string.str_playlists'));
    const name = `${base} · ${new Date().getMonth() + 1}/${new Date().getDate()}`;
    const ids: number[] = this.songs.map((s: Song): number => s.id);
    PlaylistRepo.get().createPlaylist(name).then((id: number): void => {
      if (id > 0) {
        PlaylistRepo.get().addSongs(id, ids).then((): void => {
          this.getUIContext().getPromptAction().showToast({ message: L($r('app.string.pl_saved'), name) });
        });
      } else {
        this.getUIContext().getPromptAction().showToast({ message: $r('app.string.pl_dup_fail') });
      }
    });
  }

  private playAll(shuffle: boolean): void {
    if (this.songs.length === 0) {
      return;
    }
    const q = QueueService.get();
    q.setQueueNow(this.songs, 0, Ls(this.title));
    if (shuffle) {
      q.toggleShuffle();
    }
    PlayerController.get().playQueueIndex(q.locateCurrent());
  }

  // ===== 0.14.0 头部卡数据 =====

  private headerArt(): string {
    for (const s of this.songs) {
      if (s.artPath.length > 0) {
        return s.artPath;
      }
    }
    return '';
  }

  private headerYear(): number {
    let y = 0;
    for (const s of this.songs) {
      if (s.year > y) {
        y = s.year;
      }
    }
    return y;
  }

  private headerArtist(): Artist | undefined {
    return LibraryStore.get().artists.find((a: Artist): boolean => a.key === this.param.key);
  }

  private totalMs(): number {
    let sum = 0;
    for (const s of this.songs) {
      sum += s.durationMs;
    }
    return sum;
  }

  private fmtTotal(ms: number): string {
    const min = Math.round(ms / 60000);
    if (min >= 60) {
      const h = Math.floor(min / 60);
      const m = min % 60;
      return m > 0 ? L($r('app.string.stat_hours_f'), String(h), String(m))
        : L($r('app.string.stat_hours_exact'), String(h));
    }
    return L($r('app.string.stat_minutes_f'), String(min));
  }

  private headerLine1(): string {
    if (this.param.mode === 'album') {
      const y = this.headerYear();
      return y > 0 ? `${this.param.key} · ${y}` : this.param.key;
    }
    if (this.param.mode === 'artist') {
      const a = this.headerArtist();
      return a !== undefined ? L($r('app.string.artist_stats'), a.albumCount, a.songCount) : '';
    }
    return '';
  }

  private headerLine2(): string {
    // 曲目数已在 line1(艺人模式)/标题栏语境体现,此行只给总时长,避免重复
    return L($r('app.string.total_duration'), this.fmtTotal(this.totalMs()));
  }

  @Builder
  ListHeader() {
    Column({ space: 10 }) {
      Row({ space: 12 }) {
        if (this.param.mode === 'album') {
          AlbumCover(this.headerArt(), 68)
        } else {
          Column() {
            SymbolGlyph($r('sys.symbol.music_note_list'))
              .fontSize(26)
              .fontColor([$r('app.color.accent')])
          }
          .width(68)
          .height(68)
          .borderRadius(12)
          .backgroundColor($r('app.color.badge_bg'))
          .justifyContent(FlexAlign.Center)
        }
        Column({ space: 4 }) {
          if (this.headerLine1().length > 0) {
            Text(this.headerLine1())
              .fontSize(13)
              .fontColor($r('app.color.text_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          Text(this.headerLine2())
            .fontSize(11)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')

      Row({ space: 10 }) {
        Button(L($r('app.string.play_all_n'), this.songs.length))
          .fontSize(13)
          .fontColor($r('app.color.on_accent'))
          .backgroundColor($r('app.color.accent'))
          .height(40)
          .borderRadius(20)
          .layoutWeight(1)
          .onClick(() => {
            this.playAll(false);
          })
        Button($r('app.string.shuffle_play'))
          .fontSize(13)
          .fontColor($r('app.color.text_primary'))
          .backgroundColor($r('app.color.badge_bg'))
          .height(40)
          .borderRadius(20)
          .layoutWeight(1)
          .onClick(() => {
            this.playAll(true);
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 6 })
  }

  @Builder
  listMenu() {
    Menu() {
      if (this.param.mode === 'album') {
        // EQ 按专辑:整专辑曲线覆盖(target 与 LibraryStore 分组键一致)
        MenuItem({ content: $r('app.string.eq_scope_current_album') })
          .onClick(() => {
            const stack = AppStorage.get<NavPathStack>('navStack');
            if (stack !== undefined && stack !== null) {
              stack.pushPathByName('Equalizer',
                new EqScopeParam(`album:${this.param.key}\u0001${this.param.subKey}`,
                  this.param.subKey));
            }
          })
      }
      MenuItem({ content: $r('app.string.menu_rg_scan') })
        .onClick(() => {
          RgScanner.get().scan(this.songs);
        })
      MenuItem({ content: $r('app.string.menu_batch_tags') })
        .onClick(() => {
          const stack = AppStorage.get<NavPathStack>('navStack');
          if (stack !== undefined && stack !== null) {
            const p = new TagEditorParam();
            p.batch = true;
            p.songIds = this.songs.map((s: Song): number => s.id);
            stack.pushPathByName('TagEditor', p);
          }
        })
    }
  }

  // 添加歌曲半模态内容:搜索 + 全库曲目逐曲加入(已入列表勾选态)
  @Builder
  AddSongsSheet() {
    Column() {
      Row({ space: 8 }) {
        Button({ stateEffect: true }) {
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(18)
            .fontColor([$r('app.color.text_primary')])
        }
        .width(48)
        .height(48)
        .borderRadius(24)
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          this.showAddSheet = false;
        })
        Text($r('app.string.add_songs'))
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: 8, right: 16, top: 8 })

      TextInput({ text: this.addSearch, placeholder: $r('app.string.search_hint') })
        .height(40)
        .fontSize(14)
        .borderRadius(10)
        .backgroundColor($r('app.color.badge_bg'))
        .fontColor($r('app.color.text_primary'))
        .placeholderColor($r('app.color.text_secondary'))
        .margin({ left: 16, right: 16, top: 4, bottom: 4 })
        .maxLines(1)
        .onChange((v: string): void => {
          this.addSearch = v;
        })

      List({ space: 0 }) {
        ForEach(this.addCandidates(), (s: Song) => {
          ListItem() {
            Row({ space: 12 }) {
              Column({ space: 2 }) {
                Text(s.displayTitle())
                  .fontSize(14)
                  .fontColor($r('app.color.text_primary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(s.displayArtist())
                  .fontSize(11)
                  .fontColor($r('app.color.text_secondary'))
                  .maxLines(1)
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              SymbolGlyph(this.memberIds.indexOf(s.id) >= 0
                ? $r('sys.symbol.checkmark_circle_fill') : $r('sys.symbol.plus_circle'))
                .fontSize(22)
                .fontColor([this.memberIds.indexOf(s.id) >= 0 ? $r('app.color.accent') : $r('app.color.text_secondary')])
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 9, bottom: 9 })
            .onClick(() => {
              this.addSongToPlaylist(s);
            })
          }
        }, (s: Song): string => `ac_${s.id}_${this.memberIds.indexOf(s.id) >= 0 ? 1 : 0}`)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Auto)

      Blank().height(Math.max(this.bottomSafeVp, 28) + 8)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.card_bg'))
  }

  build() {
    NavDestination() {
      Column() {
        Row({ space: 8 }) {
          Text(this.title)
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Button({ stateEffect: true }) {
            SymbolGlyph($r('sys.symbol.waveform'))
              .fontSize(18)
              .fontColor([$r('app.color.text_primary')])
          }
          .width(40)
          .height(40)
          .backgroundColor(Color.Transparent)
          .bindMenu(this.listMenu)

          if (this.param.mode === 'playlist') {
            // 歌单模式:此处是"添加歌曲"入口(存为歌单仅面向专辑/艺人等聚合列表,两类页面语义不互通)
            Button($r('app.string.add_songs'))
              .fontSize(13)
              .fontColor($r('app.color.on_accent'))
              .backgroundColor($r('app.color.accent'))
              .height(40)
              .borderRadius(20)
              .onClick(() => {
                this.openAddSheet();
              })
          } else {
            Button($r('app.string.save_as_pl'))
              .fontSize(13)
              .fontColor($r('app.color.text_primary'))
              .backgroundColor($r('app.color.badge_bg'))
              .height(40)
              .borderRadius(20)
              .onClick(() => {
                this.saveAsPlaylist();
              })
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 8 })

        if (this.songs.length === 0) {
          Column({ space: 8 }) {
            SymbolGlyph($r('sys.symbol.music_note_list'))
              .fontSize(42)
              .fontColor([$r('app.color.text_secondary')])
            Text($r('app.string.list_empty'))
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
          }
          .width('100%')
          .padding({ top: 80 })
        } else {
          // 头部卡(0.14.0):封面/图标 + 统计 + 播放全部/随机双钮
          this.ListHeader()
          List({ space: 0 }) {
            ForEach(this.songs, (s: Song) => {
              ListItem() {
                SongRow({ song: s, showAlbum: this.param.mode !== 'album',
                  listIds: this.songs.map((x: Song): number => x.id), listTitle: Ls(this.title) })
              }
            }, (s: Song): string => `${s.id}_${this.param.mode}`)
          }
          .width('100%')
          .layoutWeight(1)
          .scrollBar(BarState.Auto)
          .padding({ bottom: 60 })
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.page_bg'))
      // 添加歌曲半模态(歌单模式):两档高度,默认中档
      .bindSheet(this.showAddSheet, this.AddSongsSheet(), {
        detents: [SheetSize.MEDIUM, SheetSize.LARGE],
        dragBar: false,
        showClose: false,
        onDisappear: (): void => {
          this.showAddSheet = false;
        }
      })
    }
    .padding({ top: this.topSafeVp })
    .title(this.title)
    .onReady((ctx: NavDestinationContext): void => {
      this.pathStack = ctx.pathStack;
      const p: Object | undefined = ctx.pathInfo.param as Object | undefined;
      if (p !== null && p !== undefined && p instanceof SongListParam) {
        this.param = p as SongListParam;
        this.title = (p as SongListParam).title;
        this.reload();
      }
    })
    .onShown((): void => {
      // 收藏列表返回后可能变化
      if (this.param.mode === 'favorites') {
        this.reload();
      }
    })
  }
}


@Builder
export function SongListBuilder() {
  SongListDest()
}

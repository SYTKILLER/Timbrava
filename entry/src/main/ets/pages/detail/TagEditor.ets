// 标签编辑页(#40 单曲 / #41 批量):FLAC VorbisComment 原子写回。
// 单曲模式:param = songId(number);批量模式:param = TagEditorParam(batch + songIds,统一字段)。
import { hilog } from '@kit.PerformanceAnalysisKit';
import { LibraryStore } from '../../data/LibraryStore';
import { Db } from '../../data/Db';
import { Song } from '../../data/Model';
import { TagWriter, TagFields } from '../../service/TagWriter';

const TAG = '[Timbrava][TagEditor]';
const DOMAIN = 0x0001;

export class TagEditorParam {
  batch: boolean = false;
  songIds: number[] = [];
  title: string = '批量修改标签';
}

@Component
export struct TagEditorDest {
  @State songId: number = -1;
  @State batch: boolean = false;
  @State batchIds: number[] = [];
  @State fTitle: string = '';
  @State fArtist: string = '';
  @State fAlbum: string = '';
  @State fAlbumArtist: string = '';
  @State fGenre: string = '';
  @State fYear: string = '';
  @State fTrackNo: string = '';
  @State fDiscNo: string = '';
  @State busy: boolean = false;
  @State progressText: string = '';
  private pathStack: NavPathStack | null = null;

  private song(): Song | null {
    return this.songId >= 0 ? LibraryStore.get().song(this.songId) : null;
  }

  private loadSong(id: number): void {
    const s = LibraryStore.get().song(id);
    if (s === null) {
      return;
    }
    this.fTitle = s.title;
    this.fArtist = s.artist;
    this.fAlbum = s.album;
    this.fAlbumArtist = s.albumArtist;
    this.fGenre = s.genre;
    this.fYear = s.year > 0 ? String(s.year) : '';
    this.fTrackNo = s.trackNo > 0 ? String(s.trackNo) : '';
    this.fDiscNo = s.discNo > 0 ? String(s.discNo) : '';
  }

  private async save(): Promise<void> {
    if (this.busy) {
      return;
    }
    const mkFields = (): TagFields => {
      const f = new TagFields();
      f.title = this.fTitle.trim();
      f.artist = this.fArtist.trim();
      f.album = this.fAlbum.trim();
      f.albumArtist = this.fAlbumArtist.trim();
      f.genre = this.fGenre.trim();
      f.year = this.fYear.trim();
      f.trackNo = this.fTrackNo.trim();
      f.discNo = this.fDiscNo.trim();
      return f;
    };
    if (this.batch) {
      this.busy = true;
      const targets: Song[] = [];
      for (const id of this.batchIds) {
        const s = LibraryStore.get().song(id);
        if (s !== null && s.codec === 'flac') {
          targets.push(s);
        }
      }
      let done = 0;
      let fail = 0;
      for (const s of targets) {
        this.progressText = `${done + fail + 1}/${targets.length} · ${s.displayTitle()}`;
        // 批量:统一专辑级字段,单曲级字段(title/track/disc)不动(写回原值 = 不变更)
        const f = new TagFields();
        f.title = '';
        f.artist = this.fArtist.trim();
        f.album = this.fAlbum.trim();
        f.albumArtist = this.fAlbumArtist.trim();
        f.genre = this.fGenre.trim();
        f.year = this.fYear.trim();
        f.trackNo = '';
        f.discNo = '';
        // 空串 = 清键:批量场景空输入不应清空文件标签 → 传现值保持
        const cur = new TagFields();
        cur.title = s.title;
        cur.artist = f.artist.length > 0 ? f.artist : s.artist;
        cur.album = f.album.length > 0 ? f.album : s.album;
        cur.albumArtist = f.albumArtist.length > 0 ? f.albumArtist : s.albumArtist;
        cur.genre = f.genre.length > 0 ? f.genre : s.genre;
        cur.year = f.year.length > 0 ? f.year : (s.year > 0 ? String(s.year) : '');
        cur.trackNo = '';
        cur.discNo = '';
        const ok = await TagWriter.write(s, cur);
        if (ok) {
          done++;
        } else {
          fail++;
        }
      }
      this.busy = false;
      this.progressText = '';
      hilog.info(DOMAIN, TAG, 'batch done ok=%{public}d fail=%{public}d', done, fail);
      this.getUIContext().getPromptAction().showToast({ message: `批量完成:成功 ${done},失败 ${fail}` });
      return;
    }
    const s = this.song();
    if (s === null) {
      return;
    }
    this.busy = true;
    this.progressText = '写入文件…';
    const ok = await TagWriter.write(s, mkFields());
    this.busy = false;
    this.progressText = '';
    if (ok) {
      this.getUIContext().getPromptAction().showToast({ message: '已写入文件并更新曲库' });
      hilog.info(DOMAIN, TAG, 'tags saved song=%{public}d', s.id);
    } else {
      this.getUIContext().getPromptAction().showToast({ message: '写入失败(仅支持 FLAC,或文件被占用)' });
    }
  }

  build() {
    NavDestination() {
      Column() {
        Scroll() {
          Column({ space: 10 }) {
            if (this.batch) {
              Text(`批量模式:以下专辑级字段将写回列表内全部 FLAC 文件(空输入保持原值)`)
                .fontSize(12)
                .fontColor($r('app.color.accent'))
                .width('100%')
            } else {
              Text(this.song() !== null
                ? `${(this.song() as Song).displayTitle()} · ${(this.song() as Song).codec.toUpperCase()}`
                : '未找到歌曲')
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
            }

            if (!this.batch) {
              this.Field('标题', this.fTitle, (v: string): void => {
                this.fTitle = v;
              })
            }
            this.Field('艺人', this.fArtist, (v: string): void => {
              this.fArtist = v;
            })
            this.Field('专辑', this.fAlbum, (v: string): void => {
              this.fAlbum = v;
            })
            this.Field('专辑艺人', this.fAlbumArtist, (v: string): void => {
              this.fAlbumArtist = v;
            })
            this.Field('流派', this.fGenre, (v: string): void => {
              this.fGenre = v;
            })
            Row({ space: 10 }) {
              this.Field('年份', this.fYear, (v: string): void => {
                this.fYear = v;
              })
              if (!this.batch) {
                this.Field('音轨号', this.fTrackNo, (v: string): void => {
                  this.fTrackNo = v;
                })
                this.Field('碟号', this.fDiscNo, (v: string): void => {
                  this.fDiscNo = v;
                })
              }
            }
            .width('100%')

            Text('仅支持 FLAC(VorbisComment);写入前自动校验,失败自动放弃')
              .fontSize(11)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')

            if (this.progressText.length > 0) {
              Row({ space: 8 }) {
                LoadingProgress().width(16).height(16).color($r('app.color.accent'))
                Text(this.progressText)
                  .fontSize(12)
                  .fontColor($r('app.color.accent'))
              }
              .width('100%')
            }

            Button(this.busy ? '写入中…' : (this.batch ? '批量写入' : '保存并写入文件'))
              .fontSize(14)
              .height(44)
              .width('100%')
              .fontColor($r('app.color.on_accent'))
              .backgroundColor($r('app.color.accent'))
              .enabled(!this.busy)
              .opacity(this.busy ? 0.6 : 1)
              .onClick(() => {
                this.save();
              })

            Blank().height(40)
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 12 })
        }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Auto)
        .align(Alignment.Top)
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.page_bg'))
    }
    .title(this.batch ? '批量修改标签' : '编辑标签')
    .onReady((ctx: NavDestinationContext): void => {
      this.pathStack = ctx.pathStack;
      const p: Object | undefined = ctx.pathInfo.param as Object | undefined;
      if (p instanceof TagEditorParam) {
        this.batch = (p as TagEditorParam).batch;
        this.batchIds = (p as TagEditorParam).songIds;
      } else if (p !== null && p !== undefined && typeof p === 'number') {
        this.songId = p as number;
        this.loadSong(this.songId);
      }
    })
  }

  @Builder
  Field(label: string, value: string, onChange: (v: string) => void) {
    Column({ space: 4 }) {
      Text(label)
        .fontSize(11)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
      TextInput({ text: value })
        .fontSize(14)
        .height(42)
        .width('100%')
        .onChange(onChange)
    }
    .width('100%')
  }
}

@Builder
export function TagEditorBuilder() {
  TagEditorDest()
}

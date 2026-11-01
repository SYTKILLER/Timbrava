// 歌曲行组件:封面/标题/艺人/格式徽章/时长 + 长按上下文菜单(播放/下一首/入队/收藏/看专辑/看艺人)。
import { Song, formatDuration } from '../data/Model';
import { LibraryStore } from '../data/LibraryStore';
import { PlayerController } from '../service/PlayerController';
import { QueueService } from '../service/QueueService';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = '[Timbrava][SongRow]';
const DOMAIN = 0x0001;

@Component
export struct SongRow {
  @Prop song: Song = new Song();
  @Prop showAlbum: boolean = false;
  @StorageProp('libVer') libVer: number = 0;
  @StorageProp('playerVer') playerVer: number = 0;

  navStack(): NavPathStack | null {
    return AppStorage.get<NavPathStack>('navStack') ?? null;
  }

  build() {
    Row({ space: 12 }) {
      // 封面
      Stack() {
        if (this.song.artPath.length > 0) {
          Image(this.song.artPath)
            .width(46)
            .height(46)
            .borderRadius(8)
            .objectFit(ImageFit.Cover)
        } else {
          Column() {
            SymbolGlyph($r('sys.symbol.music_note_list'))
              .fontSize(22)
              .fontColor([$r('app.color.accent')])
          }
          .width(46)
          .height(46)
          .borderRadius(8)
          .backgroundColor($r('app.color.badge_bg'))
          .justifyContent(FlexAlign.Center)
        }
      }
      .alignContent(Alignment.Center)

      // 标题区
      Column({ space: 3 }) {
        Text(this.song.displayTitle())
          .fontSize(16)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Row({ space: 6 }) {
          Text(this.song.displayArtist() + (this.showAlbum ? ' · ' + this.song.displayAlbum() : ''))
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          if (this.song.codec.length > 0) {
            Text(this.song.codec.toUpperCase())
              .fontSize(9)
              .fontColor($r('app.color.badge_text'))
              .backgroundColor($r('app.color.badge_bg'))
              .borderRadius(4)
              .padding({ left: 5, right: 5, top: 1, bottom: 1 })
          }
          if (this.song.specBadge().length > 0) {
            Text(this.song.specBadge())
              .fontSize(9)
              .fontColor($r('app.color.badge_text'))
              .backgroundColor($r('app.color.badge_bg'))
              .borderRadius(4)
              .padding({ left: 5, right: 5, top: 1, bottom: 1 })
          }
        }
        .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      if (LibraryStore.get().isFavorite(this.song.id)) {
        SymbolGlyph($r('sys.symbol.heart_fill'))
          .fontSize(15)
          .fontColor([$r('app.color.accent')])
      }
      Text(formatDuration(this.song.durationMs))
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 8 })
    .onClick(() => {
      this.playNow();
    })
    .bindContextMenu(this.rowMenu(), ResponseType.LongPress)
  }

  private playNow(): void {
    const q = QueueService.get();
    const existing = q.list.indexOf(this.song.id);
    if (existing >= 0) {
      q.jumpTo(existing);
      PlayerController.get().playQueueIndex(existing);
    } else {
      q.playNext(this.song.id);
      q.jumpTo(q.locateCurrent() + 1);
      PlayerController.get().playQueueIndex(q.locateCurrent());
    }
  }

  @Builder
  rowMenu() {
    Menu() {
      MenuItem({ content: '播放' })
        .onClick(() => {
          this.playNow();
        })
      MenuItem({ content: '下一首播放' })
        .onClick(() => {
          QueueService.get().playNext(this.song.id);
          hilog.info(DOMAIN, TAG, 'playNext %{public}s', this.song.title);
        })
      MenuItem({ content: '添加到队列' })
        .onClick(() => {
          QueueService.get().append([this.song.id]);
        })
      MenuItem({
        content: LibraryStore.get().isFavorite(this.song.id) ? '取消收藏' : '收藏'
      })
        .onClick(() => {
          PlayerController.get().toggleFavoriteFor(this.song.id);
        })
      MenuItem({ content: '查看专辑' })
        .onClick(() => {
          const stack = this.navStack();
          if (stack !== null) {
            stack.pushPathByName('SongList', SongListParam.album(this.song.albumArtist, this.song.displayAlbum()));
          }
        })
      MenuItem({ content: '查看艺人' })
        .onClick(() => {
          const stack = this.navStack();
          if (stack !== null) {
            stack.pushPathByName('SongList', SongListParam.artist(this.song.displayArtist()));
          }
        })
    }
  }
}

// 路由参数(SongList 通用)
export class SongListParam {
  mode: string = 'songs'; // album | artist | genre | folder | favorites | songs
  key: string = '';
  subKey: string = '';
  title: string = '';

  static album(albumArtist: string, album: string): SongListParam {
    const p = new SongListParam();
    p.mode = 'album';
    p.key = albumArtist;
    p.subKey = album;
    p.title = album;
    return p;
  }

  static artist(name: string): SongListParam {
    const p = new SongListParam();
    p.mode = 'artist';
    p.key = name;
    p.title = name;
    return p;
  }

  static genre(name: string): SongListParam {
    const p = new SongListParam();
    p.mode = 'genre';
    p.key = name;
    p.title = name;
    return p;
  }

  static folder(dirPath: string): SongListParam {
    const p = new SongListParam();
    p.mode = 'folder';
    p.key = dirPath;
    p.title = dirPath.substring(dirPath.lastIndexOf('/') + 1);
    return p;
  }

  static favorites(): SongListParam {
    const p = new SongListParam();
    p.mode = 'favorites';
    p.title = '收藏';
    return p;
  }

  static allSongs(): SongListParam {
    const p = new SongListParam();
    p.mode = 'songs';
    p.title = '歌曲';
    return p;
  }
}

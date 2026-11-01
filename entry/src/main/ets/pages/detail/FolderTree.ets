// 文件夹目录树页:递归展开/收起 + 目录内歌曲直读。
import { LibraryStore } from '../../data/LibraryStore';
import { Song, FolderNode } from '../../data/Model';
import { SongRow, SongListParam } from '../../components/SongRow';
import { PlayerController } from '../../service/PlayerController';
import { QueueService } from '../../service/QueueService';

class FlatRow {
  node: FolderNode | null = null;
  song: Song | null = null;
  depth: number = 0;

  constructor(depth: number) {
    this.depth = depth;
  }
}

@Component
export struct FolderTreeDest {
  @StorageProp('libVer') libVer: number = 0;
  @State rows: FlatRow[] = [];
  @State expanded: Set<string> = new Set<string>();
  @State title: string = '文件夹';
  private pathStack: NavPathStack | null = null;

  private rebuild(): void {
    const out: FlatRow[] = [];
    const root = LibraryStore.get().folderRoot;
    for (const child of root.children) {
      this.emit(child, 0, out);
    }
    this.rows = out;
  }

  private emit(node: FolderNode, depth: number, out: FlatRow[]): void {
    const row = new FlatRow(depth);
    row.node = node;
    out.push(row);
    if (this.expanded.has(node.dirPath)) {
      for (const child of node.children) {
        this.emit(child, depth + 1, out);
      }
      for (const id of node.songIds) {
        const s = LibraryStore.get().song(id);
        if (s !== null) {
          const srow = new FlatRow(depth + 1);
          srow.song = s;
          out.push(srow);
        }
      }
    }
  }

  private toggle(dirPath: string): void {
    const next = new Set<string>(Array.from(this.expanded));
    if (next.has(dirPath)) {
      next.delete(dirPath);
    } else {
      next.add(dirPath);
    }
    this.expanded = next;
    this.rebuild();
  }

  build() {
    NavDestination() {
      Column() {
        if (this.rows.length === 0) {
          Column({ space: 8 }) {
            SymbolGlyph($r('sys.symbol.folder'))
              .fontSize(42)
              .fontColor([$r('app.color.text_secondary')])
            Text('扫描后这里会显示目录结构')
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
          }
          .width('100%')
          .padding({ top: 80 })
        } else {
          List({ space: 0 }) {
            ForEach(this.rows, (r: FlatRow, i: number) => {
              ListItem() {
                if (r.node !== null) {
                  this.DirRow(r.node, r.depth)
                } else if (r.song !== null) {
                  Row() {
                    Blank().width(r.depth * 16)
                    SongRow({ song: r.song, showAlbum: false })
                  }
                  .width('100%')
                }
              }
            }, (r: FlatRow, i: number): string =>
              r.node !== null ? `d_${r.node.dirPath}_${this.expanded.has(r.node.dirPath) ? '1' : '0'}` : `s_${r.song?.id}_${i}`)
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
    }
    .title('文件夹')
    .onReady((ctx: NavDestinationContext): void => {
      this.pathStack = ctx.pathStack;
      this.rebuild();
    })
  }

  @Builder
  DirRow(node: FolderNode, depth: number) {
    Row({ space: 10 }) {
      Blank().width(depth * 16)
      SymbolGlyph($r('sys.symbol.folder'))
        .fontSize(18)
        .fontColor([$r('app.color.accent')])
      Text(node.name)
        .fontSize(15)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
        .layoutWeight(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(`${node.countSongsRecursive()} 首`)
        .fontSize(11)
        .fontColor($r('app.color.text_secondary'))
      SymbolGlyph(this.expanded.has(node.dirPath) ? $r('sys.symbol.arrow_down') : $r('sys.symbol.chevron_right'))
        .fontSize(13)
        .fontColor([$r('app.color.text_secondary')])
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 10, bottom: 10 })
    .onClick(() => {
      this.toggle(node.dirPath);
    })
    .gesture(LongPressGesture({ repeat: false }).onAction((): void => {
      // 长按:整目录入队
      const ids: number[] = [];
      const collect = (n: FolderNode): void => {
        for (const id of n.songIds) {
          ids.push(id);
        }
        for (const c of n.children) {
          collect(c);
        }
      };
      collect(node);
      if (ids.length > 0) {
        QueueService.get().append(ids);
      }
    }))
  }
}


@Builder
export function FolderTreeBuilder() {
  FolderTreeDest()
}

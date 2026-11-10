// 多选批量操作栏(0.18.0):宿主列表页底部常驻,未激活零高度。
// 行1:已选计数 + 全选/反选 + 退出;行2:收藏 / 加入歌单(选歌单半模态,可新建) / 加入队列 / 下一首播放。
// 操作完成即退出选择模式。宿主页负责 setHost(全选范围) 与离开时 stop()。
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SelService } from '../common/SelService';
import { LibraryStore } from '../data/LibraryStore';
import { PlaylistRepo, PlaylistInfo } from '../data/PlaylistRepo';
import { QueueService } from '../service/QueueService';
import { L } from '../common/Lang';

const TAG = '[Timbrava][SelBar]';
const DOMAIN = 0x0001;

// 新建歌单弹窗(选歌单半模态内;与 PlaylistsTab 的弹窗同款交互)
@CustomDialog
struct SelNewPlDialog {
  controller?: CustomDialogController;
  onConfirm: (name: string) => void = (_n: string): void => {
  };
  @State name: string = '';

  build() {
    Column({ space: 14 }) {
      Text($r('app.string.str_new_playlist'))
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
      TextInput({ text: this.name, placeholder: $r('app.string.new_pl_name') })
        .height(44)
        .fontSize(14)
        .width('100%')
        .borderRadius(10)
        .backgroundColor($r('app.color.badge_bg'))
        .fontColor($r('app.color.text_primary'))
        .placeholderColor($r('app.color.text_secondary'))
        .maxLines(1)
        .onChange((v: string): void => {
          this.name = v;
        })
      Row({ space: 12 }) {
        Button($r('app.string.str_cancel'))
          .fontSize(14)
          .height(40)
          .layoutWeight(1)
          .fontColor($r('app.color.text_primary'))
          .backgroundColor($r('app.color.badge_bg'))
          .onClick(() => {
            this.controller?.close();
          })
        Button($r('app.string.str_ok'))
          .fontSize(14)
          .height(40)
          .layoutWeight(1)
          .fontColor($r('app.color.on_accent'))
          .backgroundColor($r('app.color.accent'))
          .onClick(() => {
            const t = this.name.trim();
            if (t.length > 0) {
              this.onConfirm(t);
              this.controller?.close();
            }
          })
      }
      .width('100%')
    }
    .padding(20)
    .borderRadius(16)
    .backgroundColor($r('app.color.card_bg'))
    .width('86%')
  }
}

@Component
export struct SelActionBar {
  @StorageProp('selVer') selVer: number = 0;
  @StorageProp('bottomSafeVp') bottomSafeVp: number = 28;
  @State showPlSheet: boolean = false;
  @State playlists: PlaylistInfo[] = [];
  private newCtrl: CustomDialogController | null = null;

  private sel(): SelService {
    return SelService.get();
  }

  private toast(msg: ResourceStr): void {
    this.getUIContext().getPromptAction().showToast({ message: msg, duration: 2000 });
  }

  // ===== 批量操作(完成即退出选择模式) =====

  private doFavorites(): void {
    const lib = LibraryStore.get();
    const ids = this.sel().selectedIds();
    for (const id of ids) {
      lib.setFavorite(id, true);
    }
    this.toast(L($r('app.string.sel_fav_done'), String(ids.length)));
    this.sel().stop();
  }

  private doAppendQueue(): void {
    QueueService.get().append(this.sel().selectedIds());
    this.toast(L($r('app.string.sel_queue_done'), String(this.sel().count())));
    this.sel().stop();
  }

  private doPlayNext(): void {
    QueueService.get().playNextBatch(this.sel().selectedIds());
    this.toast(L($r('app.string.sel_playnext_done'), String(this.sel().count())));
    this.sel().stop();
  }

  private async addToPl(plId: number, plName: string): Promise<void> {
    await PlaylistRepo.get().addSongs(plId, this.sel().selectedIds());
    this.toast(L($r('app.string.sel_pl_done'), plName, String(this.sel().count())));
    this.sel().stop();
  }

  private async createPlAndAdd(name: string): Promise<void> {
    const id = await PlaylistRepo.get().createPlaylist(name);
    if (id < 0) {
      this.toast($r('app.string.pl_name_exists'));
      return;
    }
    await this.addToPl(id, name);
  }

  private openPlSheet(): void {
    PlaylistRepo.get().listPlaylists().then((list: PlaylistInfo[]): void => {
      this.playlists = list;
      this.showPlSheet = true;
    });
  }

  private openCreateDialog(): void {
    this.newCtrl = new CustomDialogController({
      builder: SelNewPlDialog({
        onConfirm: (name: string): void => {
          this.createPlAndAdd(name);
        }
      }),
      autoCancel: true,
      customStyle: true
    });
    this.newCtrl.open();
  }

  build() {
    Column() {
      if (this.sel().active) {
        Column() {
          // 行1:计数 + 全选/反选 + 退出
          Row({ space: 8 }) {
            Text(L($r('app.string.sel_count'), String(this.sel().count())))
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
              .layoutWeight(1)
            Button($r('app.string.sel_all'))
              .fontSize(12)
              .fontColor($r('app.color.text_primary'))
              .backgroundColor($r('app.color.badge_bg'))
              .height(36)
              .borderRadius(18)
              .padding({ left: 14, right: 14 })
              .onClick(() => {
                this.sel().selectAll();
              })
            Button($r('app.string.sel_invert'))
              .fontSize(12)
              .fontColor($r('app.color.text_primary'))
              .backgroundColor($r('app.color.badge_bg'))
              .height(36)
              .borderRadius(18)
              .padding({ left: 14, right: 14 })
              .onClick(() => {
                this.sel().invert();
              })
            Button({ stateEffect: true }) {
              SymbolGlyph($r('sys.symbol.xmark'))
                .fontSize(14)
                .fontColor([$r('app.color.text_secondary')])
            }
            .width(36)
            .height(36)
            .borderRadius(18)
            .backgroundColor($r('app.color.badge_bg'))
            .onClick(() => {
              this.sel().stop();
            })
          }
          .width('100%')

          // 行2:批量动作
          Row({ space: 4 }) {
            this.ActBtn($r('sys.symbol.heart'), $r('app.string.str_favorites'), (): void => {
              this.doFavorites();
            })
            this.ActBtn($r('sys.symbol.plus_square_on_square'), $r('app.string.add_to_playlist'), (): void => {
              this.openPlSheet();
            })
            this.ActBtn($r('sys.symbol.list_bullet'), $r('app.string.menu_add_to_queue'), (): void => {
              this.doAppendQueue();
            })
            this.ActBtn($r('sys.symbol.forward_end_fill'), $r('app.string.menu_play_next'), (): void => {
              this.doPlayNext();
            })
          }
          .width('100%')
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 8, bottom: Math.max(this.bottomSafeVp, 28) + 6 })
        .backgroundColor($r('app.color.card_bg'))
        .borderRadius({ topLeft: 16, topRight: 16 })
      }
    }
    .width('100%')
    // 选歌单半模态:现有歌单 + 新建歌单
    .bindSheet(this.showPlSheet, this.PlPickSheet(), {
      detents: [SheetSize.MEDIUM, SheetSize.LARGE],
      dragBar: false,
      showClose: false,
      onDisappear: (): void => {
        this.showPlSheet = false;
      }
    })
  }

  // 批量动作钮:icon 上 / label 下,均分四格;热区 ≥40vp(0.17.0 约定)
  @Builder
  ActBtn(icon: Resource, label: ResourceStr, onTap: () => void) {
    Column({ space: 4 }) {
      SymbolGlyph(icon)
        .fontSize(19)
        .fontColor([$r('app.color.text_primary')])
      Text(label)
        .fontSize(10)
        .fontColor($r('app.color.text_secondary'))
        .maxLines(1)
    }
    .width('100%')
    .height(52)
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      onTap();
    })
  }

  // 歌单选择列表(点歌单即批量加入)
  @Builder
  PlPickSheet() {
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
          this.showPlSheet = false;
        })
        Text(L($r('app.string.sel_pl_title'), String(this.sel().count())))
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: 8, right: 16, top: 8 })

      List({ space: 0 }) {
        ListItem() {
          Row({ space: 12 }) {
            Column() {
              SymbolGlyph($r('sys.symbol.plus'))
                .fontSize(20)
                .fontColor([$r('app.color.accent')])
            }
            .width(46)
            .height(46)
            .borderRadius(8)
            .backgroundColor($r('app.color.badge_bg'))
            .justifyContent(FlexAlign.Center)
            Text($r('app.string.sel_pl_new'))
              .fontSize(15)
              .fontColor($r('app.color.accent'))
              .layoutWeight(1)
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 10, bottom: 10 })
          .onClick(() => {
            this.showPlSheet = false;
            this.openCreateDialog();
          })
        }
        ForEach(this.playlists, (pl: PlaylistInfo) => {
          ListItem() {
            Row({ space: 12 }) {
              Column() {
                SymbolGlyph($r('sys.symbol.music_note_list'))
                  .fontSize(20)
                  .fontColor([$r('app.color.accent')])
              }
              .width(46)
              .height(46)
              .borderRadius(8)
              .backgroundColor($r('app.color.badge_bg'))
              .justifyContent(FlexAlign.Center)
              Text(pl.name)
                .fontSize(15)
                .fontColor($r('app.color.text_primary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
              Text(L($r('app.string.count_songs'), pl.songCount))
                .fontSize(11)
                .fontColor($r('app.color.text_secondary'))
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 10, bottom: 10 })
            .onClick(() => {
              this.showPlSheet = false;
              this.addToPl(pl.id, pl.name);
            })
          }
        }, (pl: PlaylistInfo): string => `plp_${pl.id}`)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      .padding({ bottom: Math.max(this.bottomSafeVp, 28) + 8 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.card_bg'))
  }
}

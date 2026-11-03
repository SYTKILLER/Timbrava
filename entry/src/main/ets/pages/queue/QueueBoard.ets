// 队列板(QueueBoard,蓝本 Gramophone):命名队列列表,切换接管/删除/另存当前。
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { QueueService, QueueBrief } from '../../service/QueueService';
import { PlayerController } from '../../service/PlayerController';
import { AppTheme, SafeAreaResult } from '../../common/Theme';
import { L } from '../../common/Lang';

const TAG = '[Timbrava][QueueBoard]';
const DOMAIN = 0x0001;

@Component
export struct QueueBoardDest {
  @StorageProp('queueVer') @Watch('reload') queueVer: number = 0;
  @State queues: QueueBrief[] = [];
  @State newTitle: string = '';
  @State topSafe: number = 36;
  private pathStack: NavPathStack | null = null;

  aboutToAppear(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    AppTheme.safeAreas(ctx).then((r: SafeAreaResult): void => {
      this.topSafe = r.topVp;
    });
    this.reload();
  }

  private reload(): void {
    QueueService.get().listQueues().then((arr: QueueBrief[]): void => {
      this.queues = arr;
    });
  }

  private async onSwitch(id: string): Promise<void> {
    const q = QueueService.get();
    if (id === q.currentQueueId()) {
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.already_active') });
      return;
    }
    const songIds = await q.switchTo(id);
    if (songIds.length > 0) {
      // 切换即接管:从当前索引开始播
      const idx = q.locateCurrent();
      PlayerController.get().playQueueIndex(idx >= 0 ? idx : 0);
    }
    this.getUIContext().getPromptAction().showToast({ message: $r('app.string.queue_switched') });
  }

  build() {
    NavDestination() {
      Column() {
        Row({ space: 8 }) {
          TextInput({ text: this.newTitle, placeholder: $r('app.string.new_queue_name') })
            .height(40)
            .fontSize(13)
            .borderRadius(10)
            .layoutWeight(1)
            .onChange((v: string): void => {
              this.newTitle = v;
            })
          Button($r('app.string.save_current_queue'))
            .fontSize(12)
            .height(40)
            .fontColor($r('app.color.on_accent'))
            .backgroundColor($r('app.color.accent'))
            .onClick(() => {
              const t = this.newTitle.trim();
              if (t.length === 0) {
                this.getUIContext().getPromptAction().showToast({ message: $r('app.string.name_required') });
                return;
              }
              QueueService.get().saveCurrentAs(t).then((ok: boolean): void => {
                if (ok) {
                  this.newTitle = '';
                  this.getUIContext().getPromptAction().showToast({ message: $r('app.string.str_saved') });
                } else {
                  this.getUIContext().getPromptAction().showToast({ message: $r('app.string.queue_empty_toast') });
                }
              });
            })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: 8 })

        if (this.queues.length === 0) {
          Column({ space: 8 }) {
            SymbolGlyph($r('sys.symbol.list_bullet'))
              .fontSize(40)
              .fontColor([$r('app.color.text_secondary')])
            Text($r('app.string.no_saved_queues'))
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
          }
          .width('100%')
          .padding({ top: 80 })
        } else {
          List({ space: 6 }) {
            ForEach(this.queues, (b: QueueBrief) => {
              ListItem() {
                Row({ space: 10 }) {
                  SymbolGlyph(b.isActive ? $r('sys.symbol.play_fill') : $r('sys.symbol.list_bullet'))
                    .fontSize(18)
                    .fontColor([b.isActive ? $r('app.color.accent') : $r('app.color.text_secondary')])
                  Column({ space: 2 }) {
                    Text(b.title)
                      .fontSize(15)
                      .fontWeight(b.isActive ? FontWeight.Bold : FontWeight.Normal)
                      .fontColor(b.isActive ? $r('app.color.accent') : $r('app.color.text_primary'))
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(L($r('app.string.count_songs'), b.songCount))
                      .fontSize(11)
                      .fontColor($r('app.color.text_secondary'))
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)
                  if (!b.isActive) {
                    Button($r('app.string.str_switch'))
                      .fontSize(12)
                      .height(30)
                      .fontColor($r('app.color.on_accent'))
                      .backgroundColor($r('app.color.accent'))
                      .onClick(() => {
                        this.onSwitch(b.id);
                      })
                    Button({ stateEffect: true }) {
                      SymbolGlyph($r('sys.symbol.trash'))
                        .fontSize(14)
                        .fontColor([$r('app.color.text_secondary')])
                    }
                    .width(30)
                    .height(30)
                    .backgroundColor(Color.Transparent)
                    .onClick(() => {
                      QueueService.get().deleteQueue(b.id);
                    })
                  }
                }
                .width('100%')
                .padding({ left: 16, right: 12, top: 10, bottom: 10 })
                .borderRadius(12)
                .backgroundColor(b.isActive ? $r('app.color.badge_bg') : $r('app.color.card_bg'))
                .onClick(() => {
                  this.onSwitch(b.id);
                })
              }
            }, (b: QueueBrief): string => `${b.id}_${b.isActive ? 'a' : 'n'}_${b.songCount}`)
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
    .padding({ top: this.topSafe })
    .title($r('app.string.queue_board'))
    .onReady((ctx: NavDestinationContext): void => {
      this.pathStack = ctx.pathStack;
    })
  }
}

@Builder
export function QueueBoardBuilder() {
  QueueBoardDest()
}

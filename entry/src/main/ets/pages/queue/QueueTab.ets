// 队列页:当前播放队列(定位当前/上移/下移/移除/点播/清空)+ 循环与随机控制。
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { QueueService } from '../../service/QueueService';
import { PlayerController } from '../../service/PlayerController';
import { LibraryStore } from '../../data/LibraryStore';
import { Song, RepeatMode, formatDuration } from '../../data/Model';
import { AppTheme, SafeAreaResult } from '../../common/Theme';

const TAG = '[Timbrava][QueueTab]';
const DOMAIN = 0x0001;

@Component
export struct QueueTab {
  @StorageProp('queueVer') @Watch('onQueueChanged') queueVer: number = 0;
  @StorageProp('playerVer') playerVer: number = 0;
  @StorageProp('themePageBg') themePageBg: string = '';
  @StorageProp('bottomSafeVp') bottomSafeVp: number = 28;
  @State topSafe: number = 36;
  @State items: Song[] = [];
  @State curIndex: number = -1;

  aboutToAppear(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    AppTheme.safeAreas(ctx).then((r: SafeAreaResult): void => {
      this.topSafe = r.topVp;
    });
    this.reload();
  }

  onQueueChanged(): void {
    this.reload();
  }

  private reload(): void {
    const q = QueueService.get();
    const arr: Song[] = [];
    for (let i = 0; i < q.list.length; i++) {
      const s = LibraryStore.get().song(q.list[i]);
      if (s !== null) {
        arr.push(s);
      }
    }
    this.items = arr;
    this.curIndex = q.currentOrderIndex;
  }

  private pageBg(): ResourceColor {
    return this.themePageBg.length > 0 ? this.themePageBg : $r('app.color.page_bg');
  }

  build() {
    Column() {
      Row() {
        Text('队列')
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
        Button({ stateEffect: true }) {
          SymbolGlyph($r('sys.symbol.square_stack_3d'))
            .fontSize(18)
            .fontColor([QueueService.get().shuffled ? $r('app.color.text_primary') : $r('app.color.text_primary')])
        }
        .width(36)
        .height(36)
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          const stack = AppStorage.get<NavPathStack>('navStack');
          if (stack !== undefined && stack !== null) {
            stack.pushPathByName('QueueBoard', null);
          }
        })
        this.RepeatButton()
        this.ShuffleButton()
        this.SleepButton()
        Button({ stateEffect: true }) {
          SymbolGlyph($r('sys.symbol.trash'))
            .fontSize(18)
            .fontColor([$r('app.color.text_secondary')])
        }
        .width(36)
        .height(36)
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          QueueService.get().clear();
        })
      }
      .width('100%')
      .padding({ left: 16, right: 12, top: this.topSafe + 8, bottom: 8 })

      if (this.items.length === 0) {
        Column({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.list_bullet'))
            .fontSize(42)
            .fontColor([$r('app.color.text_secondary')])
          Text('队列为空:在曲库中长按歌曲加入')
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
        }
        .width('100%')
        .padding({ top: 80 })
      } else {
        List({ space: 0 }) {
          ForEach(this.items, (s: Song, i: number) => {
            ListItem() {
              this.QueueRow(s, i)
            }
          }, (s: Song, i: number): string => `${i}_${s.id}_${i === this.curIndex ? 'cur' : 'n'}`)
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ bottom: this.bottomSafeVp + 140 })
        .scrollBar(BarState.Auto)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.pageBg())
  }

  @Builder
  SleepButton() {
    Button({ stateEffect: true }) {
      SymbolGlyph($r('sys.symbol.timer'))
        .fontSize(18)
        .fontColor([PlayerController.get().sleepRemainMin() > 0 ? $r('app.color.accent') : $r('app.color.text_primary')])
    }
    .width(36)
    .height(36)
    .backgroundColor(Color.Transparent)
    .bindMenu(this.sleepMenu())
  }

  @Builder
  sleepMenu() {
    Menu() {
      MenuItem({ content: '关闭睡眠定时' })
        .onClick(() => {
          PlayerController.get().setSleepTimer(0);
        })
      MenuItem({ content: '15 分钟' })
        .onClick(() => {
          PlayerController.get().setSleepTimer(15);
        })
      MenuItem({ content: '30 分钟' })
        .onClick(() => {
          PlayerController.get().setSleepTimer(30);
        })
      MenuItem({ content: '45 分钟' })
        .onClick(() => {
          PlayerController.get().setSleepTimer(45);
        })
      MenuItem({ content: '60 分钟' })
        .onClick(() => {
          PlayerController.get().setSleepTimer(60);
        })
      MenuItem({ content: '90 分钟' })
        .onClick(() => {
          PlayerController.get().setSleepTimer(90);
        })
    }
  }

  @Builder
  RepeatButton() {
    Button({ stateEffect: true }) {
      SymbolGlyph(this.repeatIcon())
        .fontSize(18)
        .fontColor([this.repeatAccent() ? $r('app.color.accent') : $r('app.color.text_primary')])
    }
    .width(36)
    .height(36)
    .backgroundColor(Color.Transparent)
    .bindMenu(this.repeatMenu())
  }

  private repeatAccent(): boolean {
    const q = QueueService.get();
    return q.repeat !== RepeatMode.OFF || q.boundary !== 'none' || q.stopAfterCurrent;
  }

  private repeatIcon(): Resource {
    const r = QueueService.get().repeat;
    if (r === RepeatMode.ONE) {
      return $r('sys.symbol.repeat_1');
    }
    return $r('sys.symbol.repeat');
  }

  @Builder
  repeatMenu() {
    Menu() {
      MenuItem({ content: '顺序播放(不循环)' })
        .onClick(() => {
          PlayerController.get().setRepeat(RepeatMode.OFF);
        })
      MenuItem({ content: '列表循环' })
        .onClick(() => {
          PlayerController.get().setRepeat(RepeatMode.ALL);
        })
      MenuItem({ content: '单曲循环' })
        .onClick(() => {
          PlayerController.get().setRepeat(RepeatMode.ONE);
        })
      MenuItem({ content: QueueService.get().stopAfterCurrent ? '✓ 播完当前停止' : '播完当前停止' })
        .onClick(() => {
          QueueService.get().setStopAfterCurrent(!QueueService.get().stopAfterCurrent);
        })
      MenuItem({ content: QueueService.get().boundary === 'album' ? '✓ 按专辑推进' : '按专辑推进(跨专辑停)' })
        .onClick(() => {
          QueueService.get().setBoundary(QueueService.get().boundary === 'album' ? 'none' : 'album');
        })
      MenuItem({ content: QueueService.get().boundary === 'artist' ? '✓ 按艺人推进' : '按艺人推进(跨艺人停)' })
        .onClick(() => {
          QueueService.get().setBoundary(QueueService.get().boundary === 'artist' ? 'none' : 'artist');
        })
      MenuItem({ content: QueueService.get().boundary === 'folder' ? '✓ 按文件夹推进' : '按文件夹推进(跨目录停)' })
        .onClick(() => {
          QueueService.get().setBoundary(QueueService.get().boundary === 'folder' ? 'none' : 'folder');
        })
    }
  }

  @Builder
  ShuffleButton() {
    Button({ stateEffect: true }) {
      SymbolGlyph($r('sys.symbol.shuffle'))
        .fontSize(18)
        .fontColor([QueueService.get().shuffled ? $r('app.color.accent') : $r('app.color.text_primary')])
    }
    .width(36)
    .height(36)
    .backgroundColor(Color.Transparent)
    .onClick(() => {
      QueueService.get().toggleShuffle();
    })
  }

  @Builder
  QueueRow(s: Song, i: number) {
    Row({ space: 10 }) {
      Text(String(i + 1))
        .fontSize(12)
        .fontColor(i === this.curIndex ? $r('app.color.accent') : $r('app.color.text_secondary'))
        .width(22)
        .textAlign(TextAlign.Center)
      Column({ space: 2 }) {
        Text(s.displayTitle())
          .fontSize(15)
          .fontColor(i === this.curIndex ? $r('app.color.accent') : $r('app.color.text_primary'))
          .fontWeight(i === this.curIndex ? FontWeight.Bold : FontWeight.Normal)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(s.displayArtist() + ' · ' + formatDuration(s.durationMs))
          .fontSize(11)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Button({ stateEffect: true }) {
        SymbolGlyph($r('sys.symbol.arrow_up'))
          .fontSize(16)
          .fontColor([$r('app.color.text_secondary')])
      }
      .width(30)
      .height(30)
      .backgroundColor(Color.Transparent)
      .onClick(() => {
        QueueService.get().move(i, i - 1);
      })

      Button({ stateEffect: true }) {
        SymbolGlyph($r('sys.symbol.arrow_down'))
          .fontSize(16)
          .fontColor([$r('app.color.text_secondary')])
      }
      .width(30)
      .height(30)
      .backgroundColor(Color.Transparent)
      .onClick(() => {
        QueueService.get().move(i, i + 1);
      })

      Button({ stateEffect: true }) {
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(14)
          .fontColor([$r('app.color.text_secondary')])
      }
      .width(30)
      .height(30)
      .backgroundColor(Color.Transparent)
      .onClick(() => {
        QueueService.get().removeAt(i);
      })
    }
    .width('100%')
    .padding({ left: 12, right: 8, top: 6, bottom: 6 })
    .borderRadius(10)
    .backgroundColor(i === this.curIndex ? $r('app.color.badge_bg') : Color.Transparent)
    .onClick(() => {
      PlayerController.get().playQueueIndex(i);
    })
  }
}

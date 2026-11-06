// 曲库管理页(0.17.0 #5):重扫/去重等维护入口聚合(我的页"曲库管理"进入)。
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { picker } from '@kit.CoreFileKit';
import { ScanService } from '../../data/ScanService';
import { AppTheme } from '../../common/Theme';
import { L } from '../../common/Lang';

const TAG = '[Timbrava][LibraryManage]';
const DOMAIN = 0x0001;

@Component
export struct LibraryManageDest {
  @StorageProp('topSafeVp') topSafeVp: number = 36;
  @StorageProp('bottomSafeVp') bottomSafeVp: number = 28;
  @StorageProp('themePageBg') themePageBg: string = '';
  @StorageProp('scanVer') @Watch('onScanChanged') scanVer: number = 0;
  @State scanning: boolean = false;
  private pathStack: NavPathStack | null = null;

  aboutToAppear(): void {
    this.onScanChanged();
  }

  onScanChanged(): void {
    this.scanning = ScanService.get().isScanning();
  }

  private pageBg(): ResourceColor {
    return this.themePageBg.length > 0 ? this.themePageBg : $r('app.color.page_bg');
  }

  private nav(): NavPathStack {
    const stack = AppStorage.get<NavPathStack>('navStack');
    return stack !== undefined && stack !== null ? stack : new NavPathStack();
  }

  private toast(msg: ResourceStr): void {
    this.getUIContext().getPromptAction().showToast({ message: msg, duration: 2000 });
  }

  // 添加歌曲(与我的页同款:选完即入库)
  private async addSongs(): Promise<void> {
    try {
      const audioPicker = new picker.AudioViewPicker();
      const opts = new picker.AudioSelectOptions();
      opts.maxSelectNumber = 500;
      const uris: Array<string> = await audioPicker.select(opts);
      if (uris.length === 0) {
        return;
      }
      const added = await ScanService.get().addPickedAudioUris(uris);
      this.toast(added > 0 ? L($r('app.string.import_added'), String(added)) : $r('app.string.import_none'));
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'addSongs fail %{public}s', (e as Error).message);
    }
  }

  // 重新扫描:按已登记目录重读文件,同步增删改(去重/退役走既有身份链路)
  private rescan(): void {
    if (ScanService.get().isScanning()) {
      this.toast($r('app.string.dup_analyzing'));
      return;
    }
    ScanService.get().rescan().then((): void => {
      hilog.info(DOMAIN, TAG, 'rescan done');
    }).catch((e: Error): void => {
      hilog.error(DOMAIN, TAG, 'rescan fail %{public}s', e.message);
    });
    this.toast($r('app.string.rescan_started'));
  }

  build() {
    NavDestination() {
      Column({ space: 12 }) {
        Scroll() {
          Column({ space: 12 }) {
            // 媒体库维护
            Column({ space: 4 }) {
              Text($r('app.string.media_library'))
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
                .padding({ left: 4, top: 4 })
              Column() {
                this.ManageRow($r('app.string.add_songs'), $r('app.string.add_songs_sub'), (): void => {
                  this.addSongs();
                })
                Divider().color($r('app.color.divider'))
                this.ManageRow($r('app.string.rescan_now'), $r('app.string.rescan_sub'), (): void => {
                  this.rescan();
                }, this.scanning)
                Divider().color($r('app.color.divider'))
                this.ManageRow($r('app.string.duplicates_title'), $r('app.string.duplicates_sub'), (): void => {
                  this.nav().pushPathByName('Duplicates', null);
                })
              }
              .width('100%')
              .padding(12)
              .borderRadius(16)
              .backgroundColor($r('app.color.card_bg'))
            }
            .width('100%')
            .padding({ left: 16, right: 16 })

            Blank().height(this.bottomSafeVp + 140)
          }
          .width('100%')
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Auto)
        .align(Alignment.Top)
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.pageBg())
    }
    .padding({ top: this.topSafeVp })
    .title($r('app.string.lib_manage'))
    .onReady((ctx: NavDestinationContext): void => {
      this.pathStack = ctx.pathStack;
    })
  }

  @Builder
  ManageRow(title: ResourceStr, sub: ResourceStr, onTap: () => void, busy: boolean = false) {
    Row({ space: 12 }) {
      Column({ space: 2 }) {
        Text(title)
          .fontSize(15)
          .fontColor($r('app.color.text_primary'))
        Text(sub)
          .fontSize(11)
          .fontColor($r('app.color.text_secondary'))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      if (busy) {
        LoadingProgress().width(20).height(20).color($r('app.color.accent'))
      } else {
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(14)
          .fontColor([$r('app.color.text_secondary')])
      }
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
    .opacity(busy ? 0.6 : 1)
    .onClick(() => {
      if (!busy) {
        onTap();
      }
    })
  }
}

@Builder
export function LibraryManageBuilder() {
  LibraryManageDest()
}

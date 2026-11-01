// 扫描文件夹管理:权限申请 + 文件夹选择(picker)/沙箱调试目录 + 重扫 + 进度。
import { common } from '@kit.AbilityKit';
import { abilityAccessCtrl, Permissions } from '@kit.AbilityKit';
import { picker } from '@kit.CoreFileKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Db } from '../../data/Db';
import { ScanService } from '../../data/ScanService';
import { RootFolder, ScanProgress } from '../../data/Model';
import { LibraryStore } from '../../data/LibraryStore';
import { AppTheme, SafeAreaResult } from '../../common/Theme';

const TAG = '[Timbrava][ScanSettings]';
const DOMAIN = 0x0001;

@Component
export struct ScanSettingsDest {
  @StorageProp('scanVer') @Watch('onScanChanged') scanVer: number = 0;
  @State roots: RootFolder[] = [];
  @State progress: ScanProgress = new ScanProgress();
  @State topSafe: number = 36;
  private pathStack: NavPathStack | null = null;

  aboutToAppear(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    AppTheme.safeAreas(ctx).then((r: SafeAreaResult): void => {
      this.topSafe = r.topVp;
    });
    this.reloadRoots();
  }

  onScanChanged(): void {
    this.progress = ScanService.get().getProgress();
  }

  private reloadRoots(): void {
    Db.get().getRootFolders().then((roots: RootFolder[]): void => {
      this.roots = roots;
    });
  }

  private async ensureAudioPermission(): Promise<boolean> {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      const atManager = abilityAccessCtrl.getAtManager();
      const result = await atManager.requestPermissionsFromUser(ctx, ['ohos.permission.READ_AUDIO'] as Permissions[]);
      let granted = false;
      for (const r of result.authResults) {
        if (r === 0) {
          granted = true;
        }
      }
      hilog.info(DOMAIN, TAG, 'READ_AUDIO granted=%{public}s', granted ? 'yes' : 'no');
      return granted;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'requestPermissions fail %{public}s', (e as Error).message);
      return false;
    }
  }

  private async pickFolder(): Promise<void> {
    const granted = await this.ensureAudioPermission();
    try {
      const docPicker = new picker.DocumentViewPicker();
      const opts = new picker.DocumentSelectOptions();
      opts.maxSelectNumber = 1;
      opts.selectMode = picker.DocumentSelectMode.FOLDER;
      const uris: Array<string> = await docPicker.select(opts);
      if (uris.length > 0) {
        const roots = this.roots.slice();
        roots.push(new RootFolder('uri', uris[0]));
        await Db.get().setRootFolders(roots);
        this.roots = roots;
        hilog.info(DOMAIN, TAG, 'folder added(URI)');
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'pickFolder fail %{public}s', (e as Error).message);
    }
  }

  private async addSandboxDebugRoot(): Promise<void> {
    // 调试/验证通道:应用沙箱 files/music(可用 hdc file send 推入语料)
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const dir = `${ctx.filesDir}/music`;
    try {
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir, true);
      }
    } catch (e) {
      try {
        fs.mkdirSync(dir, true);
      } catch (e2) {
        hilog.error(DOMAIN, TAG, 'mkdir sandbox music fail');
        return;
      }
    }
    const roots = this.roots.slice();
    const exists = roots.find((r: RootFolder): boolean => r.value === dir);
    if (exists === undefined) {
      roots.push(new RootFolder('path', dir));
      await Db.get().setRootFolders(roots);
      this.roots = roots;
    }
    hilog.info(DOMAIN, TAG, 'sandbox debug root: %{public}s', dir);
  }

  private async removeRoot(index: number): Promise<void> {
    const roots = this.roots.slice();
    roots.splice(index, 1);
    await Db.get().setRootFolders(roots);
    this.roots = roots;
  }

  private async rescan(): Promise<void> {
    await ScanService.get().rescan();
  }

  build() {
    NavDestination() {
      Column() {
        Scroll() {
          Column({ space: 12 }) {
            // 根目录列表
            Column({ space: 4 }) {
              Text('扫描根目录')
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
                .padding({ left: 4, top: 4 })
              Column() {
                if (this.roots.length === 0) {
                  Text('还没有添加目录')
                    .fontSize(13)
                    .fontColor($r('app.color.text_secondary'))
                    .width('100%')
                    .padding(12)
                } else {
                  ForEach(this.roots, (r: RootFolder, i: number) => {
                    Row({ space: 8 }) {
                      SymbolGlyph($r('sys.symbol.folder'))
                        .fontSize(16)
                        .fontColor([$r('app.color.accent')])
                      Column({ space: 2 }) {
                        Text(r.type === 'path' ? '本地目录' : '已授权目录(URI)')
                          .fontSize(14)
                          .fontColor($r('app.color.text_primary'))
                        Text(r.value)
                          .fontSize(10)
                          .fontColor($r('app.color.text_secondary'))
                          .maxLines(1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                      }
                      .alignItems(HorizontalAlign.Start)
                      .layoutWeight(1)
                      Button('移除')
                        .fontSize(12)
                        .height(28)
                        .fontColor($r('app.color.text_secondary'))
                        .backgroundColor($r('app.color.badge_bg'))
                        .onClick(() => {
                          this.removeRoot(i);
                        })
                    }
                    .width('100%')
                    .padding({ top: 8, bottom: 8 })
                  }, (r: RootFolder, i: number): string => `${i}_${r.value}`)
                }
              }
              .width('100%')
            }
            .width('100%')
            .padding(12)
            .borderRadius(16)
            .backgroundColor($r('app.color.card_bg'))

            // 操作按钮
            Row({ space: 10 }) {
              Button('添加文件夹')
                .fontSize(14)
                .fontColor($r('app.color.on_accent'))
                .backgroundColor($r('app.color.accent'))
                .height(44)
                .borderRadius(12)
                .layoutWeight(1)
                .onClick(() => {
                  this.pickFolder();
                })
              Button(this.progress.state === 'scanning' ? '扫描中…' : '开始扫描')
                .fontSize(14)
                .fontColor($r('app.color.on_accent'))
                .backgroundColor(this.progress.state === 'scanning' ? $r('app.color.text_secondary') : $r('app.color.accent'))
                .height(44)
                .borderRadius(12)
                .layoutWeight(1)
                .enabled(this.progress.state !== 'scanning')
                .onClick(() => {
                  this.rescan();
                })
            }
            .width('100%')

            // 调试通道
            Button('添加沙箱测试目录(files/music)')
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .backgroundColor($r('app.color.badge_bg'))
              .height(36)
              .width('100%')
              .onClick(() => {
                this.addSandboxDebugRoot();
              })

            // 进度
            Column({ space: 6 }) {
              Text(this.progress.state === 'scanning'
                ? `扫描中 ${this.progress.current}/${this.progress.total}`
                : this.progress.state === 'done' ? `扫描完成:${this.progress.message}`
                  : this.progress.state === 'error' ? `扫描失败:${this.progress.message}` : '尚未扫描')
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
              if (this.progress.state === 'scanning' && this.progress.total > 0) {
                Progress({ value: this.progress.current, total: this.progress.total, type: ProgressType.Linear })
                  .color($r('app.color.accent'))
                  .width('100%')
              }
            }
            .width('100%')
            .padding(12)
            .borderRadius(16)
            .backgroundColor($r('app.color.card_bg'))

            Blank().height(60)
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: this.topSafe + 8 })
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
    .title('扫描文件夹')
    .onReady((ctx: NavDestinationContext): void => {
      this.pathStack = ctx.pathStack;
    })
  }
}

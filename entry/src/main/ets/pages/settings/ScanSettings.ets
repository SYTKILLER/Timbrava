// 扫描文件夹管理:权限申请 + 文件夹选择(picker)/沙箱调试目录 + 重扫 + 进度。
import { common } from '@kit.AbilityKit';
import { abilityAccessCtrl, Permissions } from '@kit.AbilityKit';
import { picker } from '@kit.CoreFileKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Db } from '../../data/Db';
import timbravaCore from 'libtimbrava_core.so';
import { ScanService } from '../../data/ScanService';
import { RootFolder, ScanProgress } from '../../data/Model';
import { LibraryStore } from '../../data/LibraryStore';
import { AppTheme, SafeAreaResult } from '../../common/Theme';
import { L } from '../../common/Lang';

const TAG = '[Timbrava][ScanSettings]';
const DOMAIN = 0x0001;

@Component
export struct ScanSettingsDest {
  @StorageProp('scanVer') @Watch('onScanChanged') scanVer: number = 0;
  @State roots: RootFolder[] = [];
  @State blacklist: string[] = [];
  @State newBlackPath: string = '';
  @State progress: ScanProgress = new ScanProgress();
  @State topSafe: number = 36;
  private pathStack: NavPathStack | null = null;

  aboutToAppear(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    AppTheme.safeAreas(ctx).then((r: SafeAreaResult): void => {
      this.topSafe = r.topVp;
    });
    this.reloadRoots();
    this.reloadBlacklist();
  }

  private reloadBlacklist(): void {
    Db.get().getBlacklist().then((arr: string[]): void => {
      this.blacklist = arr;
    });
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
      const atManager = abilityAccessCtrl.createAtManager();
      const perms: Array<Permissions> = ['ohos.permission.READ_AUDIO'];
      const result = await atManager.requestPermissionsFromUser(ctx, perms);
      let granted = false;
      const results: number[] = result.authResults;
      for (const r of results) {
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
    // 授权宿主 shell 穿越写入语料(files 需 o+x,music 需 o+rwx)
    try {
      timbravaCore.chmodPath(ctx.filesDir, 0o775);
      timbravaCore.chmodPath(dir, 0o777);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'chmod fail %{public}s', (e as Error).message);
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

  private importing: boolean = false;

  // 调试通道:从宿主机 HTTP 服务导入语料(模拟器网关 10.0.2.2)
  private async importFromHost(): Promise<void> {
    if (this.importing) {
      return;
    }
    this.importing = true;
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const dir = `${ctx.filesDir}/music`;
    try {
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir, true);
      }
    } catch (e) {
      this.importing = false;
      return;
    }
    const base = 'http://127.0.0.1:8099'; // hdc rport 反向隧道到宿主机
    try {
      const manifest = await this.httpGetBuffer(`${base}/manifest.json`);
      const text = this.abToString(manifest);
      const names: string[] = JSON.parse(text) as string[];
      hilog.info(DOMAIN, TAG, 'import manifest n=%{public}d', names.length);
      for (const name of names) {
        const dest = `${dir}/${name}`;
        let existing = -1;
        try {
          if (fs.accessSync(dest)) {
            const st = fs.statSync(dest);
            existing = st.size;
          }
        } catch (e) {
          existing = -1;
        }
        if (existing === 0 || (existing > 0 && name.indexOf('BigTrack') >= 0 && existing > 1024 * 1024 * 1024)) {
          hilog.info(DOMAIN, TAG, 'skip existing %{public}s size=%{public}d', name, existing);
          continue;
        }
        await this.httpDownloadToFile(`${base}/${encodeURIComponent(name)}`, dest);
      }
      hilog.info(DOMAIN, TAG, 'import done');
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'importFromHost fail %{public}s', (e as Error).message);
    } finally {
      this.importing = false;
    }
  }

  private async httpGetBuffer(url: string): Promise<ArrayBuffer> {
    const req = http.createHttp();
    try {
      const resp = await req.request(url, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 5000,
        readTimeout: 10000
      });
      if (resp.responseCode >= 300) {
        throw new Error(`http ${resp.responseCode}`);
      }
      return resp.result as ArrayBuffer;
    } finally {
      req.destroy();
    }
  }

  private async httpDownloadToFile(url: string, dest: string): Promise<void> {
    return new Promise<void>((resolve: () => void, reject: (e: Error) => void) => {
      const req = http.createHttp();
      let file: fs.File | null = null;
      let pos = 0;
      let fail = (e: Error): void => {
        if (file !== null) {
          try {
            fs.closeSync(file);
          } catch (e2) {
          }
        }
        req.destroy();
        reject(e);
      };
      req.on('dataReceive', (chunk: ArrayBuffer): void => {
        if (chunk.byteLength === 0) {
          return;
        }
        try {
          if (file === null) {
            file = fs.openSync(dest, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
            hilog.info(DOMAIN, TAG, 'download start %{public}s', dest);
          }
          const standalone: ArrayBuffer = chunk.slice(0);
          fs.writeSync(file.fd, standalone, { offset: pos, length: chunk.byteLength });
          pos += chunk.byteLength;
        } catch (e) {
          fail(e as Error);
        }
      });
      req.on('dataEnd', (): void => {
        if (file !== null) {
          try {
            fs.closeSync(file);
          } catch (e2) {
          }
          file = null;
        }
        req.destroy();
        hilog.info(DOMAIN, TAG, 'download done %{public}s bytes=%{public}d', dest, pos);
        resolve();
      });
      req.requestInStream(url, {
        method: http.RequestMethod.GET,
        connectTimeout: 5000,
        readTimeout: 600000
      }).catch((e: Error): void => {
        fail(e);
      });
    });
  }

  private abToString(ab: ArrayBuffer): string {
    const u8 = new Uint8Array(ab);
    let out = '';
    const chunk = 8192;
    for (let i = 0; i < u8.length; i += chunk) {
      const sub = u8.subarray(i, Math.min(i + chunk, u8.length));
      out += this.latin(sub);
    }
    return out;
  }

  private latin(b: Uint8Array): string {
    let s = '';
    for (let i = 0; i < b.length; i++) {
      s += String.fromCharCode(b[i]);
    }
    return s;
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
              Text($r('app.string.scan_roots'))
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
                .padding({ left: 4, top: 4 })
              Column() {
                if (this.roots.length === 0) {
                  Text($r('app.string.no_roots'))
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
                        Text(r.type === 'path' ? $r('app.string.local_dir') : $r('app.string.uri_dir'))
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
                      Button($r('app.string.str_remove'))
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
              Button($r('app.string.add_folder'))
                .fontSize(14)
                .fontColor($r('app.color.on_accent'))
                .backgroundColor($r('app.color.accent'))
                .height(44)
                .borderRadius(12)
                .layoutWeight(1)
                .onClick(() => {
                  this.pickFolder();
                })
              Button(this.progress.state === 'scanning' ? $r('app.string.scanning') : $r('app.string.start_scan'))
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
            Button($r('app.string.add_sandbox_root'))
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .backgroundColor($r('app.color.badge_bg'))
              .height(36)
              .width('100%')
              .onClick(() => {
                this.addSandboxDebugRoot();
              })
            Button($r('app.string.import_corpus'))
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .backgroundColor($r('app.color.badge_bg'))
              .height(36)
              .width('100%')
              .onClick(() => {
                ScanService.get().importFromHost();
              })

            // 进度
            Column({ space: 6 }) {
              Text(this.progress.state === 'scanning'
                ? L($r('app.string.scan_progress'), this.progress.current, this.progress.total)
                : this.progress.state === 'done' ? L($r('app.string.scan_done_msg'), this.progress.message)
                  : this.progress.state === 'error' ? L($r('app.string.scan_fail_msg'), this.progress.message) : $r('app.string.not_scanned'))
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

            // 黑名单(忽略路径前缀)
            Column({ space: 6 }) {
              Text($r('app.string.blacklist_title'))
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
              Row({ space: 8 }) {
                TextInput({ text: this.newBlackPath, placeholder: $r('app.string.blacklist_hint') })
                  .fontSize(13)
                  .height(36)
                  .borderRadius(10)
                  .layoutWeight(1)
                  .onChange((v: string): void => {
                    this.newBlackPath = v;
                  })
                Button($r('app.string.str_add'))
                  .fontSize(12)
                  .height(36)
                  .fontColor($r('app.color.on_accent'))
                  .backgroundColor($r('app.color.accent'))
                  .onClick(() => {
                    const p = this.newBlackPath.trim();
                    if (p.length > 0) {
                      Db.get().addBlacklist(p).then((): void => {
                        this.newBlackPath = '';
                        this.reloadBlacklist();
                      });
                    }
                  })
              }
              .width('100%')
              if (this.blacklist.length > 0) {
                ForEach(this.blacklist, (b: string, i: number) => {
                  Row({ space: 8 }) {
                    Text(b)
                      .fontSize(12)
                      .fontColor($r('app.color.text_primary'))
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .layoutWeight(1)
                    Button($r('app.string.str_remove'))
                      .fontSize(11)
                      .height(26)
                      .fontColor($r('app.color.text_secondary'))
                      .backgroundColor($r('app.color.badge_bg'))
                      .onClick(() => {
                        Db.get().removeBlacklist(b).then((): void => {
                          this.reloadBlacklist();
                        });
                      })
                  }
                  .width('100%')
                }, (b: string): string => b)
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
    .title($r('app.string.scan_folders'))
    .onReady((ctx: NavDestinationContext): void => {
      this.pathStack = ctx.pathStack;
    })
  }
}


@Builder
export function ScanSettingsBuilder() {
  ScanSettingsDest()
}

// 关于页:版本 / 隐私承诺 / 开源组件说明 / 检查更新(GitHub Releases)。
import { bundleManager, common, Want } from '@kit.AbilityKit';
import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { L } from '../../common/Lang';

const TAG = '[Timbrava][About]';
const DOMAIN = 0x0001;
const RELEASE_API = 'https://api.github.com/repos/SYTKILLER/Timbrava/releases/latest';

@Component
export struct AboutDest {
  @State versionName: string = '';
  @State checking: boolean = false;
  @StorageProp('topSafeVp') topSafeVp: number = 36; // 全屏沉浸后手动避让状态栏

  aboutToAppear(): void {
    try {
      const info = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      this.versionName = info.versionName;
    } catch (e) {
      this.versionName = '';
    }
  }

  @Builder
  Section(title: ResourceStr, body: ResourceStr) {
    Column({ space: 6 }) {
      Text(title)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
      Text(body)
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .lineHeight(20)
    }
    .width('100%')
    .padding(16)
    .borderRadius(16)
    .backgroundColor($r('app.color.card_bg'))
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    NavDestination() {
      Scroll() {
        Column({ space: 12 }) {
          Column({ space: 4 }) {
            Text($r('app.string.about_title'))
              .fontSize(26)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
            Text(this.versionName.length > 0 ? L($r('app.string.version_line'), this.versionName) : $r('app.string.version_loading'))
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
          }
          .width('100%')
          .padding({ top: 12, bottom: 4 })
          .alignItems(HorizontalAlign.Center)

          Button(this.checking ? $r('app.string.checking_update') : $r('app.string.check_update'))
            .fontSize(13)
            .fontColor(this.checking ? $r('app.color.text_secondary') : $r('app.color.text_primary'))
            .backgroundColor($r('app.color.badge_bg'))
            .height(40)
            .borderRadius(20)
            .enabled(!this.checking)
            .onClick(() => {
              this.checkUpdate();
            })

          this.Section($r('app.string.about_positioning'),
            $r('app.string.about_desc'))
          this.Section($r('app.string.privacy_title'),
            $r('app.string.privacy_desc'))
          this.Section($r('app.string.oss_title'),
            $r('app.string.oss_desc'))
          this.Section($r('app.string.about_note'),
            $r('app.string.engine_note'))
          Blank().height(60)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8 })
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Auto)
      .align(Alignment.Top)
      .backgroundColor($r('app.color.page_bg'))
    }
    .padding({ top: this.topSafeVp })
    .title($r('app.string.str_about'))
  }

  // 检查更新:请求 GitHub Releases 最新版,与包版本比较(semver 数字段)。
  private checkUpdate(): void {
    if (this.checking) {
      return;
    }
    this.checking = true;
    hilog.info(DOMAIN, TAG, 'check update start current=%{public}s', this.versionName);
    const req = http.createHttp();
    req.request(RELEASE_API, {
      method: http.RequestMethod.GET,
      header: { 'Accept': 'application/vnd.github+json', 'User-Agent': 'Timbrava' },
      expectDataType: http.HttpDataType.STRING,
      connectTimeout: 10000,
      readTimeout: 10000
    }).then((resp: http.HttpResponse): void => {
      req.destroy();
      this.checking = false;
      if (resp.responseCode !== 200) {
        hilog.warn(DOMAIN, TAG, 'check update http %{public}d', resp.responseCode);
        this.getUIContext().getPromptAction().showToast({ message: $r('app.string.check_update_failed') });
        return;
      }
      const data = JSON.parse(resp.result as string) as ReleaseInfo;
      const latest = data.tag_name.replace(/^v/i, '');
      hilog.info(DOMAIN, TAG, 'check update latest=%{public}s url=%{public}s', latest, data.html_url);
      if (this.newerThan(latest, this.versionName)) {
        this.getUIContext().showAlertDialog({
          title: L($r('app.string.new_version_found'), latest),
          message: data.html_url,
          primaryButton: {
            value: $r('app.string.cancel'),
            action: (): void => {
            }
          },
          secondaryButton: {
            value: $r('app.string.view_release'),
            action: (): void => {
              // 系统浏览器打开发布页(openLink 在当前 SDK 不可用)
              const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
              const want: Want = {
                action: 'ohos.want.action.viewData',
                entities: ['entity.system.browsable'],
                uri: data.html_url
              };
              ctx.startAbility(want).catch((e: Error): void => {
                hilog.warn(DOMAIN, TAG, 'open release fail %{public}s', e.message);
              });
            }
          }
        });
      } else {
        this.getUIContext().getPromptAction().showToast({ message: $r('app.string.already_latest') });
      }
    }).catch((e: Error): void => {
      req.destroy();
      this.checking = false;
      hilog.warn(DOMAIN, TAG, 'check update fail %{public}s', e.message);
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.check_update_failed') });
    });
  }

  // 逐段数字比较:latest 是否大于 current(容错非数字段按 0 处理)。
  private newerThan(latest: string, current: string): boolean {
    const a = latest.split('.');
    const b = current.split('.');
    const n = Math.max(a.length, b.length);
    for (let i = 0; i < n; i++) {
      const x = i < a.length ? (parseInt(a[i], 10) || 0) : 0;
      const y = i < b.length ? (parseInt(b[i], 10) || 0) : 0;
      if (x !== y) {
        return x > y;
      }
    }
    return false;
  }
}

interface ReleaseInfo {
  tag_name: string;
  html_url: string;
}


@Builder
export function AboutBuilder() {
  AboutDest()
}

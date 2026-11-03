// 关于页:版本 / 隐私承诺 / 开源组件说明。
import { bundleManager } from '@kit.AbilityKit';
import { AppTheme, SafeAreaResult } from '../../common/Theme';
import { common } from '@kit.AbilityKit';
import { L } from '../../common/Lang';

@Component
export struct AboutDest {
  @State versionName: string = '';
  @State topSafe: number = 36;

  aboutToAppear(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    AppTheme.safeAreas(ctx).then((r: SafeAreaResult): void => {
      this.topSafe = r.topVp;
    });
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
        .padding({ left: 16, right: 16, top: this.topSafe })
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Auto)
      .align(Alignment.Top)
      .backgroundColor($r('app.color.page_bg'))
    }
    .title($r('app.string.str_about'))
  }
}


@Builder
export function AboutBuilder() {
  AboutDest()
}

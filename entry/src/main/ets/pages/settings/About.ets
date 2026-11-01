// 关于页:版本 / 隐私承诺 / 开源组件说明。
import { bundleManager } from '@kit.AbilityKit';
import { AppTheme, SafeAreaResult } from '../../common/Theme';
import { common } from '@kit.AbilityKit';

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
  Section(title: string, body: string) {
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
            Text('听韵 Timbrava')
              .fontSize(26)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
            Text(this.versionName.length > 0 ? `版本 ${this.versionName}` : '版本信息获取中')
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
          }
          .width('100%')
          .padding({ top: 12, bottom: 4 })
          .alignItems(HorizontalAlign.Center)

          this.Section('定位',
            '纯本地、纯离线、无广告的 HiFi 无损音乐播放器。支持 FLAC/WAV 比特完美播放,单曲 1GB+ 超高码率真无损完整流式解码。')
          this.Section('隐私承诺',
            '不收集任何数据、不联网(默认)、无广告、无追踪。音乐文件仅在本地扫描与播放。')
          this.Section('开源组件',
            'FLAC 解码:dr_flac(公有领域 / MIT-0 双许可)。其余代码均为本项目自研。')
          this.Section('说明',
            '无损引擎下 FLAC/WAV 按源采样率与位深建流;MP3/OGG/M4A/APE 等格式由系统 AVPlayer 引擎播放。')
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
    .title('关于')
  }
}


@Builder
export function AboutBuilder() {
  AboutDest()
}

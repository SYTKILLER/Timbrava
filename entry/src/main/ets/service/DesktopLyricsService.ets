// 桌面歌词浮窗服务(26-7):window.floatView 标准悬浮窗承载 DesktopLyricsPage。
// 守卫:26 + isFloatViewEnabled;FLOAT_VIEW 权限未授(签名 profile 未含 ACL)时 start 抛 201 →
// 记日志置禁用,UI 侧提示引导;页面内容经 AppStorage 与播放器共享,无需 LocalStorage 传参。
import { floatView } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = '[Timbrava][DskLyrics]';
const DOMAIN = 0x0001;

export class DesktopLyricsService {
  private static instance: DesktopLyricsService | null = null;
  static get(): DesktopLyricsService {
    if (DesktopLyricsService.instance === null) {
      DesktopLyricsService.instance = new DesktopLyricsService();
    }
    return DesktopLyricsService.instance;
  }

  private ctrl: floatView.FloatViewController | null = null;
  private disabled: boolean = false; // 权限/能力失败后本会话停用(避免反复弹错)

  available(): boolean {
    if (deviceInfo.sdkApiVersion < 26 || this.disabled) {
      return false;
    }
    try {
      return floatView.isFloatViewEnabled();
    } catch (e) {
      return false;
    }
  }

  isOn(): boolean {
    return this.ctrl !== null;
  }

  async toggle(ctx: common.UIAbilityContext): Promise<void> {
    if (this.ctrl !== null) {
      await this.stop();
      return;
    }
    const cfg: floatView.FloatViewConfiguration = {
      context: ctx,
      templateType: 0 as floatView.FloatViewTemplateType // ROUNDED_RECTANGLE
    };
    try {
      const c = await floatView.create(cfg);
      await c.setUIContext('pages/player/DesktopLyricsPage');
      c.onStateChange((info: floatView.FloatViewStateChangeInfo): void => {
        hilog.info(DOMAIN, TAG, 'state %{public}d', info.state);
      });
      await c.start();
      this.ctrl = c;
      hilog.info(DOMAIN, TAG, 'float view started');
    } catch (e) {
      this.disabled = true;
      this.ctrl = null;
      hilog.error(DOMAIN, TAG, 'start fail %{public}s(201=FLOAT_VIEW 权限未授)', (e as Error).message);
      throw e as Error;
    }
  }

  async stop(): Promise<void> {
    const c = this.ctrl;
    this.ctrl = null;
    if (c === null) {
      return;
    }
    try {
      await c.stop();
      hilog.info(DOMAIN, TAG, 'float view stopped');
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'stop fail %{public}s', (e as Error).message);
    }
  }
}

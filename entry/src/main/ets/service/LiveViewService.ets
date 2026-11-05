// 26-6 实况窗(Live View Kit):播放中在锁屏/通知中心呈现 歌名+进度环+状态 胶囊。
// 场景映射:PROGRESS(音乐播放无专有场景,取进度展示语义);守卫:26 + isLiveViewEnabled;
// 实况窗场景权(AGC 申请)未授时 start/update 返回权限错误 → 静默停用并记日志,不打扰播放主链路。
// 节流:进度每 tick 刷会打爆实况窗,按 5% 步进或 状态/曲目 变化才 update。
import { liveViewManager } from '@kit.LiveViewKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = '[Timbrava][LiveView]';
const DOMAIN = 0x0001;

const LV_ID = 260101; // 实况窗 id(自造,区间内;与卡片/通知 id 空间无冲突)
const STEP_PERCENT = 5; // 进度刷新步进(%)

export class LiveViewService {
  private static instance: LiveViewService | null = null;
  static get(): LiveViewService {
    if (LiveViewService.instance === null) {
      LiveViewService.instance = new LiveViewService();
    }
    return LiveViewService.instance;
  }

  private supported: boolean = deviceInfo.sdkApiVersion >= 26;
  private active: boolean = false;   // 实况窗已拉起
  private disabled: boolean = false; // 权限/能力失败后本会话停用
  private lastPercent: number = -99;
  private lastSignature: string = '';

  available(): boolean {
    return this.supported && !this.disabled;
  }

  // 播放状态变化(PlayerController.bumpPlayer 链):playing/song 变化立即刷新;进度按步进节流
  sync(playing: boolean, title: string, artist: string, percent: number): void {
    if (!this.available() || !playing) {
      if (this.active) {
        this.stop();
      }
      return;
    }
    const pct = Math.max(0, Math.min(100, Math.round(percent)));
    const signature = `${title}|${artist}|${playing ? 1 : 0}`;
    if (this.active && signature === this.lastSignature &&
      Math.abs(pct - this.lastPercent) < STEP_PERCENT) {
      return; // 步进内不刷
    }
    const content: string = `${title} - ${artist}`;
    const data: liveViewManager.LiveViewData = {
      primary: {
        title: title,
        content: [{ text: artist }],
        layoutData: {
          layoutType: liveViewManager.LayoutType.LAYOUT_TYPE_PROGRESS,
          progress: pct
        } as liveViewManager.ProgressLayout
      } as liveViewManager.PrimaryData,
      capsule: {
        type: liveViewManager.CapsuleType.CAPSULE_TYPE_PROGRESS,
        status: 0,
        max: 100,
        progress: pct
      } as liveViewManager.ProgressCapsule
    } as liveViewManager.LiveViewData;
    const lv: liveViewManager.LiveView = {
      id: LV_ID,
      event: 'PROGRESS',
      liveViewData: data
    };
    if (!this.active) {
      liveViewManager.isLiveViewEnabled().then((on: boolean): void => {
        if (!on) {
          hilog.info(DOMAIN, TAG, 'live view disabled by user');
          this.disabled = true;
          return;
        }
        liveViewManager.startLiveView(lv).then((r: liveViewManager.LiveViewResult): void => {
          this.active = true;
          this.lastPercent = pct;
          this.lastSignature = signature;
          hilog.info(DOMAIN, TAG, 'start %{public}d %{public}s', r.resultCode, r.message);
        }).catch((e: Error): void => {
          hilog.warn(DOMAIN, TAG, 'start fail %{public}s(场景权未授?真机+AGC 后生效)', e.message);
          this.disabled = true;
        });
      }).catch((e: Error): void => {
        hilog.warn(DOMAIN, TAG, 'isLiveViewEnabled fail %{public}s', e.message);
        this.disabled = true;
      });
    } else {
      liveViewManager.updateLiveView(lv).then((r: liveViewManager.LiveViewResult): void => {
        this.lastPercent = pct;
        this.lastSignature = signature;
        hilog.debug(DOMAIN, TAG, 'update %{public}d', r.resultCode);
      }).catch((e: Error): void => {
        hilog.warn(DOMAIN, TAG, 'update fail %{public}s', e.message);
      });
    }
  }

  stop(): void {
    if (!this.active) {
      return;
    }
    this.active = false;
    this.lastPercent = -99;
    this.lastSignature = '';
    const lv: liveViewManager.LiveView = {
      id: LV_ID,
      event: 'PROGRESS',
      liveViewData: {
        primary: {
          title: 'x'
        } as liveViewManager.PrimaryData
      } as liveViewManager.LiveViewData
    };
    liveViewManager.stopLiveView(lv).then((r: liveViewManager.LiveViewResult): void => {
      hilog.info(DOMAIN, TAG, 'stop %{public}d', r.resultCode);
    }).catch((e: Error): void => {
      hilog.warn(DOMAIN, TAG, 'stop fail %{public}s', e.message);
    });
  }
}

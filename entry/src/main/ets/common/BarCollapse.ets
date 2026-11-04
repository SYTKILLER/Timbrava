// 迷你条滚动折叠链路(全局单例):页签内容滚动方向累积 → Index 侧 HdsTabsController.applyMiniBarStyle。
// 挂载点:各页签主滚动容器 onDidScroll(每帧偏移)/onScrollStop(清累积);
// 折叠态镜像由 HdsTabs onBarStyleChange 回写(覆盖 USER_CLICK 原生展开),不回环通知。
import { hilog } from '@kit.PerformanceAnalysisKit';

const COLLAPSE_THRESHOLD = 24; // 向列表尾部浏览累积位移阈值(vp),约半行列表高
const EXPAND_THRESHOLD = 12;   // 向列表头部回滚累积位移阈值(vp)

const TAG = '[Timbrava][BarCollapse]';
const DOMAIN = 0x0001;

export class BarCollapse {
  private static acc: number = 0;
  private static collapsed: boolean = false;
  private static applier: ((collapsed: boolean) => void) | null = null;

  static bind(applier: (collapsed: boolean) => void): void {
    BarCollapse.applier = applier;
  }

  static isCollapsed(): boolean {
    return BarCollapse.collapsed;
  }

  // 主动设置折叠态;notify=true 时驱动 applyMiniBarStyle(Index 挂钩),false 仅同步镜像(动效回调回写)
  static sync(collapsed: boolean, notify: boolean): void {
    if (BarCollapse.collapsed === collapsed) {
      return;
    }
    BarCollapse.collapsed = collapsed;
    BarCollapse.acc = 0;
    hilog.info(DOMAIN, TAG, 'sync collapsed=%{public}d notify=%{public}d', collapsed ? 1 : 0, notify ? 1 : 0);
    if (notify && BarCollapse.applier !== null) {
      BarCollapse.applier(collapsed);
    }
  }

  // onDidScroll 每帧偏移:正值=向列表尾部浏览(内容上移),负值=向头部回滚
  static feed(deltaY: number): void {
    if (deltaY === 0) {
      return;
    }
    hilog.debug(DOMAIN, TAG, 'feed d=%{public}d acc=%{public}d', Math.round(deltaY), Math.round(BarCollapse.acc));
    // 方向反转清残量,避免跨方向累积误触发
    if (BarCollapse.acc * deltaY < 0) {
      BarCollapse.acc = 0;
    }
    BarCollapse.acc += deltaY;
    if (!BarCollapse.collapsed && BarCollapse.acc >= COLLAPSE_THRESHOLD) {
      BarCollapse.sync(true, true);
    } else if (BarCollapse.collapsed && BarCollapse.acc <= -EXPAND_THRESHOLD) {
      BarCollapse.sync(false, true);
    }
  }

  // 滚动停止清累积(快速轻扫不过阈不残留)
  static settle(): void {
    BarCollapse.acc = 0;
  }
}

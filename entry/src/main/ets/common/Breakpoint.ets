// 断点服务(0.22.0 多端适配公共底座:折叠屏/平板/PC 三端共用)。
// 主通道 window.on('windowSizeChange')(官方 bpta-multi-device-responsive-layout 推荐),防抖=值无变化不写;
// avoidAreaChange(旋转/折叠必触发)作双保险由 AppTheme.watchAvoidAreas 回调里调 recompute。
// foldStatusChange 只做悬停态功能分支(foldHover token),不参与布局判定(官方 screen-diff 结论)。
import { display, window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = '[Timbrava][Breakpoint]';
const DOMAIN = 0x0001;

export class Breakpoint {
  private static inited: boolean = false;
  private static lastWVp: number = -1;
  private static lastHover: boolean = false;

  // EntryAbility.onWindowStageCreate(loadContent 回调内)调用
  static init(mainWindow: window.Window): void {
    if (Breakpoint.inited) {
      return;
    }
    Breakpoint.inited = true;
    Breakpoint.recompute(mainWindow);
    try {
      mainWindow.on('windowSizeChange', (_sz: window.Size): void => {
        Breakpoint.recompute(mainWindow);
      });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'windowSizeChange watch fail %{public}s', (e as Error).message);
    }
    if (display.isFoldable()) {
      Breakpoint.syncFoldHover();
      try {
        display.on('foldStatusChange', (_st: display.FoldStatus): void => {
          Breakpoint.syncFoldHover();
        });
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'foldStatusChange watch fail %{public}s', (e as Error).message);
      }
    }
  }

  // 窗口宽 vp → 断点 tokens(写 AppStorage,@StorageProp 消费)。
  // 取 drawableRect(自由窗口下排除标题栏,PC 布局面积以可绘制区为准),缺失回落 windowRect。
  static recompute(mainWindow: window.Window): void {
    try {
      const props = mainWindow.getWindowProperties();
      const drawable = props.drawableRect;
      const rect = (drawable !== undefined && drawable !== null && drawable.width > 0)
        ? drawable : props.windowRect;
      const density = display.getDefaultDisplaySync().densityPixels;
      const d = density > 0 ? density : 3;
      const wVp = rect.width / d;
      if (Math.abs(wVp - Breakpoint.lastWVp) < 0.5 && Breakpoint.lastWVp >= 0) {
        return; // 防抖:拖拽每帧触发,值未变不重写(避免全页重布局)
      }
      Breakpoint.lastWVp = wVp;
      const bp = wVp >= 1440 ? 'xl' : wVp >= 840 ? 'lg' : wVp >= 600 ? 'md' : 'sm';
      const hVp = rect.height / d;
      AppStorage.setOrCreate('winWVp', Math.round(wVp));
      AppStorage.setOrCreate('winHVp', Math.round(hVp));
      AppStorage.setOrCreate('bp', bp);
      AppStorage.setOrCreate('bpWide', bp === 'lg' || bp === 'xl');
      AppStorage.setOrCreate('bpMdPlus', bp !== 'sm');
      hilog.info(DOMAIN, TAG, 'bp=%{public}s w=%{public}dvp h=%{public}dvp', bp, Math.round(wVp), Math.round(hVp));
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'recompute fail %{public}s', (e as Error).message);
    }
  }

  // 悬停态(半折叠听歌,FOLD_STATUS_HALF_FOLDED=3):播放页切悬停布局
  static syncFoldHover(): void {
    let hover = false;
    try {
      hover = display.isFoldable() &&
        display.getFoldStatus() === display.FoldStatus.FOLD_STATUS_HALF_FOLDED;
    } catch (e) {
      // 保持 false
    }
    if (hover === Breakpoint.lastHover) {
      return;
    }
    Breakpoint.lastHover = hover;
    AppStorage.setOrCreate('foldHover', hover);
    hilog.info(DOMAIN, TAG, 'foldHover=%{public}s', String(hover));
  }

  // 折痕上缘 vp(悬停布局上半屏高度上限;无折痕/异常回落 0)
  static creaseTopVp(): number {
    try {
      const region = display.getCurrentFoldCreaseRegion();
      const rects = region.creaseRects;
      if (rects.length > 0) {
        const density = display.getDefaultDisplaySync().densityPixels;
        const d = density > 0 ? density : 3;
        return rects[0].top / d;
      }
    } catch (e) {
      // 回落 0
    }
    return 0;
  }
}

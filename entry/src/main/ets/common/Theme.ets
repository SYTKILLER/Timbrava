// 主题应用:跟随系统/浅色/深色/纯黑。纯黑 = 深色 + 页面背景 token 覆盖 #000000。
import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { window, display } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SettingsService, ThemeMode } from '../service/SettingsService';

const TAG = '[Timbrava][Theme]';
const DOMAIN = 0x0001;

export class AppTheme {
  static apply(ctx: common.UIAbilityContext | null): void {
    const mode = SettingsService.get().themeMode;
    let cm = ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
    let bgOverride = '';
    if (mode === ThemeMode.LIGHT) {
      cm = ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
    } else if (mode === ThemeMode.DARK) {
      cm = ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    } else if (mode === ThemeMode.BLACK) {
      cm = ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
      bgOverride = '#000000';
    }
    if (ctx !== null) {
      try {
        ctx.getApplicationContext().setColorMode(cm);
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'setColorMode fail %{public}s', (e as Error).message);
      }
    }
    AppStorage.setOrCreate('themePageBg', bgOverride);
    AppStorage.setOrCreate('themeVer', (AppStorage.get<number>('themeVer') ?? 0) + 1);
    hilog.info(DOMAIN, TAG, 'theme applied mode=%{public}s', mode);
  }

  // 页面安全区:沉浸式后需要避让状态栏/导航条(px → vp)
  // 结果同步写 AppStorage token(topSafeVp/bottomSafeVp):兄弟组件(MiniPlayer 等)经 @StorageProp 绑定,
  // 底部避让硬性下限 28vp。
  static async safeAreas(ctx: common.Context | null): Promise<SafeAreaResult> {
    const fallback = new SafeAreaResult();
    try {
      if (ctx === null) {
        return fallback;
      }
      const win = await window.getLastWindow(ctx);
      const sys = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const nav = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      const density = display.getDefaultDisplaySync().densityPixels;
      fallback.topVp = sys.topRect.height / (density > 0 ? density : 3);
      fallback.bottomVp = Math.max(nav.bottomRect.height / (density > 0 ? density : 3), 28);
    } catch (e) {
      // 保持回退值
    }
    AppStorage.setOrCreate('topSafeVp', fallback.topVp);
    AppStorage.setOrCreate('bottomSafeVp', fallback.bottomVp);
    return fallback;
  }

  // 悬浮页签(HdsTabs barFloatingStyle)总占位:栏高 56 + barBottomMargin 预留 8
  static readonly FLOAT_BAR_GAP: number = 64;

  // 实时监听避让区变化(参考 PixLume AvoidanceManager):全屏布局生效/旋转/折叠屏时
  // 系统会触发 avoidAreaChange,把最新值回写 AppStorage,页面经 @StorageProp 自动刷新。
  // 必须监听:safeAreas 只在启动读一次,会早于 setWindowLayoutFullScreen 生效拿到旧值。
  static watchAvoidAreas(ctx: common.Context | null): void {
    try {
      if (ctx === null) {
        return;
      }
      window.getLastWindow(ctx).then((win: window.Window): void => {
        win.on('avoidAreaChange', (data: window.AvoidAreaOptions): void => {
          const density = display.getDefaultDisplaySync().densityPixels;
          const d = density > 0 ? density : 3;
          if (data.type === window.AvoidAreaType.TYPE_SYSTEM) {
            const topVp = data.area.topRect.height / d;
            AppStorage.setOrCreate('topSafeVp', topVp);
            hilog.info(DOMAIN, TAG, 'avoidArea top=%{public}d', Math.round(topVp));
          } else if (data.type === window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR) {
            const bottomVp = Math.max(data.area.bottomRect.height / d, 28);
            AppStorage.setOrCreate('bottomSafeVp', bottomVp);
          }
        });
      });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'watchAvoidAreas fail %{public}s', (e as Error).message);
    }
  }
}

export class SafeAreaResult {
  topVp: number = 36;
  bottomVp: number = 28;
}

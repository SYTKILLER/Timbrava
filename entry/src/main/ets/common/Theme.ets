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
      return fallback;
    } catch (e) {
      return fallback;
    }
  }
}

export class SafeAreaResult {
  topVp: number = 36;
  bottomVp: number = 28;
}

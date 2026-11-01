import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { PlayerController } from '../service/PlayerController';
import { AppTheme } from '../common/Theme';

const DOMAIN = 0x0001;
const TAG = '[Timbrava][Ability]';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'Ability onCreate');
    AppStorage.setOrCreate('playerVer', 0);
    AppStorage.setOrCreate('posVer', 0);
    AppStorage.setOrCreate('libVer', 0);
    AppStorage.setOrCreate('queueVer', 0);
    AppStorage.setOrCreate('scanVer', 0);
    AppStorage.setOrCreate('themeVer', 0);
    AppStorage.setOrCreate('prefThemeMode', 'system');
    AppStorage.setOrCreate('themePageBg', '');
    PlayerController.get().init(this.context).then((): void => {
      hilog.info(DOMAIN, TAG, 'controller ready');
      AppTheme.apply(this.context);
    });
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, TAG, 'onWindowStageCreate');
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'Failed to load content: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, TAG, 'loadContent ok');
      // 沉浸式:必须在 loadContent 完成回调内调用(过早静默失败 1300002)
      const mainWin = windowStage.getMainWindowSync();
      mainWin.setWindowLayoutFullScreen(true).then((): void => {
        hilog.info(DOMAIN, TAG, 'layoutFullScreen on');
      }).catch((e: Error): void => {
        hilog.warn(DOMAIN, TAG, 'layoutFullScreen fail %{public}s', e.message);
      });
      AppTheme.apply(this.context);
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, 'onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, TAG, 'onForeground');
  }

  onBackground(): void {
    hilog.info(DOMAIN, TAG, 'onBackground');
    PlayerController.get().persistAll();
  }
}

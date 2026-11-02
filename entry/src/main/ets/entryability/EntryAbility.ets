import { AbilityConstant, common, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { PlayerController } from '../service/PlayerController';
import { AppTheme } from '../common/Theme';
import { SettingsService } from '../service/SettingsService';
import { ScanService } from '../data/ScanService';
import { Db } from '../data/Db';
import { LibraryStore } from '../data/LibraryStore';
import { QueueService, } from '../service/QueueService';
import { RepeatMode } from '../data/Model';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DBG_DOMAIN = 0x0001;
const DBG_TAG = '[Timbrava][DebugCmd]';

// 调试直通命令(want.parameters,验证通道;正式流程不触发)
async function runDebugCommands(ctx: common.UIAbilityContext, params: Record<string, Object>): Promise<void> {
  const player = PlayerController.get();
  const get = (k: string): string => {
    const v = params[k];
    return v === undefined || v === null ? '' : String(v);
  };
  try {
    if (get('debugArtFix') === '1') {
      await Db.get().migrateArtUri();
      await LibraryStore.get().reload();
    }
    const theme = get('debugTheme');
    if (theme.length > 0) {
      await SettingsService.get().setThemeMode(theme);
      AppTheme.apply(ctx);
    }
    if (get('debugDump') === '1') {
      await Db.get().dumpArtPaths();
    }
    if (get('debugImport') === '1') {
      await ScanService.get().ensureSandboxRoot();
      await ScanService.get().importFromHost();
    }
    if (get('debugScan') === '1') {
      await ScanService.get().rescan();
    }
    const playIdx = get('debugPlay');
    if (playIdx.length > 0) {
      const lib = LibraryStore.get();
      if (lib.songs.length > 0) {
        const q = QueueService.get();
        q.setQueueNow(lib.songs, parseInt(playIdx, 10), '调试全库');
        await player.playQueueIndex(q.locateCurrent());
      } else {
        hilog.warn(DBG_DOMAIN, DBG_TAG, 'debugPlay but library empty');
      }
    }
    if (get('debugPause') === '1') {
      await player.playPause();
    }
    if (get('debugNext') === '1') {
      await player.playNext();
    }
    if (get('debugPrev') === '1') {
      await player.playPrev();
    }
    const seekMs = get('debugSeek');
    if (seekMs.length > 0) {
      player.seekTo(parseInt(seekMs, 10));
    }
    const repeat = get('debugRepeat');
    if (repeat.length > 0) {
      player.setRepeat(parseInt(repeat, 10) as RepeatMode);
    }
    if (get('debugShuffle') === '1') {
      QueueService.get().toggleShuffle();
    }
    if (get('debugFav') === '1') {
      player.toggleFavorite();
    }
  } catch (e) {
    hilog.error(DBG_DOMAIN, DBG_TAG, 'runDebugCommands fail %{public}s', (e as Error).message);
  }
}

function wantParamsOf(want: Want): Record<string, Object> {
  const p: Record<string, Object> = {};
  const keys = Object.keys(want.parameters ?? {});
  for (const k of keys) {
    p[k] = (want.parameters as Record<string, Object>)[k];
  }
  return p;
}

const DOMAIN = 0x0001;
const TAG = '[Timbrava][Ability]';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'Ability onCreate');
    AppStorage.setOrCreate('uiAbilityContext', this.context);
    AppStorage.setOrCreate('playerVer', 0);
    AppStorage.setOrCreate('posVer', 0);
    AppStorage.setOrCreate('libVer', 0);
    AppStorage.setOrCreate('queueVer', 0);
    AppStorage.setOrCreate('scanVer', 0);
    AppStorage.setOrCreate('themeVer', 0);
    AppStorage.setOrCreate('rgScanVer', 0);
    AppStorage.setOrCreate('prefThemeMode', 'system');
    AppStorage.setOrCreate('themePageBg', '');
    PlayerController.get().init(this.context).then(async (): Promise<void> => {
      hilog.info(DOMAIN, TAG, 'controller ready');
      AppTheme.apply(this.context);
      await runDebugCommands(this.context, wantParamsOf(want));
    });
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'onNewWant');
    runDebugCommands(this.context, wantParamsOf(want));
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

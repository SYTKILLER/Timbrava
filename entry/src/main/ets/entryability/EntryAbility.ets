import { AbilityConstant, common, Configuration, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { PlayerController } from '../service/PlayerController';
import { AppTheme } from '../common/Theme';
import { SettingsService } from '../service/SettingsService';
import { ScanService } from '../data/ScanService';
import { RgScanner } from '../service/RgScanner';
import { Db } from '../data/Db';
import { LibraryStore } from '../data/LibraryStore';
import { QueueService, } from '../service/QueueService';
import { RepeatMode } from '../data/Model';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { fileIo as fs } from '@kit.CoreFileKit';

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
    if (get('debugSeedRaw') === '1') {
      // 验证通道:rawfile 内置 mp3/flac 语料落沙箱
      await ScanService.get().ensureSandboxRoot();
      await ScanService.get().seedRawfileCorpus();
    }
    if (get('debugImportUris') === '1') {
      // 验证通道:沙箱音频以 file:// URI 走「导入即入库」代码路径(模拟器无 AudioViewPicker UI)
      const added = await ScanService.get().debugImportSandboxUris();
      hilog.info(DBG_DOMAIN, DBG_TAG, 'debugImportUris added=%{public}d', added);
    }
    if (get('debugUriRoot') === '1') {
      // 验证通道:沙箱音频登记为 file:// URI 根(picker 'file' 根同链路)
      await ScanService.get().ensureSandboxRoot();
      await ScanService.get().registerSandboxFileUriRoots();
    }
    if (get('debugGenCorpus') === '1') {
      // SELinux 拦 shell 写沙箱时的语料通道:应用内生成正弦波 WAV+CUE
      await ScanService.get().ensureSandboxRoot();
      await ScanService.get().genDebugCorpus();
      await ScanService.get().rescan();
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
      const q = QueueService.get();
      hilog.info(DBG_DOMAIN, DBG_TAG, 'queue state n=%{public}d idx=%{public}d repeat=%{public}d shuffled=%{public}s mode=%{public}s',
        q.list.length, q.currentOrderIndex, q.repeat as number, String(q.shuffled), q.playMode());
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
    const speed = get('debugSpeed');
    if (speed.length > 0) {
      await player.setSpeed(parseFloat(speed));
    }
    if (get('debugAb') === '1') {
      hilog.info(DBG_DOMAIN, DBG_TAG, 'ab -> %{public}s', player.setAbPoint());
    }
    if (get('debugSkipSilence') === '1') {
      await player.toggleSkipSilence();
    }
    if (get('debugRg') === '1') {
      hilog.info(DBG_DOMAIN, DBG_TAG, 'debugRg trigger');
      RgScanner.get().scan(LibraryStore.get().songs);
    }
    if (get('debugRgCancel') === '1') {
      RgScanner.get().cancel();
    }
    if (get('debugDup') === '1') {
      // 造重复语料:同内容跨路径文件 + 重扫(0.12.0 hash 查重验证:期望 deduped 跳过)
      const dir = `${ctx.filesDir}/music`;
      const dst = `${dir}/Dup_Song.flac`;
      try {
        if (!fs.accessSync(dst)) {
          // 语料源回退:取现存的任一语料文件(旧 Song16_441.flac 可能已不在)
          const srcs = [`${dir}/Song16_441.flac`, `${dir}/Test_Tone.flac`, `${dir}/Moved_Tone.flac`, `${dir}/dbg_a.wav`];
          let src = '';
          for (const s of srcs) {
            if (fs.accessSync(s)) {
              src = s;
              break;
            }
          }
          if (src.length > 0) {
            fs.copyFileSync(src, dst);
            hilog.info(DBG_DOMAIN, DBG_TAG, 'dup file created from %{public}s', src);
          } else {
            hilog.warn(DBG_DOMAIN, DBG_TAG, 'dup create skip: no corpus source');
          }
        }
      } catch (e) {
        hilog.warn(DBG_DOMAIN, DBG_TAG, 'dup create fail %{public}s', (e as Error).message);
      }
      await ScanService.get().rescan();
    }
    if (get('debugMove') === '1') {
      // 造移动场景:重命名语料文件 + 重扫(0.12.0 hash 移动认领验证:期望 relinked 且关系保留)
      const dir = `${ctx.filesDir}/music`;
      try {
        if (fs.accessSync(`${dir}/Test_Tone.flac`)) {
          fs.renameSync(`${dir}/Test_Tone.flac`, `${dir}/Moved_Tone.flac`);
          hilog.info(DBG_DOMAIN, DBG_TAG, 'move: Test_Tone.flac -> Moved_Tone.flac');
        } else if (fs.accessSync(`${dir}/Moved_Tone.flac`)) {
          fs.renameSync(`${dir}/Moved_Tone.flac`, `${dir}/Test_Tone.flac`);
          hilog.info(DBG_DOMAIN, DBG_TAG, 'move: Moved_Tone.flac -> Test_Tone.flac');
        } else {
          hilog.warn(DBG_DOMAIN, DBG_TAG, 'move skip: no corpus source');
        }
      } catch (e) {
        hilog.warn(DBG_DOMAIN, DBG_TAG, 'move fail %{public}s', (e as Error).message);
      }
      await ScanService.get().rescan();
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
  // 服务卡片(M5) router 事件:postCardAction params 打包在 want.parameters.params(JSON 串)
  const cardParams = p['params'];
  if (typeof cardParams === 'string' && cardParams.length > 0) {
    try {
      const inner = JSON.parse(cardParams) as Record<string, Object>;
      const cmd = inner['cardCmd'];
      if (typeof cmd === 'string' && cmd.length > 0) {
        p['cardCmd'] = cmd;
      }
    } catch (e) {
      hilog.warn(DBG_DOMAIN, DBG_TAG, 'card params parse fail');
    }
  }
  return p;
}

// 服务卡片控制命令(toggle/next/prev):与 debug 通道共用 want 参数管线
async function runCardCommands(params: Record<string, Object>): Promise<void> {
  const cmd = params['cardCmd'];
  if (typeof cmd !== 'string' || cmd.length === 0) {
    return;
  }
  const player = PlayerController.get();
  hilog.info(DBG_DOMAIN, DBG_TAG, 'card cmd %{public}s', cmd);
  if (cmd === 'toggle') {
    await player.playPause();
  } else if (cmd === 'next') {
    await player.playNext();
  } else if (cmd === 'prev') {
    await player.playPrev();
  }
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
      // 重启后激活已导入 URI 歌曲的持久化授权(否则 file://docs 音频不可读)
      await ScanService.get().activateImportedUriPermissions();
      const params = wantParamsOf(want);
      await runCardCommands(params);
      await runDebugCommands(this.context, params);
    });
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'onNewWant');
    const params = wantParamsOf(want);
    runCardCommands(params).then((): Promise<void> => runDebugCommands(this.context, params));
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'Ability onDestroy');
  }

  // 系统配置变更(深浅色切换/语言):只重算主题覆盖位,不重设 colorMode(否则无限递归)
  onConfigurationUpdate(newConfig: Configuration): void {
    if (!AppTheme.isReapplyingColorMode()) {
      AppTheme.recomputeOverride(this.context);
    }
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
      mainWin.setWindowLayoutFullScreen(true).then(async (): Promise<void> => {
        hilog.info(DOMAIN, TAG, 'layoutFullScreen on');
        // 全屏生效后再读一次避让区(此前读的是全屏前的旧值),并挂实时监听
        await AppTheme.safeAreas(this.context);
        AppTheme.watchAvoidAreas(this.context);
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

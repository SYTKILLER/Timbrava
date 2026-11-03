// 服务卡片扩展(M5):formId 持久化到 RDB(跨进程共享给 UIAbility 侧推送)。
// 卡片真实数据由 PlayerController(应用进程)formProvider.updateForm 推送;
// 本类只管 formId 生命周期与初始占位数据。
import { FormExtensionAbility, formBindingData, formInfo } from '@kit.FormKit';
import { Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Db } from '../data/Db';

const TAG = '[Timbrava][FormAbility]';
const DOMAIN = 0x0001;
const KEY_FORM_IDS = 'cardFormIds';

export default class EntryFormAbility extends FormExtensionAbility {
  private async loadIds(): Promise<string[]> {
    await Db.get().init(this.context);
    const raw = await Db.get().getSetting(KEY_FORM_IDS, '');
    return raw.length > 0 ? raw.split(',').filter((s: string): boolean => s.length > 0) : [];
  }

  private async saveIds(ids: string[]): Promise<void> {
    await Db.get().setSetting(KEY_FORM_IDS, ids.join(','));
  }

  onAddForm(want: Want): formBindingData.FormBindingData {
    // 初始占位;真实状态由应用进程推送(应用可能未启动,不读 PlayerController)
    const formId = want.parameters?.[formInfo.FormParam.IDENTITY_KEY] as string;
    this.loadIds().then((ids: string[]): void => {
      if (typeof formId === 'string' && formId.length > 0 && ids.indexOf(formId) < 0) {
        ids.push(formId);
        this.saveIds(ids);
        hilog.info(DOMAIN, TAG, 'card added %{public}s total=%{public}d', formId, ids.length);
      }
    });
    const data: Record<string, Object> = {
      'title': '', 'artist': '', 'playing': false, 'hasSong': false
    };
    return formBindingData.createFormBindingData(data);
  }

  onRemoveForm(formId: string): void {
    this.loadIds().then((ids: string[]): void => {
      const idx = ids.indexOf(formId);
      if (idx >= 0) {
        ids.splice(idx, 1);
        this.saveIds(ids);
        hilog.info(DOMAIN, TAG, 'card removed %{public}s total=%{public}d', formId, ids.length);
      }
    });
  }

  onCastToNormalForm(formId: string): void {
    hilog.info(DOMAIN, TAG, 'cast to normal %{public}s', formId);
  }

  onUpdateForm(formId: string): void {
    // 系统定点/定时刷新:无应用进程数据可推,保持现状(播放状态变化由应用侧主动推)
    hilog.debug(DOMAIN, TAG, 'onUpdateForm %{public}s', formId);
  }

  onFormEvent(formId: string, message: string): void {
    // 卡片 message 事件不使用(控制走 router 到 EntryAbility)
    hilog.debug(DOMAIN, TAG, 'onFormEvent %{public}s %{public}s', formId, message);
  }

  onAcquireFormState?(want: Want): formInfo.FormState {
    return formInfo.FormState.UNKNOWN;
  }
}

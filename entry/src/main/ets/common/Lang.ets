// 多语言取值助手:服务层/模板串动态取 string 资源($r 仅 UI 层可用,此处经 resourceManager)。
// L($r('app.string.key'), ...params) → 已格式化字符串;上下文缺失或异常返回空串兜底。
// 说明:不用 getStringSync(res, ...args) 的内置格式化(要求 %1$s 位置型占位符,普通 %s 多参会抛
// "Failed to format" 异常)——取原始串后按 %s/%d 顺序手工替换,模板写法与 C/hilog 习惯一致。
import { common } from '@kit.AbilityKit';

export function Ls(v: ResourceStr): string {
  if (typeof v === 'string') {
    return v;
  }
  return L(v);
}

export function L(res: Resource, ...params: Array<string | number>): string {
  const ctx = AppStorage.get<common.UIAbilityContext>('uiAbilityContext') ?? null;
  if (ctx === null) {
    return '';
  }
  let out = '';
  try {
    out = ctx.resourceManager.getStringSync(res);
  } catch (e) {
    return '';
  }
  for (const p of params) {
    const v = String(p);
    const idxS = out.indexOf('%s');
    const idxD = out.indexOf('%d');
    let idx = -1;
    if (idxS >= 0 && idxD >= 0) {
      idx = Math.min(idxS, idxD);
    } else if (idxS >= 0) {
      idx = idxS;
    } else {
      idx = idxD;
    }
    if (idx < 0) {
      break; // 占位符耗尽,剩余参数忽略
    }
    out = out.substring(0, idx) + v + out.substring(idx + 2);
  }
  return out;
}

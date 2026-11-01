// 引擎层公共类型:AudioEngine 抽象的参数/事件定义。
// 契约(Flick 式):命令进、事件出;两实现 SystemEngine(AVPlayer)/ LosslessEngine(Native)。

export enum EngineKind {
  SYSTEM = 0,
  LOSSLESS = 1,
}

export class EngineTrackInfo {
  sampleRate: number = 0;
  channels: number = 0;
  bitDepth: number = 0;
  durationMs: number = 0;
  codec: string = '';

  static EMPTY(): EngineTrackInfo {
    return new EngineTrackInfo();
  }
}

export enum EngineEventKind {
  TRACK_END = 0,     // 曲目自然播完
  ERROR = 1,         // 引擎错误(应回退/提示)
  INTERRUPT = 2,     // 音频焦点中断(force/hint 附带)
  SEEK_DONE = 3,
  UNDERRUN = 4,
}

export class EngineEventData {
  kind: EngineEventKind = EngineEventKind.ERROR;
  hint: number = 0;      // interrupt hint / error code
  message: string = '';

  constructor(kind: EngineEventKind, hint: number, message: string) {
    this.kind = kind;
    this.hint = hint;
    this.message = message;
  }
}

export type EngineEventCb = (ev: EngineEventData) => void;

export interface IAudioEngine {
  getKind(): EngineKind;
  setEventCb(cb: EngineEventCb): void;
  // 打开并准备曲目(uri 或真实路径);成功返回 true
  open(uri: string): Promise<EngineTrackInfo>;
  play(): void;
  pause(): void;
  stop(): void;
  seek(ms: number): void;
  getPositionMs(): number;
  getDurationMs(): number;
  // 引擎自检(如 native so 加载状态)
  available(): boolean;
  release(): void;
}

// 31 段参数均衡器编辑页(#29):竖向滑条逐段编辑 + 内置/自定义预设 + AutoEq 导入。
// 作用域(EQ 按曲目/按专辑):路由参数 EqScopeParam 携带 target(song:{id}/album:{key});
// 无参数 = 全局编辑;有 target 时滑条曲线读写该作用域覆盖,清除后跟随全局。
// 频点公式与 native dspPeqDefaultFreqs 一致(20Hz~16kHz 几何均分);拖动即时下发引擎。
// 0.15.0:预设行 Select 限宽 + 存为预设/导入改 symbol 钮;支持横屏(手动切换钮,归零钮上方)。
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { window, display } from '@kit.ArkUI';
import { SettingsService } from '../../service/SettingsService';
import { Db, EqPresetRow } from '../../data/Db';
import { PlayerController } from '../../service/PlayerController';
import { PEQ_FREQS, flatBands, presetBands, isBuiltinPreset, parseAutoEq } from '../../service/EqPresets';
import { L } from '../../common/Lang';

const TAG = '[Timbrava][Equalizer]';
const DOMAIN = 0x0001;

// 路由参数:作用域覆盖目标
export class EqScopeParam {
  target: string = '';        // 'song:{id}' | 'album:{artist}\u0001{album}';空=全局
  scopeLabel: string = '';    // 展示名(曲名/专辑名)

  constructor(target: string, scopeLabel: string) {
    this.target = target;
    this.scopeLabel = scopeLabel;
  }
}

@CustomDialog
struct EqTextDialog {
  controller?: CustomDialogController;
  title: ResourceStr = '';
  multiLine: boolean = false;
  onConfirm: (text: string) => void = (_t: string): void => {
  };
  @State text: string = '';

  build() {
    Column({ space: 14 }) {
      Text(this.title)
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
      if (this.multiLine) {
        TextArea({ text: this.text, placeholder: $r('app.string.autoeq_placeholder') })
          .height(120)
          .fontSize(12)
          .width('100%')
          .onChange((v: string): void => {
            this.text = v;
          })
      } else {
        TextInput({ text: this.text, placeholder: $r('app.string.preset_name') })
          .height(44)
          .fontSize(14)
          .width('100%')
          .onChange((v: string): void => {
            this.text = v;
          })
      }
      Row({ space: 12 }) {
        Button($r('app.string.str_cancel'))
          .fontSize(14)
          .height(40)
          .layoutWeight(1)
          .fontColor($r('app.color.text_primary'))
          .backgroundColor($r('app.color.badge_bg'))
          .onClick(() => {
            this.controller?.close();
          })
        Button($r('app.string.str_ok'))
          .fontSize(14)
          .height(40)
          .layoutWeight(1)
          .fontColor($r('app.color.on_accent'))
          .backgroundColor($r('app.color.accent'))
          .onClick(() => {
            const t = this.text.trim();
            if (t.length === 0) {
              return;
            }
            this.onConfirm(t);
            this.controller?.close();
          })
      }
      .width('100%')
    }
    .padding(20)
    .borderRadius(16)
    .backgroundColor($r('app.color.card_bg'))
    .width('86%')
  }
}

@Component
export struct EqualizerDest {
  @StorageProp('topSafeVp') topSafeVp: number = 36; // 全屏沉浸后手动避让状态栏
  @StorageProp('bottomSafeVp') bottomSafeVp: number = 28; // 底部避让(≥28)
  @StorageProp('prefEqOn') prefEqOn: boolean = false;
  @StorageProp('prefEqPreset') prefEqPreset: string = 'flat';
  @State bands: number[] = flatBands();
  @State savedPresets: EqPresetRow[] = [];
  // 横屏支持(0.15.0):读取设备当前方向 + 手动切换(圆钮,归零钮上方);横屏横向可见更多调音条
  @State isLandscape: boolean = false;
  private winRef: window.Window | null = null;
  // 作用域(EQ 按曲目/按专辑)
  private scope: EqScopeParam = new EqScopeParam('', '');
  @State hasOverride: boolean = false;
  private saveCtrl: CustomDialogController | null = null;
  private importCtrl: CustomDialogController | null = null;
  private pathStack: NavPathStack | null = null;

  aboutToAppear(): void {
    this.reloadBands();
    this.reloadSaved();
    this.resolveOrientation();
    this.watchDisplay();
  }

  aboutToDisappear(): void {
    this.unwatchDisplay();
    // 离页还原跟随系统(不锁定竖屏,尊重系统自动旋转设置)
    if (this.winRef !== null) {
      this.winRef.setPreferredOrientation(window.Orientation.UNSPECIFIED).catch((): void => {
      });
      this.winRef = null;
    }
    // 恢复 Navigation 分栏判定(进入时强制 Stack 见 onReady)
    AppStorage.setOrCreate('eqFullscreen', false);
  }

  // 获取设备方向:物理屏朝向(display.Orientation)→ 判定横/竖(切换钮图标态)
  private resolveOrientation(): void {
    try {
      const o = display.getDefaultDisplaySync().orientation;
      this.isLandscape = o === display.Orientation.LANDSCAPE || o === display.Orientation.LANDSCAPE_INVERTED;
      hilog.info(DOMAIN, TAG, 'orientation read -> %{public}s', this.isLandscape ? 'landscape' : 'portrait');
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'resolveOrientation fail %{public}s', (e as Error).message);
    }
  }

  // 手动切换横/竖屏(竖→横锁定横屏;横→竖)
  private async toggleOrientation(): Promise<void> {
    try {
      if (this.winRef === null) {
        const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
        this.winRef = await window.getLastWindow(ctx);
      }
      const target = this.isLandscape ? window.Orientation.PORTRAIT : window.Orientation.LANDSCAPE;
      await this.winRef.setPreferredOrientation(target);
      this.isLandscape = !this.isLandscape;
      hilog.info(DOMAIN, TAG, 'orientation -> %{public}s', this.isLandscape ? 'landscape' : 'portrait');
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'toggleOrientation fail %{public}s', (e as Error).message);
    }
  }

  // 旋转落地后的实际方向同步(物理旋转/系统拒绝时兜底);模块级 display.on('change'),离页注销
  private dispCb: ((id: number) => void) | null = null;

  private watchDisplay(): void {
    try {
      this.dispCb = (_id: number): void => {
        this.resolveOrientation();
      };
      display.on('change', this.dispCb);
    } catch (e) {
      this.dispCb = null;
    }
  }

  private unwatchDisplay(): void {
    if (this.dispCb !== null) {
      try {
        display.off('change', this.dispCb);
      } catch (e) {
        // 忽略
      }
      this.dispCb = null;
    }
  }

  private isScoped(): boolean {
    return this.scope.target.length > 0;
  }

  private reloadBands(): void {
    if (this.isScoped()) {
      // 作用域覆盖优先;未覆盖时回落展示全局曲线(保存动作才写覆盖)
      Db.get().getEqAssign(this.scope.target).then((ov: number[] | null): void => {
        this.hasOverride = ov !== null;
        if (ov !== null) {
          this.bands = ov!.slice();
        } else {
          this.bands = this.globalBands();
        }
      });
      return;
    }
    this.bands = this.globalBands();
  }

  private globalBands(): number[] {
    const s = SettingsService.get();
    if (s.eqPreset === 'custom' && s.eqBands.length === 31) {
      return s.eqBands.slice();
    }
    return presetBands(s.eqPreset);
  }

  private reloadSaved(): void {
    Db.get().listEqPresets().then((rows: Array<EqPresetRow>): void => {
      this.savedPresets = rows;
    });
  }

  private async persistBands(): Promise<void> {
    if (this.isScoped()) {
      // 写作用域覆盖并立即对引擎生效(当前曲命中时)
      await Db.get().setEqAssign(this.scope.target, this.bands.slice());
      this.hasOverride = true;
      PlayerController.get().reapplyCurrentDsp();
      hilog.info(DOMAIN, TAG, 'scoped bands saved target=%{public}s', this.scope.target);
      return;
    }
    await SettingsService.get().setEqBands(this.bands.slice());
    hilog.info(DOMAIN, TAG, 'bands saved');
  }

  // 清除作用域覆盖(跟随全局)
  private async clearOverride(): Promise<void> {
    if (!this.isScoped()) {
      return;
    }
    await Db.get().deleteEqAssign(this.scope.target);
    this.hasOverride = false;
    this.bands = this.globalBands();
    PlayerController.get().reapplyCurrentDsp();
    hilog.info(DOMAIN, TAG, 'scope override cleared');
  }

  // 预设选项名(内置 + 自定义保存)
  private presetNames(): string[] {
    const names: string[] = ['flat', 'bass', 'vocal', 'treble', 'rock', 'electronic'];
    for (const p of this.savedPresets) {
      names.push(p.name);
    }
    return names;
  }

  private curPresetLabel(): ResourceStr {
    const p = this.prefEqPreset;
    if (p === 'custom') {
      return $r('app.string.preset_custom');
    }
    const saved = this.savedPresets.find((r: EqPresetRow): boolean => r.name === p);
    if (saved !== undefined) {
      return p;
    }
    if (isBuiltinPreset(p)) {
      return this.builtinLabel(p);
    }
    return $r('app.string.select_preset');
  }

  private builtinLabel(name: string): ResourceStr {
    if (name === 'flat') {
      return $r('app.string.preset_flat');
    }
    if (name === 'bass') {
      return $r('app.string.preset_bass');
    }
    if (name === 'vocal') {
      return $r('app.string.preset_vocal');
    }
    if (name === 'treble') {
      return $r('app.string.preset_treble');
    }
    if (name === 'rock') {
      return $r('app.string.preset_rock');
    }
    if (name === 'electronic') {
      return $r('app.string.preset_electronic');
    }
    return name;
  }

  private async applyPreset(name: string): Promise<void> {
    const saved = this.savedPresets.find((r: EqPresetRow): boolean => r.name === name);
    const bands = saved !== undefined ? saved.bands.slice() : presetBands(name);
    this.bands = bands;
    if (this.isScoped()) {
      // 作用域模式:预设仅作为曲线来源写入覆盖,不动全局设置
      await this.persistBands();
      return;
    }
    await SettingsService.get().setEq(true, name);
    await SettingsService.get().setEqBands(bands);
    hilog.info(DOMAIN, TAG, 'preset -> %{public}s', name);
  }

  private openSaveDialog(): void {
    this.saveCtrl = new CustomDialogController({
      builder: EqTextDialog({
        title: $r('app.string.save_curve_title'),
        multiLine: false,
        onConfirm: (name: string): void => {
          Db.get().saveEqPreset(name, this.bands).then((): void => {
            this.reloadSaved();
            hilog.info(DOMAIN, TAG, 'preset saved %{public}s', name);
          });
        }
      }),
      autoCancel: true,
      customStyle: true
    });
    this.saveCtrl.open();
  }

  private openImportDialog(): void {
    this.importCtrl = new CustomDialogController({
      builder: EqTextDialog({
        title: $r('app.string.import_autoeq'),
        multiLine: true,
        onConfirm: (text: string): void => {
          const bands = parseAutoEq(text);
          if (bands === null) {
            this.getUIContext().getPromptAction().showToast({ message: $r('app.string.autoeq_parse_fail') });
            return;
          }
          this.bands = bands;
          this.persistBands();
          this.getUIContext().getPromptAction().showToast({ message: $r('app.string.autoeq_imported') });
        }
      }),
      autoCancel: true,
      customStyle: true
    });
    this.importCtrl.open();
  }

  private fmtFreq(hz: number): string {
    if (hz >= 1000) {
      return `${Math.round(hz / 100) / 10}k`;
    }
    return `${Math.round(hz)}`;
  }

  build() {
    NavDestination() {
      Column() {
        // 作用域条(EQ 按曲目/按专辑):显示目标 + 清除覆盖
        if (this.isScoped()) {
          Row({ space: 8 }) {
            SymbolGlyph($r('sys.symbol.music_note_list'))
              .fontSize(14)
              .fontColor([$r('app.color.accent')])
            Text(this.scope.scopeLabel)
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            if (this.hasOverride) {
              Button($r('app.string.eq_follow_global'))
                .fontSize(11)
                .height(26)
                .fontColor($r('app.color.text_primary'))
                .backgroundColor($r('app.color.badge_bg'))
                .onClick(() => {
                  this.clearOverride();
                })
            } else {
              Text($r('app.string.eq_scope_hint'))
                .fontSize(10)
                .fontColor($r('app.color.text_secondary'))
            }
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 8 })
        }

        // 开关 + 预设行
        Row({ space: 12 }) {
          Text($r('app.string.equalizer'))
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)
          Text($r('app.string.str_on'))
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
          Toggle({ type: ToggleType.Switch, isOn: this.prefEqOn })
            .selectedColor($r('app.color.accent'))
            .onChange((on: boolean): void => {
              SettingsService.get().setEq(on, SettingsService.get().eqPreset);
              hilog.info(DOMAIN, TAG, 'eq -> %{public}s', String(on));
            })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 8 })

        // 预设行:Select 按内容自适应(限宽防长自定义名吃满),存为预设/导入用 symbol 钮(0.15.0)
        Row({ space: 8 }) {
          Select(this.presetNames().map((n: string): SelectOption => {
            const opt: SelectOption = { value: isBuiltinPreset(n) ? this.builtinLabel(n) : n };
            return opt;
          }))
            .selected(this.prefEqPreset === 'custom' ? -1 : this.presetNames().indexOf(this.prefEqPreset))
            .value(this.curPresetLabel())
            .font({ size: 13 })
            .fontColor($r('app.color.text_primary'))
            .selectedOptionFont({ size: 13 })
            .optionFont({ size: 13 })
            .onSelect((idx: number): void => {
              const names = this.presetNames();
              if (idx >= 0 && idx < names.length) {
                this.applyPreset(names[idx]);
              }
            })
            .constraintSize({ maxWidth: '58%' })

          Blank()

          Button({ stateEffect: true }) {
            SymbolGlyph($r('sys.symbol.save'))
              .fontSize(17)
              .fontColor([$r('app.color.text_primary')])
          }
          .width(34)
          .height(34)
          .backgroundColor($r('app.color.badge_bg'))
          .borderRadius(10)
          .onClick(() => {
            this.openSaveDialog();
          })

          Button({ stateEffect: true }) {
            SymbolGlyph($r('sys.symbol.square_and_arrow_down'))
              .fontSize(17)
              .fontColor([$r('app.color.text_primary')])
          }
          .width(34)
          .height(34)
          .backgroundColor($r('app.color.badge_bg'))
          .borderRadius(10)
          .onClick(() => {
            this.openImportDialog();
          })

          if (this.savedPresets.length > 0) {
            Button({ stateEffect: true }) {
              SymbolGlyph($r('sys.symbol.trash'))
                .fontSize(15)
                .fontColor([$r('app.color.text_secondary')])
            }
            .width(34)
            .height(34)
            .backgroundColor(Color.Transparent)
            .bindMenu(this.deleteMenu())
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 8 })

        // 31 段竖向滑条(横向滚动)
        Scroll() {
          Row({ space: 2 }) {
            ForEach(PEQ_FREQS, (hz: number, i: number) => {
              Column({ space: 4 }) {
                Text(this.bands[i] !== 0 ? `${(Math.round(this.bands[i] * 10) / 10).toFixed(1)}` : '')
                  .fontSize(8)
                  .fontColor($r('app.color.accent'))
                  .height(10)
                Slider({
                  value: this.bands[i],
                  min: -12,
                  max: 12,
                  step: 0.5,
                  style: SliderStyle.OutSet,
                  direction: Axis.Vertical,
                  reverse: false
                })
                  .selectedColor($r('app.color.accent'))
                  .trackColor($r('app.color.divider'))
                  .blockColor($r('app.color.accent'))
                  .blockSize({ width: 14, height: 14 })
                  .width(26)
                  .height(190)
                  .onChange((value: number, mode: SliderChangeMode) => {
                    if (mode === SliderChangeMode.Moving || mode === SliderChangeMode.End ||
                      mode === SliderChangeMode.Click) {
                      const next = this.bands.slice();
                      next[i] = Math.round(value * 2) / 2;
                      this.bands = next;
                      if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                        this.persistBands();
                      }
                    }
                  })
                Text(this.fmtFreq(hz))
                  .fontSize(8)
                  .fontColor($r('app.color.text_secondary'))
                  .maxLines(1)
              }
              .width(30)
              .alignItems(HorizontalAlign.Center)
            }, (hz: number): string => `band_${Math.round(hz)}`)
          }
          .padding({ left: 10, right: 10 })
        }
        .scrollable(ScrollDirection.Horizontal)
        .width('100%')
        .layoutWeight(1)
        .align(Alignment.Center)

        // 底部:横竖屏切换圆钮(16vp,归零钮正上方) + 提示小字/全部归零;底部避让 ≥28vp(0.15.0)
        Column({ space: 4 }) {
          Row() {
            Blank()
            Button({ stateEffect: true }) {
              SymbolGlyph($r('sys.symbol.rotate_left'))
                .fontSize(10)
                .fontColor([this.isLandscape ? $r('app.color.accent') : $r('app.color.text_primary')])
            }
            .width(16)
            .height(16)
            .borderRadius(8)
            .padding(0)
            .backgroundColor(Color.Transparent)
            .responseRegion({ x: -12, y: -12, width: 40, height: 40 }) // 视觉 16vp,热区扩到 40vp(最小可点目标)
            .onClick(() => {
              this.toggleOrientation();
            })
          }
          .width('100%')

          Row({ space: 12 }) {
            Text($r('app.string.eq_hint'))
              .fontSize(11)
              .fontColor($r('app.color.text_secondary'))
            Blank()
            Button($r('app.string.reset_all'))
              .fontSize(12)
              .height(30)
              .fontColor($r('app.color.text_primary'))
              .backgroundColor($r('app.color.badge_bg'))
              .onClick(() => {
                this.bands = flatBands();
                this.persistBands();
              })
          }
          .width('100%')
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 6, bottom: Math.max(this.bottomSafeVp, 28) })
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.page_bg'))
    }
    .padding({ top: this.topSafeVp })
    .title(this.scope.target.startsWith('album:') ? $r('app.string.eq_scope_album')
      : this.isScoped() ? $r('app.string.eq_scope_song') : $r('app.string.equalizer'))
    .onReady((ctx: NavDestinationContext): void => {
      this.pathStack = ctx.pathStack;
      // EQ 页全屏:强制 Navigation Stack(横屏宽屏时 Auto 分栏会把下层页面露在左侧,0.15.1)
      AppStorage.setOrCreate('eqFullscreen', true);
      const p = ctx.pathInfo.param as EqScopeParam;
      if (p !== null && p !== undefined && p instanceof EqScopeParam && p.target.length > 0) {
        this.scope = p;
        this.reloadBands();
        hilog.info(DOMAIN, TAG, 'scoped eq target=%{public}s', p.target);
      }
    })
  }

  @Builder
  deleteMenu() {
    Menu() {
      ForEach(this.savedPresets, (p: EqPresetRow) => {
        MenuItem({ content: L($r('app.string.delete_preset'), p.name) })
          .onClick(() => {
            Db.get().deleteEqPreset(p.id).then((): void => {
              this.reloadSaved();
              hilog.info(DOMAIN, TAG, 'preset deleted %{public}s', p.name);
            });
          })
      }, (p: EqPresetRow): string => `del_${p.id}`)
    }
  }
}

@Builder
export function EqualizerBuilder() {
  EqualizerDest()
}

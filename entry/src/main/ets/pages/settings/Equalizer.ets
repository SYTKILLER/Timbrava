// 31 段参数均衡器编辑页(#29):竖向滑条逐段编辑 + 内置/自定义预设 + AutoEq 导入。
// 频点公式与 native dspPeqDefaultFreqs 一致(20Hz~16kHz 几何均分);拖动即时下发引擎。
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SettingsService } from '../../service/SettingsService';
import { Db, EqPresetRow } from '../../data/Db';
import { PEQ_FREQS, flatBands, presetBands, isBuiltinPreset, parseAutoEq } from '../../service/EqPresets';
import { L } from '../../common/Lang';

const TAG = '[Timbrava][Equalizer]';
const DOMAIN = 0x0001;

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
  @StorageProp('prefEqOn') prefEqOn: boolean = false;
  @StorageProp('prefEqPreset') prefEqPreset: string = 'flat';
  @State bands: number[] = flatBands();
  @State savedPresets: EqPresetRow[] = [];
  private saveCtrl: CustomDialogController | null = null;
  private importCtrl: CustomDialogController | null = null;
  private pathStack: NavPathStack | null = null;

  aboutToAppear(): void {
    this.reloadBands();
    this.reloadSaved();
  }

  private reloadBands(): void {
    const s = SettingsService.get();
    if (s.eqPreset === 'custom' && s.eqBands.length === 31) {
      this.bands = s.eqBands.slice();
    } else {
      this.bands = presetBands(s.eqPreset);
    }
  }

  private reloadSaved(): void {
    Db.get().listEqPresets().then((rows: Array<EqPresetRow>): void => {
      this.savedPresets = rows;
    });
  }

  private async persistBands(): Promise<void> {
    await SettingsService.get().setEqBands(this.bands.slice());
    hilog.info(DOMAIN, TAG, 'bands saved');
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
            .layoutWeight(1)

          Button({ stateEffect: true }) {
            Text($r('app.string.save_preset'))
              .fontSize(12)
              .fontColor($r('app.color.text_primary'))
          }
          .height(34)
          .backgroundColor($r('app.color.badge_bg'))
          .borderRadius(10)
          .onClick(() => {
            this.openSaveDialog();
          })

          Button({ stateEffect: true }) {
            Text($r('app.string.str_import'))
              .fontSize(12)
              .fontColor($r('app.color.text_primary'))
          }
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
        .padding({ left: 16, right: 16, top: 6, bottom: 20 })
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.page_bg'))
    }
    .padding({ top: this.topSafeVp })
    .title($r('app.string.equalizer'))
    .onReady((ctx: NavDestinationContext): void => {
      this.pathStack = ctx.pathStack;
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

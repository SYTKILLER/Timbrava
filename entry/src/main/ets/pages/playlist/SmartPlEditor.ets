// 规则式智能歌单编辑页(0.18.0):新建(id=0)/编辑既有规则。
// 规则 = 字段 Select + 值输入(文本/数值按字段切换) + 删除;底部:添加条件/排序/上限/保存。
// 查询语义:多规则 AND 连接,内容随曲库实时求值(PlaylistRepo.getSmartPlSongs)。
import { hilog } from '@kit.PerformanceAnalysisKit';
import { PlaylistRepo, SmartRule, SmartPlFull } from '../../data/PlaylistRepo';
import { L } from '../../common/Lang';

const TAG = '[Timbrava][SmartPlEdit]';
const DOMAIN = 0x0001;

// 路由参数:id=0 新建;>0 编辑既有
export class SmartPlParam {
  id: number = 0;

  constructor(id: number) {
    this.id = id;
  }
}

// 规则字段选项(与 PlaylistRepo.buildSmartQuery 分支一一对应)
const FIELD_KEYS: string[] = ['artist', 'album', 'genre', 'codec', 'fav', 'played', 'addedDays',
  'minRate', 'minBits', 'minYear', 'maxYear', 'minDur'];
// 数值字段(其余为文本字段;fav 无值输入)
const NUM_FIELDS: string[] = ['played', 'addedDays', 'minRate', 'minBits', 'minYear', 'maxYear', 'minDur'];
const SORT_KEYS: string[] = ['added', 'title', 'artist', 'album', 'duration', 'plays'];

function fieldLabel(f: string): string {
  if (f === 'artist') {
    return L($r('app.string.sm_f_artist'));
  }
  if (f === 'album') {
    return L($r('app.string.sm_f_album'));
  }
  if (f === 'genre') {
    return L($r('app.string.sm_f_genre'));
  }
  if (f === 'codec') {
    return L($r('app.string.sm_f_codec'));
  }
  if (f === 'fav') {
    return L($r('app.string.sm_f_fav'));
  }
  if (f === 'played') {
    return L($r('app.string.sm_f_played'));
  }
  if (f === 'addedDays') {
    return L($r('app.string.sm_f_added'));
  }
  if (f === 'minRate') {
    return L($r('app.string.sm_f_rate'));
  }
  if (f === 'minBits') {
    return L($r('app.string.sm_f_bits'));
  }
  if (f === 'minYear') {
    return L($r('app.string.sm_f_minyear'));
  }
  if (f === 'maxYear') {
    return L($r('app.string.sm_f_maxyear'));
  }
  return L($r('app.string.sm_f_dur'));
}

function sortLabel(s: string): string {
  if (s === 'title') {
    return L($r('app.string.sort_title'));
  }
  if (s === 'artist') {
    return L($r('app.string.sort_artist'));
  }
  if (s === 'album') {
    return L($r('app.string.sort_album'));
  }
  if (s === 'duration') {
    return L($r('app.string.sort_duration'));
  }
  if (s === 'plays') {
    return L($r('app.string.sm_s_plays'));
  }
  return L($r('app.string.sm_s_added'));
}

// 规则行:本地状态承载编辑(父层 onChange 静默收集,免整列表重渲丢焦点)
@Component
struct RuleRow {
  @Prop field: string = 'genre';
  @Prop value: string = '';
  @Prop num: number = 0;
  onDelete: () => void = (): void => {
  };
  onChange: (field: string, value: string, num: number) => void = (_f: string, _v: string, _n: number): void => {
  };
  @State fldIdx: number = 0;
  @State textVal: string = '';
  @State numVal: string = '';

  aboutToAppear(): void {
    this.fldIdx = Math.max(0, FIELD_KEYS.indexOf(this.field));
    this.textVal = this.value;
    this.numVal = this.num > 0 ? String(this.num) : '';
  }

  private isNumField(): boolean {
    return NUM_FIELDS.indexOf(FIELD_KEYS[this.fldIdx]) >= 0;
  }

  private emit(): void {
    this.onChange(FIELD_KEYS[this.fldIdx], this.textVal.trim(),
      Number.isFinite(parseFloat(this.numVal)) ? parseFloat(this.numVal) : 0);
  }

  build() {
    Row({ space: 8 }) {
      Select([
        { value: fieldLabel('artist') }, { value: fieldLabel('album') }, { value: fieldLabel('genre') },
        { value: fieldLabel('codec') }, { value: fieldLabel('fav') }, { value: fieldLabel('played') },
        { value: fieldLabel('addedDays') }, { value: fieldLabel('minRate') }, { value: fieldLabel('minBits') },
        { value: fieldLabel('minYear') }, { value: fieldLabel('maxYear') }, { value: fieldLabel('minDur') }
      ])
        .selected(this.fldIdx)
        .value(fieldLabel(FIELD_KEYS[this.fldIdx]))
        .fontColor($r('app.color.text_primary'))
        .font({ size: 13 })
        .selectedOptionFont({ size: 13 })
        .optionFont({ size: 13 })
        .width(132)
        .height(38)
        .onSelect((idx: number): void => {
          this.fldIdx = idx;
          // 切字段:重置为该字段的默认值,避免旧值语义错乱
          const nf = FIELD_KEYS[idx];
          this.textVal = nf === 'codec' ? 'flac' : '';
          const d = SmartRule.of(nf);
          this.numVal = d.num > 0 ? String(d.num) : '';
          this.emit();
        })

      if (FIELD_KEYS[this.fldIdx] === 'fav') {
        Text($r('app.string.sm_rule_fav_hint'))
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .layoutWeight(1)
      } else {
        TextInput({ text: this.isNumField() ? this.numVal : this.textVal,
          placeholder: this.isNumField() ? $r('app.string.sm_num_hint') : $r('app.string.sm_text_hint') })
          .height(38)
          .fontSize(13)
          .layoutWeight(1)
          .borderRadius(10)
          .backgroundColor($r('app.color.badge_bg'))
          .fontColor($r('app.color.text_primary'))
          .placeholderColor($r('app.color.text_secondary'))
          .maxLines(1)
          .inputFilter(this.isNumField() ? '[0-9]' : '')
          .onChange((v: string): void => {
            if (this.isNumField()) {
              this.numVal = v;
            } else {
              this.textVal = v;
            }
            this.emit();
          })
      }

      Button({ stateEffect: true }) {
        SymbolGlyph($r('sys.symbol.minus'))
          .fontSize(14)
          .fontColor([$r('app.color.text_secondary')])
      }
      .width(38)
      .height(38)
      .borderRadius(10)
      .backgroundColor($r('app.color.badge_bg'))
      .onClick(() => {
        this.onDelete();
      })
    }
    .width('100%')
  }
}

@Component
export struct SmartPlEditorDest {
  @StorageProp('topSafeVp') topSafeVp: number = 36;
  @StorageProp('bottomSafeVp') bottomSafeVp: number = 28;
  @State name: string = '';
  @State rules: SmartRule[] = [];
  @State sortBy: string = 'added';
  @State limitText: string = '0';
  @State sortIdx: number = 0;
  private editingId: number = 0;
  private pathStack: NavPathStack | null = null;

  aboutToAppear(): void {
    // 避让由 NavDestination padding(topSafeVp) 处理;无额外初始化
  }

  private loadExisting(id: number): void {
    PlaylistRepo.get().getSmartPl(id).then((full: SmartPlFull | null): void => {
      if (full === null) {
        return;
      }
      this.name = full.name;
      this.rules = full.rules;
      this.sortBy = full.sortBy;
      this.sortIdx = Math.max(0, SORT_KEYS.indexOf(full.sortBy));
      this.limitText = String(full.limitN);
    });
  }

  // 规则行变更静默收集(不触发整页重渲,TextInput 不丢焦点)
  private ruleChanged(i: number, field: string, value: string, num: number): void {
    const r = this.rules[i];
    if (r !== undefined) {
      r.field = field;
      r.value = value;
      r.num = num;
    }
  }

  private addRule(): void {
    this.rules = this.rules.concat([SmartRule.of('genre')]);
  }

  private removeRule(i: number): void {
    const next = this.rules.slice();
    next.splice(i, 1);
    this.rules = next;
  }

  private validRules(): boolean {
    if (this.rules.length === 0) {
      return false;
    }
    for (const r of this.rules) {
      if (r.field === 'fav') {
        continue;
      }
      if (NUM_FIELDS.indexOf(r.field) >= 0) {
        if (!(r.num > 0)) {
          return false;
        }
      } else if (r.value.trim().length === 0) {
        return false;
      }
    }
    return true;
  }

  private async save(): Promise<void> {
    const trimmed = this.name.trim();
    if (trimmed.length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.pl_name_required') });
      return;
    }
    if (!this.validRules()) {
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.sm_need_rule') });
      return;
    }
    const limitN = parseInt(this.limitText, 10);
    const lim = Number.isFinite(limitN) && limitN > 0 ? limitN : 0;
    const repo = PlaylistRepo.get();
    if (this.editingId > 0) {
      const ok = await repo.updateSmartPl(this.editingId, trimmed, this.rules, SORT_KEYS[this.sortIdx], lim);
      if (!ok) {
        this.getUIContext().getPromptAction().showToast({ message: $r('app.string.pl_name_exists') });
        return;
      }
    } else {
      const id = await repo.createSmartPl(trimmed, this.rules, SORT_KEYS[this.sortIdx], lim);
      if (id < 0) {
        this.getUIContext().getPromptAction().showToast({ message: $r('app.string.pl_name_exists') });
        return;
      }
    }
    hilog.info(DOMAIN, TAG, 'smart pl saved rules=%{public}d', this.rules.length);
    this.pathStack?.pop();
  }

  build() {
    NavDestination() {
      Column() {
        Column({ space: 12 }) {
          TextInput({ text: this.name, placeholder: $r('app.string.sm_name_hint') })
            .height(44)
            .fontSize(15)
            .borderRadius(10)
            .backgroundColor($r('app.color.card_bg'))
            .fontColor($r('app.color.text_primary'))
            .placeholderColor($r('app.color.text_secondary'))
            .maxLines(1)

          // 规则行列表
          Column({ space: 8 }) {
            ForEach(this.rules, (r: SmartRule, i: number) => {
              RuleRow({
                field: r.field,
                value: r.value,
                num: r.num,
                onDelete: (): void => {
                  this.removeRule(i);
                },
                onChange: (f: string, v: string, n: number): void => {
                  this.ruleChanged(i, f, v, n);
                }
              })
            }, (r: SmartRule, i: number): string => `sr_${i}_${r.field}`)
            if (this.rules.length === 0) {
              Text($r('app.string.sm_no_rule_hint'))
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
                .textAlign(TextAlign.Center)
                .padding({ top: 8, bottom: 8 })
            }
            Button($r('app.string.sm_add_rule'))
              .fontSize(13)
              .fontColor($r('app.color.text_primary'))
              .backgroundColor($r('app.color.badge_bg'))
              .height(40)
              .borderRadius(20)
              .width('100%')
              .onClick(() => {
                this.addRule();
              })
          }
          .width('100%')
          .padding(12)
          .borderRadius(16)
          .backgroundColor($r('app.color.card_bg'))

          // 排序 + 上限
          Column({ space: 8 }) {
            Row({ space: 8 }) {
              Text($r('app.string.sm_sort'))
                .fontSize(14)
                .fontColor($r('app.color.text_primary'))
                .layoutWeight(1)
              Select([
                { value: sortLabel('added') }, { value: sortLabel('title') }, { value: sortLabel('artist') },
                { value: sortLabel('album') }, { value: sortLabel('duration') }, { value: sortLabel('plays') }
              ])
                .selected(this.sortIdx)
                .value(sortLabel(SORT_KEYS[this.sortIdx]))
                .fontColor($r('app.color.text_primary'))
                .font({ size: 13 })
                .selectedOptionFont({ size: 13 })
                .optionFont({ size: 13 })
                .width(150)
                .height(38)
                .onSelect((idx: number): void => {
                  this.sortIdx = idx;
                })
            }
            .width('100%')
            Row({ space: 8 }) {
              Text($r('app.string.sm_limit'))
                .fontSize(14)
                .fontColor($r('app.color.text_primary'))
                .layoutWeight(1)
              TextInput({ text: this.limitText, placeholder: '0' })
                .height(38)
                .fontSize(13)
                .width(120)
                .borderRadius(10)
                .backgroundColor($r('app.color.badge_bg'))
                .fontColor($r('app.color.text_primary'))
                .placeholderColor($r('app.color.text_secondary'))
                .maxLines(1)
                .inputFilter('[0-9]')
                .textAlign(TextAlign.End)
                .onChange((v: string): void => {
                  this.limitText = v;
                })
            }
            .width('100%')
            Text($r('app.string.sm_limit_hint'))
              .fontSize(11)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
          }
          .width('100%')
          .padding(12)
          .borderRadius(16)
          .backgroundColor($r('app.color.card_bg'))

          Button($r('app.string.str_save'))
            .fontSize(14)
            .fontColor($r('app.color.on_accent'))
            .backgroundColor($r('app.color.accent'))
            .height(44)
            .borderRadius(22)
            .width('100%')
            .onClick(() => {
              this.save();
            })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: Math.max(this.bottomSafeVp, 28) + 12 })
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.page_bg'))
      .alignItems(HorizontalAlign.Start)
    }
    .padding({ top: this.topSafeVp })
    .title($r('app.string.sm_editor_title'))
    .onReady((ctx: NavDestinationContext): void => {
      this.pathStack = ctx.pathStack;
      const p: Object | undefined = ctx.pathInfo.param as Object | undefined;
      if (p !== null && p !== undefined && p instanceof SmartPlParam) {
        this.editingId = (p as SmartPlParam).id;
        if (this.editingId > 0) {
          this.loadExisting(this.editingId);
        } else {
          this.addRule(); // 新建:预置一条规则,降低空规则误存
        }
      }
    })
  }
}

@Builder
export function SmartPlEditorBuilder() {
  SmartPlEditorDest()
}

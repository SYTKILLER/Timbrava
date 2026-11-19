// 全屏播放页(对齐华为音乐/QQ音乐共识交互):
// - 封面⇄歌词左右 Swiper 切换(官方《多设备音乐界面》最佳实践:窄屏 Swiper 分页);
// - 下滑手势关闭(跟手位移+速度阈值;0.14.0) + 顶栏 chevron_down/红心收藏直达;
// - 音量条(双引擎;0.14.0)+ 沉浸皮肤(封面高斯模糊背景);
// - 控制区:左播放模式键(顺序→列表循环→单曲→随机,symbol 显示当前模式)+ 上一曲/播放暂停(缩放动画)/下一曲 + 右队列键;
// - 右上角"更多"入口 → bindSheet 菜单(收藏/均衡器/编辑歌词/倍速弹层/A-B/跳过静音/睡眠定时弹层/桌面歌词/查看队列);
// - 底部 ≥28vp 导航条避让。
// 0.24.0:「更多」面板抽为 MoreSheetPanel 子组件——bindSheet 的 @Builder 内容对宿主 @State
// 变化完全不重渲染(实测收藏/A-B label 永滞旧值),子组件自带 @StorageProp/@Watch 才有真响应式;
// 菜单行全面改造:收藏/A-B toast 反馈、跳过静音/频谱/桌面歌词明确 Toggle。
// 0.25.0:进度条上方附加区收口——频谱区 × 直关钮移除(遮挡频谱,开关统一在「更多」菜单);
// 频谱/波形条开关读 @StorageProp token,关闭即整区卸载(此前仅停帧不消失)。
// 0.25.1:频谱区引擎侧条件镜像化(vizEngineOk @State)——vizNow() 直读普通字段不被状态代理
// 追踪,页面先于无损曲打开时切歌频谱永不挂载(反之不卸载);模拟器 mp3→flac→ogg 双向实证。
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import { display } from '@kit.ArkUI';
import { vibrator } from '@kit.SensorServiceKit';
import { AppTheme, SafeAreaResult } from '../../common/Theme';
import { Breakpoint } from '../../common/Breakpoint';
import { PlayerController } from '../../service/PlayerController';
import { QueueService, PlayMode } from '../../service/QueueService';
import { EngineKind } from '../../service/engine/EngineTypes';
import { LibraryStore } from '../../data/LibraryStore';
import { Db } from '../../data/Db';
import { Song, RepeatMode, formatDuration } from '../../data/Model';
import { LyricsPanel } from '../../components/LyricsPanel';
import { CoverSuperRes } from '../../service/CoverSuperRes';
import { DesktopLyricsService } from '../../service/DesktopLyricsService';
import { WaveformService } from '../../service/WaveformService';
import { SettingsService } from '../../service/SettingsService';
import { L } from '../../common/Lang';

const TAG = '[Timbrava][FullPlayer]';
const DOMAIN = 0x0001;

// 倍速弹层档位(0.14.0:循环点击改离散选择)
const SPEED_OPTIONS: number[] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0];
// 睡眠定时弹层档位(分钟;0=关)
const SLEEP_OPTIONS: number[] = [0, 15, 30, 45, 60, 90];
const SLEEP_FADE_MS = 30000; // 到点前线性渐弱时长(与 PlayerController 一致)
const VIZ_BANDS = 48;        // native 对数频段数(与 viz.h kVizBandCount 一致)

// 频谱可视化(0.18.0):Canvas 48 柱对数频段 + 峰值保持线。
// 仅本组件存活期间轮询 native(30fps);暂停/无新帧平滑回落,系统引擎返回 null 同样回落清零。
@Component
struct VizView {
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private timer: number = -1;
  private vals: Float32Array = new Float32Array(VIZ_BANDS);
  private peaks: Float32Array = new Float32Array(VIZ_BANDS);
  private lastFrameId: number = 0;
  private accentColor: string = '#FF7A5C';
  private capColor: string = '#66FFFFFF';

  aboutToAppear(): void {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const c = ctx.resourceManager.getColorSync($r('app.color.accent'));
      this.accentColor = `#${(c >>> 0).toString(16).padStart(8, '0')}`;
    } catch (e) {
      // 取色失败用兜底色
    }
    this.timer = setInterval((): void => {
      this.poll();
    }, 33) as number;
  }

  aboutToDisappear(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  private poll(): void {
    const snap = PlayerController.get().vizPoll();
    if (snap !== null && snap.frameId !== this.lastFrameId) {
      this.lastFrameId = snap.frameId;
      for (let i = 0; i < VIZ_BANDS; i++) {
        const v = snap.bands[i];
        this.vals[i] = v;
        if (v > this.peaks[i]) {
          this.peaks[i] = v;
        }
      }
    } else {
      // 暂停/切系统引擎:平滑回落到静默
      for (let i = 0; i < VIZ_BANDS; i++) {
        this.vals[i] = this.vals[i] * 0.86;
      }
    }
    for (let i = 0; i < VIZ_BANDS; i++) {
      this.peaks[i] = Math.max(this.vals[i], this.peaks[i] * 0.985);
    }
    this.draw();
  }

  private draw(): void {
    const w = this.ctx.width;
    const h = this.ctx.height;
    if (w <= 0 || h <= 0) {
      return;
    }
    const gap = 2;
    const barW = Math.max(1, (w - gap * (VIZ_BANDS - 1)) / VIZ_BANDS);
    const usable = h - 4;
    this.ctx.clearRect(0, 0, w, h);
    this.ctx.fillStyle = this.accentColor;
    for (let i = 0; i < VIZ_BANDS; i++) {
      const bh = Math.max(2, this.vals[i] * usable);
      const x = i * (barW + gap);
      this.ctx.fillRect(x, h - bh, barW, bh);
    }
    // 峰值保持线
    this.ctx.fillStyle = this.capColor;
    for (let i = 0; i < VIZ_BANDS; i++) {
      if (this.peaks[i] > 0.02) {
        const y = h - Math.max(2, this.peaks[i] * usable);
        this.ctx.fillRect(i * (barW + gap), y - 2, barW, 2);
      }
    }
  }

  build() {
    Canvas(this.ctx)
      .width('100%')
      .height(64)
      .onReady((): void => {
        this.draw();
      })
  }
}

// 「更多」菜单面板(0.24.0 抽为独立组件):见文件头说明。
@Component
struct MoreSheetPanel {
  @State favMirror: boolean = false;
  @State abMirror: string = 'off';
  @State abLabelRes: ResourceStr = 'A-B';
  @State skipMirror: boolean = false;
  @State vizMirror: boolean = false;
  @State waveMirror: boolean = false;
  @State lyricsMirror: boolean = false;
  @State sheetExpand: string = '';  // 展开区:'' | 'speed' | 'sleep'
  @State volMirror: number = 100;
  @State spdMirror: number = 1.0;
  private initialExpand: string = '';
  onClose: () => void = (): void => {
  };
  onOpenQueue: () => void = (): void => {
  };

  aboutToAppear(): void {
    this.sheetExpand = this.initialExpand;
    this.volMirror = Math.round(PlayerController.get().volume * 100);
    this.spdMirror = PlayerController.get().speed;
    this.refreshMirrors();
  }

  private refreshMirrors(): void {
    const s = PlayerController.get().currentSong;
    const fav = s !== null && LibraryStore.get().isFavorite(s.id);
    const ab = PlayerController.get().abState();
    const skip = this.skipSilenceNow();
    const viz = PlayerController.get().vizOn();
    const wave = SettingsService.get().waveEnabled;
    const lyrics = DesktopLyricsService.get().isOn();
    const abRes: ResourceStr = ab === 'a' ? $r('app.string.ab_set_a')
      : ab === 'ab' ? $r('app.string.ab_looping') : 'A-B';
    this.favMirror = fav;
    this.abMirror = ab;
    this.abLabelRes = abRes;
    this.skipMirror = skip;
    this.vizMirror = viz;
    this.waveMirror = wave;
    this.lyricsMirror = lyrics;
  }

  private toast(msg: ResourceStr): void {
    this.getUIContext().getPromptAction().showToast({ message: msg, duration: 2000 });
  }

  private navStack(): NavPathStack | null {
    return AppStorage.get<NavPathStack>('navStack') ?? null;
  }

  // 桌面歌词开关:开→floatView 拉起浮窗页;失败提示(权限/设备不支持)
  private async toggleDesktopLyrics(): Promise<void> {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await DesktopLyricsService.get().toggle(ctx);
    } catch (e) {
      this.toast($r('app.string.float_lyrics_fail'));
    }
  }

  private editLabel(): ResourceStr {
    return PlayerController.get().currentLyrics.length > 0 ? $r('app.string.edit_lyrics')
      : $r('app.string.add_lyrics');
  }

  private speedNow(): number {
    return PlayerController.get().speed;
  }

  private speedLabel(): ResourceStr {
    const v = this.speedNow();
    if (v === 1.0) {
      return $r('app.string.speed_label');
    }
    return `${v}x`;
  }

  private abLabel(): ResourceStr {
    if (this.abMirror === 'a') {
      return $r('app.string.ab_set_a');
    }
    if (this.abMirror === 'ab') {
      return $r('app.string.ab_looping');
    }
    return 'A-B';
  }

  private skipSilenceNow(): boolean {
    return PlayerController.get().currentSong !== null &&
      (PlayerController.get().engineKind === EngineKind.LOSSLESS) &&
      PlayerController.get().isSkipSilenceOn();
  }

  private sleepChipLabel(n: number): ResourceStr {
    if (n <= 0) {
      return $r('app.string.sleep_off');
    }
    return L($r('app.string.sleep_chip_min'), String(n));
  }

  private sleepChipActive(n: number): boolean {
    const cur = PlayerController.get().sleepRemainMin();
    if (n <= 0) {
      return cur <= 0;
    }
    return cur > n - 15 && cur <= n;
  }

  private sleepLabel(): ResourceStr {
    const cur = PlayerController.get().sleepRemainMin();
    if (cur <= 0) {
      return $r('app.string.sleep_timer');
    }
    return L($r('app.string.sleep_remain'), String(cur));
  }

  // 开关行实时态(体内直读)
  private rowToggleOn(kind: string): boolean {
    if (kind === 'skip') {
      return this.skipMirror;
    }
    if (kind === 'viz') {
      return this.vizMirror;
    }
    if (kind === 'wave') {
      return this.waveMirror;
    }
    if (kind === 'lyrics') {
      return this.lyricsMirror;
    }
    return false;
  }

  // 开关行置位后同步镜像(Toggle 内部视觉已自翻,镜像对齐供下次打开)
  private syncToggleMirror(kind: string, on: boolean): void {
    if (kind === 'skip') {
      this.skipMirror = on;
    } else if (kind === 'viz') {
      this.vizMirror = on;
    } else if (kind === 'wave') {
      this.waveMirror = on;
    } else if (kind === 'lyrics') {
      this.lyricsMirror = on;
    }
  }

  // 开关行置位;桌面歌词失败(权限/设备)经 toggleDesktopLyrics 内 toast
  private applyRowToggle(kind: string, on: boolean): void {
    if (kind === 'skip') {
      PlayerController.get().setSkipSilenceOn(on);
    } else if (kind === 'viz') {
      PlayerController.get().setVizEnabled(on);
    } else if (kind === 'wave') {
      SettingsService.get().setWaveEnabled(on); // token 同步驱动播放页波形区整区卸载/补载
    } else if (kind === 'lyrics' && on !== DesktopLyricsService.get().isOn()) {
      this.toggleDesktopLyrics();
    }
    this.syncToggleMirror(kind, on);
  }

  @Builder
  SheetRow(icon: Resource, label: ResourceStr, accent: boolean, onTap: () => void,
    expandable: boolean = false, expanded: boolean = false, toggleKind: string = '') {
    Row({ space: 12 }) {
      SymbolGlyph(icon)
        .fontSize(18)
        .fontColor([accent ? $r('app.color.accent') : $r('app.color.text_primary')])
      Text(label)
        .fontSize(14)
        .fontColor(accent ? $r('app.color.accent') : $r('app.color.text_primary'))
        .layoutWeight(1)
      if (toggleKind.length > 0) {
        Toggle({ type: ToggleType.Switch, isOn: this.rowToggleOn(toggleKind) })
          .selectedColor($r('app.color.accent'))
          .onChange((on: boolean): void => {
            this.applyRowToggle(toggleKind, on);
          })
      } else if (expandable) {
        SymbolGlyph(expanded ? $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_down'))
          .fontSize(13)
          .fontColor([$r('app.color.text_secondary')])
      }
    }
    .width('100%')
    .padding({ left: 20, right: 16, top: 12, bottom: 12 })
    .onClick(() => {
      onTap();
    })
  }

  build() {
    Column() {
      Row({ space: 8 }) {
        Button({ stateEffect: true }) {
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(18)
            .fontColor([$r('app.color.text_primary')])
        }
        .width(48)
        .height(48)
        .borderRadius(24)
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          this.onClose();
        })
        Text($r('app.string.more_menu'))
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: 8, right: 16, top: 8 })
      List({ space: 0 }) {
        // 音量(0.15.1:自播放页主体收入此菜单;引擎流音量,无损=OHAudio 渲染流/系统=AVPlayer)
        ListItem() {
          Row({ space: 12 }) {
            SymbolGlyph($r('sys.symbol.speaker_wave_2'))
              .fontSize(18)
              .fontColor([this.volMirror <= 0 ? $r('app.color.text_secondary') : $r('app.color.text_primary')])
            Slider({
              value: this.volMirror,
              min: 0,
              max: 100,
              step: 1,
              style: SliderStyle.OutSet
            })
              .selectedColor($r('app.color.accent'))
              .trackColor($r('app.color.divider'))
              .blockColor($r('app.color.accent'))
              .layoutWeight(1)
              .height(34)
              .onChange((value: number, mode: SliderChangeMode) => {
                this.volMirror = Math.round(value);
                if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                  PlayerController.get().setVolume(value / 100);
                }
              })
            Text(`${Math.round(this.volMirror)}%`)
              .fontSize(11)
              .fontColor($r('app.color.text_secondary'))
              .width(34)
              .textAlign(TextAlign.End)
          }
          .width('100%')
          .padding({ left: 20, right: 16, top: 16, bottom: 8 })
        }
        // 收藏(0.24.0:toast 反馈已收藏/已取消收藏;favMirror 经子组件 @Watch 活刷新)
        ListItem() {
          this.SheetRow(this.favMirror ? $r('sys.symbol.heart_fill') : $r('sys.symbol.heart'),
            this.favMirror ? $r('app.string.str_favorited') : $r('app.string.str_favorites'),
            this.favMirror, (): void => {
              const s = PlayerController.get().currentSong;
              if (s === null) {
                return;
              }
              const fav = !LibraryStore.get().isFavorite(s.id);
              PlayerController.get().toggleFavorite();
              this.toast(fav ? $r('app.string.str_favorited') : $r('app.string.str_unfavorited'));
            })
        }
        // 均衡器直达(0.14.0)
        ListItem() {
          this.SheetRow($r('sys.symbol.adjustment'), $r('app.string.eq_entry'), false, (): void => {
            this.onClose();
            const stack = this.navStack();
            if (stack !== null) {
              stack.pushPathByName('Equalizer', null);
            }
          })
        }
        // 编辑歌词
        ListItem() {
          this.SheetRow($r('sys.symbol.pencil_line'), this.editLabel(), false, (): void => {
            this.onClose();
            const song = PlayerController.get().currentSong;
            const stack = this.navStack();
            if (song !== null && stack !== null) {
              stack.pushPathByName('LyricsEditor', song.id);
            }
          })
        }
        // 倍速(展开档位 chips + 0.05 微调滑条)
        ListItem() {
          this.SheetRow($r('sys.symbol.speed_multiple'), this.speedLabel(),
            this.speedNow() !== 1.0, (): void => {
              this.sheetExpand = this.sheetExpand === 'speed' ? '' : 'speed';
              if (this.sheetExpand === 'speed') {
                this.spdMirror = this.speedNow();
              }
            }, true, this.sheetExpand === 'speed')
        }
        if (this.sheetExpand === 'speed') {
          ListItem() {
            Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
              ForEach(SPEED_OPTIONS, (v: number) => {
                Button(`${v}x`)
                  .fontSize(12)
                  .fontColor(this.speedNow() === v ? $r('app.color.on_accent') : $r('app.color.text_primary'))
                  .backgroundColor(this.speedNow() === v ? $r('app.color.accent') : $r('app.color.badge_bg'))
                  .borderRadius(14)
                  .height(36)
                  .margin({ right: 8, bottom: 8, left: 4 })
                  // 最小可点目标 40vp:视觉 36,热区纵向外扩(0.17.0)
                  .responseRegion({ x: 0, y: -2, width: '100%', height: 40 })
                  .onClick(() => {
                    PlayerController.get().setSpeed(v);
                    this.spdMirror = v;
                    this.sheetExpand = '';
                  })
              }, (v: number): string => `spd_${v}`)
            }
            .width('100%')
            .padding({ left: 16, right: 16, bottom: 4 })
          }
          // 自定义微调滑条(0.21.0,YT Music 0.05 步进):0.25~3.0,松手落库
          ListItem() {
            Row({ space: 12 }) {
              Text('0.25x')
                .fontSize(11)
                .fontColor($r('app.color.text_secondary'))
              Slider({
                value: this.spdMirror,
                min: 0.25,
                max: 3.0,
                step: 0.05,
                style: SliderStyle.OutSet
              })
                .selectedColor($r('app.color.accent'))
                .trackColor($r('app.color.divider'))
                .blockColor($r('app.color.accent'))
                .layoutWeight(1)
                .height(34)
                .onChange((value: number, mode: SliderChangeMode) => {
                  this.spdMirror = Math.round(value * 20) / 20; // 0.05 步进对齐
                  if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                    PlayerController.get().setSpeed(this.spdMirror);
                  }
                })
              Text(`${this.spdMirror.toFixed(2)}x`)
                .fontSize(11)
                .fontColor(this.spdMirror !== 1.0 ? $r('app.color.accent') : $r('app.color.text_secondary'))
                .width(46)
                .textAlign(TextAlign.End)
            }
            .width('100%')
            .padding({ left: 20, right: 16, top: 4, bottom: 12 })
          }
        }
        // A-B 重复(三态动作 + toast;abMirror @State 活刷新 label/accent)
        ListItem() {
          this.SheetRow($r('sys.symbol.scope'), this.abLabelRes,
            this.abMirror !== 'off', (): void => {
              const st = PlayerController.get().setAbPoint();
              this.toast(st === 'a' ? $r('app.string.ab_set_a')
                : st === 'ab' ? $r('app.string.ab_looping') : $r('app.string.ab_cancelled'));
            })
        }
        // 跳过静音(明确开关)
        ListItem() {
          this.SheetRow($r('sys.symbol.speaker_slash'), $r('app.string.skip_silence'),
            false, (): void => {
            }, false, false, 'skip')
        }
        // 频谱可视化(明确开关;0.25.0 关=播放页频谱区整区卸载,× 直关钮已移除)
        ListItem() {
          this.SheetRow($r('sys.symbol.waveform'), $r('app.string.viz_toggle'),
            false, (): void => {
            }, false, false, 'viz')
        }
        // 波形进度条(0.19.0 波形包络;0.25.0 起明确开关:关=进度条上方波形区彻底移除)
        ListItem() {
          this.SheetRow($r('sys.symbol.waveform_1'), $r('app.string.wave_toggle'),
            false, (): void => {
            }, false, false, 'wave')
        }
        // 驾驶模式(0.22.0 车机适配预备):大钮横屏页,支架/超级桌面车机屏场景
        ListItem() {
          this.SheetRow($r('sys.symbol.car_fill'), $r('app.string.driving_mode'),
            false, (): void => {
              this.onClose();
              const stack = this.navStack();
              if (stack !== null) {
                stack.pushPathByName('DrivingMode', null);
              }
            })
        }
        // 睡眠定时器(展开档位 chips;到点前 30s 渐弱)
        ListItem() {
          this.SheetRow($r('sys.symbol.timer'), this.sleepLabel(),
            PlayerController.get().sleepRemainMin() > 0, (): void => {
              this.sheetExpand = this.sheetExpand === 'sleep' ? '' : 'sleep';
            }, true, this.sheetExpand === 'sleep')
        }
        if (this.sheetExpand === 'sleep') {
          ListItem() {
            Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
              ForEach(SLEEP_OPTIONS, (n: number) => {
                Button(this.sleepChipLabel(n))
                  .fontSize(12)
                  .fontColor(this.sleepChipActive(n) ? $r('app.color.on_accent') : $r('app.color.text_primary'))
                  .backgroundColor(this.sleepChipActive(n) ? $r('app.color.accent') : $r('app.color.badge_bg'))
                  .borderRadius(14)
                  .height(36)
                  .margin({ right: 8, bottom: 8, left: 4 })
                  // 最小可点目标 40vp:视觉 36,热区纵向外扩(0.17.0)
                  .responseRegion({ x: 0, y: -2, width: '100%', height: 40 })
                  .onClick(() => {
                    PlayerController.get().setSleepTimer(n);
                    this.sheetExpand = '';
                  })
              }, (n: number): string => `slp_${n}`)
            }
            .width('100%')
            .padding({ left: 16, right: 16, bottom: 4 })
          }
        }
        // 桌面歌词(26-7,floatView;24 设备/权限未授时不显示入口;明确开关)
        if (DesktopLyricsService.get().available()) {
          ListItem() {
            this.SheetRow($r('sys.symbol.music_note_list'), $r('app.string.desktop_lyrics'),
              false, (): void => {
              }, false, false, 'lyrics')
          }
        }
        // 查看队列
        ListItem() {
          this.SheetRow($r('sys.symbol.list_bullet'), $r('app.string.view_queue'), false, (): void => {
            this.onClose();
            this.onOpenQueue();
          })
        }
      }
      .width('100%')
      .padding({ bottom: 16 })
    }
    .width('100%')
    .backgroundColor($r('app.color.card_bg'))
  }
}

@Component
export struct FullPlayerDest {
  @StorageProp('playerVer') @Watch('onPlayerChanged') playerVer: number = 0;
  @StorageProp('posVer') @Watch('onPosChanged') posVer: number = 0;
  @State posMs: number = 0;
  @StorageProp('queueVer') @Watch('onQueueChanged') queueVer: number = 0;
  @State modeMirror: PlayMode = 'order'; // 模式键图标镜像(经 @State 切换驱动刷新)
  @StorageProp('libVer') @Watch('onLibChanged') libVer: number = 0;
  @StorageProp('themePageBg') themePageBg: string = '';
  @StorageProp('prefPlayerSkin') playerSkin: string = 'standard';
  @State seeking: boolean = false;
  @State seekPreviewMs: number = 0;
  @State showQueue: boolean = false;
  @State showMoreSheet: boolean = false;
  @State pageIdx: number = 0; // Swiper 当前页:0 封面 / 1 歌词
  @State playingMirror: boolean = false; // 播放键动画镜像(经 @State 切换才触发过渡)
  @State playBounce: boolean = false; // 点击缩放弹跳
  @State topSafe: number = 36;
  @State bottomSafe: number = 28;
  @StorageProp('bpMdPlus') bpMdPlus: boolean = false;  // md+:播放页双栏(0.22.0 折叠屏展开/平板/PC)
  @StorageProp('foldHover') foldHover: boolean = false; // 折叠悬停态:上封面避折痕/下半屏控制(0.22.0)
  @State srPm: image.PixelMap | null = null; // 26-5 超分封面(小封面实时超分,失败/不支持=null 原图)
  @State dragY: number = 0;          // 下滑关闭跟手位移(0.14.0)
  // pop 自定义转场位移(Index.playerNavTransition 经 animateTo 驱动 0→视口高;
  // 与 dragY 相加为整层 translate——转场期间系统保持前后页同帧可见,纵向滑出直见下层页面)
  @StorageProp('playerExitY') exitY: number = 0;
  // 曲目信息镜像(0.15.0 #20):playerVer 不经 @State 落地时 build 内节点零依赖不刷新,
  // "if (playerVer < 0)"注册依赖写法条件恒假不重评——切歌标题/艺人/专辑/封面纹丝不动的根因
  @State songTitle: string = '';
  @State songSub: string = '';
  @State songArt: string = '';
  @State songSpec: string = '';
  @State engineMirror: string = '';
  @State favMirror: boolean = false;
  @State hasSong: boolean = false;
  // 频谱引擎侧条件镜像(0.25.1):无损引擎+有曲目。vizNow() 方法直读 controller 普通字段
  // (engineKind/currentSong)不被状态代理追踪——切歌/引擎切换不触发频谱 if 重估,
  // 页面先于无损曲打开(或从 mp3 切入无损)时频谱区永不挂载,反之不卸载(0.24.0 关闭不消失的同根残留)
  @State vizEngineOk: boolean = false;
  @StorageProp('prefDblTapFav') dblTapFav: boolean = true; // 双击封面收藏开关(0.20.0)
  // 频谱可视化开关(0.25.0 改 @StorageProp 读 token):方法直读 SettingsService 的条件是惰性的,
  // 菜单里关掉只停帧不卸载(频谱冻在最后一帧);@StorageProp 才能让开关切换驱动 build 重估整区卸载
  @StorageProp('prefVizEnabled') vizPref: boolean = true;
  // 波形进度条开关(0.25.0):关=波形区整区移除且 loadWaveform 守卫不再解码;开=补载当前曲包络
  @StorageProp('prefWaveEnabled') @Watch('onWavePrefChanged') wavePref: boolean = true;
  @State heartScale: number = 0;    // 红心爆裂动效(0.20.0)
  @State heartOpacity: number = 0;
  @State showGuide: boolean = false; // 首次手势引导(0.20.0;一次性,轻触关闭并记忆)
  @State qIndexMirror: number = -1;  // 队列抽屉当前序高亮镜像
  // 波形包络(0.19.0;null=隐藏波形条)。0.22.0 修复:@State 存 TypedArray 丢 [[TypedArrayName]] 内部槽
  // (KB 红线:状态代理不存 TypedArray)——开播放页即 jscrash(0.19.0 模拟器未验漏网)。
  // 数据改 private + waveVer 计数触发 build 重估,drawWave 直读 private 无代理。
  private waveData: Float32Array | null = null;
  @State waveVer: number = 0;
  @State waveFor: number = -1;
  private waveCtx: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private waveReady: boolean = false;
  private waveAccent: string = '#FF7A5C';
  private waveRest: string = '#66888888';
  private srFor: string = '';
  private pathStack: NavPathStack | null = null;
  private swiperCtrl: SwiperController = new SwiperController();
  private lastCoverTap: number = 0; // 封面双击判定窗口(0.20.0)

  aboutToAppear(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    AppTheme.safeAreas(ctx).then((r: SafeAreaResult): void => {
      this.topSafe = r.topVp;
      this.bottomSafe = Math.max(r.bottomVp, 28);
    });
    this.posMs = Math.round(PlayerController.get().positionMs);
    this.playingMirror = PlayerController.get().isPlaying;
    this.modeMirror = QueueService.get().playMode();
    AppStorage.setOrCreate('playerExitY', 0); // 上次 pop 残留清零(新实例从原位开始)
    this.cacheWaveColors();
    // 首次手势引导(0.20.0):只在有曲目时弹一次
    Db.get().getSetting('gestureGuideSeen', '0').then((v: string): void => {
      if (v !== '1' && PlayerController.get().currentSong !== null) {
        this.showGuide = true;
      }
    });
    // 页面可能晚于播放打开:@Watch 不会补发,主动拉一次(歌词由控制器中心化加载)
    this.onPlayerChanged();
  }

  aboutToDisappear(): void {
    // 0.15.0 下滑关闭:pop 前不再复位 dragY(保持离屏位,避免默认 pop 转场露馅),
    // 此处(转场结束组件销毁前)清零,实例复用/重进都从原位开始
    this.dragY = 0;
    this.dismissing = false;
    AppStorage.setOrCreate('playerExitY', 0);
    AppStorage.setOrCreate('playerExitFrom', 0);
    AppStorage.setOrCreate('fullPlayerInStack', false);
  }

  onPlayerChanged(): void {
    this.playingMirror = PlayerController.get().isPlaying;
    this.modeMirror = QueueService.get().playMode();
    this.refreshSongMirrors();
    this.loadCoverSr();
    this.loadWaveform();
  }

  // 波形开关切换(0.25.0):开→当前曲包络缺则补载(WaveformService 缓存命中即时);
  // 关→build 重估卸载波形区(loadWaveform 内守卫同步清态)
  onWavePrefChanged(): void {
    this.loadWaveform();
  }

  // 曲目信息镜像刷新(切歌/收藏变化唯一入口;0.15.0)
  private refreshSongMirrors(): void {
    const s = PlayerController.get().currentSong;
    this.hasSong = s !== null;
    this.songTitle = s !== null ? s.displayTitle() : '';
    this.songSub = s !== null ? (s.displayArtist() + ' — ' + s.displayAlbum()) : '';
    this.songArt = s !== null ? s.artPath : '';
    this.songSpec = s !== null ? s.specBadge() : '';
    this.engineMirror = PlayerController.get().engineInfo;
    this.favMirror = s !== null && LibraryStore.get().isFavorite(s.id);
    this.qIndexMirror = QueueService.get().currentOrderIndex;
    // 频谱引擎侧条件随镜像落 @State(0.25.1):playSong/gapless 推进/错误兜底均经 bumpPlayer →
    // onPlayerChanged 到此,引擎或曲目变化即驱动频谱 if 重估(挂载/卸载)
    this.vizEngineOk = PlayerController.get().engineKind === EngineKind.LOSSLESS && s !== null;
  }

  onLibChanged(): void {
    this.favMirror = this.hasSong && LibraryStore.get().isFavorite((PlayerController.get().currentSong as Song).id);
  }

  // ===== 双击封面收藏 + 手势引导(0.20.0) =====

  // 收藏翻转 + 红心爆裂 + 轻震动:顶栏红心与双击封面共用
  burstFavorite(): void {
    PlayerController.get().toggleFavorite();
    this.vibrate();
    // 两段动画:弹出(0.4→1)再放大淡出(1→1.7/0),结束清零可复触发
    this.heartScale = 0.4;
    this.heartOpacity = 0;
    this.getUIContext().animateTo({
      duration: 170,
      curve: Curve.EaseOut,
      onFinish: (): void => {
        this.getUIContext().animateTo({
          duration: 280,
          curve: Curve.EaseIn,
          onFinish: (): void => {
            this.heartScale = 0;
            this.heartOpacity = 0;
          }
        }, (): void => {
          this.heartScale = 1.7;
          this.heartOpacity = 0;
        });
      }
    }, (): void => {
      this.heartScale = 1.0;
      this.heartOpacity = 0.95;
    });
  }

  // 轻震动反馈(手势动效标配);模拟器/不支持设备静默忽略
  // API26 d.ts:VibratePreset={type:'preset',effectId,count};EffectId 仅有 clock timer 预设
  private vibrate(): void {
    try {
      vibrator.startVibration(
        { type: 'preset', effectId: vibrator.EffectId.EFFECT_CLOCK_TIMER, count: 1 },
        { usage: 'touch' }
      ).catch((): void => {
      });
    } catch (e) {
      // 无振动能力(模拟器/无马达)忽略
    }
  }

  // 首次引导:轻触关闭并落库(此后不再弹)
  private closeGuide(): void {
    this.showGuide = false;
    Db.get().setSetting('gestureGuideSeen', '1');
  }

  // ===== 波形进度条(0.19.0) =====

  // 切歌即拉取包络:缓存命中即时,未命中后台整曲解码(仅 flac/wav,完成且仍是本曲才上屏)
  // 0.25.0:开关关时直接清态返回(不解码,进度条上方波形区彻底消失)
  private loadWaveform(): void {
    const s = this.song();
    if (s === null || !this.wavePref || !WaveformService.get().supported(s.codec)) {
      this.waveData = null;
      this.waveFor = -1;
      this.waveVer++;
      return;
    }
    const id = s.id;
    WaveformService.get().getFor(s).then((d: Float32Array | null): void => {
      const cur = this.song();
      if (cur !== null && cur.id === id && d !== null) {
        this.waveData = d;
        this.waveFor = id;
        this.waveVer++;
        this.drawWave();
      }
    });
  }

  private drawWave(): void {
    const d = this.waveData;
    if (!this.waveReady || d === null) {
      return;
    }
    const w = this.waveCtx.width;
    const h = this.waveCtx.height;
    if (w <= 0 || h <= 0) {
      return;
    }
    const n = d.length;
    const frac = this.durMs() > 1 ? Math.min(1, this.posMs / this.durMs()) : 0;
    this.waveCtx.clearRect(0, 0, w, h);
    const barW = w / n;
    const usable = h - 4;
    for (let i = 0; i < n; i++) {
      const bh = Math.max(2, d[i] * usable);
      const played = (i + 0.5) / n <= frac;
      this.waveCtx.fillStyle = played ? this.waveAccent : this.waveRest;
      this.waveCtx.fillRect(i * barW, (h - bh) / 2, Math.max(1, barW - 1), bh);
    }
  }

  private cacheWaveColors(): void {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const accent = ctx.resourceManager.getColorSync($r('app.color.accent'));
      this.waveAccent = `#${(accent >>> 0).toString(16).padStart(8, '0')}`;
    } catch (e) {
      // 取色失败用兜底色
    }
  }

  // 26-5:当前曲封面短边 <500px 时实时超分(26 设备),完成后回到本曲才上屏
  private loadCoverSr(): void {
    const s = this.song();
    if (s === null || s.artPath.length === 0) {
      this.srPm = null;
      this.srFor = '';
      return;
    }
    if (!CoverSuperRes.get().available()) {
      hilog.info(DOMAIN, TAG, 'sr unavailable(api/syscap)');
      return;
    }
    const key = String(s.id);
    if (this.srFor === key) {
      return;
    }
    this.srFor = key;
    CoverSuperRes.get().superRes(key, s.artPath).then((pm: image.PixelMap | null): void => {
      if (this.srFor === key) {
        this.srPm = pm;
      }
    });
  }

  onQueueChanged(): void {
    this.modeMirror = QueueService.get().playMode();
    this.qIndexMirror = QueueService.get().currentOrderIndex;
  }

  onPosChanged(): void {
    // KB 三规则:posVer 必须经 @Watch 落到 @State 才驱动进度文本/滑条(KB 红线:声明不读=零依赖)
    this.posMs = Math.round(PlayerController.get().positionMs);
    this.drawWave(); // 波形条已播进度着色(250ms 粒度,与滑条同步)
  }

  private song(): Song | null {
    return PlayerController.get().currentSong;
  }

  private pageBg(): ResourceColor {
    return this.themePageBg.length > 0 ? this.themePageBg : $r('app.color.player_bg');
  }

  private queueItems(): Song[] {
    const q = QueueService.get();
    const arr: Song[] = [];
    for (let i = 0; i < q.list.length; i++) {
      const s = LibraryStore.get().song(q.list[i]);
      if (s !== null) {
        arr.push(s);
      }
    }
    return arr;
  }

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.Bottom }) {
      // 沉浸皮肤背景层:当前封面高斯模糊 + 主题色蒙版(标准/极简皮肤不渲染,保持纯色底)
      if (this.playerSkin === 'immersive' && this.hasSong) {
        Stack() {
          // 基底垫色:无封面曲(既无超分又无原图)时保证皮肤层不透明(NavDestination 已透明化,见下)
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor(this.pageBg())
          if (this.srPm !== null) {
            Image(this.srPm)
              .width('100%')
              .height('100%')
              .objectFit(ImageFit.Cover)
              .blur(120)
          } else if (this.songArt.length > 0) {
            Image(this.songArt)
              .width('100%')
              .height('100%')
              .objectFit(ImageFit.Cover)
              .blur(120)
          }
        }
        .width('100%')
        .height('100%')
        // 主题色蒙版:保证 text token 在模糊图上可读;0.87 几乎盖死模糊层(用户感知"皮肤没生效"),
        // 降到 0.62 让封面色彩透出(0.15.0)
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(this.pageBg())
          .opacity(0.62)
      }
      Column() {
        // 顶栏:下滑关闭 | 正在播放 | 收藏 | 更多(右上角,bindSheet)
        Row() {
          Button({ stateEffect: true }) {
            SymbolGlyph($r('sys.symbol.chevron_down'))
              .fontSize(24)
              .fontColor([$r('app.color.text_primary')])
          }
          .width(40)
          .height(40)
          .backgroundColor(Color.Transparent)
          .onClick(() => {
            // 0.15.2:返回键与下滑手势同款纵向滑出(此前走默认 pop 横向转场,与操作直觉矛盾)
            this.dismissAnimated();
          })
          Text($r('app.string.now_playing'))
            .fontSize(15)
            .fontColor($r('app.color.text_secondary'))
            .layoutWeight(1)
            .textAlign(TextAlign.Center)
          Button({ stateEffect: true }) {
            SymbolGlyph(this.favMirror ? $r('sys.symbol.heart_fill') : $r('sys.symbol.heart'))
              .fontSize(20)
              .fontColor([this.favMirror ? $r('app.color.accent') : $r('app.color.text_primary')])
          }
          .width(40)
          .height(40)
          .backgroundColor(Color.Transparent)
          .onClick(() => {
            // 0.20.0:与双击封面同路径(红心爆裂+轻震动)
            this.burstFavorite();
          })
          Button({ stateEffect: true }) {
            // 四点钮(0.17.0):华为应用"展开更多选项"语义;原 more(方块)改 dot_grid_2x2
            SymbolGlyph($r('sys.symbol.dot_grid_2x2'))
              .fontSize(20)
              .fontColor([$r('app.color.text_primary')])
          }
          .width(40)
          .height(40)
          .backgroundColor(Color.Transparent)
          .onClick(() => {
            this.openMoreSheet();
          })
        }
        .width('100%')
        .padding({ left: 8, right: 8, top: this.topSafe })
        if (this.hasSong) {
          this.PlayerBody()
        } else {
          Column({ space: 10 }) {
            SymbolGlyph($r('sys.symbol.music_note_list'))
              .fontSize(48)
              .fontColor([$r('app.color.text_secondary')])
            Text($r('app.string.no_playing_song'))
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.playerSkin === 'immersive' && this.hasSong
        ? Color.Transparent : this.pageBg())
      // 下滑关闭手势:绑在内容 Column(实证 Stack 级 .gesture 在本页不触发,Row/Column 级正常)。
      // 跟手位移削顶 55%vh:节点拖出屏后手势失灵(KB §9.4),松手动画收尾;抽屉/菜单展开时回调内守卫。
      // 注意 translate 挂在内层 Stack(含皮肤背景层整体下沉);挂本 Column 会让背景层滞留原地。
      .gesture(PanGesture({ fingers: 1, direction: PanDirection.Vertical, distance: 8 })
          .onActionUpdate((e: GestureEvent): void => {
            this.dragUpdate(e);
          })
          .onActionEnd((e: GestureEvent): void => {
            this.dragFinish(e);
          }))
      // 播放队列(0.15.2:自绘 Stack 条目改标准 bindSheet 半模态——标准上滑动画/下拉关闭;
      // 0.17.0 多档高度:默认中档,上滑展开大档;0.22.0 preferType POPUP——<600vp 底部/≥600vp 跟手,官方折叠屏推荐)
      .bindSheet(this.showQueue, this.QueueDrawer(), {
        detents: [SheetSize.MEDIUM, SheetSize.LARGE],
        preferType: SheetType.POPUP,
        dragBar: false,
        showClose: false,
        onDisappear: (): void => {
          this.showQueue = false;
        }
      })

      // 首次手势引导(0.20.0):一次性浮层,轻触任意处关闭并记忆
      if (this.showGuide) {
        Column({ space: 22 }) {
          Row({ space: 14 }) {
            SymbolGlyph($r('sys.symbol.heart'))
              .fontSize(22)
              .fontColor([$r('app.color.accent')])
            Text($r('app.string.player_guide_fav'))
              .fontSize(15)
              .fontColor($r('app.color.text_primary'))
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)
          Row({ space: 14 }) {
            SymbolGlyph($r('sys.symbol.arrow_down'))
              .fontSize(22)
              .fontColor([$r('app.color.accent')])
            Text($r('app.string.player_guide_swipe'))
              .fontSize(15)
              .fontColor($r('app.color.text_primary'))
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)
          Row({ space: 14 }) {
            SymbolGlyph($r('sys.symbol.dot_grid_2x2'))
              .fontSize(22)
              .fontColor([$r('app.color.accent')])
            Text($r('app.string.player_guide_more'))
              .fontSize(15)
              .fontColor($r('app.color.text_primary'))
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)
          Text($r('app.string.player_guide_dismiss'))
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .margin({ top: 6 })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor('#B3000000')
        .onClick(() => {
          this.closeGuide();
        })
      }

      }
      .width('100%')
      .height('100%')
      .backgroundColor(Color.Transparent)
      // 下滑位移挂整层:皮肤背景 + 内容一起跟手/下沉(NavDestination 已透明)
      // dragY=手势跟手段;exitY=pop 自定义转场段(纵向),相加保证手势→转场视觉连续
      .translate({ y: this.dragY + this.exitY })
      .bindSheet(this.showMoreSheet, this.MoreSheet(), {
        height: 500,
        preferType: SheetType.POPUP,
        showClose: false,
        dragBar: true,
        onDisappear: (): void => {
          this.showMoreSheet = false;
        }
      })
    }
    .hideTitleBar(true)
    // 关键:NavDestination 默认底色不透明——内容下沉后露出"空背景",pop 默认横向转场再把它整体滑走
    // (0.16 实测"先下滑消失→空背景侧滑消失"双重动画)。透明化后:跟手阶段直见下层页,pop 转场全程不可见。
    .backgroundColor(Color.Transparent)
    .onReady((ctx: NavDestinationContext): void => {
      this.pathStack = ctx.pathStack;
      // 宽屏播放条(Index.PlayerBar)据此隐藏:播放页自带完整播控(0.22.0)
      AppStorage.setOrCreate('fullPlayerInStack', true);
    })
    .onBackPressed((): boolean => {
      if (this.showQueue) {
        this.showQueue = false;
        return true;
      }
      // 0.15.2:系统返回同样纵向滑出(默认 pop 横向转场已废弃)
      this.dismissAnimated();
      return true;
    })
  }

  // 下滑关闭:垂直下拉跟手,松手按位移/速度判定关闭或回弹(KB §9.4:手势对象必须 build 内构造)。
  // 位移出屏后 pop(页面已离屏,默认转场不可见)。 dismissing 防多手势实例重复触发。
  // 0.15.0 修复:此前 pop 前先 dragY=0 复位,页面瞬间回位再叠默认 pop 转场(整体右滑)——
  // 与下滑手势直觉矛盾;现在保持离屏位移直接 pop,复位延迟到转场后。
  // 0.15.2:返回键/系统返回也走同一纵向滑出动画(dismissAnimated),全页退出动作统一。
  // 0.17.0:pop 动画改由 Navigation.customNavContentTransition 接管(Index.playerNavTransition)——
  // 默认 pop 的横向转场(下层页面横入,实测 f4 帧)彻底移除;本方法只负责把起始位移交给转场后立即 pop。
  private dismissing: boolean = false;

  private dismissAnimated(): void {
    if (this.dismissing) {
      return;
    }
    this.dismissing = true;
    AppStorage.setOrCreate('playerExitFrom', this.dragY); // 手势已有位移:转场从当前位置继续滑出
    if (this.pathStack !== null) {
      this.pathStack.pop();
    }
  }

  // 悬停态封面区高度(0.22.0):折痕上缘以上空间 − 状态栏 − 顶栏;无折痕数据回落 45% 视口高
  private hoverCoverH(): number {
    const crease = Breakpoint.creaseTopVp();
    if (crease > 0) {
      return Math.max(160, crease - this.topSafe - 56);
    }
    const density = display.getDefaultDisplaySync().densityPixels;
    const vh = display.getDefaultDisplaySync().height / (density > 0 ? density : 3);
    return Math.max(160, vh * 0.45);
  }

  // 下滑关闭跟手/判定(多手势实例共用:内容 Column + Swiper 两个页面容器)
  private dragUpdate(e: GestureEvent): void {
    if (this.showQueue || this.showMoreSheet || this.dismissing) {
      return;
    }
    const vh = px2vp(display.getDefaultDisplaySync().height);
    const dy = e.offsetY;
    // 仅向下滑跟手;削顶 55%vh——节点拖出屏后手势失灵(KB §9.4),松手动画收尾
    this.dragY = Math.min(Math.max(dy, 0), vh * 0.55);
  }

  private dragFinish(e: GestureEvent): void {
    if (this.showQueue || this.showMoreSheet || this.dismissing) {
      return;
    }
    const vh = px2vp(display.getDefaultDisplaySync().height);
    hilog.info(DOMAIN, TAG, 'dragFinish offsetY=%{public}d vel=%{public}d vh=%{public}d',
      Math.round(e.offsetY), Math.round(e.velocityY), Math.round(vh));
    if (e.offsetY > vh * 0.22 || e.velocityY > 900) {
      this.dismissAnimated();
    } else {
      this.getUIContext().animateTo({ duration: 200, curve: Curve.Friction }, (): void => {
        this.dragY = 0;
      });
    }
  }

  // ===== 0.22.0 抽出的三形态共用子块(原 PlayerBody 内联;窄屏 Swiper/宽屏双栏/悬停态三处复用) =====

  // 封面页(原 Swiper 第 1 页):双击收藏红心爆裂 + 下滑关闭手势
  @Builder
  CoverPage() {
    Stack() {
      Column() {
        if (this.srPm !== null) {
          Image(this.srPm)
            .width(this.playerSkin === 'minimal' ? '52%' : '78%')
            .aspectRatio(1)
            .borderRadius(24)
            .objectFit(ImageFit.Cover)
            .shadow({ radius: 48, color: '#33000000', offsetX: 0, offsetY: 12 })
        } else if (this.songArt.length > 0) {
          Image(this.songArt)
            .width(this.playerSkin === 'minimal' ? '52%' : '78%')
            .aspectRatio(1)
            .borderRadius(24)
            .objectFit(ImageFit.Cover)
            .shadow({ radius: 48, color: '#33000000', offsetX: 0, offsetY: 12 })
        } else {
          Column({ space: 12 }) {
            SymbolGlyph($r('sys.symbol.music_note_list'))
              .fontSize(72)
              .fontColor([$r('app.color.accent')])
          }
          .width(this.playerSkin === 'minimal' ? '52%' : '78%')
          .aspectRatio(1)
          .borderRadius(24)
          .backgroundColor($r('app.color.badge_bg'))
          .justifyContent(FlexAlign.Center)
        }
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      // 红心爆裂层:双击封面收藏后的即时反馈(缩放淡出;轻震动在 burstFavorite 内)
      SymbolGlyph($r('sys.symbol.heart_fill'))
        .fontSize(110)
        .fontColor([$r('app.color.accent')])
        .opacity(this.heartOpacity)
        .scale({ x: this.heartScale, y: this.heartScale })
    }
    .width('100%')
    .height('100%')
    .onClick(() => {
      // 双击收藏(0.20.0):TapGesture count=2 与单击 click 并存时单击会吞双击首击,
      // 改 onClick + 自判 300ms 双击窗口,单击无动作
      const now = Date.now();
      if (now - this.lastCoverTap <= 300) {
        this.lastCoverTap = 0;
        if (this.dblTapFav) {
          this.burstFavorite();
        }
      } else {
        this.lastCoverTap = now;
      }
    })
    // 子级垂直 pan:子手势优先于 Swiper 内建手势(方向正交),封面区下滑可关闭页面
    .gesture(PanGesture({ fingers: 1, direction: PanDirection.Vertical, distance: 8 })
      .onActionUpdate((e: GestureEvent): void => {
        this.dragUpdate(e);
      })
      .onActionEnd((e: GestureEvent): void => {
        this.dragFinish(e);
      }))
  }

  // 歌词页(原 Swiper 第 2 页):逐字歌词面板 + 打轴入口 + 下滑关闭手势
  @Builder
  LyricsPage() {
    Column({ space: 6 }) {
      LyricsPanel({ lyricText: this.lyricsNow() })
        .width('100%')
        .layoutWeight(1)
      Button(this.editLabel())
        .fontSize(11)
        .height(36)
        .fontColor($r('app.color.text_secondary'))
        .backgroundColor($r('app.color.badge_bg'))
        .responseRegion({ x: 0, y: -2, width: '100%', height: 40 }) // 最小可点目标 40vp(0.17.0)
        .onClick(() => {
          const song = PlayerController.get().currentSong;
          const stack = this.pathStack;
          if (song !== null && stack !== null) {
            stack.pushPathByName('LyricsEditor', song.id);
          }
        })
    }
    .width('88%')
    .height('100%')
    .padding({ top: 8, bottom: 8 })
    .justifyContent(FlexAlign.Center)
    .gesture(PanGesture({ fingers: 1, direction: PanDirection.Vertical, distance: 8 })
      .onActionUpdate((e: GestureEvent): void => {
        this.dragUpdate(e);
      })
      .onActionEnd((e: GestureEvent): void => {
        this.dragFinish(e);
      }))
  }

  // 信息 + 引擎徽章(全部走 @State 镜像:切歌经 onPlayerChanged 落镜像驱动刷新)
  @Builder
  PlayerMeta() {
    Column({ space: 6 }) {
      Text(this.songTitle)
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(this.songSub)
        .fontSize(14)
        .fontColor($r('app.color.text_secondary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Row({ space: 8 }) {
        Text(this.engineMirror)
          .fontSize(10)
          .fontColor($r('app.color.badge_text'))
          .backgroundColor($r('app.color.badge_bg'))
          .borderRadius(6)
          .padding({ left: 8, right: 8, top: 2, bottom: 2 })
        if (this.songSpec.length > 0) {
          Text(this.songSpec)
            .fontSize(10)
            .fontColor($r('app.color.badge_text'))
            .backgroundColor($r('app.color.badge_bg'))
            .borderRadius(6)
            .padding({ left: 8, right: 8, top: 2, bottom: 2 })
        }
      }
      .justifyContent(FlexAlign.Center)
    }
    .width('100%')
    .padding({ left: 24, right: 24, top: 8 })
    .alignItems(HorizontalAlign.Center)
  }

  // 进度条(0.19.0:有包络数据时波形条前置,点击波形即 seek)
  @Builder
  PlayerProgress() {
    Column({ space: 4 }) {
      // wavePref 读入条件注册开关依赖(关=波形区整区卸载);waveVer 计数驱动包络上屏/隐藏
      if (this.wavePref && this.waveVer > 0 && this.waveFor >= 0 && this.waveData !== null) {
        Canvas(this.waveCtx)
          .width('88%')
          .height(44)
          .onReady((): void => {
            this.waveReady = true;
            this.drawWave();
          })
          .onClick((e: ClickEvent) => {
            const w = this.waveCtx.width;
            if (w > 0) {
              const frac = Math.min(1, Math.max(0, e.x / w));
              PlayerController.get().seekTo(Math.round(frac * this.durMs()));
            }
          })
      }
      Slider({
        value: this.sliderValue(),
        min: 0,
        max: Math.max(1, this.durMs()),
        step: 1,
        style: SliderStyle.OutSet
      })
        .selectedColor($r('app.color.accent'))
        .trackColor($r('app.color.divider'))
        .blockColor($r('app.color.accent'))
        .width('88%')
        .onChange((value: number, mode: SliderChangeMode) => {
          if (mode === SliderChangeMode.Begin) {
            this.seeking = true;
            this.seekPreviewMs = value;
          } else if (mode === SliderChangeMode.Moving) {
            this.seekPreviewMs = value;
          } else if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
            PlayerController.get().seekTo(Math.round(value));
            this.seeking = false;
          }
        })
      Row() {
        Text(formatDuration(this.sliderValue()))
          .fontSize(11)
          .fontColor($r('app.color.text_secondary'))
        Blank()
        Text(formatDuration(this.durMs()))
          .fontSize(11)
          .fontColor($r('app.color.text_secondary'))
      }
      .width('88%')
    }
    .width('100%')
    .padding({ top: 4 })
  }

  // 控制区:播放模式(左) | 上一曲/播放暂停(动画)/下一曲 | 队列(右)
  // 音量条 0.15.1 起收入「更多」菜单(用户约定)
  @Builder
  PlayerControls() {
    Row({ space: 8 }) {
      Button({ stateEffect: true }) {
        SymbolGlyph(this.modeIcon())
          .fontSize(20)
          .fontColor([this.modeAccent() ? $r('app.color.accent') : $r('app.color.text_primary')])
      }
      .width(46)
      .height(46)
      .backgroundColor(Color.Transparent)
      .onClick(() => {
        const m = QueueService.get().cyclePlayMode();
        hilog.info(DOMAIN, TAG, 'play mode -> %{public}s', m);
      })

      Button({ stateEffect: true }) {
        SymbolGlyph($r('sys.symbol.backward_end_fill'))
          .fontSize(30)
          .fontColor([$r('app.color.control_fg')])
      }
      .width(52)
      .height(52)
      .backgroundColor(Color.Transparent)
      .onClick(() => {
        PlayerController.get().playPrev();
      })

      // 播放/暂停:点击缩放弹跳动画 + symbol 切换(@State 镜像驱动过渡)
      Button({ stateEffect: false }) {
        SymbolGlyph(this.playingMirror ? $r('sys.symbol.pause_fill') : $r('sys.symbol.play_fill'))
          .fontSize(38)
          .fontColor([$r('app.color.on_accent')])
      }
      .width(76)
      .height(76)
      .borderRadius(38)
      .backgroundColor($r('app.color.accent'))
      .scale(this.playBounce ? { x: 0.82, y: 0.82 } : { x: 1, y: 1 })
      .animation({ duration: 160, curve: Curve.Friction })
      .onClick(() => {
        this.playBounce = true;
        PlayerController.get().playPause();
        // 下一帧回弹(等价按下-松开的弹性反馈)
        setTimeout((): void => {
          this.playBounce = false;
        }, 90);
      })

      Button({ stateEffect: true }) {
        SymbolGlyph($r('sys.symbol.forward_end_fill'))
          .fontSize(30)
          .fontColor([$r('app.color.control_fg')])
      }
      .width(52)
      .height(52)
      .backgroundColor(Color.Transparent)
      .onClick(() => {
        PlayerController.get().playNext();
      })

      Button({ stateEffect: true }) {
        SymbolGlyph($r('sys.symbol.list_bullet'))
          .fontSize(20)
          .fontColor([$r('app.color.text_primary')])
      }
      .width(46)
      .height(46)
      .backgroundColor(Color.Transparent)
      .onClick(() => {
        this.showQueue = !this.showQueue;
      })
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ top: 8, bottom: 8 })
  }

  @Builder
  PlayerBody() {
    Column() {
      Blank().height(8)

      // 0.22.0 三形态内容区:悬停(上封面避折痕/下歌词+控制,FolderStack 官方同款上下分区;
      // 半折叠时窗口仍为全屏,上下两半都可交互)| 宽屏 md+(左封面/右歌词,官方 MusicHome
      // 宽屏播放页同构,Q 音乐折叠屏同款)| 窄屏 sm(Swiper 封面⇄歌词,现状)
      if (this.foldHover) {
        Column() {
          Column() {
            this.CoverPage()
          }
          .width('100%')
          .height(this.hoverCoverH()) // 折痕上缘以上:封面区(悬停听歌免手持,官方点名场景)
          Row({ space: 16 }) {
            Column() {
              this.LyricsPage()
            }
            .layoutWeight(1)
            Column({ space: 4 }) {
              this.PlayerMeta()
              this.PlayerProgress()
              this.PlayerControls()
            }
            .layoutWeight(1)
            .padding({ right: 12 })
          }
          .width('100%')
          .layoutWeight(1)
        }
        .width('100%')
        .layoutWeight(1)
      } else if (this.bpMdPlus) {
        Row({ space: 16 }) {
          Column() {
            this.CoverPage()
          }
          .layoutWeight(1)
          Column() {
            this.LyricsPage()
          }
          .layoutWeight(1)
        }
        .width('100%')
        .layoutWeight(1)
      } else {
        // 窄屏:Swiper 左右滑动(封面向左滑→歌词;歌词向右滑→封面)
        Swiper(this.swiperCtrl) {
          this.CoverPage()
          this.LyricsPage()
        }
        .index(this.pageIdx)
        .loop(false)
        .indicator(false)
        .cachedCount(1)
        .width('100%')
        .layoutWeight(1)
        .onChange((i: number) => {
          this.pageIdx = i;
        })
      }

      // 信息 + 引擎徽章(0.22.0 抽 PlayerMeta 三形态共用;镜像链路不变)
      this.PlayerMeta()

      // 频谱可视化(0.18.0):开关开 + 无损引擎 + 有曲目时显示;0.22.0 悬停态隐藏(下半屏空间有限)
      // 0.25.0:右上角 × 直关钮移除(遮挡频谱末端频段,开关收口「更多」菜单);vizPref 经
      // @StorageProp 注册依赖,菜单里关掉即整区卸载(此前仅停帧,频谱冻在最后一帧)
      // 0.25.1:引擎侧条件改读 vizEngineOk 镜像——vizNow() 直读普通字段不被追踪,切歌/换引擎
      // 不重估致频谱区不挂载/不卸载(mp3 起播再切无损实证)
      if (!this.foldHover && this.vizPref && this.vizEngineOk) {
        VizView()
          .width('100%')
          .padding({ left: 28, right: 20, top: 6, bottom: 2 })
      }

      // 进度条(0.22.0 抽 PlayerProgress 三形态共用;波形条前置逻辑不变)
      this.PlayerProgress()

      // 控制区(0.22.0 抽 PlayerControls 三形态共用):播放模式(左) | 上一曲/播放暂停(动画)/下一曲 | 队列(右)
      this.PlayerControls()

      // 底部导航条避让(≥28vp)
      Blank().height(Math.max(this.bottomSafe, 28) + 8)
    }
    .width('100%')
    .layoutWeight(1) // 占顶栏以下剩余空间(height 100% 会把顶栏挤出视口致底部溢出)
  }

  // ===== 右上角"更多"bindSheet 菜单(0.24.0:面板抽为 MoreSheetPanel 子组件获得真响应式) =====

  private moreInitialExpand: string = '';

  private openMoreSheet(expand: string = ''): void {
    this.moreInitialExpand = expand;
    this.showMoreSheet = true;
  }

  @Builder
  MoreSheet() {
    MoreSheetPanel({
      initialExpand: this.moreInitialExpand,
      onClose: (): void => {
        this.showMoreSheet = false;
      },
      onOpenQueue: (): void => {
        this.showQueue = true;
      }
    })
  }

  // 播放队列(0.15.2 改 bindSheet 承载:高度/圆角/动画由 sheet 管理,内容只管列表)
  @Builder
  QueueDrawer() {
    Column() {
      Row() {
        Text($r('app.string.current_queue'))
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
          .padding({ left: 8 })
        // 多队列管理(原队列页签入口迁移至此);热区 40vp(0.17.0 最小可点目标)
        Button({ stateEffect: true }) {
          SymbolGlyph($r('sys.symbol.square_stack_3d'))
            .fontSize(18)
            .fontColor([$r('app.color.text_primary')])
        }
        .width(40)
        .height(40)
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          this.showQueue = false;
          this.pathStack?.pushPathByName('QueueBoard', null);
        })
        // 循环模式 + 播完停止 + 推进边界(原队列页签菜单迁移)
        Button({ stateEffect: true }) {
          SymbolGlyph(this.modeIcon())
            .fontSize(18)
            .fontColor([this.modeAccent() ? $r('app.color.accent') : $r('app.color.text_primary')])
        }
        .width(40)
        .height(40)
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          QueueService.get().cyclePlayMode();
        })
        // 睡眠定时器(原队列页签入口迁移;0.14.0 起档位选择在更多菜单弹层内)
        Button({ stateEffect: true }) {
          SymbolGlyph($r('sys.symbol.timer'))
            .fontSize(18)
            .fontColor([PlayerController.get().sleepRemainMin() > 0 ? $r('app.color.accent') : $r('app.color.text_primary')])
        }
        .width(40)
        .height(40)
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          this.showQueue = false;
          this.openMoreSheet('sleep');
        })
        Button({ stateEffect: true }) {
          SymbolGlyph($r('sys.symbol.trash'))
            .fontSize(18)
            .fontColor([$r('app.color.text_secondary')])
        }
        .width(40)
        .height(40)
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          QueueService.get().clear();
        })
        Button({ stateEffect: true }) {
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(18)
            .fontColor([$r('app.color.text_secondary')])
        }
        .width(40)
        .height(40)
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          this.showQueue = false;
        })
      }
      .width('100%')
      .padding({ left: 8, right: 8, top: 12, bottom: 4 })

      List({ space: 0 }) {
        ForEach(this.queueItems(), (s: Song, i: number) => {
          ListItem() {
            Row({ space: 10 }) {
              Text(String(i + 1))
                .fontSize(11)
                .fontColor(i === this.qIndexMirror ? $r('app.color.accent') : $r('app.color.text_secondary'))
                .width(24)
                .textAlign(TextAlign.Center)
              Column({ space: 2 }) {
                Text(s.displayTitle())
                  .fontSize(14)
                  .fontColor(i === this.qIndexMirror ? $r('app.color.accent') : $r('app.color.text_primary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(s.displayArtist())
                  .fontSize(10)
                  .fontColor($r('app.color.text_secondary'))
                  .maxLines(1)
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              Text(formatDuration(s.durationMs))
                .fontSize(10)
                .fontColor($r('app.color.text_secondary'))
            }
            .width('100%')
            .padding({ left: 12, right: 12, top: 8, bottom: 8 })
            .onClick(() => {
              PlayerController.get().playQueueIndex(i);
            })
          }
        }, (s: Song, i: number): string => `qd_${i}_${s.id}`)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      .padding({ bottom: Math.max(this.bottomSafe, 28) + 8 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.card_bg'))
  }

  // ===== 辅助 =====

  private sliderValue(): number {
    if (this.seeking) {
      return Math.round(this.seekPreviewMs);
    }
    return this.posMs;
  }

  private durMs(): number {
    return Math.max(1, PlayerController.get().durationMs);
  }

  private lyricsNow(): string {
    return PlayerController.get().currentLyrics;
  }

  // 频谱条引擎侧条件已镜像化(0.25.1):vizEngineOk @State 于 refreshSongMirrors 统一刷新

  private editLabel(): ResourceStr {
    return this.lyricsNow().length > 0 ? $r('app.string.edit_lyrics') : $r('app.string.add_lyrics');
  }

  private modeIcon(): Resource {
    const m = this.modeMirror;
    if (m === 'shuffle') {
      return $r('sys.symbol.shuffle');
    }
    if (m === 'one') {
      return $r('sys.symbol.repeat_1');
    }
    if (m === 'loop') {
      return $r('sys.symbol.repeat');
    }
    return $r('sys.symbol.arrow_right');
  }

  private modeAccent(): boolean {
    return this.modeMirror !== 'order';
  }
}


@Builder
export function FullPlayerBuilder() {
  FullPlayerDest()
}

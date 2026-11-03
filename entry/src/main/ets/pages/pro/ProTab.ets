// 专业页:APP 独有调音/引擎能力集中展示——实时输出 + 音频引擎(无损/EQ/RG) + 响度分析 + 专业工具。
import { common } from '@kit.AbilityKit';
import { PlayerController } from '../../service/PlayerController';
import { Song } from '../../data/Model';
import { AppTheme, SafeAreaResult } from '../../common/Theme';
import { L } from '../../common/Lang';
import { CardSection, PrefToggleRow, RgModeRow, RgScanSection } from '../settings/SettingsTab';

@Component
export struct ProTab {
  @StorageProp('playerVer') playerVer: number = 0;
  @StorageProp('themePageBg') themePageBg: string = '';
  @StorageProp('bottomSafeVp') bottomSafeVp: number = 28;
  @State topSafe: number = 36;

  aboutToAppear(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    AppTheme.safeAreas(ctx).then((r: SafeAreaResult): void => {
      this.topSafe = r.topVp;
    });
  }

  private pageBg(): ResourceColor {
    return this.themePageBg.length > 0 ? this.themePageBg : $r('app.color.page_bg');
  }

  private nav(): NavPathStack {
    const stack = AppStorage.get<NavPathStack>('navStack');
    return stack !== undefined && stack !== null ? stack : new NavPathStack();
  }

  private song(): Song | null {
    return PlayerController.get().currentSong;
  }

  private openLyricsTool(): void {
    const s = this.song();
    if (s === null) {
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.not_playing') });
      return;
    }
    this.nav().pushPathByName('LyricsEditor', s.id);
  }

  build() {
    Column() {
      Text($r('app.string.tab_pro'))
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
        .padding({ left: 16, right: 16, top: this.topSafe + 8, bottom: 8 })

      // 能力徽标行
      Row({ space: 8 }) {
        Text($r('app.string.pro_cap_flac'))
          .fontSize(10)
          .fontColor($r('app.color.badge_text'))
          .backgroundColor($r('app.color.badge_bg'))
          .borderRadius(8)
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
        Text($r('app.string.pro_cap_dsd'))
          .fontSize(10)
          .fontColor($r('app.color.badge_text'))
          .backgroundColor($r('app.color.badge_bg'))
          .borderRadius(8)
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
        Text($r('app.string.pro_cap_cue'))
          .fontSize(10)
          .fontColor($r('app.color.badge_text'))
          .backgroundColor($r('app.color.badge_bg'))
          .borderRadius(8)
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
        Text($r('app.string.pro_cap_gapless'))
          .fontSize(10)
          .fontColor($r('app.color.badge_text'))
          .backgroundColor($r('app.color.badge_bg'))
          .borderRadius(8)
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 8 })

      Scroll() {
        Column({ space: 12 }) {
          // 实时输出
          CardSection({ title: $r('app.string.pro_output') }) {
            Column() {
              if (this.song() !== null) {
                Row({ space: 10 }) {
                  Column({ space: 2 }) {
                    Text((this.song() as Song).displayTitle())
                      .fontSize(15)
                      .fontColor($r('app.color.text_primary'))
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text((this.song() as Song).displayArtist())
                      .fontSize(11)
                      .fontColor($r('app.color.text_secondary'))
                      .maxLines(1)
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)
                }
                .width('100%')
                .padding({ top: 8, bottom: 8 })
                Row({ space: 8 }) {
                  Text(PlayerController.get().engineInfo)
                    .fontSize(10)
                    .fontColor($r('app.color.badge_text'))
                    .backgroundColor($r('app.color.badge_bg'))
                    .borderRadius(6)
                    .padding({ left: 8, right: 8, top: 2, bottom: 2 })
                  if ((this.song() as Song).specBadge().length > 0) {
                    Text((this.song() as Song).specBadge())
                      .fontSize(10)
                      .fontColor($r('app.color.badge_text'))
                      .backgroundColor($r('app.color.badge_bg'))
                      .borderRadius(6)
                      .padding({ left: 8, right: 8, top: 2, bottom: 2 })
                  }
                }
                .width('100%')
                .padding({ bottom: 8 })
              } else {
                Text($r('app.string.pro_idle'))
                  .fontSize(13)
                  .fontColor($r('app.color.text_secondary'))
                  .width('100%')
                  .padding({ top: 12, bottom: 12 })
              }
            }
          }

          // 音频引擎
          CardSection({ title: $r('app.string.audio_engine') }) {
            Column() {
              PrefToggleRow({
                prefKey: 'lossless',
                title: $r('app.string.lossless_pref'),
                sub: $r('app.string.lossless_sub')
              })
              Divider().color($r('app.color.divider')).margin({ left: 0 })
              this.NavItem($r('app.string.eq_entry'), $r('app.string.eq_entry_sub'), (): void => {
                this.nav().pushPathByName('Equalizer', null);
              })
              Divider().color($r('app.color.divider')).margin({ left: 0 })
              RgModeRow()
              Divider().color($r('app.color.divider')).margin({ left: 0 })
              this.InfoItem($r('app.string.system_fallback'), $r('app.string.system_fallback_sub'))
            }
          }

          // 响度分析(ReplayGain 扫描)
          CardSection({ title: $r('app.string.loudness') }) {
            Column() {
              RgScanSection()
            }
          }

          // 专业工具
          CardSection({ title: $r('app.string.pro_tools') }) {
            Column() {
              this.NavItem($r('app.string.lrc_tool'), $r('app.string.lrc_tool_sub'), (): void => {
                this.openLyricsTool();
              })
              Divider().color($r('app.color.divider')).margin({ left: 0 })
              this.NavItem($r('app.string.duplicates_title'), $r('app.string.duplicates_sub'), (): void => {
                this.nav().pushPathByName('Duplicates', null);
              })
            }
          }

          Blank().height(this.bottomSafeVp + 140)
        }
        .width('100%')
        .padding({ left: 16, right: 16 })
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.pageBg())
  }

  @Builder
  NavItem(title: ResourceStr, sub: ResourceStr, onTap: () => void) {
    Row({ space: 12 }) {
      Column({ space: 2 }) {
        Text(title)
          .fontSize(15)
          .fontColor($r('app.color.text_primary'))
        Text(sub)
          .fontSize(11)
          .fontColor($r('app.color.text_secondary'))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(14)
        .fontColor([$r('app.color.text_secondary')])
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
    .onClick(() => {
      onTap();
    })
  }

  @Builder
  InfoItem(title: ResourceStr, sub: ResourceStr) {
    Row({ space: 12 }) {
      Column({ space: 2 }) {
        Text(title)
          .fontSize(15)
          .fontColor($r('app.color.text_primary'))
        Text(sub)
          .fontSize(11)
          .fontColor($r('app.color.text_secondary'))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
  }
}

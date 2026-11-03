// 播放控制卡片(M5,2x4 ArkTS 卡片):曲目信息 + 上一曲/播放暂停/下一曲。
// 数据由 UIAbility 侧 formProvider.updateForm 推送(title/artist/playing/hasSong);
// 控制经 postCardAction router 拉起 EntryAbility(want.parameters.params.cardCmd)。
let storage = new LocalStorage();

@Entry(storage)
@Component
struct PlayCard {
  @LocalStorageProp('title') title: string = '';
  @LocalStorageProp('artist') artist: string = '';
  @LocalStorageProp('playing') playing: boolean = false;
  @LocalStorageProp('hasSong') hasSong: boolean = false;

  private sendCmd(cmd: string): void {
    postCardAction(this, {
      'action': 'router',
      'abilityName': 'EntryAbility',
      'params': { 'cardCmd': cmd } as Record<string, Object>
    });
  }

  build() {
    Column({ space: 10 }) {
      Row({ space: 10 }) {
        Column() {
          SymbolGlyph($r('sys.symbol.music_note_list'))
            .fontSize(26)
            .fontColor([$r('app.color.accent')])
        }
        .width(48)
        .height(48)
        .borderRadius(10)
        .backgroundColor($r('app.color.badge_bg'))
        .justifyContent(FlexAlign.Center)

        Column({ space: 3 }) {
          Text(this.hasSong ? this.title : $r('app.string.card_idle_title'))
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.hasSong ? this.artist : $r('app.string.card_idle_sub'))
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')

      Row({ space: 28 }) {
        SymbolGlyph($r('sys.symbol.backward_end_fill'))
          .fontSize(26)
          .fontColor([$r('app.color.text_primary')])
          .onClick(() => {
            this.sendCmd('prev');
          })
        SymbolGlyph(this.playing ? $r('sys.symbol.pause_fill') : $r('sys.symbol.play_fill'))
          .fontSize(32)
          .fontColor([$r('app.color.accent')])
          .onClick(() => {
            this.sendCmd('toggle');
          })
        SymbolGlyph($r('sys.symbol.forward_end_fill'))
          .fontSize(26)
          .fontColor([$r('app.color.text_primary')])
          .onClick(() => {
            this.sendCmd('next');
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .backgroundColor($r('app.color.card_bg'))
    .justifyContent(FlexAlign.Center)
  }
}

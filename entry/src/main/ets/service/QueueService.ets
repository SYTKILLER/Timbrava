// 队列服务:内存为权威 + relationalStore 持久化(防抖双写)。
// 语义:playNow 替换队列;playNext 插到当前后;append 追加;随机 = 重排列表(originalList 记忆,可还原)。
import { hilog } from '@kit.PerformanceAnalysisKit';
import { relationalStore } from '@kit.ArkData';
import { Db } from '../data/Db';
import { LibraryStore } from '../data/LibraryStore';
import { Song, RepeatMode } from '../data/Model';
import { L } from '../common/Lang';

const TAG = '[Timbrava][Queue]';
const DOMAIN = 0x0001;
const QUEUE_ID = 'main';

export class QueueBrief {
  id: string = '';
  title: string = '';
  songCount: number = 0;
  isActive: boolean = false;
  createdAt: number = 0;
}

export class QueueService {
  private static instance: QueueService | null = null;
  static get(): QueueService {
    if (QueueService.instance === null) {
      QueueService.instance = new QueueService();
    }
    return QueueService.instance;
  }

  list: number[] = [];              // 实际播放顺序(song id)
  originalList: number[] = [];      // 随机前原序(还原用)
  currentOrderIndex: number = -1;
  repeat: RepeatMode = RepeatMode.OFF;
  shuffled: boolean = false;
  queueTitle: string = '';
  // 循环扩展(#16):推进边界(下一曲跨出边界即停止)+ 播完当前停止
  boundary: string = 'none';        // none | album | artist | folder
  stopAfterCurrent: boolean = false;

  private saveTimer: number = -1;

  // ===== 多队列(QueueBoard,P1 简化版:切换=重建播放流) =====

  currentQueueId(): string {
    return QUEUE_ID;
  }

  async listQueues(): Promise<QueueBrief[]> {
    const out: QueueBrief[] = [];
    const db = Db.get();
    if (!db.ready()) {
      return out;
    }
    const st = db.storeOrNull();
    if (st === null) {
      return out;
    }
    try {
      const rs = await st.querySql('SELECT id, title, created_at FROM queues ORDER BY created_at DESC');
      while (rs.goToNextRow()) {
        const id = rs.getString(0);
        const title = rs.getString(1);
        const createdAt = rs.getLong(2);
        const rs2 = await st.querySql('SELECT COUNT(*) FROM queue_items WHERE queue_id = ?', [id]);
        let n = 0;
        if (rs2.goToFirstRow()) {
          n = rs2.getLong(0);
        }
        rs2.close();
        const brief = new QueueBrief();
        brief.id = id;
        brief.title = title.length > 0 ? title : L($r('app.string.queue_unnamed'));
        brief.songCount = n;
        brief.isActive = id === QUEUE_ID;
        brief.createdAt = createdAt;
        out.push(brief);
      }
      rs.close();
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'listQueues fail %{public}s', (e as Error).message);
    }
    return out;
  }

  // 以当前活动队列内容创建新队列(命名)
  async saveCurrentAs(title: string): Promise<boolean> {
    const db = Db.get();
    if (!db.ready() || this.list.length === 0) {
      return false;
    }
    const id = `q_${Date.now()}`;
    await db.saveQueue(id, title, this.list, this.currentOrderIndex, 0, this.repeat, this.shuffled);
    this.bump();
    return true;
  }

  // 切换队列:持久化当前 → 载入目标(返回 songIds 供 PlayerController 接管播放)
  async switchTo(queueId: string): Promise<number[]> {
    this.persistNow();
    const db = Db.get();
    const snap = await db.loadQueueById(queueId);
    if (snap === null) {
      return [];
    }
    this.list = snap.songIds;
    this.originalList = snap.songIds.slice();
    this.currentOrderIndex = Math.min(Math.max(0, snap.activeIndex), Math.max(0, this.list.length - 1));
    this.repeat = snap.repeat;
    this.shuffled = snap.shuffled;
    this.queueTitle = snap.title;
    this.bump();
    hilog.info(DOMAIN, TAG, 'switched to queue %{public}s n=%{public}d', queueId, this.list.length);
    return this.list;
  }

  async deleteQueue(queueId: string): Promise<void> {
    if (queueId === QUEUE_ID) {
      return;
    }
    await Db.get().deleteQueueById(queueId);
    this.bump();
  }

  bump(): void {
    AppStorage.setOrCreate('queueVer', (AppStorage.get<number>('queueVer') ?? 0) + 1);
  }

  currentSongId(): number {
    if (this.currentOrderIndex >= 0 && this.currentOrderIndex < this.list.length) {
      return this.list[this.currentOrderIndex];
    }
    return -1;
  }

  currentSong(): Song | null {
    const id = this.currentSongId();
    return id >= 0 ? LibraryStore.get().song(id) : null;
  }

  songAt(index: number): Song | null {
    if (index >= 0 && index < this.list.length) {
      return LibraryStore.get().song(this.list[index]);
    }
    return null;
  }

  // ===== 操作 =====

  setQueueNow(songs: Song[], startIndex: number, title: string): number {
    this.list = songs.map((s: Song): number => s.id);
    this.originalList = this.list.slice();
    this.shuffled = false;
    this.queueTitle = title;
    this.currentOrderIndex = Math.max(0, Math.min(startIndex, this.list.length - 1));
    this.scheduleSave();
    this.bump();
    return this.list[this.currentOrderIndex];
  }

  playNext(songId: number): void {
    if (this.list.length === 0) {
      this.list = [songId];
      this.originalList = this.list.slice();
      this.currentOrderIndex = 0;
    } else {
      const insertAt = this.currentOrderIndex + 1;
      this.list.splice(insertAt, 0, songId);
      if (this.shuffled) {
        const origIdx = this.originalList.indexOf(songId);
        if (origIdx < 0) {
          this.originalList.splice(this.currentOriginalIndex() + 1, 0, songId);
        }
      }
      // 若插在当前之前,当前索引不变;插在当前之后亦不变
    }
    this.scheduleSave();
    this.bump();
  }

  private currentOriginalIndex(): number {
    if (this.currentOrderIndex < 0 || this.currentOrderIndex >= this.list.length) {
      return -1;
    }
    return this.originalList.indexOf(this.list[this.currentOrderIndex]);
  }

  append(songIds: number[]): void {
    for (const id of songIds) {
      this.list.push(id);
      if (this.shuffled && this.originalList.indexOf(id) < 0) {
        this.originalList.push(id);
      }
    }
    if (this.currentOrderIndex < 0 && this.list.length > 0) {
      this.currentOrderIndex = 0;
    }
    this.scheduleSave();
    this.bump();
  }

  removeAt(orderIndex: number): boolean {
    if (orderIndex < 0 || orderIndex >= this.list.length) {
      return false;
    }
    const removedId = this.list[orderIndex];
    this.list.splice(orderIndex, 1);
    const origIdx = this.originalList.indexOf(removedId);
    if (origIdx >= 0) {
      this.originalList.splice(origIdx, 1);
    }
    if (orderIndex < this.currentOrderIndex) {
      this.currentOrderIndex--;
    } else if (orderIndex === this.currentOrderIndex) {
      if (this.currentOrderIndex >= this.list.length) {
        this.currentOrderIndex = this.list.length - 1;
      }
    }
    this.scheduleSave();
    this.bump();
    return true;
  }

  move(from: number, to: number): boolean {
    if (from < 0 || from >= this.list.length || to < 0 || to >= this.list.length || from === to) {
      return false;
    }
    const id = this.list[from];
    this.list.splice(from, 1);
    this.list.splice(to, 0, id);
    if (this.currentOrderIndex === from) {
      this.currentOrderIndex = to;
    } else if (from < this.currentOrderIndex && to >= this.currentOrderIndex) {
      this.currentOrderIndex--;
    } else if (from > this.currentOrderIndex && to <= this.currentOrderIndex) {
      this.currentOrderIndex++;
    }
    this.scheduleSave();
    this.bump();
    return true;
  }

  clear(): void {
    this.list = [];
    this.originalList = [];
    this.currentOrderIndex = -1;
    this.queueTitle = '';
    this.scheduleSave();
    this.bump();
  }

  locateCurrent(): number {
    return this.currentOrderIndex;
  }

  // ===== 播放顺序推进(由 PlayerController 调用) =====

  // 边界比较:下一曲与当前曲的 album/artist/folder 键是否一致
  private sameBoundary(a: Song | null, b: Song | null): boolean {
    if (a === null || b === null) {
      return false;
    }
    if (this.boundary === 'album') {
      return a.albumArtist + '\u0001' + a.displayAlbum() === b.albumArtist + '\u0001' + b.displayAlbum();
    }
    if (this.boundary === 'artist') {
      return a.displayArtist() === b.displayArtist();
    }
    if (this.boundary === 'folder') {
      return a.dirPath() === b.dirPath();
    }
    return true;
  }

  nextIndex(auto: boolean): number {
    if (this.list.length === 0) {
      return -1;
    }
    if (auto && this.repeat === RepeatMode.ONE) {
      return this.currentOrderIndex;
    }
    if (auto && this.stopAfterCurrent) {
      return -1; // 播完当前停止
    }
    let next = -1;
    if (this.currentOrderIndex + 1 < this.list.length) {
      next = this.currentOrderIndex + 1;
    } else if (this.repeat === RepeatMode.ALL) {
      next = 0;
    }
    if (next >= 0 && this.boundary !== 'none' && auto) {
      // 跨出推进边界 → 停止(列表自然播尽时才判;手动切曲不受限)
      if (!this.sameBoundary(this.songAt(this.currentOrderIndex), this.songAt(next))) {
        return -1;
      }
    }
    return next;
  }

  setBoundary(b: string): void {
    const v = b === 'album' || b === 'artist' || b === 'folder' ? b : 'none';
    this.boundary = v;
    this.stopAfterCurrent = false; // 互斥:选边界推进即取消播完停止
    this.persistLoopExt();
    this.bump();
    hilog.info(DOMAIN, TAG, 'loop boundary -> %{public}s', v);
  }

  setStopAfterCurrent(on: boolean): void {
    this.stopAfterCurrent = on;
    if (on) {
      this.boundary = 'none';
    }
    this.persistLoopExt();
    this.bump();
    hilog.info(DOMAIN, TAG, 'stop after current -> %{public}s', String(on));
  }

  // 循环扩展持久化(app_settings;队列表结构不变)
  private persistLoopExt(): void {
    Db.get().setSetting('loopBoundary', this.boundary);
    Db.get().setSetting('stopAfterCurrent', this.stopAfterCurrent ? '1' : '0');
  }

  async restoreLoopExt(): Promise<void> {
    this.boundary = await Db.get().getSetting('loopBoundary', 'none');
    this.stopAfterCurrent = (await Db.get().getSetting('stopAfterCurrent', '0')) === '1';
  }

  prevIndex(): number {
    if (this.list.length === 0) {
      return -1;
    }
    if (this.currentOrderIndex - 1 >= 0) {
      return this.currentOrderIndex - 1;
    }
    if (this.repeat === RepeatMode.ALL) {
      return this.list.length - 1;
    }
    return 0;
  }

  setRepeat(mode: RepeatMode): void {
    this.repeat = mode;
    this.scheduleSave();
    this.bump();
  }

  cycleRepeat(): RepeatMode {
    const next = this.repeat === RepeatMode.OFF ? RepeatMode.ALL
      : this.repeat === RepeatMode.ALL ? RepeatMode.ONE : RepeatMode.OFF;
    this.setRepeat(next);
    return next;
  }

  toggleShuffle(): boolean {
    if (this.shuffled) {
      // 还原原序
      const curId = this.currentSongId();
      this.list = this.originalList.slice();
      this.shuffled = false;
      this.currentOrderIndex = curId >= 0 ? this.list.indexOf(curId) : this.currentOrderIndex;
    } else {
      if (this.originalList.length === 0) {
        this.originalList = this.list.slice();
      }
      const curId = this.currentSongId();
      const rest = this.list.slice();
      // Fisher-Yates
      for (let i = rest.length - 1; i > 0; i--) {
        const j = Math.floor(Math.random() * (i + 1));
        const t = rest[i];
        rest[i] = rest[j];
        rest[j] = t;
      }
      this.list = rest;
      this.shuffled = true;
      this.currentOrderIndex = curId >= 0 ? this.list.indexOf(curId) : 0;
    }
    this.scheduleSave();
    this.bump();
    return this.shuffled;
  }

  jumpTo(orderIndex: number): number {
    if (orderIndex >= 0 && orderIndex < this.list.length) {
      this.currentOrderIndex = orderIndex;
      this.bump();
      return this.list[orderIndex];
    }
    return -1;
  }

  // ===== 持久化(防抖) =====

  private scheduleSave(): void {
    if (this.saveTimer >= 0) {
      clearTimeout(this.saveTimer);
    }
    this.saveTimer = setTimeout((): void => {
      this.saveTimer = -1;
      this.persistNow();
    }, 800) as number;
  }

  persistNow(): void {
    if (!Db.get().ready()) {
      return;
    }
    Db.get().saveQueue(QUEUE_ID, this.queueTitle, this.list, this.currentOrderIndex,
      0, this.repeat, this.shuffled).then((): void => {
      hilog.debug(DOMAIN, TAG, 'queue persisted n=%{public}d idx=%{public}d', this.list.length, this.currentOrderIndex);
    });
  }

  async restore(): Promise<boolean> {
    const saved = await Db.get().loadLastQueue();
    if (saved === null) {
      return false;
    }
    this.list = saved.songIds;
    this.originalList = saved.songIds.slice();
    this.currentOrderIndex = Math.min(Math.max(0, saved.activeIndex), this.list.length - 1);
    this.repeat = saved.repeat;
    this.shuffled = saved.shuffled;
    this.queueTitle = saved.title;
    this.bump();
    hilog.info(DOMAIN, TAG, 'queue restored n=%{public}d idx=%{public}d', this.list.length, this.currentOrderIndex);
    return true;
  }
}

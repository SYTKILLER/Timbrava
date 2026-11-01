// 队列服务:内存为权威 + relationalStore 持久化(防抖双写)。
// 语义:playNow 替换队列;playNext 插到当前后;append 追加;随机 = 重排列表(originalList 记忆,可还原)。
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Db } from '../data/Db';
import { LibraryStore } from '../data/LibraryStore';
import { Song, RepeatMode } from '../data/Model';

const TAG = '[Timbrava][Queue]';
const DOMAIN = 0x0001;
const QUEUE_ID = 'main';

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

  private saveTimer: number = -1;

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

  nextIndex(auto: boolean): number {
    if (this.list.length === 0) {
      return -1;
    }
    if (auto && this.repeat === RepeatMode.ONE) {
      return this.currentOrderIndex;
    }
    if (this.currentOrderIndex + 1 < this.list.length) {
      return this.currentOrderIndex + 1;
    }
    if (this.repeat === RepeatMode.ALL) {
      return 0;
    }
    return -1;
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

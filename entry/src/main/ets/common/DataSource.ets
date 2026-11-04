// LazyForEach 数据源(轻量封装:整表替换 + 局部刷新)
export class BasicDataSource<T> implements IDataSource {
  private items: T[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): T {
    return this.items[index];
  }

  indexOf(item: T): number {
    return this.items.indexOf(item);
  }

  // 当前顺序快照(SongRow 列表上下文用;T 为 Song 时返回 id 列表由调用方映射)
  snapshot(): T[] {
    return this.items.slice();
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const pos = this.listeners.indexOf(listener);
    if (pos >= 0) {
      this.listeners.splice(pos, 1);
    }
  }

  get raw(): T[] {
    return this.items;
  }

  setData(items: T[]): void {
    this.items = items;
    this.notifyReload();
  }

  notifyReload(): void {
    this.listeners.forEach((l: DataChangeListener): void => l.onDataReloaded());
  }

  notifyMove(from: number, to: number): void {
    this.listeners.forEach((l: DataChangeListener): void => l.onDataMove(from, to));
  }
}

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

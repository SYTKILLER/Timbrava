// 多选批量操作服务(0.18.0):全局选择模式状态 + AppStorage 'selVer' 广播。
// SongRow 读 selVer 感知选择模式(点击改勾选),宿主列表页挂 SelActionBar 承载批量操作;
// hostIds 由各宿主页写入(当前列表曲目序),供全选/反选。离开列表页即退出选择模式。
export class SelService {
  private static instance: SelService | null = null;
  static get(): SelService {
    if (SelService.instance === null) {
      SelService.instance = new SelService();
    }
    return SelService.instance;
  }

  active: boolean = false;        // 是否处于选择模式
  ids: Set<number> = new Set<number>(); // 已选曲目 id(Set 迭代保插入序)
  hostIds: number[] = [];         // 宿主页当前列表(全选/反选范围)

  private bump(): void {
    AppStorage.setOrCreate('selVer', (AppStorage.get<number>('selVer') ?? 0) + 1);
  }

  // 进入选择模式(长按行菜单/列表头部菜单入口);initial 为初始已选(通常 1 项)
  start(initial: number[]): void {
    this.active = true;
    this.ids = new Set<number>(initial);
    this.bump();
  }

  // 退出选择模式(操作完成/取消/离开页面)
  stop(): void {
    if (!this.active) {
      return;
    }
    this.active = false;
    this.ids.clear();
    this.bump();
  }

  toggle(id: number): void {
    if (this.ids.has(id)) {
      this.ids.delete(id);
    } else {
      this.ids.add(id);
    }
    if (this.ids.size === 0) {
      // 全部取消即退出选择模式(主流行为)
      this.active = false;
    }
    this.bump();
  }

  selectAll(): void {
    for (const id of this.hostIds) {
      this.ids.add(id);
    }
    this.bump();
  }

  invert(): void {
    const next: Set<number> = new Set<number>();
    for (const id of this.hostIds) {
      if (!this.ids.has(id)) {
        next.add(id);
      }
    }
    this.ids = next;
    this.bump();
  }

  isSel(id: number): boolean {
    return this.ids.has(id);
  }

  count(): number {
    return this.ids.size;
  }

  // 已选 id(保插入序:勾选顺序即批量操作的顺序)
  selectedIds(): number[] {
    const out: number[] = [];
    this.ids.forEach((id: number): void => {
      out.push(id);
    });
    return out;
  }

  // 宿主页注册当前列表(全选/反选范围);列表重载/排序变化时更新
  setHost(ids: number[]): void {
    this.hostIds = ids;
  }
}

// 库内歌曲 path 稳定键:沙箱/本地路径原样;picker 授权的文件/目录 URI 带 'uri:' 前缀
// (与 Db.getSongsByPathPrefix 的清理前缀约定配套)。fs 实际打开时需剥掉前缀。
export function openTargetOf(path: string): string {
  return path.startsWith('uri:') ? path.substring(4) : path;
}

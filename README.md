# Timbrava

基于 HarmonyOS 的音乐播放器应用。

## 环境要求

- [DevEco Studio](https://developer.huawei.com/consumer/cn/deveco-studio/)（配套 HarmonyOS SDK）
- compatibleSdkVersion: `6.1.1(24)` / targetSdkVersion: `26.0.0`

## 构建与运行

1. 使用 DevEco Studio 打开本工程根目录。
2. 等待 IDE 自动完成 `oh_modules` 依赖安装（依赖由 `oh-package.json5` 声明，无需上传）。
3. 连接设备或启动模拟器，点击 **Run 'entry'** 运行。

> 调试签名请在 DevEco Studio 中登录华为开发者账号后由 IDE 自动生成，签名文件（`.p12` / `.cer` / `.p7b` 等）严禁提交到仓库。

## 目录结构

```
├── AppScope/            # 应用级配置与资源
├── entry/               # 主模块（代码与模块资源）
├── hvigor/              # 构建工具配置
├── build-profile.json5  # 工程级构建配置
├── oh-package.json5     # 依赖配置
└── CHANGELOG.md         # 更新日志
```

## 协作约定（多端开发）

1. **开发开始前**：先执行 `git pull --rebase` 检查并同步远程更新，避免冲突。
2. **开发完成后**：在 `CHANGELOG.md` 的 `[Unreleased]` 下追加本次变更记录，再提交并推送。
3. **提交内容限制**：仓库只包含必要的代码、应用资源、README.md 和 CHANGELOG.md。
   签名文件、开发文档、截图一律不得入库（已通过 `.gitignore` 强制排除）。

## License

许可证待定，尚未添加 LICENSE 文件。

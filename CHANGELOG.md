# 更新日志（CHANGELOG）

本项目的所有显著变更都将记录在此文件中。

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [Unreleased]

## [0.2.0] - 2026-11-02

### Added(P0 完整落地,模拟器验证通过)

- 播放闭环:Navigation 路由骨架 + HdsTabs 三页签 + 五分区库页(歌曲/专辑/艺人/流派/文件夹)+ 全屏播放页(队列抽屉)+ 扫描管理 + 设置 + 关于。
- 双引擎:AVPlayer 系统引擎(MP3/OGG/M4A/AAC/APE 兜底)+ Native 无损引擎(dr_flac + 自研 WAV 解码、8MB SPSC 环形缓冲流式、OHAudio 按 S16/S32 建流、SEEKTABLE seek),按扩展名自动选路,无损失败自动回退系统引擎。
- 1GB+ 真无损:1.06GB 24bit/192kHz FLAC 全曲流式播放验证通过,seek 可用(当前 ~1.1s,目标 300ms 列入优化)。
- 媒体库:递归扫描 + 自研标签解析(ID3v2.2-2.4/Vorbis/MP4/APE/WAV INFO/ADTS)+ mtime/size 差分增量 + 封面提取缓存(file:// URI)。
- 队列:持久化恢复/下一首播放/追加/上移下移移除/循环三态/随机还原。
- 系统集成:AVSession 锁屏卡片 + 连续任务 audioPlayback + 音频焦点 + 耳机/蓝牙断开暂停(可配)+ 收藏 + 播放统计入库。
- 主题:深浅色 + 纯黑模式;调试验证通道(want 参数 debugCmd 直通 + 沙箱语料 HTTP 导入)。

### Fixed(验证期修复)

- AVPlayer prepare 竞态:等 initialized 态再 prepare。
- Native 解码器 fd 偏移共享:dup 后统一回卷(wav 探测失败根因)。
- MiniPlayer 零刷新依赖(@StorageProp 未在 build 读取)抽为独立组件。
- 封面路径需 file:// 前缀;存量迁移 migrateArtUri。
- TabBarSymbol 运行时不存在的崩溃 → CustomBuilder 页签。

### Added(P0 进行中,WIP 提交)

- P0 全量骨架:Navigation 路由体系(HdsTabs 底部三页签 + 系统路由表五目的地)、深浅色/纯黑主题资源。
- 播放核心:PlayerController(引擎选路)+ SystemEngine(AVPlayer)+ LosslessEngine(Native 桥)+ AVSession 锁屏控制 + 后台连续任务(audioPlayback)+ 音频焦点/设备断开暂停(默认可配)。
- Native 无损引擎 `timbrava_core`:FLAC(dr_flac,公有领域,§13 登记)+ 自研 WAV 解码、SPSC 环形缓冲流式(1GB+ 硬需求架构)、OHAudio 渲染(S16/S24/S32/F32,FAST 档)、SEEKTABLE/估算 seek、NAPI 命令进/事件轮询出(Flick 式契约)。
- 媒体库:文件夹根目录管理(READ_AUDIO + DocumentViewPicker FOLDER + 沙箱调试通道)、递归扫描、自研标签解析(ID3v2/FLAC/Ogg/MP4/APE/WAV/AAC)、封面缓存、mtime/size 差分增量、relationalStore 全表建库。
- 队列:单队列持久化恢复、下一首播放/追加/上移下移/移除、循环三态 + 随机还原、收藏(红心)。
- 库页:歌曲/专辑/艺人/流派/文件夹五分区(TabSegmentButtonV2+Swiper),全屏播放页 + 队列抽屉。

## [0.1.0] - 2026-11-01

### Added

- 初始化 DevEco Studio 工程骨架（entry 模块，compatibleSdkVersion `6.1.1(24)`）。
- 配置 `.gitignore`：仓库仅保留代码、应用资源、README 与 CHANGELOG；强制排除签名文件、开发文档、截图及构建产物。
- 建立多端协作约定：开发前先拉取远程更新；开发完成后更新本文件并提交推送。

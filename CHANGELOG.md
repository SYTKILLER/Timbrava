# 更新日志（CHANGELOG）

本项目的所有显著变更都将记录在此文件中。

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [Unreleased]

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

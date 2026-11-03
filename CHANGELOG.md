# 更新日志（CHANGELOG）

本项目的所有显著变更都将记录在此文件中。

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [Unreleased]

### Added

- 页面架构 3 页签改版(0.6.0,#首页重构):移除在线曲库形态,**曲库升级为首页**;新增**专业**页(实时输出卡/无损引擎/EQ 入口/ReplayGain 模式与全库扫描/歌词打轴/重复清理工具集中承载);新增**我的**页(曲库统计四宫格含累计播放时长、最近播放/最常播放/收藏智能入口、歌单嵌入、设置/关于入口);**设置降级为我的页二级路由页**(SettingsDest,NavDestination 默认标题栏+状态栏避让);**队列页签移除**,睡眠定时器/循环扩展(播完停止+专辑/艺人/文件夹边界)/多队列管理/清空队列全部迁入全屏播放器队列抽屉顶栏。
- 曲库首页增强:智能列表入口行(最近播放/最常播放/收藏,复用 PlaylistRepo.getSmartSongs + SongListParam,补齐"有数据无入口");最近添加专辑横滑卡(按 date_added 去重取前 10,点击进专辑 SongList);Song 模型补 dateAdded 字段映射。
- 新增 Db.getPlayStatsTotal()(play_count.total_ms 求和);PlaylistsTab 支持 embed 嵌入模式;版本号 0.6.0/versionCode 6000。

### Added

- 关于页新增"检查更新":请求 GitHub Releases 最新版(api.github.com),与包版本号逐段数字比较;有新版弹窗(版本号+发布页链接,可跳系统浏览器),无新版/失败 toast 反馈;按钮带检查中状态。

### Changed

- 主题移除"纯黑"选项(跟随系统/浅色/深色三选);AppTheme 删除 BLACK 分支,SettingsService 加载时把存量 'black' 值迁移为深色。
- 关于页状态栏避让补齐:改用 @StorageProp('topSafeVp')+NavDestination 根 padding(此前只避让了内容区,默认标题栏仍顶到状态栏)。

### Fixed

- 二级页面状态栏避让未生效根因修复:AppTheme.safeAreas 只在 Index.aboutToAppear 读一次,早于 setWindowLayoutFullScreen(true) 生效(时序在 loadContent 回调内),拿到的是全屏前的旧避让值且此后无人更新。对齐 PixLume AvoidanceManager 与《踩坑记录汇总》§4.3/《开发规范》§4:全屏生效后重读一次避让区,并新增 AppTheme.watchAvoidAreas 实时监听 window.on('avoidAreaChange')(TYPE_SYSTEM→topSafeVp / TYPE_NAVIGATION_INDICATOR→bottomSafeVp,px→vp,底部兜底≥28vp),页面 @StorageProp 自动刷新。

### Changed

- 底部页签渐变蒙版(参考 PixLume):HdsTabs barFloatingStyle 的 gradientMask 由全透明改为半透明渐变蒙版——新增 `app.color.tab_bar_mask` token(浅色 #CCF7F7F8 / 深色 #99000000,随主题切换),maskHeight 72(栏高 56+16),内容滚入页签栏下方时呈现柔和渐隐。

### Fixed

- 二级页面状态栏避让:窗口为全屏沉浸布局(setWindowLayoutFullScreen)时系统默认避让失效,NavDestination 默认标题栏顶到状态栏下。为 歌词打轴/歌曲列表/文件夹树/搜索/标签编辑/均衡器/重复清理/队列管理 8 个二级页面的 NavDestination 统一补 `.padding({ top: topSafeVp })`(读 AppStorage 'topSafeVp',由 AppTheme.safeAreas 写入);FullPlayer/扫描设置/关于 此前已自行避让,未动。

### Changed

- 底部页签真正悬浮:Index.ets 的 HdsTabs 此前缺少 `barOverlap(true)`,悬浮胶囊样式未生效、页签贴底;补上后页签抬起固定 28vp,并开启沉浸光感材质(`systemMaterialEffect: IMMERSIVE` + ADAPTIVE 档)。窗口已是全屏沉浸布局,各 Tab 页已有 bottomSafeVp+140 底部避让,无需改动。

## [0.5.0] - 2026-11-02

### Added(P2 收尾,M-H 多语言)

- 多语言资源化(#49):全部 UI 文案抽至 string 资源(base 中文 + en_US 英文,239 项);新增 common/Lang.ets(L/Ls 助手:服务层与模板串经 resourceManager 取值,支持 %s/%d 格式化);页签/设置/播放器/均衡器/扫描/歌单/队列/标签编辑/重复清理/歌词打轴等全页面覆盖;日志与调试通道文案按规范保留中文。
- 组件参数与状态类型同步加宽 ResourceStr(SongListParam.title、CardSection/PrefToggleRow/NavItem/Field/Section/toast 等);SongList 列表 key 去除标题依赖(改 mode+id)。

### 决策(2026-11-03 用户确认)

- 主题取色(封面动态取色)不做——主题保持 跟随系统/浅色/深色/纯黑 四态。

### 遗留

- 系统语言切英文的端到端回归(模拟器深浅色/语言切换无 CLI,留真机);日志文案不翻译(调试规范)。
- 修复:L() 改为原始串+手工替换 %s/%d 占位符——getStringSync 内置格式化要求 %1$s 位置型占位符,普通 %s 多参抛 "Failed to format" 异常(0.5.0 首装实测抓到,引擎信息显示为空)。


## [0.4.0] - 2026-11-02

### Added(P2,开发完成,统一模拟器验证中)

- 倍速(0.5x~3.0x):无损引擎线性插值重采样(变速变调,P2 近似实现),系统引擎走 AVPlayer setSpeed 档位;设置持久化 + AVSession speed 同步。
- A-B 重复:全屏播放页功能行,两点循环(引擎无关,控制层实现)。
- 循环扩展:播完当前停止 / 按专辑推进 / 按艺人推进 / 按文件夹推进(跨边界自动停),队列页循环菜单。
- 跳过静音:无损引擎 DSP 门限压静音(-50dB/500ms 保持,渐变无爆音),全屏播放页开关。
- 均衡器编辑页:31 段竖向滑条(±12dB,0.5dB 步进,拖动即时生效)、内置预设、自定义预设 CRUD(P1 已建表,P2 启用)、AutoEq「GraphicEq:」文本导入(频点线性插值映射)。
- ReplayGain 扫描器(#23):native 全曲解码测响度(50ms 块 RMS 取 95 分位 + 峰值,napi 异步工作),按专辑能量均值聚合,写回 rg_* 字段;设置页全库扫描 + 列表页菜单扫描;扫描后当前曲即时应用。
- DSD 支持(#32,PCM 抽取保底):native DSF/DFF 解码(DSD64/128/256,盒车低通抽取到 88.2kHz F32;DST 压缩不支持),扫描登记时长/采样率,DSD 徽章与引擎信息(DSDxx)。
- 桌面歌词:AVSession AVMetadata.lyric 带 LRC 原文(系统侧渲染)。
- 歌词打轴编辑器(#37):播放中逐行标记时间戳、行文本可编辑、保存入缓存、导出 .lrc(DocumentViewPicker 零权限)。
- LRCLIB 联网歌词(#38):默认关,设置页显式开关;精确 get + search 回退,KB 网络规范(deadline 竞速/HTTP1.1/诚实 UA)。
- FLAC 标签写回(#40):native VorbisComment 重建(其余元数据块与音频字节不动),临时文件 → dr_flac 重开校验(帧数比对)→ rename 原子替换;标签编辑页 + 库自动重索引(CUE 同文件行同步)。
- 批量标签(#41):列表页菜单,统一专辑级字段(空输入保持原值)批量写回 FLAC,带进度。
- 重复清理(#9):同标题+艺人±2s 或同体积同时长跨路径检测,分组报告,从库移除(不删文件)。
- 备份恢复(#50):设置/歌单/收藏/队列/EQ 预设/黑名单 → JSON,零权限 DocumentViewPicker 导出/导入,歌单按文件路径重挂。
- 播放页皮肤(#53):标准(大封面)/极简,设置页外观选择。
- 平板分栏(#54):Navigation Auto 模式,宽屏(≥600vp)自动 Split(46% 栏宽),手机不变。

### Fixed

- MiniPlayer 未避让底部导航条与悬浮页签(抬升 = 导航条 + 页签占位,安全区 token 化 bottomSafeVp)。
- DSP 开启 + 16bit FLAC 破音隐患:渲染回调按 F32 字节数读整型源导致转换条件不满足时直读原始字节;重写为按输出帧数反推源字节数。
- 队列页循环/随机按钮无状态区分(重复 OFF/ALL 同图标同色、随机死分支)。
- AVSession loopMode 空 catch 吞错。
- 全部 Tab 页列表底部留白接入动态安全区(导航条 + MiniPlayer + 页签占位)。
- seek 预填阈值 256KB/1s → 96KB/0.5s(1GB 文件 seek 响应优化,待真机复测)。

### 遗留(至下阶段)

- 多语言 string.json 中英资源化(#49):约 300 处字符串,为保证统一验证质量主动延后。
- DSP 听感/波形验证与 DSD 听感(待真机)。
- DSD DST 压缩、DoP 直通(USB DAC P3 阶段一并评估)。

## [0.3.0] - 2026-11-02

### Added(P1,模拟器验证通过)

- 歌词:自研 LRC 解析器(行级+逐词扩展+offset)+ 内嵌提取(ID3 USLT/FLAC VorbisComment/MP4 ©lyr)+ 缓存表 + 全屏播放页同步歌词面板(当前行高亮/自动居中),实测 FLAC 内嵌歌词 6 行渲染与高亮跟随。
- 歌单:PlaylistRepo(CRUD/排序/智能歌单 recent·added·most)+ 歌单第六分区 + 列表「存为歌单」+ M3U 解析/导出(沙箱 exports/)。
- 多队列 QueueBoard:命名队列保存/切换接管/删除,队列页入口。
- DSP(31 段 PEQ + ReplayGain + 软压限):Native 三槽无锁系数切换、F32 渲染管线、整型→F32 转换、预设 5 种(bass/vocal/treble/rock/electronic)、RG 按曲目标签自动应用;设置页开关接入。
- CUE 分轨:自研解析器(FILE/TRACK/INDEX 00/01/pregap)+ 扫描集成(同文件多行裁剪区间)+ 播放区间控制(起点 seek/终点自动切曲/进度换算)。
- 全局搜索:歌名/艺人/专辑 LIKE 模糊匹配,300ms 防抖 + 代次防串,搜索页路由。
- 睡眠定时:15/30/45/60/90 分钟菜单,到点自动暂停。
- 黑名单:路径前缀忽略,扫描过滤,扫描页管理 UI。
- UI:HdsTabs 悬浮式底部页签(barFloatingStyle,API 23+,符合规范);搜索按钮启用。

### Fixed

- FullPlayer 切曲不刷新:playerVer/posVer 在 build 中条件读取;歌词面板位置改为组件内自取(规避 @Builder 传参快照)。
- 歌词面板高度塌陷:Stack 中 layoutWeight 无效,改显式高度容器。
- FullPlayer 打开时歌词不加载(晚于播放打开时 @Watch 不补发),aboutToAppear 主动加载。
- debugPlay/导入流程:沙箱根目录自动注册+chmod。


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

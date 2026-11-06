# 更新日志（CHANGELOG）

本项目的所有显著变更都将记录在此文件中。

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [Unreleased]

### Added/Fixed(0.17.0 实测反馈 14 项批量:曲库/歌单/我的页改版 + 播放页返回动画/收藏/热区修复)

- **空专辑修复(#1)**:专辑分组键是 `album_artist`,但专辑卡点击传的是首曲 `displayArtist()`——凡 album_artist≠曲目艺术家(合辑/带专辑艺术家标签),点进详情过滤为空,即"空专辑"。Album 新增 `groupArtist`(分组键原值),网格点击改传 `groupArtist`,展示名同样回退分组值。
- **歌单改版(#2/#13/#14)**:我的页歌单改卡片容器——延伸到屏幕最底部,左上角"+"新建(弹窗输入歌单名,替代常驻行内输入框);歌单详情页右上角"存为歌单"换成"添加歌曲"(半模态:搜索+全库曲目逐曲加入,串行化追加防 position 并发顶掉);曲库分区"流派"整体换为"歌单"(实测流派标签长期为空);歌单与专辑/艺人聚合列表语义不再混用(去重页/存为歌单按钮各归其位)。
- **我的页统计滞后修复(#3)**:计数此前在 build 内直读且刷新只更新总时长——导入/播放后纹丝不动。全部改 @State + `statsVer` 广播(Db.recordPlay 落库即 bump),曲库/播放变化即时反映。
- **播放页返回双重动画根治(#4)**:内容下沉后露出 NavDestination 不透明底色("空背景"),pop 默认横向转场再把它整体滑走。NavDestination 强制透明 + 下滑位移改挂整层 Stack(皮肤背景层同步跟手),跟手阶段直见下层页,pop 转场全程不可见;沉浸皮肤无封面曲补基底垫色。
- **我的页改版(#5/#6)**:"添加歌曲"右侧并列"曲库管理"(新页:重新扫描/去重识别/添加歌曲聚合);通用区移除(关于已在设置页内),设置入口收进右上角四点钮(`dot_grid_2x2`,华为"更多选项"语义);播放页右上角"更多"同样改四点钮。
- **队列 BindSheet 多档高度(#7)**:`detents [MEDIUM, LARGE]` 默认中档、上滑展开大档;抽屉右上按钮 32→40vp;EQ 横竖屏旋转钮 16vp 视觉 → 40vp 标准钮(用户实测过小)。
- **更多菜单头部重做(#10)**:系统 showClose 几何不可控——改自绘头部(48vp 关闭钮 + 标题与其垂直居中对齐 + 关闭钮与音量条间预留 8vp)。
- **全量按钮热区审计 ≥40vp(#8)**:搜索/排序钮 40;SongList 播放全部/随机 40、波形菜单 40;EQ 存为预设/导入/清除覆盖/归零 40;队列/搜索/打轴/去重/历史/关于全部小钮放大或 responseRegion 外扩(档位 chips 36+热区 40);迷你条下一曲 40;PlayHistory 滑删钮 16→36。
- **状态栏(控制中心)收藏按钮修复(#9)**:AVSession 从未上报 `AVPlaybackState.isFavorite`——控制中心红心不可用。播放态上报补 isFavorite,收藏变化后即时同步(d.ts 确认字段,API 10+)。
- **曲库顶部重构(#12)**:智能列表改分段 stack(顺序:我的收藏/播放历史/最常播放/最近添加),下方封面横滑行随选中切换,点封面以对应列表起播、「查看全部」跳对应列表。
- **播放全部(#11)**:歌曲分区 stack 下方左侧新增——清空队列后将曲库全部歌曲(当前排序)加入播放队列并从首曲起播。
- 多语言:新增 8 键(base+en_US)。版本号 0.17.0/versionCode 17000。

### Added/Fixed(0.16.0 歌词获取补全 + 循环回绕卡死修复 + 底部避让补齐)

- **循环模式最后一首播完卡死修复(0.15.x 遗留,模拟器复现实锤)**:循环回绕(最后一首→第一首)走 gapless 预排时,native swap 穿界通知与 end 事件竞态——ArkTS 滞留旧曲、重播、recordPlay 双写,用户观感"卡住不切歌"(手动下一首正常)。修复:`refreshGaplessPrefetch` 对回绕目标(next ≤ 当前序)不再预排,回绕走已验证可靠的 TRACK_END→autoNext 普通路径(引擎重开 ~100ms 停顿,可接受);实测 seek 到最后一首结尾,自然 end → 自动切第一首,后续 dbg_a→dbg_b→CueA→Ending 循环链路健康推进。
- **歌词获取路径补全(对齐开源播放器通行方案)**:①伴生 .lrc 自动加载——播放时检查歌曲同目录同名 .lrc(Poweramp/Musicolet/foobar2000 惯例,零操作来源),命中即入缓存;②打轴页新增「导入 .lrc」按钮(DocumentViewPicker 选文件→解析进编辑器,时间戳行直接可用);③空态文案去掉"先在文件里内嵌歌词"的旧引导,改为导入/伴生/LRCLIB 三条路径。LRCLIB 联网获取(设置开关)与文件头内嵌提取原有保留。
- **底部 28vp 手势条避让补齐**:歌词打轴页底部操作行(bottom 16→max(bottomSafeVp,28));去重页身份列表(24→同式);播放历史两个列表补 contentEndOffset;其余路由页审计达标(SongList 60/Search 40/QueueBoard 40/TagEditor 40/About 60)。
- 多语言:新增 3 键、更新 1 键。版本号 0.16.0/versionCode 16000。

### Fixed(0.15.2 三轮实测反馈:迷你条封面闪烁/队列抽屉改标准半模态/返回键纵向滑出)

- **迷你条切页签封面闪烁**:日志实锤根因——HdsTabs 切页签内部回落会重挂 miniBarBuilder,MiniPlayer 组件销毁重建(aboutToDisappear→aboutToAppear),新 Image 节点异步解码封面出空帧。修复:封面 Image 加 `syncLoad(true)`(44px 小图同步解码,重挂首帧即有图);MiniPlayer 增加生命周期 debug 日志。实测连拍 6 帧,封面区域色彩分布逐帧一致(2688 色),无空帧。
- **播放队列改标准 bindSheet 半模态**:此前为 Stack 内 if 条件自绘抽屉(无转场,直接闪现)——改 `.bindSheet`(height 55%、无 dragBar/关闭钮,头部自带),获得标准上滑动画、蒙层、下拉关闭与 Back 响应;onDisappear 复位 showQueue。实测连拍抓到上滑中帧,Back 正常关闭。
- **播放页返回键/系统返回改纵向滑出**:0.15.0 只修了下滑手势路径,顶栏 chevron_down 与系统 Back 仍走默认 pop 横向转场——统一走 dismissAnimated(与手势同款 220ms 纵向滑出后 pop),onBackPressed 消费返回。实测 Back 连拍:纵向滑出中帧,无横向位移。
- 版本号 0.15.2/versionCode 15002。

### Fixed(0.15.1 二轮实测反馈:迷你条重置闪动/EQ横屏全屏/音量条入菜单/旋转钮热区)

- **迷你条切页签"重置后闪恢复"根治**:上一版 900ms 定时补救只是把闪动窗口缩小,用户仍可见"重置→恢复"。改为双保险:① 用户态样式持续同步进 barFloatingStyle.miniBar 配置对象(syncCacheStyle)——HdsTabs 切页签/旋转的内部回落以配置态为准,回落即落在用户当前态(源头消除);② onBarStyleChange 增加 mode 参数判别(HdsTabsBarChangeMode)——非 USER_CLICK 的内部回落(切页签/旋转)若与用户镜像态不一致,**当场** applyMiniBarStyle 重新断言且污染值不写入镜像(无延时)。模拟器连拍实测:COLLAPSE 态点页签/横滑切页签全程 4 帧形态稳定、EXPAND 态切页签同样稳定,日志无 mismatch。
- **EQ 横屏全屏**:此前横屏时 NavigationMode.Auto 分栏(≥600vp)把下层页面露在左侧、EQ 只占右半屏——EQ 页 onReady 强制 Navigation Stack(AppStorage token eqFullscreen → Index .mode 响应式切换),离页恢复 Auto;横屏实测 EQ 全屏,一屏可见 24+ 调音条。
- **播放页音量条收进「更多」菜单**(用户约定):主体移除音量 Row,菜单首行新增音量行(喇叭 icon + Slider + 百分比);openMoreSheet 统一入口打开时镜像对齐当前引擎值;实测点击滑条落库(volume -> 52)。
- **EQ 旋转钮热区**:视觉保持 16vp(单位确证:实测渲染 56×56px = 16vp × 密度 3.5,非 px),responseRegion 热区扩到 40vp(鸿蒙最小可点目标);实测点击视觉边界外 54px 仍命中切换。
- 版本号 0.15.1/versionCode 15001。

### Changed(0.15.0 实测反馈批量修复:迷你条/播放页/EQ/设置/去重/歌词预取)

- **迷你条折叠态跨页签保持**:HdsTabs 页签切换动画结束后会内部把迷你栏重置回 pill+圆钮形态并经 onBarStyleChange 回写镜像(污染用户态)——onChange 先记录切换前折叠态,900ms 后恢复断言(applyMiniBarStyle)+ 镜像还原;barFloatingStyle 样式对象记忆化(此前每次 rebuild 生成新对象触发迷你栏重初始化)。模拟器实测:折叠态切页签保持,日志 reassert→sync collapsed=1 闭环。
- **空队列迷你栏占位**:无当前曲时迷你栏渲染「空队列 · 去曲库挑首歌」占位行(此前 Visibility.None 露出 HdsTabs 空壳)。
- **播放页下滑退出动画修正**:此前 pop 前先复位 dragY(页面瞬间回位)+ 默认 pop 转场(整体右滑),与下滑手势直觉矛盾——改为保持离屏位移直接 pop,aboutToDisappear 清零;实测中帧纵向滑出、无右滑残帧。
- **播放页切歌信息刷新(0.14.0 回归修复)**:`if (playerVer < 0)` 注册依赖写法条件恒假不重评、兄弟节点零依赖——标题/艺人/专辑/封面/引擎徽章切歌纹丝不动;全部改 @State 镜像(onPlayerChanged/onLibChanged/onQueueChanged 落镜像),含队列抽屉当前序高亮。实测:手动/自动切曲全部联动。
- **沉浸皮肤可见化**:主题色蒙版 opacity 0.87→0.62(此前几乎盖死模糊封面,用户感知"皮肤没生效");极简皮肤封面 56%→52%。
- **最近添加横滑卡重做**:专辑卡改逐曲封面(左=最新 10 首,.ListDirection Horizontal——此前 List 默认纵向被 118vp 裁剪只露 1 项,即"只能显示一首"根因);点击封面以「最近添加」队列(前 50,与查看全部一致)从本曲起播;末尾「查看全部」占位封面跳 smart added 列表。
- **EQ 页**:预设 Select 按内容自适应(限宽 58%,不再吃满整行);存为预设/导入改 symbol 圆角钮(save / square_and_arrow_down);支持横屏——底部归零钮上方 16vp 圆形旋转钮手动切换横竖屏(display.Orientation 读方向 + 离页还原 UNSPECIFIED),横屏分栏可见调音条翻倍;底部小字/归零钮避让抬升 ≥28vp(bottomSafeVp token)。
- **专业页**:「系统引擎兜底」独立说明行移除,改无损引擎开关左侧 info 圆钮(showAlertDialog 弹说明);「响度分析」组更名「ReplayGain 配置」并整合为两项——ReplayGain 扫描 + 应用模式(关闭/按曲目/按专辑,改 Select);专业工具移除重复清理入口(与设置页重复);RgScanSection 改 @Watch 落 @State 镜像(修复同款无效依赖模式)。
- **设置页**:首组(媒体库)与页标题间距对齐组间距(top 12);主题/播放页皮肤改 Select(跟随系统/浅色/深色;标准/极简/沉浸);**AMOLED 纯黑功能与设置项整体移除**(SettingsService/Theme/strings)。
- **重复清理页改造**:改三页签「待分析曲目 / 已去重曲目 / 重复分组」——待分析=SHA-256 未收敛路径聚合列表(带「立即分析」按钮,hashVer 逐路径 bump 驱动刷新);已去重=内容身份确认列表;分组每组**默认保留最早入库的一首**(此前取列表首行,与入库时间无关),移除链路实测(15→14 条,计数联动);页签计数/列表体内直读修复 @Builder 参数快照不刷新。
- **联网歌词静默预取**:身份收敛 Stage B 每条路径 SHA-256 落定后即对路径下全部行(LRCLIB 开关开启时)预取歌词落缓存,导入/重扫完成后自动触发收敛(不等下次启动);实测日志:hash done=15 → 逐路径 lrclib 请求(语料无对应歌词 404,链路完整)。
- 调试通道:EntryAbility 新增 `debugClone n`(批量复制语料+尾部写独特样本绕开内容查重,滚动/列表大数据验证)。
- 多语言:新增 14 键、移除 2 键(base 中文 + en_US)。版本号 0.15.0/versionCode 15000。

### Changed(0.14.1 迷你条折叠方向反转,用户约定)

- **迷你条折叠逻辑反转**:原"向列表尾部浏览(上滑)折叠/回滚展开"改为"**向头部回滚(下滑)折叠**/正向浏览展开"——浏览既定内容时收起迷你条聚焦列表,正常下滑听歌时迷你条常驻可切歌;BarCollapse 累积判定对调(负向 24vp 折叠/正向 12vp 展开),模拟器三段日志实测(正向不折叠→回滚 collapsed=1→再正向 collapsed=0)。版本号 0.14.1/versionCode 14001。

### Added(0.14.0 播放页体验重构 + 曲库浏览效率,对齐 QQ音乐/网易云/华为音乐共识)

- **播放页下滑关闭手势**:垂直下拉跟手(削顶 55%vh 防手势失灵),位移/速度双阈值判定关闭或回弹;内容 Column + Swiper 两页容器三处绑定(子级手势优先于 Swiper 内建手势,Swiper 区垂直事件被其内建手势吞掉的场景走真机实测);顶栏返回键改 chevron_down。
- **播放页顶栏收藏红心**:一键收藏当前曲,收藏态 accent 高亮(libVer 依赖注册,修复更多菜单红心状态此前不刷新的潜伏问题)。
- **播放页音量条(双引擎)**:无损引擎走 native `OH_AudioRenderer_SetVolume`(napi `setVolume` 已有),系统引擎走 AVPlayer `setVolume`(API 9);`IAudioEngine` 契约加 `setVolume`;设置持久化(app_settings `playerVolume`),开新曲 prepared 后重放。
- **睡眠定时渐弱**:到点前 30s 线性渐弱(引擎音量链路),到点暂停并还原音量。
- **更多菜单重做**:新增均衡器直达(全局 EQ,免专业页三级跳);倍速/睡眠定时从"循环点击"改弹层档位 chips(0.5x~3x / 关闭~90 分钟,当前档位高亮);修复 @Builder 参数快照导致的 label 不刷新(体内直读)。
- **沉浸皮肤(第三皮肤)**:封面高斯模糊(blur 120px)+ 主题色蒙版(opacity 0.87,保证 text token 对比度)全屏背景;设置外观三选:标准/极简/沉浸。
- **AMOLED 纯黑**:深色实际生效时页面背景覆盖 #000000(themePageBg 覆盖位启用);`onConfigurationUpdate` 重算覆盖位(拆分 apply/recomputeOverride + 再入哨兵,修复 setColorMode 与配置回调互递归导致的启动栈溢出 jscrash)。
- **曲库分区排序**:歌曲(标题/艺人/专辑/最近添加/时长)、专辑(名称/艺人/最近添加/歌曲数)、艺人(名称/歌曲数)bindMenu 排序,持久化 app_settings;索引条仅按名称排序时显示。
- **字母索引条**:歌曲/艺人分区 AlphabetIndexer(API 7)+ 字母分组头;汉字拼音首字母经 `i18n.Transliterator('Any-Latin')`(API 9,设备不支持退化 '#');点选跳组+滚动反向高亮+气泡(气泡字色修 badge_text 防白底白字)。
- **SongList 头部卡**:专辑模式封面头图/其他模式图标瓦片 + 统计行(专辑/曲目数·总时长,小时/分钟自适应)+「全部播放 N/随机播放」双钮(随机经 toggleShuffle);原 play_all 按钮从动作行迁入。
- **搜索增强**:搜索历史(最近 10 条,提交即记,单删/清空,app_settings 持久化)+ 结果分类 chips(歌曲/专辑/艺人命中数,从 300 条命中聚合,专辑/艺人点击跳详情)。
- **修复:最近添加自 M6 起恒空**——`upsertSong` 从不写 date_added(恒 0)且 SONG_COLS 漏 date_added 列:补写入(新增取当前时间)+ 查询列 + 存量回填迁移(mtime×1000 兜底,幂等标记 dateAddedBackfill1)。
- **修复:曲库分段器点击无响应**——TabSegmentButtonV2 `$selectedIndex` 事件从未接线(只能滑动切页),接 Swiper.changeIndex。
- **修复:曲库索引条压住行内徽章**——索引条显示时列表右侧留白 26vp。
- 多语言:新增 22 键(base 中文 + en_US),共 317 键。版本号 0.14.0/versionCode 14000。

### Added(0.13.0 两级身份:fp 快速识别 + SHA-256 静默收敛)

- **fp 操作身份(xxHash3-128 三窗采样)**:导入查重从全文件 SHA-256(约 0.7s/GB)降为毫秒级——native 新增 `fingerprintFd` 原语(vendored xxHash v0.8.3,BSD-2,与 dr_flac.h 同模式):头/中/尾 3×256KB 采样 + 体积混入,≤768KB 文件退化为全文件指纹;导入/认领/合并/查重页/备份重挂的全部决策键从 hash 切换为 (fp, cueStartMs),前台零全量读。
- **SHA-256 降级为权威确认层**:不再在导入时同步求值——`convergeIdentities` 三段后台收敛(A:fp 秒级回填全库 → B:hash='' 逐文件 SHA-256 → C:fp 碰撞审计);逐文件提交、按状态查询续跑,APP 任意时刻终止重启自动续算(0.12.0 backfill 机制扩展);识别在 hash 缺失期间完全正常(fp 主身份)。
- **fp 碰撞审计兜底**:采样指纹相同但权威 hash 不同的组(概率 ~2⁻¹²⁸)自动升级整文件 fp 消歧并留日志。
- **pcm_md5 音频身份**:FLAC STREAMINFO 自带 PCM MD5(MetaParse.parseFlac 现有 34 字节缓冲内直接提取,零额外 I/O)——tag 免疫:FLAC 改标签后移动的文件按 (pcm_md5, cueStartMs) 认领(仅认领不查重,同音频不同文件是合法多版本);升级后 Stage A 对存量 FLAC 头解析回填。
- **CUE fp 复用修复(0.12.0 隐患)**:分轨行携带音频 fp;parseCueFile 从同 path 任一行复用 fp(此前只查整轨行,分轨覆盖文件每次重扫全量重算 SHA-256)。
- 备份导出附 `fpByPath`(全量)+ `hashByPath`(兼容保留),恢复重挂顺序 path → fp → hash;查重页精确分组键 hash→fp;`dup_note` 文案同步。
- 版本号 0.13.0/versionCode 13000。

### Added(0.12.0 曲库内容身份:哈希唯一识别)

- **曲目身份 = (文件 SHA-256, cueStartMs)**:曲库由 path 唯一键升级为内容哈希唯一身份——native 新增 `hashFd` 摘要原语(Crypto Architecture Kit `OH_CryptoDigest` SHA256,API 12,链 libohcrypto.so;napi 异步工作 Promise 返回,pread 8MB 分块防大 DSD 撑爆 page cache);songs 表加 `hash` 列(app_settings 标记幂等迁移,ALTER 挂列免重建)+ idx_songs_hash;path 降级为"当前位置"属性,歌单/收藏/历史/歌词缓存等全部 song_id 外键零改动。
- **查重无感知自动化**:导入即哈希——同内容跨路径旧文件仍在→自动跳过(deduped 计数);旧文件已失联→移动认领 relink(原行改挂新路径,id 与全部关系保留);rescan 清理失联路径升级 `retireSongsByPaths` 合并语义(同 (hash,cueStartMs) 幸存行先继承 favorites/history/play_count/playlist_songs/lyrics_cache 关系再删行,防双失联关系丢失的两阶段退役);扫描统计追加"重复跳过/移动认领"段(有非零才显示)。
- **CUE 分轨同权**:分轨身份键 (hash, cueStartMs),整轨/分轨压制与 stale 清理保持 path 键(单文件实例内语义);音频 hash 每文件求值一次全轨共用,未变文件复用免二次求值。
- **存量库无感知回填**:启动后 `backfillHashes` 串行补齐 hash='' 行(fire-and-forget 不阻塞首帧,扫描优先让路,失联文件留空待自愈);mtime+size 未变的差分跳过零哈希开销,身份终身一次求值。
- **备份恢复按内容重挂**:导出附 `hashByPath` 映射(增量兼容旧备份),恢复 path 失配(跨设备/换目录)时按 hash 重挂歌单/收藏/队列。
- **查重页精确分组**:第一优先按 (hash, cueStartMs) 精确分组(标"内容相同"),启发式降级"疑似"兜底 hash='' 存量行;CUE 按轨对轨比较防整组混轨。
- 版本号 0.12.0/versionCode 12000。

### Fixed

- 曲库列表底部白区/断行修复:四个分页 List/Grid 的底部避让由 `.padding({bottom})` 改为 `.contentEndOffset()`——ArkUI 列表 padding 会内缩滚动视口,行到 padding 上缘被裁断形成白区(页头收起态尤甚);contentEndOffset 只约束滚动终点,视口全出血渲染到屏底,行可穿过迷你条/悬浮页签下方(对齐华为音乐形态)。

### Added(0.11.0 API 24/26 新特性创意落地)

- **24-1 曲库页头联动收起(嵌套滚动)**:标题/智能入口/最近添加/分段器收入外层 Scroll,四分区内容 List/Grid 经 `nestedScroll(PARENT_FIRST/SELF_FIRST)` 链接——上滑先收页头再滚列表、回滚先到顶再展开页头;与 0.10.0 滚动折叠迷你条形成完整沉浸浏览链路(Tabs.nestedScroll 为 API 24 特性,免守卫)。
- **24-2 逐字卡拉OK歌词底座**:LyricsPanel 活动行逐词染色(已唱=主色/正在唱=强调色/未唱=次色,A2 扩展 `<mm:ss.xx>` 词标签);点词跳播——`TextController` 布局管理器 `getCharacterPositionAtCoordinate`(API 24)点击坐标(px)→字符偏移(UTF-16/UTF-8 字节双轨换算)→定位所属词 seek 词起点,定位失败退化整行 seek;长行 `EllipsisMode.MULTILINE_CENTER`(API 24)多行缩略。
- **26-3 native mmap 大文件读流**:`MmapFile`(≥16MB 整文件映射+madvise WILLNEED)接入无损引擎——FLAC 大文件走 `drflac_open_memory` 映射直读(解封装零 read 拷贝、seek 指针归位),DSD(DSF/DFF) 采样热路径 `countOnesAt` 每帧逐通道取窗由 fseek+fread 改指针直读(免 syscall);小文件/映射失败回退 FILE* 流路径。工程选型说明:落地在 C++ 层 POSIX mmap(全 API 版本可用),非 ETS fs.mmap(26)——直击 1GB+ IO 瓶颈且无需守卫。
- **26-2 全局复用池**:SongRow 加 `@Reusable`(API 10)+ Index 作为全局池宿主 `@Component({reusePool:'shared', poolAccepts:[SongRow]})`(26;编译器强制两者同给、禁止池宿主自引)——曲库/歌单/搜索/队列四处滚动节点跨页面互复用;24 运行时忽略未知 option 键,@Reusable 照常生效。
- **26-5 封面超分(Core Vision)**:`CoverSuperRes` 服务——嵌入封面短边<500px 时 `ImageSRAnalyzer.create().process()`(26,HMS)实时超分,守卫 sdkApiVersion≥26 + VisionBase syscap 双检,失败静默降级原图;FullPlayer 大封面优先展示超分结果。
- **26-6 实况窗进度环(Live View Kit)**:`LiveViewService` PROGRESS 场景 ProgressCapsule(max/progress)+ LAYOUT_TYPE_PROGRESS 主区,播放中锁屏/通知中心可视化;进度按 5% 步进节流,暂停/无歌即停;26+isLiveViewEnabled 守卫,实况窗场景权未授(AGC)时静默停用记日志。
- **26-7 桌面歌词(floatView)**:`DesktopLyricsService` + `pages/player/DesktopLyricsPage`(floatView 标准悬浮窗,ROUNDED_RECTANGLE 模板)——仅当前行,词级双色已唱/未唱,marquee 长行;播放页「更多」菜单入口(26+isFloatViewEnabled 守卫,FLOAT_VIEW 权限未授提示后停用)。
- **targetSdk 26 行为变更回归(§3)**:V2 触摸热区——播放历史删除钮视觉 16vp+热区扩 40vp(responseRegion)、队列管理删除 30→32、打轴删行 28→32;V1 弹层审计(更多 Sheet 主题 token/系统菜单默认材质)合规、V5 无 radius:0 阴影、V3 文本与 V6 复用规则入模拟器验证清单。
- **小型项**:24-4 `getRdbStoreSync` 同步建库(消除首帧与 RDB 初始化异步竞态);24-6 `setBackgroundPlayMode(ENABLE_BACKGROUND_PLAY)` 显式声明后台播放模式;24-3 LRCLIB 已有 connectTimeout/readTimeout+deadline 竞速(全工程无 taskpool 调用点,RG 扫描走 native 线程,taskpool 超时无落地场景,如实跳过)。
### Fixed(0.11.0 验证期实测发现)

- **歌词词级解析潜伏 bug(0.3.0 起)**:模块级 `/g` 正则 `WORD_TAG.lastIndex` 复位后 while 重入从 0 重复匹配,首个时间标签被当词文本渲染(逐词歌词真语料实证);改为每行新建局部正则,plain 提取同源。顺带修末词永不高亮(无后继边界时 pos≥start 即判已唱)。
- **26-3 mmap 回归**:MmapFile::open 用 `lseek(END)` 取尺寸会移动 dup 共享文件偏移,DSD 头解析读到 EOF 全失败;改 `fstat` 不动偏移。DSD(DSF)/FLAC(742MB) mmap 双链路模拟器复验通过。
- **曲库内容列表 Spring 回弹误触迷你条展开**(内容不足一屏时回弹负 offset 累积):四分区 List/Grid 加 `edgeEffect(EdgeEffect.None)`。
- **V2 触摸热区(targetSdk 26 行为变更)回归**:播放历史删除钮(16vp,热区扩 40vp responseRegion)、队列管理删除(30→32)、打轴删行(28→32)。

- **26-5 守卫策略调整(小艺咨询+SDK 实证)**:canIUse 对 HMS syscap 依赖设备声明(模拟器镜像未含 VisionBase 恒 false,会误杀真机可用性;小艺建议的 'SystemCapability.AI.Vision.ImageSuperResolution' 名在本机 SDK 26.0.0.105 d.ts/device-define 中不存在,未采信)——改为 26 版本门槛 + `ImageSRAnalyzer.create()` 实试探测,失败(服务异常)本会话静默降级;模拟器实测 `sr fail The service is abnormal` 降级路径生效,真机待验。
- **验证结论**:26-6 实况窗(isLiveViewEnabled 模拟器未实现该服务,AGC 场景权未申请,真机项)、26-7 桌面歌词(FLOAT_VIEW=system_basic/system_grant,需 ACL 调试 profile,模拟器报 201 降级路径生效)均按设计静默降级,代码路径已实证。

- 版本号 0.11.0/versionCode 11000。

### Added(0.10.0 迷你条滚动折叠交互)

- **滚动折叠迷你条(华为音乐共识交互)**:三个页签的主滚动容器(曲库四分区 List/Grid、专业页 Scroll、我的页 Scroll)经 `onWillScroll` 逐帧馈入 `common/BarCollapse.ets` 方向累积器(向尾部浏览累积 24vp 折叠、回滚 12vp 展开、方向反转/滚动停止清残量),Index 经 `HdsTabsController.applyMiniBarStyle`(6.1.0(23))带默认动效切换 COLLAPSE/EXPAND;`miniBarStyle` 显式初始 EXPAND(官方默认折叠),`onBarStyleChange` 回写折叠态镜像(覆盖 USER_CLICK 点击折叠胶囊原生互切),无播放内容时不做空壳折叠动画。模拟器双向往返实测通过(feed→COLLAPSE→EXPAND 日志+截图)。
- **踩坑实证(与官方 d.ts 相悖)**:`Scroll.onDidScroll` 在 SDK 26.0.0.105 模拟器上声明可用(since 12)但实测不触发,`onWillScroll` 每帧可达——统一改用 onWillScroll(Scroll 取第 2 参 yOffset,List/Grid 通用回调首参即每帧偏移);方向约定正值=向列表尾部浏览。
- **<440vp 屏 HdsTabs 官方联动形态**(实测确认):迷你条 EXPAND 时页签栏自动折叠为单页签胶囊,两者合并单行底部居中;COLLAPSE 时页签栏恢复完整三页签,迷你条独占一行(两行 VERTICAL 布局)。即"滚动折叠迷你条"在该屏宽下的实际效果=滚动浏览时页签栏回归完整导航、停止浏览(上滑回看)时进入正在播放焦点形态。
- 版本号 0.10.0/versionCode 10000。

### Added(0.9.1 迷你条迁移 HdsTabs 官方迷你栏)

- **迷你播放条迁移至 HdsTabs 官方「迷你栏」能力**(用户推断实证正确):`barFloatingStyle.miniBar`(HdsTabsMiniBar,6.1.0(23) 新增)+ `barLayoutMode: VERTICAL`(6.1.1(24),迷你条独占一行悬浮于页签栏上方);背景材质/底部避让/与页签栏对齐全部由 HdsTabs 管理,移除自绘 Stack 叠加与手工 bottomSafeVp+56 抬升;模拟器验证:迷你条播控/切曲/点条开全屏均正常。小艺咨询对照:其"推断不成立"结论基于旧版文档,以 SDK d.ts 与《设置页签栏的悬浮样式》官方指南原文为准。
- 版本号 0.9.1/versionCode 9001。

### Added(0.9.0 播放器交互对齐华为音乐/业界共识)

- **歌曲添加入口重构(去文件夹扫描形态)**:删除「扫描文件夹管理」页与文件夹浏览(FolderTree);「添加歌曲」(AudioViewPicker 批量选)迁至 我的页·音乐库 + 曲库空态引导;选完即解析入库(addPickedAudioUris,含 persistPermission 持久化),无扫描按钮;应用启动自动激活库内 URI 歌曲授权(activateImportedUriPermissions)。
- **全屏播放页交互重做(参考华为官方《多设备音乐界面》最佳实践与 QQ音乐/网易云/华为音乐共识)**:封面⇄歌词 Swiper 左右滑动切换(封面向左滑→歌词,歌词向右滑→封面);左下角播放模式键四态循环(顺序→列表循环→单曲→随机,symbol 显示当前模式,随机模式 next 随机循环);右上角「更多」bindSheet 菜单(收藏/编辑歌词/倍速/A-B/跳过静音/睡眠定时/查看队列);播放/暂停键缩放弹跳动画;控制区底部 ≥28vp 避让。
- **点歌=以所在列表为队列起播**(曲库/专辑/艺人/流派/收藏/歌单/搜索结果,主流共识);重启后恢复上次播放曲(迷你条立即可用)。

### Fixed(0.9.0)

- **曲库导入/扫描后不即时刷新的根因**:空态分支 `if (songSrc.totalCount()===0)` 读数据源方法(非可观察),libVer 变更只触发 @Watch 而分支不重估 → 四分区空态改读 @State 计数。
- **全屏播放页控制区底部溢出**:PlayerBody 根 Column height('100%') 把顶栏挤出视口 → 改 layoutWeight(1)。
- **随机模式队尾 next 无响应**:nextIndex 无 shuffle 分支 → 随机模式下 next 随机跳且循环。
- **模式键/队列抽屉图标不随 queueVer 刷新**:改 @State 镜像(@Watch 驱动)。
- 空态文案"到设置→扫描文件夹"指向已删除入口 → 改"点「添加歌曲」导入本地音乐"。
- 恢复的队列 mode/repeat 经由 setPlayMode 统一管理(顺序/列表循环/单曲/随机)。

### Changed(0.9.0)

- 版本号 0.9.0/versionCode 9000。
- 全量测试计划 docs/TESTPLAN.md(本地):T1 曲库/T2 我的/T3 播放链路/T4 专业/T5 系统;改动相关用例全部模拟器实操验证通过(真机 AudioViewPicker 导入 24bit/192kHz FLAC 成功)。

### Added(0.8.0 扫描授权链路重构)

- **新增"选择音频文件"入口(AudioViewPicker)**:系统文件管理器选择音频(官方推荐,免敏感权限,可批量选媒体库音频);picker 授权(文件夹/音频文件)经 fileShare.persistPermission 持久化、重扫前 activatePermission 激活(新增普通权限 FILE_ACCESS_PERSIST);新增 `file` 类型扫描根(授权单文件),根目录列表以音符图标+"音频文件(已授权)"呈现,移除时同步 revokePermission。

### Fixed(0.8.0)

- **扫描文件夹页标题栏顶入状态栏**:NavDestination 沉浸式下不自动避让,补 `.padding({top: topSafeVp})`(与设置二级页同模式),底部内容补 bottomSafeVp 避让。
- **URI 授权根扫描不到文件**:fs.listFile 官方仅支持沙箱路径,文档类 URI 目录遍历失败静默返回空(实测媒体库音频在 DocumentViewPicker 中亦不可见)→ 授权文件走 AudioViewPicker 入口,URI 目录遍历失败显式告警;RootFolder.fromJson 未放行 `file` 类型(登记后读取即丢)。
- **URI 授权歌曲无法播放**:库内稳定键带 `uri:` 前缀,播放/RG/歌词/CUE 音频探测直接 fs.open 失败 → 统一 openTargetOf 剥前缀(LosslessEngine/SystemEngine open+openNext/歌词读/RgScanner/TagWriter reindex;TagWriter 对 URI 文件明确拒绝写标签)。
- 移除受限 ACL 权限 READ_AUDIO(发布审核风险;picker 授权链路无需任何敏感权限)。

### Changed(0.8.0)

- 版本号 0.8.0/versionCode 8000。
- 沙箱 chmod 授权链补齐祖先目录(files←entry←haps o+x,宿主 shell 推送语料用)。

### Added

- **M3 无缝衔接(gapless)**:无损引擎预排下一曲(native openNextTrack,采样率/通道/位深/DSD 率一致才接受);解码线程当前曲 EOF 后交换解码器续填环形缓冲,renderer 无感——自然播完切曲零间隙(引擎不重开);倍速≠1 自动禁用(重采样游标跨曲不可拼接,退回普通切曲);CUE 分轨区间切换升级:同文件连续轨保引擎 seek 衔接(不再"播完→重开引擎"),跨文件走普通路径;队列编辑/随机后预排自动失效重排(~2s 校验)。
- **M5 服务卡片**:新增 EntryFormAbility(FormExtensionAbility)+ 2*4 播放控制 ArkTS 卡片(曲目/艺人 + 上一曲/播放暂停/下一曲);formId 经 RDB 跨进程共享,应用侧 formProvider.updateForm 节流推送(600ms);卡片按钮 postCardAction router → EntryAbility cardCmd 控制播放;移除卡片自动清理 formId。
- **M6 统计回顾**:新增"统计回顾"页(我的页入口,最近播放/最常播放双分段);最近播放按 history 单条记录展示(时间/播放时长),最常播放按 play_count 次数排行;行内播放按钮以当前列表为队列从该曲起播;ListItem 左滑露出删除按钮(16vp 圆形红底白 symbol,左右各 8vp 留白),最近播放删 history 行、最常播放删 play_count 行。
- **均衡器按曲目/按专辑生效**:新表 eq_assign(song:{id}/album:{分组键} 覆盖);应用链 按曲目>按专辑>全局;Equalizer 页支持作用域路由参数(歌曲长按菜单"均衡器·当前曲目"/专辑页菜单"均衡器·本专辑"进入),作用域内滑条/预设写覆盖,可一键"跟随全局"清除;保存后当前播放曲立即生效。

### Fixed(模拟器统一验证期修复)

- **CUE 分轨入库三连修**(既有缺陷暴露):主循环 isAudioExt 过滤误拦 .cue 从未进入解析;songs 表 UNIQUE(path) 不容同文件多轨 → 迁移为 UNIQUE(path, cue_start_ms)(旧库自动重建保数据);整轨行/分轨行共存模型(有 CUE 只存分轨,过期分轨行/同键重复行自动清理,cue 时间轴变更差分含时长比对)。
- 统计回顾 JOIN 查询列遮蔽:SONG_COLS 裸 id 在 JOIN 下 ambiguous → 改 s.*(history 表有行却查出空)。
- gapless 交接事件时序两修:事件由渲染回调播到交界时发(交接账本按实际写入帧数记账,支持多曲连环预缓冲),帧位置归位同步移至交界时刻(消除位置/播放时长偏移)。
- 专辑页菜单 bindMenu(this.listMenu()) 括号调用致 builder 过早固化(param 未就绪) → 改引用传递。
- CUE 末轨时长误算(known 查询命中 CueA 分轨行)→ 整轨行判定加 cue_end_ms=-1 条件。

### Changed

- 我的页"最近播放/最常播放"入口由智能列表(SongList)改为统计回顾页(带播放/删除交互)。
- 版本号 0.7.0/versionCode 7000。

### 验证状态(模拟器)

- M3 gapless:双曲链式交接事件与音频交界误差 <200ms、引擎全程不重开(renderer 连续)、recordPlay 数值精确;CUE 区间 12s 交界 seek 衔接(无引擎重建);倍速≠1 自动禁用无缝走普通路径。
- M6 统计:最近/最常双 tab 数据正确,行内播放按钮以列表为队列起播,滑动删除单条记录并即时刷新。
- EQ 作用域:曲目级保存/读回(-10dB 曲线)/播放生效;专辑级入口(bug 修复后)与保存正常;总开关沿用全局。
- M5 卡片:EntryFormAbility 注册(bm dump 确认)、卡片 ArkTS 产物(widgets.abc)入包、formId RDB 跨进程链路就绪;**桌面添加卡片需真机/模拟器手动操作**(系统桌面限制 uitest 注入,遗留用户验证项)。


### Changed

- 曲库分区精简:歌曲/专辑/艺人/流派 4 分区(修复窄屏"文件夹"截断为"文…");歌单分区与我的页歌单卡去重(移除曲库内嵌);文件夹分区迁至我的页"浏览·文件夹浏览"入口(空曲库 toast 提示)。我的页通用卡补左右留白(模拟器视觉验收修复);debug 导入通道支持模拟器网关地址回退(127.0.0.1/10.0.2.2/宿主机网卡依次尝试)。

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

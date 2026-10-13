# UPlayer

> 为鸿蒙设备打造的轻量级音频播放器：外部存储导入即播，音效、歌词、标签写入一应俱全

---

## 目录

- [简介](#简介)
- [特性](#特性)
- [快速开始](#快速开始)
- [使用指南](#使用指南)
- [高级扩展](#高级扩展)
- [开发与编译](#开发与编译)
- [已知局限](#已知局限)
- [致谢与许可证](#致谢与许可证)

---

## 简介

UPlayer是一位花粉大学生的项目，为了解决鸿蒙电脑上没有软件能够直接播放U盘中音频的问题，求助许多开发者无果，看惯了别人的脸色，作者决定自己开发一个播放器软件，同时专业分流迫使作者从事偏向软件的方向，欲借此机会，增加经验，提高能力。

## 特性

UPlayer 是一款专为鸿蒙设备打造的轻量级音频播放器，由在校本科生独立开发。针对鸿蒙系统隐私沙箱机制导致外部存储（如U盘、移动硬盘）或目录外音频无法直接播放的痛点，UPlayer 摒弃了传统播放器“先复制到本地再播放”的繁琐且占存储的方案，通过直接读取外部文件列表建立索引并申请持久化授权，实现了“导入即播”的流畅体验。

在核心播放能力之外，UPlayer 还提供：

- **系统级音效**：基于 OHAudioSuite 自建音频效果链路，内置官方均衡器（9 种预设 + 10 频段调节）与声场、环境、美声、空间渲染、降噪、传统变声、通用变声、变速变调、音源分离等效果节点；针对效果链无增益 API 的问题实现闭环响度补偿，开启音效不丢音量；
- **完整的文件标签支持**：歌曲信息可查看 26 项元数据，15 项支持编辑并真实写入 MP3（ID3v2.3）/ FLAC（Vorbis Comment）/ M4A（ilst）文件本身，更换播放器不丢失；
- **歌词**：`.lrc` / `.krc` 歌词随歌曲导入，逐行滚动高亮、点击跳转，内存缓存 + 切歌预取加速加载；
- **播放细节**：淡入淡出、倍速（0.25x ~ 3x）、快进快退 15s、「通知不压低音量」AudioSession 并发策略；
- **系统集成**：AVSession 媒体控制、后台音频任务、锁屏 Live View、音频焦点与输出路由管理；
- **智慧交互**：智感握姿检测（左右手自动切换加号贴边）、主页诗词问候语、碰一碰 / 隔空传送分享；
- **深度定制**：主题模式、自定义主题色、字体大小、显示大小、磨砂强度、跟手光效、下滑隐藏加号等，均可按个人习惯调节。

> 项目已具备日常可用的完整播放体验，音效、歌词、标签写入等能力均已落地；部分系统集成效果依赖真机与设备能力验证，详见[已知局限](#已知局限)。

## 快速开始

### 环境要求

#### HarmonyOS

| 项目         | 要求                                                   |
| :----------- | :----------------------------------------------------- |
| 系统版本     | HarmonyOS NEXT API 26 及以上                           |
| 集成开发环境 | 支持 HarmonyOS NEXT API 26 及以上的 DevEco Studio      |
| 构建工具     | hvigor、ohpm（随 DevEco Studio 内置）                  |
| 支持设备     | 手机（`phone`）、平板（`tablet`）、二合一 PC（`2in1`） |

- 工程根目录 `build-profile.json5` 中声明的 SDK 信息如下：

```json5
"products"  : [
  {
    "name": "default",
    "signingConfig": "debug",
    "targetSdkVersion": "26.0.0",
    "compatibleSdkVersion": "26.0.0",
    "runtimeOS": "HarmonyOS"
  },
  {
    "name": "release",
    "signingConfig": "release",
    "targetSdkVersion": "26.0.0",
    "compatibleSdkVersion": "26.0.0",
    "runtimeOS": "HarmonyOS"
  }
]
```

- `default` 使用调试签名供真机调试，`release` 使用发布签名供打包上架。

### 安装

1. 使用 DevEco Studio 打开项目根目录。
2. 在 `File > Project Structure > Signing Configs` 中启用自动签名，或配置自己的 HarmonyOS 调试签名。请勿直接复用仓库中的签名材料。
3. 连接已开启开发者模式的真机，或创建模拟器。
4. 点击运行按钮，将应用安装到目标设备。

### 第一个示例

1. 打开应用进入首页，点击右下角的 `+` 悬浮按钮，通过系统文件选择器选择音频文件（支持 `mp3`、`flac`、`wav`、`m4a`、`aac`、`ogg`、`wma`、`ape`、`opus`、`aiff` 等常见格式，可多选）。若导入歌词，则需在导入的同时选中和歌曲同名的lrc文件。
2. 导入后，点击列表中的任意歌曲即可开始播放，界面底部有常驻播控条（显示封面、歌名、歌手以及播放/暂停、上一曲/下一曲），点击即可进入播放器。
3. 切换到「歌单」页，可看到按文件夹自动聚合的歌单卡片；点击「我的收藏」可查看已收藏歌曲。

## 使用指南

### 基础用法

- **导入歌曲**：通过系统文档选择器（`DocumentViewPicker`）读取外部存储设备中的音频，导入时自动去重，并通过 `fileShare.persistPermission` 持久化文件访问授权，无需把文件拷贝到应用目录即可长期播放；导入过程带进度浮层，支持增量流式导入。
- **播放控制**：点击歌曲播放/暂停；支持上一曲/下一曲、进度条拖拽跳转、快退/快进 `15s`；倍速支持 `0.25x` ~ `3x`。
- **歌单与文件夹**：首页支持「平铺 / 文件夹」两种视图切换；「歌单」页按文件夹聚合歌曲，支持收藏、单选/多选文件夹。
- **收藏与下一首**：点击歌曲右侧爱心图标收藏；点击列表图标可将歌曲加入「下一首播放」队列。
- **批量管理**：长按歌曲或文件夹进入多选/编辑模式，可批量删除；首页歌曲项支持左滑露出删除按钮；多选/编辑态下按 `Delete` 键亦可删除。

### 进阶用法

- **音效**：「设置 → 音效」提供均衡器开关与 9 种官方预设（`32Hz~16kHz` 共 10 个频段），以及声场、环境、美声、空间渲染、降噪、传统变声、通用变声、变速变调、音源分离等效果节点。音效走自建 native 音频管线（解码 → 重采样 → OHAudioSuite 效果链 → AudioRenderer），开启后自动进行闭环响度补偿，避免效果链导致的音量下降；部分效果依赖设备能力（如音源分离依赖 NPU）。
- **歌词**：目录下的 `.lrc` / `.krc` 歌词文件随歌曲一同导入，解析后随播放进度滚动高亮，点击任意一行可跳转到对应时间点；歌词经内存 LRU 缓存与切歌预取加速，加载中显示「正在加载歌词…」，不再误报「无歌词」。
- **播放模式**：支持顺序播放、随机播放、单曲循环三种模式，循环切换时弹出 Toast 提示。
- **倍速与音量**：点击控制区的倍速图标弹出滑块，可在 `0.25x` ~ `3x` 之间调节播放速度；音量弹层与系统媒体音量实时联动。
- **淡入淡出**：「设置 → 播放 → 淡入淡出」开启后，起播、暂停与恢复播放均以指数曲线平滑过渡；关闭时全链路不经过任何淡变处理。
- **通知不压低音量**：「设置 → 播放」开启后，系统通知、提示音响起时本应用音量保持不变，可与其他应用音频并发播放。
- **封面与氛围**：从音频元数据提取并缓存专辑封面，播放页使用封面生成模糊背景，并将主色调用于部分界面高亮。
- **歌曲信息**：播放页「歌曲信息」面板展示码率、声道数、位深、编码格式等 26 项元数据；点击编辑可修改 15 项信息，并真实写入 MP3 / FLAC / M4A 文件标签（自动保留封面，更换播放器不丢失）。
- **系统媒体集成**：项目已接入后台音频任务、AVSession 和锁屏 Live View，可同步基础播放状态与歌曲信息；这些能力仍需在支持对应系统能力的真机上继续验证。

### 配置说明

在「设置」页中可进入四组详情配置：

| 分组 | 配置项                                                       |
| :--- | :----------------------------------------------------------- |
| 定制 | 主题模式（跟随系统/深色/浅色）、自定义主题色、字体大小、显示大小、磨砂强度（关闭/轻/中/重）、跟手光效（白光/主题色）、下滑隐藏加号 |
| 播放 | 显示歌词、淡入淡出、播放速度、通知不压低音量                   |
| 音效 | 均衡器开关与官方预设、声场/环境/美声/空间渲染、降噪/传统变声/通用变声/变速变调/音源分离等效果节点 |
| 关于 | 版本号、仓库地址、联系方式（邮箱/QQ）、检查更新               |

## 高级扩展

### 架构说明

项目采用「单 Ability + 单例 Service」的分层架构，ArkTS 负责界面与业务编排，native C++ 负责音频效果管线与文件标签解析，各层职责清晰：

| 层次   | 关键类                                                       | 职责                                                         |
| :----- | :----------------------------------------------------------- | :----------------------------------------------------------- |
| 数据层 | `DataService`、`SongScanner`、`SongDatabase`、`AudioMetadataService`、`MetadataTask` | 歌曲/歌单/设置的数据读写、文件导入扫描、元数据与封面提取     |
| 播放层 | `AVPlayerService`                                            | 基于 `AVPlayer` 的播放状态机、进度/时长/错误/中断监听、倍速、音量、淡入淡出 |
| 音效层 | `cpp/napi_init.cpp`                                          | native 音频效果管线：解码 → 重采样（`OH_AudioConverter`）→ OHAudioSuite 效果链 → `AudioRenderer`；含闭环响度补偿与 MP3/FLAC/M4A 标签写入 |
| 会话层 | `AVSessionController`、`AudioFocusService`、`AudioRoutingService` | 对接系统媒体会话、音频焦点与输出路由管理                     |
| 视图层 | `Index`、`MusicPlayer`、`HomeContent`、`PlaylistContent`、`SettingsContent`、`SettingsDetailPage` 等 | 各页面与组件 UI                                |

- 歌曲与文件夹数据持久化在关系型数据库 `uplayer.db`（`SongDatabase`，`songs` / `folders` 两张表），设置等轻量数据走 `PreferencesUtil`（`@ohos.data.preferences`）；新增设置项只需在 `AppSettingsData` 中增加字段并在 `DataService` 中补充序列化。
- 歌词解析独立在 `LrcUtils`，加载统一收敛到 `LyricLoader`（内存 LRU 缓存 + 在途去重 + 切歌预取），新增歌词格式（如 `trc`、`srt`）时只需新增解析函数并按扩展名分发。

### API 参考

| HarmonyOS 能力                                            | 用途                             |
| :-------------------------------------------------------- | :------------------------------- |
| `@ohos.multimedia.media`（AVPlayer、AVMetadataExtractor） | 音频播放与元数据/封面提取        |
| `@ohos.file.picker`（DocumentViewPicker）                 | 选择外部存储中的音频文件与文件夹 |
| `@ohos.file.fs` + `@ohos.file.fileShare`                  | 文件读写、持久化文件访问授权     |
| `@ohos.data.preferences`                                  | 设置等轻量数据持久化             |
| `@ohos.data.relationalStore`                              | 歌曲/文件夹数据库持久化          |
| `@ohos.multimedia.avSession`                              | 系统媒体会话与媒体控制中心       |
| `@ohos.backgroundTaskManager`                             | 音频播放后台持续任务             |
| `@ohos.multimedia.liveView`                               | 锁屏实时通知（胶囊）             |
| `@ohos.multimedia.audio`                                  | 音量管理、音频焦点与流音量监听   |
| `ohaudiosuite`（native，`OH_AudioSuite` / `OH_AudioConverter`） | 音效效果链与官方重采样        |
| NAPI（`cpp/napi_init.cpp`）                               | native 音频管线与标签写入的 ArkTS 桥接 |

权限声明（`entry/src/main/module.json5`）：`ohos.permission.KEEP_BACKGROUND_RUNNING`、`ohos.permission.FILE_ACCESS_PERSIST`、`ohos.permission.DETECT_GESTURE`（智感握姿）、`ohos.permission.INTERNET`（诗词问候语）。

---

## 开发与编译

### 目录结构

```
entry/src/main
├── cpp/            # native：napi_init.cpp（音频效果管线、标签写入）、types/libuplayer（NAPI 类型声明）
├── ets
│   ├── pages/          # 页面：Index(主页)、MusicPlayer(播放器)、HomeContent(首页)、
│   │                   #       PlaylistContent(歌单)、SettingsContent/SettingsDetailPage(设置)
│   ├── view/           # 组件：PlayerInfoComponent、LyricsComponent、LrcListView、
│   │                   #       ControlAreaComponent、MusicInfoComponent、GlassBackButton、
│   │                   #       GlassPlusButton、ImportProgressOverlay 等
│   ├── component/      # 复用组件：AlbumCover 等
│   ├── service/        # 服务：AVPlayerService、DataService、SongScanner、SongDatabase、
│   │                   #       AudioMetadataService、MetadataTask、LyricLoader、LiveViewService、
│   │                   #       AudioFocusService、AudioRoutingService、HoldingHandService(智感握姿)、
│   │                   #       PoetryService(诗词问候语)、ShareService(碰一碰/隔空分享)
│   ├── viewmodel/      # 数据源与歌词条目：SongDataSource、DisplayItemDataSource、LrcEntry
│   ├── model/          # 数据模型：SongInfo、FolderInfo
│   ├── liveview/       # 锁屏：LockScreenPage、LiveViewExtAbility
│   ├── entryability/   # 应用入口：EntryAbility、InsightIntentExecutorImpl
│   ├── entrybackupability/ # 应用备份：EntryBackupAbility
│   └── common/         # 常量、工具（utils/、mediautils/）
└── resources/      # 界面资源（base/dark 双主题）
```

### 环境搭建

1. 安装 DevEco Studio 并配置 HarmonyOS SDK。
2. 在 `File > Project Structure > SDK` 中确认 SDK 与 `build-profile.json5` 中声明的版本一致。

### 构建步骤

- 图形界面：DevEco Studio 菜单 `Build > Build Hap(s)/APP(s)` 生成安装包；`default` 产物用于真机调试，`release` 产物用于打包上架。
- 命令行：先执行 `ohpm install` 安装依赖，再使用 Hvigor 构建对应目标。
- 单元测试入口位于 `entry/src/test` 与 `entry/src/ohosTest`，可在 DevEco Studio 中直接运行。

## 已知局限

- 音频解码能力取决于设备系统，极少数无损/专有格式（如 `ape`、`dsf` 等）在部分设备上可能无法播放。
- 音源分离效果依赖 NPU，部分设备不支持；降噪、传统变声、变速变调效果输出为单声道。
- 后台播放依赖系统「后台任务」授权与常驻通知，若被系统清理或关闭通知权限可能中断。
- `.krc` 歌词按当前解析逻辑处理时间轴，个别文件可能存在兼容性或时间点偏差。
- AVSession、后台任务和锁屏 Live View 已完成基础接入，但仍依赖设备系统能力、权限和真机验证。
- 外部存储中的文件被移动、删除或重新插拔后，应用会通过可用性检查标记为「文件不可访问」，需重新导入对应歌曲。
- 智感握姿依赖 `DETECT_GESTURE` 权限与设备传感器能力；诗词问候语需要联网访问。

## 致谢与许可证

- 作者：莫洛佐夫
- 本工程代码以 **Apache License 2.0** 协议开源发布（各源文件头部已标注许可证信息）。
- 感谢 HarmonyOS / OpenHarmony 开源生态与广大独立开发者的支持。我相信没有公司的监管，独立开发者们依然能够产出优秀的应用，为国产鸿蒙软件生态注入点点星光！一切反动派都是纸老虎！国产必胜！

> 本项目由作者业余独立开发，仅供学习与交流使用。

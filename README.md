# UPlayer

> 为鸿蒙PC打造的轻量级音频播放器，无需拷贝即可列表播放

---

## 目录

- [简介](#简介)
- [特性](#特性)
- [快速开始](#快速开始)
- [使用指南](#使用指南)
- [高级扩展](#高级扩展)
- [开发与编译](#开发与编译)
- [致谢与许可证](#致谢与许可证)

---

## 简介

UPlayer是一位花粉大学生的项目，为了解决鸿蒙电脑上没有软件能够直接播放U盘中音频的问题，求助许多开发者无果，看惯了别人的脸色，作者决定自己开发一个播放器软件，同时专业分流迫使作者从事偏向软件的方向，欲借此机会，增加经验，提高能力。

## 特性

UPlayer 是一款专为鸿蒙设备设计的本地音频播放器，能够在全平台上运行。核心定位在于解决来自外接存储设备（如U盘、移动硬盘等）或应用沙箱外部的音频文件无法直接播放的痛点。鉴于鸿蒙的隐私机制和权限控制，其他播放器均要求文件复制至下载文件夹后方可播放，操作繁琐且占用存储空间，UPlayer 通过直接读取整个列表的方法，允许用户直接导入并列表播放外部存储设备中的音频文件，实现无需复制，导入即播的流畅体验。

项目由一名在校本科生独立开发，既是满足个人实际使用需求的实践产物，也是学习软件开发过程中的系统性工程训练。通过完整经历需求分析、架构设计、编码实现到测试交付的全流程，持续积累工程经验，提升专业综合能力。

> ⚠️ 当前项目仍处于早期开发阶段。基础播放、歌曲管理、歌词和界面设置已经具备，但部分系统集成与音效功能仍需继续完善，敬请谅解。

## 快速开始

### 环境要求

#### HarmonyOS

| 项目         | 要求                                                   |
| :----------- | :----------------------------------------------------- |
| 系统版本     | HarmonyOS NEXT API 20 及以上                           |
| 集成开发环境 | 支持 HarmonyOS NEXT API 20 及以上的 DevEco Studio      |
| 构建工具     | hvigor、ohpm（随 DevEco Studio 内置）                  |
| 支持设备     | 手机（`phone`）、平板（`tablet`）、二合一 PC（`2in1`） |

- 工程根目录 `build-profile.json5` 中声明的 SDK 信息如下：

```json5
"products"  : [
  {
    "name": "default",
    "signingConfig": "debug",
    "targetSdkVersion": "6.1.1(24)",
    "compatibleSdkVersion": "6.1.1(24)",
    "runtimeOS": "HarmonyOS"
  }
]
```

### 安装

1. 使用 DevEco Studio 打开项目根目录。
2. 在 `File > Project Structure > Signing Configs` 中启用自动签名，或配置自己的 HarmonyOS 调试签名。请勿直接复用仓库中的发布签名材料。
3. 连接已开启开发者模式的真机，或创建模拟器。
4. 点击运行按钮，将应用安装到目标设备。

### 第一个示例

1. 打开应用进入首页，点击右下角的 `+` 悬浮按钮，通过系统文件选择器选择音频文件（支持 `mp3`、`flac`、`wav`、`m4a`、`aac`、`ogg`、`wma`、`ape`、`opus`、`aiff` 等常见格式，可多选）。若导入歌词，则需在导入的同时选中和歌曲同名的lrc文件。
2. 导入后，点击列表中的任意歌曲即可开始播放，界面底部有常驻播控条（显示封面、歌名、歌手以及播放/暂停、上一曲/下一曲），点击即可进入播放器。
3. 切换到「歌单」页，可看到按文件夹自动聚合的歌单卡片；点击「我喜欢的」可查看已收藏歌曲。

## 使用指南

### 基础用法

- **导入歌曲**：通过系统文档选择器（`DocumentViewPicker`）读取外部存储设备中的音频，导入时自动去重，并通过 `fileShare.persistPermission` 持久化文件访问授权，无需把文件拷贝到应用目录即可长期播放。
- **播放控制**：点击歌曲播放/暂停；支持上一曲/下一曲、进度条拖拽跳转、快退/快进 `15s`。
- **歌单与文件夹**：首页支持「平铺 / 文件夹」两种视图切换；「歌单」页按文件夹聚合歌曲，支持收藏、单选/多选文件夹。
- **收藏与下一首**：点击歌曲右侧爱心图标收藏；点击列表图标可将歌曲加入「下一首播放」队列。
- **批量管理**：长按歌曲或文件夹进入多选/编辑模式，可批量删除。

### 进阶用法

- **歌词**：目录下的 `.lrc` / `.krc` 歌词文件随歌曲一同导入，解析后随播放进度滚动高亮，点击任意一行可跳转到对应时间点；无歌词时显示占位提示。
- **播放模式**：支持顺序播放、随机播放、单曲循环三种模式，循环切换时弹出 Toast 提示。
- **倍速与音量**：点击控制区的倍速图标弹出滑块，可在 `0.25x` ~ `3x` 之间调节播放速度；音量面板与系统媒体音量实时同步（该功能正在加紧修复）。
- **封面与氛围**：从音频元数据提取并缓存专辑封面，播放页使用封面生成模糊背景，并将主色调用于部分界面高亮。
- **系统媒体集成**：项目已接入后台音频任务、AVSession 和锁屏 Live View，可同步基础播放状态与歌曲信息；这些能力仍需在支持对应系统能力的真机上继续验证。

### 配置说明

在「设置」页中可进入三组详情配置：

| 分组 | 配置项                                                       |
| :--- | :----------------------------------------------------------- |
| 定制 | 滚动时隐藏加号按钮、主题模式（跟随系统/深色/浅色）、主题色（6 种）、字体大小、显示大小 |
| 播放 | 显示歌词、淡入淡出、播放速度                                 |
| 音效 | 均衡器开关，以及 `32Hz~16kHz` 共 10 个频段的增益参数         |

## 高级扩展

### 架构说明

项目采用「单 Ability + 单例 Service」的分层架构，各层职责清晰，便于按需扩展：

| 层次   | 关键类                                                       | 职责                                                         |
| :----- | :----------------------------------------------------------- | :----------------------------------------------------------- |
| 数据层 | `DataService`、`SongScanner`、`AudioMetadataService`         | 歌曲/歌单/设置的数据读写、文件导入扫描、元数据与封面提取     |
| 播放层 | `AVPlayerService`                                            | 基于 `AVPlayer` 的播放状态机、进度/时长/错误/中断监听、倍速、音量、淡入淡出 |
| 会话层 | `AVSessionController`                                        | 对接系统媒体会话，支持控制中心播放/暂停/切歌/收藏            |
| 视图层 | `Index`、`MusicPlayer`、`HomeContent`、`PlaylistContent`、`SettingsContent` 等 | 各页面与组件 UI                                              |

- 数据持久化依赖 `PreferencesUtil`（`@ohos.data.preferences`），新增设置项只需在 `AppSettingsData` 中增加字段并在 `DataService` 中补充序列化即可。
- 歌词解析独立在 `LrcUtils`，新增歌词格式（如 `trc`、`srt`）时只需新增解析函数并在 `LyricsComponent` 中按扩展名分发。

### API 参考

| HarmonyOS 能力                                            | 用途                             |
| :-------------------------------------------------------- | :------------------------------- |
| `@ohos.multimedia.media`（AVPlayer、AVMetadataExtractor） | 音频播放与元数据/封面提取        |
| `@ohos.file.picker`（DocumentViewPicker）                 | 选择外部存储中的音频文件与文件夹 |
| `@ohos.file.fs` + `@ohos.file.fileShare`                  | 文件读写、持久化文件访问授权     |
| `@ohos.data.preferences`                                  | 歌曲列表、设置等轻量数据持久化   |
| `@ohos.multimedia.avSession`                              | 系统媒体会话与媒体控制中心       |
| `@ohos.backgroundTaskManager`                             | 音频播放后台持续任务             |
| `@ohos.multimedia.liveView`                               | 锁屏实时通知（胶囊）             |
| `@ohos.multimedia.audio`                                  | 音量获取与流音量变更监听         |

权限声明（`entry/src/main/module.json5`）：`ohos.permission.KEEP_BACKGROUND_RUNNING`、`ohos.permission.FILE_ACCESS_PERSIST`。

---

## 开发与编译

### 目录结构

```
entry/src/main/ets
├── pages/          # 页面：Index(主页)、MusicPlayer(播放器)、HomeContent(首页)、
│                   #       PlaylistContent(歌单)、SettingsContent/SettingsDetailPage(设置)
├── view/           # 组件：PlayerInfoComponent、LyricsComponent、LrcListView、
│                   #       ControlAreaComponent、MusicInfoComponent
├── service/        # 服务：AVPlayerService、DataService、SongScanner、
│                   #       AudioMetadataService、LiveViewService
├── viewmodel/      # 数据源与歌词条目：SongDataSource、DisplayItemDataSource、LrcEntry
├── model/          # 数据模型：SongInfo、FolderInfo
├── liveview/       # 锁屏：LockScreenPage、LiveViewExtAbility
├── entryability/   # 应用入口：EntryAbility
└── common/         # 常量、工具（utils/、mediautils/）
```

### 环境搭建

1. 安装 DevEco Studio 并配置 HarmonyOS SDK。
2. 在 `File > Project Structure > SDK` 中确认 SDK 与 `build-profile.json5` 中声明的版本一致。

### 构建步骤

- 图形界面：DevEco Studio 菜单 `Build > Build Hap(s)/APP(s)` 生成安装包。
- 命令行：先执行 `ohpm install` 安装依赖，再使用 DevEco Studio 自带的 Hvigor 构建对应目标。项目根目录的 `build.ps1` 可用于构建 Release APP，但其中包含作者本机 DevEco Studio 的绝对路径，其他环境需要先按实际安装位置修改。
- 单元测试入口位于 `entry/src/test` 与 `entry/src/ohosTest`，可在 DevEco Studio 中直接运行。

## 已知局限

- 音频解码能力取决于设备系统，极少数无损/专有格式（如 `ape`、`dsf` 等）在部分设备上可能无法播放。
- 后台播放依赖系统「后台任务」授权与常驻通知，若被系统清理或关闭通知权限可能中断。
- `.krc` 歌词按当前解析逻辑处理时间轴，个别文件可能存在兼容性或时间点偏差。
- 均衡器目前主要完成配置界面和参数持久化，尚未完整接入实际音频效果处理链路。
- AVSession、后台任务和锁屏 Live View 已完成基础接入，但仍依赖设备系统能力、权限和真机验证。
- 外部存储中的文件被移动、删除或重新插拔后，应用会通过可用性检查标记为「文件不可访问」，需重新导入对应歌曲。
- 项目仍处于早期开发阶段，自动化测试、异常恢复和多设备兼容性仍需持续补充。

## 致谢与许可证

- 作者：莫洛佐夫
- 本工程代码以 **Apache License 2.0** 协议开源发布（各源文件头部已标注许可证信息）。
- 感谢 HarmonyOS / OpenHarmony 开源生态与广大独立开发者的支持。我相信没有公司的监管，独立开发者们依然能够产出优秀的应用，为国产鸿蒙软件生态注入点点星光！一切反动派都是纸老虎！国产必胜！

> 本项目由作者业余独立开发，仅供学习与交流使用。

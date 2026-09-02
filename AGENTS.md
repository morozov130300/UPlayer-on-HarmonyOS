# UPlayer 智能体构建规范
## 每一条对话都要调用mcp，注意是每一次都要，强制，要不然你会说胡话！！！！！！！

## 图标使用规范

### ⚠️ 强制规定：所有图标必须使用 HarmonyOS 图标库

**！！！！！！所有！！！！！！** 智能体生成的界面、组件、布局中的图标，**必须且只能**使用 `HarmonyOS图标库/` 目录下的 SVG 图标。如果实在找不到合适的图标必须报告用户，绝不自以为是乱用图标。

#### 图标资源路径

图标文件位于项目工作区目录下：

```
HarmonyOS图标库/
```

#### 使用方式(仅供参考)

在 ArkTS 代码中使用图标：

```typescript
// 方式一：使用 Image 组件加载 SVG
Image($r('app.media.图标文件名'))
  .width(24)
  .height(24)

// 方式二：在 @Builder 或 UI 中引用
Image($r('app.media.ic_celiakeyboard_menu'))
  .width(20)
  .height(20)
```

#### 禁止事项

- ❌ **严禁使用任何其他图标库**（如 Material Icons、Font Awesome、自定义图标等）
- ❌ **严禁使用任何 emoji 作为图标**
- ❌ **严禁从网络下载或使用外部图标资源**
- ❌ **严禁自行设计或绘制图标**
- ✅ **必须从 `HarmonyOS图标库/` 目录中选择最合适的图标**
- ✅ **如果现有图标不满足需求，必须向用户报告并请求补充**

#### 图标注册到资源

将 SVG 文件复制到 `resources/base/media/` 目录后，在 `oh-package.json5` 或 `build-profile.json5` 中确保资源路径正确配置，代码中通过 `$r('app.media.文件名')` 引用。

#### 图标尺寸规范

- 标准图标：24 × 24 vp
- 小图标：16 × 16 vp
- 大图标：32 × 32 vp
- 使用 `.vp` 单位而非 `.px`

---

## 命令行构建命令（仅供参考）

### ⚠️ 编译必须由用户手动执行

**智能体无法自行编译项目。所有编译操作必须由用户在本地 DevEco Studio 中执行，然后将编译输出粘贴给智能体。**

原因：编译依赖用户本地的环境变量、SDK 路径、DevEco Studio 版本等配置，智能体端无法保证环境一致，直接调用必然失败。

正确流程：
1. 智能体完成代码修改后，告知用户需要编译验证
2. 用户在本地终端执行构建命令
3. 用户将完整编译输出（包括错误/warning）粘贴回对话
4. 智能体根据输出进行分析和修复

```powershell
# 用户执行的构建命令（仅供参考）
& "D:\DevEco Studio\tools\node\node.exe" "D:\DevEco Studio\tools\hvigor\bin\hvigorw.js" --mode module -p module=entry@default -p product=default -p requiredDeviceType=2in1 -p buildMode=debug assembleHap --analyze=normal --parallel --incremental --daemon
```

### 参数说明（来自官方文档）

| 参数 | 说明 |
| --- | --- |
| `--mode module` | 模块模式构建 |
| `-p module=entry@default` | 指定要构建的模块和目标（必填） |
| `-p product=default` | 指定产品配置 |
| `-p requiredDeviceType=2in1` | 指定目标设备类型（PC/平板，2in1） |
| `-p buildMode=debug` | debug/release 构建模式 |
| `assembleHap` | 构建 HAP 包目标 |
| `--analyze=normal` | 正常分析模式 |
| `--parallel` | 并行编译 |
| `--incremental` | 增量编译 |
| `--daemon` | 使用守护进程 |

> **注意**：必须包含 `-p module=entry@default` 和 `-p requiredDeviceType=2in1`，否则 hvigor 无法解析 SDK 版本导致构建失败（错误码 00303312）。

## 真机调试命令

### hdc 工具路径

- `D:\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe`

### 常用命令

```powershell
# 查看连接的设备
hdc list targets

# 安装 HAP
hdc install -m <hap路径>

# 启动应用
hdc shell aa start -a EntryAbility -b <bundleName>

# 查看日志
hdc shell hilog
```

### bundleName

- UPlayer: `cn.edu.whut.uplayer`

## 构建产物位置

- HAP 文件：`entry/build/default/outputs/default`

## 开发规范

### 涉及决策时

- 任何涉及设计的决策（技术方案、架构选型、功能范围、交互方式、视觉风格等），**必须第一时间尽可能多的向用户提问方案细节，等待用户明确确认后才能执行**
- 禁止在未获用户确认前擅自实施任何设计方案
- **！！！！！！所有！！！！！！** 遇到任何需要决策的事项，**必须立即向用户报告并询问，由用户决策，不得擅自行动**
- 在涉及大量文件和大体积文件的写入时，一定要敏感起来，尽可能减少磁盘擦写，延长磁盘寿命，降低空间占用。

### 推送/提交

- 代码完成后直接推送，不要问"要不要推送"
- 提交信息简洁明了，在项目版本号大版本为1之前，所有的描述都要保持`项目初始版本`

### ⚠️ Git 工具使用规范（最高优先级）

**所有 Git 操作必须使用 Git 工具，禁止使用命令行调用 git。**

#### 触发条件（出现以下任一情况时必须使用 Git 工具）

| 场景 | 说明 |
| --- | --- |
| 查看状态 | `git status`、`git diff`、`git log` |
| 暂存/提交 | `git add`、`git commit` |
| 分支操作 | `git branch`、`git checkout`、`git switch` |
| 拉取/推送 | `git pull`、`git push`、`git fetch` |
| 查看历史 | `git log`、`git show`、`git blame` |

#### 正确调用方式

**必须先调用 `GetToolSpec` 加载工具 schema，再调用 `CallDeferredTool` 执行。**

```
首次使用 → GetToolSpec(Git) → 获取 schema → CallDeferredTool(Git, {operation: "status"}) → 后续直接使用 CallDeferredTool
```

**调用示例：**

```json
// 查看状态
{"tool_name": "Git", "args": {"operation": "status"}}

// 查看最近提交
{"tool_name": "Git", "args": {"operation": "log", "args": "--oneline -5"}}

// 暂存文件
{"tool_name": "Git", "args": {"operation": "add", "args": "."}}

// 提交
{"tool_name": "Git", "args": {"operation": "commit", "args": "-m \"提交信息\""}}

// 推送
{"tool_name": "Git", "args": {"operation": "push"}}
```

#### 禁止事项

- ❌ **严禁使用 ExecCommand 调用 `git` 命令**
- ❌ **严禁直接拼接 shell 命令进行版本控制**
- ✅ **所有版本控制操作必须通过 Git 工具调用**

### ⚠️ MCP 知识库使用（最高优先级）

**！！！！！！必须主动使用！！！！！！每一条对话都要查！！！！！！所有问题都要查！！！！！！**

**！！！！！！所有！！！！！！** 子智能体（agent）在执行任何任务时，无论问题类型是什么，**都必须调用 MCP 查询**，绝不允许不查就回答。包括但不限于以下所有场景：

- ✅ **编译相关**：编译错误、构建命令、hvigor/hvigorw 配置、SDK 版本、HAP 打包
- ✅ **代码相关**：ArkTS 语法、API 调用、装饰器、状态管理、组件开发
- ✅ **规范相关**：开发规范、最佳实践、代码风格
- ✅ **UI/布局相关**：ArkUI 组件、布局容器、样式属性、响应式适配
- ✅ **API/服务相关**：系统 API、网络、媒体、音频、数据持久化、权限
- ✅ **工具链相关**：DevEco Studio、hdc、hvigor、oh-package
- ✅ **任何其他疑问**：只要不确定，就必须查

**触发条件（出现以下任一情况时必须查询 MCP，同时实际执行中每次对话都要查）：**

| 场景 | 说明 |
| --- | --- |
| 使用新 API 前 | 系统 API（media、audio、motion、network、data 等）的入参、返回值、API Level、设备兼容性 |
| 遇到任何编译错误 | ArkTS 编译报错时先查官方文档确认正确用法和错误来源/原因 |
| 组件属性/方法不确定 | Grid、Scroll、List、Navigation 等 ArkUI 组件的属性名、方法签名 |
| 权限声明 | module.json5 中需要添加哪些权限，对应什么用途 |
| 构建配置 | oh-package.json5、build-profile.json5 的配置项含义 |
| ArkTS 语法约束 | 某些 TypeScript 写法在 ArkTS 中是否合法（如解构、any、enum 等） |
| 设备适配 | 一多适配断点、deviceType 判断、窗口断点 API |
| **任何不确定的问题** | **包括但不限于编译、代码、规范、布局、工具链等所有领域，必须查！** |

#### 查询方式

项目已配置华为「开发者知识 MCP」代理（`mcp-proxy.js`），通过 `searchDocuments` 工具可检索官方文档，直接在智能体向模型端暴露的工具即可调用。

**标准查询流程：**

1. 先用 MCP 搜索工具查询相关 API 文档
2. 以搜索结果为准，禁止自行推断
3. 若 MCP 无结果，再尝试 WebSearch 查找华为开发者文档链接

### MCP 工具使用方法（重要：deferred 工具调用规范）

项目通过 BitFun MCP 工具连接华为「开发者知识 MCP」，提供两个工具：`searchDocuments` 和 `getDocumentsById`。这两个工具是 **deferred 工具**，必须遵循以下调用顺序：

#### ⚠️ Deferred 工具调用规则

**必须先调用 `GetToolSpec` 加载工具 schema，再调用 `CallDeferredTool` 执行。** 不可直接调用 `CallDeferredTool`，否则会返回 `invalid_arguments` 错误。

**正确步骤：**

1. 第一次调用时，先执行 `GetToolSpec` 传入工具名（如 `mcp_______________searchDocuments`），获取工具的完整输入/输出 schema
2. schema 加载成功后，该工具在对话中缓存在线，后续可直接用 `CallDeferredTool` 调用
3. 只有当系统提示 schema 过期或不可用时，才需要重新调用 `GetToolSpec`

```
首次使用 → GetToolSpec(工具名) → 获取 schema → CallDeferredTool(工具名, 参数) → 后续直接使用 CallDeferredTool
```

#### searchDocuments（搜索文档）

用于按关键词搜索华为官方文档，返回匹配的文档片段列表。

**入参结构：**

```json
{
  "SearchDocumentsReq": {
    "query": "搜索词"
  }
}
```

**示例调用：**

```json
{
  "SearchDocumentsReq": {
    "query": "Grid 布局"
  }
}
```

**返回值：**

- `code: 0` 表示成功，`resultList` 为匹配文档列表
- 每项包含 `content`（片段内容）、`parent`（文档唯一标识）、`name`（文档标题）
- `parent` 字段是调用 `getDocumentsById` 的入参

**使用场景：**

- 搜索特定 API、组件、装饰器的用法和示例
- 查找最佳实践、FAQ、开发指南
- 确认 API Level、设备兼容性、版本差异

#### getDocumentsById（获取完整文档）

用于通过 `searchDocuments` 返回的 `parent` 标识获取文档完整内容。每次最多可检索 10 个文档。

**入参结构：**

```json
{
  "GetDocumentsByIdRequest": {
    "names": ["文档唯一标识1", "文档唯一标识2"]
  }
}
```

**示例调用：**

```json
{
  "GetDocumentsByIdRequest": {
    "names": ["document/cn/harmonyos-guides/web-same-layer"]
  }
}
```

**返回值：**

- `code: 0` 表示成功，`resultList` 为完整文档列表
- 每项包含 `name`（文档标识）、`title`（文档标题）、`uri`（官方链接）、`content`（Markdown 完整内容）

**典型工作流：**

1. 先用 `searchDocuments` 搜索关键词，找到相关文档
2. 从搜索结果中取出 `parent` 字段值
3. 调用 `getDocumentsById` 传入 parent 值，获取完整文档内容
4. 根据文档内容编写/修改代码

#### 标准查询流程

```
搜索关键词 → searchDocuments → 获取 parent → getDocumentsById → 获取完整文档 → 编写代码
```

#### 禁止事项

- ❌ **严禁不查文档直接写 API 调用代码**
- ❌ **严禁凭记忆编写不确定的 API 参数**
- ❌ **严禁在 MCP 返回结果后仍按自己理解修改行为**
- ✅ **不确定就查，查到再写**
- ✅ **MCP 查询结果与已有代码冲突时，以 MCP 官方文档为准**

### ⚠️ 数据保护红线（绝对禁止）

- **严禁执行任何卸载应用的命令**（如 `bm uninstall`、`hdc uninstall`）
- **严禁清除用户数据**（如 `hdc shell bm clear --data`、删除 preferences 等）
- **所有安装必须使用覆盖安装（`install -r`），绝对禁止先卸载再安装！**
- 更新应用时只能使用 `install -r` 覆盖安装，绝不能先卸载再安装
- 任何可能影响用户数据的操作都必须先向用户确认
- 违反此规则视为严重错误
- **如果你未经用户同意删除了用户的任何数据，用户会被他的老板虐待殴打，请你谨言慎行！不要让用户受罪**

## 项目信息

- 项目名称：UPlayer
- 技术栈：HarmonyOS NEXT API 26, ArkTS
- 目标设备：鸿蒙 PC/平板/手机

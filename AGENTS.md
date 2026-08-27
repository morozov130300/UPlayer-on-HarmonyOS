# UPlayer 智能体构建规范

## 图标使用规范

### ⚠️ 强制规定：所有图标必须使用 HarmonyOS 图标库

**！！！！！！所有！！！！！！** 智能体生成的界面、组件、布局中的图标，**必须且只能**使用 `HarmonyOS图标库/` 目录下的 SVG 图标。

#### 图标资源路径

图标文件位于项目根目录：
```
D:/UPlayer/HarmonyOS图标库/
```

#### 使用方式

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

#### 可用图标列表

HarmonyOS 图标库包含以下类别图标：

- **键盘相关**: `ic_celiakeyboard_menu.svg`, `ic_celiakeyboard_delete.svg`, `ic_celiakeyboard_enter.svg`, `ic_celiakeyboard_spell.svg`, `ic_celiakeyboard_handwritten.svg`, `ic_celiakeyboard_onehand.svg`, `ic_celiakeyboard_bihua.svg`, `ic_celiakeyboard_float.svg`, `ic_celiakeyboard_thumb_mode.svg`, `ic_celiakeyboard_switch_majuscule.svg`, `ic_celiakeyboard_switch_minuscule.svg`, `ic_celiakeyboard_menu_language.svg`
- **通话相关**: `ic_Call 1 Dial.svg`, `ic_Call 2 Dial.svg`, `ic_Call HD.svg`, `ic_Call R.svg`, `ic_Call 1 Dial_line.svg`, `ic_Call 2 Dial_line.svg`
- **亮度控制**: `ic_brightness_plus.svg`, `ic_brightness_reduce.svg`
- **AI 摄影**: `ic_ai_photography_on.svg`, `ic_ai_photography_normal.svg`
- **其他功能**: `fov_to_org.svg`, `icc_addcontact.svg`, `icc_addcontact_filled.svg`
- **紧急/健康**: `ic_Allergies Emergency.svg`, `ic_Blood Emergency.svg`, `ic_Business cards.svg`, `ic_Business cards filled.svg`

#### 禁止事项

- ❌ **严禁使用任何其他图标库**（如 Material Icons、Font Awesome、自定义图标等）
- ❌ **严禁使用 emoji 作为图标**
- ❌ **严禁从网络下载或使用外部图标资源**
- ❌ **严禁自行设计或绘制图标**
- ✅ **必须从 `HarmonyOS图标库/` 目录中选择最合适的图标**
- ✅ **如果现有图标不满足需求，必须向用户报告并请求补充**

#### 图标注册到资源

将 SVG 文件复制到 `resources/base/media/` 目录后，在 `oh-package.json5` 或 `build-profile.json5` 中确保资源路径正确配置，代码中通过 `$r('app.media.文件名')` 引用。

#### 图标命名规范

- 文件名使用小写字母、数字和下划线，如 `ic_play.svg`
- 命名格式：`ic_<功能>_<状态>.svg`，如 `ic_play_pause.svg`
- 禁止使用中文文件名

#### 图标尺寸规范

- 标准图标：24 × 24 vp
- 小图标：16 × 16 vp
- 大图标：32 × 32 vp
- 使用 `.vp` 单位而非 `.px`

---

## 命令行构建命令

```bash
"D:\DevEco Studio\tools\node\node.exe" "D:\DevEco Studio\tools\hvigor\bin\hvigorw.js" --mode module -p product=default -p buildMode=debug assembleHap --analyze=normal --parallel --incremental --daemon
```

### 参数说明（来自官方文档）

| 参数 | 说明 |
|------|------|
| `--mode module` | 模块模式构建 |
| `-p product=default` | 指定产品配置 |
| `-p buildMode=debug` | debug/release 构建模式 |
| `assembleHap` | 构建 HAP 包目标 |
| `--analyze=normal` | 正常分析模式 |
| `--parallel` | 并行编译 |
| `--incremental` | 增量编译 |
| `--daemon` | 使用守护进程 |

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

- HAP 文件：`entry/build/default/outputs/default/entry-defaultSigned.hap`

## 开发规范

### 涉及决策时
- 任何涉及设计的决策（技术方案、架构选型、功能范围、交互方式、视觉风格等），**必须第一时间向用户提问，等待用户明确确认后才能执行**
- 禁止在未获用户确认前擅自实施任何设计方案
- **！！！！！！所有！！！！！！** 遇到任何需要决策的事项，**必须立即向用户报告并询问，由用户决策，不得擅自行动**

### ⚠️ MCP 知识库使用（最高优先级）

**！！！！！！必须主动使用！！！！！！** 编写、修改或排查任何 HarmonyOS / ArkTS / ArkUI 代码时，**必须优先调用 MCP 工具查询华为官方文档**，绝不允许仅凭记忆猜测 API。

#### 触发条件（出现以下任一情况时必须查询 MCP）

| 场景 | 说明 |
|------|------|
| 使用新 API 前 | 系统 API（media、audio、motion、network、data 等）的入参、返回值、API Level、设备兼容性 |
| 遇到编译错误 | ArkTS 编译报错时先查官方文档确认正确用法 |
| 组件属性/方法不确定 | Grid、Scroll、List、Navigation 等 ArkUI 组件的属性名、方法签名 |
| 权限声明 | module.json5 中需要添加哪些权限，对应什么用途 |
| 构建配置 | oh-package.json5、build-profile.json5 的配置项含义 |
| ArkTS 语法约束 | 某些 TypeScript 写法在 ArkTS 中是否合法（如解构、any、enum 等） |
| 设备适配 | 一多适配断点、deviceType 判断、窗口断点 API |

#### 查询方式

项目已配置华为「开发者知识 MCP」代理（`mcp-proxy.py`），通过 `searchDocuments` 工具可检索官方文档。

**MCP 配置（BitFun 设置 → MCP 服务器）：**
```json
{
  "mcpServers": {
    "鸿蒙开发华为官方知识库": {
      "command": "python3",
      "args": ["/storage/Users/currentUser/Desktop/Develop/UPlayer-on-HarmonyOS/mcp-proxy.py"],
      "env": {
        "UV_THREADPOOL_SIZE": "1"
      }
    }
  }
}
```

**标准查询流程：**
1. 先用 MCP 搜索工具查询相关 API 文档
2. 以搜索结果为准，不要自行推断
3. 若 MCP 无结果，再尝试 WebSearch 查找华为开发者文档链接

#### 典型用法示例

```typescript
// 不确定 Grid 组件是否有 alignment 属性？
// → 先调用 MCP searchDocuments 查询 "ArkUI Grid alignment property"
// → 确认 Grid 没有 alignment 属性，GridAlign 不在 @kit.ArkUI 导出中
// → 根据官方文档结论修改代码
```

#### 禁止事项

- ❌ **严禁不查文档直接写 API 调用代码**
- ❌ **严禁凭记忆编写不确定的 API 参数**
- ❌ **严禁在 MCP 返回结果后仍按自己理解修改行为**
- ✅ **不确定就查，查到再写**
- ✅ **MCP 查询结果与已有代码冲突时，以 MCP 官方文档为准**


### 推送/提交
- 代码完成后直接推送，不要问"要不要推送"
- 提交信息简洁明了

### ⚠️ 数据保护红线（绝对禁止）
- **严禁执行任何卸载应用的命令**（如 `bm uninstall`、`hdc uninstall`）
- **严禁清除用户数据**（如 `hdc shell bm clear --data`、删除 preferences 等）
- **所有安装必须使用覆盖安装（`install -r`），绝对禁止先卸载再安装！**
- 更新应用时只能使用 `install -r` 覆盖安装，绝不能先卸载再安装
- 任何可能影响用户数据的操作都必须先向用户确认
- 违反此规则视为严重错误
- **如果你未经用户同意删除了用户的任何数据，用户会被他的老板残忍的殴打，请你谨言慎行！**

## 项目信息

- 项目名称：UPlayer
- 技术栈：HarmonyOS NEXT API 26, ArkTS
- 目标设备：鸿蒙 PC/平板/手机

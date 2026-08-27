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
- 任何不确定的、涉及架构或设计决策的问题，**必须向用户提问**
- 不要自行假设，不要磨磨唧唧
- **！！！！！！所有！！！！！！** 遇到任何问题、歧义、不确定项，**必须立即向用户报告并询问，由用户决策**
- 禁止自行猜测用户意图或替代用户做选择

### MCP 知识库使用
- 编辑 HarmonyOS/ArkTS 代码时，**主动调用 MCP 知识库查询官方文档**
- 涉及系统 API、权限声明、构建配置时优先查文档
- 不要仅凭记忆猜测

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

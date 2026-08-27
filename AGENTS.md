# UPlayer 智能体构建规范

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

### MCP 知识库使用
- 编辑 HarmonyOS/ArkTS 代码时，**主动调用 MCP 知识库查询官方文档**
- 涉及系统 API、权限声明、构建配置时优先查文档
- 不要仅凭记忆猜测

### 推送/提交
- 代码完成后直接推送，不要问"要不要推送"
- 提交信息简洁明了

## 项目信息

- 项目名称：UPlayer
- 技术栈：HarmonyOS NEXT API 26, ArkTS
- 目标设备：鸿蒙 PC/平板/手机

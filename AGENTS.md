# UPlayer 智能体规范

## 强制规则（最高优先级）

### 1. MCP 查询
**每次对话都必须调用 MCP**，不查就回答视为严重错误。

### 2. 图标规范
所有图标**必须**来自 `HarmonyOS图标库/` 目录，禁止使用任何外部图标库或 emoji。

### 3. 行为准则
- 只做用户明确要求的任务，禁止擅自行动
- 涉及决策时必须先问用户，不等用户确认不得执行
- 完成后立即停止，不追加额外操作

### 4. 编译调试流程
**智能体完成代码修改后，执行编译调试：**
1. `devecocli run --device "<设备名>" --module entry` 编译并部署到真机
2. 连接设备：`& "D:\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe" tconn <IP>:<端口>`
3. 截图验证：`devecocli ui screenshot --device "<设备名>" --path "<路径>"`
4. 清理截图：`Remove-Item <截图路径>`

**真机 IP**：`10.82.231.201:37391`（HUAWEI Mate X7 典藏版）

### 5. Git 推送
所有改动完成后立即推送远程：
```
git add .
git commit -m "描述"
git push
```

### 6. 工具优先
优先使用工具（Read/Grep/Glob/Edit/Delete），只有在工具不可用时才用命令行。

### 7. 临时文件清理
任务完成后立即删除所有临时文件。

## 项目信息
- 名称：UPlayer
- 技术栈：HarmonyOS NEXT API 26, ArkTS
- bundleName：`cn.edu.whut.uplayer`
- HAP 产物：`entry/build/default/outputs/default/`
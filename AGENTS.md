# UPlayer 智能体规范与记忆

## 普适规则

### 1. MCP 查询（强制）
每次对话都必须调用 MCP，不查就回答视为严重错误。

### 2. 图标规范
所有图标必须来自 `HarmonyOS图标库/` 目录，禁止使用任何外部图标库或 emoji。

### 3. 行为准则
- 只做用户明确要求的任务，禁止擅自行动
- 涉及决策必须先问用户，不等确认不得执行
- 完成后立即停止，不追加额外操作

### 4. 编译调试流程
**智能体完成代码修改后，必须执行编译调试：**
1. 连接设备：`& "D:\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe" tconn 10.82.231.201:37391`
2. 编译部署：`devecocli run --device "HUAWEI Mate X7 典藏版" --module entry`
3. 截图验证：`devecocli ui screenshot --device "HUAWEI Mate X7 典藏版" --path "D:\UPlayer\check.png"`
4. 清理截图：`Remove-Item D:\UPlayer\check.png`

**真机**: HUAWEI Mate X7 典藏版 (10.82.231.201:37391)
**bundleName**: `cn.edu.whut.uplayer`

### 5. Git 推送
所有改动完成后立即：
```
git add .
git commit -m "描述"
git push
```

### 6. 工具优先
优先使用工具（Read/Grep/Glob/Edit/Delete），只有工具不可用时才用命令行。

### 7. 临时文件清理
任务完成后立即删除所有临时文件。

---

## 项目进展记录

### 2026-09-26 Tab栏迁移完成

**核心变更：**
- `Index.ets`: `Tabs` → `HdsTabs`（@kit.UIDesignKit）
- 布局由断点决定：小屏 sm/md 上下叠，大屏 lg/xl 左右分栏（miniBar）
- 玻璃厚度仅控制材质：glassThickness=0 时 pill 形状不变，无材质效果
- 播控条在 `miniBarBuilder()`，小屏降级为自建 `playerControl`

**关键代码：**
- `getHdsBarFloatingStyle()`: 仅检查 `tabStyle` 和 `isLiquidGlassAvailable()`
- `build()`: `.barHeight(44).barWidth(228)` 固定值
- `tabLabelBuilder`: 指示器内嵌 Stack（径向渐变 + shadow）
- Tab 文字间距: `top margin = 3vp`

**设置项兼容性：**
- ✅ 生效: `tabStyle`, `glassThickness`, `lightColorMode`, `tabIndicatorVisible`, `tabIndicatorOpacity`
- ❌ 无效（系统自动）: `interactive`, `colorInvert`, `applyShadow`, `glassFrostOverlay`

**Bug 修复记录：**
1. C++ `napi_init.cpp` 引入不存在 API → 已回退
2. `glassThickness=0` 时错误退回全宽经典 bar → 应为 pill 无材质
3. miniBar 条件误加 `glassThickness > 0` → 应由断点决定
4. 进度条拖拽白色光晕 → 删除 `.shadow()`
5. 进度条触控区窄 → 外层容器 32vp

**已推送 commit:** `e32c37b`, `4a317fb`, `5811d22`, `97423f8`, `5626e07`

---

## 构建产物
- HAP: `entry/build/default/outputs/default/`
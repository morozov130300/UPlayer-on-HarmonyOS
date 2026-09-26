# UPlayer 记忆文档

## 2026-09-26 Tab 栏迁移

### 核心变更
- `Index.ets`: `Tabs` → `HdsTabs`（`@kit.UIDesignKit`），实现 tab pill + miniBar 左右分栏
- 布局由**断点**决定：小屏 sm/md 上下叠，大屏 lg/xl 左右分栏
- 材质由**玻璃厚度**决定：pill 形状始终保留，glassThickness=0 时无材质
- 播控条移入 `miniBarBuilder()`，小屏时降级为自建 `playerControl`

### 关键代码位置
- `getHdsBarFloatingStyle()`: 返回 undefined 条件仅为 `tabStyle !== 'immersive' || !isLiquidGlassAvailable()`
- `build()`: `.barHeight(.barWidth` 固定值（pill 布局不受 glassThickness 影响）
- `tabLabelBuilder`: 指示器光晕内嵌 Stack（径向渐变 + shadow）
- `miniBarBuilder`: 播控条内容（封面+歌名+播放按钮）

### 设置项兼容性
- ✅ 生效: `tabStyle`, `glassThickness`, `lightColorMode`, `tabIndicatorVisible`, `tabIndicatorOpacity`
- ⚠️ 半生效: `tabTouchIndicator`（仅 lightColor）、`glassBlurStrength`（经典模式）
- ❌ 无效: `interactive`, `colorInvert`, `applyShadow`, `glassFrostOverlay`（系统自动控制）

### Bug 修复记录
1. C++ `napi_init.cpp` 引入不存在 API → 回退到原始版本
2. `glassThickness <= 0` 错误退回全宽经典 bar → 应为 pill 无材质
3. miniBar 下发条件误加 `glassThickness > 0` → 应由断点决定
4. 进度条拖拽白色光晕 → 删除 `.shadow({ sliderGlow })`
5. 进度条触控区太窄 → 外层容器 32vp 包裹

### Tab 文字间距
- 最终值: `top margin = 3vp`（从图标底部到文字顶部）
- 调参历史: 1→4→6→8→10→5→3 vp

### 构建调试
- 设备: HUAWEI Mate X7 典藏版 (10.82.231.201:37391)
- bundleName: `cn.edu.whut.uplayer`
- HAP 位置: `entry/build/default/outputs/default/`
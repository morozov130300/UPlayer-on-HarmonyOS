# UPlayer 记忆

## 2026-09-26 Tab栏迁移

### 变更
- `Index.ets`: `Tabs` → `HdsTabs`（@kit.UIDesignKit）
- 布局由断点决定：小屏 sm/md 上下叠，大屏 lg/xl 左右分栏
- 玻璃厚度仅控制材质：glassThickness=0 时 pill 形状不变，无材质效果
- 播控条在 `miniBarBuilder()`，小屏时降级为自建 `playerControl`

### 关键代码
- `getHdsBarFloatingStyle()`: 仅检查 `tabStyle` 和 `isLiquidGlassAvailable()`，不再因 `glassThickness <= 0` 返回 undefined
- `build()`: `.barHeight(44).barWidth(228)` 固定值，pill 形状不受玻璃厚度影响
- `tabLabelBuilder`: 指示器内嵌 Stack（径向渐变 + shadow）
- `miniBarBuilder`: 播控条内容

### Tab 文字间距
- `top margin = 3vp`（图标底部到文字顶部）

### 调试设备
- HUAWEI Mate X7 典藏版: `10.82.231.201:37391`
- bundleName: `cn.edu.whut.uplayer`
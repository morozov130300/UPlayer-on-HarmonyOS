# Tab 栏迁移至 HdsTabs 记录

## 概述
将 `Index.ets` 中的标准 `Tabs` + 自定义播控条布局迁移到 `HdsTabs`（`@kit.UIDesignKit`），实现 tab 栏与播控条分居两侧，同时保持手机端液态玻璃合规。

## 核心设计决策

### 布局由断点决定，材质由系统决定
- **断点决定布局**：小屏（sm/md）上下叠放，大屏（lg/xl）左右分栏
- **玻璃厚度决定材质**：pill 形状始终保留，仅 `systemMaterialEffect` 是否生效

| 断点 | glass > 0 | glass = 0 |
|------|-----------|-----------|
| 小屏 sm/md | pill + 自建播控条上下叠 | pill（无材质）+ 自建播控条上下叠 |
| 大屏 lg/xl | pill + 系统 miniBar 左右分栏 | pill（无材质）+ 系统 miniBar 左右分栏 |

### miniBar 与自建播控条的切换条件
```ts
// getHdsBarFloatingStyle() 中
const smallScreen = breakpoint === 'sm' || breakpoint === 'md'
// 小屏：不下发系统 miniBar（系统会收折页签栏，布局失控）
// 大屏：下发系统 miniBar（左右分栏）
if (!smallScreen) {
  miniBar = { miniBarBuilder: ..., enableMiniBarBackground: true, ... }
}

// build() 中
// 小屏：渲染自建 playerControl
// glassThickness = 0 时：同样渲染自建 playerControl（miniBar 未下发）
if (breakpoint === 'sm' || breakpoint === 'md') {
  // 自建 playerControl
}
```

## 关键代码变更

### Index.ets
1. **导入**：新增 `HdsTabs`, `HdsTabsController`, `HdsTabsFloatingStyle`, `hdsMaterial` from `@kit.UIDesignKit`
2. **控制器**：`TabsController` → `HdsTabsController`
3. **组件**：`Tabs` → `HdsTabs`
4. **材质**：`uiMaterial.ImmersiveMaterial` → `hdsMaterial`（ADAPTIVE 档位）
5. **getHdsBarFloatingStyle()**：
   - 不再因 `glassThickness <= 0` 返回 undefined（始终返回 pill 配置）
   - `systemMaterialEffect` 在 glassThickness <= 0 时为 undefined
6. **tabLabelBuilder**：指示器光晕内嵌 Stack（选中时 radialGradient + shadow）
7. **miniBarBuilder**：播控条内容移入此 @Builder
8. **playerControl**：保留用于小屏自建播控条

### ControlAreaComponent.ets
- 移除进度条拖拽时的白色外发光：删除 `.shadow({ radius: sliderGlow, color: '#B3FFFFFF' })` 及 `sliderGlow` 状态
- 进度条触控区域扩大：包裹 Column(height=32vp)，Slider 居中

### HomeContent.ets
- 加号按钮 `Text('+')` → `Image($r('app.media.ic_public_add_norm_filled'))`（图标库资源）

## 设置项兼容性

| 设置项 | HdsTabs 模式下状态 |
|--------|------------------|
| `tabStyle`（classic/immersive） | ✅ 生效 |
| `glassThickness` | ✅ 生效（0=无材质，>0=pill+材质） |
| `glassBlurStrength` | ⚠️ HdsTabs 材质自带模糊，经典模式下生效 |
| `tabTouchIndicator`（light/mask/off） | ⚠️ lightColor 生效，其余系统自动 |
| `lightColorMode` | ✅ 生效 |
| `tabIndicatorVisible` | ✅ 生效 |
| `tabIndicatorOpacity` | ✅ 生效 |
| `interactive` | ❌ 系统自动，开关无效 |
| `colorInvert` | ❌ 系统自动，开关无效 |
| `applyShadow` | ❌ 系统自动，开关无效 |
| `glassFrostOverlay` | ❌ HdsTabs 模式下无意义 |

## 编译调试记录

- 2026-09-26：初始迁移编译通过，部署到 HUAWEI Mate X7 典藏版（10.82.231.201:37391）
- 2026-09-26：修复 C++ napi_init.cpp 中不存在的 API，回退到原始版本
- 2026-09-26：修复 glassThickness=0 时 tab 栏错误退回全宽经典 bar
- 2026-09-26：修复 build() 中 barHeight/barWidth 固定值问题
- 2026-09-26：修复 miniBar 下发条件中加入 glassThickness 判断的错误
- 2026-09-26：tab 文字间距多次调整，最终稳定在 3vp

## 构建产物
- HAP: `entry/build/default/outputs/default/`
- bundleName: `cn.edu.whut.uplayer`
# UPlayer 记忆

## 2026-09-26 Tab栏迁移

### 核心变更
- Index.ets: `Tabs` → `HdsTabs`（@kit.UIDesignKit）
- 布局由断点决定：小屏 sm/md 上下叠，大屏 lg/xl 左右分栏（miniBar）
- 玻璃厚度只管材质：pill 形状始终保留，glassThickness=0 时无材质
- 播控条移入 miniBarBuilder()，小屏降级为自建 playerControl

### 关键代码
- getHdsBarFloatingStyle(): 仅 tabStyle/liquidGlass 检查，不再因 glassThickness<=0 返回 undefined
- build(): barHeight/barWidth 固定 pill 尺寸，不受 glassThickness 影响
- tabLabelBuilder: 指示器内嵌 Stack（径向渐变+shadow）
- miniBarBuilder: 播控条（封面+歌名+播放按钮）
- playerControl: 保留用于小屏自建

### 设置项兼容
| 生效 | 无效 |
|------|------|
| tabStyle, glassThickness, lightColorMode, tabIndicatorVisible, tabIndicatorOpacity | interactive, colorInvert, applyShadow, glassFrostOverlay |

### 已知 Bug 修复
1. C++ napi_init.cpp 引入不存在 API → 已回退
2. glassThickness=0 时错误退回全宽经典 bar → 应为 pill 无材质
3. miniBar 条件误加 glassThickness>0 → 应由断点决定
4. 进度条拖拽白色光晕 → 删除 shadow
5. 进度条触控区窄 → 外层容器 32vp

### Tab 文字间距
- top margin = 3vp（图标底部到文字顶部）

### 构建调试
- 设备: HUAWEI Mate X7 典藏版 (10.82.231.201:37391)
- bundleName: cn.edu.whut.uplayer
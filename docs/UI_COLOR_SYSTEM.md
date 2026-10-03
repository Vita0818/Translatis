# UI_COLOR_SYSTEM — 上一版配色方案

文档状态：历史视觉方案；冻结于 v0.21 之前
历史语境核对：2026-08-03

> **本文已被 `CURRENT_UI_COLOR_SYSTEM.md` 完全取代。**
>
> 本文中的暖中性色、香槟金和自定义玻璃体系只记录 Intatis 之前的配色，不代表当前
> 源码或下一版方向，也不得作为新增 UI 的默认要求。

本文正文中“当前源码”“迁移前”等措辞均以 2026-07-14 的历史快照为语境。当前实现已改用
Apple 动态语义表面、Material 和原生 Liquid Glass；当前事实与验收清单只看
`CURRENT_UI_COLOR_SYSTEM.md` 和源码。

本文保留旧值仅用于视觉对照和 provenance；不要据此恢复已删除的固定 RGB/Hex、渐变、
品牌金或自绘玻璃。

## 1. 上一版视觉方向

macOS 的上一版视觉语言是：**暖中性底色 + 克制的香槟金强调 + 半透明玻璃层次**。

- 大面积背景保持暖黑、暖白和低饱和中性色，不用金色铺满界面。
- 香槟金主要表示品牌、选中、主操作、运行中和强调信息。
- 正文使用暖墨色而非纯黑/纯白，次级文字降低明度和对比度。
- 卡片、输入区、助手气泡和侧栏通过暖色玻璃底、细描边及系统 Material 建立层次。
- 成功、等待和失败仍使用系统语义色，避免用品牌金承担所有状态含义。

上一版暗色界面的总体观感是暖黑棕背景、石墨色玻璃侧栏、象牙白文字、低饱和沙金用户气泡和深色玻璃助手气泡；亮色模式对应为暖白、奶油色描边与深暖墨文字。

## 2. 源码事实来源

以下文件是上一版配色在当前源码中的事实来源，按优先级排列；它们不是下一版配色的设计依据：

1. `Apps/IntatisMac/Sources/IntatisDesign.swift`：macOS 品牌色、明暗模式、渐变、玻璃修饰器与字体。
2. `Packages/IntatisSharedUI/Sources/ThreadSurfaces.swift`：跨平台 thread 语义色和 iOS 使用的标准样式。
3. `Apps/IntatisMac/Sources/IntatisMacRootView.swift`、`IntatisChatScreen.swift`：侧栏、选择态、聊天气泡、composer 和设置页的实际使用。
4. `Packages/IntatisSharedUI/Sources/CodeViews.swift`、`CoworkViews.swift`、`Views.swift`：Code/Cowork 状态色及 iOS Chat 行的实际使用。

## 3. 上一版 macOS 基础颜色令牌

下表中的 Hex 是源码 RGB 分量按 sRGB 方式换算的设计令牌值。带透明度或 Material 的最终屏幕像素不会等于这个 Hex，详见“新配色迁移约束”。

| 令牌 | 暗色模式 | 亮色模式 | 主要用途 |
|---|---:|---:|---|
| `gold` | `#C9A86A` | `#C9A86A` | 标准香槟金、强调描边、警告描边、渐变终点 |
| `goldSoft` | `#D8BE86` | `#D8BE86` | 高光、柔和选择底、品牌渐变起点 |
| `goldDeep` | `#B5934F` | `#B5934F` | 强调文字、选中图标、按下/运行中状态 |
| `sand` | `#EFE6D2` | `#EFE6D2` | 用户气泡的浅沙色基底 |
| `deepText` | `#ECE4D4` | `#2B2620` | 标题、正文和主要信息 |
| `softText` | `#ADA288` | `#7A7064` | 副标题、说明、非活动控件 |
| `tertiaryText` | `#6E6552` | `#A89E8C` | 占位、弱提示、未知或取消状态 |
| `glassSurface` | `#1B1811` | `#FFFFFF` | 玻璃卡片、侧栏、助手气泡的底色基值 |
| `glassStroke` | `#8D7648` | `#F1EAD8` | 暖金/奶油玻璃边缘基值 |
| `shadow` | 系统黑色 | `#B59C6B` | 玻璃层阴影基值 |

### 3.1 页面背景渐变

`pageGradient` 从左上到右下：

| 模式 | 色标顺序 |
|---|---|
| 暗色 | `#17150F` → `#1F1C14` → `#1A1710` |
| 亮色 | `#FBF9F4` → `#F4EFE3` → `#FAF6EE` |

上一版品牌按钮的 `accentGradient` 同样从左上到右下，色标为 `#D8BE86` → `#C9A86A`，迁移前源码中的按钮文字使用白色。

## 4. 上一版 macOS 语义色映射

在上一版实现中，`IntatisThreadStyle.intatisMac` 是 Chat、Code、Cowork 共用界面消费的语义层。

| 语义字段 | 暗色模式 | 亮色模式 | 用途 |
|---|---|---|---|
| `primaryText` | `deepText` | `deepText` | 主要文字 |
| `secondaryText` | `softText` | `softText` | 次要文字 |
| `tertiaryText` | `tertiaryText` | `tertiaryText` | 弱提示和默认状态 |
| `accent` | `goldDeep` | `goldDeep` | 选中、活动和强调 |
| `accentSoft` | `goldSoft` × 24% | `goldSoft` × 45% | 选择态和弱强调背景 |
| `surface` | `glassSurface` | `glassSurface` | 表面基色 |
| `stroke` | `glassStroke` × 50% | `glassStroke` × 85% | 通用边框 |
| `userBubble` | `sand` × 16% | `sand` × 85% | 用户消息气泡 |
| `assistantBubble` | `glassSurface` × 30% | `glassSurface` × 70% | 助手消息气泡 |
| `cardSurface` | `glassSurface` × 28% | `glassSurface` × 64% | 卡片、面板、统计胶囊 |
| `cardStroke` | `glassStroke` × 40% | `glassStroke` × 70% | 卡片边框 |
| `warningSurface` | `goldSoft` × 16% | `goldSoft` × 20% | 警告背景 |
| `warningStroke` | `gold` × 32% | `gold` × 42% | 警告边框 |
| `error` | 系统 `.red` | 系统 `.red` | 错误、失败和破坏性操作 |
| `material` | `.ultraThinMaterial` | `.ultraThinMaterial` | 玻璃模糊和环境混色 |

“× 24%”表示对该基色应用 SwiftUI `opacity(0.24)`，不是独立、不透明的新 Hex。

## 5. 上一版组件使用记录

本节记录旧实现如何使用颜色，不是新方案必须继承的设计规则。

### 5.1 页面、侧栏与选择态

- macOS 根页面使用 `pageGradient`。
- 侧栏等大面积容器使用低透明度 `glassSurface` 叠加系统 Material，保持中性，不使用大块实心金色。
- 通用 mode segment 的选中底使用 `accentSoft`，选中图标/文字使用 `accent`。
- Settings 选中底使用 `goldSoft`：暗色 22%，亮色 36%；选中描边使用 `gold`：暗色 34%，亮色 42%。
- Provider 选中底使用 `goldSoft`：暗色 22%，亮色 32%；选中描边使用 `gold` 55%。
- hover、未选中和禁用态在上一版中使用玻璃表面与次级文字，不会升级为主金色操作态。

### 5.2 消息、卡片与输入区

- 用户消息使用右对齐的 `userBubble`；助手消息使用左对齐的 `assistantBubble` 并叠加 `.ultraThinMaterial`。
- Code/Cowork 卡片、Goal/Tasks、Agent 和 Git 状态区使用 `cardSurface` / `cardStroke`，不自行发明固定灰色。
- Composer、模型菜单和统计胶囊使用玻璃表面；边框保持细、低对比，焦点或选择时才增加金色提示。
- 主要提交按钮使用 `accentGradient`；次级按钮使用玻璃胶囊或语义文字色。
- 错误、权限拒绝和破坏性操作使用系统红色，不能只靠金色或低对比文字表达。

### 5.3 玻璃修饰器

`intatisGlassCard` 和 `intatisGlassCapsule` 会在 `glassSurface` 之上叠加 Material、渐变描边和阴影。暗色模式还会收窄不透明度：

- fill：`min(传入值 × 0.82, 0.40)`；
- stroke：`min(传入值 × 0.72, 0.34)`；
- 暗色卡片阴影：`max(传入阴影 × 0.5, 0.08)`。

因此复现或分析上一版玻璃表面时，应通过这些修饰器或语义样式理解，不能把截图取色值当成原始令牌。

## 6. 上一版状态色

状态色是语义提示，不是品牌装饰。上一版 Cowork 的主要映射如下：

| 状态 | 颜色 |
|---|---|
| `active`、`in_progress`、`running`、`thinking`、`tool` | `accent` / `goldDeep` |
| `assigned`、`paused`、`pending`、`queued`、`ready`、`mailbox` | 系统 `.orange` |
| `blocked`、`budget_limited`、`usage_limited` | 系统 `.orange` |
| `completed`、`complete`、`done` | 系统 `.green` |
| `failed`、`error`、`rejected` | `error` / 系统 `.red` |
| 未知、默认、取消 | `tertiaryText` |

Code 中的低/中/高风险也分别使用系统 `.green` / `.orange` / `.red`。这些系统颜色会随平台、显示模式和可访问性设置变化，本文不为它们声明固定 Hex。

## 7. 上一版字体与颜色搭配

- 英文品牌名和大标题：系统 Serif，配 `deepText`。
- 正文、中文和操作文字：系统字体，主要内容用 `deepText`，说明用 `softText`。
- 代码、路径和技术令牌：系统 Monospaced，按信息层级使用主要或次级文字色。
- 不使用颜色作为唯一的信息通道；状态应同时保留图标、标签或文字。

## 8. 上一版时期的 iOS 配色

截至上一版方案记录时，iOS 没有直接使用 `IntatisTheme`，而是使用 `IntatisThreadStyle.standard(scheme)` 和系统 `accentColor`。因此 iOS 与 macOS 的组件结构部分共享，但品牌配色没有完全统一。

| iOS 语义字段 | 迁移前源码实现 |
|---|---|
| 主要/次要文字 | 系统 `.primary` / `.secondary` |
| 第三级文字 | `.secondary` × 72% |
| 强调色 | 系统或宿主配置的 `.accentColor`，无固定 Hex |
| 弱强调色 | `.accentColor` × 16% |
| 暗色表面 | RGB `0.12 / 0.12 / 0.12`，约 `#1F1F1F` |
| 亮色表面 | `#FFFFFF` |
| 用户气泡 | `.accentColor`：暗色 18%，亮色 12% |
| 助手气泡 | surface：暗色 30%，亮色 70% |
| 卡片表面 | surface：暗色 26%，亮色 62% |
| 卡片描边 | `.secondary`：暗色 22%，亮色 14% |
| 警告 | 系统 `.yellow`：背景暗色 14%/亮色 10%，描边 38% |

共享 iOS Chat 的 `MessageRow` 在迁移前源码中仍直接使用：用户 `.accentColor` 12%，其他角色 `.gray` 10%，tag 使用 `.accentColor` 及其 14% 背景。这是旧实现当前事实，不应误写成 macOS 香槟金主题已经覆盖 iOS，也不表示下一版必须保留系统强调色。

## 9. 新配色迁移约束

- SwiftUI Material、透明度、窗口后方内容、系统 vibrancy、显示器色彩管理都会影响最终像素；本文 Hex 是源令牌，不是截图像素保证。
- `.primary`、`.secondary`、`.accentColor`、`.green`、`.orange`、`.red`、`.yellow` 和系统黑/白均可能自适应，除非源码另有固定 RGB，否则不得编造固定 Hex。
- 本文不是下一版配色 brief；新方案未明确前，不得从上一版令牌自行推断“只换一个强调色”或默认保留香槟金、暖黑、沙色与玻璃材质。
- 新方案应先明确基础令牌、语义令牌、明暗模式、状态色、组件映射、macOS/iOS 一致性和迁移边界，再修改业务 View。
- 迁移期间应区分上一版令牌与新令牌，避免同名 token 在不同界面表达不同语义；完成迁移后删除无引用旧令牌，而不是长期叠加两套隐式主题。
- 跨平台组件仍应接收语义样式并由平台注入，不得让 SharedUI 反向依赖 macOS target。
- 新方案至少检查暗色、亮色、提高对比度和降低透明度场景；关键信息不能只通过色相区分。
- 开始和完成迁移时，应同步更新本文、`CURRENT_STATE.md`、`PROJECT_MAP.md`、`NEXT_TARGET.md` 与相关视觉验证记录；在源码尚未迁移完成前必须明确标注混合状态。

## 10. 上一版未固定的部分

- 系统 Material 在不同 macOS/iOS 版本和设备上的最终混色值未固定。
- iOS `accentColor` 的实际值取决于 App/系统配置，上一版源码没有声明一个可作为产品规范的固定 Hex。
- Display P3、HDR、特定显示器 profile 下的像素差异未建立独立基准。
- 本文只记录上一版配色体系，不替代下一版设计 brief，也不替代布局、交互、动态字体和完整无障碍规范。

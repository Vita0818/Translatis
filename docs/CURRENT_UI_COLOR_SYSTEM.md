# CURRENT_UI_COLOR_SYSTEM — 系统原生表面与 Liquid Glass 规范

文档状态：当前 UI 实施规范
最近核对日期：2026-09-03
产品基线：v0.72（build 72）

> Intatis 不再把“系统外观”解释为固定的纯白和纯黑。页面、侧栏、内容层与控制层均使用 Apple 平台的动态语义资源；在支持的系统上，导航与交互控件采用原生 Liquid Glass。`docs/UI_COLOR_SYSTEM.md` 只保存上一版香槟金 / 暖中性色方案，不随当前方案修改。

## 1. 核心规则

1. 不为浅色或深色模式声明固定 `.white`、`.black`、RGB、Hex 或取色器采样值。
2. macOS detail 区使用系统 window surface；sidebar 交还 `NavigationSplitView` 自己渲染，不覆盖自定义底色。
3. 除用户消息外的对话行（assistant / agent / system，包括失败 / 中断回复与媒介化 Agent 通信）直接继承系统 conversation canvas，不额外叠 Material、圆角或描边；用户消息是唯一对话气泡，使用原生 `Glass.regular`，不再叠加 accent 蓝色描边。tool、error、permission、artifact、Goal / Task 等专用结构化内容继续使用系统 `Material`。
4. 功能层（导航、模式切换、composer、模型菜单、主要操作与紧凑交互控件）在 macOS 26 / iOS 26 采用原生 Liquid Glass；内容层只允许用户消息气泡与 Cowork 紧凑 trailing status rail 两类明确例外。
5. Liquid Glass 不铺满页面或整段 transcript，也不作为一般长文本或数据卡片的默认背景；用户消息气泡只包裹该条用户输入，其他对话正文仍直接位于 canvas。
6. 文本、分隔线、强调色与错误色使用系统语义资源：`.primary`、`.secondary`、系统 separator、`.accentColor`、`.red` 等。
7. 颜色不是状态的唯一信息通道；状态同时保留文字、图标或结构提示。
8. macOS rich message 的直接拖拽选区以每个 native leaf 的同一份系统
   `selectedTextAttributes` 为唯一颜色事实源，即 `NSColor.selectedTextBackgroundColor` 与
   `NSColor.selectedTextColor`；不得另用 `controlAccentColor`、固定蓝色 RGB 或透明 overlay 形成第二套
   高亮。跨 native leaf 的强调只存在于 selection lifetime 的 disposable attributed projection，清除时
   恢复原动态语义色与 native selection attributes。

“系统原生”指由当前 Apple 平台实时解析的语义表面和材质，而不是把某一台设备上看到的像素颜色写死。取色器只能用于视觉核对，不能成为令牌来源。

## 2. 表面层级

| 层级 | 当前实现 | 用途 |
|---|---|---|
| Window | SwiftUI `.windowBackground`；macOS 13 使用 `NSVisualEffectView.Material.windowBackground` 兼容 | macOS detail 根表面 |
| Sidebar | `NavigationSplitView` 原生 sidebar | macOS 导航栏及其 vibrancy / active-window 行为 |
| Conversation text | 继承 Window / 系统容器 canvas | assistant / agent / system 对话正文，包括失败 / 中断时已产生的正文、Markdown 与公式；Chat 的恢复建议仍跟随正文，Code/Cowork 的错误说明统一进入右栏 |
| User message bubble | 原生 `Glass.regular`；防御性 fallback 为 `.regularMaterial` | 唯一带外层气泡的对话角色；保持 trailing 对齐、既有宽度与 gutter，不加 accent 描边 |
| Structured content | `.regularMaterial` / 原生 glass + 系统 separator | 正常 tool、permission、artifact、Goal / Task 等专用内容卡片，以及 Code/Cowork 右栏唯一的条件式错误卡片 |
| Functional glass | `glassEffect`、`GlassEffectContainer`、`.buttonStyle(.glass/.glassProminent)` | composer、模型菜单、主要按钮、操作组、agent pill 等 |
| Fallback | `.regularMaterial` 或系统 bordered button | macOS 13–15、iOS 16–18 等不支持 Liquid Glass 的部署目标 |

系统强调色用于焦点、选中态和 prominent 操作。Intatis 不再以固定黑白代替系统 accent，也不自行模拟玻璃的高光、折射、阴影或动态响应。

## 3. 组件映射

### 3.1 页面与侧栏

- macOS detail 区由 `IntatisSystemCanvas` 渲染动态 window surface。
- macOS sidebar 不设置 `IntatisTheme.canvas` 或其他背景覆盖层；`NavigationSplitView` 继续提供系统侧栏材质，内部是 `Intatis` 标题、带 SF Symbol 的 Chat/Code/Cowork 竖向三行导航、mode-specific session history/New 与底部 Settings 的连贯结构。只有当前模式行使用 interactive Liquid Glass。
- iOS 继续由 `NavigationStack` / SwiftUI 容器提供原生根背景，不引入 Intatis 私有页面色。紧凑 Chat 使用同一容器内的约 82% 左抽屉；抽屉与右移后的圆角主画布都只使用系统语义背景、Material、separator 和 glass controls，不复制参考应用的固定渐变或品牌资产。

### 3.2 Chat

- 用户消息保持 trailing 对齐和既有宽度合同，但外层改为原生 `Glass.regular`，不再绘制蓝色细线；这是唯一对话气泡。assistant / agent / system 正文，包括失败 / 中断回复，都没有外层卡片、底色或描边，Markdown、公式与恢复建议直接显示在系统 canvas 上。
- assistant / agent 名称右侧的消息时间属于三级只读元数据，不加 badge、图标、头像、玻璃或独立容器；它跟随系统本地化，24 小时内仅时间、7 天内星期加时间、更早为年月日加时间。
- composer 固定为两排：macOS 第一排左侧是模型选择控件；Chat右侧保留会话级Context，Code/Cowork在
  official context事实未接通前不显示占位。每条已完成assistant/agent正文下方使用低噪声footer，最左是
  无文字`doc.on.doc`复制按钮；Chat/历史显示可证明的legacy turn stats，新Codex回复显示Input/Cache Hit/
  Cache Write/Output/Reasoning/Total/Duration七项native值，Input不减Cache Hit。不增加背景、玻璃、点赞、
  点踩或其他反馈按钮。iOS Chat继续保留model + 完整latest-turn usage第一排。Chat/Code/Cowork选择器共用
  原生`Menu`语义与40pt高interactive Liquid Glass胶囊；关闭态只显示模型名，弹出菜单内部仍按provider
  分组并保留variant明细。第二排从左到右是当前产品面已有的附件或图像action、原生多行`TextField`、
  voice、唯一主操作位；voice始终紧邻主操作左侧。
- macOS reply footer 直接继承 conversation canvas，使用三级/二级语义文字与等宽数字，不绘制 card、Material、Glass、separator 或固定颜色。复制按钮只显示 SF Symbol，help/VoiceOver 仍使用本地化“Copy message”；clipboard 写入 canonical raw message text，统计值和其他 UI metadata 不进入复制结果。
- macOS rich assistant/agent 正文可在同一条 rendered message 内直接跨 heading、paragraph、list、quote、
  table cell 与 code body 拖拽；所有参与 leaf 在 mouse-up 后使用同一系统 selected-text 选区。首个 leaf
  只保留不重复绘制的 native selected range 以维持 Copy responder 语义，不能再叠一层随 focus 改变的
  原生浅/深高亮。它不是新的内容 surface，也不增加背景、card、glass 或固定蓝色；普通点击/stream
  replacement/dismantle 恢复原 attributed colors。Command-C 复制显示 plain text；reply footer 的整条
  raw copy 仍是独立能力。
- composer 第二排的附件/图像 action、voice 与主操作使用 40×40 原生圆形 glass/bordered control，输入容器单行最小高度同为 40，同行 spacing 为 8；多行输入只向上增长，左右按钮保持底边对齐。主操作 idle 时是 Send，工作时在同一位置替换为 `Button(role: .destructive)` + `stop.fill` 的系统红色 Stop，不并排显示两个操作。voice 不占用该唯一槽位：第一次点击开始录音，第二次点击停止并转写，结果只进入可编辑草稿。
- composer 的附件、图像 action、voice、Stop 与 Send 复用 `.controlSize(.regular)`、圆形 button border shape 和系统原生 glass / bordered 表现；Send 使用 prominent 语义，Stop 使用系统 destructive/red 语义且不自绘。sidebar `Recent` 旁 `+` 则使用 `.controlSize(.small)`、圆形 border shape 与原生 glass，fitting size 为 30×30。没有对应能力的 Chat / Code 不凭空增加附件入口；voice 是四个 composer 共用的输入能力，不生成设置页或自动发送。
- iOS 复用同一两排 composer 几何：第一排左侧是关闭态只显示模型名的原生 glass
  `Menu`，右侧在有统计时显示 usage；第二排固定为左侧 paperclip Chat 功能菜单、中间
  输入、右侧 voice + 唯一 Send/Stop。菜单中的图片生成必须继续使用已有能力；托管网络搜索仍是
  后台透明路由，不生成 UI。通用附件链没有实现前不得伪装成可发送文件，也不得扩大
  Chat-only 产品边界。
- macOS Chat仍可使用自身first-token waiting的`Thinking…`计时。Code/Cowork不复用该合成行：official
  turn lifecycle只驱动临时、无计时的本地化`Working`活动；App Server item按Command/File changes/Tool/
  MCP tool/Web search/Image/Collaboration/Subagent/Plan/Reasoning/Runtime activity语义显示。活动行直接继承
  canvas，使用系统语义文字与SF Symbol，不增加card、Material、Glass、固定颜色或每event一个badge；
  started/delta/completed按exact identity原位归并，raw method只在技术help或backend trace中出现。

### 3.3 Code

- 正常及失败 / 中断时已产生的 agent 对话正文继承系统 canvas；用户消息使用原生 `Glass.regular` 气泡。Plan、Workspace、权限提示和 artifact 仍属于专用结构化内容层，使用系统 Material。
- Code 与 Cowork 共用名称右侧的低噪声消息时间；时间不参与 agent 状态、权限或任务完成语义。
- header / workspace 操作与主要 CTA 属于功能层，使用原生 glass button。
- App Server执行进度使用低chrome语义活动行：类别图标、自然语言名称、可选Running/Completed/Failed/
  Cancelled状态及App Server明确允许展示的reasoning/plan正文。turn完成后的临时Working行消失；usage、
  permission与error继续进入footer、权限卡和右栏，不复制为protocol日志。未知future event显示通用
  Runtime activity并通过help保留安全技术详情。
- Code inspector 是内容区内的系统风格 trailing status rail，使用稳定 outer width 决定显隐并继承系统 `.bar` / separator；不创建固定灰色或纯黑 / 纯白面板，也不向 window toolbar 动态增删 item。当前 page 的 runtime error、失败 trace、恢复建议、失败 submission 与全部 voice/composer 页面级错误经过去重后，只在 rail 最底部一张现有圆角 section 风格的“错误信息”卡片内显示；没有任何来源时完全不生成卡片。主 thread 与 composer 上方不得再出现同一错误，旧 `Recent Failures` section 不再存在。

### 3.4 Cowork

- 用户消息与 Code 共用原生 `Glass.regular` trailing 气泡；其余 agent 对话正文共用无外框渲染。通用 Agent message、`information_requested`、`information_replied` 与其他 agent-to-agent 正文也使用同一普通回答版式，身份只显示 exact `sender->recipient`。正常 tool、permission 与 task 等专用结构化记录继续保留语义容器；error、失败 trace 与 recovery 文案不再占用 thread 中央区域。
- Cowork trailing status rail 是用户明确指定的紧凑玻璃状态层：待处理权限 / 最近权限结果置顶，其后依次为 Agents、Goal、Tasks；当前选中 agent page 的 runtime error、失败 trace、恢复建议、失败 submission 与全部 voice/composer/inference/projection/session-storage 页面级错误经过去重后，在最底部同一张“错误信息”圆角卡片内显示。没有任何来源时不生成卡片或占位；失败 submission 的 Retry 位于该卡片内，主 thread 与 composer 上方不再重复错误。各 section 使用独立、稳定的系统原生 `Glass.clear` backdrop，不放进会融合或重组 shape 的 `GlassEffectContainer`。rail 作为 conversation detail 同一 canvas 上的 trailing overlay，不再使用 divider、整栏 `.bar` / Material 背板或固定灰底；主 thread 滚动容器延伸到 detail 最右侧，以 trailing scroll-content margin 给 cards 留位，原生滚动条保持在整个内容区最右端；rail 最右透明边缘不参与命中测试，不能遮挡滚动条交互。Cowork rail 不显示 Git。
- 有 pending permission 且窗口可安全容纳 rail 时，rail 临时固定可见；窗口窄到无法容纳 rail 时，只在 composer 上方保留同一个低对比 Material 权限卡作为安全兜底。两种布局不得同时显示权限卡，也不得在 thread 顶部复制 Goal/Tasks 或保留对应占位高度。
- Cowork session header 不显示独立 MCP Content 快捷按钮；该浏览能力位于
  `Project Settings → MCP → Browse Content`。status rail 的显隐使用系统 compact 圆形
  glass/bordered icon control，不用默认的横向 glass action chrome，也不进入 window toolbar。
- Goal 操作、agent 操作、task action、项目设置按钮和紧凑 agent pill 属于功能层，可使用 Liquid Glass 并以 `GlassEffectContainer` 组织相邻效果。
- 红、橙、绿继续只承担错误、等待 / 阻塞、成功等语义状态，并同时保留文字或图标。
- `@main`与每个selected child复用Code同一semantic activity reducer和组件；child live/durable event
  使用同一稳定ID，切换agent时不得看到双份活动。非选中child的activity publication不得刷新当前thread，
  reasoning/plan持续delta继续服从既有selected-agent raw/rich quiet gate和projection cadence。

### 3.5 模式切换与设置

- Chat / Code / Cowork、mode-specific sessions、New 和 Settings 位于同一个 sidebar navigation/session center；mode 是带 SF Symbol 的三行竖向按钮，仅选中行使用 interactive Liquid Glass，session 保留明确选中态与原生 Rename/Delete context menu。
- 设置表单继续优先使用原生控件；主要操作按语义使用 glass 或 glass prominent，不画自定义黑白按钮。

## 4. API 与部署边界

- `glassEffect`、`GlassEffectContainer`、`.glass` 和 `.glassProminent` 只在 macOS 26 / iOS 26 及以上启用。
- 当前产品 deployment target 是 macOS 26 / iOS 26；源码中的 Material / bordered fallback 只保留为防御性实现，不属于当前产品验收矩阵，也不能被替换成手绘静态“仿玻璃”。
- `IntatisSharedUI` 通过可用性检查共享实现，不反向依赖 macOS app target，也不扩大 iOS 的 Chat-only 产品边界。
- 系统 Reduce Transparency、Increase Contrast、accent、active / inactive window 与其他辅助功能设置应由原生 API 自动响应，不能用固定值覆盖。

## 5. 事实来源

- `Apps/TranslatisMac/Sources/TranslatisDesign.swift`：系统 window canvas、macOS 13 兼容表面、语义色与内容卡片。
- `Apps/TranslatisMac/Sources/TranslatisMacRootView.swift`：系统 split-view sidebar 材质、title/竖向 icon mode/history/Settings 内部结构与 detail canvas。
- `Packages/IntatisSharedUI/Sources/ThreadSurfaces.swift`：用户消息原生 regular glass helper、结构化内容 Material、30×30 sidebar New 圆形 glass control、原生圆形 icon controls、40pt composer/selection-menu 几何合同、两排 composer、macOS Context strip、macOS icon-only copy/per-turn metrics footer、iOS full usage strip 与可选 accessories。
- `Packages/IntatisSharedUI/Sources/Views.swift`：共享 Chat 消息和 composer；仅用户消息使用 glass 气泡，其余对话角色继承系统 canvas。
- `Packages/IntatisSharedUI/Sources/CodeViews.swift`、`CoworkViews.swift`、`ArtifactViews.swift`：各产品面的内容层 / 功能层映射。
- `Vendor/SwiftStreamingMarkdown/Sources/MarkdownText/UI/TextSelection/MarkdownDocumentSelectionCoordinator+macOS.swift` 与 AppKit paragraph/table/code leaves：单一 `selectedTextAttributes` 跨 block 选择、transient emphasis、Copy responder 与清理。
- `Apps/TranslatisMac/Sources/TranslatisChatScreen.swift`、`TranslatisMacApp.swift`：macOS Chat、设置与 home CTA。
- `Apps/TranslatisiOS/Sources/TranslatisiOSApp.swift`：iOS JetBrains Mono 标题角色、顶部 session header、
  macOS 同层级抽屉、两排 composer 接线、Settings 与根 Icon Composer resource 选择。

Apple 官方设计与 API 依据：

- [Liquid Glass overview](https://developer.apple.com/documentation/TechnologyOverviews/liquid-glass)
- [Adopting Liquid Glass](https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass)
- [Applying Liquid Glass to custom views](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views)
- [SwiftUI `glassEffect`](https://developer.apple.com/documentation/swiftui/view/glasseffect%28_%3Ain%3A%29)
- [SwiftUI `windowBackground`](https://developer.apple.com/documentation/swiftui/shapestyle/windowbackground)
- [SwiftUI `List`](https://developer.apple.com/documentation/swiftui/list)
- [Apple HIG — Lists and tables](https://developer.apple.com/design/human-interface-guidelines/lists-and-tables)

## 6. 验收清单

- 浅色界面是系统当前解析出的 window / sidebar / Material 外观，而非固定纯白。
- 深色界面是系统当前解析出的 window / sidebar / Material 外观，而非固定纯黑。
- 侧栏保留系统材质，前台 / 后台窗口状态切换时能够跟随系统。
- Liquid Glass 主要出现在导航和交互功能层；内容层例外只包括用户消息气泡与用户明确指定的 Cowork 紧凑 trailing status rail。仅用户消息有外层对话气泡且不得叠加 accent 蓝色描边；assistant / agent / system（包括失败 / 中断回复）直接位于系统 canvas。专用结构化卡片继续使用 Material，页面与长 transcript 不整片玻璃化。
- Code/Cowork默认活动使用自然语言类别与状态，不显示raw App Server method。相同item的started/delta/
  completed原位归并；usage/Goal/permission/Agents/message lifecycle进入各自组件，unknown future event显示
  通用Runtime activity。活动只用系统语义文字、SF Symbol、对齐与留白，不使用card/glass/pill堆叠；raw
  method只在help或backend trace可见。Cowork child不得出现live/durable双份活动。
- 支持的系统上使用真实 `glassEffect` / glass button；旧系统 fallback 仍由系统语义 Material / control 渲染。
- macOS Chat / Code / Cowork 与 iOS Chat 的 Light / Dark 运行态都经过视觉核对；不能只用源码搜索或固定像素值推断。
- thread header显示session display name；Code/Cowork header使用紧凑顶部留白且Cowork不常驻
  permission-reviewer横幅；消息无agent头像与通用Agent badge；正常agent回复无外层卡片；agent名称旁有
  本地化三级时间元数据；已完成Mac回复底部以icon-only copy开始，Chat/历史显示可证明的legacy stats，
  新Code/Cowork显示七项native Responses usage，且无反馈按钮或额外表面。macOS sidebar模式为带图标的
  竖向三行且仅选中行使用玻璃，Recent New `+`为30×30原生圆形glass；macOS composer第一排保持40pt、
  关闭态仅模型名的model/profile glass菜单左，只有Chat保留Context右侧，Code/Cowork不显示Context占位；
  第二排保持已有action左、输入居中、voice紧邻唯一Send/Stop左侧。iOS顶部固定sidebar/session/new，
  抽屉为JetBrains Mono `Intatis`、选中Chat、Recent/New和底部Settings，空页无onboarding/建议卡；底部仍为
  model/full-usage第一排和paperclip/input/voice/Send-or-Stop第二排。两平台第一方英文字形统一使用
  JetBrains Mono，标题/正文/控件仍由语义字号和字重区分；中文继续走Apple CJK fallback。两平台第二排
  action/voice/stop/Send与单行输入均为40pt，输入变为多行时按钮底边不漂移；Cowork宽屏rail第一位为
  权限审查、其后为Agents/Goal/Tasks且无Git，pending时rail固定；无法容纳rail时只显示一个权限兜底卡且
  不复制Goal/Tasks。
- macOS rich message 正向/反向跨 block 拖拽应显示一套连续系统 selected-text 选区；active/inactive window
  都不得让首个 leaf 与后续 leaf 分裂成两种颜色。清除后原文本语义色与 native selection attributes 逐属性
  恢复，table/code 布局不变，Intatis 不显示 `Select more text` 菜单/sheet。Increase Contrast、Dark 与
  VoiceOver 仍须单独验收，不以固定蓝色截图作唯一通过依据。
- macOS 与 iOS touched targets 均可编译，全量 SwiftPM 测试通过。

静态复核重点：

```sh
rg -n 'IntatisTheme\.canvas|scheme == \.dark \? \.black : \.white|Color\.(white|black)|LinearGradient' Apps Packages
rg -n 'glassEffect|GlassEffectContainer|buttonStyle\(\.glass|regularMaterial|windowBackground' Apps Packages
```

第一组命中需要人工确认是否属于图标、图片或测试语境；任何页面 / 组件固定表面色都不符合本规范。第二组用于确认系统语义表面和玻璃入口仍存在。

## 7. 2026-07-15 实施验证

- SwiftPM build 通过。
- TranslatisMac macOS Debug 与 TranslatisiOS Simulator Debug 构建通过。
- 使用 Computer Use 检查本轮构建的 Chat、Code、Cowork：Light 使用系统浅色 window / sidebar / Material，Dark 使用系统动态深灰层级而非纯黑；composer、CTA、模式切换和相关操作呈现原生控件 / Liquid Glass。
- Light / Dark 验收使用 DEBUG-only 启动参数 `-IntatisAppearanceLight` / `-IntatisAppearanceDark` 隔离测试，不修改用户的全局系统 Appearance；生产启动不设置偏好，始终跟随系统。
- 完整 SwiftPM 测试通过：605 tests，14 skipped，0 failures。

## 8. 未固定的部分

- 系统表面、Material、Liquid Glass、`.primary`、`.secondary`、separator、accent 和状态色的最终像素值不固定。
- 不为不同墙纸、显示器 profile、Display P3 / HDR、Reduce Transparency、Increase Contrast 或 window focus 状态建立硬编码色表。
- 本文规范视觉表面与颜色语义，不替代布局、动态字体、焦点、键盘操作和完整无障碍规范。

## 9. 2026-07-21 OS26 UI shell 复验（历史）

- 该次截图与 Computer Use 只验证当时的自定义纵向 mode/session 表面，以及“usage 独占上方一行、model/profile/attachment 位于输入容器”的旧布局。控制位置已被 2026-07-23 方案取代，不能继续作为当前像素、键盘或焦点行为的 Passed 证据。
- 当时的 session-name header、无消息 agent 头像/通用 Agent badge和 Code/Cowork 原生 inspector 结论仍是历史事实。
- `swift build`、TranslatisMac macOS Debug、TranslatisiOS Simulator Debug 与 `CoworkInferencePresentationTests` 4/4 通过。
- Computer Use 在最新 Debug app 中只读检查了 Chat、Cowork 与宽屏 inspector；参考图和实现截图在同一比较输入中核对，结果见根目录 `design-qa.md`。
- 本轮没有改字体 token、用户字体选择、EventLog/projection schema、权限链路、iOS chat-only target 边界或开源依赖。

## 10. 2026-07-22 conversation surface 收口

- Cowork 对话页删除常驻 permission-reviewer 顶部横幅；Code / Cowork session header 的顶部留白统一从 26pt 收紧为 12pt。真正待处理的 `PermissionCard`、permission FIFO 与权限引擎没有删除；横幅原有的 workspace reauthorization / automatic-review retry 只在异常时进入 Cowork Project Settings 的 Recovery 区。
- macOS Chat、Code、Cowork 与共享 iOS Chat 的正常 assistant / agent 回复取消外层 Material、圆角和描边，正文、Markdown 与公式直接继承系统 canvas；用户消息、失败 / 中断回复、tool、error、permission、task 等结构化内容继续保留容器。
- macOS Chat/Code/Cowork 与共享 iOS Chat 的 assistant/agent 名称右侧复用同一时间表现：首次 message envelope 定时，24 小时 / 7 天滚动分层，遵循当前 locale、时区和 12/24 小时偏好；流式完成不刷新为“完成时间”。
- 没有硬编码白色背景，也没有修改字体。`MessageRenderingTests` 22/22、`swift build --disable-sandbox`、TranslatisMac macOS Debug 与 TranslatisiOS Simulator Debug build 通过；运行态 Light / Dark 和真实长回复视觉复核仍待用户检查。
- 名称旁时间追加后的组合过滤实际执行 161 tests / 0 failures，SwiftPM 与 macOS/iOS Debug app target 再次构建通过；遵守 renderer NO-GO，没有启动 App/fixture，因此不同 locale、Light/Dark 和跨阈值长期停留仍未做运行态视觉结论。

## 11. 2026-07-23 原生 List sidebar 与两排 composer（已撤销）

- 该轮曾把 macOS 根侧栏收敛为单个 `List(selection:)`，以 `Section` 组织 mode、当前 mode 的 sessions 与 Settings，并采用 `.listStyle(.sidebar)`；此排布已被同日后续视觉修订撤销，不再代表当前实现。
- composer 第一排为 model/profile 左、usage 右；第二排为当前已有附件/图像 action 左、`TextField` 居中、可选 Cowork stop 与 Send 右。`+`、附件、图像 action、stop 和 Send 使用统一 regular/circle 原生 glass/bordered control，Send 保持 prominent。Cowork selector 仍可在 busy 时选择且只冻结下一次 `@main` Send；没有新增 Chat/Code 附件能力，字体未改。
- Swift parse、`swift build --target IntatisSharedUI`、`IntatisSharedUITests` 50/50、`PerAgentInferenceProfileTests` 20/20、`SubmittedIntentStoreTests` 11/11、`SubmissionProjectionTests` 4/4、XcodeGen、TranslatisMac macOS Debug 与 TranslatisiOS generic Simulator Debug build 均通过。
- 本轮没有启动 App 或 renderer fixture；当前像素、sidebar 键盘/焦点、Light/Dark、Reduce Transparency 和真实窄宽布局仍为 `UNKNOWN`。

## 12. 2026-07-23 sidebar 竖向导航恢复与 composer 几何修正

- sidebar 当前为系统 `NavigationSplitView` 材质内的 `Intatis` 标题、带 SF Symbol 的 Chat/Code/Cowork 竖向三行导航、mode-specific `Recent` history/New 与底部 Settings；仅当前模式行使用 interactive Liquid Glass。该状态取代同日较早的单一 `List(selection:)` 和横向 segmented control 修订；session Rename/Delete、busy delete gate 与 durable selection 逻辑保持不变。
- `Recent` 旁 New `+` 使用 24pt label、`.controlSize(.small)`、圆形 button border shape 与原生 glass，fitting-size probe 为 30×30。composer 仍为两排；第一排 Chat/Code/Cowork 模型或 profile `Menu` 共用 40pt 高 interactive Liquid Glass 胶囊，关闭态只显示模型名，右侧 usage 保持只读且不伪装成按钮。
- 第二排附件/图像 action/stop/Send 的 icon label 统一为 32×32，经原生 `.glass` / `.glassProminent` 或 bordered fallback 后得到 40×40 外观；输入容器单行最小高度为 40、间距为 8、圆角为 20。外层使用 bottom alignment，多行输入时按钮保持贴底。
- 原生控件 fitting-size probe 确认 Recent `+` 为 30×30，plain native `Menu` 加共享 interactive glass label 后为 40pt 高；第二排 glass/glassProminent/bordered 按钮与单行输入均为 40pt。Swift parse、SharedUI build、`IntatisSharedUITests` 50/50、`PerAgentInferenceProfileTests` 20/20、XcodeGen、macOS Debug 与 iOS generic Simulator Debug build 均通过。
- 遵守 renderer NO-GO，本轮未启动 App 或 fixture；实际像素、sidebar 交互、Light/Dark、Reduce Transparency 和真实窄宽布局仍为 `UNKNOWN`。

## 13. 2026-07-31 权限审查与消息标识收口

- 待处理权限使用紧凑、左对齐的低对比 Material 卡片，不再用风险色描整张卡。风险色只用于小图标与 risk chip；tool、reason 与当前状态保持可扫读，结构化 scope 和 patch diff 默认收进 `Details`，避免长参数抢占对话主视觉。
- `Details` 只展示 host 生成的结构化 action preview / intent / resource / touched path；raw JSON arguments 不进入通用详情列表。patch diff 仍可在用户主动展开后查看和选择，权限 action、RequestID/FIFO 与审批语义不变。
- macOS Code/Cowork的official structured question位于composer正上方，保留透明底、system-separator细描边
  的bounded panel，不使用Material、Glass、模糊或固定填充。只显示可选requester、当前问题、SwiftUI
  native single-selection `List`的编号整行、标题下一行的可选secondary description、按需Other文本框、
  多题`N of M`前后导航与右下角`⌘↩`提交；不增加info图标、tooltip-only入口、状态标题、解释段、
  radio/checkbox、自绘选中控件或固定色。
- automatic reviewer 状态只显示进度，不暴露 Approve / Decline / Cancel；人工模式继续区分 `Approve Call`、`Decline Call` 与 `Cancel Turn`。resolved notice 收窄为同一低对比表面的紧凑状态行。
- Chat、Code、Cowork 和共享 iOS Chat 的用户气泡继续靠右并保留既有 Material/宽度合同，但不再重复显示 `You`；assistant、agent、system 的 structured identity header 与 agent timestamp 保留。macOS sidebar 品牌块只显示 `Intatis`。active Chat/Code/Cowork session header 和 sidebar Recent row 都只显示 session name，不在其下显示灰色 model/provider/host、workspace/state、agent/running、event/date/path/runtime metadata；空态首页与 Settings 的说明性 subtitle 不属于 session metadata，继续保留。
- Computer Use 使用独立 bundle 的离线 Phase C fixture 验证了 Light/Dark、默认折叠、详情展开、automatic non-actionable 与 approved notice；另以本轮构建打开真实历史 Chat，只读确认侧栏品牌副标题、active session subtitle、Recent session detail 和用户气泡 `You` 均消失，并在 Cowork history 再核对单行 session row；未发送 provider 请求。当前截图与逐项对比记录见根目录 `design-qa.md`。

## 14. 2026-08-02 iOS 与 macOS 设计语言统一（取代同日全局 serif 记录）

- iOS 不再在 App 根视图设置全局 `.fontDesign(.serif)`。当时的角色区分只影响
  品牌 `Intatis`、当前 session、Settings 页面标题与正文/控件的语义层级。Markdown/plain fallback、代码块、
  公式和第三方声明继续与 macOS 共用 renderer 的语义字体。第 23 节的后续正式决定将这些
  英文字形统一为 JetBrains Mono，并取代本节关于 Apple serif/sans family 的旧基线；本节的语义角色、
  字号、字重和 Dynamic Type 合同继续有效。
- iOS 当前 session 与 Settings 的 large-title nominal size 为 22pt，并继续通过
  `@ScaledMetric(relativeTo: .largeTitle)` 响应 Dynamic Type；共享
  `IntatisTypography.largeTitle` 的 30pt 事实源和 macOS 标题尺寸不变，抽屉品牌标题也保持原值。
- 顶部中央从 model picker 改为 session title；model 选择移入 composer 第一排，
  使用 13pt semibold 语义字体、向下 chevron 与原生 interactive Liquid Glass capsule。
  有 turn stats 时同排右侧显示共享 usage strip；第二排继续是
  paperclip/input/voice/Send-or-Stop，voice 紧邻唯一主操作左侧。
- iOS 的 Send 按钮和键盘提交在调用 Chat send 前先释放 composer FocusState；消息 ScrollView
  使用 `.scrollDismissesKeyboard(.interactively)`，允许用户在消息区拖动收起键盘。模型输出完成、
  输入框重新启用或自动滚动都不得重新取得输入焦点；该行为不改变 macOS composer focus。
- 左抽屉采用 macOS 的同一信息层级：`Intatis`、选中 Chat 玻璃模式行、`Recent`
  session history/New 与底部 Settings；删除旧顶部 gear、假 search 占位和底部大 Chat CTA。
  Settings 使用页面标题语义角色，原生 toolbar、section、说明和字段保持正文/控件语义角色；
  两者的英文字形均由 JetBrains Mono 提供。
- iPhone 17e Simulator 已检查 Light/Dark 主界面、Light 抽屉、Settings 与主屏幕安装态；
  根 `Translatis.icon` 的 2026-08-02 22:26:51 版本正确显示为新版指针图标。对比图与详细
  severity review 见根目录 `design-qa.md`。

## 15. 2026-08-02 Cowork permission-first Liquid Glass rail（历史）

- 用户提供的宽屏 Light 截图作为改造前基线；最新 Light 与 Dark 运行态截图和该基线
  已放入同一比较输入。新 rail 第一位为待处理权限或最近权限结果，其后为 Agents、
  可选 Goal、可选 Tasks；旧 `Git Status`、workspace path 和 Git 说明完全消失。
- 当时版本由系统 `.bar` 提供区域分层，section 使用原生 `GlassEffectContainer` /
  `glassEffect(.regular, in: .rect(cornerRadius: 18))`；该整栏 `.bar` 已由第 17 节的同画布
  overlay 取代。两版都没有固定灰底、采样 RGB、自绘高光、假阴影或手写玻璃资产。
- 权限卡允许宿主关闭其默认 Material，由 rail 的单层 glass 承担表面，避免双层卡片。
  按钮仍使用原生 glass/bordered action style，并通过 `ViewThatFits` 在紧凑 rail 中换行；
  permission action、keyboard shortcut 与 accessibility identifier 不变。
- 980pt 及以上出现 live pending 时，rail 临时固定可见，权限卡只在 rail 中出现；
  窄到无法安全容纳 rail 时，rail 和占位都移除，仅保留一个 composer 上方默认
  Material pending 兜底。当前只读 session 没有 live pending，因此运行态实际截图覆盖
  resolved notice，而 pending pin/fallback 由相同生产路径和 focused tests 验证。
- 最新截图：
  `/Users/vita/.codex/visualizations/2026/08/01/019fbc6f-219c-7340-a461-92dc6f2794b7/cowork-permission-rail-light.png`
  与
  `/Users/vita/.codex/visualizations/2026/08/01/019fbc6f-219c-7340-a461-92dc6f2794b7/cowork-permission-rail-dark.png`。
  完整成对比较、severity review 与最终结论见根目录 `design-qa.md`。

## 16. 2026-08-02 Settings 渐进披露与低噪声层级

- Settings 默认只呈现完成日常 provider 配置所需的字段与 Test/Save。Base URL、Chat
  endpoint、key source 和模型增删改使用原生 disclosure 渐进披露；切换 provider 时收起
  低频分组，避免旧 provider 的展开状态形成视觉误导。
- 页面只保留一个主要 provider 内容卡。`Advanced settings` 与 `Diagnostics` 使用 divider
  和轻量行建立层级，不再以多个同权重大卡片堆叠；Advanced 展开后复用既有 MCP 表面，
  避免 Material 套 Material。
- 低频解释优先放入原生 help，而不是常驻正文。Diagnostics 默认文案限制为一行，明确本地
  ZIP 且不上传；导出成功、失败和采集 warning 仍使用既有状态反馈，不隐藏行动结果。
- 继续使用系统字体、语义色、Divider、DisclosureGroup 和原生 button style，没有新增固定
  色、手绘玻璃或自定义资产。深色运行态已用改前/改后同窗截图和 AX 树检查；浅色、Reduce
  Transparency 与 Increase Contrast 本轮未运行，不能仅凭语义 API 宣称已完成视觉验收。

## 17. 2026-08-04 Cowork Agent rail 视觉收口

- Cowork session header 再次收口为 durable session name 单行，不显示当前正在查看的 Agent；
  当前选择仍由 Agents 行的选中背景表达，不保留不可见 subtitle 占位。
- 宽屏 rail 仍是 conversation detail 同一 canvas 上的 trailing overlay，没有 divider、整栏
  Material 或 `.bar` 背景。rail 使用更宽的稳定几何和更小的 leading inset，让原生 Liquid Glass
  section 明确浮在画布上而不是形成独立侧栏；最右透明命中边界与主滚动条合同不变。
- Agents section 使用更大的原生标题、18pt 内容 inset、52pt 最小行高和系统 semantic text/status
  color。header 使用系统 `person.2.fill`；每行 status marker 直接使用 20pt SF Symbol、30pt 槽位与
  hierarchical rendering，并统一为圆形 symbol family，不叠加自绘圆底或图片资产。选中 ordinary
  agent 只显示 accent 蓝色圆角背景，不再叠加 checkmark；detached 和控制面 identity 继续由不同
  原生 symbol 及是否可点击表达，颜色不是唯一状态通道。
- Agents 按 identity 第一次 durable admission 的创建顺序稳定显示。实时消息、运行状态、detach
  或 reattach 不会重排列表，从而避免用户点击目标移动，也避免为 last-message 排序扫描长会话。
- rail 的“割裂”按光学层级处理，而不是再增加背景板：各 passive section 使用系统原生
  `Glass.clear`（旧系统为 `.ultraThinMaterial` 语义 fallback），且 glass 位于与动态文字/选中背景
  分离的稳定 backdrop。彼此独立的 status cards 不再放入 `GlassEffectContainer`，避免 selection、
  focus 或邻卡内容变化触发整组 glass shape 的光学重组；不自绘渐变、投影或高光。
- 宽屏几何由未压缩 outer width 唯一决定：rail 固定 348pt、glass card 固定 318pt，并单独保留
  10pt 原生滚动条命中净空。选中 Agent、消息数量、文本长度、空态、rich/raw 状态或滚动条出现
  都不得参与宽度计算。transcript 始终复用一个 `ScrollViewReader` / `ScrollView` 根，并先固定
  `contentWidth` 与 thread raw width，再让 overlay 覆盖其上。
- Agents 标题、名称、模型与 Goal/Tasks 的次级文字各提高一个系统文本层级。rail 顶部权限结果
  只保留状态图标与“tool + decision”；pending 权限只保留 tool、安全摘要和必要 actions，risk chip、
  raw arguments 与默认展开详情不进入 compact rail。人工 Approve/Decline/Cancel、automatic
  non-actionable、RequestID/FIFO 与权限引擎语义不变。

## 18. 2026-08-04 Cowork rail 窗口移动与切换稳定性（已被第 19 节取代）

- rail 从参与父级布局的 trailing `ZStack` child 收口为 thread 上真正的
  `.overlay(alignment: .trailing)`；348pt rail、318pt card 与 10pt scroller clearance 不变。
- 本节记录的是被用户再次复现问题的第一版尝试：曾按 global origin 做 backing-pixel 补偿，并保留
  一个收窄 interaction spacing 的 `GlassEffectContainer`。后续真实 Test session 证明该方案仍有
  viewport preference 同帧重复更新，且 screen-global 补偿不是正确的窗口内布局依据，因此二者已删除。
- 每个 passive glass 外叠系统动态 separator 的单物理像素 `strokeBorder`，固定的是结构轮廓而非
  玻璃光线；没有固定 RGB、整栏 separator/Material 背板、自绘渐变、投影或高光。
- 1372×768 Light 原生 fixture 中，Main/Research 的 Agents card 外轮廓均为 x=1076…1366；
  切到 Finder 再返回的 rail crop 逐像素一致。该结果不替代 Dark、Reduce Transparency、
  Increase Contrast、VoiceOver 或不同显示器 scale 的完整矩阵。

## 19. 2026-08-04 Cowork rail 稳定 surface 与无坐标回写

- rail 继续由 outer detail width 固定为 348pt、card 固定 318pt，并作为 trailing overlay；不做任何
  screen-global origin 或 backing-pixel translation。
- rail 使用仅含 Agents/permission/Goal/Tasks/selection/appearance 的 Equatable render snapshot；
  transcript 的 empty/loading/page/rich 更新不会重新物化 rail subtree。
- 每个 `Glass.clear` 位于独立稳定 backdrop；蓝色 selected-row 内容更新与原生 glass surface 分层。
  independent cards 不共享 `GlassEffectContainer`，从根源上取消邻卡光学融合/重组。
- Code/Cowork 删除 `IntatisThreadViewportFramesPreferenceKey`、GeometryReader frame probe 和
  `.global`/named coordinate comparison；raw bottom-anchor 改由系统 `onScrollVisibilityChange`
  观察，窗口移动、focus 与全屏变化不再因 origin 改变触发布局 preference。
- 85 个 MessageRendering/ThreadLayout/ThreadScrollCoordinator focused tests 通过；其中 AppKit host
  交错完成 360 次 agent selection、mode、inspector 和 window size 变化。真实 Test 长历史完成
  main/code-reader/doc-reader 连续切换、Xcode 失焦/回焦和全屏变化；同 viewport strip 中 card 外边界
  保持一致，回焦 AX tree 无结构变化，且系统日志中旧 viewport preference warning 为 0。原生
  全屏过渡仍出现一次 AppKit/ThemeWidget 的系统 negative-geometry warning；该 warning 未在 agent
  或 focus 操作中复发，不作为 rail 通过证据，也不得误记成已消除全部 AppKit runtime warning。

## 20. 2026-08-05 输入栏语音按钮

- macOS Chat/Code/Cowork 与 iOS Chat 的 composer 第二排在唯一 Send/Stop 左侧新增同一个 40×40
  原生圆形 voice control；它不改变第一排 model/usage，也不复制或挪动 Send↔Stop 主操作槽位。
- idle 显示 `mic.fill`；第一次点击开始录音，recording 显示 `stop.fill`，第二次点击停止并转写；
  requesting permission 与 transcribing 使用同一位置的 progress 状态。转写结果只追加到当前可编辑
  草稿，不自动 Send，错误显示在 composer 本地状态区。
- 该功能只复用顶层 `transcription_model` 与既有 provider 配置/importer，没有新增 Settings 字段、
  页面、固定颜色、自绘图标或第三方视觉资产。English/简体中文按钮、状态、错误与麦克风 usage
  description 已接入两端 bundle。后续把底层替换为 Flotis-derived WAV recorded-file runtime、
  disk-backed upload 与 OpenRouter JSON adapter，没有改变上述 control 尺寸、位置或视觉状态，也没有
  迁入 Flotis 的 panel、设置 UI、快捷键或输入法外观。
- draft/config focused tests、完整 SwiftPM tests、XcodeGen、macOS Debug 与 iOS Simulator Debug build
  已通过；本轮未启动 App、未请求真实麦克风权限，也未做 Light/Dark、窄宽、Dynamic Type、
  VoiceOver 或真实录音的运行态视觉检查，因此这些像素与交互结果仍为 `UNKNOWN`。

## 21. 2026-08-13 用户消息原生 Liquid Glass 气泡

- macOS Chat、共享 iOS Chat 与 Code/Cowork 共用消息行都收敛为同一角色规则：只有用户消息
  带外层气泡，继续保持 trailing 对齐、原 `messageMaxWidth` 与 gutter；其他对话角色直接位于
  conversation canvas。
- 用户气泡复用 `ThreadSurfaces.swift` 已有的 `intatisLiquidGlass`，在当前 macOS 26 / iOS 26
  产品面使用原生 `Glass.regular`。旧 `.regularMaterial` 用户表面及 accent 蓝色细线描边已删除，
  没有新增颜色 token、自绘高光、渐变、阴影或玻璃组件。
- assistant/agent/system 的普通、失败与中断回复不再因 failure/recovery 状态获得外层容器。
  Chat recovery advice 仍跟随原消息正文；Code/Cowork recovery advice 与错误事实统一迁入右栏，
  正常 tool、permission、artifact、Goal/Task 等专用结构化卡片保持不变。
- `ThreadLayoutTests` 18/18、`swift build --disable-automatic-resolution`、TranslatisMac macOS Debug
  unsigned build 与 TranslatisiOS generic Simulator Debug unsigned build 均通过。未启动 App 或 fixture；
  实际折射强度、长用户消息、Light/Dark、Reduce Transparency 与 Increase Contrast 仍需运行态观察。

## 22. 2026-08-13 Code/Cowork 会话错误统一右置

- `ThreadSurfaces.swift` 只在 presentation 层收集当前 page 的 `.error`、失败 tool/patch/note、
  `recoveryAdvice`、失败 submission，以及宿主传入的所有页面级错误字符串；规范化后相同文案
  合并为一项。Code/Cowork 不再用 `??` 丢弃同时存在的后续错误。
- Code inspector 与 Cowork Liquid Glass rail 都只在列表非空时于最底部生成一张“错误信息”卡片；
  卡片内部可列出多项错误。Cowork 的 retryable submission 保留 exact `SubmissionID` 与 Retry，
  不另造自动重试。
- thread 使用错误清理后的 presentation copy：完整移除 error/失败 trace 行和 recovery 文案，
  清除用户行的 `Needs attention`/timeout 状态，同时保留用户消息、正常消息及已产生的 partial agent
  正文。EventLog、`CodeProjection`、submission failure 和 runtime error 的 durable 数据均未改动。
- `ThreadLayoutTests` 21/21、`swift build --disable-automatic-resolution`、TranslatisMac macOS Debug
  unsigned build 与 TranslatisiOS generic Simulator Debug unsigned build 均通过。测试直接复现同一 timeout
  同时来自失败 submission 与 `.error` 的截图场景，确认右栏去重为一项并保留 Retry；未启动 App 或
  fixture，长错误滚动、Light/Dark 与窄宽实际像素仍需手动观察。

## 23. 2026-08-19 JetBrains Mono 全局英文字体正式规范

- 用户在视觉试用后明确批准保留 JetBrains Mono。macOS/iOS 所有正常 Debug、Release 与发行构建都
  使用它作为第一方可控界面的统一英文字体；不再提供实验参数、system-font opt-out 或第二套默认字体。
- 正式接线保留所有现有名义字号、字重、iOS 22pt session/Settings override、`@ScaledMetric` 与 Markdown
  Dynamic Type scale，只替换英文字形 family。第一方 SwiftUI 的共享 role、直接 semantic/system font
  call sites、plain message、rich paragraph/heading/list/table/inline-code 与 code-block body 均接入同一
  product typography seam；没有通过运行时 swizzle 或第二 renderer 伪造。
- 两份官方 JetBrains Mono 2.304 variable TTF 原样进入 `IntatisSharedUI` 的 SwiftPM resource bundle，
  macOS/iOS 与 SharedUI tests 通过 `Bundle.module` 使用同一份 bytes。App 启动先校验固定
  SHA-256、完整 PostScript-name inventory、Core Text process registration 和 registered-font bundle URL；
  缺资源、篡改、同名冲突或解析漂移会明确终止实验，不使用系统安装字体或另一 family 兜底。
- JetBrains Mono 没有 CJK 字形；中文继续由 Core Text glyph fallback 使用系统 CJK font。该边界符合
  “只改英文字体”，但中英混排字宽、baseline 与视觉节奏仍须由用户实际观察，不能从单一截图外推。
- 当前 iPhone 17 Pro 隔离 Simulator 的无参数 Light 启动已看到 JetBrains Mono 的 `New chat`、model
  label 与 composer placeholder；macOS 隔离 Renderer Fixture 也在无字体参数下稳定存活。自动化尚未覆盖
  Dark、超大 Dynamic Type、VoiceOver、真实长中英混排、全部系统 sheet/menu/control 与真机。
- 正式发布须继续完成 release/accessibility/license/bundle gate；尤其要验证 Dark、超大 Dynamic Type、
  VoiceOver、真实中英混排、真机与正式签名/公证。字体选型本身已经定案，不再要求删除这些资源。

## 24. 2026-08-20 macOS 逐回复操作与 usage footer

- macOS Chat、Code、Cowork 的已完成 assistant/agent 对话行在正文最下方复用同一个无表面 footer；
  `doc.on.doc` 是最左且唯一的消息操作，不显示文字，也不加入点赞/点踩或其他反馈动作。
- 复制操作写入 raw EventLog/projection message text，保持 Markdown、代码围栏、公式源文本与换行；
  footer 的统计、名称和时间不进入 clipboard。
- `turn_stats` 的 optional `turnID` / `responseMessageID` 只把新式 exact stats 投影到对应回复；旧日志
  缺关联时不按邻近或正文猜测。footer 依次显示可证明的 Input（prompt-cached）、Cached、Output、
  Time；缺字段就省略，不造零值。
- macOS composer 第一排右侧只保留 Context；iOS Chat 本轮保持完整 latest-turn usage，不把 Mac
  交互变更外推到 iOS。
- footer 不进入 Markdown renderer、没有 Material/Glass/card 或固定颜色，因此不改变 rich admission、
  paragraph layout、16-row paging、Cowork rail 或用户气泡合同。

## 25. 2026-08-21 macOS 气泡、Jump 与 Tasks 紧凑化

- macOS Chat/Code/Cowork 用户消息仍是唯一 `Glass.regular` 对话气泡；材质、语义色、trailing
  alignment、`messageMaxWidth` 与 gutter 不变。continuous corner radius 统一为 20pt，使单行 intrinsic
  content 呈现接近胶囊的形状，多行/附件消息仍保持圆角矩形。
- Code/Cowork user row 不再渲染 queued/running/completed/cancelled submission status。此前 status
  HStack 的 `Spacer` 会把短消息撑满允许宽度；删除整个 presentation row 后气泡随正文收缩。
  SubmissionID/status/EventLog/projection、失败右栏和 Retry 不变；permission card/notice 完全不属于本次删减。
- `Jump to latest` 复用已有 native glass helper，但使用 `.large` control size 与 13pt arrow，显示更实用的
  圆形 `arrow.down`；视觉文字删除，但本地化 help、VoiceOver label 与 identifier 保留。macOS root
  注入完整 window content width，纯 layout policy 用 window/detail/overlay-surface widths 补偿实际
  sidebar 与 Code inspector；因此 Chat/Code/Cowork 都落在包含 sidebar 的整个 app window 横向中线。
  Cowork 的 ScrollView 继续跨越 thread + rail，并删除 rail clearance 的 trailing offset；standalone
  fixture 缺 window host 时回退自身中线。没有新增自绘图标、颜色、材质或 shape fallback，也不读取
  screen-global geometry或写 PreferenceKey。
- Cowork Tasks 的 `Glass.clear` card 外表面和 durable projection 不变。默认 header 只显示 `Tasks` 与
  completed/total；row 只显示一个 status marker、标题与可选 trailing disclosure。可见 Ready/Completed
  文案、ordinal、leading disclosure、strikethrough 和独立 progress 行均删除；status 通过 AX value/help
  保留，展开后仍显示 detail/result/evidence/dependencies/invocations。
- Agents header 与 row status 都直接使用系统 SF Symbols。header 为 `person.2.fill`；status marker 最终从
  原始 13pt/20pt 明显放大到 20pt/30pt，并使用 hierarchical 圆形 symbol family，删除媒体式 play、triangle、
  octagon、gauge 与 slash 的混合外观；没有自绘 icon、额外图片资源或自定义圆底。
- `ThreadLayoutTests` 29/29、SwiftPM build、TranslatisMac Debug、TranslatisiOS Simulator Debug 与离线
  Cowork fixture build 通过。
  Computer Use 已在真实 Cowork session 观察短气泡和 compact Tasks，并在 fixture Earlier 页观察放大后
  位于 fixture 整体中线的圆形 Jump button；whole-window sidebar/inspector 补偿由纯 geometry test 冻结。
  新 agent-status fixture 另确认 `person.2.fill` header 与 20pt/30pt hierarchical 圆形 SF Symbols
  没有挤压名称、模型标签、选中背景或 52pt row geometry。
  Light 视觉通过，Dark/Reduce Transparency/Increase Contrast/VoiceOver 仍需后续手动矩阵。

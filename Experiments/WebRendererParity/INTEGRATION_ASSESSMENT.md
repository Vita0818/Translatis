# Web renderer 与 Intatis 原生渲染层对比

日期：2026-07-26

## 结论

把这个实验的**行为合同**作为 Intatis 的参考是可行的；把 React、KaTeX、
CodeMirror 和会话驻留控制器整套塞进生产 App 的 `WKWebView` 则技术上可行、
工程上不划算。当前直接接 App 的结论是 **NO-GO**。

推荐保留现有 `IntatisMessageContentView`、plain-safe 熔断、64 KiB admission、
latest-only scheduler 和原生 `DocumentView`，分阶段把缺失行为移植到
`Vendor/SwiftStreamingMarkdown`。这个目录应继续作为独立参考实现和 DOM
合同，不应直接成为 SwiftPM/XcodeGen 的运行时依赖。

## 两条代码链路

### 本实验

```text
raw source
  → react-markdown / unified
  → GFM + hard-break + literal-HTML plugins
  → explicit LLM-math micromark adapter
  → React component boundary
      → KaTeX HTML + MathML
      → read-only CodeMirror + lazy language parser
      → safe link / non-loading image policy
```

关键文件：

- `src/renderer/MarkdownRenderer.tsx`
- `src/renderer/remarkLlmMath.ts`
- `src/renderer/MathRenderer.tsx`
- `src/renderer/CodeBlock.tsx`
- `src/renderer/urlPolicy.ts`

### 当前 Intatis

```text
raw message
  → IntatisMessageContentView
  → rich/plain-safe routing + exact raw fallback
  → 64 KiB admission + latest-only parse scheduling
  → vendored SwiftStreamingMarkdown / swift-markdown
  → native SwiftUI DocumentView
      → TextKit 2 + iosMath inline attachment
      → plain selectable SwiftUI code block
```

生产事实源：

- `Packages/IntatisSharedUI/Sources/MessageRendering/IntatisMessageContentView.swift`
- `Packages/IntatisSharedUI/Sources/MessageRendering/IntatisMicrosoftMarkdownPipeline.swift`
- `Vendor/SwiftStreamingMarkdown/Sources/MarkdownText/Parser/InlineMathPreprocessor.swift`
- `Vendor/SwiftStreamingMarkdown/Sources/MarkdownText/UI/CodeBlockView.swift`

## 能力对比

| 维度 | 独立 Web 实验 | 当前 Intatis 原生实现 | 判断 |
|---|---|---|---|
| Markdown | CommonMark、GFM table/task/autolink/strikethrough、hard break、source offsets | `swift-markdown` 0.8 + 原生 heading/list/table/quote/code 布局 | 主体已具备；soft/hard-break 和边缘语法仍需同 fixture 比对 |
| 原始 HTML | 转成文字节点，不进入 HTML parser | 不存在浏览器脚本执行面；HTML 节点最终显示形态尚需 fixture 固定 | 安全目标一致，显示合同未完全等价 |
| 公式定界符 | `\(...\)`、`\[...\]`、`$$...$$`；单 `$...$` 保持文字；代码内不解析 | 仅 code-aware 单美元 `$...$` inline；其余定界符保持文字 | 最大的明确语法缺口 |
| 公式引擎 | KaTeX 0.16.21，HTML + MathML、横向滚动、有限缓存和错误回退 | iosMath 2.5.0 + TextKit 2 live attachment、Dynamic Type、原始 TeX/辅助功能回退 | 原生引擎可继续用；block math 需要新 renderable/layout |
| 代码块 | CodeMirror 6，只读/不可编辑、按语言懒加载、未知语言 plain fallback | 原生 `Text`、横向滚动、真实 Copy 按钮，无语法高亮 | 高亮和增量尾部是明确缺口 |
| 流式代码 | append-only 尾部暂不着色，500 ms 后结算；generation 防旧结果覆盖 | 整条消息 50 ms debounce；raw 100 ms 投影；全局 1 running / 32 pending latest-only | 原生背压更强；要做代码尾部需保留这些门 |
| 链接/图片 | URL allowlist；阻止 scheme-relative URL；图片只显示占位，不发请求 | 仅 `http`/`https`/`mailto`；图片 disabled | 原生策略更窄，应继续作为生产标准 |
| 输入上限 | 512 KiB 字符实验上限 | 64 KiB UTF-8 rich admission，超限 exact plain text | 不应因接入而放宽生产上限 |
| 降级 | 单消息 error boundary、plain code、公式 literal fallback | renderer-wide plain-safe、exact raw fallback、stale publication guard | 生产保护更完整，必须保留 |
| 可访问性 | MathML、语义 Markdown、只读 textbox | 原生 Dynamic Type、VoiceOver/selection、公式原始 TeX attachment | 直接 WebView 会引入新的辅助功能与焦点边界 |
| 供应链/体积 | 本次安装图 266 个 runtime+dev 包；主入口约 941.04 kB minified / 290.19 kB gzip，另有语言 chunks 和 KaTeX fonts | 已审计的 vendored Swift derivative + exact iosMath | 直接引入 Web 栈会显著扩大审核和分发面 |

## 接入方案

### A. 生产中嵌入完整 Web renderer

可行性：**技术上可行，当前不推荐**。

需要新增本地 `WKWebView` 资源加载、Swift↔JavaScript revision/cancel bridge、
内容高度同步、链接代理、剪贴板、主题/Dynamic Type、VoiceOver、选择、CSP HTTP
header、macOS/iOS 双平台资源和进程生命周期处理。它还会绕开现有原生
`DocumentView` 的成熟 stale-request、scheduler 和 plain-safe 保护，除非把这些
保护全部重新包在 WebView 外层。

这条路与当前 Apple-first、Swift-native 优先及“本任务不引入生产依赖”的边界不符。

如果下一步只想做同语料 A/B，而不是改默认 renderer，可以在
`IntatisMessageContentView` 完成 role、plain-safe、revision、appearance 和
typography 判定后，增加仅启动参数可用的第三个实验 backend。Native→Web 只传
`generation/rawText/isComplete/theme/typography/configVersion`；Web→Native 只回
`generation/measuredHeight/link/copy/ready/failure`。所有回调必须 exact-generation
匹配，WebContent 退出、超时或加载失败立即显示当前 raw source。不要先改成新的
持久默认值，也不要把桥放到 Chat/Code/Cowork projection 之前。

### B. 把行为移植到现有原生 renderer

可行性：**高，推荐**。

1. 在 `MathRenderConfig.Mode` 增加独立的 Chat-style delimiter 模式；不要改变
   现役 single-dollar 模式的含义。
2. 复用现有 code/link/image/raw-HTML protected ranges，让 `\(...\)`、
   `\[...\]`、`$$...$$` 的扫描与占位替换保持 code-aware、bounded、
   fail-closed。
3. inline 继续走现有 iosMath attachment；为 display math 增加显式 block
   renderable、最大尺寸、横向滚动、literal fallback 和 source-preserving copy。
4. 在 `CodeBlockView` 后面放一个可取消、generation-scoped 的 native highlight
   adapter。未知语言必须继续显示原文；Copy 永远读取 canonical raw code。
5. 若增加流式尾部高亮，保留当前 64 KiB admission、50 ms incomplete debounce、
   100 ms raw projection、1/32 latest-only permits 与 stale publication guard。
6. 用同一组语料同时驱动本目录 DOM tests、vendor parser tests、
   `MessageRenderingTests` 和 `RendererFixtureView`，再做真实 VoiceOver/clipboard/
   长消息 soak。

推荐接缝仍是：

```text
IntatisMessageContentView
  → IntatisMicrosoftMarkdownPipeline
  → MarkdownRenderConfig
      → native math delimiter adapter
      → native code presentation adapter
  → DocumentView
```

不要让实验目录读取 EventLog、凭据、工具、workspace lease 或 agent runtime。

## 多会话切换实验补充

当前页面新增的生命周期层是可读、可测的独立模型：

```text
switch request
  → cancel active stream generation
  → unmount keyed message subtree
  → previous session becomes warm for 30 s
  → mount newest 12 messages for the selected session
  → viewport boundary releases far Markdown / KaTeX / CodeMirror children
  → return before expiry cancels eviction; otherwise metadata becomes cold
```

外层 shell 在切换时保持同一个 DOM 节点；旧 session 的 message subtree 会
disconnect，不会隐藏在另一个 tab panel。warm 状态只保留 session ID、时间和
状态，不保留隐藏的消息 DOM 或 CodeMirror view。fixture 的 raw message 是实验
输入事实源，随时可从 cold 重新投影。

这层实现适合验证 teardown、timer cancellation、分页和 viewport release
合同，但**不能**直接证明 ChatGPT 私有 thread tree、Intatis runtime 或 WebContent
进程会使用相同内存。真实生产方案还需要：

- active + 1–2 warm 的全局 LRU/byte budget，而不是只按条目数；
- hibernate 时取消 projection subscriber，记录最后 durable `seq`，恢复时从
  EventLog catch-up；
- 切换 generation、旧 renderer root cleanup acknowledgment 和 late callback
  fencing；
- selection/focus/scroll anchor/VoiceOver 保持；
- parser queue、math cache bytes、已加载语言、EditorView、observer/timer、
  JS heap/WebContent RSS/native runtime 的统一 telemetry；
- memory pressure 下可回收整个 renderer realm，并从 canonical raw source
  正确重建。

因此这次页面增强不会改变上面的生产建议：只复用 renderer kernel 的行为和
测试语料；不要把实验 session shell、React root 或 WebView 直接接到
Chat/Code/Cowork。

## 已验证与未验证

当前 46 个测试覆盖 Markdown DOM、HTML literal、URL policy、KaTeX/MathML、
公式错误、代码内公式隔离、语言加载、unknown fallback、canonical copy、
Strict Mode、streaming tail、suffix-only editor update、warm timer、subtree
disconnect、pagination、stream cancellation 和 editor teardown。先前真实
Microsoft Edge 检查使用 DOM、computed style、clipboard 和
`window.rendererHarness`，没有使用截图；同时确认所有资源请求都来自
`127.0.0.1`。本次 lifecycle 页面没有新增手工浏览器验收。

尚未验证：

- Web 实验与 Intatis native fixture 的逐语料视觉/辅助功能一致性；
- 原生 block math 的布局和 selection；
- 生产级 native 语法高亮供应链；
- 低端 iOS 设备、超长消息与多会话长期 soak；
- ChatGPT 私有实现的未公开内部算法。此实验只复现所需行为，不声明复制或完全等价。

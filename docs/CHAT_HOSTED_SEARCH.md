# Chat 与 Agent 托管网络搜索产品合同

文档状态：当前产品合同与实现说明
最近核对：2026-09-02
产品基线：v0.72（build 72）

## 一句话定义

托管网络搜索只属于用户当前选择的 exact Chat provider/model/variant route。该 route 明确支持
托管搜索时，Intatis 向模型提供厂商对应的搜索能力，并由模型通过 `tool_choice: auto` 自己决定
当前问题是否需要搜索。该 route 不支持、未声明、无法确认或尚未适配时，Intatis 静默发送普通
Chat 请求：不搜索、不提示，也不切换到其他模型或搜索服务。

## 用户可观察行为

| 当前所选 exact Chat route | Intatis 发给模型的能力 | 最终行为 | 用户界面 |
|---|---|---|---|
| 明确支持托管搜索 | 厂商对应的托管搜索声明，`tool_choice: auto` | 当前模型自行决定是否搜索 | 不新增按钮、开关、状态或提示 |
| 明确不支持 | 不声明搜索能力 | 当前模型普通回答 | 静默，不提示 |
| 支持情况未知或 adapter 尚未实现 | 不声明搜索能力 | 当前模型普通回答 | 静默，不提示 |
| 搜索能力已提供，但模型认为无需搜索 | 搜索能力仍可用 | 当前模型直接回答，不产生来源 | 不显示空 Sources |
| 当前模型实际使用搜索 | 搜索能力可用 | 当前模型返回回答及结构化来源 | 只展示通过安全校验的 citations |

“模型自己选择”只表示当前所选模型决定是否调用已经提供给它的托管搜索能力。Intatis 不按关键词
预判是否搜索、不强制执行搜索，也不先发一次可能失败的搜索请求来探测能力。

## 每次 Send 的路由合同

1. 在 Send 边界冻结用户当前选择的 exact provider、model、variant、request adapter 与原始
   model options。用户切换模型或接入点后，下一次 Send 必须重新规划。
2. 先确认该 exact route 的普通 Chat adapter 可执行。普通 Chat adapter 本身未知或不受支持时，
   继续按既有配置错误处理；不能伪装成“仅搜索不支持”。
3. 只有同时满足以下条件才向当前模型声明托管搜索：
   - exact request adapter 已实现并通过审查的厂商搜索 dialect；
   - exact model/endpoint 有受审 catalog 或用户配置提供的明确 `hosted_web_search` 能力依据；
   - 搜索所需 endpoint family 与结构化 citation decoder 均已实现。
4. 条件满足时，在同一个用户已选 provider/model/variant 上使用对应 dialect，并保持
   `tool_choice: auto`。
5. 任一搜索条件不满足时，省略全部托管搜索字段，使用同一个 exact Chat route 发送普通请求。
   该分支不产生 toast、banner、错误卡、状态文字、模型提示词或设置警告。

`responsesEndpoint` 存在、Base URL 长得像某厂商、provider/model 名称或 model slug 都不能单独
证明支持搜索。不得通过 URL、品牌名或相似名称猜测能力。

## `web_search_model` 的处理

`web_search_model` / `webSearchModel` 曾被设计为隐藏后台搜索模型路由，但该运行时行为现已明确
取消。目标实现不得读取它来覆盖当前 Chat route、选择第二个模型、执行 fallback 或发起额外
provider 请求。

为兼容既有配置，decoder 可以继续接受并保留该字段，且不得因此显示警告或阻止普通 Chat；但它
在运行时没有效果。Intatis 新生成的配置不应再主动加入该字段。是否在未来 schema 版本中彻底
删除兼容 decode，需要另行进行配置迁移评审，不能在读取用户文件时擅自删除或改写。

## 厂商协议适配

托管搜索必须由 exact adapter 映射，不能把一个厂商的 request shape 硬编码给所有
OpenAI-compatible 接入点。

| exact adapter / dialect | 目标 wire 映射 | 支持依据 |
|---|---|---|
| OpenAI native Responses | `web_search` | exact adapter 与 Responses decoder 已实现，且 exact model 明确支持 |
| OpenRouter server tools | `openrouter:web_search` | OpenRouter adapter 与对应 stream/citation decoder 已实现，且当前 exact route 可使用该 server tool |
| `@ai-sdk/openai-compatible`、legacy 或其他 custom adapter | 默认无托管搜索 | 只有新增并审查对应 dialect 后才可启用，不能因“OpenAI-compatible”自动继承 |

上表描述的是 Chat 的 provider-hosted 能力，不是 Chat 中的 Intatis Tool。现有
`Capability.toolSearch` 表示 MCP deferred `tool_search` 合同，不得复用为网络搜索能力。
Code/Cowork/CLI另有一个显式 `hosted_web_search` Intatis Tool包装同一类provider-hosted wire；它与Chat
透明能力、MCP `tool_search`、`browser_search`、`web_fetch`各自独立。该Tool只通过pinned App Server
official `thread/start.dynamicTools`发布，App Server内建`web_search`继续固定为disabled。

新增厂商或模型接入点时，必须同时提供 dialect encoder、stream/citation decoder、能力声明来源
和请求 fixture。只增加 endpoint URL、provider 名称或 `responsesEndpoint` 不能自动获得搜索能力。
未知新接入点的默认行为永远是“普通 Chat 可用、托管搜索关闭”。

## 请求参数与严格路由

- 当前 route 的原始 model/variant options 继续由 exact package adapter 降级；`reasoning`、采样、
  response format 和 provider routing 配置不得因开启或省略搜索而丢失。
- `provider.only`、`allow_fallbacks`、`require_parameters` 等严格路由选项必须保真。不得通过关闭
  `require_parameters`、放开 fallback 或删除用户路由限制来掩盖搜索参数不兼容。
- Intatis 只拥有运行时结构字段。支持搜索时只注入该 dialect 必需的 tool/endpoint 字段；不支持
  时只省略托管搜索字段，不得改写其他用户配置。
- Chat中provider实际是否执行搜索仍由 `tool_choice: auto` 和当前模型决定；advertise capability不等于
  execute search。Agent显式工具调用则使用独立的`tool_choice: required`专用请求，不能把两种合同互换。

## 不支持与运行时失败

- 请求发送前已知不支持、未知或未适配：静默普通 Chat，不记为错误。
- 若 exact adapter 能把 provider 响应确定分类为“托管搜索不受支持”，且尚未接受任何文本、
  citation、usage、completion 或其他有效模型 payload，可在同一 provider/model/variant 上至多
  重发一次普通 Chat 请求；该降级不提示用户。
- 不得只匹配自由文本、任意 HTTP 404 或“看起来像参数错误”就重发。只有 provider-specific 的
  状态、错误字段和 adapter 分类组合能证明搜索能力被拒绝。
- 其他 provider/config/transport 错误，或已接受任何有效 payload 后发生的失败，继续走普通的
  sanitized provider error 路径；不得静默重放、切换模型或制造第二份回答。

## Sources 与持久化

- 只有当前模型实际使用托管搜索且 provider 返回结构化 URL annotation 时才产生 citations。
- citation 只接受带 host、无 user-info 的 HTTP(S) URL 并去重；不得从 Markdown 正文猜测来源。
- provider annotation 若同时暴露 `content`、`start_index`、`end_index`，Intatis 必须和
  `url`、`title` 一起接收；`web_search_call.action.sources` 另行暴露的 URL 也必须并入同一来源集。
  流式增量、search-call item 与最终 response 中的同 URL 记录合并为信息更完整的一项，不能因为
  较早记录只含 URL 就丢掉最终 evidence excerpt。
- `message_completed.citations` 继续是 optional additive 字段，旧 EventLog 不受影响。
- 没有搜索、模型未调用搜索或普通 Chat 降级时，citations 为空；UI 不显示空 Sources 区域。

## 明确不做

- 不为每条消息强制执行网络搜索。
- 不在不支持时显示提示、警告或搜索错误。
- 不使用 `web_search_model` 切换隐藏模型或执行 fallback。
- Chat 不注册或调用 Intatis 搜索工具，也不调用 `hosted_web_search`、`web_fetch`、
  `browser_search`、本地浏览器、shell、MCP 或第三方搜索后端作为 fallback。
- 不按关键词预分类是否搜索，不选择“相似”模型，不从 URL 或名称猜测支持情况。
- 不为了规避 provider 路由错误而放松用户的严格 routing options。
- 不实现任何两模型搜索编排。

因此，macOS/iOS Chat 仍是无 Intatis Tools、无 PermissionEngine 的产品面；托管搜索只是在当前
exact provider wire 上向当前模型提供的一项可选能力。

## Shipping Agent Tool 合同

2026-09-02起，Code、Cowork与CLI Code/Cowork通过official App Server `dynamicTools`条件式发布仓内既有
`hosted_web_search`。这次变更只增加exact route/service/authority接线，没有重新实现搜索、浏览器或provider
协议，也没有恢复legacy AgentLoop。

- `hosted_web_search` 是普通 Agent Tool，schema 只有 required string `query`，`strict:true` 且
  `additionalProperties:false`；模型不能选择 engine、provider、model、adapter、result count、URL
  fetcher 或浏览器 profile。
- tool只有在exact agent route的model metadata明确声明`hosted_web_search`、exact adapter有受审dialect、
  host已冻结匹配service并且当前read-write `CapabilityLease`含独立
  `ToolCapability.hostedWebSearch`时才可执行。read-only、reviewer、旧durable lease或不支持的route不得
  被静默扩权。
- Code只有root route；Cowork与CLI Cowork为root和每个显式child role分别解析service。App Server因固定
  fork surface要求所有后代共享schema，所以某个route支持时其他caller可能看见同名schema；这不构成
  authority。host使用不可由模型填写的root/role scope选择exact service，unsupported/read-only caller在
  permission与provider dispatch前拒绝。省略`agent_type`的后代只继承其最近显式role或root scope。
- 工具通过 `ToolRegistry`、schema/secret validation、`CapabilityLease`、`WorkspaceLease`、三层权限门、
  durable execution ticket、executor 与 `tool_result`，不是绕过App Server turn的隐藏 provider 请求。
- executor 冻结并复用调用 agent 的同一个 exact provider/model/options route，发起一个专用
  provider-hosted search 请求。该请求只有一个 hosted search tool，因此使用
  `tool_choice: required`；Chat 的透明请求继续使用 `auto`。
- 工具路径禁止 ordinary-model fallback：provider 明确拒绝 hosted-search shape 时 typed fail closed，
  不能把普通模型回答伪装成搜索结果。它也不会改走 `browser_search`、`web_fetch`、MCP、shell、
  本地浏览器或另一个模型。
- provider 返回的 citation evidence 先进入同一次有界 ToolObservation，字段包括上游实际暴露的
  URL、title、content excerpt 与 answer span；内层模型生成的回答只作为随后附带的
  `Provider summary`。工具不打开来源 URL、不二次抓取、不再调用另一个模型，也不声称取得了
  provider 没有向客户端暴露的搜索后端原始记录。所有来源在既有 50,000 Character 输出边界内
  按返回顺序保留；超界时显式标记 truncated，不再使用独立的 24-source 提前截断。
  OpenRouter `openrouter:web_search` 未暴露 engine 参数，因此遵守其服务端默认 engine 选择；
  Intatis 不在本工具内另行选择搜索后端。

## 当前实现（2026-09-02）

- `ChatViewModel` 与 CLI Chat 每次 Send 都调用 `ProviderRegistry.chatRuntimeRoute()`；该方法只读取
  当前 `models.chat` endpoint/model（CLI 的本轮 model override 也保持同一 endpoint），完全忽略
  `models.webSearch`。
- `Capability.hostedWebSearch` 与 MCP deferred `Capability.toolSearch` 已分离。能力只接受 exact
  model metadata 中的 `capabilities: ["hosted_web_search"]` 或
  `supports_hosted_web_search: true`；显式 false 优先，缺失默认关闭。
- planner 先验证普通 Chat adapter。当前已实现的普通 Chat adapters 中，OpenRouter 可规划
  `openrouter:web_search`；compatible 与 legacy 始终规划为普通 Chat。OpenAI native
  `web_search` encoder 已独立实现并有 request fixture，但 `@ai-sdk/openai` 的普通 Chat adapter
  仍未实现，因此 exact route 会继续在网络前返回既有 config error，而不会被误报成“仅搜索不支持”。
- Responses builder按dialect分别编码OpenAI `web_search`与OpenRouter
  `openrouter:web_search`。Chat使用`tool_choice:auto`；Agent service使用`tool_choice:required`并固定
  `unsupportedBehavior:failClosed`。compatible、legacy、unknown或未声明能力的agent route不获得service。
- `ProviderRegistry.codexRuntimeRoute`把App Server Responses route和同一exact provider/model配置的optional
  hosted-search route一起冻结；`CodexBusinessToolHost`只接收按`.root`或`.childRole(name)`预绑定的既有
  `ProviderHostedWebSearchToolService`。工具参数、App Server JSON-RPC与EventLog都不包含provider、model、
  credential或该host-only scope。
- authoritative基础目录在没有任何受支持Agent route时仍为73项；只要root或某个child exact route有匹配
  service，共享目录增加`hosted_web_search`为74项。相应Code目录为74/75，Cowork为79/80；配置Knowledge
  时分别为76/77与81/82。斜线前后依次表示无/有hosted-search registration。
- Responses citation decoder 同时接受 flat 与 nested `url_citation`，保留安全 URL、title、可选
  content excerpt 和可选 start/end index，也接收 `web_search_call.action.sources` 中的 source URL；
  stream annotation、search-call item、message item 与 completed response 先按 URL 合并，再把最终
  完整 citation 交给 Chat；Agent Tool把同一结构化evidence放在bounded observation中，随后才附provider
  summary，不二次抓取URL。
- provider 只有返回受审结构化 code/type + `tools`/`tool_choice` parameter（或明确的结构化
  web-search unsupported code），且尚未接受任何有效 Responses payload 时，才会在同一路由重发
  一次普通 Chat。裸 404、自由文本和 partial payload 后失败不会触发重放。
- macOS 新生成的 Intatis 配置不再写出 `web_search_model`；读取与内存兼容字段仍保留，更新既有
  JSON 时也不会擅自删除用户原字段。无效 legacy 值不阻止普通 Chat，有效 legacy 值也不再把
  隐藏搜索模型追加到用户可见模型列表。
- 离线 provider/request、capability、fallback 与 ChatLoop citation tests覆盖Chat矩阵；
  `HostedWebSearchToolTests`、`ProviderHostedWebSearchToolServiceTests`、provider route tests与
  `CodexRuntimeTests`进一步覆盖strict schema、required/fail-closed、exact root/child service、
  read-only/unsupported拒绝、secret pre-dispatch、durable execution和authoritative publication。
- Cowork generation已提升到`codex-native-v6`，CLI使用新的v6 hosted-search session salt；旧generation或
  不同toolset要求新session，不做resume-time注入或静默迁移。
- 2026-09-02最终工作树的focused矩阵、完整SwiftPM suite、CLI product、macOS Debug与iOS Simulator
  Debug均退出0。全部search执行使用fake/loopback service，没有读取或请求OpenAI API key，也没有发送真实
  provider请求或产生计费。真实厂商smoke仍须用户显式opt in，不能从离线成功外推。

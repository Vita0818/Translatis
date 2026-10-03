# DO_NOT_BREAK

## 外部依赖优先与禁止功能兜底（Vitemis 强制规则）

本项目继承 `/Users/vita/Vitemis/docs/DEPENDENCY_POLICY.md`。本节是强制约束，不是建议。

- 当用户指定、仓库已经采用，或经许可证、provenance、安全与平台审查可采用的外部依赖提供同等能力时，必须直接集成该依赖的官方 API 或官方扩展点。
- 不得自行重写同等能力，不得新增替代 adapter、shim、compatibility layer、wrapper、proxy、facade、协议翻译层、parallel backend、preview backend、shadow implementation 或“先兜底、以后再换”的实现。
- 本地代码只允许保留官方 API 必需的最薄生命周期、类型、权限、配置和 bundle 接线；不得重新实现、解释、扩展或替代依赖的核心能力。
- exact 依赖因版本、构建、签名、许可证、平台、安全或官方 API 限制无法接入时，必须停止该能力、明确失败、报告 blocker 并请求用户决定；不得静默降级、切换 legacy/另一 provider/backend、使用 cache/mock/简化路径或继续交付不完整替代实现。
- 现有 fallback、adapter 或重复实现不构成先例，后续不得扩展。安全 fail-closed 与明确要求的旧数据解码/迁移不是功能兜底，但必须保持最窄范围，不能演化成备用产品实现。
- 只有用户针对 exact 依赖、exact 范围和退出条件作出的新明文决定才能例外。

文档状态：当前回归禁区
最近核对：2026-09-08
产品基线：v0.72（build 72）

Translatis 是活动宿主命名空间。App/CLI 必须使用 `IntatisHostApplication.configure(name: "Translatis")`
派生 `TRANSLATIS_*`、`.translatis`、`translatis.*` 和 `translatis:*`；旧 `.intatis*`/`INTATIS_*` 只
保留在共享安全边界中作为 legacy/deny floor。`Intatis*` Swift module/type、固定 Codex runtime 和
外部协议字段不随宿主名迁移。

## Codex Runtime 内核不变量

- Code、Cowork、CLI Code/Cowork 的 shipping turn 只能进入固定派生
  `codex app-server`；固定版本为 `codex-cli 0.145.0-intatis.4`，上游base仍是
  `rust-v0.145.0` exact commit。旧
  `AgentRuntime.code` / `AgentLoop` / `Orchestrator` 可暂留用于测试和手工源码回退，但生产入口必须
  保持 `unavailable`/不可达。任何 runtime 缺失、版本、schema、provider 或启动失败都必须明确停止，
  不能自动或“临时”调用旧内核。`translatis exec`与其旧`runExecCommand`也必须保持禁用，不能成为
  绕过新CLI入口的隐藏AgentLoop path。
- 不得新增 Chat Completions→Responses translator、provider shim、Codex protocol facade、备用
  scheduler、shadow thread、mock backend 或 cache recovery。provider 必须是 Intatis exact Responses
  route；custom `responsesEndpoint` 只有能表达为 baseURL + `/responses` 时可接入，否则 fail closed。
- App Server process 必须使用 session-owned isolated `CODEX_HOME`、
  `requires_openai_auth=false` 和 provider-specific child environment credential。不得读取/复制用户
  Codex/ChatGPT login，不得把 credential 放入 argv、JSON-RPC、stderr diagnostic、runtime mapping、
  model catalog、EventLog、session.json 或文档。Codex `shell_environment_policy` 必须保持
  `inherit=core`、`ignore_default_excludes=false`，并排除 `INTATIS_*`/`CODEX_HOME`；不得让shell
  tool继承 App Server provider token。0.145.0 `features.shell_snapshot`必须保持false，因为该feature
  在tool filter前捕获parent environment并会把token写入`CODEX_HOME/shell_snapshots`；不得为保留shell
  convenience重新开启。isolated home若已存在该目录必须在credential注入前fail closed并要求新session；
  host不得自动读取、清洗或删除可能已经含secret的旧snapshot。
- `CodexRuntimeExecutable.pinnedVersion`、`ThirdPartyNotices/OpenAICodexRuntime.md`、测试用真实握手和
  release binary inventory 必须一起升级；`pinnedDerivationID`还必须等于当前0003 patch SHA-256并由
  binary的`--intatis-derivation-id`确认。不得接受版本范围、`latest`、浮动 `main`、same-version/
  different-derivation、PATH 中任意 `codex` 或未验证的 bundle executable。
- 跨项目共享入口固定为SwiftPM package/product/module
  `Intatis` / `IntatisCodexRuntime` / `IntatisCodexRuntime`。
  `CodexRuntimeHostContract.publicAPIMajorVersion == 1`时，
  `docs/CODEX_RUNTIME_INTEGRATION.md`列出的route/configuration、session lifecycle、event/result、approval、
  executable与dynamic-tools公开名称、参数标签和既有语义不得删除、改名或增加无默认值的必填参数。
  additive overload/default/event允许继续加入；source-breaking变更必须先提升API major并写迁移说明。
  `CodexRuntimePublicContractTests`必须保持plain public imports，禁止用`@testable`掩盖外部消费者不可见的
  internal声明。该稳定合同不得扩成Codex协议facade、第二runtime或provider/backend adapter。
- 下游宿主产品命名必须只来自一个`IntatisHostApplicationIdentity`。App/CLI必须在首次使用任何共享
  storage/provider/tool/MCP/Knowledge/SharedUI/Codex对象前调用一次
  `IntatisHostApplication.configure(name:)`；第一次identity读取后不得再安装不同名称。不得在各下游
  复制字符串替换表，也不得让Application Support、config/auth、env、defaults、Keychain、diagnostics、
  temporary、workspace metadata、Knowledge publication、registry/policy/toolset、MCP/provider adapter或
  authorization-sidecar退回硬编码Intatis新写值。当前Translatis identity的全部派生值必须与既有canonical
  名称逐字相等。下游新identity不得自动读取、迁移、合并或删除Intatis顶层数据；legacy Intatis敏感路径
  与`.intatis-rag-*`必须继续保留在deny/secret-recognition floor。Swift module/type、fixed
  `codex-cli 0.145.0-intatis.4`、`intatis_responses_provider`、`intatis_agent_workspaces`和
  `--intatis-derivation-id`是共享实现/external-runtime协议常量，不得被host name改写。
- selected model/variant options不得静默丢失。当前解释层只允许空options或可唯一归一化为
  `reasoning.effort`的minimal/low/medium/high/xhigh/max/ultra；exact OpenRouter adapter的
  `options.provider`是明确例外，作为完整opaque object经`intatis_responses_provider`进入最终
  `ResponsesApiRequest.provider`。不得枚举、解释、重命名或丢弃其children，也不得让它覆盖host-owned
  request字段。跨进程前必须递归拒绝secret/auth/header/query/URL/endpoint material并保持结构资源边界。
  其他top-level option仍在secret resolve/network前fail closed；不得新增控制header、generic whole-body
  `extra_body`、proxy或协议adapter。显式OpenRouter marker下只能省略exact route未声明的optional
  OpenAI controls；必须保持`require_parameters`和完整provider routing，禁止按URL/name猜adapter、放宽
  fallback或切换provider。host须用Codex官方config关闭未配置的web search，并以显式
  `features.multi_agent_v2.flat_tools=true`把原生V2协作控制呈现为普通top-level functions；普通business
  functions保持。不得根据provider名称或URL启停、翻译或改写这些工具。上游有官方等价
  provider-body/request-shape extension时应删除
  对应补丁。
- `codex-runtime/` 必须位于 exact Intatis session directory，目录 owner-only；`runtime.json` 与
  `models.json` 必须使用 `DurableOwnerOnlyFile` 的 no-follow/0600/atomic/durability边界。
  `runtime.lock`必须是owner-only/no-follow/single-link并持有nonblocking cross-process `flock`整个process
  生命周期；同session第二runtime明确拒绝。`runtime.json` schema/version/derivation/mode/workspace/thread ID/
  dynamic toolset不一致、损坏或unsafe时fail closed。0.145.0普通thread在首个turn前没有可resume
  rollout，因此普通消息只能在首个`turn/start`接受后写mapping；Goal-first路径必须在official
  `thread/goal/set`成功且返回的Goal ThreadID一致后写同一mapping。只start后shutdown不得留下stale ThreadID。
- 当前阶段不做runtime/thread/toolset mapping迁移。`.3`及更早runtime、缺失或不同dynamic toolset、
  mode/workspace不一致、resume失败或ID漂移一律要求新建session，不得改写旧record、resume-time注入
  dynamicTools或新建空thread。
- Codex rollout 是模型上下文权威，Intatis EventLog 是产品/UI/audit 投影权威；两者必须通过
  required `runtime.json` exact ThreadID join。EventLog 已有 legacy agent history而 mapping 缺失时，
  不得静默新建空 Codex thread、猜测历史、注入 legacy tool transcript 或宣称迁移成功；第一版只允许
  新建 session。
- shipping macOS fresh Cowork只能在brand-new empty EventLog上，以一个锁内批次按settings、`@main`
  workspace lease、`@main` business capability lease、`@main` identity连续写四个事件；四项必须绑定同一
  canonical primary workspace、exact root profile/binding与相互一致的metadata。App Server、native MCP与
  business tool host必须消费该durable root lease pair，不得再构造临时root authority绕过EventLog。
  bootstrap不调用provider、不创建legacy `@permission-reviewer`。任何非空、partial、ambiguous、detached、
  path/root-identity或lease-shape不匹配的session都要求新建，不能原地补事件或创建空thread；root workspace/
  access变化必须在一个session-state事务内revoke旧pair、grant新pair并更新agent metadata。本文后部legacy
  AgentKernel的七事件main+reviewer条目不适用于shipping Codex入口。
- owner-only `models.json` 只能使用 0.145.0 的 exact schema和官方 `model_catalog_json` extension；
  `auto_review_model_override` 必须明确绑定 selected Responses model，不能隐式请求 OpenAI 默认 reviewer
  model。不得把此配置扩写成 Intatis reviewer implementation。
- 第一方文档/浏览器/图片/hosted-search工具只能使用pinned App Server official experimental
  `thread/start.dynamicTools`→`item/tool/call`→`DynamicToolCallResponse`。目录必须来自既有
  `ToolRegistry.standard.v5` exact registration并复用WorkspaceLease、PermissionEngine与durable
  execution ticket；不得另建schema/executor、改走MCP、用shell/Python重做、调用legacy
  AgentLoop/Orchestrator或在失败后切backend。dynamicTools只能随fresh thread/start注册，resume不得
  重发。agent management仍归Codex native collaboration，不能包装旧Orchestrator成为business tool。
- 当前shipping Codex authoritative无搜索基础catalog必须包含71个文档/浏览器business tools与两个exact图片
  tools，共73项；至少一个root/child exact route存在匹配hosted-search service时，共享catalog条件式增加
  strict `hosted_web_search`为74项；`rename_session`、Cowork WorkTask与Knowledge按host能力继续追加。
  `generate_image`与
  `edit_image`必须继续直接注入既有`ImageGenerationToolService`，使用同名exact capability，只向
  read-write root/verified child授权；不得恢复aggregate `.generateMedia`、legacy AgentLoop、另一provider/
  model或替代backend。`hosted_web_search`必须继续复用既有`HostedWebSearchTool`与
  `ProviderHostedWebSearchToolService`，按同一次exact route resolution冻结的root/显式child-role service
  scope选择，不得让模型通过arguments、JSON-RPC或caller-supplied identity选择route。read-only、缺service、
  unknown role或无法证明parent chain的caller必须在permission/provider dispatch前拒绝；专用请求固定
  `tool_choice:required`和unsupported fail-closed。不得启用Codex默认web search，也不得ordinary-model、
  browser/MCP/shell、legacy Loop、另一provider/model/backend fallback。当前Cowork generation必须保持
  `codex-native-v6`且CLI使用v6 hosted-search session identity；旧toolset/session不得静默迁移。
- Cowork的每一种MultiAgent V2 fork都必须继承父turn已经注册的同一dynamic business-tool surface；
  子代理首次调用若早于roster通知，host只能通过official `thread/read`逐级证明其parent chain后再执行。
  未验证thread、跨root thread、未知role/workspace、cwd不等于host批准preset或找不到唯一
  WorkspaceLease必须fail closed，不能转交`@main`。permission记忆键必须包含真实来源AgentID。
- persisted child恢复只能使用official relationship-filtered `thread/list`与逐级`thread/read`父链。按关系
  查询必须保留只有inter-agent input、preview为空的spawned child，普通global list过滤不变。App Server
  descendant `sessionId`是child自己的rollout session，绝不能作为root membership；host projection只能在
  verified parent chain到达当前root后绑定root。child `thread/resume`必须重带approved full provider/model/
  workspace/sandbox config；roleless nested child按verified parent继承，unknown role不得回退root。root
  resume确认前重放的child通知只能有界缓存，确认与roster恢复后再按child重放，不能提前授权。
- 子代理只能选择host写入isolated `CODEX_HOME`的完整`agent_type`和同名`workspace` preset；preset
  冻结model/provider/credential reference/reasoning/request options与canonical cwd/workspace roots，模型
  不得提交raw endpoint、credential、model override或path。显式role和workspace必须同名；read-only
  preset不能被child提升为workspace-write；resume/reload必须保持原完整preset，不得漂回root配置。
- `thread/subagent/message`只允许当前root向自己的verified live descendant投递native AgentControl mailbox
  message。它不得调用root模型、provider、旧MessageBus/Orchestrator，也不得用child `turn/start`、
  `turn/steer`或私有rollout注入替代。空消息、超限消息、root自身、跨root目标和缺正式AgentPath均拒绝。
  模型通过V2 tool产生的task/follow-up/message必须使用普通mailbox text；不得恢复第三方Responses route
  无法解开的OpenAI内部encrypted-content，也不得因此增加provider adapter。
- WorkTask shipping接线只允许`CodexWorkTaskController`保存卡片DAG/revision/result/evidence及
  `task_link_agent`的显式verified-child关联；这些工具不得创建、调度、等待、传话、恢复或终止agent。
  Goal卡只读写official thread Goal，不得恢复旧Goal续跑器或从child/WorkTask终态伪造Goal完成。Cowork
  冷启动若Goal仍active，必须先official get/set paused成功并核对同一ThreadID，再thread/resume；只有
  显式Resume才重新active，不得让普通App reopen隐式产生provider continuation。
- official `item/tool/requestUserInput`只能经
  `CodexRuntimeConfiguration.requestUserInputHandler`接入；不得新增Plan/Default产品模式、同名dynamic tool、
  普通文本答案解析或legacy Intatis MCP/Knowledge/agent fallback。handler非nil才可在现有Code/Cowork流启用
  `default_mode_request_user_input`，nil必须显式关闭；macOS Code/Cowork production roots提供handler，CLI保持
  nil。request/response须绑定exact RequestID/thread/turn/item与verified child AgentID；一个request含1–3题、
  每题2–3个互斥option且exact一个answer；Other只可作为自由文本替代项，不得扩成multi-select或附加note。
  secret、secret-bearing文本、坏ID/answer mapping、跨root请求必须在host callback/回传前fail closed。
  `serverRequest/resolved`、turn terminal、child identity变化、shutdown/process exit必须取消pending host task；
  问题/答案原文不得进入EventLog或diagnostic。SharedUI/CoworkUI只可持有request-local纯presentation与
  submission action；不得取得runtime/session ownership。UI必须使用原生SwiftUI control并由`⌘↩`提交，
  保留透明底、system-separator描边的bounded panel，但不得套Material/Glass/模糊。互斥选项必须使用native
  single-selection `List`的编号整行与系统选中高亮，不得使用radio/checkbox或自绘选中控件；多题一次只显示
  一题并提供题号/前后导航。非空option description必须在标题下一行以secondary小字显示，不得增加
  info图标、tooltip-only入口、模式、设置开关或解释性冗余。
  handler启用位必须进入persisted toolset identity，旧session不得在
  resume时注入。其他未支持/未接线的server request必须返回JSON-RPC error与
  typed failure，不得用legacy实现补齐外部MCP/plugin。
  child roster/history、WorkTask card与thread Goal已经有正式shipping接线，不得再添加第二条实现。
- Code/Cowork EventLog 只可镜像 bounded、exact-token-redacted presentation facts。credential、raw
  environment、raw stdin、未界定 command output、approval transient或整个 App Server payload 不得
  落盘。completed assistant item 是正文权威，delta 只能增量展示。官方agent-message `phase`必须
  原值保留：`commentary`为小号灰色中间文本、`final_answer`为正常回答、缺失为legacy样式；不得从文案
  或tool lifecycle猜phase。exact wire method和允许的原始scalar必须继续作为durable raw projection与
  backend trace保留，但默认macOS Code/Cowork UI必须通过typed semantic reducer消费，不得把协议方法名
  当用户文案。归约只能依赖method/itemType/status/phase/turnID/itemID等结构事实，不得从正文或相邻事件
  猜状态；started/delta/completed只能按exact identity归并。usage、Goal、permission、roster和message
  lifecycle应更新其专用组件而非复制一行。unknown future method必须用通用自然语言可见并保留技术详情，
  不能静默drop、伪装成已知动作或扩大payload安全allowlist。完整payload/output/args/path仍不得为了语义
  展示突破EventLog边界；自然语言/localization不得写回EventLog。backend trace开关必须恢复原始method/
  scalar行。Code/Cowork不得恢复从文本猜测的合成Thinking计时行。
- App Server `error.willRetry`是required authoritative retry fact：`true`不得结算turn/submission失败、不得
  追加通用runtime error或由host再次发送whole turn；只可更新同一临时Reconnecting presentation。
  `false`才可作为terminal diagnostic，submission终态仍须跟随official turn lifecycle。shipping Code与
  Cowork root必须在任何Runtime启动/发网前先durable append同一batch的`user_message + queued`，Runtime
  ready后才写`running`；pre-runtime失败也必须settle该已接受submission。显式Retry必须创建fresh可见
  continuation submission，不重放旧附件/one-shot context、不覆盖旧失败。process/protocol terminal必须让
  response-accepted但尚未来得及登记的turn waiter也收到失败，不能永久悬挂。
- 固定App Server experimental server-request/notification inventory必须有exact schema drift test。新增method
  未审计前不得静默drop或随意支持；需要新UI/authority的request必须明确fail closed。`currentTime/read`只
  返回whole Unix seconds；implicit `model/rerouted`必须因exact binding变化fail closed。session-level
  notification可只保留bounded method projection，账户/搜索/平台/高频output等非transcript事件可在默认
  semantic UI消费，但backend raw trace必须仍能恢复，不能靠“不显示”停止接收或删除事实；唯一
  agent-message delta必须进入typed message path而非重复raw row，也不能因此丢正文。
- 新Codex统计只能来自固定App Server schema的
  `thread/tokenUsage/updated.tokenUsage.last`与`turn/completed.turn.durationMs`，以additive
  `responses_usage`保存。六项token字段必须原名/原语义投影；尤其Input就是完整`inputTokens`，不得减
  Cache Hit。只可绑定exact active turn和当前runtime thread；resume重放不得绑定新回答。同turn多次
  通知只保留最后一个官方`last`快照，不得累计`last`或对thread累计`total`做差分，也不得改用
  internal-only `rawResponse/completed`作为shipping依赖/fallback。不得从文本、相邻事件、旧
  `turn_stats`、catalog context常量或host计时猜数据。缺失事件不得伪造零值，malformed/负数必须fail
  closed。上下文窗口未接通前Code/Cowork不得恢复旧Context或Last Turn占位；旧`turn_stats`仅保留
  Chat/iOS Chat/历史解码兼容。
- cancel/shutdown 必须发送 exact `{threadId, turnId}` interrupt（若 active），关闭 stdin、终结 process
  与 event/read tasks；必须观察到process真实退出后才可释放`runtime.lock`，TERM超时后须KILL，KILL后仍
  无法证明退出时继续持锁并后台retire，不得允许第二owner进入同一`CODEX_HOME`。窗口切换/Command-W
  不得隐式 stop。provider/model
  rebind 只能在无 active turn 时重启 process并 resume同一 thread。
- iOS/Chat target 不得链接 `IntatisCodexRuntime`、Process、shell 或 workspace agent surface。
- 当前源码不把 Codex binary 放入 App bundle。未完成 exact Cargo lock license closure、arm64+x86_64
  build/hash、nested Developer ID signing、Hardened Runtime/notarization/stapling/Gatekeeper 与 clean-user
  smoke 前，不得生成或宣称独立可分发的 Codex-backed macOS release。

本文后续涉及 Intatis AgentLoop/PermissionEngine/Orchestrator 的禁区仍约束 legacy 源码与兼容测试；
它们不得被误读为新 shipping path 必须在 Codex 外再包一层同等功能。

## Cowork纯UI跨项目不变量

- `IntatisCoworkUI`只拥有完整右侧presentation与公开state/bindings/actions合同；不得拥有或引用
  `CoworkViewModel`、session/runtime lifecycle、provider registry、workspace/bookmark、MCP、permission
  engine或dynamic tools。
- UI target不得直接依赖`IntatisCodexRuntime`、`IntatisAgentKernel`、`IntatisCowork`、`IntatisTools`、
  `IntatisPermission`或`IntatisMCP`。新增上述任一依赖均视为把UI复用错误升级为runtime迁移。
- TranslatisMac的`CoworkViewModel.swift`、`CoworkProjectSettings.swift`、`WorkspaceAccess`和
  `AppSessionRuntimeManager`必须继续留在App owner；其他宿主也必须保留自己的session root、runtime、
  per-session toolset和shutdown lifecycle。
- `IntatisCoworkContentView`不得在action缺失或失败时创建替代session、注册替代工具、执行mock/cache路径或
  猜测permission结果。UI显示不构成授权事实。
- TranslatisMac与其他宿主只可建立薄state/action映射；不得复制右侧SwiftUI、扩展第二套Cowork presentation
  state machine，或直接挂`CoworkShell`再自制模型菜单冒充完整UI接入。
- `IntatisCoworkUIContract.publicAPIMajorVersion == 1`期间不得删除现有公开state/action语义或新增无默认值的
  必填宿主authority；breaking变更必须提升major并提供迁移说明。
- `TranslatisiOS`不得链接`IntatisCoworkUI`。

## macOS 分发不变量

- macOS 唯一发行 App 是 Developer ID/direct-distribution `TranslatisMac`；不得把
  Mac App Store App Sandbox 恢复为产品约束、功能裁剪理由、依赖准入条件或
  默认测试/release gate。精确合同见 `docs/MACOS_DISTRIBUTION.md`。
- 已删除的 `TranslatisMacAppStore` target/scheme、`TRANSLATIS_MAC_APP_STORE` 编译条件和
  App Store entitlements 不得重新引入；`.macAppStore` 仅可维持共享协议解码/
  隔离测试兼容，不能演化成第二个产品图。
- “不考虑 App Store 沙箱”不允许弱化 PermissionEngine、CapabilityLease、
  WorkspaceLease、PathConfinement、SecretScanner、durable tool execution、
  managed-terminal Seatbelt/default-network-deny、Hardened Runtime、签名/
  公证或 iOS target 边界。
- 面向人工运行的发行脚本不得用 JSON/plist 输出隐藏 `notarytool submit` 的上传进度；
  必须在上传完成后立即显示并持久化 submission ID，再进入有界等待。
- `.translatis/release-recovery/<run>/state.plist` 是 owner-only 的本地恢复状态（schema
  v1）。恢复根目录与 run 目录必须为 `0700`，状态文件必须为 `0600` 并原子更新；
  resume 只接受 canonical 仓库恢复根目录下、非 symlink、属于当前 UID 的状态与 App。
- App/DMG submission ID 必须 first-write/reuse。超时、`In Progress`、中断、网络失败
  或 `Invalid` 都必须保留恢复状态且不得自动重复提交；只有最终 ZIP、DMG 与 manifest
  全部成功落盘后才可清理恢复目录。
- 人工可运行、安装或交给用户的macOS Debug预览必须以`ENABLE_DEBUG_DYLIB=NO`构建；最终
  `Contents/MacOS`不得含`TranslatisMac.debug.dylib`或`__preview.dylib`，主程序也不得通过`LC_LOAD_DYLIB`
  引用它们。不得用`codesign --deep --strict`静态通过替代真实启动验证，也不得为兼容默认Xcode Debug
  launcher而开启`disable-library-validation`。预览必须在最终交付路径实际启动并保持运行后才可交付。

## macOS 文件夹项目不变量

- 文件夹项目只是 `{ProjectID, exact SessionKind, canonical folder path, same-kind SessionID[]}` 的
  模式内跨 session 组织层。每个项目必须固定一个 kind，引用必须同 kind；跨模式关联必须 fail closed。
  相同 path 可在 Chat/Code/Cowork 分别登记，但三者不得共享项目选择、session list 或新建入口。
  不得把它扩写成新的 EventLog、session runtime、Goal、WorkTask、Agent owner、workspace
  lease、共享模型 history、知识库、索引或配置继承层；Chat/Code/Cowork 继续使用原执行链。
- `projects-v1.plist` 必须保持 schema-v1 binary、owner-only `0600`、no-follow、single-link、稳定
  跨进程 lock、原子替换和读回验证；未知 schema、损坏、超限、unsafe inode 或冲突 ProjectID/path/
  conversation reference 必须 fail closed，不能覆盖旧文件、退化到 UserDefaults 或从 Recent/mtime
  猜测 membership。旧 global mixed-project 草稿只可按 kind 确定性拆分，不能继续作为跨模式项目运行。
- 项目目录不得保存 security-scoped bookmark。添加项目时选择器只证明并保存 canonical path；
  创建 Code/Cowork conversation 必须再次由用户确认 exact 文件夹，并继续把 bookmark 只写入该
  session 的 `workspace-access.plist`。Chat 不得因项目 membership 获得路径、文件、tool 或 workspace
  能力，项目 path 也不得进入 provider prompt/EventLog。
- project membership 不移动、不复制、不重命名 session 目录，也不改写 session EventLog、
  `session.json`、artifacts、SessionID 或 runtime key。一个 conversation 在自己的模式内最多属于一个
  项目；同一 `{kind, path}` 重复添加必须幂等保留原 ProjectID 和会话引用。
- UI 必须把项目放在当前模式的 session browser 内，使用可展开/收起的单行文件夹；不得恢复固定
  Projects 高度、独立项目主页或跨模式 session-type 菜单。收起项目不得保留子 session 占位高度；
  归入项目的 session 只显示在该文件夹，其他当前模式 session 显示在 `Unfiled`，二者共享一个滚动面。
- 移除项目只能删除项目分组记录；不得删除用户文件夹、任何 session、EventLog 或 artifact，也不得
  stop 不相关 runtime。删除 session 后项目引用清理失败只能留下不可见的 stale reference，不能回滚
  或伪造 session 删除结果；UI 只显示当前 SessionHistory 能解析的引用。
- 第一版只从当前模式的项目入口创建同模式 conversation。未经新的明确设计，不得自动把同路径
  session 归组、把既有 Unfiled 会话迁入、跨会话共享上下文，或从文件夹相同推导权限与所有权。

## OKF / RAG knowledge bundle 不变量

- 第一版知识库继续只有既有 OKF/Profile/Validator/immutable-store core 与现有 Code/Cowork Agent
  工作流；产品只增加 closed-schema `build_knowledge` 和 path-aware `search_knowledge` 两个 model-facing
  ToolRegistration，不新增独立 Knowledge Agent/runtime/UI。两工具不得绕过 ToolRegistry、
  CapabilityLease、PermissionEngine、durable execution 或 EventLog。
- 两个 path-aware Knowledge 工具必须由宿主在 permission/execution 前做 closed-schema 与语义联合校验；含可选
  CAS/limit 字段时不得向 OpenAI/OpenRouter 宣告 provider `strict: true`。snapshot-bound
  `search_knowledge` 若声明 strict，则 `limit` 必须出现在 `required` 并用 integer-or-null 保留宿主默认值；
  当前合同须使用 input schema v2，旧 v1 resource 不得原地改写。所有 strict object schema 必须满足
  `required == properties.keys` 与 `additionalProperties:false`。Chat Completions function tool wire 不得携带 Responses-only
  `defer_loading` / `output_schema`；Responses wire 也不得因此丢失自己的 metadata。关闭 provider strict
  不得被解释为允许额外字段或跳过宿主校验。
- `ThirdPartyStandards/OpenKnowledgeFormat/0.2/` 的规范、许可证、upstream identity 和
  `SHA256SUMS` 必须一起保持 byte-exact；`.translatis-rag/` profile、chunks、index、checksums、
  receipt 和 store pointer 都是 Intatis 派生状态，不得冒充 OKF 标准或知识真值。
- legacy `timestamp` / `# Citations` 只是 reader fallback；新 build 不得原样 publish legacy
  bytes，必须由 host-owned writer 生成 canonical v0.2。任意层非保留 `.md` 均为
  concept，任意层 `index.md` / `log.md` 均必须执行 reserved shape 验证。
- model-facing source ID 必须是 portable bounded identity；build writer 由 canonical resource 生成
  opaque ID。resource 只能是可携带 URI、bundle-local immutable path 或规范化 scope
  identity；source ID/resource/evidence/diagnostic 不得包含私有绝对路径、credential 或编码绕过。
- 解析、清洗、来源标注、deterministic chunk、全库 embedding/index build 必须发生在独立
  build/publish 流程。普通 query 不得偷偷解析全库、重建索引、下载模型、换 backend、访问网络
  或静默扫描 retained snapshot fallback。
- `store_path` 可以是 workspace 内路径或用户自然语言点名的外部绝对目录，但路径文本不授予权限。
  workspace 内必须匹配现有 WorkspaceLease；workspace 外必须由宿主在 permission settlement 后签发
  exact `KnowledgeLease`，绑定 session/agent/task/root identity/access/operation/revision，并且不得扩展
  普通文件、patch、Git 或 terminal authority。model-facing 参数不得包含 provider/model/backend、
  credential、bookmark、ACL 或任意 capability 数据。
- macOS raw security-scoped bookmark 只能进入 session-owned `knowledge-access.plist`，必须 binary、
  owner-only、no-follow、read-merge-atomic-write；其 sidecar lock 也必须验证 current owner、普通文件、
  single-link 后才可收窄为 `0600` 并加锁；不得进入 EventLog、session.json、tool result 或安全
  durable projection。restore、stale refresh、revoke、cancel 和 shutdown 必须保持 scope acquire/release
  配对；父目录替代、symlink/root replacement、过宽或敏感 root 均 fail closed。
- shipping Knowledge 必须同时解析 canonical `embedding_model` 与 `reranker_model`。build document
  embedding 与 search query embedding 必须来自 compatible configured route；snapshot 必须冻结 complete
  embedding identity 和 exact required reranker binding。每次成功 search 都必须实际调用 semantic
  reranker 且 `rerank_applied=true`；不得退回 Chat model、Apple NaturalLanguage、cosine、RRF-only 或
  相似名称 route 冒充完成。
- Profile 的 embedding identity、normalization/similarity、chunker、component format、retrieval
  policy、reranker、bundle/chunk/component/composite revision 是单一 compatibility contract。任一
  语义字段变化必须 fail closed 或全量重建；不能按相似名称、维度或可用性猜 fallback。L2/cosine
  route 必须拒绝 zero/non-finite/non-unit 存量向量，并对 query 执行冻结的 normalization。
- exact-slice `chunks.jsonl` 不得把运行时 wall clock 带入 canonical bytes/manifest
  identity；相同 OKF bytes 与 chunk config 跨时钟重建必须 bit-stable。
- publish 只能从 bounded staging 经同一 Validator、checksum completeness 和 content-seal 复核后
  原子切换 current pointer。reader 固定 exact snapshot；旧 reader drain 前不得删除。A/B 只能由
  host 明确 admission exact snapshot，不能从 retained 集合自动选择。urgent purge 必须先 revoke
  admission、cancel/drain、持久清除 current pointer/receipt，再删已 drain snapshot；不得把普通 GC
  写成紧急清除。
- shipping 发布区固定为 `.translatis-rag-store.json`、`.translatis-rag-snapshots/` 与
  `.translatis-rag-host/`。它们必须留在 WorkspaceLease/managed terminal 的不可移除、大小写无关 deny
  floor；普通 file/patch/Git/process/terminal 不得通过 read-write workspace authority 修改、移动或删除
  这些内容。只有 Knowledge writer/Validator 内部最小 projection 可以解除这三个 exact managed
  pattern，且不能扩大到 credential deny floor 或其它路径。
- legacy `snapshots/` 与 current `.translatis-rag-snapshots/` 同时存在必须 fail closed；只读 open 不得
  创建 coordination/snapshot/staging 目录，也不得迁移旧布局。迁移只能由 read-write build/update 在
  exact store lock 内原子 rename 并复核 identity。pointer publish 或 layout migration 在 rename 后无法
  证明 parent directory durability 时必须返回 non-retryable `commitUncertain`，不得自动重试或宣称
  未提交。
- YAML alias/custom tag、unsafe mode/owner/link/root identity 和路径逃逸是 host safety refusal，不能
  被误标成普通 OKF conformance 错误。source locator 只可由 exact executable adapter
  identity/version 重放 Validator 已验证的 immutable source bytes；未注册 kind、source revision 或
  registry digest 漂移都必须拒绝，不能从 URL、concept range 或正文猜 locator。
- `search_knowledge` evidence 始终是 untrusted tool-role data。只有本轮成功结果登记的 stable
  evidence ID 可引用；同一 ID 只有 exact binding 完全一致时才可幂等重复。final answer 前必须异步
  重开 exact snapshot 并复核 handle/revisions/hash/URI/concept/source-locator；fabricated、old-turn、
  cross-KB、purged 或漂移的引用必须阻止 final，而不是只做字符串 membership 检查。当前 turn 一旦有
  成功 Knowledge evidence，最终回答必须至少包含一个本轮 exact `[[evidence:<id>]]` 引用；无引用 final
  必须被 AgentLoop 拒绝并要求模型修正。
- SecretScanner 对 API key 的识别必须要求 credential-shaped 边界与足够长度；不得用裸 `sk-` 子串
  把 `ask-user` 等普通文本误判为 secret，也不得因此绕过真实 credential 的 fail-before-egress。
- snapshot-bound dynamic registration 不得丢失 instance-owned permission intent/preview 或
  local/network semantics。local-only `search_knowledge` 必须复用现有只读默认放行路径，不创建
  permission request 或调用 reviewer，同时保留 PermissionEngine、authorization correlation 和 durable
  lifecycle；network-backed instance 仍按网络 effect 审查。
- `KnowledgeBundleBuildService` 只复核外层 resolved authorization，不是独立 caller。正式
  `build_knowledge` 必须持续产生真实 permission/authorization/prepared/result/settled correlation；
  不得伪造 authorization，也不得让 service/raw terminal 代替执行生命周期。更新现有 store 必须在
  writer lock 内同时 CAS exact `expected_store_id` 与 `expected_snapshot_id`。其 descriptor 主副作用
  必须保持 `.write`，同时以 `risksNetwork` 与 permission intent 保留 embedding 外发和 model-cost 风险；
  不得因它需要联网而把 durable publish 错标成纯 `.network`。
- Knowledge provider usage 只能记录供应商真实返回且经过有限/非负校验的 token/billable units；未报告
  必须保持 unknown/unreported，不得伪造零用量，也不得脱离明确版本化价目表推算或持久化虚构金额。
- `knowledge://` 是内部 provenance URI，不得交给 hosted web citation renderer 当 HTTP(S) 链接。
  Validator/grounding 只能证明 bundle 内机械一致性，不能声称证明现实世界真伪或自然语言蕴含。
- Code、Cowork exact `@main`、host明确授予Knowledge capability的verified Codex child和CLI只在两个
  configured role均存在时组合Knowledge augmenter；缺失时registration必须完全不可见并给出actionable
  status。每个Codex child必须用自己的AgentID、exact workspace/access与独立augmentation lease，read-only
  最多search、read-write才可build；model参数、共享dynamic surface或parent root identity都不能扩大grant。
  legacy ordinary Cowork worker/mailbox若无explicit delegated knowledge grant、permission
  reviewer、GoalVerifier、Chat 的无工具 `ChatLoop` 与 iOS 依赖图不得继承 Knowledge tools。没有
  Knowledge 管理 UI、CLI mount command、Chat/iOS RAG 或 MCP Server，不能从 model-driven 工具面外推。
- augmentation close/shutdown 必须 cancel 并等待 active build/search/mount/provider/scope drain；false/
  timeout 是可见的 runtime failure，不能被 Code/Cowork/CLI 当成成功 completion。重复 close 仍须
  single-flight/idempotent，且 closed handle 不得恢复 admission。
- snapshot purge 不等于安全擦除 APFS/SSD/backup，也不会倒写 append-only EventLog 中已经提交的
  bounded evidence。任何跨 store/session 强删除承诺必须另行设计 encrypted-artifact indirection、
  retention 与 migration，不能由当前 purge API 外推。
- urgent purge 的 current-pointer removal 是持久 admission boundary，exact receipt tombstone 防止旧
  receipt 并发复活；pointer、receipt、snapshot physical delete 不是单个 crash-atomic transaction。
  crash-left orphan/receipt metadata 必须 fail closed 并由 host reconciliation 清理，不能据此恢复查询。

## 诊断导出不变量

- 诊断导出只能由用户在 macOS 设置页明确触发并写入用户选择的本地位置；在另行完成
  产品设计、告知同意、服务端与安全评审前，不得新增自动或远程上传。
- 不得把 canonical `events.jsonl` 原样复制进导出包，也不得导出用户/模型正文、工具
  参数或结果、provider endpoint/URL、credential/token、配置/auth 文件、workspace、
  artifact、浏览器数据、bookmark bytes 或完整私人路径。新增事件类型默认不能靠未知
  字段穿透；只允许结构化 allowlist 的诊断字段。
- session 与系统诊断源必须 bounded、no-follow、current-UID/regular/single-link；暂存
  成员和最终 ZIP 必须 owner-only。任何 symlink/hardlink/不安全权限、超时、取消、
  字节或数量上限都必须 fail closed 或显式标为 truncated，不能静默输出不受限数据。
- 单项采集失败不得伪造成完整成功；必须在 manifest/error ledger 中保留 sanitized
  原因，同时尽量保存其他已成功来源。只有锁文件而没有 `events.jsonl` 的空 session
  应安静跳过，不能制造 warning。
- 导出器是 EventLog 的只读投影消费者，不得改变 JSONL schema、Envelope、`seq`
  单调性、session writer lease、ArtifactStore 索引或任何 runtime authorization 状态。

## Replacement-history compaction 不变量

- `model_history_item` 与 `model_history_compacted` 是 provider-facing canonical
  history，不是 UI transcript、task result 或 bounded audit preview。
  Conversation/Code/Cowork UI projection 必须继续对二者 no-op；不得从显示层
  文本反推新式 replacement history。
- checkpoint 必须保存完整 replacement items、非空 summary、单调 window number
  和合法 UUIDv7 first/previous/current lineage。新写入不得使用 nil
  replacement；恢复必须从最新有效 checkpoint 为基底，只正向重放存活尾部，
  不得把 checkpoint 前已被替换的 raw history 再拼回来。
- Protocol 必须在 encode/decode 时拒绝未知 schema、空 replacement、非法 v1/v2 item
  shape/classification、坏图片 descriptor、坏 summary 与非 canonical UUIDv7；EventLog 必须在
  per-agent CAS 后、WAL/JSONL 前验证整条连续 lineage，并拒绝 window ID
  重用。`model_history_compacted` 不得经 generic append 绕过专用验证入口。
  projector 仍须独立证明 accepted user provenance、contextual placement 与
  checkpoint coverage，不能把 durable shape 校验误当成 provenance 证明。
- 含图 direct history 必须使用 schema v2 与无 bytes/path 的
  `ModelHistoryImageReference`；projected image sidecar 必须与 messages 等长并核对 user role
  或 exact tool call ID。blob 只能由 exact-session bounded resolver 在 dispatch 前读取，重新验证
  MIME/size/hash/完整解码与 route capability；projector/provider adapter 不得遍历 session 文件，
  也不得把无法物化的媒体静默降为 text-only。`AgentLoop.send`不得接受调用方构造的provider-ready
  `images`/data URL；stable与task-scoped current都只能从durable accepted attachment IDs解析，不能
  恢复只在首轮有效的图片快路。首版图片route必须同时满足effective request adapter为`.openAI`且
  exact model声明`.visionInput`；user/FCO capability分别检查，compatible、legacy、OpenRouter及
  unknown adapter默认false，不得从URL/provider ID/model slug猜测。图片需要Responses transport不等于
  请求使用tool search；tool-search capability gate不得被复用为图片gate。
- 含图function output只允许在同一append batch中与同turn/call的唯一`tool_result`及同
  `{callID, agent, taskID, attempt}`的唯一`tool_execution_settled`精确绑定；只匹配call ID、邻近事件或
  settlement数量都不够。stable Code的prepare/settle attempt必须与model-history规范化attempt 1一致。
- EventLog 是唯一权威。压缩必须在 complete-known replay 和同一 agent
  model-history CAS 下先持久化，再替换 live request history；append、WAL、CAS
  或 decode 失败时不得继续使用未落盘 replacement，也不得伪造普通完成。
  unknown future event、seq gap、冲突 item/checkpoint、坏 provenance 或 lineage
  必须 fail closed。
- Code stable-conversation direct item 必须保持 `taskID == nil` 并有稳定
  SubmissionID；
  Cowork stable `@main` 必须保持 exact root task/submission/assignee/attempt
  绑定。task-scoped worker、permission reviewer、GoalVerifier 与控制面 agent
  不得读取、记录或压缩主线程历史。
- user-role item 的 `real_user` / `contextual` / `compaction_summary` 分类是协议
  事实。只有真实用户输入可进入最多 20k 的原文保留区；该值是上限，必须在窗口
  较小时动态缩小。Skill body、developer/task
  context、旧 summary、assistant 与 tool 内容不得通过文本形状猜成真实用户。
  summary 必须是 replacement 最后一项，UTF-8 边界截断必须保留明确标记。
- pre-turn 必须在当前 user/context 入历史前检查；mid-turn 只能在仍需下一次
  采样时运行。压缩调用必须使用同一 exact provider/model、`tools=[]`，usage
  计入当前 Turn，但不消耗工具循环次数；取消、超限、malformed、provider 或
  persistence failure 不得被包装成成功。pre-turn 必须冻结首个普通请求的
  request-owned dynamic tool snapshot；工具执行后仍需采样时，必须先冻结下一
  普通请求的 snapshot，并让阈值判断、95% replacement postcondition 与对应
  dispatch 精确复用同一份 provider specs。snapshot 解析失败必须在下一
  provider call/checkpoint 前 fail closed，不得回退 base registry。
- 自动阈值优先来自 exact route 的显式 context metadata；raw/max 均缺失时必须统一
  使用 1,000,000 token 产品缺省值，不得按 model slug 猜测。默认 total-scope 90%
  auto 与 95% usable hard trigger 取较早值；95% 还必须作为 checkpoint
  落盘前的 replacement request postcondition。summary output 不得使用与 resolved
  usable window 或 explicit token budget 无关的固定 token ceiling；只能从这两者
  派生 request ceiling，host 必须在 append
  stream delta 前执行对应的实际输出 bound，并在 replacement 前拒绝
  `SecretScanner` 命中的摘要；provider 忽略真实 constraint、逻辑裁剪破坏
  tool call/output 配对或替换后仍超窗都必须 fail closed。media-aware compaction必须把它将覆盖的
  完整active window及其中用户/工具图片交给summarizer；context overflow不得删除旧逻辑项后仍声称
  摘要覆盖未见内容。成功checkpoint必须剥离所有旧attachment IDs/image refs，以摘要接替旧原图但
  保留ArtifactStore与审计事实；media-aware schema v2 lineage不得由后继v1 checkpoint降级。
  raw/max 缺失时，exact metadata 中显式的 `auto_compact_token_limit` 仍须被
  1,000,000 产品缺省窗口的 90% 上限 clamp；route 歧义或 legacy binding 使用同一
  产品缺省值，仍不得按 model 名猜窗口。`body_after_prefix`、切模
  previous-model compact、remote compact、rollback/fork/world-state parity
  未落地前不得写成已支持。
- Skill 仍是 Turn-scoped context，不得为解决物理历史占用而新增 sticky
  activation、Session ledger、TTL 或权限型卸载状态；再次需要时从新 invocation
  snapshot 重读，旧 contextual body 由通用 compaction 管理。

## Skill capability 不变量

- Skill 是 instruction/context，不是权限。不得因 Skill metadata、正文、脚本
  或 resource 新增/推导 filesystem、shell、network、MCP、communication、
  delegation 或 coordinator 能力；任何动作仍须使用 authoritative tool list、
  CapabilityLease、WorkspaceLease、PermissionEngine 与 durable tool ticket。
- 一次 Code send / Cowork AgentInvocation 必须只使用一个 immutable
  `SkillSnapshot`。developer catalog、显式 user Skill body、dynamic tool
  schema/executor、registryVersion 和 MCP base registry 必须绑定同一 digest；
  不得在同一 invocation 的后续 provider dispatch 偷换 live Skill 内容，也
  不得让旧 response 查询 current registry。
- catalog 必须保持 developer role；只有当前用户 turn 中无歧义的显式
  `$name` 可直接形成 user contextual body，模型自主选择必须调用
  `activate_skill` 并获得 ordinary tool result。不得把 catalog/正文拼入 system
  prompt，不得把 developer 静默降级为 system/user，也不得从 reviewer、
  agent message 或历史 assistant 文本猜成用户显式 Skill selection。
- Cowork coordinator system prompt 可以要求激活产品内置 Skill，但只能引用稳定
  name 与 exact catalog identity 约束，不得内嵌 `SKILL.md` 正文、model-routing
  table 或伪造 activated block。`cowork-agent-orchestration` 必须匹配
  `scope="system"` 且 source 以 `system:bundle-` 开头；同名 workspace/user Skill
  不能替代。entry 缺失、omitted 或激活失败时必须使用 direct / exact-profile
  inheritance / read-only / no-child-coordination fallback，不得猜测正文。
- 调度 Skill 的厂商定位与价格 reference 是 dated heuristic，不是运行时模型
  catalog、benchmark、计费权威或权限。child 不同 profile 只能使用当前调用
  `list_inference_profiles` 返回的 exact ID；其 capability 只能来自 host 对用户 JSON
  的 exact profile 声明，缺失必须显示/解释为 `unspecified`。歧义时继承 issuer exact
  revision，不得从厂商/模型名推导 endpoint、credential、wire、capability、发布日期、
  价格或 context limit。required capability 不能被“更新/更强/更便宜”覆盖；main
  缺少 multimodal capability 时必须搭配明确 capable child，且实际 artifact 无法交付
  时必须报告 blocker，不能伪造多模态结果。
  write access 与 `canCoordinate` 必须分别显式最小化，不能由模型强弱推导。
  正式多厂商矩阵同样不能扩大候选集：Preview 不得仅因更新而绕过 stable/lifecycle
  gate，Meta 等开放权重 route 不得假设统一价格，Kimi/Z.ai/MiniMax/Qwen 等厂商名
  也不得成为 endpoint、wire compatibility 或 capability 的隐式证明。
- `activate_skill` / `read_skill_resource` 只能读取自己捕获的 frozen snapshot，
  接受 opaque Skill ID 与相对 resource path；不得接受绝对路径、`..`、live
  path 或 generic `read_file` fallback。正文/资源进入 provider/EventLog 前必须
  通过确定性 secret scan 和 48 KiB durable-output-compatible bound；不得出现
  “首次全量、replay 截断”或把 secret 片段写进诊断。同一 invocation 的多次
  或并行 Skill tool 返回必须共享一个原子累计披露预算；不得靠重复调用绕过。
- workspace Skill discovery 不得越过 exact canonical WorkspaceLease。
  Developer ID/CLI 的 global roots 必须由 host policy 显式开启。每个 Cowork
  child 独立构建，parent 已激活 body 不继承。permission reviewer、
  GoalVerifier 与 iOS 必须保持零 Skill catalog/tool/linkage。遗留 App Store
  target 的 workspace-only 分支不是当前产品合同。
- root/entry/depth/file/resource/catalog 限制必须真实执行并有测试，不得保留只
  声明不消费的“装饰性限制”。取消、root identity/path 变化、secret、symlink
  或读取不确定性必须 fail closed，不得成功发布 partial snapshot。
- catalog 自适应预算只能来自当前 exact profile 的 canonical primary
  `contextWindowTokens`：Codex `context_window` 优先，缺失时只允许显式
  OpenCode `limit.context` 补位；两者缺失/非法时使用 8,000 字符。不得按
  model slug、最大窗口或 compaction metadata 猜测。预算只约束 metadata，
  不约束 trusted envelope。count-only
  metrics/warning 不得携带 Skill 名称、路径、description、正文或秘密，也不得
  把尚无 host consumer 的 snapshot 字段宣称成已上线 operational telemetry。
- `agents/openai.yaml` machine metadata 必须保持有界、严格、默认不可通过
  generic resource tool 读取；当前只允许 MCP dependency。Skill 正文或资源
  披露前必须使用会接收该结果的 exact request-owned MCP snapshot，按 server
  ID + transport-locator fingerprint 成对证明，不得以 process-global config、
  server 名称、旧连接 generation 或 live registry 兜底。无 MCP host、无效
  metadata、endpoint/command 变化、snapshot 无法承载 exact host assertion
  时必须 fail closed。
  production assertion 只能从同一请求经过 capability/policy 过滤的
  agent-visible tool entries 派生；server 至少贡献一个可见 tool 才能满足。
  低层 `.frozen` factory 只是 trusted host construction seam，不得把手工构造
  值、仅连接/config 存在或仅 resource 可见当作自认证 proof。
  locator 原文、header、credential、query 与 command 不得进入 model-visible
  availability 或 durable diagnostic。不得把当前 preflight 扩写成已支持 Codex
  的自动安装、Continue anyway、OAuth、外部配置持久化或 runtime refresh。

## External MCP client 不变量

- 只允许连接外部 MCP Server 的客户端角色。不得新增 Intatis MCP Server
  target/API/UI/CLI command/server transport/server OAuth/hosting seam；sampling、
  elicitation 与 client-hosted Tasks 是 client callback，不得误删，也不得借其
  名义引入 server hosting。`IntatisMCPConformanceClient` 必须保持开发期
  client driver，不能进入发行 bundle。
- 当前产品平台链接必须保持：Developer ID macOS 与 CLI 可链接 stdio + HTTP；
  iOS 不得链接 `IntatisMCP`、Curl transport、stdio runtime 或 MCP 产品 UI。
  共享 `IntatisProtocol` payload 不构成平台能力。不得恢复已删除的
  `TranslatisMacAppStore` HTTP-only 产品图。
- attachment 不是连接权限，grant 也不是独立连接权限。每次 provider dispatch
  必须冻结 exact `AgentRequestToolSnapshot`；准备和执行必须分别重验
  attachment、Agent、CapabilityLease/task、WorkspaceLease、grant、server
  revision、schema、raw/view catalog revision、binding、connection generation、
  account/environment authority 与 revocation。旧 provider response 不得查询
  current registry 或被重绑定到新 route。
- worker 默认零 MCP，child grant 只能由 parent grant 与 child lease 显式求
  交集；`@permission-reviewer`、GoalVerifier、read-only/unleased identity 不得
  看见或执行 MCP tool。`tool_search` 只能返回当前 frozen Agent catalog；
  canonical JSON 与 provider-native output 必须在 loaded-state commit 前原子
  计入 provider-request/turn 预算。
- shipping Codex root只可把上述exact durable authority收窄投影到官方`[mcp_servers]`，不得调用本节
  legacy client作为fallback。Cowork每个显式role、默认role与persisted child resume必须使用完整
  secret-free disabled server config保持child默认零MCP；root grant绝不构成child grant。未来exact
  per-child native MCP只有在durable child CapabilityLease/grant和official per-thread config同时成立时才能
  开放，不能删除disabled围栏或把session-wide surface冒充逐Agent authority。
- **Native Codex MCP授权入口**：macOS Code/Cowork Project Settings与Codex CLI会话内grant必须在EventLog
  append前绑定exact Code root或Cowork `@main` session-root，并精确等于完整Interactive、non-expiring
  capability set；approval与tool filter可以收窄，不能借template、partial capability、TTL、child或task
  authority生成一个随后才被runtime拒绝的grant。历史child grant只可撤销，历史root不兼容grant只可升级或撤销。
- HTTP direct mode 必须维持 exact origin、每 hop DNS/address authorization、
  native socket binding、无 ambient cookie/cache、受控 proxy/redirect；
  已发送的 tool operation 不得因 401/redirect/network failure 自动 replay。
  `MCP-Session-Id` 必须在任何 JSON/SSE body 发布前同步校验并注册 exact
  redaction value；mismatch 必须 retire exact generation。
- stdio 不得回退到裸 `Process`、普通 shell 或“完全信任 localhost”。macOS
  必须保留 Seatbelt + generation-local authenticated CONNECT gateway；Linux
  必须在 bwrap 与 ptrace/seccomp guard 可证明时运行，否则 fail closed。
  gateway 只允许 exact frozen origin/address，不能解析/托管 MCP JSON-RPC。
  timeout/cancel/task terminal/runtime shutdown 必须先 drain transport、process
  tree 与 gateway。
- MCP macOS secret 必须使用 data-protection Keychain；CLI secret 必须使用
  owner-only 认证加密 store。catalog/EventLog/session projection/diagnostic/
  permission preview/CLI history 不得保存 bearer、header/env/OAuth value、
  session identifier 或可逆派生值，只能保存 opaque reference 与 secret-free
  identity。普通 provider config secret backend 与 MCP secret backend 不得
  混写。
- 外部文本、JSON key、cursor、URI/template、MIME、icon/annotation、binary
  bytes、错误与 server instructions 在进入 model、UI、EventLog 或
  ArtifactStore 前必须经过 session exact/derived redactor、结构校验和最终
  字节预算。resource/template catalog 在 SDK session boundary 清洗后，
  reader-facing UI sink 仍须以同一 session redactor 复核。敏感结构字段只能
  fail closed，不能用 `[REDACTED]` 替换后继续当 route/identifier。
- MCP durable event 必须继续 additive、旧日志 default-empty 可解码；unknown
  future event、seq gap、冲突 attachment/grant/terminal 或 incomplete-known
  history 不能被当成“无 MCP”。remembered approval 仅能由用户对 exact
  read-only、effective `auto` call 明确 `approve_and_remember` 创建，普通
  approve 不能隐式扩权。
- vendored SDK 必须保持 client-only derivative、固定 upstream/provenance/
  patch ledger/NOTICE。升级不得重新带入 Server actor、HTTP server transport、
  server OAuth、server/conformance executable 或不必要依赖；任何公开源码
  变更继续执行许可证、来源、双平台 linkage 与 client-only surface gate。

## 2026-07-24 Session 展示隔离不变量

- Code / Cowork 的可见详情和 thread 必须保留 exact `{kind, sessionID}` presentation identity。bottom anchor、scroll request 和任何延迟 UI 工作必须携带同一 scope/generation；不得恢复静态共享 anchor、无 owner 的 `DispatchQueue.main.async` 或可在切换后命中新树的闭包。
- 每个窗口、每个当前可见 thread 最多一个 pending auto-scroll。scope change、disappear、新一代请求和用户开始滚动都必须取消/拒绝旧请求；initial restore 不动画，用户离开底部后 live token、Thinking、completion 或 rich height 变化不得强制抢回。回到底部后才恢复 follow。rich correction 必须忽略亚像素 jitter；raw-content/width layout epoch 内最多完成一次 shrink→regrow recovery，首次 correction 后同一 epoch 的重复高度振荡必须被拒绝，不能形成 geometry→scroll→geometry 自激循环。
- Session presentation 的销毁不等于 runtime shutdown。切换 mode/session、关闭任一窗口或关闭最后窗口不得 stop Chat/Code/Cowork runtime；相同 session 的多窗口可共享业务 runtime，但 ScrollView、coordinator、bottom-follow 与临时 rich/layout state 必须按窗口独立。
- 不得把 retained runtime 的通用 `objectWillChange` 桥接成 root-wide revision 或无差别刷新。窗口只可消费它真正展示的 exact-key summary/status；sidebar busy、delete guard、完成排序等不同语义应使用各自的窄投影，不能为了方便恢复全局失效桥。
- runtime 删除必须先取得 exact-key removal fence，并在 fence 内复核 busy、drain exact runtime、完成 session storage delete 或明确 abort、撤销 exact observation，最后才向所有窗口发布 removal；异步删除未完成时其他窗口不得 reopen/register 同 key，`.removing` 也不得被 activity 覆盖。删除仍不得影响其他 session 或工作区文件。
- Chat 历史恢复必须从 strict snapshot 一次折叠并一次发布，再增量发布 live 事件；不得从历史起点把每个 delta 重新喂给 SwiftUI。subscriber 必须先于 strict catch-up 注册，snapshot/catch-up/live 按 seq 去重；任一 strict read 失败都必须在历史/live publication 前 fail closed 并允许显式 reentry 重试。stop/shutdown/restart 后 stale fold 不得发布。该规则不改变 EventLog raw truth、实时 streaming 或旧日志解码。

## 2026-08-03 Cowork Agent 对话切换不变量

- 新窗口和 session 默认查看 durable `@main`。ordinary agent 可切换查看；
  `@permission-reviewer`、GoalVerifier 或其他保留控制面 identity 只能显示状态，不得成为普通
  conversation selection、send、delegate、message 或 ask target。查看选择不得改变 composer
  默认 `@main` 路由、runtime、scheduler、mailbox、Goal、lease、权限或 agent status。
- 不得在点击时对完整 `CodeProjection.items` 做 `filter`/`contains`/排序/重放，也不得把完整
  Cowork item array 复制发布到 MainActor。fold 时必须增量维护 typed agent index，窗口查询
  当前选中 agent 的完整连续有序快照；其他 agent 的 canonical rows 继续留在 projection actor，
  非选中 agent publication 只能更新其 latest-only channel，不能刷新当前 transcript。
- 归因只可信 typed payload 和 durable correlation。缺失 target 的 legacy user/model/tool/patch
  row 只能回退 durable main；tool result 继承 exact call，submission error 继承 exact submission。
  A2A/information/delegation/task row 可属于双方索引，但 canonical row 不得复制两份。不得从
  title/body、`@mention` 字符串、展示文案或当前选中 agent 反推归属。
- selected agent 和 request generation 必须 window-local。A→B→C race、session replacement、
  disappear 或新一代请求都必须取消/拒绝 stale
  load/update；多个窗口可以查看不同 agent，互不覆盖。ordinary agent detach 不是 identity 删除：
  当前窗口必须继续停留在该 historical agent 并保留其连续历史，不得自动回退 `@main`。
- Agents 列表必须来自 EventLog-derived historical identity roster，并在同一列表保留所有曾 durable
  attach/spawn 的 agent；不得过滤 `detached` / `removed` / `cleaned`。既有状态图标显示 detached
  lifecycle，ordinary historical agent 仍 conversation-selectable，控制面仍 status-only。发送、
  委派、message/ask、rebind/remove、settings 与 workspace/capability 引用必须只认 live roster，
  不得因为历史项仍可点击而恢复其运行时权限。大量历史项必须使用 stable ID lazy list；构建
  presentation 不得对每个 agent 重扫全部 task、workspace lease 或 capability lease。列表顺序必须
  使用 identity 第一次 durable admission 的稳定创建顺序；status、消息、detach/reattach 不得让行在
  用户点击期间跳位，也不得为了排序扫描 transcript。
- Cowork transcript 必须是一条没有 Earlier/Newer/Latest 或消息页码的连续滚动时间线，并复用一个
  ScrollView 根。顶层 rows 使用稳定 identity 的 lazy materialization；屏幕附近最多 16 条 row 可
  保留重型 native rich-document graph，离开活跃 viewport budget 后必须释放该 graph并保留轻量 raw
  text。不得恢复 `.id(pageScope)` root replacement，也不得把 16 重新解释为数据页大小。
  selected-agent delta 到达时 rich admission 必须暂停；同一精确状态连续静止 300 ms 后才可恢复，
  持续 streaming 使用 raw projection。raw/rich 切换不得改变内容字节、canonical item、连续历史总数
  或 EventLog。
- Cowork agent/content 切换不得改变横向几何。wide rail 必须继续由 stable outer width
  唯一决定，visible width 固定 348pt、glass section 固定 318pt，并单独保留 10pt primary-scroller
  clearance；selected agent、消息数量/长度、空态、rich/raw admission 和 scrollbar 可见性不得
  参与宽度计算。thread 必须先固定 content/raw frame 再扩展到 overlay 下方，不能因换 Agent 替换
  ScrollView 根、重新协商 composer/header 宽度或让中栏左右边界跳动。exact outer-detail canvas
  必须直接拥有 leading thread 与 trailing rail；禁止把 rail overlay 重新挂到 `threadColumn` 或任何
  transcript/content intrinsic-size 宿主上。selected-agent ID 不得进入会使整条 rail 失效的 render
  snapshot；只允许独立更新选中行蓝底与 accessibility value。passive glass backdrop 必须是与行内容
  更新隔离的稳定 identity，independent status cards 不得放进会自动融合/重组 shape 的
  `GlassEffectContainer`，inspector/selection 状态变化不得带入隐式 layout animation。不得使用
  screen-global origin、窗口位置补偿或 backing-pixel translation 改动 rail 位置。
  bottom-anchor 恢复必须使用系统 scroll visibility observation；不得恢复 GeometryReader + global/named
  frame + `PreferenceKey` 的布局回写链。
- 性能诊断只能记录 duration/count/generation/rowCount/totalCount 等 content-free 数值；不得写入
  agent 名称、message body、tool args/result、workspace、endpoint、credential 或完整响应。

## 2026-07-23 UI / history 不变量

- recent sessions 必须按 durable `turn_outcome` 时间倒序排列；不得使用点击/选择顺序、Cowork reconciliation-only submission terminal 或 `events.jsonl` mtime。打开、replay、rename、migration、recovery、settings/lease append 均不得提升排序；运行中 turn 在 terminal 落盘前不得提前提升；相同时间必须 deterministic。mtime 只可参与缓存失效。
- 工作态必须在 composer 原 Send 槽位显示系统原生 destructive red Stop，不得并排保留 Send，也不得用自绘图形替代系统 Button/SF Symbol。键盘提交不得绕过该状态。
- composer voice 必须保持在唯一 Send/Stop 槽位的紧邻左侧，不得取代、复制或挪动主操作槽位。
  第一次点击只开始录音，第二次点击才停止并转写；结果只追加到当时仍可编辑的草稿，不得自动发送。
  requesting permission、recording 或 transcribing 期间不得允许同一草稿提交造成语音结果跨 turn 混入。
- Stop 是当前数据面活动的 scoped cancel：Chat/Code 不得借此 shutdown session runtime；Cowork 不得关闭 reviewer/control plane，Goal 必须走现有 pause/checkpoint/cancellation barrier。仍须遵守 provider/tool drain-before-terminal 与 durable outcome 合同。
- Chat保留的`Ns Thinking…`只代表当前可见first-token waiting phase；不得根据它伪造协议时间、EventLog
  事件或agent状态。phase identity必须区分exact session与最新raw trigger item；行销毁、工具轮次或
  session切换后计时必须停止/重置。Code/Cowork使用上面的App Server官方phase/event直出，不得复用该
  合成计时行。

本文列出不可破坏的工程禁区、数据格式、协议、路径和回归要求。修改前必须确认不违反下列任一条目。

## 工程禁区

- 不执行破坏性 Git 操作：`git reset --hard`、`git clean -fd`、`git checkout .`、强制 push、删除未提交文件。
- 未经用户明文要求具体 Git 操作，不 add、不 commit、不 push、不创建 PR；编辑、整理、修复、验证或准备工作都不等于提交请求。
- 若用户要求提交，只提交当前 Git root 中与本任务相关的文件；不得递归进入、暂存、提交或推送子仓库、submodule、nested Git repo 或依赖 checkout。
- 不引入或升级第三方依赖，不改构建脚本，不改测试源码，除非任务明确要求。当前对话渲染依赖/资源已按精确版本与 hash 锁定；任何变更均须重做许可证、传递依赖、资源范围、安全与 NOTICE 审查。计划中的 SwiftGit2/libgit2 仍须先过许可证审查。
- 系统原生表面与 Liquid Glass 是当前视觉基线：不得把浅色 / 深色写死为 `.white` / `.black`、固定 RGB、Hex 或取色器采样值。macOS detail 使用动态 window surface，sidebar 交给 `NavigationSplitView`；assistant/agent/system 对话正文（包括失败/中断时已产生的正文与媒介化 Agent 通信）直接继承系统 canvas。用户消息是唯一对话气泡，必须使用原生 `Glass.regular`，不得叠加自定义 accent 蓝色描边；正常 tool、permission、task 等专用结构化内容卡片继续使用系统 Material。Code/Cowork 的 error、失败 trace、recovery 与失败 submission 状态不得回到 thread 中央，而应只进入右栏唯一的条件式错误卡。Liquid Glass 主要用于导航与交互功能层，内容层例外只包括用户消息气泡和用户明确指定的 Cowork 紧凑 trailing status rail，并且都必须使用原生 `glassEffect`。`GlassEffectContainer` 只用于确实需要融合/形变的交互 cluster，不得包裹彼此独立且位置必须稳定的 status cards。Apple deployment target 已是 macOS 26 / iOS 26，旧系统 fallback 不属于当前验收面。不得自行模拟玻璃，也不得把 glass 铺成页面或整段 transcript。修改配色语义、材质、明暗模式或跨平台映射时必须同步更新 `docs/CURRENT_UI_COLOR_SYSTEM.md` 并复验 macOS/iOS；`docs/UI_COLOR_SYSTEM.md` 是上一版配色的历史底稿，不得被当前方案覆盖。
- 不绕过 3 层权限门、`PathConfinement`、`SecretScanner`、`Mediator` 秘密拦截或配置文件凭据隔离。
- 不把 CapabilityLease/WorkspaceLease 当成某次调用的 effect，也不再用 `SideEffect.write/readOnly` 代替结构化 `PermissionIntent`。agent/task/message/workspace admission 属于控制面动作；实际文件、网络、exec、destructive effect 由具体工具调用决定。`spawn_agent` 默认 read-only，显式 `requestedAccess=read_write` 与 `canCoordinate` 必须独立授权且不能超过 issuer lease；一个外部 spawn ToolCall 只能有一次审批，内部 atomic admission 不得二次进入 PermissionEngine，child 后续数据面调用仍须逐次审批。

## 开源复用与来源禁区

- 允许按 `docs/OPEN_SOURCE_REUSE.md` 复制、翻译、修改、链接、vendor 或以独立 runtime 使用兼容许可证的公开源码；逐行翻译也必须按派生复用记录来源。
- 每批复用必须固定上游 URL + tag/commit + 文件路径，核对根许可证、文件头、NOTICE、传递依赖与资产许可证，并在实际引入时更新 `NOTICE.md`；缺许可证、来源不明或范围冲突时停止合入。
- 不使用泄露、反编译或绕过访问控制获得的源码/私有 prompt；不复制第三方名称、Logo、图标、截图、UI 资产、商标性外观或品牌文案作为 Intatis 产品身份。
- 公开仓库中许可证兼容的 model-facing prompt 可经审查后派生复用，但必须去除上游品牌/支持链接并重新核对 Intatis 工具名、权限和安全语义；私有或许可证不明 prompt 禁止使用。
- 上游默认权限、工具、文件访问、网络访问或自动执行行为不能直接继承；必须映射到 Intatis 的 PermissionEngine、CapabilityLease、WorkspaceLease、PathConfinement、durable tool ticket 和 EventLog。
- Apple-first 边界不因源码复用而改变：Swift-native 优先；非 Swift helper/runtime 必须显式评估签名、sandbox、进程清理与失败降级，且不得进入 iOS local-agent target。

## 对话内容渲染禁区

- `SessionProjectionPump` 必须逐 seq fold 所有 envelope；50 ms 只能限制连续
  delta 的 presentation publication，不能变成 reducer 前合并、reset
  debounce、EventLog 抽样或事件重排。任意非 delta 必须立即 barrier flush；
  exact `{sessionID, generation, throughSeq}` fence 不得移除。
- scroll geometry 永远 observation-only，不得直接或同步间接触发
  `scrollTo`。用户 detached 后 delta、completion 与 rich settle 都不得抢回
  滚动位置；viewport admission 只能延迟 rich parse/mount，不能延迟 raw
  final、EventLog fold 或 terminal projection。
- macOS `ParagraphNSView` 不得重新声明 intrinsic width；bounds width 变化
  不得调用 `invalidateIntrinsicContentSize()`。内容或 line-spacing 变化仍可
  invalidate intrinsic height。
- macOS `ParagraphView.sizeThatFits` 必须返回 exact finite positive proposal
  width 与 measured height，不得返回 glyph used width。
  `ParagraphMeasurementCache` 最多一项且 key 为 exact width；不得重新引入
  rounding、width-history dictionary、message-height cache、document cache
  或 native-view cache。
- `EventLog` / projection 中的原始消息文本是唯一真值。Markdown document、attributed content、原生 view 和缓存都只是可丢弃的显示投影，不得写回 `EventLog`、改写 `Envelope` / message payload，或在恢复/复制时以派生文本替代 raw text。
- macOS rich message 的普通左键拖拽必须保持“一条 `DocumentView` 一个 coordinator、多个 native
  TextKit leaf”的合同：鼠标目标可由真实窗口 geometry 决定，但 selection/copy 顺序必须来自稳定
  document registration，不得按 paragraph 高度、当前 first responder、正文或相邻 view 猜顺序。
  不得恢复整棵 rich tree 的第二个 SwiftUI `SelectionOverlay`，不得要求用户进入 `Select more text`
  菜单/sheet，也不得叠加纯文本 shadow renderer。标题、段落、列表正文、block quote、表格 cell 和
  code body 继续由既有 derivative 的 native layout owner 渲染；code 必须保持 unwrapped + horizontal
  scroll，table 的 unspecified natural measurement 与 row-major order 不得因 selection 改成零宽或乱序。
  drag 期间只改各 view 的 transient selected range；mouse-up 强调只能把该 view 的 exact 系统
  `selectedTextAttributes` 写入 view-owned disposable `textStorage` snapshot。首个 leaf 可保留真实 native
  selected range 维护 responder/Copy，但必须暂时清空它的 native temporary selection attributes，不能再
  叠加一套随 focus 改变的浅/深高亮。普通点击、stream replacement、mode/session/page change 与
  dismantle 必须逐属性恢复 text projection 和 native selection attributes。Command-C 可按显示顺序合并
  plain text、换行/tab 与 inline-math literal，但不能把
  该派生文本写回 EventLog，也不能取代 message footer 的 raw-message whole-copy。当前边界只跨同一
  rendered message document；跨消息、结构化卡/footer、拖出 viewport autoscroll 与 modifier selection
  未经独立设计/验证前不得宣称支持。iOS 和 plain-safe leaf selection 不得被 macOS coordinator 扩大。
- Code/Cowork verbose execution trace 的默认隐藏也只能是可丢弃的展示投影：不得删除、截断或停止记录 `.tool_call` / `.tool_result` / patch / note / agent-to-agent / `task_completed` 事件，不得改变模型上下文、权限审计、durable tool ticket、scheduler/WorkTask candidate 语义或恢复。默认会话显示 user、真实 agent message、媒介化 `.agentToAgent` 通信（含通用 agent message、`information_requested` 与 `information_replied`）、没有对应完整 message 的 task-result fallback 与 actionable error；不得重新把 `.agentToAgent` 归入默认隐藏 execution trace。只有同一 TaskID/agent/attempt 内正文完全相同的 `message_completed` → `task_completed` 镜像可标为 trace-only。禁止按全局正文或相邻事件去重；new start/retry 不得继承旧配对，迟到旧 terminal 不得清除新 attempt，跨任务同文、attempt 不同与正文不同必须保留。`-IntatisShowExecutionTrace` / `INTATIS_SHOW_EXECUTION_TRACE=1` 必须恢复完整既有调试视图。该开关保持 backend-only、默认关闭、无 UI/UserDefaults/运行中切换；Code inspector、thinking 判断和 auto-scroll 也必须消费同一过滤结果，不能在侧栏或滚动签名中偷偷重新处理大型隐藏 body。
- 当前角色边界是 assistant/agent 使用富文本，user/system 和特殊结构化卡片保持纯文本/专用 UI。不得无意扩大对模型输出的信任范围。
- `IntatisMessageRendererMode.plainSafe` 是必须长期保留的产品熔断，不是迁移期临时代码；持久键 `intatis.messageRendering.mode.v1` 与启动参数 `-IntatisPlainSafeMessages` / `-IntatisMicrosoftMarkdownMessages` 不得静默改名或失效。旧 `rich` value 与 `-IntatisRichTextMessages` 只作向 `.microsoft` 的兼容映射，设置 Picker 也必须显示 resolved Microsoft selection。plain-safe 必须在历史 message view 初始 state 前生效，不得构造上游 Markdown view 或启动 parser。历史初始态、activation/reentry、correction/truncation 与 final 除空未完成消息的 `…` 外必须 byte-exact 显示 raw `String`；append-only 中间态允许至多 100 ms latest-only 视觉滞后，但不得改写、丢失或阻止 final 精确 flush。
- 缺少 renderer preference 时默认 `.microsoft`；未知或损坏值必须 fail closed 到 `.plainSafe`。iOS `Settings.bundle` 必须继续使用同一 string key、`microsoft` / `plainSafe` values 与 Microsoft default，并实际存在于签名 app 产物。应用内 Picker、系统 Settings 与 facade 必须解析为同一语义；plain-safe 启动参数与 Microsoft 参数冲突时 plain-safe 胜出。
- rich 流式更新必须保持monotonic presentation，禁止每个token先清rich、回raw、再挂rich。首份rich尚未
  发布时继续使用facade-lifetime current raw；已经挂载一份未complete rich document后，只有同一message、
  同一style/appearance/typography/configuration、当前消息仍满足64 KiB admission，且新raw逐字以旧raw为
  prefix的append-only successor，才可在下一exact parse期间继续显示该单份active rich projection。
  下一份document仍必须与exact current request全等后才能发布，并只做rich→rich replacement。correction、
  truncation、上一份已complete后的变化、message/mode/style/appearance/typography/config漂移、oversize、
  viewport suspension、offscreen eviction、取消或view dismantle必须立即回current raw并释放旧rich。
  raw state、copy、EventLog与provider history始终是最新exact文本；这一窄active-view retention不得变成
  completed-document/native-view cache，不得跨message/scope/view lifetime复用，也不得让stale parse发布。
- macOS新rich document必须先经过Intatis facade的单次owner-bound attachment-hosting turn再无动画显示，
  防止TextKit generic文稿占位在live公式provider安装前到达屏幕。该gate只能保存document identity与可取消
  Task；不得保存document/parser/result、使用固定sleep/spin、解析LaTeX、修改vendor、影响iOS，或演化成
  第二renderer/cache。replacement、deactivate与dismantle必须取消旧gate；等待期间只能使用既有exact raw
  projection，不能创建另一份语义内容。
- 不在 Intatis 内重写 Markdown parser、AST rewriter、代码 lexer/grammar/token classifier、TeX 解析/排版或 Markdown layout。Markdown grammar/AST/原生布局属于经审计的 Microsoft `SwiftStreamingMarkdown` 派生包；Intatis 只维护 admission/backpressure/revision/policy/plain fallback。任何需要改 parser 或 table/paragraph layout 的缺陷，应在仓内 vendored derivative 中以 provenance/tests 约束，并尽量提交 upstream；不得悄悄堆成无来源、无 ledger 的 Intatis 私有 renderer。
- rich admission 固定为完整消息 UTF-8 ≤64 KiB；超限整条走 raw projection，final 必须 exact。process-wide parser permit 上限为 1、pending message key 上限为 32；每个 key 最多 1 个 running permit与 1 个可替换 pending acquire，view request buffer 必须为 latest-only 1 项，未完成消息 debounce 为 50 ms。scheduler 只保存 key/generation/continuation/metrics，不得接收 operation closure、保存 parser/document/result 或形成第二条 publication queue。调大上限、改为并行 parse 或重新加入 cache 前必须有同一 fixture 的性能、内存与取消/stale 证据。
- plain-safe 与 rich pending/rejected/oversize 必须复用同一个 facade-lifetime raw projection，不得在 `DocumentView` 条件分支切换时为每个 token 重建状态。append-only publication 使用 100 ms fixed-window leading/trailing throttle，不能退化为 reset-on-every-token debounce 或逐 token 整段 `Text` 更新；activation/reentry、correction、truncation、final 必须同步直出。timer 必须携带 generation，旧 timer 不得清除或覆盖新 timer/final；`@Published nil` 不得在 parser document 已为 nil 时按 token 重复赋值。
- 第一版没有 completed-document cache 和 paragraph native-view cache；流式append期间保留当前可见view已经
  挂载的一份兼容未完成rich document，不属于cache，也不能在evict/deactivate后保留。不得把旧96项/4 MiB
  MarkdownUI cache或64项highlighter cache迁回。零cache只证明derivative自身不持有该cache，不证明
  SwiftUI/TextKit总view graph内存有界。不可见view必须deactivate并释放document graph；只有测量证明收益
  且不扩大历史session内存/主线程风险后才能设计新cache。
- 图片、citations、文字动画与语法高亮当前关闭；数学只允许经审计的 code-aware `$...$` / `\(...\)` 行内模式与 `$$...$$` / `\[...\]` display 模式，display 内容允许跨行。公式路径不得重新加入 Intatis 自设的每消息数量、单公式 UTF-8 或固定 attachment 尺寸上限；64 KiB whole-message rich admission 与 1-running/32-pending parser scheduler 是语法无关的 facade 资源边界，不得伪装成公式限制。代码、金额、escaped delimiter、link/image/autolink 与 raw HTML literal 不得进入数学识别。合法公式必须通过 TextKit 2 live `MTMathUILabel` attachment 展示，并保留 inline/display presentation；无效 TeX 或非有限/非正 geometry 恢复 exact source，不得改回 bitmap/raster preview 或新增公式图像 cache。attachment 必须继续使用唯一 MIME 派生的专用动态 UTI和 subclass-owned exact provider，AppKit generic `attachmentCell` 必须为空；不得给 `.json` / `.data` 等宽泛 UTI 注册 provider。AppKit paragraph 必须强持有 root `NSTextContentStorage`，整段 attributed-string replacement 后恢复 `primaryTextLayoutManager`，并在内容或真实有效宽度变化后合并调度 `layoutViewport()`；不得访问 legacy `NSTextView.layoutManager`。`CATransaction.flush()` 只能用于测试确定性，production 不得用 flush/sleep/spin 驱动 provider。semantic appearance 与 Dynamic Type 必须进入当前 display revision，旧色彩/旧字号结果不得覆盖较新请求。代码块必须保留完整、可选择、可复制的原始代码与横向滚动；不得为恢复颜色而执行模型产生的 JavaScript或在 Intatis 内自写 grammar。Markdown 图片不得触发远程或本地资源加载；链接只允许 `http` / `https` / `mailto`，不得允许 `file:`、自定义执行协议或未审查 scheme。
- 不得重新引入 MarkdownUI、NetworkImage、HighlightSwift/highlight.js、Shimmer、macro/snapshot testing 或旧 `IntatisRenderDocument` / `IntatisCodeBlockView` / `IntatisMathView`。iosMath 只允许当前已批准并固定的官方 `2.5.0` / `838cddc01fdd67efd530f8bb67959ad2715f9b06` 条件依赖及其已记录字体资源；变更版本、fork、字体清单或许可证必须重新完成依赖/许可证/安全/性能审查并更新 NOTICE。旧代码和历史报告可作证据，不是生产事实。
- 派生包必须继续以 Microsoft v0.6.0 commit `c7b12f7b3d77caa188fd1fc056d0f7ce305ef5cd` 为 provenance basis，并保留 `Vendor/SwiftStreamingMarkdown/LICENSE`、相邻永久 patch ledger、完整派生包回归测试及传递的 swift-markdown/swift-cmark exact revisions。根 manifest 只能用仓内相对 vendor 路径；重新指向 `/private/tmp`、删除/模糊 Microsoft 归属、把派生代码标成 Intatis 原创、纳入嵌套 `.git`/缓存/probe/上游 agent instructions，或重新夹带未经审计的 Examples/品牌/字体/媒体资源，均是发行阻断。每次 vendor/upstream 变化都必须重跑许可证、品牌、依赖图、测试和最终 app 产物扫描；Intatis 根 Git revision 是派生快照的发行身份，不要求另建 remote fork。
- renderer 回归 fixture 必须保持脱敏文件 `incident-1249-sanitized-v1.json` 的 17 messages / 1,249 deltas 与 SHA-256 `fb548849d0b708d31e8c6d055805f29f5c09ee4c8306bf9adc537a48e95707f1`，或在明确版本化并解释原因后更新。性能数字必须注明 Debug/Release、设备、cold/replay 次数与采样口径；Simulator/macOS 结果不得冒充低端真实 iPhone/iPad、VoiceOver、动态字体、旋转/内存压力或附件组合通过。
- 2026-07-18 正式协议中唯一预先冻结的 pass/fail 数值是 interaction p95 ≤8 ms、single max ≤50 ms。100 ms Plain 与当时 production-shaped `LazyVStack` Microsoft 均过该门；Microsoft cold/replay worst p95/max 必须保留为 4.020458/37.840875 ms、4.876292/36.596500 ms，replay absolute peak/residual RSS 为 102.953/101.375 MiB。不得把 main/RSS/footprint/CPU observational 数据或 production facade 未暴露的 parse/runtime backlog 写成“通过”。当时无界 17-row eager `VStack` 对照的 cold 5/5、replay 20/20 p95 failure 也必须保留为历史结果，但它既不是当前“连续 timeline + 最多 16 个 active rich rows”的等价测试，也不能推翻后来真实 session 对 lazy/native AttributeGraph feedback 的 A/B。旧 xctrace 的 17 条 `.task(id: ViewRevision)` 每帧多次更新告警只作已修复历史；post-fix target-log lifecycle warning pattern 为 0、>250 ms potential hang 为 0，但这仍不等于形式化证明零 cycle/零运行时告警。
- 两平台继续保留 `DocumentView` / `ParagraphView` equality 与 selection
  ownership。UIKit 保留 patch group 8 的 leaf selection 和 bounded positive/zero/invalid width
  invalidation；macOS 以 patch group 11 的 no-intrinsic-width、exact proposal
  ownership、zero width-driven invalidation 和 one-entry measurement memo 为布局基线，并以 patch
  group 14 的 document-scoped coordinator 连接 native leaves。任何改动必须同步更新 vendored patch
  ledger、NOTICE/ThirdPartyNotices 与对应平台测试。
- 2026-07-18 GUI/CU adverse evidence 必须永久保留为历史发行风险：Force Quit 的 129.63 GB 是 application-memory UI 读数而非精确 RSS/footprint；CPU diagnostic incident `FA228932-2C40-4AC2-A0C2-62EF41342B4A` 的 sampled footprint 为 109.16 MB→803.30 MB。根因/retaining edge 仍为 `UNKNOWN`，不得伪称已归因。2026-07-24 单实例 hard-watchdog 的 math-disabled/enabled A/B、1/32/structure/history/stream 短时 stages 和 Light/Dark 约 47 秒 Computer Use 均通过、无残留；这些结果关闭了“未受控重跑”和公式不可见，但短于历史 160 秒窗口，也未验证真实 clipboard/VoiceOver 或 malloc retaining edge。以后所有 GUI 验收仍必须由父进程保证单实例、wall/RSS/footprint/CPU hard watchdog、越界终止和残留清理；不得并发启动多个 validation app，也不得用一个短时 stage 把 renderer 标为 release-ready。
- renderer/依赖变更必须更新 `NOTICE.md` 与 `ThirdPartyNotices/`，并复验 macOS/iOS 最终 app bundle 中声明文件可访问且与仓库内容 hash 一致。当前 iosMath 的八套数学字体及许可证只允许通过其独立 SwiftPM resource bundle 分发：`fonts/` payload 固定为 26 files / 7,234,424 bytes，完整 Xcode/SwiftPM bundle 加生成的根 `Info.plist` 后为 27 files；不得把两种口径混写。不得夹带 Cambria Math、highlight.js/CSS、Copilot 品牌资产或未声明字体/资源，发现即发布 fail closed。
- JetBrains Mono 正式字体资源只允许 `ThirdPartyNotices/JetBrainsMono.md` 登记的 v2.304 两份 unmodified
  variable TTF 与 exact OFL 文本；文件名、byte count、SHA-256、PostScript inventory 或上游 commit
  任一变化都必须重新做 font/asset license 与 final-bundle review。vendored Markdown patch group 13
  只能让 code block 使用既有 `MarkdownRenderConfig` font，默认 config 行为必须不变；不得把 JetBrains
  注册、产品字体策略或第二 typography registry 写进第三方 derivative。

## 数据格式禁区

- **事件日志 JSONL**：`~/Library/Application Support/Translatis/<session>/events.jsonl`。一行一个 `Envelope`：`{seq, ts, session, v:1, type, payload}`。`seq` 单调递增；event type 只能追加演进；replay 时不可解码行跳过。Goal / WorkTask / ContinuationRun 新事件不得改写旧 Envelope 或复用既有 type。`continuation_run_close_requested` 是追加式 durable claim，不得覆盖或冒充既有 completed/cancelled/checkpoint 事件；同一 RunID 的 first-write 只能在 complete-known history 与跨进程锁内决定，冲突 durable history 必须 fail closed。
- **PermissionIntent 兼容性**：permission request/resolved、review task、tool execution prepare/settle 中的 `intent` 只能作为可选追加字段演进；旧日志没有 intent 时必须继续解码，并由兼容 adapter 使用 tool name/side-effect/touched path 推导保守 intent。不得把 replay policy、lease ceiling 或 reviewer decision 合并进同一个可变布尔权限字段。
- **Phase C outcome 兼容性**：`turn_outcome` 只能作为 additive append-only event；旧日志没有该 terminal 合法。ToolResult、permission request/resolved、review task/settled 的 `TurnID`、tool-call/request correlation、approval mode/action、typed outcome/failure source 都必须保持 optional legacy decode，`approvalMode == nil` 兼容解释为 manual。RequestID 不得绑定两个不同 payload；同一 permission request 的首个 terminal 不得被 late/duplicate response 覆盖。unknown future event 或 `seq` gap 时不得用 absence proof 登记或结算 permission lifecycle。
- **Chat/Code/Cowork session/history**：不得回退为单一固定会话日志。New session 必须生成新的 `SessionID` 并打开独立 `<session>/events.jsonl` 与 `<session>/artifacts/`；History/Resume 只能切换到目标 session 的日志投影。macOS/iOS 共享 `SessionHistoryStore` 路径与最近会话扫描逻辑。legacy display name 必须在任何 schema-v2 rebuild 前只读捕获，并在同一 EventLog transaction 中先追加 settings+marker；Chat、Code、Cowork 实际恢复入口都不得先 rebuild 覆盖旧值。Rename 仍须 EventLog-first；不得只改 cache、目录名、`SessionID`、Envelope 或既有 JSONL。删除只允许 app-support root 的单个直接子目录，运行中 session 不得删除，也不得删除其绑定工作区内容。
- **Session settings 权威性**：`events.jsonl` 是 session settings、migration、agent/lease 登记与运行状态的唯一 durable 权威。`session_settings_updated` 必须是版本化全快照并保持严格、overflow-safe 的 revision/previousRevision、session/kind/schema 校验；Cowork canonical writer 不得写 legacy `defaultProviderID`。append 返回值和 subscriber 必须发布从实际落盘 bytes 反解的 canonical Envelope，不得发布会与 replay 分叉的编码前对象。`<session>/session.json` 只是 schema-v2、secret-free、可删除重建的派生投影；refresh 必须用完整 EventLog fold 验证。unknown future event、wrong-session、非法 revision/schema 或写后校验失败时必须拒绝覆盖；历史 main recovery 初检与最终 CAS 也必须复用同一严格 fold。
- **模型会话改名边界**：`rename_session` 的 model schema 只能接受 `name`，不得接受 SessionID、SessionKind、路径、operation ID 或任意目标选择字段；宿主必须把服务绑定到当前 runtime 的 EventLog/kind，并把 durable execution ID 作为唯一 operation ID。Code root与Cowork exact root `@main`可用，reviewer和Chat不可用。当前固定App Server要求所有fork共享dynamic tool surface，所以worker、spawn coordinator和普通descendant可能看见该schema；不得为隐藏它另写adapter，也不得把“可见”等同授权。developer instructions必须明确child永不调用，host必须在任何audit/authorization/execution前按verified child identity hard deny。它必须经过 strict schema、ToolRegistry/CapabilityLease、PermissionEngine、durable prepare/settle 与 `tool_result`；只有 exact current-session/no-path/no-network/no-data-effect intent 可 deterministic low-risk allow，near-miss/locked 调用不能复用。raw 名称不得进入 durable tool-call args或raw-value digest，且必须在 authorization/prepared 前 secret-scan。operation ID first-write-wins：exact retry 幂等，冲突 payload fail closed，旧 operation retry 不能覆盖更晚 rename；`session.json` 与窗口列表只消费 verified EventLog projection。只有authoritative tool list含该工具时，首项用户任务提示才要求工作完成验证或真实blocker后、final前调用一次；后续仅响应明确改名。Cowork必须先改名，再调用`finish_run`/`stop_run`。
  Code/Cowork 第一轮改名只能通过既有 system prompt 要求模型在任务完成后调用，不得另加宿主自动触发器、
  隐藏标题请求或跨 turn 状态机。提示必须以 authoritative tool list 为条件；当前共享提示到达child时必须
  明确说明它永不调用，不能依赖隐藏文字或schema。标题不得是日期、时间、SessionID 或泛化占位词。
  Cowork exact `@main` 必须先把改名作为最后一个非 run-control call，
  再按既有 run 终态合同调用 `finish_run` / `stop_run`。
- **Chat 自动命名边界**：自动标题只能由成功完成的 Chat 回合触发，必须保持为宿主侧独立、无工具、
  无 web search 的 metadata request；不得给 Chat 添加 ToolRegistry/AgentLoop/PermissionEngine，亦不得
  从 Code/Cowork 入口调用自动 set-if-absent API。必须复用触发回合冻结的 exact provider/model 与
  durable completed terminal seq；后台上下文只能读取该 seq 及以前的 EventLog，旧 route 不得读取
  后续 route 的回合，
  不得另选隐藏模型或把标题 request/response 写入 conversation messages、turn stats、错误事件、
  `isBusy`/Stop。资格只能来自 complete-known EventLog 和可证明串行的最早三个 completed Chat
  segment；歧义必须 fail closed。每进程、每 SessionID 最多三个逻辑 generation；只有同步调用
  `provider.stream` 才能消费 attempt，prepare/ineligible/already-named/pre-dispatch cancel 均不得计次。
  `ChatProvider.stream` 必须 prompt-return request-owned stream，并把 consumer termination 传播给
  producer；不得引入会在该同步入口执行永久阻塞 I/O 的 conformer。
  标题 collector 必须允许 usage metadata 位于唯一 done 的前面或后面；done 后任何正文、citation、第二个
  done 或缺少正常 EOF 都必须拒绝，不能因兼容尾随 usage 而放宽标题正文协议。
  attempt ledger 不得
  因同 session runtime 重建而重置；同 session 保持 single-flight，关闭围栏后旧 binding 不得复活或
  阻塞 fresh binding。输出必须按冻结 stream/格式/敏感内容合同 accept-or-reject，禁止截短、补前缀、
  二次 AI 清洗或语义改写。持久化必须在 EventLog 跨进程锁内 Chat-only set-if-absent，source 保持 nil
  兼容，随后 rebuild/read-back `session.json`；只有 verified exact projection 可发 callback。手工 Rename
  永远优先，automatic settings event 不得提升 recent-session activity；失败、取消、timeout、no-op、
  append/rebuild/read-back failure 均不得污染已成功 Chat 回合或发布伪 commit。macOS/iOS 通知必须按
  exact SessionID + revision/seq 水位处理，迟到 A 不得覆盖当前 B。
- **Cowork project settings**：Cowork per-session project metadata 必须通过 `session_settings_updated` 保存到 EventLog；UserDefaults `intatis.cowork.projectSettings.<sessionID>` 及旧 bookmark/path key 只作一次性迁移输入。settings 只能保存 sessionID、主 agent 名称、未来新 agent exact inference binding、默认权限 profile、可选 token budget 与 secret-free workspace path/agent/primary metadata；不得保存 bookmark bytes、API key、raw endpoint、完整 request options/响应/转写或秘密内容。修改 default 只影响未来 agent，不得动态重写现有 agent、queued/running task、控制面 provider 或授予 lease。Cowork composer 的模型选择器只能展示 host-approved、secret-free current profile options，并暂存“下一次 `@main`”选择；选择动作本身不得 live rebind，忙时也不得禁用。只有按下 Send 才把当时的 exact binding 冻结进该 submission，FIFO 到达空闲执行边界后才允许 host-only rebind `@main`。不得复用 Chat/Code 的 session-global provider selection，也不得连带修改既有 worker、控制面 binding、当前任务或 future-agent default。
- **Workspace bookmark capability**：Apple security-scoped bookmark bytes 只能保存在 session-owned `<session>/workspace-access.plist` schema v1 binary plist；必须 `0600`、稳定 no-follow cross-process lock、owner-only atomic replace、file fsync + parent-directory fsync、session/path/schema/单一-primary/写后等值校验。EventLog、`session.json`、UserDefaults 和 UI projection 不得复制 bookmark bytes。macOS 必须让 `WorkspaceAccessLease` 从 bookmark 解析所得的 scoped URL start access，在完整 Code/Cowork 使用期保留并在 teardown 后 stop。共享 path 不得由最后写入的单个 agent 冒充唯一 owner；Agent/目录移除必须先 durable persist 新 settings，再只删除 settings + live roster 均零引用的非-primary capability，任何 canonical identity 无法证明时都保留。primary 必须在 UI、业务方法和 store 默认拒删；底层绕过只允许新建/重授权事务尚未成立时的显式回滚，不得供普通项目目录删除调用。
- **Fresh Cowork bootstrap**：唯一无需普通模型审批的初始路径是 brand-new empty session 的严格 settings-first 七事件合同：settings；`@main` workspace/capability/agent；`@permission-reviewer` workspace/capability/agent，连续 `seq 0...6`。两 agent 共享 canonical workspace，但 host 必须分别传入 main 与 reviewer exact binding；bootstrap 不得从 main/session/default 推导 reviewer。identity 和 leases 必须不同；reviewer 必须 read-only、空工具、无 communication/delegation、depth 0。任何事件存在、非空 roster、binding/profile mismatch、路径/sensitive-root/root-identity 问题或持久化失败都必须 fail closed；bootstrap 不得调用模型/provider，也不能被普通 attach/spawn/tool/recovery 复用。
- **Legacy session migration**：共享旧 path→bookmark map 只有在当前 session 存在 legacy ownership evidence 时才可消费。必须先 exact-resolve binding，迁移并验证全部必需 workspace bookmark、primary 语义和 capability 文件。旧 symlink spelling 只能在 bookmark security scope 已启用后 canonicalize/比较；验证成功后先把 canonical path 作为新 settings revision 写入 EventLog，再 durable append migration marker，最后才清理旧 key。marker 前崩溃必须可重试；任一 required item 失败保留输入，marker 后不得回退全局 map 补回 plist。
- **user_message 与 `/goal` 兼容性**：`UserMessagePayload.text` 是送入模型的清洗后文本；v0.12 追加的 `tags` / `goal`、附件 `attachments` 和 Cowork next-main 的 `mainAgentInferenceBinding` 必须保持可选、追加式演进，不得让旧 JSONL 缺字段解码失败。`attachments` 只能保存 session ArtifactID，绝不能保存文件 bytes、base64、bookmark 或路径；`mainAgentInferenceBinding` 只能保存 secret-free exact binding，Chat、legacy Cowork 和直接发给 ordinary worker 的消息必须允许为 `nil`。Chat / Code 的 `/goal` 仍只产生 Goal 标签元数据；Cowork 的 `/goal` 必须创建独立 durable Goal/ContinuationRun 事件并由宿主续跑，不能退化为 user-message 标签，也不能改写旧 Envelope shape 或 provider 线协议。
- **Chat web-search citation 兼容性**：`message_completed.citations` 只能作为 optional additive 字段演进，旧 JSONL 缺字段必须继续解码。citation 必须来自 provider 的结构化 URL annotation，只接受带 host、无 user-info 的 HTTP(S) URL并按 URL 去重；UI 创建 `Link` 前必须再次验证。不得从 assistant Markdown 猜测 citation，也不得把 citations 复用为本地浏览器权限、Tool call、自动打开页面或 iOS Tools/AgentKernel linkage。只有 exact route 实际使用托管搜索并返回结构化 annotation 时才可产生 citations；普通 Chat、模型未调用搜索或静默省略搜索时必须保持空值且不得显示空 Sources。
- **Chat hosted-search capability 与模型自主选择**：托管搜索只属于用户当前选择的 exact Chat route，不是 Send 前置条件。宿主只有在该 route 的 exact request adapter 已实现受审 provider dialect、且 exact model/endpoint 有明确 `hosted_web_search` 能力依据时才可声明搜索；随后必须使用 `tool_choice: auto` 让当前模型决定是否调用，不得由宿主强制执行。OpenAI native `web_search`、OpenRouter `openrouter:web_search` 与未来厂商协议必须分别实现；`@ai-sdk/openai-compatible`、`responsesEndpoint`、provider/model 名称、URL 或现有 MCP `Capability.toolSearch` 均不能自动证明支持。
- **Chat hosted-search 静默降级与路由边界**：当前 exact Chat route 明确不支持、未声明、未知或 dialect 尚未实现时，必须在同一 provider/model/variant 上省略全部搜索字段；不得显示 toast/banner/错误/状态/提示词，不得切换 provider/model，也不得调用通用 Intatis search tool、`web_fetch`、`browser_search`、本地浏览器、MCP 或第三方搜索后端。`web_search_model` / `webSearchModel` 的运行时路由语义已取消：兼容 decoder 可保留旧字段，但 runtime 必须忽略、新生成配置不得主动写入、UI 不得警告。只有 exact adapter 以 typed provider-specific 响应证明“搜索不受支持”且尚未接受任何有效 payload 时，才可在同一路由至多重发一次普通 Chat；不得匹配自由文本或任意 404 推断。其他错误及 partial payload 后失败继续走 sanitized provider error，不得重放。`provider.only`、`allow_fallbacks`、`require_parameters` 等路由选项必须保真，禁止为绕过搜索兼容错误而放宽。
- **turn_stats 兼容性**：token/耗时统计必须继续通过 `turn_stats` append-only 事件传播。`cachedPromptTokens` / `contextWindowTokens` / `turnID` / `responseMessageID` 等细节只能作为可选追加字段演进，旧 JSONL 缺字段必须继续解码。逐回复 UI 只能把 non-nil `responseMessageID` 精确匹配到 assistant/agent message；必须同时支持 message-first 与 stats-first 事件顺序，旧 unbound stats 只可继续支持 latest session/context，禁止按相邻事件、agent 名称、正文、当前 selection 或时间猜测消息归属。GUI 只能消费 `TurnStatsProjection`、`ConversationProjection`、`CodeProjection` 或等价事件投影，不得解析 transcript 文本、SSE 原文或 UI 文案来推断 token。endpoint usage 为空是合法状态，GUI 应降级显示可证明的 total wall time 或隐藏对应指标；cached/context 字段缺失时不得编造数值。同一次 provider 响应里的多个 usage chunk 应字段级合并，不能用后一个 nil 字段抹掉前值；Agent 工具循环中的多个模型请求应按请求累计，不能把同一响应里的补充 usage 重复相加。macOS composer 只保留 conversation Context；Input/Cached/Output/Time 只能出现在 exact reply footer。iOS Chat 在独立迁移前继续保留完整 latest-turn composer usage。
- **ArtifactStore**：blobs 在 `<root>/blobs/<id>.<safe-ext>`，索引在 `<root>/index.json`（`[ArtifactRef]`），日期继续使用 ISO-8601、索引继续保持 pretty JSON 兼容。root/blobs 必须是当前 UID 拥有、非 symlink、非 group/other writable 的真实目录；blob/index/lock 必须是单链接 owner-only regular file，leaf no-follow。历史可信 `0644` 文件可在 exact store path 显式收紧为 `0600`，`0664`、symlink、hardlink 或异常 inode 必须 fail closed。写入必须在稳定 owner-only lock 下 read-merge-write、fsync temp/rename/parent 并读回验证；跨实例/跨进程不得丢索引项。扩展名只允许短 ASCII 字母数字，unsafe 值归一为 `bin`；对 rename 后 durability 无法证明的情况必须返回 `commitUncertain`，不得宣称 clean rollback。
- **macOS Chat/Code/Cowork composer 附件**：三者必须复用同一 security-scoped 文件读取、ArtifactStore 保存/读回校验与附件 accessory；文件只有在 durable add 且读回一致后才能成为 draft attachment。Send 冻结当时的附件 ID，EventLog 只写 ArtifactID；当前轮和受支持的 stable 历史轮都必须从同一 session ArtifactStore 解析，只有经 bounded resolver 完整验证的 PNG/JPEG 可转换为 Agent provider image。导入/读回失败或 durable admission 前失败必须 fail closed 并保留既有草稿；一旦对应 user intent 已 durable accepted，草稿可按既有发送合同清除，随后 AgentLoop 的缺失、不可读、类型不支持或 route capability 失败必须保留 accepted intent 并 typed fail，不能把它伪装成未发送草稿、静默丢图或只在首轮传图。macOS Chat 不得恢复独立的提示词生图 composer action/runtime wiring；旧 `artifact_added` / `artifact_progress` 与缺 `attachments` 的历史 JSONL 必须继续解码和回放。该能力不得扩张 iOS 的产品边界，也不得把 Agent `generate_image` / `edit_image` 工具改成无权限的 Chat 快捷功能。
- **Cowork submitted intent**：一次 Send 必须先冻结 immutable payload 并分配稳定 `SubmissionID`；面向 `@main` 的普通消息与 durable Goal 还必须冻结按钮按下瞬间的 exact `mainAgentInferenceBinding`，连续排队提交不得共享一个后读的 mutable selector 值。该协议字段虽为 legacy-compatible optional，但新式 main/Goal Send 缺值必须保留草稿并拒绝 admission。以 session-owned owner-only schema-v1 outbox 作为 canonical append 前的 crash-safe 暂存；随后用同一 EventLog transaction 写入且只写一次 `user_message + submission_status_changed(queued, attempt 1)`，成功后才清 outbox。相同 submission first-write-wins，payload 不得重写；状态 attempt 从 1 开始、单调且不可跳号/回退/重写 terminal，orphan status 必须拒绝。Goal 必须 durable 保存同一 binding，所有 host continuation/restart 都不得改读 mutable live/default。FIFO 执行时，可选 main rebind 与本次 root created/assigned/queued 必须在一个 admission lock 和 EventLog batch 内提交，live roster 只能在成功后更新。显式Retry必须由canonical task状态规划：outbox canonicalization保持attempt 1；restored queued exact task不递增或重写queued，直接交回Orchestrator恢复；restored running若已被durable requeue，只对齐该下一exact attempt；created/assigned/running、attempt不一致或身份不一致必须fail closed。failed/cancelled root没有Run时仍可递增原submission/task attempt；一旦其ContinuationRun已terminal，Retry不得调用`Orchestrator.retry`或复活旧Run，必须经同一个outbox/EventLog admission创建可见的fresh continuation message、fresh SubmissionID/root/Run，并复用原冻结`mainAgentInferenceBinding`。不得复制one-shot external context或把旧失败改写成成功；旧Run和旧submission保持terminal，SharedUI只给当前thread最新submitted intent提供Retry按钮。执行前若冻结 binding 不再 host-approved/可解析，必须明确失败且不得 fallback；direct worker submission 不得触发 main rebind。GUI 恢复出的 queued/running root submission 必须显示 paused/interrupted，只有同一提交的显式 Retry 才可释放；无关新提交不得批量唤醒旧任务。
- **GUI config**：UserDefaults 规范主键为 `translatis.providerCatalog.v1`（mac/iOS 共用），保存 provider/model 两层元数据：provider `baseURL` + `chatEndpoint` + secret ref 元数据、model id + 展示名；当前聊天选择另存 `translatis.providerSelection.v1`，macOS 可保存 provider/model/variant identity，iOS 保存 provider/model identity。Base URL 与 Chat endpoint 需要保持同步：Base URL 自动补 `/chat/completions` 生成 Chat endpoint；Chat endpoint 清洗 `/chat/completions` 后缀回填 Base URL。旧 `translatis.baseURL`、`translatis.model` 仅作为迁移来源/兼容镜像，不得作为唯一新状态。macOS 高级 JSON/JSONC 配置只允许 `TRANSLATIS_CONFIG` 显式指定文件、`~/.config/translatis/intatis.json` / `intatis.jsonc`、app support `intatis.json` / `intatis.jsonc`，旧 Intatis `config.json` 仅作兜底兼容读取；不得自动发现名为 `opencode.json` 的文件或读取 OpenCode app 配置。配置内容可采用 OpenCode-compatible 顶层 `$schema` / `enabled_providers` / `model` + `provider` map，但文件所有权、默认路径和生成文件名必须属于 Intatis。聊天页当前选择可覆盖 JSON 顶层 `model` 且不得自动改写外部 JSON；模板不得回退到直接输出内部 `providers` 数组。
- **Image model config**：macOS/modern CLI 顶层 canonical 字段是 `image_model`，`imageModel`
  只能作为兼容 alias；新模板/保存不得新增 camelCase。该字段必须只配置宿主
  `ResolvedModels.imageGen`，不得改写 Chat/Code/Cowork exact inference binding，也不得把专用
  image model 强制加入推理模型菜单。显式引用的 image-only provider 可保留空 `models`，但 provider
  route、HTTP(S) Base URL 与 credential reference 仍须完整。`generate_image` / `edit_image` schema
  均不得加入 provider/model 参数；字段缺失必须明确 fail closed，禁止恢复 `dall-e-3` 或其他隐藏
  fallback。当前 generation/edit wire 分别为 OpenAI-compatible `images/generations` 与 multipart
  `images/edits`；输入图片只能通过 `edit_image.imagePath` 的受审工作区资源上传，不能偷偷塞进 prompt
  或未审查 payload。扩展 mask、多参考图、URL 输入或其他编辑参数前，必须同步扩展 provider protocol、
  schema、权限/持久化边界和测试。
  shipping Code/Cowork/CLI必须由`CodexBusinessToolHost`在fresh
  `thread/start.dynamicTools`发布两个工具，并在`item/tool/call`时使用verified AgentID、exact workspace与
  同名capability；read-only/unknown/cross-root child必须在permission/audit/executor前拒绝。旧Loop同名工具
  的存在不是shipping证据。两个工具的normalized arguments必须在任何permission request、execution
  prepare或provider dispatch前通过`SecretScanner`；命中时只写固定secret-free denial，不能把raw prompt
  送给reviewer/provider或写入Intatis durable audit。改变这两个descriptor、capability或toolset时必须提升
  当前Codex runtime generation/session salt，旧toolset不得静默复用。
- **Composer voice / transcription config**：macOS 与 iOS 输入栏语音转写的唯一配置入口是顶层
  canonical `transcription_model`，格式为 `<provider>/<model-id>`；不得新增 camelCase alias、独立
  设置页、第二套模型目录或把 route 写进 EventLog/session。该字段只设置
  `ResolvedModels.transcription`，不得改写 Chat/Code/Cowork exact inference binding。显式引用的
  transcription-only provider 可保留空 `models` 且不得进入推理菜单；字段缺失、route 无效或 provider
  不兼容时必须 fail closed，禁止回退当前 Chat model、`whisper-1` 或其他隐藏默认值。macOS 高级配置
  与 iOS 用户显式 Files import 都必须保留同一 exact route；当前 wire 是 OpenAI-compatible multipart
  `audio/transcriptions`，exact `@openrouter/ai-sdk-provider` route 另使用官方 JSON-base64
  `input_audio` 同 endpoint；方言只能由 exact request adapter 选择，不得从 display name 或 URL 猜测。
  recorded-file runtime 固定使用 WAV/16 kHz/mono，M4A 兼容设置也不得恢复硬编码
  `AVEncoderBitRateKey`。录音开始前必须验证 runtime adapter 并冻结 route，credential 仅在转写请求
  边界懒加载。临时音频和 request body 必须 owner-only、随机命名、有 stale cleanup 与 120 秒/25 MiB
  边界，并在成功、失败、取消与 runtime shutdown 后删除；stop/upload 前拒绝空文件、symlink、非普通
  文件、非法扩展和超限内容。多 runtime 只能由一个进程级 microphone lease 同时录音，取消/迟到权限
  回调不得复活旧 generation。转写只更新 composer draft，在用户真正 Send 前不得写 EventLog、
  ArtifactStore 或 projection，也不得自动发送。不得为此迁入 Flotis 多模型对比、第二设置页、全局
  快捷键、review/clipboard 或输入法 target。shipping Developer ID target 必须同时保留
  `NSMicrophoneUsageDescription`、系统 TCC 请求和 Hardened Runtime 最小
  `com.apple.security.device.audio-input=true`；不得借语音输入启用 App Sandbox、放宽其他 entitlement
  或重新引入已删除的 `TranslatisMacAppStore` target。
- **iOS config import**：iOS 只能经用户显式操作的系统 Files picker 导入 Translatis JSON/JSONC，不得扫描 macOS home/config 路径、持续持有外部 security scope、监视或改写原文件。共享 importer 必须保持文件/数量/字符串/URL 边界与 secret-aware 投影，只把 Chat 子集复制到 app-owned schema-versioned protected snapshot；literal `options.apiKey` 必须先迁入 protected auth JSON，再让新配置生效，且不得进入 snapshot、UserDefaults、日志或 UI。env/file 引用可保留但必须提示 iOS 可用性需要复核。base model raw options、exact npm adapter 与 capability metadata不得因导入而丢失；unsupported adapter 继续在网络前 fail closed。variants 在 iOS 支持落地前不得静默任选或伪装已导入，必须忽略并显示明确 warning。iOS thread-only root 必须由 host 持有唯一 `NavigationStack`，确保顶部 sidebar/session/new、抽屉 Recent/Settings、底部 model/usage + input composer 和 Settings sheet 在已有 key 时仍可达；不得以“无 key 自动弹 sheet”替代 Settings 入口，紧凑宽度下 model label 也不得遮挡或挤出第二排 controls。导入路径不得让 iOS 链接 Tools、Permission、AgentKernel、Cowork、shell 或 workspace runtime。
- **Chat/Code model request options**：兼容 `ProviderEndpoint` 路径中的 `provider.<id>.models.<model>.options` 是开放 JSON 请求扩展，不得按已知 provider/字段白名单解码后丢弃未知值。选中 model 的 options 必须按 model ID 到达 wire adapter；Chat 与 Code Agent 路径行为一致。`models.<model>.variants.<variant>` 是同一真实 model 的命名请求参数预设；选择 variant 后必须保留真实 model ID，只以 variant 原始字段浅覆盖基础 options，且不得把本地 `disabled` 控制字段发给 provider。顶层 `model` 必须先尝试匹配启用 provider 的完整 model key，未命中才按 `provider/model` 拆分，不能把 model ID 自身的 `/` 无条件误判为 Intatis provider 分隔符。只能由 Intatis 覆盖 `model` / `messages` / `tools` / `stream` 等真实运行时结构字段；OpenAI-compatible builder 必须移除配置 `stream_options` 与 `n` / `best_of` / `num_return_sequences` / `candidate_count`，且仅允许 host `includeUsage` 重建受控 usage shape。新式 package adapter 必须按 pinned OpenCode package 省略 `n`，不得从 parallel-safe tool metadata 自动合成 `parallel_tool_calls`；legacy wire 可保留显式 `n = 1` 与 call-level parallel 开关。单次 runtime 显式值只能在 exact adapter 支持的边界内覆盖配置默认。provider-level endpoint/auth 配置不得混入 body，model/variant options 不得镜像到 UserDefaults、EventLog 或日志；API key、Authorization 与其他 secret 仍遵守秘密边界。此开放契约不得套用到 Cowork durable catalog。
- **Provider options 只由 exact package adapter 降级**：配置解析、variant merge、immutable profile 与 UI 展示必须保留原始 `provider.npm`、model `provider.npm`、`reasoningEffort` / `reasoning_effort` / nested `reasoning.effort`，不得回写用户 JSON/JSONC。禁止恢复跨 provider 的全局 camel/snake/nested 优先级。新 OpenCode-shaped custom provider 真正缺少 npm 时必须显式冻结 `@ai-sdk/openai-compatible`；model override 优先于 provider。显式空串或空白 npm 不是“缺失”，必须保留 exact identity并在网络前fail closed。Compatible adapter 才可按其 pinned SDK 语义把camel `reasoningEffort`生成snake `reasoning_effort`，且必须保留独立nested reasoning与完整`options.provider`；OpenRouter adapter使用自己的nested reasoning语义，并由Codex Runtime把该provider object作为request-owned opaque JSON透传。未知或未实现npm adapter必须在网络前fail closed，不得按endpoint/provider名称猜测、不得静默回退compatible，也不得为绕过路由错误关闭strict routing。历史缺adapter的durable值须保持legacy decode/fingerprint。
- **Config presentation is read-only**：模型 UI 可以识别 `reasoning_effort` / `reasoningEffort` / nested `reasoning.effort` / `output_config.effort` / thinking level 或 token budget 等常见拼写，但只可展示配置中的原始值。展示投影不得改写 key/value、不得转换 provider 协议、不得回写 JSON/JSONC、不得覆盖 request options；未知 model-level metadata 必须在内存保留。没有显式 selected variant 时不得从 `variants` 中任选一个 effort 显示为当前活动值。provider/model/variant 选择状态只能是指向配置条目的 identity，不得复制第二套模型参数；variant 参数来源始终是当前配置文件。
- **Per-agent inference catalog**：Cowork connection/profile 定义必须以 exact ID + revision 进入 versioned immutable `InferenceCatalog`；endpoint、wire、credential reference、trust metadata、model、variant、有效 options 或 declared capabilities 的语义变化都必须追加 revision并保留旧 revision，不得原地改写。current reference 只供未来 binding，不能成为现有 agent 的动态指针。macOS connection/trust identity 必须保持 opaque、不得编码 raw URL；CLI connection/trust/credential reference 必须按 route identity 隔离，不能让不同 endpoint 共用模糊 credential account。`InferenceCatalogStore` 遇到 corruption、未知 schema、过大文件或非 owner-only 权限必须 fail closed 且不得覆盖原文件；写入必须保持 owner-only 临时文件和原子替换。Reconcile 的旧值读取、revision 分配、校验和替换必须处于同一 mutation 临界区；同进程 store instances 不得利用 POSIX process-scoped lock 发生重入，跨进程必须在稳定 sidecar inode 上互斥。Sidecar 必须 no-follow/close-on-exec、当前用户所有、`0600`、普通且单链接；不得删除后重建来绕过锁、自动修复不安全既有锁，或在不支持真实跨进程锁的平台退回无锁写入。当前仅支持 OpenAI-compatible wire，不能因配置声明其他 wire 就假装可执行。
- **Exact inference binding 与兼容性**：`AgentInferenceBinding`、`TaskContract.agentInferenceBinding`、agent lifecycle/turn-stats/authorization 中的 inference 字段只能追加式、可选演进，旧 JSONL 缺字段必须继续解码为 unresolved。Live strict Cowork 必须逐项核对 exact profile/connection revision、model/opaque durable variant、安全 route label/trust domain/egress classification 与 opaque definition digest；macOS/CLI raw variant config key 只能留在 local presentation selector，不能进入 binding/EventLog。Revision 缺失、definition 被原地改写、binding mismatch、unsupported wire 或显式声明能力不兼容时，必须在 secret/network access 前 fail closed。不得回退 catalog current、session default、同名 model、同 provider 或任意“最接近”配置；不得把 legacy unresolved agent 自动绑定到当前默认。
- **Atomic inference resolution 与 TOCTOU**：shipping strict Cowork 只能通过一次 resolver 调用获得 `binding + model + provider`，不得先返回 provider、再从另一份 mutable state 查询 binding/model。`requiresInferenceBindings = true` 必须拒绝 provider-only public runtime factory；Orchestrator 在 admission/preflight/dispatch 复核 `Agent.model == binding.modelID`、resolved binding 全等和 resolved model 全等。Catalog candidate update 与 attach/spawn/delegate/rebind 必须共享 admission lock；锁外 async exact resolve 返回后必须重新核对 host-approved map、live roster/current binding 与 authorization fingerprint。Reviewed delegation 必须把 authorization、catalog snapshot、target binding/model/workspace/fingerprint 和 caller leases 贯穿 Mediator/resolve await 到最终 admission；target reservation 必须阻止 rebind。`delegate_task` 不得创建 agent，只能选择已经 attached 的 data-plane target；需要新 agent 时由独立 `spawn_agent` 调用完成，且必须等待其成功 ToolResult 后才能委派。最终 lock 内复核通过且 `TaskContract` binding 等于 reviewed binding 后，才可用一个 EventLog batch 原子提交委派事实并入队。AgentLoop 的 execution revalidation hook 必须在 durable tool prepare 前完成 profile resolve，并在 `await` 返回后再次校验，不能让 catalog/roster 在 suspension 期间变化后仍写入 prepared ticket。Ordinary attach 在 permission review `await` 返回后必须再次 exact-resolve，并比较 review 前、resolve 前与 commit 前的 host-approved catalog snapshot；fresh `bootstrapMainAgent` 不经过模型 review，但必须在 admission wait 前后复核空 roster/EventLog、在锁外二次 resolve，并在锁内复核 exact catalog snapshot 后才 durable admission。macOS、CLI 与生产 self-test 不得绕过该 seam；internal legacy provider seam 只能留给 isolated `@testable` fixture。
- **Inference recovery 与隔离门禁**：GUI 与 CLI 的恢复门禁必须分开。GUI 的 durable `@main` exact resolution、reviewer/control-plane readiness 与 Goal recovery 是提交后的执行状态，不得成为 composer/本地 admission gate；释放新工作时必须继续把前一进程恢复出的 root tasks 围栏为 paused/interrupted，只有该 submission 的显式 Retry 才可释放对应历史 task，不能用普通启动或无关新消息整批 `resumePendingTasks`。CLI 仍保留自己的显式 `/auto|/default` 与 data-plane resume 边界。不得把任一 ordinary worker unresolved 升格为全局 scheduler pause，否则它的 queued task 会与 idle-only rebind busy fence 形成死锁。Scheduler 必须允许其他 agents 继续运行，并让该 worker 的 queued invocation 在 provider request 前因 exact-resolution 失败而 durable failed、撤销 task lease、清除 active/queued fence；host 随后才能显式 rebind。历史 session 缺失 durable `@main` 时不得套 current default：GUI 只能从 canonical settings/roster 走 host-authorized exact historical-main recovery，并在 main 成功后 replacement/retry reviewer；CLI 只能由 host 显式 `/agent restore-main <path> <profile-id>` 走专用历史恢复入口，再显式启用控制面。恢复登记不得调用模型。历史 active Goal 冷启动只可 reconcile/checkpoint/audit 后 durable pause（或 budget-limit）；只有显式 Resume 才可创建 continuation。Modern CLI 的 unqualified model 只能在唯一 route 匹配时自动选择；explicit reasoning 无 matching configured variant/base effort 时 fail closed，不得合成 profile。
- **Cowork durable inference options 与安全投影**：catalog 编译保持 connection defaults → model base → variant → profile overrides 的 deep merge；仅两侧都是 plain object 时递归，array/scalar/null 由后层整体替换。调用阶段保持 resolved options → exact package adapter lowering → 受限 invocation values → clamp → runtime structural fields 的优先级。Connection/profile 必须把 provider/model adapter 作为 immutable 语义冻结；adapter 变化必须产生新 revision，旧缺字段值仍保持 legacy identity。Bound Cowork agent 的 reasoning/options 由 profile 所有，session-wide effort 不得覆盖。Durable connection 的 HTTP(S) base/chat URL 必须拒绝 user-info、query 与 fragment，不能把凭据或路由 material 藏入 URL。Durable schema 对 sampling/token/logprob、reasoning/thinking/output_config与其他top-level字段继续显式allowlist；exact `options.provider`子树作为provider-owned opaque JSON例外，不枚举future keys，但必须先递归拒绝secret/auth/header/query/URL/endpoint transport material并满足depth/object/array/string有限结构边界。provider子树以外的unknown key、错误shape、runtime structural、stream与multi-candidate fields继续fail closed。所有 Chat/Agent request 还必须无条件移除配置 `stream_options` 和候选数量控制；新式 package adapter 省略 `n` 并禁止从 tool metadata 自动合成 `parallel_tool_calls`，legacy wire 才保留旧显式控制。host output-token ceiling 另按 normalized key（忽略大小写和常见分隔符）移除竞争 token aliases并写入 host ceiling。Binding/EventLog/permission preview/roster/UI/错误文案不得包含 raw endpoint、credential value/ref 细节、headers、query 或 arbitrary options；只允许 exact identity/revision、model/variant、安全 route/trust/egress 分类和不可逆 digest 等安全字段。Credential value 只按 exact connection revision 的 reference 在真实 provider 请求边界懒加载；CLI 不得用 selected route 的 key 替换其他 route 或旧 revision，definition digest 不得在文档、UI 或日志中输出完整实际值。
- **Provider config 路径引用**：`providerConfig` secret ref 只能读取当前 Translatis 自有 `intatis.json/jsonc`、旧 Intatis `config.json/jsonc` 或用户本次显式 `TRANSLATIS_CONFIG` 指定文件；历史 UserDefaults 中其他绝对路径必须 fail closed，不能借旧元数据恢复对 `opencode.json` 或第三方配置的隐式读取。
- **Provider 线协议**：OpenAI 兼容 HTTP/SSE（`/chat/completions` streaming）。`WireFormat.openai` 是唯一 shipped 格式。
- **Provider tool-call delta 兼容**：tool-calling streaming 必须继续归一到既有 `ToolCall`，不得改事件 schema 或绕过权限门。解析器应保留对缺失单工具 `index`、字符串 `index`、非字符串 JSON `function.arguments` 的兼容；JSON arguments 必须作为 JSON 字符串进入工具参数解析，不得用描述性文本替代。Chat/tool-calling streaming 不得只消费 `choices.first`；同一 SSE chunk 中非首个 choice 的 content、tool_calls 与 `finish_reason` 也必须被处理，且多 choice 同时出现 `stop` 与 `tool_calls` / `function_call` 时不得把工具轮降级成普通文本完成。若 provider 以 `tool_calls` / 旧式 `function_call` finish reason 结束但未发出完整 tool-call delta 或缺 tool name，或已发出 tool-call delta 后错误以 `stop` 结束且仍缺 tool name，不得静默丢弃并合成成功，必须暴露 provider/tool-call 兼容错误。非空累计 `function.arguments` 必须在 provider 层确认可解码为完整 JSON；截断或非法 JSON 不得下放成泛化工具输入失败，空 arguments 可继续保留以兼容无参工具。
- **Provider / runtime 错误反馈**：HTTP 非 2xx、provider error payload、malformed SSE、transport/cancellation 等错误必须通过共享 provider/runtime 错误格式化进入 `ErrorPayload` 或 `tool_result`，并可由 `ConversationProjection` / `CodeProjection` 等投影层派生恢复建议；HTTP 非 2xx 响应体只有结构化 `error`/`message`/`detail`/`error_description` 可显示为 provider message，普通 HTML/纯文本代理错误页只能显示裁剪 preview；HTTP 2xx 但 image/transcription 响应结构不符合 OpenAI-compatible payload（如缺 `data[].b64_json`、坏 base64、HTML 响应或缺 `text`）时也必须变成裁剪后的 provider decoding 错误，不得泄漏底层 `DecodingError` 或完整响应体；partial assistant/agent delta 后的错误必须保留已输出文本，并从同一个 `error` 事件投影为 stopped/recovery advice，不得新增一次性事件 shape。Provider formatter 必须先用 diagnostic sanitizer 脱敏 secret 和完整 HTTP(S) URL（普通 URL 也可能暴露私有 infrastructure），`RuntimeErrorPresentation` 还必须在任意错误成为 durable `ErrorPayload`/task-failure 事实前再次 URL/secret-redact 并限长，覆盖 custom provider 绕过 formatter 的路径；ordinary permission preview 可保留非秘密 URL 语义，不得因此改用 diagnostic scrubber。不得把完整 API 响应、raw endpoint URL、secret、未裁剪代理错误页或原始 SSE dump 写入事件日志、文档或 UI。
- **Provider endpoint URL 预校验**：OpenAI-compatible chat streaming、tool-calling streaming、image generation、transcription 在构建 `URLRequest` 时必须先确认 Chat endpoint 或 Base URL 是带 host 的 `http`/`https` URL；缺 scheme、缺 host 或 `file:` 等非 HTTP URL 必须作为 `config` 错误暴露，并可被 health check 报告，不得落到原始 URLSession/文件 URL 行为；错误文案不得包含 secret、完整 auth config 或原始响应 dump。
- **Provider redirect policy**：所有 provider HTTP transport（streaming 与 data request）遇到 300...399 必须 fail closed，不得自动跟随 `Location` 到 catalog exact connection 之外的未审查 endpoint；redirect 响应按净化后的 provider failure 处理，错误/UI/EventLog 不得输出完整 Location URL。若将来允许 redirect，必须先新增显式 route/trust/egress 授权模型与对应测试，不能依赖 URLSession 默认行为。
- **Provider retry/timeout/rate-limit headers**：Chat/tool-calling streaming、image generation、transcription 的 timeout/retry/backoff 必须走共享 `ProviderRuntimePolicy` / `ProviderRuntime`。Chat与Agent streaming默认只能是initial + 5 reconnects，退避1/2/4/8/16秒；non-streaming保持initial + 1 retry。流式重放围栏必须依据已经向consumer交付的语义输出，而不是任意socket byte或typed status：text delta、完整tool call、usage或done一旦yield就不得自动retry；收到partial后失败只能保留partial并解释停止原因。空SSE、heartbeat/status、结构化可重试error和仅在当前attempt本地累计但尚未yield的tool-call fragment可以在有界`maxAttempts`内重连。hosted-search协议unsupported fallback继续使用独立typed acceptance fence，不得把transport replay fence误用于ordinary-chat降级。取消请求不得retry，必须保持`cancelled`语义。OpenAI-compatible streaming completion 必须同时兼容 `[DONE]` 和 chunk `finish_reason`；看到 `finish_reason` 后不得立刻丢弃后续 usage chunk，且不得重复投递 done；若底层流结束时既无 `[DONE]` 也无 `finish_reason`，不得合成成功，必须抛出可投影的 completion-marker 兼容错误。HTTP `Retry-After` / rate-limit reset headers 可以用数字秒、HTTP 日期或 `750ms` / `1m30s` 等 duration 字符串影响 retry delay 和错误说明，但不得把完整 response headers、secret 或原始响应 dump 写入事件日志、文档或 UI。
- **Provider health check**：设置页 Test Provider/Health Check 必须调用共享 `ProviderRegistry.healthCheck(role:options:)` / `ProviderHealthReport`，不得在 macOS/iOS UI 里复制 provider-specific 判断。chat 与 agent health check 都应请求 usage，并复用 `turn_stats` 的 usage 合并语义。报告只能展示裁剪后的 response preview、endpoint/model/wire/耗时/usage/code/message，不得展示 secret、完整响应体或原始 SSE dump；timeout 与 partial stream 必须有明确状态；缺 `[DONE]` 但已有 `finish_reason` 的流不应误判为 partial；真正缺完成标记时应保留 preview 并报告 partial stream。
- **工具执行反馈**：工具失败仍应通过 `tool_result` observation 表达，且 GUI/CLI 应消费 `CodeProjection` / 事件投影；失败状态和恢复建议必须从结构化 `tool_result` / `ErrorPayload` 投影派生，不得通过解析 assistant transcript 文案来判断工具是否失败。已知工具的坏 JSON、非对象、缺 required 字段、基础类型错误参数、数字 `minimum`/`maximum` 约束违规、字符串 `minLength`/`maxLength` 约束违规，或被 `additionalProperties:false` schema 禁止的未知字段，必须在权限判断和工具执行前变成 `invalid tool input:` 结果；当前 shipped tool schemas 应保持 strict object shape，`read_file.maxBytes` 必须保持 `>= 1`，标准工具 path/query/command/diff 字符串必须保持非空约束，不得让坏参数通过 `try?` 默认值进入路径计算、权限请求或工具执行。
- **Tool-call 参数持久化边界**：provider/model 输出的 raw tool arguments 必须在 `.tool_call` append 前分类，不能先落盘再校验。Unknown tool、schema-invalid input 与作为 inference-control surface 的所有 `spawn_agent` 调用只能持久化固定、bounded redacted placeholder + character count/redacted flag，且不得写 raw-value digest；其他 schema-valid tool args 也必须 secret-scrub 与限长，只有未脱敏/未截断的 canonical args 才可附加 digest。`ToolCallPayload.argsDigest` / `argsCharacterCount` / `argsRedacted` 只能作为 additive optional audit metadata，旧日志缺字段继续解码；不得把含秘密/endpoint/options 的 raw input 变成可离线猜测的普通 fingerprint。endpoint、Authorization/header、api_key/token/credential、secret-shaped unknown field 或其 raw hash 不得出现在新写入的 `args`、错误、UI 或 projection 中。
- **Agent 文档工具必须保持原子、薄适配**：fresh registry 只能暴露 `inspect_pdf`、
  `read_pdf`、五个初读 + 五个 continuation、`ocr_pdf`、`pdf_render_page`、四个
  `*_export_pdf`、17 个 DOCX/7 个 PPTX/5 个 XLSX exact write tools，以及独立
  `compile_latex`；不得重新注册 `document_read` / `document_ocr` / `document_render` /
  `document_export_pdf` / `document_write`。每个 model-visible schema 必须闭合且不得包含
  `format`、`mode`、`operation(s)`、`backend`、`engine`、command/env/runtime selector。
  每个业务工具只能固定调用一个已 pin 外部官方 API/不可再分 save lifecycle，拥有独立
  PermissionIntent、execution 与 ToolResult；不得把 exact names 汇入解释 operations array 的
  generic dispatcher。共享 ToolRegistry/Permission/Lease/PathConfinement/identity/SHA/CAS/staging/
  sandbox/timeout/cancel/process cleanup/output budget/2 GiB RSS/EventLog 管线必须业务语义盲。
  Intatis 不得解析 OOXML/HTML/EPUB/PDF 正文、建立 AST、解释公式、做 recalc/preview/postcondition
  verifier 或在失败时选择另一 backend。允许的 OOXML ZIP preflight 只能检查 hostile container 的
  member path、symlink、encryption、compression 与 expansion bounds，不能读取 main part、formula、
  chart 或 vendor extension 业务语义。PDF 生成物只做 regular-file/size/signature/digest 等机械验收。
  HTML export 只能机械 stage 已冻结且受 PathConfinement 保护的 source/local assets，再直接调用
  `WKWebView.createPDF`；不得恢复 lxml sanitizer 或资源内联 parser。Tectonic 只能从 fixed runtime
  以 0.15.0 + `--untrusted --only-cached` 运行，不得探测/调用 latexmk/xelatex/pdflatex。
  LibreOffice 短路径 socket、默认断网、输入/辅助资产重验、pinned-parent no-follow commit 与 typed
  fail-closed 必须保留。legacy names/capability/intent/EventLog 只可 decode 或最窄映射 concrete tools；
  fresh lease 不得签发 legacy aggregate raw values；除 inspect/read PDF 明确共享 `readPDF` 外，
  exact capability raw value 必须与 tool name 一致，PermissionIntent action 必须保持 exact tool
  语义。v4 authorization 不得验证为 v5。shipping App 必须使用 active-architecture bundled runtime，并在
  stage 前后验证 hash/SBOM/license/architecture/load commands/RPATH/bottom-up signature；CLI/debug
  user runtime 不得成为 App fallback。缺 runtime/model/cache/version/signature proof 时必须停止能力。
  图片工具及其 provider/model/path 规则不属于本次文档迁移，不得借此更改。iOS target 不得链接
  IntatisTools 或 DocumentRuntime。
- **Agent Git control 工具**：`git_status`、`git_diff`、`git_diff_staged`、`git_info`、`git_recent_commits`、`git_diff_base`、`git_branch`、`git_create_branch`、`git_stage`、`git_unstage`、`git_commit`、`git_apply_patch_check`、`git_apply_patch`、`git_stage_patch`、`git_unstage_patch`、`git_revert_patch`、`git_worktree_list`、`git_worktree_create`、`git_worktree_remove`、`git_remotes`、`git_fetch`、`git_pull_ff`、`git_push`、`git_switch` 必须继续作为普通 Agent 工具运行，不能绕过 schema 校验、`PermissionEngine`、`PathConfinement` 或 `tool_result` 事件记录。Git read-only 工具只能观察状态/diff/ref/commit/worktree/remote metadata 或做 patch preflight；`git_create_branch`、path/patch stage/unstage、`git_commit`、`git_apply_patch`、`git_worktree_create`、`git_fetch`、`git_pull_ff` 是写入工具，必须触发写/网络权限流；`git_revert_patch`、`git_worktree_remove`、`git_push`、`git_switch` 是 destructive 工具，必须要求显式确认参数并仍走权限门，其中 `git_push` 是 destructive + network high-risk。动态 Git 参数不得拼进 shell 字符串；当前 process-backed 后端必须使用参数数组调用 `git`，并保持 repository root 与 agent workspace root 一致。普通 repo 的 git metadata 不得逃出 workspace；Intatis 受管 linked worktree 只能位于 `.translatis/git-worktrees/<name>`，且 `.git` file 只能指向 owning workspace repo 的 `worktrees/` metadata。`git_stage` / `git_unstage` 只能接受 workspace-confined paths；patch 工具必须先从 diff 解析 changed paths 并做 workspace confinement；worktree name 必须是简单安全目录名；remote Git 工具只接受已配置 remote name，不接受 URL remote/refspec，输出必须遮蔽 remote URL 中的凭据/token；`git_pull_ff` 和 `git_switch` 必须要求 clean working tree；`git_pull_ff` 只能执行 `--ff-only`；`git_push` 不得支持 force/force-with-lease，必须要求 `confirmRemote` / `confirmBranch` 精确匹配；`git_switch` 不得实现 `checkout .`、discard 或隐式创建分支。`git_commit` 必须在提交前拒绝 staged sensitive path，并保持 hooks/GPG 交互关闭。worker 默认不得获得 `gitControl` 或 `gitRemote`；coordinator lease 可暴露本地 Git control 与 remote Git control；旧 `runShell` 兼容 lease 只能暴露 Git read-only 工具。不得暗中加入 merge/rebase/reset/clean/force-push/remote auth 管理/PR/CI/review workflow；这些能力必须另做权限、UI 和测试设计。不得复制 Codex/libgit2/SwiftGit2/GitButler/Jujutsu 等外部项目源码；若未来引入依赖，必须先完成许可证和平台边界审查。
- **Agent 网络/浏览器工具**：`web_fetch`、`browser_diagnostics`、
  `browser_profiles`、`browser_profile_delete`、`browser_history` 及全部
  interactive `browser_*` 必须继续作为普通 Agent 工具运行，不能绕过 schema
  校验、`PermissionEngine`、`PathConfinement` 或 `tool_result` 事件记录。
  `web_fetch` 是网络工具；`browser_profiles`、`browser_history` 和
  `browser_downloads` 是只读 metadata 工具；其他 browser action 是专用
  broker-backed exec 工具，页面导航/headed handoff/刷新/前进/后退/交互/表单
  提交/滚动/等待/截图/上传/下载/搜索仍标记 network risk，必须先满足平台 shell
  capability，再进入网络审批。浏览器后端可优先走 Playwright，也可在其缺失时走
  Node.js 内置 `WebSocket` + Chrome DevTools Protocol fallback；两条路径都必须
  使用 workspace-confined persistent profile。同一进程内同一 workspace profile
  的命令必须串行，state/history 读写和 back/forward 真实执行不得拆出临界区；
  不同 profile 不得退化为全局互斥。profile/state/history/downloads 只能落在
  `.translatis/browser/`；截图只能写 workspace PNG，上传只能读 workspace 文件，
  download 只能写 profile 专属目录并通过 `changedFiles` 暴露。state 可保存当前
  页面 metadata 和 Intatis navigation stack/index，但不能保存 secret。
  popup/new-tab 交互应跟随到最终页面；CDP click/download 应使用真实鼠标事件。
  profile inventory/runtime marker/history/downloads 只暴露受控 metadata，不得
  读取或列出 marker/database/download content。profile 的 cookies、登录态、
  localStorage 和历史痕迹不得打印、摘要、提交、作为普通 artifact 分享或写入
  UserDefaults/文档。页面动作可返回控件 role/name/selector/options，但不得输出
  password/token/current input value；`browser_type` 必须在 Swift 与 DOM backend
  两层拒绝疑似密码/2FA/token/API key 目标并要求 `browser_handoff`，observation
  必须遮蔽输入值。不得复制 Chromium、Playwright、CEF、Browser Use、Selenium
  源码；未来引入依赖/嵌入内核须先审查许可证、体积、sandbox 与平台边界。
- **Agent 浏览器 profile 删除工具**：`browser_profile_delete` 是显式 `.destructive` 工具，必须继续要求 `confirmProfile` 与目标 `profile` 匹配，且只能删除 workspace `.translatis/browser/profiles/<profile>`、`.translatis/browser/downloads/<profile>`、`.translatis/browser/state/<profile>.json` 并剪除 `.translatis/browser/history.jsonl` 中对应 profile 的 metadata 行。删除前可检测少数 Chromium active/lock runtime marker 是否存在并输出概括提示，但不得列 marker 文件名或读取 marker 内容。不得删除 workspace 外路径、不得读取或输出 cookie/localStorage/profile 数据库/下载内容/内部文件名，不得在 worker 默认 lease 中暴露；read_only 下必须 hard deny，其他 profile 下必须进入用户/审查权限流。

- **浏览器执行 broker 不可回退**：生产浏览器 action 不得重新路由到 generic
  `structuredShell` / `networkStructuredShell`，不得接受模型或调用方提供的 raw
  shell string，也不得通过 `/bin/sh -c` 启动 Node。它只能消费 host 生成的
  typed/opaque invocation，并在任何目录创建或进程启动前同时验证 canonical root
  identity、WorkspaceLease read/write、allowed rules、mandatory denied patterns
  和完整 touched paths：profile、downloads、state、history，以及本次
  upload/screenshot path。macOS 不得用会被 Chromium helper 继承的外层 Seatbelt
  包装浏览器进程树，除非已有真实 helper sandbox-reinit 兼容证明；绝不允许用
  `--no-sandbox` 换取可运行。Linux 缺 Bubblewrap 时继续 fail closed。stdout/stderr
  必须持续 bounded drain，timeout/cancel/startup abort 必须在 DevTools port 出现
  前后都清理 child/process tree/client/active state。任何显式、state/history
  恢复或 backend-result navigation URL 都必须在 Swift + fixed driver 双层限制为
  HTTP(S)，不得让 `file:` / `data:` / `javascript:` / 自定义 scheme 进入浏览器或
  durable state。旧 `DevToolsActivePort` 只可在明确 `ENOENT` 时视为不存在；新
  marker 必须证明属于本次启动，browser/page WebSocket 必须精确绑定同一
  loopback port，且 `/json/list`、`/json/new` PUT/GET 三条 page-target 来源都须
  在连接前执行相同校验；不能采用旧代/符号链接/多链接/非当前用户 marker。

## Legacy AgentKernel/Orchestrator 协议禁区

本节直到后续明确回到通用平台/持久化不变量前，约束仓内manual-rollback源码与兼容测试，不定义shipping
Codex新turn的第二套Goal、Run、reviewer、scheduler或mailbox。shipping对应合同只以上文Codex Runtime节为准。

- **独立终态隔离**：`Goal`、Session-scoped `WorkTask`、`ContinuationRun` 与现有 `TaskContract`（产品语义为 AgentInvocation execution contract）是彼此独立的状态机。AgentInvocation completed 只能作为 WorkTask candidate/result linkage，不能自动完成 WorkTask；WorkTask completed 必须显式 `task_update` 提交 result，并在存在 acceptance criteria 时提交 agent-reported evidence；Goal completed 必须有非空、无 remaining work/blocker、每项 proven 且引用 host-derived `validationEvidence`，并逐项覆盖 objective、全部 success criteria 与 constraints（重复项也要按次数覆盖）的独立 GoalVerifier audit。UI 不得从 TaskContract objective、transcript 或子任务数量反推 WorkTask/Goal 完成。
- **Cowork root 与终态协议**：每条普通生产用户指令必须先创建 kind=`root` 的 `TaskContract`，Goal continuation 的每个 run 也必须由 host 把 scoped root invocation 放入 scheduler，再经 queue/claim 执行；不得恢复为直接调用 AgentLoop 的旁路。AgentInvocation 状态只能沿 `created → assigned → queued → running → completed|failed|cancelled` 演进，failed/cancelled 只有显式 retry 才能回到 queued；queue/start/terminal 事件必须保留 attempt。denied/failed tool call 只能作为 model-visible observation，不得登记为副作用完成债务、跨 restart 恢复，也不得在 provider 正常 final 后把整轮 cast 为失败。provider 正常完成且没有 tool call 时，final message/model-history、idle 与 `turn_outcome(completed)` 必须用一个 EventLog batch 提交。failed/interrupted outcome 必须使旧日志里因其他运行时失败而失效的完成气泡和 final assistant history 失效，但不得删除真实 user/tool history；同一 TurnID 的冲突 terminal fail closed。`maxIterations`、缺 completion marker、`length` / `max_tokens` / `content_filter` 等不完整 finish reason、timeout 与 cancellation 均不得写 `task_completed`。
- **Session-scoped WorkTask DAG 与 revision**：WorkTask 是当前 Cowork Session 内的独立记录，不含 Run、Goal、Agent 或 Turn owner；Task tools 和 UI 不得按 current Run/Goal 过滤，也不得用其他字段重建 ownership。`WorkTaskGraph` 必须拒绝当前 Session 中缺失/self/cyclic dependency、stale revision、非法状态转换、未满足依赖，以及缺少必需 result/evidence 的完成；依赖重规划必须由 host graph 在同一 durable batch 重新计算被编辑节点及下游 readiness，projection 不得接受与 DAG 不一致的 ready/pending/blocked 事件。进入 `in_progress` 后 title/description/criteria/expected artifacts/priority/dependencies 等执行契约不得再改。stable `wt_` ID 和 latest authoritative revision 不能被 UI index、聊天历史或 AgentInvocation `task_…` ID 替代。`task_create/update` reviewer preview 只能包含 bounded、脱敏语义字段，完整执行参数只用 digest/count 绑定 authorization；`task_create/update/get/list` 必须走 strict schema、PermissionIntent、CapabilityLease 与 durable EventLog。
- **WorkTask 并发写集**：write-capable invocation 入队前必须拒绝同 workspace active WorkTask 的重叠 `expectedArtifacts`；路径祖先/后代都算重叠，空/unsafe/unknown write set 必须保守视为 workspace-wide。不得因模型声称“不会冲突”而绕开，也不得把该逻辑当作 WorkspaceLease/PermissionEngine 的替代品。
- **Goal / ContinuationRun 单一 authority 与原子结算**：同一 session 同时只显示/续跑当前 durable Goal；Goal 可跨多个 ContinuationRun，默认没有 token budget，只有用户显式设置才存在。生产 create/pause/edit/resume/clear、audit 与 terminal transition 必须收口到 Orchestrator host authority，并通过 revision/state/session/Goal/run ownership 校验；普通 agent 不得创建、直接完成、暂停或清除 Goal。Cowork `/goal` 是显式 host action；普通自然语言不得由宿主分类为 Goal create intent，模型工具表与 capability lease 也不得暴露 `create_goal`。start/ordinary turn/Goal mutation/stop 必须分别遵守 single-flight、mutation 与 stop gates；pending stop 未结算前不得新建 run，shutdown 后不得接纳 ordinary turn或从失败尾部重启。Pause/Edit/Clear 必须先成功取消当前精确 run scope并 durable checkpoint；取消、stop settlement 或 checkpoint 持久化失败时不得先写 paused/edited/cleared。Goal Edit 必须 invalidate 旧 latest audit、blocker fingerprint、consecutive blocked/no-progress streak，不能让旧 objective 的证明影响新 revision。run 必须先 durable checkpoint，且每个 run 最多接受一次 audit；生产结算必须在同一 admission lock/replay 下，以一个 append batch 按顺序提交 `goal_audit_completed`、`continuation_run_completed` 与可选 Goal terminal event，禁止拆成可留下半结算状态的多个写入。Continuation 必须由 host event loop/scheduler 驱动，禁止在 AgentLoop 内同步递归续跑。
- **ContinuationRun 模型终止控制**：`finish_run` / `stop_run` 只能暴露给 exact `@main`、issuer=nil、带 current RunID 的 root invocation，且必须有不可派生给 worker/child/mailbox/reviewer 的 `controlRun` capability。模型参数不得包含任何 identity，只能提交 completed/stopped 与有界 reason；session/run/Goal/submission/root TaskID/source 必须从宿主上下文注入。工具照常经过 strict schema、PermissionEngine 与 durable tool ticket。close installation 必须先形成 actor-local tombstone，使重入 admission 和已审批但未执行的同 run 工具 fail closed；EventLog first-write claim 必须先于等待旧 admission、provider/tool cleanup 与 exact-run drain 落盘，任何其他 run 不得被连带取消。允许当前 root 在成功工具结果后返回一次 final；之后所有同 run 工具/消息/admission 都须观察 fence。普通自然语言 final 不能被猜测为显式 close claim；root failure/timeout、用户取消、session lifecycle shutdown 必须分别保留 runtime/user/hostLifecycle typed source。恢复必须在 mailbox wake/provider dispatch 前 drain 已 claim 的 run，不能使其复活。
- **Goal scoped barrier / cancel 与 WorkTask 独立性**：Goal run 的 idle barrier 和取消只能覆盖同一 Goal/可选 ContinuationRun 的 queued、claimed、running AgentInvocation；取消必须先建立精确 Goal/run tombstone，并在 root admission、admission lock 和 durable queue append 边界复核。admission barrier 必须等待同 scope 在途创建；取消 await 后必须重新 snapshot，直到该 scope drain 或持久化失败后 fail closed。已经部分 durable admission 的 root invocation 必须先写 terminal cancellation，provider 才可保持未调用；terminal persistence failure 必须 quarantine。send/request/reply/delegation 必须共享 communication admission fence；取消期间迟到且已 durable 的 scoped message 必须以 `agent_message_discarded` 结算。Run/Goal terminal 不得改变 WorkTask；新 Run 继续使用当前 Session 原 WorkTaskID，严禁 carry-forward、clone、重分配 ID 或重映射依赖。
- **Goal crash/in-process recovery**：Orchestrator restore 必须持有 persistent startup scheduler suspension。GUI 完成 roster/main/reviewer 状态解析与 Goal recovery 后只可释放新提交，恢复出的 root invocations 保持 paused/interrupted；CLI 才保留显式 `/auto|/default` 后的数据面 resume 边界。incidental attach/policy/mailbox 操作不能唤醒恢复任务。当前格式 EventLog 中遗留的 `created/running` Run 必须写为 terminal `interrupted`，不得追加 recovered 事件、恢复旧 provider/tool stack 或让同一 Run 回到 running；冷启动仍 active 的 Goal 必须 durable pause（到预算则 budget-limit）。只有显式 Resume/Edit/Send 等动作才可创建新 Run。未审计 checkpoint、uncertain non-replayable execution、取消/持久化失败或 Goal terminal 仍按既有 fail-closed 规则处理。
- **App/runtime ownership 与退出协议**：macOS runtime 必须由进程级 manager 按 exact `{SessionKind, SessionID}` 持有；窗口只能拥有展示选择。mode/session 切换、History、Command-W 与关闭最后窗口不得调用 runtime stop。删除 session 只能 drain exact runtime，并向其他窗口发布 removal；不得用全局 `isWorking` 阻断无关 session。Command-Q 必须先关闭所有 runtime 的新操作 admission，再并发 stop，并以单调 bounded deadline 等待；超时只允许退出并报告 timed out，不得伪造 settled。Chat/Code/Cowork shutdown 必须取消并等待其登记的 provider/tool/mutation tasks 后再释放 permission waiter、subscription 与 workspace scope；quiesce 后任何公开 send/settings/workspace/agent/Goal/permission 入口都不得新建异步工作。正常重开或 crash/force-quit 后重开只 replay/reconcile，不自动发 provider；继续只来自显式 Send/Retry/Resume。
- **独立 GoalVerifier**：GoalVerifier 与 `@permission-reviewer`、main/worker 数据面彼此独立；只能收到无工具、有界的 provider 审计请求，不能执行工具、写 EventLog 或自行更改 Goal。WorkTask result/evidence 是 agent-reported，绝不能单独证明 Goal；host 只能从同一 Goal 的 durable 成功 tool-execution settlement、经 validation-tool allowlist 派生 `validationEvidence`，再校验 requirement/evidence，不能接受伪造引用。malformed/tool call/缺完成标记/普通 provider failure/timeout/cancel 只能 fail safe 为 continue；相同 blocker 只有达到配置的连续 run 阈值后才可 blocked，单轮 `blocked_candidate` 不是终态。
- **Provider hard usage-limit 持久化**：只有 typed `ProviderUsageLimitError` 可以给 scoped `task_failed` 写入可选 `TaskFailedPayload.failureCode = provider_usage_limit`；旧 JSONL 缺字段必须继续解码为 nil。运行时 hard-limit signal 只能在该 `task_failed` 成功持久化后发布；restore 必须同时核对 TaskContract 的 Goal/run scope、current non-completed Goal（包括 paused）和尚未 audit 的 run，原子 Goal/run settlement 成功后才能消费 signal。不得从自由文本、普通 429/rate-limit、`length` / `max_tokens` output limit 推断 usage-limited；显式 Goal token budget 达到后的 `budgetLimited` 也必须与 provider account `usageLimited` 分离。
- **Cowork 调度与恢复协议**：同一 assignee 必须 single-flight，不同 assignee 的运行数不得超过 `CoworkExecutionPolicy.maxConcurrentTasks`。Orchestrator restore、Goal startup/进程内 launch 与 whole-task retry 必须使用 `replayForProjectionChecked()` 并要求 `hasCompleteKnownHistory`；unknown future event type 或 seq gap 不能支持 absence/order proof，必须 fail closed。restore 期间 scheduler 必须保持暂停。自动递增 attempt 重排只允许明确 eligible 的 non-root/CLI read-only crash-recovery task，不适用于 GUI restored root。`doNotReplay` 调用在旧 task attempt 中断后必须阻断该 attempt 的自动重放并明确失败；继续工作由用户在同一 Session 创建新 Run，不恢复同一个 Run，也不新增对账对象。五个 exact `structured_read_only + safeToReplay` reader 不属于该集合。created/assigned 半入队、attempts 耗尽或关键 lease 缺失也必须失败；stop 必须取消 queued/running work并解决悬挂 permission continuations。
- **Cowork persistence-first admission/execution**：root、delegation/ask、mailbox wake、retry、agent attach/reviewer attach 与 crash requeue 只有在关键 roster/lease/task/queue 事件成功追加后才能进入可执行 registry/taskGraph/scheduler 内存状态。attach request 三联事件及 allow/deny 后的关联事件必须分别用一次 `appendAdmissionEvents` batch 提交，不能逐事件留下 ghost roster/lease 或半审批状态。tool call、permission request/resolution、`tool_execution_prepared` 任一写入失败不得调用 executor；tool result 与 settled 应在同一 batch 持久化。detach 与 lease revoke 必须先持久化完整 revoke/detach batch 再改 registry/map。queue/start/terminal/admission 写入失败不得调用 provider；半 admission task 必须补 terminal cancellation/failure 或由 restore fail closed。
- **No-effect 与 unknown outcome 不得混淆**：普通 executor error 必须结算为 `failed/unknown` 并作为 observation 返回同一 Agent turn，不能自动 retry，也不能升级为通用整轮终止；executor-entered cancel 结算为 `cancelled/unknown`。只有受信实现能证明 mutation boundary 尚未跨过时，才可在同一 batch 写 `tool_result + tool_execution_settled(..., effectDisposition=not_started)`。production Orchestrator 只可证明 `task_create/task_update` 首个 WorkTask append 前的预检，或 `delegate_task` 完整原子 admission batch 前的预检。`task_update` 重复合同字段只可归一为 no-op。新成功 settlement 必须显式 `committed`；Projection 对每个 execution ID 只接受首 prepare/首 terminal，冲突或顺序错误 fail closed。不得解析错误字符串、借用后续状态或增加通用修复器。
- **Cowork 投递与原子委派协议**：普通 typed message 仍通过 `MessageBus.deliver`；`Mediator.mediate` 必须先于转发，禁止绕过。`delegate_task` 的 MessageBus 阶段只能纯调解，不得先 append/deliver；可能异步等待的纯 Mediator/exact-provider 检查不得占住 admission lock。取得 lock 后必须重新复核 authorization、target/binding/lease、WorkTask 与 graph/scheduler 状态，并用一次 EventLog batch 原子写入 message、mediation audit、lease、AgentInvocation、queue 与 WorkTask linkage，batch 成功后才更新内存状态。`ask_agent` / `delegate_task` 必须通过 scheduler 运行目标 agent 并把 mediated 结果作为上级 tool observation；不得只返回 queued ack，也不得同步嵌套另一个 `AgentLoop`。
- **Cowork mailbox 消费/丢弃与 correlation 协议**：typed message 必须先通过 Mediator 并成功追加 EventLog，才能进入 runtime mailbox。每个 new mailbox delivery `TaskContract` 必须冻结 1–8 个去重 exact MessageID；ContextProjector、presented IDs 与 consumed 必须依次收窄为该集合。authority class 只有三类且不得混用：ordinary message 只能获得 read-only workspace、communication `.none`，不得发送 ACK；information request 只能获得 `reply_message` + `.replyOnly`，且 `inReplyTo` 必须等于 frozen RequestID；information reply receipt 不得再暴露 `reply_message`，只可向原 sender 用 `request_information(based_on: exact reply MessageID)` 发起实质追问。mailbox 不得获得 delegation grant；委派只能由 coordinator 显式调用 `delegate_task`。每个 information RequestID 只接受一个 terminal reply；后续实质对话必须生成 fresh RequestID、保留 stable `conversationID` 并记录 `basedOn`。成功 task terminal、可选 candidate WorkTask progress 与全部 exact consumed events 必须在一个 EventLog batch 落盘，成功后才从 runtime mailbox ack；append 失败不得留下 completed/consumed 半状态。若 owning Goal/run 在呈现成功前取消，只能 durable `agent_message_discarded` 后 ack。delivery 失败只能对同一 TaskID 做受 `maxAttempts` 约束的有界重试。
- **Cowork 任务回报与回收**：`delegate_task` 完成后必须把稳定 invocation `task_id`、`agent_id` 与结构化 Task Report 作为 mediated tool observation 回填给上级 agent，并在 `task_completed` / `task_failed` payload 中保留可选 `report`；绑定 `work_task_id` 时只追加 invocation linkage，结果仍只是 candidate，不能自动 settle WorkTask 或 Goal。`to` 省略/`auto` 时只能在 delegation budget 与同 workspace 边界内选择已 attached 的 idle worker；没有候选就 typed `not_started`，必须由独立 `spawn_agent` 在较早 tool-call round 创建后再委派。不得隐式 proposed/spawn worker。并发 auto delegation 必须预留不同已有候选并在所有出口释放 reservation。tool-spawned agent 的既有 idle 回收规则保持不变；用户/GUI 手动 attach 的 agent 不参与自动回收。
- **Cowork 上下文投影**：worker prompt 必须继续通过 `ContextProjector` / `ContextBundle` 构造，不得恢复全局 transcript 直灌。各类 context 必须同时有 count 与 character budget；动态 task/message/event/path/artifact data 只能进入带边界转义的 user-role `UNTRUSTED_CONTEXT_DATA`，不得拼接到 system role。`taskGroupEvents` 只能暴露 task ID、状态、agent 与 current/parent/sibling/child/related 关系；不得把 sibling/related task 的 objective、expected deliverable、tool args、workspace private path、report detail 或 result 文本投影给无关 worker。没有显式分享元数据时，禁止把全会话 artifacts 冒充 `explicitlySharedArtifacts` 注入 worker。
- **Cowork `@main` 模型历史**：稳定 `@main` 的下一次 provider 请求必须从 durable `model_history_item` 或最新有效 `model_history_compacted` checkpoint + suffix 重建此前 user / final assistant / function-call / function-output 顺序，再追加当前用户输入；不得退回“每次只发当前一句”、UI bubble replay、`task_completed.result` 拼接、截短 audit args 或最近 N 条自定义摘要。user item 必须在首次 dispatch 前持久化，完整 assistant call batch 必须在任何工具执行前原子持久化，每个 output 必须与对应 `tool_result` / execution settlement 同 batch；含图output还必须绑定同turn/call的唯一result及同`{callID, agent, taskID, attempt}`的唯一settlement。failed/interrupted `turn_outcome` 必须只过滤同 TurnID 的 final assistant message，保留真实 user、reasoning、call/output 与 tool-search 历史，completed 或无 outcome 的 legacy turn 不变，冲突 outcome fail closed。恢复时 missing output 只可在 prompt 副本补稳定 `aborted`，orphan output 必须删除，不能改写事实日志。只有 direct output 已存在时才可从 ContextBundle 删除同一 audit result；空/重复 call ID 必须在同一 turn 内唯一化并让 call/result/ticket一致。`write_stdin`原文与其他不可安全持久化参数不得进入model history。未知schema、unknown future event、seq gap、冲突item/call/output/checkpoint或错误root/submission/attempt绑定必须在provider前fail closed。compaction必须持久化typed replacement-history item array，禁止只存摘要或简单截掉最近N条之外的结构。
- **Cowork lease 协议**：task-scoped capability/workspace lease 必须核对 task ID、工具、communication/delegation grant、workspace root、access 与 allow/deny path，并在 completed/failed/cancelled 后撤销。WorkspaceLease 必须持久化 canonical root 的 device/inode identity，并在 attach commit、权限等待后、durable execution prepare 后紧邻 executor、派生/retry 与 managed process 启动前复核；目录身份改变或 legacy identity 缺失时 fail closed。retry 只能从原 lease audit history 克隆权限；历史缺失时必须 fail closed（当前拒绝 retry），禁止回退到 assignee 默认 coordinator lease。默认 agent lease 必须持久，不得误标为 task-completion expiry；restore 不得恢复不属于当前 roster 的 orphan default lease。
- **WorkTask / Goal capability lease**：coordinator 可持有 `manage_work_tasks` / `read_goal`，worker 默认只有 `read_work_tasks` / `update_bound_work_task` / `read_goal`；任何模型 lease 都不得获得 Goal 创建能力。worker 只能读取当前 AgentInvocation 绑定的 WorkTask及其依赖，并更新该 exact binding；不得改 DAG、priority、retry/cancel 或提交 Goal verdict。ordinary worker 的 provider-facing `task_update` 必须保持 closed narrow business schema，只暴露 `task_id`、`expected_revision`、`progress_note`、允许的 `status`、`result`、`evidence`；automatic authorization sidecar 另行装饰，不得把 manager 合同/图/优先级/重试/取消字段暴露给 worker。Goal 和 WorkTask 权限及终态相互独立；Goal completion 仍必须消费独立 GoalVerifier + host-derived validation audit。
- **Cowork inference spawn/delegate 协议**：`spawn_agent` 未指定 inference profile 时必须复制 issuer 的完整 exact binding；显式 profile 只能来自 host-approved map，raw model 与 profile 不得并存，worker/模型不得用 raw endpoint/model/options 绕过 allowlist。`delegate_task` 不得改写目标 agent binding；authorization 必须包含目标 binding 的安全 route/trust/egress 快照与派生 `targetInferenceFingerprint`，allow 后、durable prepare 后与 queue/executor 前复核 fingerprint/binding 未变。Project/session default 只用于未来 agent，不得作为 recovery 或 delegation fallback。
- **Cowork inference rebind 协议**：rebind 只能由 host 发起，只允许无 queued/running invocation 的 ordinary agent；`@permission-reviewer`、普通 agent 自切换和 busy agent 必须拒绝。候选 binding 必须与 host-approved entry 完全相等并先 exact resolve；admission lock 内再次核对 current binding/busy state，再先 durable append previous/new binding 与原因，成功后才改内存 roster。已冻结 `TaskContract` 不得被 rebind 改写；rebind 只影响未来 invocation。Composer next-main drain 使用同一校验但不是两阶段的独立 rebind：必须先从 immutable submission 读取 binding、仅以 `@main` 为目标，并把 rebind event 与其 root/retry queue admission 放在同一个 lock-held atomic batch，batch 成功后才同时提交内存状态；不能把菜单点击直接当成 rebind，也不能留下“live main 已切换但对应 root 尚未入队”的窗口。
- **Inference route 边界**：per-agent inference binding 不是 `PermissionProfile`、`CapabilityLease`、`WorkspaceLease` 或 browser profile，不能互相替代。当前实现没有独立 `InferenceRouteLease`、per-task route approval 或跨 trust-domain 专用审批；不得在没有独立设计、协议与回归的情况下把 host-approved catalog/现有 permission snapshot 宣称为这些能力，也不得据此自动放宽网络或数据出口权限。
- **Coordinator 工具**：`spawn_agent` / `delegate_task` / `list_agents` / `remove_agent` / `ask_agent` 只对持有对应 coordinator capability lease 的 agent 暴露；worker 默认不得获得 coordinator 能力。`spawn_agent` schema 不得暴露 raw `model`，只允许可选 host-approved `inference_profile_id`，省略时继承调用者 exact binding。不得重新加入请求委派工具、capability、event 或 mailbox authority；worker 需要帮助时只能在结果中报告。一个已通过 AgentLoop schema/lease/permission/durable prepare 的 `spawn_agent` / `delegate_task` 是一个外部 ToolCall，只能有一个权限决定；executor 内部 roster/lease/attach/task/mailbox/scheduler admission 不得再次调用 `PermissionEngine`。`@main` agent 不可被 remove。
- **Cowork coordinator 主动推进合同**：只有持有 coordinator lease 的 invocation 才能获得主动全局编排提示。它必须先建立本轮 execution objective、检查 bounded Skill catalog 并激活/读取明确相关的 exact Skills；非简单工作在 task tools 可用时维护最小可验证 WorkTask DAG，在收益超过协调成本时尽早委派并继续自己的关键路径，核验 child report 后才显式结算，持续到结果验证或真实 blocker。这里不得把普通请求自动提升为 durable Goal，不得为一步两步工作仪式化 spawn，也不得借“主动”放宽 authoritative tool list、Skill 非权限语义、CapabilityLease、WorkspaceLease、PermissionEngine、exact inference binding、最小 team/lease 或 worker 无协调权边界。
- **外部目录恢复提示词**：直接 out-of-workspace hard deny 必须继续终局，不能通过 system prompt
  放宽 agent 当前 WorkspaceLease。Cowork coordinator 的恢复指引必须以 authoritative request
  tools 真实包含 `spawn_agent` 为采用前提：停止直接重试/路径逃逸，以目标绝对目录创建默认
  `read_only`、仅任务确需修改时 `read_write`、默认 `canCoordinate=false` 的子 agent，并在 spawn
  成功后用 `delegate_task` 交付目录内工作。工具缺失或 workspace expansion 被拒时必须报告所需
  目录/访问级别的 blocker，不得伪称完成。Code、worker、reviewer 与无 coordinator lease 的
  invocation 不得宣称或猜测该能力；提示词不得绕过 bookmark、PathConfinement、PermissionEngine、
  敏感/过宽根目录拒绝或子 agent 后续逐次工具审批。
- **Cowork 文档/媒体工具 lease**：read-only worker 默认获得 `readPDF` capability 对应的
  `inspect_pdf` + `read_pdf`、五个拆分 read capability 各自对应的初读 + continuation，以及
  legacy `documentOCR` capability 最窄映射的 `ocr_pdf`。五组 Docling reader/continuation 必须
  携带 `structured_read_only`、read/execute、`safeToReplay` intent；OCR 同为
  structured-read-only deterministic allow，但保持 `doNotReplay`。解析失败必须形成 failed
  settlement/observation 并允许同批独立读取继续。`pdf_render_page`、四个 export、29 个 write、
  `compile_latex`、`generate_image`、`edit_image` 只向 read-write worker/coordinator 显式签发。
  legacy aggregate capability 可以映射 concrete registrations，但 fresh lease/registry 绝不能暴露旧名。
- **Cowork Git / 网络 / 浏览器工具 lease**：worker 默认不得获得 `gitControl` 或 `browse_web`，也不得暴露 `git_*` 写入工具、`web_fetch` 或任何 `browser_*`。Git control、网络/浏览器能力只能通过 coordinator lease 或未来显式 `CapabilityLease` 授予，且执行时仍必须通过 `PermissionEngine`。
- **Cowork project-mode agent 管理**：GUI 无 @mention 的用户消息必须默认发送给项目 `@main`，不得在已有多个 agent 时强迫用户手动选择目标。子 agent 应由 `@main` 通过 `spawn_agent` / `delegate_task` 等工具按任务需要创建和管理；`spawn_agent` 默认创建 worker（`coordinationDepth=0`），只有显式 `canCoordinate:true` 或未来明确 capability lease/任务契约授予时，子 agent 才可获得 coordinator 工具并继续管理下级 agent。右侧 inspector 不提供 agent 删除或详情管理；如未来在 settings/专门管理面板恢复人工删除普通子 agent，也不得删除 `@main` 或 `@permission-reviewer`，且不得删除用户文件或清理未提交工作区，只能更新 Orchestrator roster 与非主 workspace metadata。
- **自动权限审查保留身份与 generation 隔离**：`@permission-reviewer` 由 GUI/CLI Cowork session 默认启用；CLI `/auto` 只能重新启用，只有用户明确 `/default` 才移除并进入人工模式。它是 read_only、无工具 capability lease 的特殊控制面 agent，不得作为普通 send/delegate/message/ask 目标，不得暴露给 `list_agents`，也不得由其他 agent 用 `spawn_agent` / `remove_agent` 管理。它必须使用有界独立 FIFO/single-flight/timeout/cancel，不得占普通 scheduler 槽或运行嵌套 AgentLoop；默认不得注入 `temperature`、output-token 或字符上限，只有用户/host 显式策略或真实上游/上下文约束存在时才可使用对应控制。deadline 必须从 submit 计时，queue full/timeout fail closed。自动模式只有 allow/deny；pre-submit caller cancel 必须返回 typed deny、不创建 review lifecycle，且不能误报 control-plane shutdown；ask_user/truncated/malformed/tool-call/provider/persistence/timeout 与已登记 review 在 terminal-claim 前被观察到的 cancel 均 durable deny 当前调用，禁止隐式 GUI fallback；claim 后 cancel 可保留唯一 reviewer settlement，但最终 authorization delivery 必须 deny。caller cancellation 必须在 cancellation handler 内通过 request-owned 同步 token 对 settlement path 可见，并在 caller-task post-await 与直接 host admission 边界再次 fail closed；不得只依赖异步 actor hop。累计 token 只能是可选 soft warning，不能成为不可恢复的 session-lifetime shutdown；optional completion estimate 只能用于缺失 provider usage 时的 soft accounting，不能发送上游。结构化 review task 必须携带当前 task/attempt/tool/path/side-effect/gate/lease/context；request 与 settled 均 durable-first，allow 只有 settled 成功后生效，恢复必须关闭 orphan request。provider failure 的 durable reason 必须先经过共享 diagnostic sanitizer 去除 secret/完整 URL 并限长。每次 provider dispatch 必须创建 exact request generation；provider/timeout 竞争同代首 terminal，provider-backed terminal claim 必须校验该 generation，pre-dispatch terminal 从 running/no-generation 状态唯一 claim。caller cancel 另由同步 token 与下游围栏保证。timeout/cancel 只能影响当前 call；若已有 active generation 就只 retire 该代，下一 request 必须可 fresh-resolve provider wrapper，不得恢复 process/session-lifetime quarantine。late/duplicate result 不得写 EventLog、改变 health/authorization 或执行工具。production provider factory 必须冻结 reviewer identity/exact binding，且不得捕获 Orchestrator 形成 retain cycle。`ToolCallingProvider.stream` 必须立即返回 request-owned stream，并传播 consumer termination；不得用 `Task.detached` 声称已隔离同步永久阻塞实现。terminal claim 后 cancel/quiesce 可以使最终 authorization delivery deny，但不得追加第二个 settlement 或执行工具。用户 Cancel task 只能取消数据面 queued/running task，不得关闭常驻 reviewer；session stop 或显式 disable 才可 quiesce/shutdown 控制面。disable 必须先 quiesce 并在 revoke/detach 落盘成功后才报告 disabled；落盘失败 resume 后也必须使用 fresh generation，旧 allow 无效。Phase A 后 GUI reviewer 未就绪不得锁定 composer、阻止本地 durable Send 或阻止不含 ask-class tool 的普通主请求；只有真正进入 ask 边界的工具调用由 unavailable responder fail closed。Cowork 对话页不得恢复常驻 reviewer 状态横幅；workspace reauthorization 与 automatic-review retry 的异常恢复入口必须保留在 Project Settings，不得随横幅删除。旧 `provider_still_stopping` 只为 legacy EventLog 解码保留，不得重新作为 permission reviewer live 状态。
- **自动权限瞬时故障的 fresh-review 上限**：provider/timeout failure 必须先 durable deny 当前调用，且不得产生 execution prepare。只有 typed `automatic_reviewer_failure` 且 failure kind 为 `provider_failure` / `reviewer_timed_out` 时，模型的第一个 exact retry 才可创建新 RequestID/new reviewer generation；它必须重新通过 gate、authorization、durable settlement 与 executor 前重校验。每个 denial signature 最多一次，第二次失败不得重新装填。显式 user/policy/reviewer deny、malformed/cancel/persistence/shutdown/authorization failure 必须继续使用普通 cached-denial fuse，绝不能借该路径再审或执行。
- **Inference 控制面冻结**：GUI/CLI 必须从 canonical 顶层 `permission_reviewer_model` 独立解析并冻结 Permission Reviewer exact base-profile binding；字段缺失只允许在配置解析层一次性继承同一 JSON 文档顶层 `model`，兼容来源缺失/未知、显式空值/错误类型/unresolved route，以及已选配置文件整体损坏或不可读都必须让 reviewer fail closed，不能回退 `TRANSLATIS_MODEL`、UI/UserDefaults selection、session default、live/historical `@main` 或普通 agent rebind。Permission Reviewer 每个 generation 只能在该冻结 binding 上重新 exact-resolve provider wrapper。GoalVerifier 另行冻结首个可解析的 exact `@main` binding并保留独立 provider lifecycle；legacy/unresolved main 只影响该 verifier，不得阻止独立 reviewer 启动。后续 data-plane rebind 或 future-agent default 更新不得静默 retarget 任一已运行控制面。
- **工具授权单一事实源**：model schema、concrete tool identity、canonical permission、CapabilityLease membership、semantic preview 与 executor 必须来自同一个 `ToolRegistry` registration。unknown/duplicate/unleased tool、descriptor/registry/lease fingerprint drift 必须在 reviewer/provider/executor 前 fail closed；reviewer 不得根据 `write_file` / `apply_patch` 或 capability alias 自行推断 membership。等价文件编辑工具的 canonical permission 保持 `filesystem.edit`，但严格的每次写入都审查策略不变。
- **不可变授权链**：同一 `authorizationID` / `ResolvedToolAuthorization` 必须贯穿 permission requested → review requested/settled → permission resolved → tool execution prepared/settled。review 后和 executor 前必须复核 registry/spec、authorization-identity digest、lease、workspace/target identity；executor 不得换用另一份参数、target、lease 或重新解析的 tool。`ResolvedToolAuthorization.normalizedArgumentsDigest/count` 绑定 registration 的 `authorizationArgumentIdentity`，不保证等于 raw stripped business args；旧 JSONL 缺 authorization 可以兼容解码，但 live automatic-review 不能用 legacy 缺省值继续执行。
- **Same-call permission sidecar 输入契约**：Cowork provider-facing business schema 只在 request-owned copy 中增加 required string `__intatis_authorization_context`；对任何 `strict:true` function，decorated copy 必须递归满足 `required == properties.keys` 与 `additionalProperties:false`，否则在发网前 typed fail closed。`tool_search` 本身不得伪装成普通 function；其 request-owned `tool_search_output` 中 deferred function/namespace children 必须装饰，durable output 与远端原业务 schema 不变。原 ToolDescriptor/business required/executor schema 不变，宿主仅在 deterministic gate 实际进入 automatic ask 时消费并验证 sidecar。live reviewer 必须收到 acting model 同一 generation 的 complete canonical sidecar-free safe business arguments、完整 string sidecar 与 mechanical host binding/gate/lease/action facts；不得退回 digest/preview-only reviewer，也不得恢复第二次 Reporter/full-context/PDF/image resend。reviewer provider prompt 不得包含 TaskContract objective/role/deliverable、causal userGoal、raw/current 用户指令、assistant/history、PDF 或图片原文。valid sidecar 只可保留在当前 turn 的 acting-model 内存 conversation；raw sidecar 与 reviewer transient exact-args 副本不得进入 EventLog/permission lifecycle，durable `.tool_call` 与 model history 只保存 stripped business view。sidecar/invocation business digest/count 只绑定该 stripped canonical business view；它必须与自定义 authorization identity digest/count 分域校验，禁止直接要求二者相等。missing/malformed/secret-bearing sidecar 只能产生 failed/runtimeFailed `tool_result`，不得创建 `permission_request` / `permission_resolved`、调用 reviewer或消耗 permission denial fuse；同 business args 修正后必须仍可送审。binding 不一致单列为 authorization snapshot failure并 typed fail closed。manual/nonautomatic call 携带保留字段必须 redacted fail closed，绝不能把它传给业务 tool/MCP/executor。live size ceiling 不能凭空固定，未来只能由 exact route budget 推导并整份拒绝，禁止裁切后继续审查。
- **Automatic reviewer 交付/重复/输出契约**：automatic responder 必须实现 bound-invocation overload；未实现、缺 transient、binding 不一致都必须拒绝。live active duplicate 只有 request 与 invocation 完全相同才可共用 owner generation；cached terminal 每次交付前仍重验本次 invocation；restart recovered allow 不得重新交付。唯一无 acting-model invocation 的 automatic `agent.attach` 必须走 dedicated host-admission entry，并同时证明 exact task/tool/action/policy/authorization/workspace identity 与先行 durable attach/lease events；仅设置 `TaskContract.kind` 不得豁免。verdict 必须有非空 plain-text reason + 唯一 final-line ASCII `ALLOW`/`DENY`；240 Character 只能是共享 prompt 的简洁度建议，不得作为 parser hard limit。必须先扫描完整 reason 的敏感信息，再有界化任何可交付/持久化摘要；对 live bound invocation，model-authored reason 和 provider diagnostic 可能回显 transient input，durable settlement/tool-result 必须使用固定宿主文案。缺失/重复/非末行 marker、空 reason、JSON/code fence、无 completion 与非成功 finish 必须细分为 secret-free typed failure 并 fail closed；旧 coarse failure kind 只为历史解码保留。risk 固定为 deterministic gate。deny/failure 的 source/status/failure kind 必须保真，禁止伪装成用户拒绝。Cowork shipping `PermissionEngine` 不得配置 in-engine reviewer；如果误配，control-plane 前即使已多出一次 reviewer 调用也必须 typed fail closed，绝不能使用其 allow。
- **Sidecar P2 隐私边界**：codec 之外唯一允许保存 raw valid sidecar 的位置，是同一 turn 的 acting-model 内存 function-call history；turn 结束即释放，任何 durable history/EventLog/executor 都必须 stripped。sidecar codec 不能阻止 acting model 在普通 assistant text 自行复述相同内容；该文本仍按既有消息/history 规则保存。malformed acting-provider error preview 也继续依赖通用 bounded/URL/secret sanitizer，不能宣称所有 provider-specific 诊断都经过 sidecar-aware 剥离。新增 provider adapter/error shape 时必须增加 adversarial non-echo 回归，不能把“raw sidecar 不落盘”外推为“任何语义副本都不会落盘”。
- **精确 delegation 审批**：`delegate_task(to:auto)` / 省略 `to` 时，host 必须在 review 前从已 attached、可用、同 workspace 的 data-plane agents 中解析 exact target，并把 agent/workspace/model/access/fingerprint 写入 authorization；无候选即在 review/admission 前拒绝。allow 后必须复核 exact target 与 lease，执行时不得重新选人、fallback 或隐式创建 worker。相同 durable executionID 必须命中同一 AgentInvocation identity。
- **禁止副作用完成 cast**：不得从 permission/review/resolved/prepared/settled 事件建立或恢复 unresolved-side-effect ledger，不得要求后续同资源成功 action 清债，也不得在 provider 正常 final 后以既往 denied/failed tool call 为由把 turn/AgentInvocation 改判失败。权限 hard deny、tool result 的真实 outcome/failure source、durable execution ticket、`effectDisposition` 与 `.doNotReplay` crash guard 仍各自保留；它们不能重新组合成 final completion gate。`ask_agent` admission/Mediator failure仍必须作为 typed tool failure，不得产生 succeeded settlement，但 caller 可读取该 observation 后正常结束当前 turn。
- **权限协议**：硬 DENY 终局；普通文件写入、shell/exec、网络、destructive 操作必须进入权限请求或 hard deny，不能因 reviewed/autopilot 静默执行；`ModelPermissionReviewer` 只能收窄不能放行；Cowork 的 `AgentPermissionResponder` 只能回答已经产生的 `ask_user` 请求，不能覆盖 `DeterministicPolicyGate` hard deny；自动模式的回答只能 allow/deny，人工 responder 只能在用户显式切换的人工模式使用。任何 model tool_call 到执行都必须过 `PermissionEngine`，无旁路。production Code/Cowork registry 不得重新暴露 raw `run_shell`，除非未来能同时证明 OS workspace allow-list、WorkspaceLease 任意 denied-pattern、默认断网与进程隔离；保留的底层 runner 仍必须使用 OS sandbox、最小环境，缺 backend 时 fail closed，绝不可退回裸 `/bin/sh -c`。
- **Decline / Cancel / terminal 顺序**：`Decline Call` 是 call-scoped，必须产生 typed denied tool result并允许同一 turn 继续；`Cancel Turn` 是 turn-scoped，只能在 permission terminal 后写 interrupted turn outcome，禁止伪造 user-denied tool result。policy/reviewer/sandbox/runtime failure 不得显示成 user declined；automatic mode 不得暴露人工 action 或 fallback。pending approval 按 durable registration FIFO；exact duplicate/reconnect 幂等，冲突 duplicate fail closed，远端或本地结算中间项不得重排剩余项。turn/task abort 必须先 cancel 并 await provider/tool execution，再 settle/clear waiter，最后才 shutdown reviewer/发布 terminal/恢复 caller。可信 sandbox startup denial 可 typed 为 `sandboxDenied/notStarted`，但当前不得自动扩大权限、移除 sandbox 或 retry；普通 nonzero、EPERM 与目标伪造诊断不能套用该分类。GUI/CLI/projection 不得退回错误文本推断 outcome。
- **JSON-RPC 词汇**：`Command`→request、`Envelope`→event notification 映射已定义，传输未挂。不得在未确认 out-of-process 传输设计前随意改词汇结构。

- **WorkTask/委派 proof scope**：production `task_create` / `task_update` 只能由 Orchestrator adapter 在首个 WorkTask append 前证明 no-effect；create 的 capability/title/dependency/graph 与 update 的 binding/revision/transition/frozen-contract rejection 可 typed `not_started`。`delegate_task` 只可在完整 admission batch 前证明 no-effect。append/batch 已开始、persistence/lost-ack 必须结算 unknown 且不得自动 retry；不得按 `IntatisError` case 或错误字符串做全局推断。

## 路径禁区

- **工作区根**：`PathConfinement.resolve` 拒绝 `..` 与越界绝对路径。
- **受保护配置路径**：lockfile / CI / Dockerfile / Makefile → 写操作必须 `ask`。
- **可执行 Git 配置**：通用 model-facing 文件工具不得读取或改写 workspace `.git/config`、linked-worktree `config.worktree` 或其符号链接；只能由结构化 Git service 在固定 executable、禁 hooks、静态配置审计与 workspace lease 约束下访问。
- **敏感路径**：`~/.ssh`、`~/Library/Keychains`、`~/.local/share/translatis/auth.json`、`~/.local/share/opencode/auth.json`、`~/.config/translatis/intatis.json`、`~/.config/opencode/opencode.json`、secret/token/key 目录 → 硬 deny。

## Managed terminal 禁区

- production 不得把 raw `run_shell` 重新放进 Code/Cowork registry；真实 shell 只能通过 runtime-owned `exec_command` / `write_stdin`，且两个调用都必须经过 concrete ToolRegistry registration、CapabilityLease、PermissionEngine、durable prepare/settle 与 executor 前复核。
- 已有 session ID 不是通行证。每次交互都必须精确匹配 session、agent、task、attempt、WorkspaceLease 与 canonical root identity；`write_stdin.chars` 也必须进入跨调用危险命令 hard-deny 检查。光标移动、补全、历史、escape 控制和 shell keymap 改写因无法可靠还原结果而必须 fail closed；输入只写入部分后报错时必须终止 session，不能通过先开空 shell、拆分字符串、改变行编辑规则或状态漂移来绕过。
- 终端执行边界必须把 `WorkspaceLease.mandatoryTerminalDeniedPatterns` 与 lease 自带规则取并集，并以大小写无关的 OS sandbox 规则执行；旧事件、显式空数组或大小写变化不得移除凭据路径底线。
- read-only worker、reviewer、iOS 与 host shell disabled 时不得看到 managed
  terminal。Cowork `runShell` capability 只可映射到 managed tools，不能映射
  到底层 raw runner。
- macOS terminal 必须保留 Seatbelt workspace allow-list 与默认断网，不得改回 `(allow process*)`、不得开放所有 `/dev/ttys*`，也不得为“命令能跑”而删除 sandbox。Linux 缺 bwrap 或 PTY backend 时 fail closed，不能回退裸 shell。
- PTY child 在 fork 与 exec 之间不得运行 Swift/Objective-C runtime 或做动态分配；参数必须在父进程准备完成，child 只做 C/POSIX signal/FD/chdir/exec，启动错误用 CLOEXEC channel 返回。任何新 launcher 实现都要重新覆盖 chdir/exec failure、FD 泄漏与 signal reset。
- terminal output 必须持续 drain 且有界，保留最新 tail；timeout、task terminal、turn cancel、session deletion、runtime shutdown 必须终止并等待 descendant cleanup 后再发布上层 terminal。不得让完成但无人 poll 的 session 永久占 active slot。
- 交互输入原文、无盐固定摘要和延迟回显不得写入 EventLog、permission preview、tool-call durable args、error 或普通 observation。环境不得继承常见 token/password/auth/proxy/database/JWT/access-key/session-key；临时 HOME 和 Git no-prompt/no-global-config 边界不得移除。
- managed terminal 不能恢复会限制正常构建产物大小的 `ulimit -f`。若将来需要资源限制，应分别设计 CPU/memory/output/process policy，不能用小文件上限误伤编译、链接和归档。

## 回归要求

- iOS 必须保持 macOS 真子集：**不得**链接 Tools/Permission/AgentKernel/Cowork 或 shell/git/patch 模块。
- 正式默认 typography 由 `IntatisTypography` 统一拥有：2026-08-19 用户已批准把第一方英文字形路由到
  exact bundled JetBrains Mono 2.304，并保留既有名义字号、字重和 Dynamic Type 语义层级。不得增加
  system-font opt-out、旧实验参数、UserDefaults/设置选择或 release-script alternate default。资源必须
  先通过固定 SHA-256、完整 PostScript inventory、Core Text process registration 与 exact bundle-URL
  revalidation；任一失败都必须在启动时 fail closed，禁止读取用户安装字体、system mono 或另一 family
  兜底。中文必须继续由 Apple glyph fallback 处理，禁止为此新增未审查 CJK 字体。正式发布须重跑完整
  release/accessibility/license/bundle gate，但不得再要求删除已批准的 exact 字体资源。
- iOS Chat 的正式默认必须沿用 macOS 的字体 family 与设计角色：品牌 `Intatis`、session 名称、
  Settings 页面标题、正文、按钮、菜单、表单、状态与输入的英文字形统一使用 JetBrains Mono，
  Markdown/代码/公式继续服从共享 renderer 的语义字体。抽屉保持
  `Intatis` → 选中 Chat → `Recent`/New → 底部 Settings；顶部保持 sidebar/session/New；
  底部 composer 保持 model/usage 第一排与 paperclip/input/voice/唯一 Send-or-Stop 第二排；voice
  必须紧邻主操作左侧。iOS session 与 Settings large title 使用 22pt nominal size 并继续按
  `.largeTitle` Dynamic Type 缩放；不得为此修改共享 30pt `IntatisTypography.largeTitle` 或 macOS 标题。
  iOS Send/键盘提交必须先释放 composer FocusState，消息 ScrollView 必须保持 interactive keyboard
  dismissal；stream completion、输入重新启用和自动滚动不得让键盘重新弹出。macOS 既有 focus 行为不变。
  不得恢复全局 `.fontDesign(.serif)`、system-font alternate default、顶部 model picker、抽屉底部假 search/Chat CTA，
  也不得因复用 macOS 视觉而让 iOS 增加本地附件、workspace 或 agent 能力。
- 根 `Translatis.icon` 是 `TranslatisMac` 与 `TranslatisiOS` 的 canonical Apple 图标源；两个
  shipping target 都必须以 `ASSETCATALOG_COMPILER_APPICON_NAME=Translatis` 编译它，
  不得手工导出另一套 iOS PNG 或重新引入第三个 App target 作为图标事实源。
- macOS UI 信息架构不得回退为三套 demo screen：mode navigation、mode-specific session history、New 与 Settings 必须保持在同一个连贯 sidebar navigation/session center 中；当前实现是系统 `NavigationSplitView` sidebar 内的 `Intatis` 标题、带 SF Symbol 的 Chat/Code/Cowork 竖向三行导航（仅选中项使用 interactive Liquid Glass）、mode-specific history/New 与底部 Settings。不得把模式导航改回横向 segmented control、单一 `List(selection:)` 或三套独立入口，也不得把 session/history 移回主内容工具栏。主 thread header 必须显示 session durable display name（仅缺失时回退 `SessionID`），不得写死 Chat/Code/Cowork；Code/Cowork header 保持紧凑顶部留白，Cowork 不得在标题之前恢复常驻 permission-reviewer 横幅。macOS composer 第一排必须是 model/profile 左、conversation Context 右；Input/Cached/Output/Time 不得继续作为 global latest strip，而应在每条 exact assistant/agent reply 的正文下方与最左 icon-only copy action同排显示。该 footer 不得增加 card/glass、文字版 Copy、点赞/点踩或其他反馈控件；复制必须使用 raw message text。iOS Chat 在单独迁移前继续保持 model/full-usage 第一排。Chat/Code/Cowork 的选择器必须保持同一个 40pt 高、原生 `Menu` 语义的 interactive Liquid Glass 胶囊，不得让 `Menu` 自带的压缩 chrome 把可见控件降回 24pt；关闭态只能显示选中模型名，不得恢复 CPU/芯片图标、provider 前缀或 variant/reasoning detail，弹出菜单内部的 provider 分组与 exact variant 选择仍需保留。第二排必须是当前产品面已经具备的 attachment/image action 左、原生多行输入居中、voice 紧邻唯一 Send/Stop 左侧；macOS Chat/Code/Cowork 的 attachment action 必须复用同一 durable import/draft accessory，iOS paperclip 继续是 Chat tools menu 且不得因此获得本地附件。attachment/image action/voice/stop/Send 必须复用同一 40×40 原生圆形 glass/bordered control，输入容器单行最小高度必须同为 40，同行 spacing 使用共享 token，多行输入增长时按钮保持底边对齐，Send 使用 prominent。sidebar `Recent` 旁 `+` 必须保持原生小型圆形 glass control 与 30×30 fitting size。没有 top accessories 的共享 iOS composer 不得产生空白行。消息不得重新添加 agent 头像或通用 Agent badge；agent 名称与状态只显示真实 structured identity/status。assistant/agent/system 对话回复（包括失败/中断回复、通用 Agent message、`information_requested` 与 `information_replied`）不得恢复外层 Material、圆角或描边，应直接继承系统 canvas；Agent 通信身份必须显示 exact `sender->recipient`，不得添加 `info` / `reply` 前缀。用户消息是唯一对话气泡，继续保持 trailing 几何并使用原生 regular Liquid Glass；正常 tool、permission、task 等专用结构化卡片继续保留语义容器，Code/Cowork error chrome 只进入右栏统一错误卡。不得为实现“白底”硬编码 `Color.white`，也不得用自定义蓝色 stroke 冒充玻璃。Chat 默认不显示右 inspector；Code/Cowork 宽屏 status rail 只能消费 structured projections/view-model state，不能解析 assistant transcript；显隐必须由同一个稳定 outer geometry 的未压缩 available width 与用户请求状态决定，禁止用已经压缩后的 child/thread width 反推自身显隐。Code 保留有界分栏；Cowork rail 必须作为同一 detail canvas 的 trailing overlay，不得用 divider 或独立 `.bar` 背景切成另一块面板，主 thread `ScrollView` 必须延伸至 detail 最右端并只用 trailing scroll-content margin 给 rail 留出正文空间，使原生滚动条位于整个内容区最右侧。Code/Cowork 不得在 mode/session 切换时动态增删 window `.toolbar` item，也不得重新嵌套 SwiftUI `.inspector` preference。Code 的 MCP/inspector action 与 Cowork 的 Project action 仍只能进入内容 header；Cowork header 不得恢复独立 MCP Content 快捷按钮，内容浏览必须位于 `Project Settings → MCP → Browse Content`，status rail toggle 必须保持系统 compact 圆形 glass/bordered icon control。
- Cowork 宽屏右栏必须把 pending permission 或最近权限结果放在第一位，其后才是未清理 agent 名字+状态图标、真实 `Goal` card 与 `Tasks` card；每个 section 独立使用系统 `Glass.clear`，glass backdrop 必须与动态内容分层，不得恢复包住整组 status cards 的 `GlassEffectContainer`、廉价固定灰框、独立强光块或手绘玻璃。Agents header 与 row status marker 必须继续使用 `Image(systemName:)` / SF Symbols；row marker 只能用圆形系统 symbol、system symbol font 和 hierarchical rendering，不得增加自绘圆底、SVG/PNG、第三方 icon 或仅靠颜色区分 lifecycle。rail 只能由各 glass section 自身建立边界；允许在每个 passive glass 之外使用系统动态 separator 的单物理像素 `strokeBorder` 作为不随玻璃光线漂移的轮廓锚点，但不得使用固定 RGB、整栏 separator/Material/`.bar` 背板、自绘渐变、投影或高光伪造“融合”。Cowork 右栏不得显示 Git 状态、workspace path 或任何 Git 控件；本地 Git control 仍只能通过 Agent 工具 + 权限门执行。wide rail 的 compact permission 只能显示状态、tool、安全 structured summary 与必要 actions，不得显示 raw args、risk chip 或默认详情；人工模式仍保留 exact RequestID/FIFO、Approve Call、Decline Call、Cancel Turn 与 remembered MCP approval 语义，automatic 模式保持不可人工操作。pending permission 在 rail 可安全容纳时必须临时固定右栏；窗口窄到无法容纳 rail 时只在 composer 上方显示一个同请求完整权限兜底卡，不能与 rail 重复。无 pending 时用户仍可隐藏右栏；任何窄屏或隐藏状态都不得在 thread 顶部复制 Goal/Tasks dock或保留空白占位。不得重新以 TaskContract objective 伪造 Goals 表，也不得塞入 project summary、选中 agent 详情、workspace/lease 列表或 Last Turn。Goal card actions 与 Tasks detail 必须绑定 durable state。
- Code/Cowork 的统一“错误信息”卡片仅在至少一个 error source 非空时位于各自右栏最底部，必须在单卡内列出所有去重项并保留 Cowork retryable submission 的 exact Retry；不得恢复中央 error card、`Needs attention`、recovery advice、composer error 横幅或另一张 `Recent Failures`。错误收口只能修改 presentation copy，不得删除、覆盖或重写 EventLog/projection 中的 durable failure facts。
- macOS Chat/Code/Cowork 的用户消息必须继续使用 trailing 气泡、原 `messageMaxWidth` 和左侧 gutter，并以原生 regular Liquid Glass 渲染；assistant/agent 正文与 Thinking 必须使用整个 thread `contentWidth`，不得重新套用用户气泡的宽度上限或在右侧放同等 gutter。system 对话消息也必须无外层气泡；正常 tool、permission、task 等专用结构化卡片继续使用各自既有宽度策略，Code/Cowork error chrome 只能使用右栏错误卡宽度。不得用放大全局 `messageMaxWidth` 的方式实现 AI 全宽，以免连带拉宽用户气泡。本 UI pass 不得替换既有字体 token 或用户选择的字体体系。
- macOS Chat/Code/Cowork 用户气泡必须保持 20pt continuous rounded rectangle + 原生
  `Glass.regular`；单行靠 intrinsic width 形成接近胶囊的形状，多行/附件继续受原宽度合同约束。
  Code/Cowork 不得在气泡内恢复 `Queued locally` / `Running` / `Completed` / `Cancelled` 等
  ordinary submission lifecycle row，也不得用隐藏 Spacer 再把短消息撑满 `messageMaxWidth`。
  这条只约束 presentation：SubmissionID/status/EventLog/projection、失败事实和右栏 exact Retry 必须保留。
  Permission card/notice 不在该删减范围内，其 pending/settled 展示和权限语义不得随气泡修改。
- 共享 `Jump to latest` 必须是 icon-only 原生 large 圆形 glass `arrow.down` 按钮，不得恢复过小的
  compact regular control 或突出的文字 bordered pill；既有出现条件、page/follow 行为、accessibility
  identifier、本地化 help 与 VoiceOver label 必须保留。Chat/Code/Cowork 必须落在包含 sidebar 的整个
  app-window content 横向中线；只允许 root 注入 finite window width，再由 window/detail/overlay-surface
  widths 纯计算 offset。不得硬编码 ideal sidebar 宽度，不得读取 screen-global frame、恢复 PreferenceKey
  回写或让 sidebar/inspector resize 触发持久状态。Cowork 不得按 transcript width 或 rail
  `trailingContentMargin` 右移。Cowork `Tasks` 默认卡必须合并 `Tasks` + completed/total header；任务行只显示一个
  durable-status marker、标题及确有详情时的 trailing disclosure，不得同时恢复 leading disclosure、
  ordinal、可见 status 文案和 completed strikethrough。status 必须继续作为 accessibility value/help，
  展开态必须继续读取 durable detail/result/evidence/dependency/invocation link。
- 用户消息由 trailing alignment + 原生 Liquid Glass surface 已充分表达归属，Chat/Code/Cowork 与共享 iOS Chat 不得重新显示冗余 `You` sender label，也不得恢复自定义 accent 蓝色描边；assistant/agent/system 的真实 structured identity 和 agent timestamp 不得一并删掉。macOS sidebar 品牌块只显示 `Intatis`，不得恢复 `Local AI workbench` 副标题；active Chat/Code/Cowork thread header 与 sidebar Recent row 均只显示 durable session name，不得在名称下恢复 model/provider/host、workspace/state、agent/running、event/date/path/runtime 等灰色 metadata，也不得用空 subtitle 保留不可见占位。selection、New、Rename/Delete、busy delete gate、空态首页和 Settings 的非 session 说明不受此视觉规则影响。待处理权限卡必须保持可操作但不主导 transcript：风险色只用于小面积 semantic indicator，详情默认折叠且通用摘要只能来自 structured authorization preview/intent/resource/touched path，不能直接渲染 raw args；manual approve/decline/cancel、automatic non-actionable、RequestID/FIFO 与 PermissionEngine 语义不得因视觉收口改变。
- English / 简体中文本地化必须保持为 App presentation concern：`Localizable.xcstrings` 的 English source/fallback 不得被删除，两个 App target 必须同时携带 `en` 与 `zh-Hans`，语言选择继续交给系统 Preferred Languages / App Language；不得写 `AppleLanguages`、强制根 locale 或另造会与系统冲突的启动偏好。只能翻译产品外壳、按钮、状态、设置、错误和辅助说明；session/agent/provider/model identity、文件与工作区路径、用户输入、模型输出、Markdown/公式/代码、EventLog/schema/raw enum、tool payload、permission correlation 与 model-facing prompt 必须保持原文。新增格式文案必须保持 English/zh-Hans 的 `%@` / `%lld` 等占位符类型和数量一致；iOS `Settings.bundle` 与 `InfoPlist.strings` 需单独校验，不能用主 catalog 的存在替代。
- macOS Chat/Code/Cowork rich transcript 必须展示完整连续会话并仅靠普通滚动浏览；不得出现
  Earlier/Newer/Latest、消息范围页码或要求用户管理历史 window。顶层 rows 使用
  `IntatisContinuousThreadStack` 的 lazy materialization，但 16 只约束同时保留重型 native
  rich-document graph 的活跃 viewport rows，不得重新变成数据分页。离屏 row 必须释放 rich graph并
  保留 exact raw text；用户离开底部后 live update 不得抢回，`Jump to latest` 只恢复 bottom-follow，
  不是分页控件。presentation scope、bottom anchor、scroll coordinator、viewport admission 与
  rich-settle generation 必须按窗口稳定，geometry callback 继续 observation-only并异步合并，禁止
  重建 ScrollView root、无界 eager `VStack`、completed-document、第二 renderer、消息高度 cache或
  geometry→state→layout 同帧反馈。4-row rich-entry 阈值只控制首次 bottom restore 前的 rich admission；
  带 ID 的 bottom sentinel 必须包含视觉底部留白。共享 iOS Chat 继续使用同一连续语义，并单独验证
  UIKit/keyboard 行为。
- `PlatformProfile.current` 默认 `.iOS`（最受限）：忘记设置的 target 不得意外启用 shell/workspace。
- 默认且唯一发行的 `TranslatisMac` 是 Developer ID/direct-distribution
  workbench：`project.yml` 必须指向 `TranslatisMac.DeveloperID.entitlements`，
  `AppConfig.platformProfile` 必须是 `.macDeveloperID`，macOS 主产品不得启用
  `com.apple.security.app-sandbox`。Code/Cowork 的 shell/git/browser 能力仍须
  经过 Intatis 权限链；managed terminal/git shell 继续经过 runtime Seatbelt，
  浏览器则遵守上面的专用 broker + WorkspaceLease + Chromium native sandbox
  合同，不能把两类执行器混称为同一个 Seatbelt lane。
- `IntatisSharedUI` 用 `#if canImport(SwiftUI)`，不得引入 macOS 专属 API 而破坏 Linux/无头构建。
- `swift test` 无头：不得让测试 target 依赖 UI/app target。
- 修改 per-agent inference catalog/binding/resolution/spawn/delegate/rebind/UI projection 时，至少覆盖 `InferenceProfileProtocolTests`、`InferenceCatalogTests`、`InferenceCatalogStoreResolverTests`、`PerAgentInferenceProfileTests`、`CoworkInferencePresentationTests`，并按改动范围补 Cowork/AgentKernel 既有回归。必须保留 legacy optional decode、no-default-fallback、explicit durable-options schema、unknown/shape/secret/transport/structural/multi-candidate fail-closed、package-aware `n` / `parallel_tool_calls` wire parity、safe route/trust/egress exact mismatch、provider-only strict factory 拒绝、atomic binding/model/provider tuple mismatch、catalog update/admission lock、suspended resolver + pre-prepare execution revalidation、ordinary attach review-await + bootstrap admission-wait exact revalidation、exact inheritance、busy rebind 拒绝、durable idle rebind、main/control-plane startup gate + unresolved-worker invocation durable failure/queue isolation、CLI multi-route exact credential/unique-model/reasoning/restore-main、opaque durable variant ID、diagnostic complete-URL redaction、HTTP 30x no-follow 和安全投影用例。若触及 Cowork 底部选择器，还必须覆盖 busy 时 selector 可用且当前 task 不变、Send-boundary exact freeze、A/B 多 queued submission 各自保真、后续选择不重写已接受 payload、direct worker 字段为 nil、restart/Retry 保留原值、选中 profile 不可用时 no fallback，以及 worker/reviewer/GoalVerifier/future default 不变；store 变更还必须覆盖多个独立 store instance 并发 revision allocation 无丢失/无碰撞，以及 lock 符号链接、owner、权限、普通文件和单链接 fail-closed 回归。
- 任意 host 缺 structured process 能力时，process-backed
  五个初读/五个 continuation / `ocr_pdf` / 四个 LibreOffice export / 29 个 exact write /
  `compile_latex` / `browser_*` 必须返回 typed
  权限或配置错误，不得绕过 `DeterministicPolicyGate` 使用私有执行路径。

## 不可降级项

- `EventLog` append-only：业务事件的 `append` 是唯一 mutation；除 WAL 明确授权的 partial-batch recovery truncate 外，不得原地修改或删除已提交 JSONL。append/batch 必须保留跨进程锁内 seq CAS 和 sync；多事件 batch 必须先持久化同 session/offset/prefix/连续 seq 的 WAL，再提交 JSONL，WAL 与 JSONL 的 rename/create commit 顺序必须同步父目录。初始化、append、兼容 replay/stream 与 checked replay 都不得在未恢复或无法验证 WAL 时暴露 batch 子集。production Cowork runtime 必须通过唯一公开 factory 取得并持有 session writer lease，不能允许两个调度器同时执行同一日志。
- `seq` 单调性：不得回退或重排。
- `session.json` 不得成为第二事实源：EventLog full fold 永远获胜，same-watermark/lagging cache corruption、未知未来事件、跨进程 refresh race 均必须 fail closed 或重建；rename/settings/migration 必须 EventLog-first。
- `workspace-access.plist` 不得进入日志或普通设置：bookmark bytes 必须保持 session-owned、binary、`0600`、锁/写 no-follow、原子替换及 RAII security-scope 生命周期；legacy migration marker 后不得 resurrect 全局 fallback。
- 未知未来 event 即使当前版本无法解码，也不得导致下次 append 复用它已占用的 `seq`；EventLog 初始化至少要从合法 JSON envelope 探测序号。任何合法 header 的 `session` 必须等于当前 `EventLog.sessionID`，known/unknown wrong-session 都要 fail closed。
- fresh Cowork bootstrap 与 durable token usage refresh 必须使用 `replayChecked` / `isEmptyChecked` 或复用同一已验证 snapshot；不得用兼容 replay 的空数组掩盖 lock/read/known-payload/session corruption。automatic reviewer reconcile，以及任何 authorization user-evidence mapping/closure/process，必须使用 `replayForProjectionChecked()` 并要求 `hasCompleteKnownHistory`。未知 future type 即使可跳过 payload，也必须占用 seq、算 durable nonempty state；凡是要证明某事件不存在或比较全历史顺序的 Cowork restore、Goal startup/进程内 launch、legacy no-effect repair 与 whole-task non-replayable retry，同样不得在 unknown future type 或 seq gap 时继续推断。
- per-agent inference exact binding 不得降级成 `agent.model`、session-global provider 或 catalog current pointer。现有 agent/default、data plane/control plane、inference binding/permission/tool/workspace lease 的边界必须保持分离；任何无法精确解析的 live binding 都不得调用 provider。
- shipping `hosted_web_search` Agent Tool不得退化成Chat隐式开关或browser/MCP别名；它必须只绑定同一次
  exact agent inference resolution中的provider/model/options，并同时要求明确
  `Capability.hostedWebSearch` dialect、host-bound service 和独立 `ToolCapability.hostedWebSearch` lease；
  不得从 provider/model 名称、URL、compatible wire、Chat current/default 或旧 durable lease 猜测/补 grant。
  专用工具请求必须保持 `tool_choice:required` 与 unsupported fail-closed；不得 ordinary-model fallback、
  不得改走 `browser_search` / `web_fetch` / MCP / shell / 本地浏览器 / 第二模型。Chat 仍为无 Intatis
  Tools、`tool_choice:auto` 的独立路径。该工具只有 strict required `query`，输出有界，仍须经过 schema/
  secret validation、ToolRegistry、CapabilityLease、WorkspaceLease、权限三层门、durable ticket 与
  `tool_result`。App Server共享dynamic surface只表示schema可见，绝不允许unsupported caller借用另一个
  root/role的service；root call也必须忽略任何伪造child scope。registry identity 当前为
  `intatis.standard.v5` / `intatis.cowork.v5`，Codex host toolset为namespaced `codex-business.v4`；任何旧
  authorization snapshot或runtime toolset都必须mismatch fail closed。
- `Mediator` 默认转发摘要、不转发原始字节：不得退化成透传完整内容。
- `SecretScanner` 标记集不得删减。
- Provider catalog 不存秘密本身：UserDefaults 与 `translatis.providerSelection.v1` 只能保存 provider/model/variant/secret ref 元数据，不得保存 model/variant 任意参数或明文 API key；UserDefaults/docs 不得出现明文 API key。Translatis 生成的 OpenCode-compatible provider 模板默认只能写 `options.apiKey` 的 `{env:NAME}` / `{file:path}` 等引用，不得在模板中写真实 key。macOS 设置页用户主动输入的 API key 必须写入当前可编辑 Translatis-owned OpenCode-compatible provider JSON 的 `provider.<id>.options.apiKey`，iOS 设置页用户主动输入的 API key 仍写入 app container `Translatis/auth.json`（或 `TRANSLATIS_AUTH_FILE` 指定文件）并应尝试设置 `0600`；不得写入 OS Keychain。真实 provider 请求可从 Translatis-owned OpenCode-compatible config 的 `provider.<id>.options.apiKey`、auth JSON、env 或 file secret 懒加载 secret；如果 macOS 当前 provider catalog 来自 Translatis-owned OpenCode-compatible config 且该 provider 直接声明了 `options.apiKey`，secret ref 必须绑定到该 provider config 文件本身，不得被同 provider id 的旧 auth JSON 抢先覆盖；默认不得读取 OpenCode app 的 `~/.config/opencode/opencode.json` 或 `~/.local/share/opencode/auth.json`。macOS auth JSON/secret/config 文件可能含密钥，Agent 不得读取、打印、摘要或写入其内容。启动、`needsAPIKey`、设置 UI 占位符和真实 provider 请求均不得调用 OS Keychain 查询；真实 provider 请求读取 secret 后必须复用 resolver 进程内缓存，但 provider registry 刷新时可以清空该缓存以避免旧 key 继续生效；OpenAI-compatible `Authorization` header 必须只发送单层 `Bearer <token>`，并容错剥离用户误存的外层引号或 `Bearer ` 前缀。
- 开源来源合规：允许兼容许可证的公开源码/公开 prompt 派生复用，但必须满足 `docs/OPEN_SOURCE_REUSE.md` 的 provenance、NOTICE、Apple-first 与安全集成要求；泄露/私有材料及第三方品牌/UI 资产仍禁止使用。
- Cowork 不得实现为硬编码递归 agent 树（见 `docs/COWORK_PRINCIPLES.md`）。
- legacy `AgentLoop`不得直接同步递归调用另一个`AgentLoop`；shipping Codex collaboration由App Server拥有。
- legacy自动权限审查不得通过嵌套`AgentLoop`实现；以下reviewer/sidecar规则只约束manual rollback源码，
  shipping Codex使用official auto_review且不得再包同等本地reviewer。
- legacy Cowork automatic provider-facing business tool schema必须在request-owned copy上加入required string
  `__intatis_authorization_context`并保持strict object不变量；该字段不得注入shipping Codex dynamic tool
  schema。legacy sidecar仍须在durable history/EventLog/permission identity/executor前拆除并只用stripped
  business arguments计算digest、intent、paths、risk与execution。
- sidecar 是 acting model 在同一 provider generation、同一 exact tool call 内给出的未信任压缩解释，不是 authority。它不得声明或覆盖 user authority、agent/session/task/tool identity、generation/snapshot binding、authorization ID、gate、risk、lease、path ceiling 或 permission verdict；host 必须把它绑定到 exact session/turn/task/call/tool/provider-generation/tool-snapshot/business digest。每个并行 call 独立绑定，禁止按 batch/index 共享或跨 call/cache/retry 复用。
- live automatic ask 必须把 complete canonical safe business arguments 与 complete string sidecar 作为 non-Codable、request-local transient input 交给 control plane；reviewer 另只接收机械 host facts，不接收 objective/role/deliverable/userGoal、raw/current user、assistant/history、PDF 或图片原文。valid sidecar 可保留在同一 turn 的 acting-model 内存 history 作为正确格式示例；raw sidecar 永不写入 PermissionRequest、PermissionReviewTask、EventLog 或 durable model history，reviewer transient exact-args 副本也不得复制到 permission lifecycle。只有 `permission_request.context` 保存 business digest/count 与 sidecar generation/snapshot/digest/status receipt，`PermissionReviewTask` 不复制 receipt。crash/recovery 缺 transient input 必须 deny，不得从完整 provider history 重建或重新发送 conversation/PDF。active/cached duplicate 必须复验 exact invocation，recovered allow 不得重新交付；invocation-free automatic `agent.attach` 只能走 dedicated host entry + exact prior durable admission evidence。
- missing/malformed/secret-bearing sidecar 在 permission request 和 reviewer provider 之前只写 failed/runtimeFailed `tool_result`；不得伪造 permission lifecycle、调用 reviewer或记录 denial fuse，完全相同 business args 必须允许继续纠正。binding 无法与 exact call/generation/business digest 一致时单独 typed fail closed。当前 live AgentLoop 没有固定 sidecar byte ceiling，也没有 `review_input_too_large` admission；未来若从真实 route/context budget 派生并显式启用大小门，超限必须整份 fail closed，不能静默裁切后继续。不得因 acting request 含图片就 blanket deny，也不得为补证据重发整份 PDF/图片/对话。manual permission、deterministic allow 与 hard deny 不得新增 sidecar review dispatch；人工 responder 不得收到 transient exact args/sidecar，manual/nonautomatic call 携带保留字段必须在业务执行前 redacted fail closed。
- reviewer 收到的 exact business arguments 和 sidecar 不得做静默裁切或清洗后继续 allow。若宿主不能证明其完整、安全和绑定一致，当前 automatic call 必须 fail closed；secret-bearing exact args 使用 opaque reference 或用户显式切换人工模式，不得把明文秘密发送给 reviewer。live bound reviewer reason/provider diagnostic 必须用固定宿主文案落 durable state，不能回显 transient input。Cowork shipping engine 不得注入 in-engine reviewer；误配产生的结果即使已多调用一次也必须拒绝。sidecar non-persistence 不能外推到 ordinary assistant text 或所有 acting-provider malformed error preview，后两者仍分别服从既有 message persistence 与通用 diagnostic sanitizer。
- Goal continuation 与 GoalVerifier 也不得通过嵌套 `AgentLoop` 实现；verifier 无工具且不能直接写 EventLog，只有宿主可提交最终 Goal state transition。

## 验证要求

- `make test`（`swift test`，无头）
- `make build`（`swift build`）
- 改 GUI/app：`make app`（xcodegen + Xcode）
- 改 Cowork/AgentKernel：必须加/更新对应测试（见 `docs/COWORK_PRINCIPLES.md` §8 测试期望）
- 改 provider-hosted search、legacy Agent wrapper或shipping Codex的`hosted_web_search`接线：至少覆盖
  `HostedWebSearchToolTests`、`ProviderHostedWebSearchToolServiceTests`、provider request/route tests、
  `InferenceCatalogStoreResolverTests`、`CapabilityLeaseTests` 与 `ToolRegistryLeaseTests`；必须证明 Chat
  auto/ordinary-fallback 与 Agent required/fail-closed 分流、exact provider/model/options 不串线、strict
  query-only schema、service+lease 双门、旧/read-only/reviewer suppression、browser/MCP 独立性，以及
  cancellation/incomplete stream 不结算成功；重新接线还必须在`CodexRuntimeTests`中断言authoritative
  dynamic tool catalog真实含该名称并完成`item/tool/call`往返。真实provider smoke只能补充，不能替代
  离线协议fixture。
- 改 `@main` 模型历史、恢复或上下文归一化：至少覆盖 `ModelHistoryProtocolTests`、`ModelHistoryProjectionTests`、`ModelHistoryAgentLoopTests`、`SubmittedIntentHistoryTests`、`ContextProjectionTests` 与 main continuity / worker isolation Cowork tests；必须证明 U1/A1/U2 的顺序、tool call/output 配对、崩溃缺 output、orphan output、retry attempt 选择、重启后恢复、direct/audit 去重和 `write_stdin` 不落原文。
- 改 managed terminal / PTY / shell sandbox：至少覆盖 `TerminalToolsTests`、`TerminalAgentLoopTests`、`ShellPermissionTests`、`WorkspaceSandboxDenialTests`、`CapabilityLeaseTests`、`ToolRegistryLeaseTests`、`AgentLoopPolicyTests`、`OrchestrationReliabilityTests` 与 full `swift test`；并构建 TranslatisMac 和 TranslatisiOS，证明 macOS 真终端可链接且 iOS 仍未链接本地 agent/shell 模块。
- 改 session settings/projection/workspace bookmark/bootstrap/recovery：shipping Codex至少覆盖
  `SessionStateProtocolTests`、`SessionProjectionStoreTests`、`IntatisCoreTests`与Codex fresh-root tests，证明
  strict four-event/no-provider bootstrap、同一root lease pair及partial-session拒绝；legacy/manual rollback
  变更才追加`AutomaticPermissionReviewTests`并证明旧seven-event main+reviewer合同。触及模型改名工具时追加
  `SessionNamingToolTests`、`SessionRenameAgentLoopTests`、`IntatisPermissionTests`、`ToolRegistryLeaseTests`与
  root/child tool-surface回归。两条路径都必须保留EventLog-first、owner-only bookmark、secret
  pre-authorization denial与exact-session隔离，并构建受影响macOS/iOS target。
- 改 Chat 自动命名：至少覆盖 `ChatSessionAutoTitleTests` 与 `ChatAutoTitleViewModelTests`，证明
  successful-only trigger、exact frozen route + completed seq 前缀（旧 route 不读取后续轮次）、前三
  completed segment、user/assistant 正文字段合计 6,000-Character budget（JSON 编码开销不计入）、严格
  stream/validator、官方 provider pre-byte retry 边界、Chat-only set-if-absent/manual race、跨 runtime
  attempt ledger、pre-stream cancel 不计次、pending single-flight（含 ineligible 后的较新 pending）、
  timeout/close/shutdown drain、消息/错误/busy 隔离；并构建
  `TranslatisMac` 与 `TranslatisiOS`，复核 iOS target 未链接 Tools/Permission/AgentKernel/Cowork/MCP。
- 改 permission response、pending queue、turn outcome、sandbox failure 分类或 cancel/cleanup：至少覆盖 `TurnOutcomeProtocolTests`、`PermissionSettlementTransactionTests`、`PermissionProjectionTests`、`AgentLoopOutcomeTests`、`SandboxDenialOutcomeTests`、`WorkspaceSandboxDenialTests`、`PermissionReviewControlPlaneTests`、`OrchestrationReliabilityTests`；触及 GUI/CLI 时构建对应 target，并用隔离 fixture 验证 Approve/Decline/Cancel 与 automatic non-actionable，不能用 fixture 冒充真实 provider/EventLog/executor E2E。
- 文档任务：至少 `git diff --check` + `git status --short`
- 未运行构建/测试时，最终报告必须声明"未运行构建/测试"。

# TESTING

## 外部依赖与禁止兜底验证（Vitemis 强制规则）

本项目继承 `/Users/vita/Vitemis/docs/DEPENDENCY_POLICY.md`。涉及外部能力的变更必须验证：

- exact 外部依赖可用时只调用其官方 API/扩展点，不调用第一方重复实现。
- 依赖缺失、版本不兼容或构建/签名/许可证/平台/安全条件不成立时，产生明确、可诊断失败并停止该能力。
- 失败路径不会切换到 legacy、另一 provider/backend、adapter/shim、cache、mock、简化实现或不完整路径。
- 测试 double 只存在于测试 target，不进入 production selection 或 runtime fallback。
- Review 检查新增 wrapper/adapter/facade 是否仅为官方 API 必需的最薄接线；发现核心能力复制、第二实现或静默降级即判定失败。

文档状态：当前验证矩阵
最近核对：2026-09-08
产品基线：v0.72（build 72）

历史测试数量、性能数字和事故复验保留在 Git 历史及 dated reports；它们不能替代当前
working tree 的验证。这里只记录现行命令、release gate 和最近一次真实结果。

产品入口使用 Translatis host identity：当前 CLI/product environment、活动 workspace/Knowledge
目录和 release state 采用 `TRANSLATIS_*` 与 `.translatis`；`Intatis*` package/module 名称以及
Codex 固定 `intatis` 协议字段仍按共享实现合同保留。

## 环境与产品边界

- 当前 Apple 构建环境：Xcode 27 / Swift 6.x / XcodeGen。
- macOS 默认只验证 Developer ID/direct-distribution `TranslatisMac`。
- `xcodegen generate` 后必须确认 target/scheme 清单中不存在已删除的
  `TranslatisMacAppStore`，源码/工程也不得恢复 `TRANSLATIS_MAC_APP_STORE` 或专属 App Store
  entitlements；`.macAppStore` 仅可出现在共享协议解码/隔离测试兼容路径。
- iOS 验证只覆盖 Chat 子集，不得链接 Tools、Permission、AgentKernel、Cowork 或 MCP。
- SwiftPM 测试中的 sandbox、managed terminal Seatbelt、Linux bwrap/guard、权限与路径
  围栏仍是产品安全边界，不能因为不做 App Store 而跳过。

## Codex Runtime 专项验证

Code/Cowork/CLI 内核变更至少运行：

```sh
swift test --filter CodexRuntimeTests
swift test --filter CodexNativeSubagentIntegrationTests
swift test --filter CodexRuntimePublicContractTests
swift test --filter CodexWorkTaskControllerTests
swift build --product translatis
xcodegen generate
xcodebuild -project Translatis.xcodeproj -scheme TranslatisMac \
  -configuration Debug -destination 'platform=macOS' \
  ENABLE_DEBUG_DYLIB=NO build
xcodebuild -project Translatis.xcodeproj -scheme TranslatisiOS \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' build
```

派生Codex Runtime还必须从exact upstream commit应用仓内patch并运行：

```sh
git apply --check 0001-responses-provider-passthrough.patch
git apply --check 0002-openrouter-strict-routing-shape.patch
git apply --check 0003-cowork-subagent-reconnection.patch
cargo test -p codex-model-provider-info intatis_responses_provider_preserves_opaque_object_without_changing_headers
cargo test -p codex-core intatis_provider_config_maps_to_opaque_responses_provider_body
cargo test -p codex-core serializes_intatis_opaque_provider_object_without_field_loss
cargo test -p codex-api direct_serialization_preserves_websocket_request_payload
cargo test -p codex-features
cargo test -p codex-app-server-protocol
RUST_MIN_STACK=33554432 cargo test -p codex-core multi_agent_v2 -- --test-threads=1
INTATIS_CODEX_DERIVATION_ID=0003-sha256:9cd57fc61366cb7410f6e551aa48ec762094e9a4edbfcbf0ae4670b7ba1f2285 \
  cargo build --release -p codex-cli
./target/release/codex --version
./target/release/codex --intatis-derivation-id
```

最后两行必须分别是`codex-cli 0.145.0-intatis.4`与当前0003 SHA-256派生身份。Swift host和
owner-only runtime record必须同时拒绝same-version/different-derivation binary。前三项patch构成当前exact派生源码；任何新增
dependency或lock漂移都必须另行审计。前两项patch只可在`Cargo.lock`增加
`codex-model-provider-info`对workspace既有`serde_json`的package-edge；Cargo生成的workspace package
version机械重写不得纳入patch，任何dependency版本漂移都必须另行审计。

Finder/LaunchServices启动前还必须对应用实际发现的`~/.local/bin/translatis-codex`执行同样两项检查；
不能只验证临时build目录里的binary，也不能把相同version string当作相同derivation。当前本机exact
helper SHA-256为`880dbbbd97ad3077a54296940c0c219a33ac153979126be7129a8998a4ff5685`；旧helper只以分名备份
保留，official `codex`不得覆盖。

任何交给用户或由 Finder/LaunchServices/终端直接启动的 macOS Debug 预览包都必须显式使用
`ENABLE_DEBUG_DYLIB=NO`。构建后须证明`Contents/MacOS`只含主`TranslatisMac`可执行文件，且
`otool -L`不引用`@rpath/TranslatisMac.debug.dylib`；默认Xcode 27 Debug launcher、
`TranslatisMac.debug.dylib`和`__preview.dylib`不能进入人工可运行预览。ad-hoc `codesign --deep --strict`
静态通过不证明library validation可启动，最终包还必须从其交付路径做真实进程启动smoke。

`CodexRuntimeTests` 必须同时覆盖：

- `CodexRuntimePublicContractTests`必须只使用普通public imports，不得使用`@testable`；它要冻结
  `IntatisCodexRuntime` SwiftPM product名、`CodexRuntimeHostContract` API major与exact runtime identity、
  最小外部route/configuration/session构造，以及events/start/runTurn/interrupt/approval/shutdown调用标签。
  修改`docs/CODEX_RUNTIME_INTEGRATION.md`中的v1清单时必须同步更新该compile contract；破坏既有签名须先
  提升API major并提供迁移说明。

- exact provider/model/Responses base URL 解析，custom endpoint 非 `/responses` fail closed；
- credential 的 `Bearer` 归一化与所有 description/debug redaction；
- owner-only `codex-runtime/`、`runtime.json`、`models.json` round trip，且mapping冻结exact dynamic
  toolset identity；旧runtime/缺失或不同toolset必须要求新session；
- exact executable discovery、`codex-cli 0.145.0-intatis.4` version mismatch 与same-version derivation mismatch；
- OpenRouter exact adapter的完整`options.provider`同时通过current Code route和Cowork exact
  `AgentInferenceBinding`，已知与未知nested字段逐值保持；生成的custom provider使用
  `intatis_responses_provider`，没有控制header。secret/auth/header/query/URL/endpoint material必须在
  credential resolution前fail closed且不回显；
- test-only fake App Server 的 initialize→thread/start→turn/start→official
  `commentary`/`final_answer` assistant delta/completed、reasoning delta、无需host allowlist的新notification、
  完整`thread/tokenUsage/updated.{total,last}`及`turn.durationMs`→turn/completed；必须断言只读取官方
  `last`六字段、不差分累计`total`、final-answer绑定与Input不减Cache Hit。测试double不得进入production
  selection；
- official experimental `initialize.capabilities.experimentalApi=true`与fresh
  `thread/start.dynamicTools`的flat function shape；`thread/resume`不得重发dynamicTools；fake
  `item/tool/call`必须异步执行exact client handler并回传`{success,contentItems}`，unknown/malformed失败
  不得转MCP、shell、Python或legacy runtime；
- Cowork `features.multi_agent_v2.flat_tools=true`必须把V2控制面作为top-level functions，所有
  fork模式必须继承同一dynamic tools；custom role只能使用同名host-approved workspace preset，raw
  model/reasoning/path不可见。真实`.4`离线E2E必须证明child exact route/cwd、child实际调用business
  function、verified ancestry、native control-plane message与resume metadata；不得以fake handler替代全部链路；
- relationship-filtered `thread/list`必须恢复只有inter-agent input、preview为空的spawned child；App Server
  `sessionId`不得被宿主当作root membership，完整parent chain才是authority。child resume必须重带approved
  provider/model/workspace/sandbox config；root resume response前的child usage只能有界缓存后按child重放；
- `CodexBusinessToolHost`无搜索基础目录必须精确包含71个`ToolRegistry.standard.v5`文档/浏览器registration与
  `generate_image`/`edit_image`两个exact registration，共73项；至少一个exact route有匹配hosted-search
  service时共享目录必须增加既有strict `hosted_web_search`为74项。相应无/有search时，注入session naming
  后Code root为74/75项，Cowork再加5个WorkTask后为79/80项；继续排除file/Git/terminal/agent-manager重复面。
  图片工具必须证明root与read-write child可经injected fake service完成、read-only child在permission/
  executor前拒绝、prepared authorization分别绑定`.generateImage`/`.editImage`且legacy `.generateMedia`
  不进入shipping lease；`rename_session`必须证明root成功、child在audit前拒绝、
  secret标题在authorization/prepared前拒绝、raw title不进入durable input/digest，且developer
  instructions只在工具存在时要求首任务恰好一次、Cowork rename先于run close；invalid input不得进入permission/executor；request-owned
  dynamic tool closure必须强持有该host直到runtime shutdown，不能出现“schema仍可见但executor已释放”；
- hosted-search目录必须证明root与read-write child分别调用各自预绑定的exact service，roleless descendant
  只继承最近显式role或root scope；read-only、unsupported、缺service、未知role和root伪造child scope均在
  permission/provider前拒绝。schema可见不得等同authority；必须同时覆盖strict query-only input、secret
  pre-dispatch、独立`.hostedWebSearch` lease、durable prepared/settled、official `item/tool/call`往返、
  cancellation/incomplete completion失败与shutdown。任何工具面变化必须同步toolset identity、目录计数、
  Cowork generation、CLI session salt和文档语义门；
- Knowledge augmenter存在时只允许既有`buildKnowledge`/`searchKnowledge` capability；无/有hosted search时
  Code/Cowork exact root目录分别扩为76/77与81/82项。root与verified child必须按各自host-owned capability/workspace建立scope，
  read-only只获得search、read-write才可获得build+search，未授权child在audit前拒绝。所有augmentation
  lease在runtime shutdown恰好drain，重复shutdown幂等，关闭失败必须报告；
- Code与Cowork exact model catalog都必须设置`include_skills_usage_instructions=true`。fake App Server要断言
  official `skills/extraRoots/set`携带absolute bounded host `$CODEX_HOME/skills`且发生在thread start/resume
  前；description不得泄露path。installed pinned binary smoke还需证明isolated home下repo Skill原生可见，
  设置extra root后host user Skill进入同一`skills/list`，不能调用legacy Skill tools；
- native MCP投影必须覆盖official `[mcp_servers]` URL、allow/deny filter、server/per-tool approval、required、
  parallel、startup/call timeout与public OAuth metadata；bearer/header secret只出现在process environment，TOML、
  runtime files、EventLog及description逐字节不得出现。partial capability、TTL、stdio policy、retired/
  confidential OAuth、缺失或歧义consent必须fail closed；Cowork root可使用native MCP，但显式/default
  child role与persisted resume必须载入完整secret-free disabled definition，不能继承root或切换legacy MCP
  runtime。MCP authority mutation要先drain现有App Server；macOS/CLI native grant入口必须在append前
  拒绝child/task、partial与TTL，只保存exact root完整Interactive non-expiring authority；
- 若本机有 exact pinned binary，则启动真实 `app-server`，使用 isolated temporary
  `CODEX_HOME`与本地fake Responses server完成initialize/thread/start、flat native child spawn、child
  dynamic tool、thread restore与shutdown。该测试只访问loopback且使用placeholder credential；缺binary时
  可明确skip，不能伪造通过；
- 0.145.0 exact `model_catalog_json` schema、`base_instructions`、只声明configured reasoning effort、
  `supports_parallel_tool_calls=false`、reasoning summary disabled与
  `auto_review_model_override == selected model`；不得用当前 main 的
  schema 代替 pinned release；
- event/request credential exact-token redaction、未知 server request JSON-RPC fail closed、approval
  decision mapping、interrupt/termination、response/terminal notification race。
- official `item/tool/requestUserInput`必须只在`requestUserInputHandler`非nil时把
  `default_mode_request_user_input`写为true，nil明确false；不得新增Plan/Default产品模式或同名dynamic tool。
  fake与installed fixed-binary loopback都要证明root request→typed callback→exact answer map→
  `function_call_output`→同turn继续；verified child必须携带exact AgentID，unknown/cross-root拒绝。
  另覆盖1–3 questions、2–3 options、ID/answer mapping、secret pre-presentation deny、auto-resolved notification、
  turn terminal、identity change、shutdown/process exit取消pending handler，且问题/答案不落EventLog原文。
  macOS还必须覆盖handler启用位改变persisted toolset identity、旧thread要求新session、每题exact单选、Other
  自由文本、全部问题完成前禁用提交、`⌘↩`提交，以及SharedUI/IntatisCoworkUI不取得runtime依赖或ownership；
  CLI保持nil handler与原toolset identity。

### 2026-08-26 MCP、Knowledge 与 Skills 新内核接线

- `swift test --filter CodexRuntimeTests --disable-automatic-resolution`：58/58、0 failures；其中
  `CodexRuntimeTests` 56项，bundled Skill与installed pinned native child integration各1项。新增覆盖native
  MCP official TOML/filter/approval/parallel/timeout、secret只进environment且不落盘、partial/TTL拒绝、
  Cowork显式/default role完整disabled config；Knowledge root registration、read-only build收窄、child
  explicit grant/未授权pre-audit deny、普通additional registration不能绕过scoped augmenter，以及多scope
  augmentation lease幂等drain；Code/Cowork native Skill instructions及
  `skills/extraRoots/set`先于`thread/start`。
- 同一installed pinned integration使用temporary loopback Streamable HTTP MCP与Responses server：root
  request实际出现`mcp__native_probe` namespace；显式child成功spawn并连续调用dynamic business function与
  host-approved `search_knowledge`，其request没有MCP namespace。随后完全shutdown App Server、恢复同一
  root/child并经native mailbox触发新turn，恢复child仍没有MCP。该测试证明的是fixed binary原生tool
  publication/role/resume隔离，不冒充真实第三方server或互联网兼容矩阵。
- 用本机exact `intatis-codex 0.145.0-intatis.4`和temporary isolated `CODEX_HOME`做只读协议探针：
  `skills/list(cwds=[repo])`原生发现repository `intatis-skill-creator`；随后official
  `skills/extraRoots/set`加入host `$CODEX_HOME/skills`，再次list发现user-scope `pdf`与`playwright`。
  未发送provider turn、未读取ChatGPT/Codex login或provider credential。
- 最终`swift test --disable-automatic-resolution`整仓退出0。第一次整仓运行准确暴露CLI fake App Server仍
  把第二个请求硬编码为`thread/start`，产生唯一失败；fixture改为明确验证
  `initialize → skills/extraRoots/set → thread/start`后，定向回归1/1、最终整仓均通过。没有删除新Skill
  调用、放宽协议或恢复legacy路径来迎合旧断言。
- `xcodebuild -project Translatis.xcodeproj -scheme TranslatisMac -configuration Debug -destination platform=macOS
  ENABLE_DEBUG_DYLIB=NO CODE_SIGNING_ALLOWED=NO build`在最终源码上退出0；Code/Cowork authority mutation
  会取消并等待in-flight startup、drain runtime与event task后才允许下一代配置。该证据是无签名Debug
  编译，不替代Developer ID、notarization、Gatekeeper或bundle runtime release gate。
- 本轮没有连接真实第三方native MCP server，没有完成native OAuth login/elicitation、per-child MCP grant，
  也没有开放stdio；这些边界不能从loopback测试外推。现有整仓loopback MCP client测试仍
  通过，但它验证旧client core本身，不冒充shipping Codex native MCP E2E。
- `MCPCLIProcessOwnerTests` 11/11、0 failures；新增真实loopback catalog/attachment fixture证明Codex会话内
  grant入口拒绝partial、child和TTL，省略capability参数时只落一个exact root完整Interactive、non-expiring
  grant，同时原legacy client定向用例仍可保存其原有tools-only authority。

### 2026-08-24 Cowork native subagent重新接线

- exact 0003 patch SHA-256为
  `9cd57fc61366cb7410f6e551aa48ec762094e9a4edbfcbf0ae4670b7ba1f2285`；`git apply --check --cached`、
  `cargo fmt --all -- --check`与`git diff --check`通过。current-patch Rust完成MultiAgent V2 68/68、
  `codex-state` 153/153和App Server relationship-list真实协议测试；clean arm64 release build退出0。
- 独立validation runtime为`codex-cli 0.145.0-intatis.4`，derivation为上述0003 hash，binary SHA-256为
  `880dbbbd97ad3077a54296940c0c219a33ac153979126be7129a8998a4ff5685`。同一exact binary现已安装为
  `~/.local/bin/translatis-codex`；原same-version binary SHA-256
  `61350e40759975bb4ae3669ddbbb73b1d25c4beddb34f2233abde7f7196cbde3`以分名备份保留，official `codex`
  未修改。
- `swift test --filter CodexRuntimeTests`：50/50、0 failures，其中runtime本体48项、Skill 1项、真实
  current-patch native child integration 1项；覆盖business-tool host跨setup scope生命周期、preview-empty child
  relation restore、self-valued child sessionId、完整provider config child resume、pre-root child usage、
  Goal冷启动pause、未知父链拒绝，以及root rename成功、child pre-audit deny、secret pre-authorization deny
  与条件式首任务/root-only/last-non-run-control提示。
- `CodexWorkTaskControllerTests` 5/5，覆盖跨两个EventLog/controller的same-revision唯一winner、
  in-progress合同冻结与task-name原子替换；完整`IntatisCoworkTests`退出0。`TranslatisCLITests`49项中
  41项通过、8项真实provider/计费opt-in明确skip。`CoworkAgentThreadPresentationModelTests` 10/10、
  `CoworkAgentThreadProjectionTests` 8/8、`SessionStateProtocolTests` 4/4通过。集中SharedUI运行另发现一项
  source-shape断言把live-child fallback排序误当成historical roster排序；断言已收窄到真正的
  `historicalAgentsInCreationOrder`路径；本轮focused回归已通过。
- `MCPCLIProcessOwnerTests` 10/10、`swift build --product translatis`与`TranslatisMac` Debug（独立DerivedData、
  `ENABLE_DEBUG_DYLIB=NO`、无签名）退出0；CLI已把配置文件中host-approved safe inference profiles降为
  same-workspace custom-agent presets，并继续拒绝raw endpoint/credential/options/path。
- 真实`stealth/ox-alpha`验收：root创建`ox_probe` child；child以自己的ThreadID调用
  `browser_profiles({})`并durable settled为`succeeded/committed`，返回`CHILD_TOOL_OK`，root返回
  `ROOT_OK`；`/agents`显示`intatis/stealth/ox-alpha · effort max`，`/thread ox_probe`显示child历史。CLI完全
  退出后重开同一session，仍恢复同一child/parent/model/effort/cwd/history，恢复本身没有provider turn。
- macOS Debug GUI真实重启验收：Finder可发现的exact helper启动成功，新Cowork session由
  `stealth/ox-alpha`创建原生子代理树；其中两个后代child分别调用`browser_profiles({})`，两次
  `tool_execution_settled`均为`succeeded/committed`，root等待两者并显示成功汇总；roster显示main/child
  exact模型标签，选中child可查看其独立工具与回复历史。此前弱持有host导致的
  `Intatis business-tool host is unavailable`已用生命周期测试固定。首次Gemma免费route尝试在child
  provider请求处收到429；spawn本身成功，该外部限流与最终Ox验收分开记录。
- Goal回归确认：冷启动先official `thread/goal/get`，active时`thread/goal/set(status=paused)`，再
  `thread/resume`；`/goal`不额外`runTurn`，edit/clear继续核对official response。只有显式Resume才恢复active。

### 2026-08-24 Codex session重命名重新接线

- `swift test --filter SessionNamingToolTests`：5/5；确认authorization identity只含标题字符数，不含raw
  标题。`swift test --filter 'SessionRenameAgentLoopTests|IntatisPermissionTests|ToolRegistryLeaseTests'`：
  2/2、56/56、27/27，0 failures。
- `swift build --product translatis`、`xcodegen generate`、`TranslatisMac` macOS arm64 Debug unsigned和
  `TranslatisiOS` generic Simulator Debug unsigned均退出0。macOS构建使用独立
  `/private/tmp/IntatisDerivedData-session-rename`、`ENABLE_DEBUG_DYLIB=NO`；bundle的`Contents/MacOS`
  只有`TranslatisMac`，`otool -L`无debug/preview dylib。
- Computer Use在该新Debug App中新建`cowork_io2khx37`，选择免费`stealth/ox-alpha`，只发送“请计算
  17 × 19，并用一句话说明计算过程”，未提出改名要求。运行中侧栏和页面标题从raw SessionID同步变为
  “17×19=323 口算问答”，随后正常显示最终答案与Completed。
- 同session EventLog证明模型先发`rename_session`；输入arguments在`model_history_item`与`tool_call`均为
  固定redacted placeholder，deterministic allow后依次写prepared、`session_settings_updated`（source
  `model_tool`、同execution operation ID）、succeeded/committed。下一次function call才是`finish_run`，
  最后`turn_outcome=completed`。因此验收覆盖模型提示、普通工具调用、root权限、持久化与UI刷新，不是
  宿主隐藏自动命名。

### 2026-08-23 document/browser dynamicTools直连

- `swift test --filter CodexRuntimeTests`：25/25、0 failures；覆盖71-tool目录、flat
  `thread/start.dynamicTools`、resume省略字段、fake `item/tool/call`完整往返、toolset mismatch要求新session、
  `.2`及更早runtime全部拒绝，以及installed exact `0.145.0-intatis.3`的真实experimental offline
  handshake。未发送provider turn、未读取真实credential。
- SwiftPM同次构建成功编译`IntatisCodexRuntime`与`translatis` CLI新增接线。
- `swift build --product translatis`退出0；`TranslatisMac` Debug unsigned增量build使用locked package
  resolution与独立`/private/tmp/intatis-dynamic-tools-build` DerivedData退出0。只观察到仓库既有deprecated/
  unused-result warnings；本轮未生成发行预览包，也未做签名/启动声明。
- 本节验证没有MCP server、旧AgentLoop/Orchestrator、shell/Python替代或备用backend进入production
  selection。

### 2026-08-23 App Server事件直出第一版

- `swift test --filter CodexRuntimeTests --disable-automatic-resolution`：22/22、0 failures；fake full turn
  覆盖官方`commentary`/`final_answer`、reasoning delta、`thread/tokenUsage/updated`无需method allowlist
  进入active-turn事件流，并继续覆盖installed exact runtime offline handshake。
- `swift test --filter 'IntatisProtocolTests|IntatisConversationCodeTests|ExecutionTracePresentationTests|ThreadLayoutTests'
  --disable-automatic-resolution`：Protocol 108/108、Conversation 19/19、SharedUI 38/38，合计165/165、
  0 failures；覆盖phase/event envelope round trip、legacy nil phase、event delta coalescing、commentary不
  冒充task completion、灰色caption样式与Code/Cowork不再挂载synthetic Thinking row。
- `swift build --target IntatisSharedUI --disable-automatic-resolution`与
  `swift build --product translatis --disable-automatic-resolution`均通过；`xcodegen generate`退出0。
- `TranslatisMac` macOS Debug unsigned build以`ENABLE_DEBUG_DYLIB=NO`、独立
  `/private/tmp/IntatisDerivedData-response-events`退出0，仅有仓库既有warnings。最终
  `dist/Intatis-Responses-Events-Preview.app`以Developer ID entitlements做ad-hoc Hardened Runtime
  签名，strict deep verify通过；`Contents/MacOS`只有主`TranslatisMac`，`otool -L`无debug/preview dylib，
  主程序SHA-256为`8c553d6d631acd7334cf52ea3d77b58689d840ff81ec0fa76d918ea799d7c3c9`。
  LaunchServices从最终路径启动后精确进程路径读回并持续运行。
- 本轮未运行完整`swift test`、iOS build、真实外部provider/credential/计费请求、Developer ID正式签名、
  公证、staple、Gatekeeper或干净机验证；不得从本轮focused/Debug/ad-hoc证据外推这些门槛。

### 2026-08-23 Responses usage第一版与真实事件修正

- `IntatisProtocolTests`：108 tests / 0 failures；新增`responses_usage` envelope round trip通过。
- `CodexRuntimeTests.testAppServerTurnStreamsOfficialLifecycle`：1/1；离线fake App Server复刻真实顺序
  `item/completed → thread/tokenUsage/updated → turn/completed`，并故意令累计`total`与`last`不同；断言
  只采用exact `last`的150/100/10/30/10/180、duration 1234ms及`message-fake` final-answer绑定。
- `IntatisConversationCodeTests.testResponsesUsageAttachesToExactFinalReplyAcrossEventOrder`：1/1；覆盖
  usage-first和message-first，未把stats猜到相邻回答。
- `ThreadLayoutTests.testPerMessageMetricsPreserveNativeResponsesSemantics`与
  `testMacReplyFooterUsesNativeResponsesMetricsAndDefersCodeCoworkContext`：各1/1；确认Input保持完整值、
  七标签齐全、Code/Cowork不含旧Context strip。
- `xcodegen generate`退出0；`TranslatisMac` macOS arm64 Debug unsigned build以
  `ENABLE_DEBUG_DYLIB=NO`和`CODE_SIGNING_ALLOWED=NO`退出0。首次Xcode编译额外暴露并修正
  dynamic-tool task的`Task<Void, Never>`类型收窄；增量重建成功。
- `dist/Intatis-Responses-Usage-Preview.app`使用独立bundle identifier，ad-hoc Hardened Runtime strict
  deep verify通过。Computer Use读取真实窗口AX树并截图，七项全部可见且未裁切；该证据只覆盖离线
  footer fixture，不能证明production runtime会生成usage。
- 真实Cowork EventLog/rollout只读审计确认缺失点位：UI收到公开`thread/tokenUsage/updated`但
  `responses_usage`计数为0；同turn rollout的`last_token_usage`六字段与`duration_ms`完整。审计没有输出
  credential或完整对话正文。
- 修正后再次运行Protocol 108、Conversation 20、SharedUI 38，合计166 tests / 0 failures；runtime
  lifecycle定点测试另为1/1。新的独立DerivedData macOS arm64 Debug unsigned `TranslatisMac` build退出0。
- `dist/Intatis-Token-Usage-Event-Preview.app`走production UI/config路径，独立bundle ID、单一arm64主
  Mach-O、ad-hoc Hardened Runtime strict codesign通过；主程序SHA-256为
  `d68e95c532c6cc88d57299988e055c43f18343c29a4dfe42abd828eba9645d6e`。没有替用户发送真实provider
  turn；旧EventLog不会回填，需用新turn做人工确认。
- 未运行完整`swift test`、iOS build、真实provider/credential/计费网络、Developer ID签名、公证、
  staple、Gatekeeper或干净机验证。上下文窗口明确未接入，不能从catalog metadata外推UI占用。

### 2026-08-23 完整连续会话与16-row rich预算纠正

- 用户明确确认`16`只应限制同一时刻的重型富文本渲染，不应成为Earlier/Newer/Latest数据分页。
  Chat、Code、Cowork和每代理thread现统一使用`IntatisContinuousThreadStack`：完整消息序列保持在一个
  普通ScrollView中，row由lazy materialization按需创建；`IntatisContinuousThreadRenderBudget`只给最多
  16个可见row保留native rich-document graph，离屏row调用rich eviction并继续显示exact raw text。
- `CodeProjection`/`SessionProjectionPump`/`CoworkAgentThreadPresentationModel`不再暴露page、capacity、
  requestedUpperBound或per-agent page boundary；窗口只查询当前选中agent的完整有序snapshot，其他agent
  rows仍留在projection actor，A→B→C generation fence、non-selected publication suppression和双窗口隔离
  保留。
- focused组合回归为120 tests / 0 failures：SharedUI 112（`MessageRenderingTests`39、
  `ThreadLayoutTests`32、`ThreadScrollCoordinatorTests`31、
  `CoworkAgentThreadPresentationModelTests`10）+ Conversation
  `CoworkAgentThreadProjectionTests`8。覆盖0/1/16/17/1,000行完整snapshot、8,000 rows下1,000次选中查询、
  16-row rich cap、离屏eviction、无pager/source contract、agent切换、scroll fence和rich lifecycle。
- `swift build --target IntatisSharedUI --disable-automatic-resolution`、`xcodegen generate`、
  `TranslatisMac` macOS Debug unsigned build（`ENABLE_DEBUG_DYLIB=NO`）和`TranslatisiOS` generic Simulator
  Debug unsigned arm64+x86_64 build均退出0。iOS解析阶段出现GitHub cached-repository update的临时
  LibreSSL失败诊断，但本地exact checkout解析完成且最终`BUILD SUCCEEDED`；不能把缓存网络噪声记成源码失败。
- production-surface离线Cowork fixture使用8个agent×每个1,000 rows、4-agent合计500 canonical delta/s。
  Computer Use从`@main`第991–1,000条直接跳到第1–10条并保持在历史顶部，没有产品分页按钮，也没有被
  后台delta抢回；返回底部后切换`@research`显示其独立第991–1,000条。1,000 rapid switches通过，
  final `@docs`、warning 0、incident 0。180秒soak完成763 timed switches，heartbeat 777、warning 0、
  incident 0；最终`@writer`恢复第991–1,000条。
- soak中/后`ps` RSS为184,368/184,384 KiB，未随剩余运行增长；`vmmap` physical footprint 67.0 MiB、
  peak 124.4 MiB；`heap`中`NSTextViewSharedData`为5、`Gestures.GestureNode<()>`为86。该fixture不打开
  EventLog、provider、workspace、permission runtime或credential，只证明连续presentation和资源生命周期。
- 本次未运行完整`swift test`、Developer ID正式签名、公证、staple、Gatekeeper、真实provider或低端真机；
  focused和Debug证据不能替代这些完整门槛。

CLI 无网络 smoke 可使用不可连接的 loopback Responses URL，只验证 runtime startup/exit：

```sh
TRANSLATIS_BASE_URL=http://127.0.0.1:9/v1 \
TRANSLATIS_API_KEY=offline-placeholder \
TRANSLATIS_MODEL=offline-test-model \
  .build/debug/translatis code /absolute/test/workspace
# 出现 Codex Runtime 0.145.0-intatis.4 ready 后输入 /exit
```

必须确认该 smoke 使用新的 `CodexRuntimeCLI`；`translatis code|cowork` 不得进入
`AgentRuntime.code` 或 `coworkREPL`。`translatis exec`必须明确拒绝且`runExecCommand`保持编译期
unavailable；`translatis chat`继续使用ChatLoop。

session identity必须单测/手测三类：只有valid `.4`、当前0003 derivation且dynamic toolset identity完全相同的
`runtime.json`可resume exact thread；`.3`及更早runtime、same-version/different-derivation、缺失/不同toolset全部显示
`threadMigrationRequired`并要求新session；EventLog已有legacy agent history但没有mapping时同样不创建
空thread。missing/mismatched
binary、unsafe mapping、provider不是原生 Responses、App Server schema error 都必须可诊断且没有 legacy
fallback。

真实 provider E2E 不是默认测试：只有用户明确允许该 exact route 的网络/计费调用后才能运行，并必须
报告 model、turn status、工具/approval覆盖与 provider usage，不得打印 URL、credential 或完整响应。

发行前除普通 macOS gate 外，还必须从固定 Codex source/Cargo.lock 建 arm64+x86_64，保存 binary hash与
完整第三方 license/NOTICE closure，把 nested executable 先签名再签 outer App，并验证 notarization、staple、
Gatekeeper、fresh-account startup 和 final bundle 中 `codex --version`。当前 external local install smoke
不能替代该 gate。

## 版本一致性

```sh
xcodegen generate
scripts/check-version-consistency.sh
# 或仅运行同一门槛：make version
```

必须同时满足：

- `project.yml`：`MARKETING_VERSION=0.72`，`CURRENT_PROJECT_VERSION=72`；
- macOS/iOS 参考 Info.plist：`0.72 (72)`；
- 生成的 `Translatis.xcodeproj`：相同版本；
- README、文档索引、CURRENT_STATE 和 PROJECT_MAP：相同当前基线；
- 最终 App bundle：`CFBundleShortVersionString=0.72`、`CFBundleVersion=72`。

旧设计文档、依赖版本、协议 schema 和 dated reports 中的其他 v0.x 不属于该一致性检查。

## SwiftPM 基线

```sh
swift build
swift test
```

外层 managed sandbox 若阻止 nested Seatbelt、process spawn 或 loopback bind，应在允许的真实
host 环境重跑，不能把 sandbox 环境失败直接改写成产品失败，也不能把跳过冒充通过。

高风险改动至少补充对应 focused suite：

```sh
swift test --filter IntatisProvidersTests
swift test --filter IntatisConversationTests
swift test --filter IntatisToolsTests
swift test --filter IntatisPermissionTests
swift test --filter IntatisAgentKernelTests
swift test --filter IntatisCoworkTests
swift test --filter IntatisSharedUITests
swift test --filter IntatisCoworkUITests
```

修改`IntatisCoworkUI`、TranslatisMac Cowork adapter或跨项目右侧UI合同，还必须运行：

```sh
swift build --target IntatisCoworkUI --disable-automatic-resolution
swift test --filter IntatisCoworkUIPublicContractTests \
  --disable-automatic-resolution
swift test --filter 'CoworkInferencePresentationTests|ThreadLayoutTests' \
  --disable-automatic-resolution
```

public contract测试必须普通import UI product，并source-check其direct target/source不含
CodexRuntime、AgentKernel、Cowork runtime、Tools、Permission、MCP、`CoworkViewModel`或
`dynamicTools`。还必须确认App-owned `CoworkViewModel.swift`仍存在、TranslatisMac只做state/action映射、
iOS产品图不链接UI product。

修改共享provider streaming runtime时，还必须覆盖默认initial + 5 reconnects及1/2/4/8/16秒退避、
status/heartbeat/尚未yield的tool-call fragment后可重连、text/完整tool call/usage/done任一交付后禁止重放、
取消不重连，以及hosted-search unsupported fallback仍使用独立typed acceptance fence。测试不得继续把
“收到任意raw byte”等同于“consumer已经收到语义输出”。

修改 Cowork automatic permission sidecar / reviewer 时，至少运行：

```sh
swift test --filter PermissionReviewProtocolTests
swift test --filter AuthorizationSidecarTests
swift test --filter IntatisPermissionReviewerTests
swift test --filter PermissionReviewControlPlaneTests
swift test --filter AutomaticPermissionReviewTests
swift test --filter DurableMultimodalAgentLoopTests
```

必须覆盖 provider-facing schema decoration（普通/strict/namespace/deferred/collision）：reserved sidecar 是
request-owned provider schema 中的 required string property；对任何 `strict:true` function，必须递归断言
`required == properties.keys` 且 `additionalProperties:false`，生产装饰器也必须在发网前递归 fail closed。
`tool_search` 本身保持不变；provider-bound `tool_search_output` 中的 deferred function/namespace children
必须装饰，同时断言原消息与 durable output 不变。原 business descriptor/schema 不变，只有
deterministic gate 到达 automatic ask 时宿主才消费并验证 sidecar。还要覆盖
sidecar 拆包与 canonical business args、同文案变化不改变 digest/intent/path/retry identity、executor 永不看到
保留字段、同 batch 多 call 独立绑定、valid sidecar 出现在同 turn 下一次 acting request 但不进入 EventLog/durable
model history、reviewer transient exact-args 不进入 permission lifecycle、stripped business call 仍服从既有
bounded/secret-safe history/audit 规则、permission-request receipt round-trip、legacy optional decode，以及图片/PDF
history 不触发 blanket deny 或 full-context resend。missing/malformed/secret-bearing sidecar 必须只写
failed/runtimeFailed `tool_result`，产生 0 个 permission/review event、0 次 reviewer dispatch、0 次 denial-fuse
消耗；必须有同 business args 的 missing → missing → valid 回归。binding mismatch 则单列为 typed fail closed。
另须证明 hard deny、deterministic allow 与 manual flow 不调用 reviewer/不接收 transient input；reviewer prompt
得到 complete safe args + complete string sidecar + mechanical host facts，并负断言 objective/role/deliverable/
userGoal/raw user/assistant history/PDF marker 不存在；gate/lease/authorization 仍为 host authority；plain-text
verdict 对旧 JSON、tool call、无 completion、非成功 finish、多/缺 marker、timeout/cancel/provider/persistence
failure 全部 fail closed。还必须覆盖 manual/nonautomatic 保留字段在 business execution 前拒绝；automatic
responder 缺 bound overload、active/cached duplicate 缺失或更换 invocation、recovered allow 再交付均拒绝；
invocation-free host
`agent.attach` 只能经 dedicated entry + exact prior durable events；live reviewer reason/provider diagnostic 不会
回显 transient input 到 durable state；误注入 in-engine reviewer 的结果不能获得执行权。

得到用户明确的真实网络与计费授权后，还应对当前 exact Agent route 运行：

```sh
TRANSLATIS_REAL_TOOL_SHAPE_DIAGNOSTIC=1 swift test --filter RealProviderSmokeTests/testRealAgentAuthorizationSidecarShapeWhenEnabled
```

该 smoke 使用 `strict:true`，只验证当前 exact Agent route 接受 required string sidecar property，并在 prompt 明示需要时返回
可拆分的 valid sidecar + business arguments；ask-only host enforcement、binding、secret scan、durable isolation 与 fail-closed
语义仍必须由上述离线测试覆盖。本轮尚未运行该真实 provider smoke，不能从 scripted provider 测试外推
线上 route 的 sidecar compliance、token 或 latency。

MCP、browser、managed terminal、OAuth、real provider 和设备测试中明确标为 opt-in 的项目，
必须在具备相应 runtime/credential/网络的环境单独执行。

### OKF / RAG knowledge bundle 专项

修改 OKF/Profile 合同、Validator、build/publish、embedding/index、snapshot store、mount、
`search_knowledge`、final grounding 或 Code/Cowork augmenter 时，至少运行：

```sh
swift build --target IntatisKnowledge --disable-automatic-resolution
swift test --filter IntatisKnowledgeTests
swift test --filter KnowledgeModelProviderTests
swift test --filter CLIProviderAdapterTests
swift test --filter ModelDrivenKnowledgeAgentLoopTests
swift test --filter TurnGroundingEvidenceRegistryTests
swift test --filter ToolRegistryLeaseTests
```

其中 Knowledge suite 必须覆盖：

- 9 份 strict JSON Schema、bounded OKF YAML、alias/custom-tag safety classification；任意层非保留
  `.md` concept 与任意层 `index.md` / `log.md` reserved shape；host-owned canonical v0.2
  writer 对 legacy `timestamp` / `# Citations`、strict `generated.by/at`、footnote claim/definition/source-ID
  join、multi-source per-chunk attribution、bundle-local path、scope descriptor和私有路径的迁移/拒绝；
  source locator exact adapter/revision replay 与 custom registry digest
  continuity；
- WorkspaceLease/root identity、no-follow/owner-only/single-link、path/byte/count/depth bounds、checksum
  inventory/completeness、content-seal/TOCTOU、staging/atomic pointer、reader isolation、retention/GC、
  explicit A/B admission、receipt invalidation、exact purge tombstone 的 concurrent writer race 和
  current/non-current urgent purge；staging、snapshot rename、
  pointer replace 与 GC 四个 crash boundary 均只恢复为完整 old/new/no-current 状态；
- embedding identity 任一支持的语义字段变化都全量 re-embed；不支持的 scalar/quantization/
  normalization/similarity/truncation 明确拒绝。dense zero/non-unit/NaN/Inf/dimension/missing/orphan/
  duplicate 和 lexical tokenizer/count/digest/missing/orphan/duplicate 都有负向验证；
- canonical `chunks.jsonl` 与 manifest digest 在不同运行时钟下 bit-stable；Validator 对同一
  snapshot/policy/registry 双跑报告一致且不调用 embedding/network；build cancel/timeout
  不发布 pointer、不留 validation receipt；
- frozen dense-only/lexical-disabled/optional-unbound/hybrid-required route 精确执行；dense exact +
  BM25 + RRF、status/trust/OKF date-only `stale_after` 和 host ACL 在 Top-K 前过滤、
  optional/required exact reranker、unanswerable、增量修改/删除、prompt-injection data-only、
  secret fail-before-embedding、bounded/truncated result packing、hard deadline cancel+join；
- dynamic bound/unbound inputSchema、typed `TOOL_INPUT_INVALID`、MCP-compatible complete envelope、
  stable evidence ID、真实 direct success，以及 final 前 exact snapshot reopen/hash/locator revalidation；
- Code/Cowork opt-in 走真实 AgentLoop 的 capability/permission/prepared/tool_result/settled 链，mailbox
  窄 capability 时工具完全缺席，close/shutdown 会 cancel/drain mount；snapshot-bound dynamic
  registration 必须保留 instance-owned local/remote intent，本地 `search_knowledge` 复用现有只读
  deterministic allow 且不产生 permission/reviewer lifecycle，network-backed instance 仍进入审查。
- canonical `embedding_model` / `reranker_model` decode 与 exact independent route；Knowledge-only provider
  可以没有普通 inference models。任一 role/dialect 不可用时，secret、network、store 与 bookmark
  副作用前 fail closed；credential 必须在真实 embedding/rerank dispatch 内才解析；official-shaped
  embedding/rerank fixtures 必须证明 endpoint、payload、result index/permutation 与 bounded candidates。
- path-aware `build_knowledge` / `search_knowledge` 的 closed input/output schema 与 host strict validation、
  provider strict 仅在所有 properties 都 required 时启用、existing-store 双 ID CAS、
  workspace/external authority 分流、read-only/broad/sensitive/root-swap/父目录替代/撤权，以及 raw bookmark
  与 safe projection 分离；bookmark sidecar lock 必须拒绝 symlink/hardlink 等 unsafe inode。至少一个
  真实 AgentLoop turn 应查询两个 exact store，并证明每个成功结果
  `rerank_applied=true`、current-turn citations 不串 snapshot、scope 在 grounding 后 drain。
- `.translatis-rag-store.json` / `.translatis-rag-snapshots` / `.translatis-rag-host` 必须由普通 file/patch/
  Git/process 与实际 managed-terminal anti-bypass 回归覆盖；legacy `snapshots/` 只能由 writer 原子迁移，
  read-only open 不得创建基础设施，dual layout 必须拒绝。pointer/layout rename 的 post-commit
  uncertainty 必须返回 non-retryable typed failure；checked augmentation close 必须证明 false drain 不会
  结算为成功且 repeated close 仍 single-flight。

质量测试必须冻结 corpus 与阈值，至少记录 Recall@5、MRR、nDCG@5、unanswerable、citation
coverage/precision、index bytes、memory proxy 和 deterministic latency proxy。Apple NaturalLanguage
不可用时只能 `XCTSkip`；开发机 arm64 结果不能外推 Intel 真机。x86_64 编译、Intel 上 exact
language/revision/dimension availability 和质量、真实 remote embedding/reranker credential/network smoke
必须分开记录，缺一项就标 `UNKNOWN`，不得静默换模型或宣称 universal runtime 已验证。

真实 Knowledge route 是显式付费 opt-in：

运行前先在 `TRANSLATIS_CONFIG` 指向的 Translatis JSON/JSONC（或默认 Translatis-owned 配置）中确认顶层
`embedding_model`、`reranker_model` 均为完整 `<provider>/<model-id>`，且两个 provider 的
`options.baseURL`、`options.apiKey` 引用和 `npm` adapter 与实际服务一致。可复制的无 secret 配置 shape
见根目录 `README.md` 和
`codex-report/08_10_26-16_57-model-driven-knowledge-tools-design.md` §4.1。CLI 的 `/config` 必须显示
`knowledge ready`；该状态必须来自与真实 provider 构造共用 configuration builder 的同步预检。字段缺失、
endpoint 不存在、embedding 维度不明或 adapter 不受支持时应在解析/组装阶段失败，不得先解析 credential、
发网、取得 bookmark 或触碰 store。

```sh
TRANSLATIS_REAL_KNOWLEDGE_SMOKE=1 swift test \
  --filter RealProviderSmokeTests.testRealKnowledgeEmbeddingAndRerankerWhenEnabled

TRANSLATIS_REAL_KNOWLEDGE_QUALITY=1 swift test \
  --filter RealProviderSmokeTests.testRealKnowledgeRerankQualityWhenEnabled

TRANSLATIS_REAL_KNOWLEDGE_AGENT_E2E=1 swift test \
  --filter RealProviderSmokeTests.testRealModelBuildsSearchesAndCitesExternalKnowledgeWhenEnabled

TRANSLATIS_REAL_KNOWLEDGE_PDF_E2E=1 \
TRANSLATIS_REAL_KNOWLEDGE_PDF_SOURCE=/absolute/path/to/pdf-directory \
swift test \
  --filter RealProviderSmokeTests.testRealModelBuildsSearchesAndCitesPDFKnowledgeWhenEnabled
```

第一条使用当前高级配置的 exact `embedding_model` / `reranker_model` 各发一个最小请求；第二条在冻结
的中英/代码 corpus 与 ground-truth queries 上分别报告 embedding-cosine baseline 和 configured semantic
reranker 的 MRR/nDCG@5/Recall@5；两个入口同时汇总 provider 实际返回的 token/billable units，未返回
时打印 `unreported`，不按可变价目表推算金额。第三条让当前配置的真实 Agent、embedding 与 reranker
执行“读取资料 → 整理 draft → 外部建库 → 检索 → 引用”；第四条先把指定目录中三个冻结 PDF 复制到
隔离临时 workspace，再要求 Agent 用 `read_pdf` 读取冻结页段、建立三主题库并回答。原始 PDF 不得修改。
后两条会产生多次可计费请求。执行任一入口前必须由用户提供或确认配置、credential、网络、费用与所需
资料外发授权；默认 `XCTSkip` 不能记为通过。这四条仍不能替代 macOS NSOpenPanel/bookmark 跨重启
restore 交互验收。

macOS external bookmark 手动验收必须使用 Developer ID/Debug `TranslatisMac`（不使用 legacy App Store
target）：在 Code 中用自然语言给出一个 workspace 外的精确 `store_path`，批准 tool permission 后在
NSOpenPanel 只选择该目录；核对当前 session 的 `knowledge-access.plist` 是 binary、owner-only `0600`，
且只含 exact normalized path、opaque bookmark、revision 与 digest。随后退出 App、重新启动、恢复同一
Code session 并再次调用同一路径：不得再次出现授权面板。换 session、不同路径、root identity 漂移或
撤权后仍必须重新授权；测试时不得打印 raw bookmark bytes。

### 文档原子工具链专项

修改文档 schema、fixed backend、staging/commit、registry、permission、lease 或 release runtime 时，
至少运行：

```sh
swift build --target IntatisTools --disable-automatic-resolution
swift build --target IntatisToolsTests --disable-automatic-resolution
swift test --filter DocumentReadToolSplitTests
swift test --filter DocumentToolContractTests
swift test --filter DocumentInfrastructureTests
swift test --filter PDFNativeDocumentServiceTests
swift test --filter DocumentPythonWriteBackendTests
swift test --filter DocumentFixedBackendsTests
swift test --filter DocumentToolsIntegrationTests
swift test --filter CapabilityLeaseTests
swift test --filter ToolRegistryLeaseTests
swift test --filter IntatisPermissionTests
swift test --filter AgentLoopPolicyTests
zsh -n scripts/validate-document-runtime.sh
zsh -n scripts/package-macos-release.sh
plutil -convert xml1 -o /dev/null Packages/IntatisTools/Runtime/document-runtime/release-spec.json
xcodegen generate
```

外层 managed sandbox 若阻止 SwiftPM manifest/Seatbelt/process spawn，必须在允许 SwiftPM 自有 sandbox
的 host 环境重跑并记录两次结果；不能把环境性失败或零测试匹配冒充通过。

真实 external runtime 只允许显式 opt-in：

```sh
INTATIS_REAL_DOCUMENT_RUNTIME_SMOKE=1 \
  swift test --filter DocumentToolsIntegrationTests/testInstalledDocumentRuntimeExactDOCXChainWhenEnabled
INTATIS_REAL_DOCUMENT_RUNTIME_SMOKE=1 \
  swift test --filter DocumentToolsIntegrationTests/testInstalledDocumentRuntimeOCRWhenEnabled
INTATIS_REAL_DOCUMENT_CORPUS_ROOT=<external-corpus-root> \
  swift test --filter DocumentToolsIntegrationTests/testInstalledDocumentRuntimeReadsUserCorpusWhenConfigured
```

外部 corpus 只能复制到临时 workspace，不能修改来源或把个人绝对路径写入仓库。release root 验证
另要求真实 Developer ID identity：

```sh
scripts/validate-document-runtime.sh <arm64-root> arm64 '<Developer ID Application identity>' static
scripts/validate-document-runtime.sh <x86_64-root> x86_64 '<Developer ID Application identity>' static
```

`execute` mode只允许 runtime 已位于最终 signed App 的
`Contents/Resources/DocumentRuntime/<arch>` 且 outer resource seal 已验证时使用。

专项必须证明：

- fresh standard/Cowork registry 是 v5，包含 inspect/read、五组 reader/continuation、OCR、单页
  render、四个 exports 与 29 个 writes，且不包含五个 legacy aggregate names；
- 每个 schema 闭合，无 `format/mode/operation(s)/backend/engine/command/environment`；
- 初读 cursor/landmarks 与 continuation 绑定 source SHA；来源改变 typed conflict；
- `inspect_pdf` / `read_pdf` 返回 identity，image-only PDF typed `ocr_required`；
  `ocr_pdf` 固定 Tesseract 5.5.3 English/PSM3/full-page，错误不切换引擎；
- `pdf_render_page` 每次只输出一页 PNG；Office/HTML 必须先独立 export，再等真实 ToolResult；
- 29 个 write route 每个都在 Python route table 有 concrete official API，且不存在 aggregate write/
  verify/recalc/preview/HTML write/EPUB write/chart/range/style/table/name route；
- HTML export 不调用 Python/lxml sanitizer，只机械 stage PathConfinement 审查的 local assets 后调用
  `WKWebView.createPDF`；生成 PDF 只做机械文件验收，不跑 pdfcpu/render smoke；
- source/destination/auxiliary-input identity、no-clobber、CAS/cancel/backend failure、pinned parent、
  no-follow commit、output budgets、timeout/descendant cleanup 与 2 GiB aggregate RSS 均 fail closed；
- `compile_latex` 只产生 `.tectonic` invocation，固定 0.15.0 +
  `--untrusted --only-cached --outdir`，不出现 shell/command-v/latexmk/xelatex/pdflatex；
- legacy capability 可以最窄映射 concrete registrations，但 fresh lease 不签发 aggregate raw values；
  除 inspect/read PDF 共享 `readPDF` 外，每个 exact tool 的 capability raw value 与 tool name 一致，
  PermissionIntent action 带 exact tool 语义；v4 authorization snapshot 被 v5 registry mismatch 拒绝；
  read-only worker 只获得 inspect/read/continuations/OCR，不获得 mutation tools；
- release validator 拒绝 pin/hash/SBOM/license/Mach-O architecture/load command/RPATH/signature 漂移，
  release script 在 stage 前后和 outer App seal 后复验两个 architecture roots；
- `TranslatisiOS` target dependency graph 与最终 bundle 均不含 IntatisTools/DocumentRuntime；Chat 产品面
  仍存在。图片工具、SwiftUI、字体、颜色、排版、资产与 localization 不应出现在本专项 diff 中。

真实 runtime 报告必须逐项记录 executable/package/model/cache 的 exact version、hash、architecture、
signature 与缺失条件。开发机 user-managed root 只能证明 debug/CLI smoke；不能代替双架构 App bundle、
SBOM/license、notarization、Gatekeeper 或 clean-machine proof。
### Chat 自动命名专项

涉及 Chat 自动命名、session set-if-absent 或 ChatViewModel 自动标题接线时，至少运行：

```sh
swift test --filter ChatSessionAutoTitleTests
swift test --filter ChatAutoTitleViewModelTests
swift test
```

专项必须覆盖成功回合才触发、主回合失败/取消不触发、同一 exact provider/model 的隐藏两消息请求、
无 tools/web search/citation/附件、冻结 completed seq 前缀且旧 route 不读取后续轮次、最早三个可证明
completed segment、歧义 fail closed、user/assistant 正文字段合计 6,000 个 Swift
`Character` 上下文预算（JSON 编码开销不计入）、前三次 attempt/`NO_TITLE`、single-flight/pending/timeout、官方 provider 在首个
response byte 前至多一次 transport retry 且不额外消耗逻辑 attempt、收到 byte 后不 retry、严格
done/EOF（usage 可位于唯一 done 前或后；done 后正文/citation/重复 done 拒绝）与格式/敏感内容
validator、Chat-only EventLog set-if-absent、手工 Rename 竞争、跨 runtime
attempt ledger、pre-stream cancel 不计次、ineligible 后消费较新 pending、recent 排序不变、Chat
消息/error/busy 隔离、官方 provider request-owned stream termination，以及 shutdown cancel+await。

macOS/iOS host 另须确认 verified commit 发布时 EventLog 与读回 projection 已存在；重复/迟到
revision+seq 被丢弃；iOS 在 A→B 后收到 A commit 只更新 A row/header，不改变 B；目标依赖图仍是
7-product Chat 子集。真实 provider smoke 要另外记录 provider/model、是否首轮命名、15 秒可见性与
失败静默；单元测试和编译不能替代该联网产品验收。

2026-08-13 Chat/iOS 自动标题尾随 usage 修复与 Code/Cowork 首轮 prompt-only rename 的直接证据：

- `ChatSessionAutoTitleTests` 24/24、`ChatAutoTitleViewModelTests` 3/3、
  `ContextProjectionTests` 23/23，均为 0 failures；
- `swift build --disable-automatic-resolution`、`TranslatisMac` macOS Debug unsigned build 与
  `TranslatisiOS` generic Simulator Debug unsigned build 均退出 0；iOS 增量复核明确输出
  `BUILD SUCCEEDED`，首次构建仅出现仓库既有 warning 与一条 exit-code-0 Swift driver 噪声诊断；
- 一次完整 `swift test --disable-automatic-resolution` 已完成 `IntatisToolsTests` 227/227
  （19 个显式 opt-in smoke skipped）、`IntatisSkillsTests` 29/29，并在 SharedUI 中再次完成本次
  `ChatAutoTitleViewModelTests` 3/3；随后 SharedUI 后续用例连续约 90 秒无输出，人工中止为 130，
  因此不得记为整仓全绿；
- 未运行真实 provider、credential/network 或 GUI/iOS 手动 smoke；prompt-only rename 的线上模型
  遵循度仍须用真实 Code/Cowork 首轮分别验收，且本次没有增加 host 自动触发器。

2026-08-13 Code/Cowork 会话错误统一右置的直接证据：`ThreadLayoutTests` 21/21、0 failures。
测试复现失败 submission 与 `.error` 同时携带 `Task timed out after 600 seconds.` 的截图场景，
确认只生成一项右栏错误、runtime title 优先且 exact Retry ID 保留；另覆盖失败 execution row、
partial reply recovery、全部 host error strings、空来源不生成卡片、中央 transcript 仍保留用户原文与
partial agent 正文。`swift build --disable-automatic-resolution`、`TranslatisMac` macOS Debug unsigned
build 与 `TranslatisiOS` generic Simulator Debug unsigned build 均退出 0。未启动 App 或 fixture，卡片
实际字高、长错误滚动、窄宽与 Light/Dark 像素仍需手动观察。

2026-08-13 用户消息原生 Liquid Glass 气泡的直接证据：`ThreadLayoutTests` 18/18、0 failures；
新增 source-shape 回归覆盖 macOS Chat、共享 iOS Chat 与 Code/Cowork，确认仅 user branch 使用
`intatisLiquidGlass`，旧 `userSelectionStroke` / `bubbleStroke` / accent 蓝色 stroke 不再存在，
failure 不参与气泡 admission。`swift build --disable-automatic-resolution`、`TranslatisMac` macOS
Debug unsigned build 与 `TranslatisiOS` generic Simulator Debug unsigned build 均退出 0；构建只报告
既有 `onChange(of:perform:)` deprecated warning。未启动 App 或 fixture，实际折射强度、长用户消息、
Light/Dark、Reduce Transparency 与 Increase Contrast 仍需手动观察。

## Apple App 构建

```sh
xcodegen generate

xcodebuild -quiet -project Translatis.xcodeproj -scheme TranslatisMac \
  -configuration Debug -destination 'platform=macOS' \
  COMPILER_INDEX_STORE_ENABLE=NO CODE_SIGNING_ALLOWED=NO build

xcodebuild -quiet -project Translatis.xcodeproj -scheme TranslatisMac \
  -configuration Release -destination 'platform=macOS' \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
  COMPILER_INDEX_STORE_ENABLE=NO CODE_SIGNING_ALLOWED=NO build

xcodebuild -quiet -project Translatis.xcodeproj -scheme TranslatisiOS \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  COMPILER_INDEX_STORE_ENABLE=NO CODE_SIGNING_ALLOWED=NO build
```

构建后读取最终 bundle，而不是静态源码 plist：

```sh
plutil -extract CFBundleShortVersionString raw -o - <App>/Contents/Info.plist
plutil -extract CFBundleVersion raw -o - <App>/Contents/Info.plist
lipo -archs <App>/Contents/MacOS/TranslatisMac
```

macOS Release 必须同时包含 `arm64` 和 `x86_64`；iOS 仍须通过 target dependency/link
inventory 证明没有本地 workspace stack。

## Developer ID 直接分发

预检：

```sh
zsh -n scripts/package-macos-release.sh
security find-identity -v -p codesigning
xcrun notarytool --version
```

正式执行：

```sh
TRANSLATIS_NOTARY_PROFILE=<profile> scripts/package-macos-release.sh
```

如果访问 GitHub 必须开启代理/VPN，而 Apple notarization 必须关闭它，则运行：

```sh
TRANSLATIS_PAUSE_BEFORE_NOTARIZATION=1 \
TRANSLATIS_NOTARY_PROFILE=<profile> \
  scripts/package-macos-release.sh
```

保持代理/VPN 开启直到脚本完成依赖解析、构建和 App 签名并显示切换网络提示；随后保持
终端和脚本运行，关闭代理/VPN，再按 Return。脚本在原地循环验证 `notarytool history`，
成功后才提交 App；失败不会丢弃已签名的 staged App，也不要求重新下载依赖。该模式要求
交互式终端，非交互 release job 不得设置 `TRANSLATIS_PAUSE_BEFORE_NOTARIZATION=1`。

上传后终端必须显示 Apple submission ID 和实时状态。默认 wait deadline 是 30 分钟；仍为
`In Progress` 时脚本必须保留 owner-only recovery 目录并打印 exact resume 命令，不能再次
提交同一 App。可用 `TRANSLATIS_NOTARY_TIMEOUT=<正整数>[s|m|h]` 修改单次等待时长。恢复命令为：

```sh
TRANSLATIS_NOTARY_PROFILE=<profile> \
TRANSLATIS_RESUME_RELEASE_DIR=<脚本打印的绝对路径> \
  scripts/package-macos-release.sh
```

恢复测试必须确认：App/DMG submission ID 复用、无第二次 `submit`；repository version 和
recovery App metadata/architecture/signature/entitlements 重新验证；超时、Control-C、TERM、
网络失败和 Invalid 保留 recovery；最终 ZIP/DMG/manifest 全部落盘后才清理 recovery。当前
真实旧运行发生在这套持久恢复机制加入前，不能用它冒充已完成 recovery E2E。

发行脚本必须在输出 `dist/` 前完成：

1. v0.72/build 72 一致性检查；
2. `TranslatisMac` universal Release；
3. Developer ID Application + secure timestamp + Hardened Runtime；
4. signed entitlements 不含 App Sandbox；
5. App notarization Accepted、staple/validate、strict codesign、Gatekeeper assessment；
6. 带 `/Applications` 拖放入口的 Developer ID signed DMG；
7. DMG notarization、staple/validate、codesign、Gatekeeper assessment；
8. ZIP/DMG SHA-256 清单。

任一门槛失败都不得发布 ad-hoc、unsigned、未公证或未通过 Gatekeeper 的包。

## 数据、权限与恢复回归

涉及 EventLog、session projection、权限、Cowork、terminal 或生命周期时，必须覆盖：

- 旧 JSONL 仍可解码，`seq` 单调，append/batch first-write/first-terminal 语义不变；
- permission RequestID/FIFO/correlation、manual decline 与 cancel-turn 语义不混淆；
- tool authorization、durable ticket、executor result 和 turn outcome 关联完整；
- current-run close 只向 exact `@main` root 暴露，模型不得提供 identity；in-flight tombstone 必须先挡住
  重入 admission/authorization，RunID first-write claim 必须早于旧 admission wait 与 cleanup/drain 落盘，
  只 drain 同 run、保留 typed source，恢复不得复活 closed run，普通 final 不伪造 claim；
- mailbox ordinary message 不 ACK；information request 只接受一个 exact `inReplyTo` terminal reply；
  information reply receipt 只能用 fresh RequestID + `based_on` 延续同 conversation，不能形成 ACK 环；
- path escape、symlink/hardlink、secret、credential path、workspace lease fail closed；
- 只有持有 coordinator lease 的 Cowork prompt 才主动建立 execution objective、检查并激活明确相关的
  exact Skills、为非简单工作维护最小 WorkTask DAG、在收益成立时尽早委派并继续自己的关键路径，
  最终验证 child report 与结果；普通请求不自动创建 durable Goal，一步两步工作不仪式化 spawn，
  worker、authoritative tool list、lease 与 PermissionEngine 边界不变；
- Cowork coordinator prompt 在 `spawn_agent` 可用时把预知的根外目录或 out-of-workspace denial
  路由为 exact-directory child + `delegate_task`，默认只读、写入显式；Code/worker prompt 不宣称
  coordinator 能力，工具缺失/扩展拒绝只报告 blocker，直接越界仍 fail closed；
- Code system prompt 与 Cowork coordinator/exact `@main` prompt 只在 session 第一轮用户任务完成验证或
  确认真实 blocker 后、且 authoritative list 含 `rename_session` 时要求调用一次具体标题；不得新增宿主
  自动 trigger。worker 与共享 Cowork runtime prompt 不得出现该要求，后续轮次只响应用户明确改名。
  Cowork 提示必须保持 `rename_session` 最后一个非 run-control call，再进入既有 `finish_run` / `stop_run`；
- runtime stop 先 drain provider/tool/process，再释放 waiter/subscription/scope；
- Cowork worker 默认无 coordinator tools，reviewer/verifier 不进入普通 scheduler；
- ordinary worker 的 `task_update` closed business schema 只含当前任务的 ID/revision、进度、允许状态、
  结果与证据，manager 的完整 schema 不受影响；两者仍保留同一稳定工具名，worker 管理字段在权限/执行前
  拒绝，automatic request-owned authorization sidecar 装饰仍独立保留；
- iOS target closure 不出现 Tools/Permission/AgentKernel/Cowork/MCP。

精确不变量见 `docs/DO_NOT_BREAK.md`。

## macOS 文件夹项目验收矩阵

涉及 `ProjectFolderStore`、macOS 当前模式的可折叠 Projects/Unfiled 侧栏或项目内会话创建时，至少运行：

```sh
swift test --filter ProjectFolderStoreTests
swift test --filter ThreadLayoutTests/testMacFolderProjectsRemainAGroupingLayerOverExistingSessions
jq empty Apps/SharedResources/Localizable.xcstrings
xcodegen generate
xcodebuild -quiet -project Translatis.xcodeproj -scheme TranslatisMac \
  -configuration Debug -destination 'platform=macOS' \
  COMPILER_INDEX_STORE_ENABLE=NO CODE_SIGNING_ALLOWED=NO build
```

专项必须证明：

- `projects-v1.plist` 是 schema-v1 owner-only binary plist，未知 schema、损坏、relative/control path、
  unsafe inode、大小/数量超限和冲突 membership 均 fail closed；同 `{kind,path}` 重加幂等，相同 path
  可按 mode 独立登记，多线程/多实例更新不丢 conversation；序列化结构不得含 `bookmarkData`、消息、
  工具参数或 artifact；旧 mixed-mode 草稿必须按 kind 确定性拆分；
- 每个项目固定一个 SessionKind，只能引用同模式 SessionID；跨模式 association 在写入前拒绝。同模式
  一个 SessionID 最多属于一个项目，重新关联只移动引用，不能移动/复制/改写 session 目录或 EventLog。
  项目删除后，用户文件夹、session EventLog 和 artifacts 逐字节保持原状；
- 侧栏只从当前 mode 的 `SessionSummary` 解析项目 conversation；missing/stale reference 不显示为伪会话。
  文件夹内 `+` 只创建当前模式会话，不得出现跨模式类型菜单；Chat 不取得 workspace，Code/Cowork
  要求用户重新选择 exact project folder，并只在新 session 的 `workspace-access.plist` 保存 bookmark；
- Projects 必须是默认收起、可展开的单行文件夹，不得有固定高度或独立项目主页；收起后不保留子会话
  空间。Projects 与 `Unfiled` 共用 sidebar ScrollView，归档会话不在 Unfiled 重复出现；
- 普通 Unfiled、新建/恢复/rename/delete 和 folder expansion 不互相改写。删除 project conversation
  仍使用 exact runtime drain/session delete，随后只清理辅助 membership；删除项目不触发任何 runtime stop；
- String Catalog 的新增 English/zh-Hans 文案 JSON 合法且格式占位符一致；macOS Light/Dark、窄侧栏、
  多窗口 selection、folder picker cancel/wrong-folder、项目为空/多会话、移除确认与 VoiceOver 需在真实
  App 中手动核对，不能由 source-shape test 冒充；
- 因 `ProjectID`/store 位于 shared `IntatisCore` 且 String Catalog 为双端资源，至少补一次 iOS Debug
  build，证明 iOS Chat-only target 仍无 Projects UI、workspace bookmark 或本地 Agent 能力。

## UI 与可访问性回归

当前至少检查：

- macOS/iOS Light 与 Dark；
- Chat/Code/Cowork session 切换与完整连续滚动；确认不存在 Earlier/Newer/Latest 或消息范围页码，
  同一时刻最多 16 个 active rich rows，离屏 row 释放 native rich graph但 exact raw text和滚动位置保留；
- macOS/iOS 新建未命名 Chat：首个有主题成功回合后标题在 15 秒内出现；简单问候可先保留默认名，
  后续有主题回合再命名；标题生成期间可立即继续 Send，Stop 只控制当前主回合；手工 Rename 在生成
  前/中/后均不得被自动标题覆盖；iOS 快速 A→B 时 A 的迟到标题只更新 A；
- Cowork 默认查看 `@main`；右侧 ordinary agent 点击后只出现该 agent 内容；
  detach 当前 agent 后它仍留在同一列表、状态图标变为 detached、选择和历史页不跳回 main，
  且所有运行时操作禁用；`@permission-reviewer` 为 status-only；两个窗口选择互不覆盖；切走再
  返回仍显示各 agent 自己的完整连续历史；查看 worker 时 composer 仍路由 `@main`；
  Agents header 使用 `person.2.fill`，row status 使用 20pt/30pt hierarchical 圆形 SF Symbols，且
  running/blocked/limited/pending/completed/cancelled/detached 不是同一个只靠颜色变化的 glyph；
- long rich response、Markdown/table/code/math 和 plain-safe fallback；
- macOS rich assistant/agent message 直接左键拖拽可在同一 rendered document 内正向/反向跨 heading、
  paragraph、list item、block quote、table cell 与 code body；拖动期间 ranges 连续，mouse-up 后所有
  leaf 使用同一系统 `selectedTextAttributes` 强调。首个 leaf 只能保留不重复绘制的 native selected range
  维护 responder/Copy；active/inactive window 均不得出现首段浅蓝、后续深蓝的双重样式。普通 click、
  stream replacement、mode/session/agent change 与 dismantle
  必须恢复 exact attributed projection；Intatis 不显示 `Select more text` menu/sheet，也不构造第二
  SelectionOverlay/plain renderer。Command-C 按 document order 复制 displayed plain text，block 间换行、
  同 table row 用 tab、inline math 恢复 literal；message footer whole-copy 仍复制 canonical raw text。
  code 必须保持 horizontal unwrapped，table 不等高 cell 仍 row-major/非零布局；iOS/plain-safe 行为不变；
- macOS 每条已完成 assistant/agent 回复在正文下方只有一个最左 icon-only copy action。Chat/历史
  `turn_stats`只显示其可证明字段；新Code/Cowork `responses_usage`按Input/Cache Hit/Cache Write/Output/
  Reasoning/Total/Duration显示exact native值，Input不得减Cache Hit；没有文字版 Copy、
  点赞/点踩、card/glass 或旧 global latest usage。复制结果必须逐字等于 raw message text；旧 unbound
  `turn_stats` 不得贴到相邻消息。Chat message-first 与 Agent stats-first 两种事件顺序都必须覆盖；
- macOS Chat、iOS Chat、Code、Cowork 仅用户消息显示 trailing 原生 regular Liquid Glass 气泡，
  不出现旧 accent 蓝色描边；assistant/agent/system（包括失败/中断回复）直接位于 canvas，
  正常 tool/permission/task 等专用结构化卡片仍保留各自容器；
- macOS Chat/Code/Cowork 用户气泡为 20pt continuous rounded rectangle；短消息随正文收缩，
  Code/Cowork 不显示 queued/running/completed/cancelled submission status row，失败/Retry 仍只在右栏；
  permission card/notice 保持原样。`Jump to latest` 为带本地化 help/VoiceOver label 的 icon-only 原生
  large 圆形 glass `arrow.down`，并按包含 sidebar 的整个 app-window content 横向居中；测试须覆盖
  Chat/Cowork full-detail surface、Code thread+inspector surface、sidebar/inspector resize 与 nil-host
  fixture fallback。Cowork 不再按 rail clearance 右移。Cowork Tasks 默认态只显示 `Tasks` + completed/total、单一 status marker、
  标题和可选 trailing disclosure；展开后 detail/result/evidence/dependency/invocation links 仍可读；
- composer 单行/多行、model menu、usage、Send/Stop；macOS Chat第一排只保留Context，Code/Cowork在
  official context事实未接通前不显示Context，iOS Chat继续完整latest-turn usage；
- iOS composer 获得焦点后，Send 按钮与键盘提交都应立即收起键盘；重新聚焦后在消息区上下拖动应
  交互式收起键盘，stream completion、输入框重新启用和自动滚动不得再次弹出；macOS focus 不变；
- Cowork wide rail、narrow permission fallback、Goal/Tasks/Agents；
- Code/Cowork默认thread不得显示`turn/started`、`item/started`、`item/completed`、
  `thread/tokenUsage/updated`等raw method标题。exact EventLog projection必须保留；backend execution-trace
  开关必须恢复原始method/scalar。默认路径应把同item的started/delta/completed归并成一条本地化语义活动，
  Command/File changes/Tool/MCP tool/Web search/Image/Collaboration/Subagent/Plan/Reasoning类别与
  Running/Completed/Failed/Cancelled状态不能仅靠颜色区分。usage、Goal、permission、Agents roster与
  message lifecycle只更新专用组件，不复制timeline row；unknown future method必须显示通用Runtime activity
  并保留技术help。Cowork child live/durable event不得双份显示；reasoning/plan连续delta必须与assistant
  delta共用fixed-window cadence，item/turn terminal仍立即barrier；
- Code/Cowork 当前选中连续 thread 的 `.error`、失败 execution row、recovery advice、失败 submission 与全部
  host 页面级错误只在右栏最底部同一张“错误信息”圆角卡片内显示；相同文案去重，Cowork Retry
  仍可用。无错误时无卡片、无占位；主 thread/composer 不得再显示 `Needs attention`、timeout、
  recovery advice、中央红框或另一张 `Recent Failures`；用户消息和 partial agent 正文必须保留；
- wide rail 连续切换 agent、应用失焦/回焦、窗口移动与进入/退出全屏；系统日志中不得出现
  `IntatisThreadViewportFramesPreferenceKey tried to update multiple times per frame`，源码不得恢复
  viewport GeometryReader/PreferenceKey 坐标回写；
- Settings disclosure、provider test、本地诊断 ZIP；
- Dynamic Type、Reduce Transparency、Increase Contrast、VoiceOver 和 clipboard/selection。

截图或 Computer Use 只能证明对应 viewport/appearance 的视觉行为，不能替代 EventLog、
权限、bundle、签名或长时性能验证。

### Cowork agent-thread 性能门禁

Debug-only `CoworkAgentConversationFixtureView` 通过启动参数
`-IntatisCoworkAgentConversationFixture` 使用真实 `CoworkShell`，但不打开 EventLog、provider、
workspace、permission runtime 或 credential。Computer Use 无法传入启动参数时，DEBUG 构建也可用
以 `.CoworkAgentConversationFixture` 结尾的独立 bundle identifier 启动同一 fixture；该入口不进入
Release。固定负载为 8 个 selectable agent × 每个 1,000 rows、4-agent 合计 500 canonical
delta/s（50 ms projection coalescing）、每个选中 agent 的完整 1,000-row 连续历史与最多 16 个
active rich rows。

专项验收至少执行：

1. `Run 1,000 switches`，确认最终 selection/内容一致且 warning/incident 均为 0；
2. `Run 180s soak`，nominal 10 selected-agent changes/s；记录实际 timed switches；
3. 结束后保持窗口打开并静置到 rich document 恢复，再记录 RSS、`vmmap -summary` 与
   `heap` 中 `NSTextViewSharedData` / `Gestures.GestureNode<()>` 数量；
4. 再手动从一个 streaming agent 和一个静态 agent 的最新消息连续滚动到最早消息，切走再返回，
   确认没有分页按钮、历史没有缺口、reviewer 没有 conversation button。

通过条件：全过程 UI 可访问，main-thread warning/incident 为 0；active rich rows 始终 ≤16；RSS/physical
footprint 和 native text/gesture objects 不随切换次数线性增长；停止后 rich view 数量回到一个
viewport-bounded visible neighborhood 的量级。`heap`/`vmmap` 会短暂停顿目标进程，只在自动 soak 完成后采样，
避免把外部采样暂停误计为产品 heartbeat incident。该 offline fixture 只证明 presentation
pipeline，不替代真实 EventLog I/O、provider、VoiceOver、最低支持设备或多小时运行。

## Chat 与 Agent 托管搜索验收矩阵

`docs/CHAT_HOSTED_SEARCH.md` 是当前产品合同。相关业务源码修改至少必须用离线 request fixture
和 Chat integration tests 证明：

- OpenAI Responses request fixture 只生成该 dialect 的 `web_search` + `tool_choice: auto`；
  OpenRouter exact route 明确声明 `hosted_web_search` 时只生成
  `openrouter:web_search` + `tool_choice: auto`，两者不得共用硬编码 tool type。
- `@ai-sdk/openai` 普通 Chat adapter 尚未实现期间，registry 必须在网络前维持既有 config error，
  不能仅凭已有 OpenAI search encoder 跳过普通 adapter gate。
- 当前 Chat route 不支持、未知、adapter 尚未实现，或只有 `responsesEndpoint`/URL/名称 heuristic
  时，发送同一 Chat route 的普通 request，body 不含 hosted-search 字段，且不会先发送失败请求。
- 配置包含任意有效、无效或未知 `web_search_model` / `webSearchModel` 时，runtime 都不得解析或
  调用该 route，不得覆盖当前模型，也不得新增 UI 警告；新生成配置 fixture 不再写入该字段。
- 用户切换 provider/model/variant 后，下一次 Send 只按新的 exact selection 重新规划；不得沿用
  上一 route 的 capability，也不得产生不同 provider/model 的请求。
- 普通与搜索分支都保留 exact model/variant options；`provider.only`、`allow_fallbacks`、
  `require_parameters` 不得被删除或放宽。搜索不支持时只移除搜索字段。
- 模型拥有搜索能力但未调用时正常完成且 citations 为空；实际返回结构化 annotation 时才写
  additive citations，非法 URL、正文猜测来源和空 Sources UI 继续被拒绝。
- typed provider-specific “hosted search unsupported” 在任何有效 payload 前只允许在同一
  provider/model/variant 上一次普通 Chat 重发。任意 404、自由文本匹配、不同 provider/model
  fallback、partial payload 后重放必须被测试拒绝。
- Chat unsupported/unknown 分支不产生 toast、banner、错误卡、状态、提示词或 Settings 项，也不
  注册/调用 Agent `hosted_web_search`、`web_fetch`、`browser_search`、MCP、shell 或本地浏览器。
- macOS/iOS 共用相同 planner 语义；iOS target closure 仍没有 Tools、Permission、AgentKernel、
  Cowork 或 MCP。Chat cancellation、TurnID、EventLog 与旧 citation decode 不因分支改变。

真实 provider smoke 只能作为 adapter fixture 之外的补充，不能用单一厂商成功替代上述 exact
adapter/capability 矩阵。2026-08-05 已新增并通过 provider focused tests，覆盖独立 capability、
当前 route/legacy route ignore、compatible 静默普通 Chat、OpenAI/OpenRouter tool shape、strict
routing options、结构化 unsupported 同路由一次降级、裸 404 拒绝降级、partial payload 后禁止重放
及 citation 安全解析。macOS/iOS app build 与完整回归结果以本文件“最近一次真实结果”为准。

Code/Cowork/CLI 的shipping显式 `hosted_web_search` 至少验证：

- `HostedWebSearchToolTests`：descriptor 只有 required `query`，`strict:true`、
  `additionalProperties:false`、network/model-cost intent、`doNotReplay`；空白/超长输入在
  provider 前失败，service 收到 trim 后 query，standard registry 无 service 时不广告工具。
- `ProviderHostedWebSearchToolServiceTests`：专用请求使用 route 中 exact model/provider/options、
  `tool_choice:required` 与 unsupported fail-closed；文本/citation 去重与 output bound 正确，缺 completion
  marker 或 cancellation 不返回成功 ToolObservation。
- Provider route/request fixtures：OpenAI `web_search` 与 OpenRouter `openrouter:web_search` 仍分 dialect；
  exact agent metadata 缺 capability、compatible/legacy/unknown adapter 时 route 不携带 search service；
  exact profile revision 能把App Server Responses route与同 provider/model配置的optional search route
  一起冻结。工具模式明确拒绝
  ordinary-model fallback，而 Chat 模式继续保持受限的一次 fallback。
- `CapabilityLeaseTests` / `ToolRegistryLeaseTests`：fresh read-write lease 有独立
  `ToolCapability.hostedWebSearch`，read-only/reviewer/旧 lease 无；concrete tool 必须同时有 lease 与
  bound service，且不得因此出现 `browser_search` / `web_fetch`。registry identity 固定为
  `intatis.standard.v5` / `intatis.cowork.v5`。
- `CodexRuntimeTests`：authoritative dynamic catalog必须在无service时精确省略、存在service时精确包含该
  名称；root/child route服务不得串线，root不得借用child service，read-only/unsupported caller不得进入
  permission或service，host构造时child enabled profile与service map必须exact相等。App Server测试还要证明
  host-only scope来自verified root/parent chain而不是model arguments/JSON-RPC，并覆盖roleless继承。
- 至少构建 SwiftPM 全图，并编译 macOS Code/Cowork 与 CLI composition root；iOS 继续不链接
  Tools/Permission/AgentKernel/Cowork。真实 provider smoke 必须显式 opt in 并记录 exact
  provider/model/dialect、tool choice、是否返回 citation、usage/cost 与失败形状，不得隐式读取凭据或
  消费额度。

2026-08-13的下列结果只证明当时legacy/tool/provider实现，不代表shipping publication；本地已通过
`swift build`、`swift test --filter HostedWebSearch`、
`swift test --filter HostedSearch`、`swift test --filter CapabilityLeaseTests` 与
`swift test --filter ToolRegistryLeaseTests`，以及 `TranslatisMac` macOS Debug unsigned build 与
`TranslatisiOS` generic Simulator Debug unsigned build。另尝试完整 `swift test`：
`IntatisToolsTests` 227/227（19 个显式 opt-in smoke skipped）与 `IntatisSkillsTests` 29/29 通过，随后
在 SharedUI `testSelectedAgentUpdateRestartsRichRenderingDwell` 连续约两分钟无输出并以 130 中止；同一
exact test 单独重跑 1/1 通过。不得把该运行记为完整 suite 通过。未运行真实 provider/key smoke。

## macOS Chat/Cowork composer 图片附件验收矩阵

涉及 macOS Chat 或 Cowork composer 附件时，至少验证：

- 两者实际组合同一个 paperclip accessory 与 file-import/drop modifier；按钮、导入进度、附件数量
  菜单、逐项移除和 accessibility 文案只允许产品面名称不同，不复制两套交互实现；macOS Chat 不再
  出现独立的提示词生图 action；
- 系统文件选择和 URL drop 支持多选；security-scoped access 成对开启/关闭，文件先保存到当前
  session ArtifactStore，再按 ID、MIME、字节读回一致后才进入 draft；导入失败不污染已有草稿；
- Send 在按钮边界冻结文本和附件 ID；纯附件消息可发送。导入/读回或 durable admission 前失败必须
  保留草稿；对应 user intent 已 durable accepted 后才清除同一份冻结草稿，随后 AgentLoop 的
  resolver/capability typed failure 保留 accepted intent，不把它恢复成未发送草稿；
- `UserMessagePayload.attachments` 只保存 ArtifactID；EventLog、projection、错误和 UI 不得保存或
  显示 base64、bookmark、文件路径。当前轮与后续历史轮都从同一 session ArtifactStore 解析图片，
  不能只在第一次 provider request 传图；
- provider 输入只接受 `image/*`。缺失、不可读或不支持的 artifact 必须在网络前产生 typed、可行动且
  不泄密的错误；若 user intent 已 durable accepted，错误不得回滚或复制该 intent。非图片文件仍可
  durable 保存和移除，但不能被静默当作图片发送；
- Chat 投影和 macOS/shared user bubble 至少显示附件数量；旧 artifact event、旧缺少 `attachments`
  字段的 JSONL 和纯文本消息继续解码/回放；
- Code 的新增 durable attachment accessory 必须继续复用共享导入/ArtifactStore 边界；Agent
  `generate_image` / `edit_image` 权限链不得被改写，iOS 不得因共享 VM 或 ArtifactStore 注入而出现
  本地文件/照片附件入口；
- 至少运行共享附件 store/resolver tests、ChatLoop 当前轮+历史轮 rehydration test、完整 SwiftPM
  tests、`TranslatisMac` macOS Debug 与 `TranslatisiOS` generic Simulator Debug unsigned build。文件选择、
  拖放和真实视觉命中仍需 macOS 手动 smoke 单独记录，不能从单元测试或编译外推。

## Agent durable 图片上下文专项

涉及 Code/Cowork 用户图片、structured-result 图片、model history、provider FCO 或 compaction 时，
至少运行：

```sh
swift test --filter ArtifactImageResolverTests
swift test --filter IntatisProvidersToolCallingTests
swift test --filter ModelHistory
swift test --filter DurableMultimodalAgentLoopTests
swift test --filter CLIAttachmentTests
swift build --target TranslatisCLI
```

具备用户明确授权的真实OpenAI凭据、网络和额度时，再显式运行一次同时携带user image与原call
function-output image的付费smoke：

```sh
TRANSLATIS_REAL_MULTIMODAL_SMOKE=1 swift test \
  --filter RealProviderSmokeTests.testRealOpenAIMultimodalUserAndFunctionOutputWhenEnabled
```

该测试只发一个provider请求；不开启环境变量时必须skip，不得隐式消费凭据或额度。

专项必须证明：

- 用户图先进入 exact-session ArtifactStore；`AgentLoop.send`拒绝调用方直接传provider-ready
  `images`/data URL，task-scoped current、stable current/next/restart与legacy ID路径都使用同一bounded
  resolver；
- PNG/JPEG MIME/magic、完整解码、byte/aggregate/count/dimension/pixel、SHA-256 与 no-follow/owner-only
  失败矩阵均 fail closed；缺少可信 decoder 的平台不列入正向图片矩阵；
- MCP structured image以原call ID进入Responses function output，text/JSON只canonicalize一次，live与
  replay使用同一append-return binding；含图completion batch必须绑定同turn/call的唯一`tool_result`与
  同`{callID, agent, taskID, attempt}`的唯一settlement；不支持FCO图片的route在网络前typed失败但不
  改写工具settlement；
- 图片正向route必须是effective `.openAI` request adapter与exact model `.visionInput`的合取；user/FCO
  capability分别验证，compatible/legacy/OpenRouter/unknown adapter保持false，图片Responses transport
  不得误触发tool-search capability错误；
- projector image sidecar与messages严格等长，v2 direct/checkpoint不能降级为v1；compaction
  summarizer看见完整active window，成功checkpoint不保留任何旧图片ref，resume不偷回checkpoint前图片；
- automatic Cowork 不得因 acting request 含 user 或 FCO 图片而 blanket deny；端到端回归必须分别覆盖
  当前 user image 与历史 FCO image，证明 same-call sidecar 可摘要媒体证据、reviewer 仍只接收文本摘要而
  不重发完整像素/PDF，并且 valid allow 后只执行 exact reviewed business call；
- Cowork Retry planner矩阵必须证明outbox canonicalization保持attempt 1、restored queued exact resume
  不递增、restored running durable requeue只对齐下一exact attempt；无Run的failed/cancelled task仍在原
  submission/task上有界递增，而terminal Run上的failed root必须创建fresh可见continuation
  submission/root/Run、复用原冻结main binding且不复制one-shot external context，并证明旧Run/旧失败
  事实不变、旧按钮在新submitted intent出现后消失；
- macOS Code/Cowork GUI与CLI产品接线编译；iOS仍不链接AgentKernel/Tools/Cowork。fake provider只能证明
  request shape与事件顺序，真实OpenAI Responses user/FCO image smoke必须另列且需要凭据/网络。

## 图片工具与 `image_model` 配置验收矩阵

涉及 macOS/modern CLI 图片路由时，至少验证：

- 顶层 canonical `image_model` 的 `<provider>/<model-id>` 精确解析到
  `ResolvedModels.imageGen`，不改变当前 Chat/Code/Cowork inference selection；
- 专用图片 provider 可使用空 `models`，连接仍保留，但不生成 inference profile 或进入模型菜单；
- 图片 model ID 不需要作为推理 model 重复登记；model-facing `generate_image` 与
  `edit_image` schema 都不包含 provider/model 字段；
- 缺少 `image_model` 时 `models.imageGen == nil`，两个工具执行都明确报未配置，不能出现
  `dall-e-3` 或其他 hidden fallback；
- provider wire 继续只接受合法 HTTP(S) Base URL；生成调用 OpenAI-compatible
  `/images/generations`，编辑调用 multipart `/images/edits`，两者都验证
  `data[].b64_json`；
- `edit_image` 必须在任何网络请求前验证输入/输出均位于 workspace、输入是受支持且魔数匹配的
  PNG/JPEG/WebP 普通文件、输入不超过 50 MiB、输入输出不相同且输出扩展名是 `.png`；
- 两个工具的文件写入都经过permission、workspace lease与`PathConfinement`；shipping App Server要求
  forks共享dynamic schema，因此read-only child可能看见工具名称，但必须在host permission/audit/executor
  前因缺少同名exact capability被拒绝。当前首版只支持单张输入图，不支持mask、多参考图或原地覆盖；
- normalized image arguments命中`SecretScanner`时必须在permission request、execution prepare与injected
  service之前拒绝；测试不得把raw secret marker写入EventLog或provider capture；
- 常规验收使用injected fake service或loopback App Server，不能读取API key或发真实provider请求。真实
  generation/edit smoke必须由用户显式opt in，且不能替代离线route/capability/fail-closed测试。

## 输入栏语音与 `transcription_model` 配置验收矩阵

涉及 macOS Chat/Code/Cowork 或 iOS Chat 语音输入时，至少验证：

- 顶层 canonical `transcription_model` 的 `<provider>/<model-id>` 精确解析到
  `ResolvedModels.transcription`，不改变 Chat/Code/Cowork inference selection；缺字段时为 `nil`，
  不得使用当前 Chat model、`whisper-1` 或其他 hidden fallback；
- 显式 transcription-only provider 可使用空 `models`，连接和 credential reference 仍保留，但不
  进入模型菜单；macOS 高级 JSON/JSONC 和 iOS Files import 均保留同一个 exact route，不新增设置页；
- Chat/Code/Cowork/iOS Chat 的 mic 位于唯一 Send/Stop 左侧：第一次点击开始录音，第二次点击停止
  并转写；其 compact control 必须以显式 40pt 外层 frame + 圆形 `contentShape` 命中屏幕上完整
  圆形按钮，不能退化成只有内部字形可点；结果追加而不是覆盖完成时的当前草稿，空结果不改变
  草稿且永不自动 Send；
- 录音开始前验证 recorded-file runtime 并冻结 registry/route，credential 只在转写边界懒加载；
  compatible/legacy/OpenAI adapter 使用 disk-backed multipart `/audio/transcriptions`，exact OpenRouter
  adapter 使用 JSON-base64 `input_audio` 同 endpoint；不得按 provider 名称或 URL 猜测方言；
- 默认录音必须是 WAV/16 kHz/mono；WAV 为 16-bit little-endian PCM，M4A 兼容设置也不得包含
  `AVEncoderBitRateKey`。临时音频与 upload body 均为 owner-only 随机文件，最多录制 120 秒，读取/
  上传前限制为 25 MiB；空文件、symlink、非普通文件、非法扩展与超限内容在请求前拒绝；
- 成功、失败、取消、VM/runtime shutdown 后均停止 recorder、释放 process-wide microphone lease 并
  删除音频/body；取消或迟到的 TCC callback 不得复活旧 generation；
- 用户 Send 前不得产生 EventLog、ArtifactStore 或 projection 写入；macOS/iOS bundle 均包含
  `NSMicrophoneUsageDescription`，English/简体中文说明可用；
- 不迁入多模型对比、第二设置页、全局快捷键、review/clipboard 或输入法 target；至少运行 draft
  merge、recorder settings、multipart/OpenRouter JSON/config route focused tests、完整 SwiftPM tests、
  `TranslatisMac` macOS Debug 与 `TranslatisiOS` generic Simulator Debug unsigned build。真实麦克风权限与
  线上 provider smoke 必须单独记录，不能从离线测试或编译外推。

## 最近一次真实结果

### 2026-09-04 v0.72版本收口与本机安装

- `project.yml`、macOS/iOS参考Info.plist、README、文档索引及全部current-baseline文档已同步为
  `0.72 (72)`；`xcodegen generate`与`scripts/check-version-consistency.sh`退出0，后者输出
  `Intatis version is consistent: 0.72 (build 72)`。历史v0.71及更早证据保持原值。
- 覆盖图片、hosted search、official `request_user_input`、Providers、Protocol、CLI与Cowork/SharedUI的
  聚焦矩阵退出0；Codex Runtime 77/77、SharedUI选中44/44、CLI 50项中8项真实付费smoke按设计skip，
  CoworkUI public contract与hosted-search专项也通过。`swift build --product translatis`退出0。
- 完整`swift test --disable-automatic-resolution`先通过Tools、Skills并进入SharedUI，随后再次在组合顺序
  中静默等待；约90秒无新输出后以SIGINT有界终止。该运行没有断言失败，但不能记为完整通过，也没有新增
  sample证据；既有`NEXT_TARGET.md`中的SharedUI间歇性生命周期缺口保持开放。
- fresh DerivedData的`TranslatisMac` universal Release unsigned与`TranslatisiOS` generic Simulator Debug unsigned
  build均退出0；两个bundle读回`0.72 (72)`。Mac主程序为`x86_64 arm64`，`Contents/MacOS`只有
  `TranslatisMac`，`otool -L`不引用Debug/preview dylib。
- staging App使用`TranslatisMac.DeveloperID.entitlements`完成ad-hoc Hardened Runtime签名；deep strict
  codesign通过，audio-input=true、allow-jit=false、disable-library-validation=false。安装到
  `/Applications/Intatis.app`后与staging逐文件一致、无quarantine，主程序SHA-256为
  `10084be0087c45ac67bda624c08dbd66044267063867bdd62aa77516e6f34adc`。Computer Use从最终路径启动成功，
  进程路径读回`/Applications/Intatis.app/Contents/MacOS/TranslatisMac`；旧v0.71保存在
  `/Users/vita/.Trash/Intatis-before-v072-20260904-230340.app`。
- 该安装仍没有`CodexRuntime`、`DocumentRuntime`或`BrowserRuntime`三套bundled runtime，也没有Developer
  ID secure timestamp、notarization、staple、Gatekeeper或fresh-account证据；它是本机开发预览，不是正式
  release。验证没有读取provider credential、调用真实模型/API或产生费用。

### 2026-09-03 macOS official `request_user_input`原生UI接线

- macOS Code/Cowork composition roots现在向既有
  `CodexRuntimeConfiguration.requestUserInputHandler`注入App-owned request-local FIFO presenter；CLI继续传
  nil。SharedUI只新增纯presentation/draft/submission、透明描边panel、native single-selection
  `List`编号整行、多题导航、按需Other `TextField`与`⌘↩`提交；不使用Material/Glass/模糊或radio/checkbox。
  `IntatisCoworkUI`只增加state/action映射，没有取得runtime/session/tool owner。
- focused命令
  `swift test --disable-automatic-resolution --filter 'CodexRuntimeTests|CodexRuntimeToolsetIdentityTests|StructuredUserInputTests|IntatisCoworkUIPublicContractTests|ThreadLayoutTests'`
  退出0。其中`IntatisCodexRuntimeTests.xctest`为77/77、SharedUI选中35/35、CoworkUI为2/2，均0 failures；
  覆盖official callback往返、verified child、secret/cancel、handler-qualified persisted toolset identity、多题
  完整回答、Other去空白、坏选项拒绝、编号整行single-selection list、无radio/Material、`⌘↩`与UI product
  依赖边界。
- 完整`swift test --disable-automatic-resolution`在有界时间内退出0，所有运行suite均0 failures；这一次成功
  仍不消除历史SharedUI组合顺序间歇性挂起风险，也不替代`NEXT_TARGET.md`要求的三次稳定性验收。
- `swift build --product translatis --disable-automatic-resolution`退出0；`xcodegen generate`退出0；
  `TranslatisMac` macOS Debug unsigned离线fixture build和`TranslatisiOS` generic Simulator Debug unsigned build均
  退出0。仅观察到仓库既有unused-result/deprecated warnings。
- DEBUG-only `RequestUserInputFixtureView`只使用真实production `CoworkShell`右侧内容，不再伪造App左栏，
  也不打开provider、EventLog、workspace或credential。Computer Use实际选中编号整行、导航到第2/2题、
  选择该题答案后确认Send可用，再发送`⌘↩`并观察question surface从accessibility tree消失；提交前截图
  保存为`/tmp/intatis-request-user-input-native-v7.jpg`。
  整个验证没有读取API key、调用真实provider或产生费用。
- `scripts/check-version-consistency.sh`退出0并输出
  `Intatis version is consistent: 0.71 (build 71)`；localization catalog通过`jq empty`，最终
  `git diff --check`退出0，production UI源码中不存在“需要你的选择”或`needs your choice`。
- 用户随后拒绝首版Material卡片后，focused SharedUI 35/35与CoworkUI 2/2再次退出0，macOS fixture和
  iOS Simulator Debug也重新构建成功。随后整仓SwiftPM重跑再次复现既有组合顺序挂起：
  `IntatisSharedUITests.xctest`与其`swift-test`父进程持续0% CPU且无新输出，1秒`sample`显示主线程停在
  `XCTWaiter._synchronouslyWaitForTimeInterval`/CoreFoundation run loop；有界诊断后以SIGINT终止，命令退出
  130。该证据继续归入`NEXT_TARGET.md`的既有SharedUI测试生命周期缺口，不归因于已单独通过的本次UI用例。
- 用户进一步指出“删除整个容器”和继续使用radio均不符合目标后，最终实现改为透明细描边容器、编号整行
  native `List`、多题单页导航与系统selected-row高亮。最终SharedUI 35/35、CoworkUI 2/2及单独
  `StructuredUserInputTests` 3/3均退出0；macOS fixture与iOS Simulator Debug重新构建成功。Computer Use
  实际走通第一题选择→第2/2题→第二题选择→Send enabled→`⌘↩`移除完整question subtree，并单独验证Other
  选择→文本输入。前一条已取得完整suite挂起sample后，本轮不以重复无界整仓运行替代focused产品验证。
- 2026-09-04按用户最终视觉修正删除每个option尾部的`info.circle`；非空description改为标题下一行的
  `caption2` secondary文本，无description的Other仍为单行。上述focused SharedUI 35/35、CoworkUI 2/2
  再次退出0，macOS fixture重新构建后以Computer Use取得的实际截图与AX tree确认不存在info图标，且
  选中行保留说明文字；最终截图保存为`/tmp/intatis-request-user-input-native-v7.jpg`。

### 2026-09-02 official `request_user_input`后端接线（无UI）

- `IntatisCodexRuntime`只增加presentation-agnostic typed callback和official App Server JSON-RPC
  往返；没有新增Plan/Default产品模式，也没有改`Apps/TranslatisMac`、`IntatisSharedUI`或
  `IntatisCoworkUI`源码。当前macOS/CLI composition root没有注入handler，runtime config明确写入
  `default_mode_request_user_input=false`，所以shipping UI与既有用户行为不变。
- `swift test --disable-automatic-resolution --filter CodexRuntimeTests`最终退出0，整个
  `IntatisCodexRuntimeTests.xctest`为76/76、0 failures。fake App Server覆盖root callback与exact answer
  map、同一turn恢复、official parent-chain验证后的child exact AgentID、auto-resolve取消、secret问题在
  presentation前拒绝、handler为nil时feature关闭，以及public configuration contract。
- installed fixed `codex-cli 0.145.0-intatis.4` loopback integration实际完成
  Responses function call → `item/tool/requestUserInput` server request → Swift host callback → official
  JSON-RPC answer → `function_call_output` →同一turn final response。该测试只访问本机loopback、使用
  placeholder credential；没有读取或请求OpenAI API key，没有调用真实provider，也没有产生计费。
- 最终完整`swift test --disable-automatic-resolution`退出0，所有已运行suite为0 failures；该单次完整通过
  不消除既有SharedUI组合顺序间歇性XCTest async waiter挂起记录，也不冒充真实GUI presenter smoke。
- `swift build --product translatis --disable-automatic-resolution`第一次只因managed sandbox禁止SwiftPM
  自己的`sandbox-exec`初始化而失败；允许同一命令使用正常SwiftPM sandbox/cache后退出0。
  `xcodegen generate`、`TranslatisMac` macOS Debug unsigned build与`TranslatisiOS` generic Simulator Debug
  unsigned build均退出0；macOS仅出现仓库既有deprecated `onChange`与unused `try?` warning。
  `scripts/check-version-consistency.sh`退出0并输出`Intatis version is consistent: 0.71 (build 71)`；
  最终`git diff --check`退出0。

### 2026-09-02 shipping Agent hosted-search 接线

- focused命令
  `swift test --disable-automatic-resolution --filter 'CodexRuntimeTests|HostedWebSearchToolTests|ProviderHostedWebSearchToolServiceTests'`
  退出0：hosted Tool 4/4、provider service 3/3；补入App Server exact hosted-search round-trip后Codex
  Runtime target最终为71/71。覆盖74项条件式
  authoritative基础目录、root与writable child distinct exact service、root无child fallback、read-only/
  unsupported pre-permission拒绝、enabled role缺service时host构造失败、trimmed query、secret pre-dispatch、
  durable prepared events、App Server root/roleless-child host-only scope，以及真实fake App Server
  `item/tool/call(hosted_web_search)`进入shipping business host exact root service并settle成功。
- 扩展矩阵
  `CodexRuntimeTests|HostedWebSearchToolTests|ProviderHostedWebSearchToolServiceTests|CapabilityLeaseTests|ToolRegistryLeaseTests|IntatisProvidersTests|InferenceCatalogStoreResolverTests|ResponsesToolSearchParityTests|TranslatisCLITests|SessionStateProtocolTests|CoworkInferencePresentationTests`
  全部退出0；CLI 50项中8项真实provider smoke按设计skip。Provider route断言同时冻结exact Responses与
  optional hosted-search route，并验证OpenAI/OpenRouter dialect与unsupported route suppression。
- `swift test --disable-automatic-resolution`最终完整运行正常退出0，所有已运行suite为0 failures。该结果
  没有抹除2026-09-01及更早SharedUI组合顺序间歇性XCTest async waiter挂起证据；稳定性目标仍要求连续
  有界重跑和诊断围栏。
- `swift build --product translatis --disable-automatic-resolution`在外层managed sandbox第一次因SwiftPM内层
  `sandbox-exec`初始化被拒；允许同一构建命令使用真实SwiftPM sandbox/cache后退出0。`xcodegen generate`、
  `TranslatisMac` macOS Debug unsigned build与`TranslatisiOS` generic Simulator Debug unsigned build均退出0；
  iOS只出现仓库既有`try?` unused-result警告。`scripts/check-version-consistency.sh`退出0并输出
  `Intatis version is consistent: 0.71 (build 71)`。
- 所有search工具执行均使用fake/loopback service；没有读取或请求OpenAI API key，没有向OpenAI或任何
  第三方provider发送真实请求，也没有产生计费。真实provider/model/dialect smoke仍需用户显式opt in，
  离线成功不能外推为外部route已兼容。

### 2026-09-01 shipping 图片工具接线

- `swift test --disable-automatic-resolution --filter CodexRuntimeTests`在宿主SwiftPM sandbox/cache边界运行，
  共67项、0 failures；覆盖73项基础authoritative catalog、74项root rename目录、root generate/edit、
  read-write child generate、read-only child pre-permission deny、同名exact capability、durable prepared
  events、shutdown，以及installed exact `.4` App Server的offline integration。
- `CapabilityLeaseTests|SessionStateProtocolTests|CoworkInferencePresentationTests|TranslatisCLITests`全部退出0；CLI
  50项中8项真实provider smoke按设计skip。图片Tools与`ProviderImageGenerationToolService`专项5/5通过。
- 随后第一次完整`swift test --disable-automatic-resolution`正常退出0且无失败；但在最终移除尚未发布的
  `.hostedWebSearch` lease authority并补完Protocol测试后，第二次完整重跑又在
  `IntatisSharedUITests.xctest`挂起。进程持续0% CPU，sample落在XCTest async waiter，人工中断为130。
  因此当前结论是间歇性不稳定，不能用第一次成功删除wall-clock timeout与sample门。
- `swift build --product translatis --disable-automatic-resolution`、`xcodegen generate`、`TranslatisMac` macOS
  Debug unsigned build与`TranslatisiOS` generic Simulator Debug unsigned build均退出0。构建只出现仓库既有
  unused-result、deprecated `onChange`及Xcode并发compile提示。
- 所有新增图片执行都使用injected fake service；未读取或请求OpenAI API key，未发真实OpenAI/第三方
  provider请求，也未产生计费。真实图片provider兼容性仍必须由用户显式opt in后单独验证。

### 2026-09-01 较早的文档事实核对与完整测试挂起复现

- `scripts/check-version-consistency.sh`退出0并输出`Intatis version is consistent: 0.71 (build 71)`；
  `git diff --check`与核对前`git status --short`通过。
- `/Applications/Intatis.app`读回`0.71 (71)`，但只读inventory确认其Resources中没有`CodexRuntime`、
  `DocumentRuntime`或`BrowserRuntime`。这与shipping locator只接受bundle root的源码事实一致；当前安装只能
  作为主App/Chat预览，不能证明Code/Cowork与固定document/browser runtime可运行。
- `swift test --disable-automatic-resolution`在外层managed sandbox第一次于SwiftPM manifest自己的
  `sandbox-exec`初始化前被宿主拒绝；允许SwiftPM真实sandbox/cache后重跑完成编译并通过多个suite，但
  `IntatisSharedUITests.xctest`约5分46秒仍为0% CPU、无新输出，sample停在XCTest async waiter，最终人工
  中断为130。本轮完整suite因此不是通过。
- 中断后定向运行`ExecutionTracePresentationTests`17、`IntatisTypographyTests`2、
  `MarkdownSchedulerTests`6、`MessageRendererModeTests`11、`MessageRenderingTests`39、
  `ThreadLayoutTests|ThreadScrollCoordinatorTests`63，合计138/138、0 failures；挂起前另外六个SharedUI
  suite 36/36也已输出通过。该证据说明断言可分组通过，但没有关闭组合顺序、异步清理、AppKit全局状态或
  beta XCTest生命周期问题。
- 当时源码核对确认shipping `CodexBusinessToolHost`不发布`generate_image`、`edit_image`或
  `hosted_web_search`，且App Server固定`web_search=disabled`。该图片结论已被上节本轮代码与测试取代；
  hosted-search结论也已被2026-09-02接线与测试取代。保留本段只为解释文档错误与较早测试状态，不能覆盖
  当前工作树。

### 2026-08-31 v0.71版本收口与本机安装

- `project.yml`、macOS/iOS参考Info.plist、README、文档索引及全部current-baseline文档已同步为
  `0.71 (71)`；历史v0.70及更早证据保持原值。
- `xcodegen generate`和`scripts/check-version-consistency.sh`退出0，后者输出
  `Intatis version is consistent: 0.71 (build 71)`；localization `jq empty`与`git diff --check`通过。
- `swift test --disable-automatic-resolution`完整运行退出0，全部已执行suite为0 failures；未安装或未显式
  启用的external document/runtime smoke按既有条件skip。CLI product build通过。
- fresh DerivedData的`TranslatisMac` universal Release unsigned build与`TranslatisiOS` generic Simulator Debug
  unsigned build通过；两个bundle读回`0.71 (71)`。Mac主程序是arm64+x86_64，`Contents/MacOS`只有主程序，
  不引用Debug dylib。
- Mac staging使用`TranslatisMac.DeveloperID.entitlements`完成ad-hoc Hardened Runtime签名，deep strict codesign
  通过；signed entitlements为audio-input=true、allow-jit=false、disable-library-validation=false。
- `/Applications/Intatis.app`已原子替换为上述staging，安装与staging逐文件一致、无quarantine，主程序
  SHA-256为`2588e2a809efcfa4099ad17e70e347de8e236c031b15a8d0c3e3f050ab3150d7`；从exact安装路径
  启动成功，进程路径读回`/Applications/Intatis.app/Contents/MacOS/TranslatisMac`。旧`0.69 (69)`保留于
  `/Users/vita/.Trash/Intatis-before-v071-20260831-223908.app`。
- 这是本机开发预览，不是正式release；没有Developer ID secure timestamp、notarization、staple、
  Gatekeeper或fresh-account证据，也没有完成内置双架构Codex/document runtime发行closure。

### 2026-08-30 Cowork纯右侧UI边界修正

- 已完整撤回把`CoworkViewModel`、project settings、workspace/runtime ownership移入跨项目Feature的
  过深方案；上述App源码恢复原位置与原实现。当前新增product为presentation-only
  `IntatisCoworkUI`，直接依赖只有Core、Protocol、Conversation与SharedUI。
- `IntatisCoworkContentView`只接收`IntatisCoworkContentState`、bindings、thread source与
  `IntatisCoworkContentActions`；源码不引用`CoworkViewModel`、App Server、provider registry或dynamic
  tools。TranslatisMac adapter继续使用原ViewModel/runtime/session。
- `swift build --target IntatisCoworkUI --disable-automatic-resolution`通过；普通public contract测试2/2
  通过。`CoworkInferencePresentationTests|ThreadLayoutTests`最终41/41通过；中途1项source-boundary测试因
  Cowork composition移动到新UI文件而失败，测试路径修正后重跑通过，不是产品行为失败。
- `xcodegen generate`与TranslatisMac macOS Debug unsigned build通过；依赖图显示Mac显式链接CoworkUI，UI
  target没有CodexRuntime/AgentKernel/Cowork/Tools/Permission/MCP direct edge。
- 完整`swift test --disable-automatic-resolution`退出0，全部已执行suite为0 failures；真实外部runtime/
  provider等opt-in smoke仍按既有条件skip。TranslatisiOS generic Simulator Debug unsigned与CLI product build
  均通过；iOS依赖图没有CoworkUI。
- 本轮未修改Kuzio、未启动真实provider/session、未新增第三方依赖，也没有签名、公证、安装、Git add或
  commit。

### 2026-08-30 Code/Cowork App Server语义活动第一版

- 用户明确把2026-08-23的raw exact-method直出定义为临时方案。当前EventLog/`CodeProjection`继续保存
  bounded exact method/scalar；新增纯presentation `CodexActivityPresentationReducer`按exact turn/item
  identity归并item lifecycle，并把专用事件消费到message/usage/Goal/permission/roster。默认Code/Cowork
  使用本地化自然语言与SF Symbols，unknown future method保持通用可见；后台execution-trace开关返回原始行。
- `SessionProjectionPump`把带`textDelta`的`codex_app_server_event`与`message_delta`统一纳入50 ms
  fixed-window leading/trailing publication；仍逐seq fold全部EventLog，item/turn terminal与所有非delta继续
  immediate barrier。Cowork child live item改用durable `payload.eventID`，reasoning/plan delta的本地更新不再
  逐块直接publish；投影失败时不发布non-durable child activity。
- focused命令
  `swift test --disable-automatic-resolution --filter 'IntatisConversationCodeTests|SessionProjectionPumpTests|ExecutionTracePresentationTests|ThreadLayoutTests|CoworkInferencePresentationTests'`
  退出0：SharedUI 58、Conversation 35，合计93/93、0 failures。覆盖raw事实保留、全部known runtime
  item category、semantic coalescing、
  dedicated-event suppression、unknown event、child duplicate representation、commentary/final phase、
  reasoning delta cadence与terminal barrier。
- `swift test --disable-automatic-resolution --filter CodexRuntimeTests`退出0：runtime本体60、public contract 3、
  native child integration 1、bundled Skill 1，合计65/65、0 failures；使用installed exact `.4`和本地loopback/
  placeholder credential，没有真实provider网络或计费。
- `swift build --target IntatisSharedUI --disable-automatic-resolution`、`swift build --product translatis
  --disable-automatic-resolution`、`jq empty`、`xcodegen generate`、
  fresh DerivedData的`TranslatisMac` macOS Debug unsigned（`ENABLE_DEBUG_DYLIB=NO`）与`TranslatisiOS` generic
  Simulator Debug unsigned build均退出0。两次SwiftPM首次在外层managed sandbox的manifest阶段被
  `sandbox-exec`拒绝；同一命令在允许SwiftPM自身sandbox/cache的宿主边界重跑通过。App构建只报告仓库
  既有warnings及Xcode的exit-code-0噪声诊断。
- 最终安装阶段启动了本机App并确认进程保持运行，但没有读取真实session/config/credential或发送provider
  turn；仍未运行Light/Dark/VoiceOver与长时soak。因此自动化证明semantic mapping、稳定identity、编译、
  固定Runtime启动及既有回归，不冒充最终自然语言节奏和实际像素已由用户验收。

### 2026-08-30 App Server retry、submission admission与完整协议面审计

- exact `.4` fixture验证`error.willRetry=true`只产生可合并Reconnecting activity且不写通用runtime failure；
  `willRetry=false + turn/completed(failed)`才终结turn。warning/config/guardian/deprecation、MCP progress/startup、
  auto-approval、hook、structured thread status与无turn/thread的session notification都经过bounded raw
  projection；默认semantic UI分别展示或按明确非transcript类别消费，backend trace仍恢复raw method。
- Code/Cowork root submission改为先原子append`user_message + queued(attempt 1)`，随后启动Runtime/解析附件并
  append running；成功、取消、失败再追加唯一terminal。启动失败不再吞掉用户消息。retryable root terminal的
  Retry创建fresh可见continuation SubmissionID，不重放附件/一次性context，也不覆盖旧失败。
- exact installed Runtime现场生成`--experimental` JSON schema并锁定11种server request与70种notification。
  三类approval、dynamic tool、`currentTime/read`均有成功round-trip；其余request保持明确unsupported。
  `model/rerouted`fixture验证exact binding fail-closed；同一fixture同时证明protocol terminal发生在
  `turn/start` response与waiter登记之间时，late waiter立即失败而不悬挂。
- `swift test --disable-automatic-resolution`全量退出0、0 failures；依赖未安装或未显式启用的外部Document
  Runtime/corpus smoke按既有条件skip。`swift build --product translatis --disable-automatic-resolution`、
  localization `jq empty`、version consistency与`git diff --check`均退出0。
- fresh DerivedData的TranslatisMac macOS Debug unsigned与TranslatisiOS generic Simulator Debug unsigned均退出0。
  本机安装成品复用原已审计arm64 Codex/Browser Runtime，Developer ID重签后通过deep strict codesign、
  Codex execute validator与Browser execute validator；安装后main executable与staging hash一致、版本为
  `0.69 (69)`且App可启动。Gatekeeper按事实报告`Unnotarized Developer ID`，因此这里只是本机preview安装，
  不满足notarization/staple/release GO，也没有被记录成发行通过。

### 2026-08-30 v0.70版本收口

- `project.yml`、macOS/iOS参考Info.plist、README、文档索引及所有current-baseline文档已同步为
  `0.70 (70)`；历史v0.69验证记录保持原值，不批量改写。
- `xcodegen generate`退出0；`scripts/check-version-consistency.sh`输出
  `Intatis version is consistent: 0.70 (build 70)`；localization `jq empty`与`git diff --check`均退出0。
- `swift test --disable-automatic-resolution`全量退出0、0 failures；未安装或未显式启用的外部Document
  Runtime/corpus smoke按既有条件skip。
- fresh DerivedData的`TranslatisMac` macOS Debug unsigned（`ENABLE_DEBUG_DYLIB=NO`）与`TranslatisiOS`
  generic Simulator Debug unsigned均退出0；两个最终bundle直接读回
  `CFBundleShortVersionString=0.70`、`CFBundleVersion=70`，macOS `Contents/MacOS`只含arm64主程序。
- 本节只证明v0.70源码、测试与Debug bundle一致性；没有执行universal Release、双架构runtime closure、
  notarization、staple或Gatekeeper release gate。本机已安装的0.69 preview也没有被本次版本提交静默替换。

### 2026-08-30 v0.69版本收口

- `project.yml`、macOS/iOS参考Info.plist、README、文档索引及全部current-baseline文档已同步为
  `0.69 (69)`；历史v0.66安装/发行证据保持原记录，不做批量改写。
- `xcodegen generate`退出0；`scripts/check-version-consistency.sh`输出
  `Intatis version is consistent: 0.69 (build 69)`。
- `TranslatisMac` macOS Debug unsigned build使用fresh
  `/private/tmp/IntatisDerivedData-v069`、`ENABLE_DEBUG_DYLIB=NO`、`CODE_SIGNING_ALLOWED=NO`退出0；
  最终bundle读回`CFBundleShortVersionString=0.69`、`CFBundleVersion=69`，`Contents/MacOS`只含主程序。
- `TranslatisiOS` generic Simulator Debug unsigned build使用fresh
  `/private/tmp/IntatisDerivedData-v069-ios`退出0；最终bundle同样读回`0.69 (69)`。输出只有仓库既有warning
  与Xcode的exit-code-0噪声诊断。
- 提交前最终focused命令
  `swift test --disable-automatic-resolution --filter 'ThreadScrollCoordinatorTests|MessageRenderingTests|CoworkAgentThreadPresentationModelTests|ThreadLayoutTests'`
  退出0：MessageRendering 39、ThreadScrollCoordinator 31、CoworkAgentThreadPresentationModel 10、
  ThreadLayout 32，合计112/112、0 failures。版本元数据变更未修改测试源码、依赖、EventLog/schema或
  产品能力。Developer ID、notarization、staple、Gatekeeper与clean-account仍是独立release gate，不能
  由本次unsigned Debug evidence替代。

### 2026-08-30 macOS LaTeX文稿占位重叠收口

- `math-stream`离线真实窗口证明问题图标不是message footer的`doc.on.doc`：该fixture没有footer；它是
  新rich document挂载后、TextKit 2 live `MTMathUILabel` provider安装前短暂出现的generic文稿占位。
- 当前只在Intatis SharedUI macOS facade增加owner-bound attachment-hosting gate。每个新
  `RenderableDocument`先opacity 0真实挂载，existing exact raw projection覆盖一个main-queue turn；随后在
  animations disabled transaction中显示rich。gate只持有`ObjectIdentifier`与可取消Task，replacement/
  disappear会取消，不保存document/parser/result，不修改vendor、依赖、公式语法/attachment或iOS路径。
- 重新构建的`math-stream` fixture逐步验证`$`→`$x`→`$x$`→`$x$ 后`→`$y$ 后`；完整和纠正后的
  `x`/`y`公式及后续中文均可见，AX继续暴露原公式描述，稳定截图中没有文稿图标。尝试使用系统
  `screencapture`录制三秒转场时录屏进程未在有界时间返回，已中止，未把该录像记为证据。
- 受管沙箱内首次SwiftPM运行在manifest阶段被`sandbox_apply`拒绝；同一focused命令在允许SwiftPM
  自身sandbox的宿主边界重跑，`MessageRenderingTests`39、`ThreadScrollCoordinatorTests`31、
  `ThreadLayoutTests`32，合计102/102、0 failures。未修改测试源码。
- `TranslatisMac` macOS Debug unsigned与`TranslatisiOS` generic Simulator Debug unsigned build均退出0；
  Mac使用`ENABLE_DEBUG_DYLIB=NO`。输出只有仓库既有warning与Xcode的exit-code-0噪声诊断。
- 三个`Vendor/SwiftStreamingMarkdown`实验文件已恢复为HEAD，当前vendor/manifest/lock/NOTICE/patch ledger
  均无本任务差异；未新增/升级依赖、renderer、图片/raster cache或公式fallback。未运行完整suite、
  Developer ID/公证/真机/长soak，因此本证据只关闭用户指出的macOS转场占位重叠与受影响编译/回归面。

### 2026-08-29 流式Markdown/公式monotonic rich replacement

- 根因位于`IntatisMicrosoftMarkdownRenderState.submit`与`IntatisMessageContentView`的双重exact-request
  gate：每个token先把上一份`publishedDocument`设为nil，facade立即显示raw；50 ms debounce/parse完成后
  又挂回rich，因此parse偶尔快于token间隔时形成高频`rich → raw → rich`。
- 当前只为同一未完成message、同style/appearance/typography/configuration、仍满足64 KiB admission且
  新raw逐字以已发布raw为prefix的append-only successor保留当前已挂载rich；latest parse只有exact-current
  才可发布并rich→rich替换。correction、truncation、completed-message mutation、semantic/style漂移、
  oversize、suspension、offscreen eviction与deactivate仍立即回current raw。没有新增cache或第二renderer。
- `swift build --target IntatisSharedUI --disable-automatic-resolution`退出0。focused命令
  `swift test --disable-automatic-resolution --filter 'MessageRenderingTests|ThreadScrollCoordinatorTests|ThreadLayoutTests'`
  退出0：MessageRendering 39、ThreadScrollCoordinator 31、ThreadLayout 32，合计102/102、0 failures；
  覆盖公式stream/correction/reentry、exact final、raw correction/truncation、oversize、viewport suspend/
  eviction、style/typography replacement、1,249-delta fixture及scroll scope。未修改测试源码。
- 另在`/private/tmp`编译并运行不写仓库的`@testable`协议探针，直接断言append与incomplete→complete可保留，
  correction、truncation、appearance漂移、oversize及completed后reopen不可保留；输出
  `STREAMING_RICH_RETENTION_PROBE_OK`，探针源码和binary随后删除。
- `TranslatisMac` macOS Debug unsigned与`TranslatisiOS` generic Simulator Debug unsigned build均使用上一节
  独立DerivedData并退出0。本轮没有运行完整`swift test`、真实provider流、GUI录像/长soak、正式签名或
  release gate；双端真实观感仍需在新构建的Markdown/公式长回复中确认，不能由离线协议测试外推。

### 2026-08-29 macOS渲染与连续滚动状态流收口

- macOS Chat与共享iOS Chat从本地`DispatchQueue.main.async + 0.18s animation`切换到与Code/Cowork相同的
  `IntatisThreadScrollCoordinator`和`IntatisContinuousThreadStack`。initial restore、live token、completion、
  rich correction与宿主提交均绑定exact session presentation scope；macOS另接width correction与既有Jump。
  live follow采用100 ms fixed-window leading/trailing cadence，只有一个executor request和一个replaceable
  pending request。长thread先确认raw bottom anchor再准入rich，并在两端使用同一16-row重型graph预算；
  macOS用户gesture detach继续阻止live/rich抢回。没有修改消息布局、字体、颜色、玻璃、控件或EventLog。
- `IntatisContinuousThreadRenderBudget`补齐flush lifecycle generation与Task cancellation检查，并跳过重复
  visibility observation；同scope deactivate→reactivate时旧yielded task不能提交。Cowork selected-agent
  snapshot更新改为same-generation单一in-flight load与一个latest follow-up marker，持续publication不再
  cancel/restart读取，也不再对已有transcript每次切换`isLoading`；A→B→C stale-generation与300 ms rich
  quiet gate保持不变。
- `swift build --target IntatisSharedUI --disable-automatic-resolution`在外层managed sandbox中先于manifest
  编译被`sandbox_apply`拒绝；按既有规则在允许SwiftPM自身sandbox的host边界原命令重跑，退出0。
- focused命令
  `swift test --disable-automatic-resolution --filter 'ThreadScrollCoordinatorTests|MessageRenderingTests|CoworkAgentThreadPresentationModelTests|ThreadLayoutTests'`
  退出0：`ThreadScrollCoordinatorTests`31、`MessageRenderingTests`39、
  `CoworkAgentThreadPresentationModelTests`10、`ThreadLayoutTests`32，合计112/112、0 failures。未修改测试源码。
- `xcodegen generate`退出0；`TranslatisMac` macOS Debug unsigned build使用独立
  `/private/tmp/IntatisDerivedData-render-scroll`、`ENABLE_DEBUG_DYLIB=NO`、
  `CODE_SIGNING_ALLOWED=NO`退出0。输出只有仓库既有warning与Xcode已知的
  `command failed with exit code 0 but produced no further output`噪声诊断；没有源码编译失败。
- `TranslatisiOS` generic Simulator Debug unsigned build使用独立
  `/private/tmp/IntatisDerivedData-render-scroll-ios`并退出0；共享public scroll geometry/lifecycle seam没有
  扩大iOS Chat-only产品图。输出同样只有既有warning与上述exit-code-0噪声诊断。
- 本轮没有运行完整`swift test`、180秒GUI soak、真实provider/credential/network、
  Developer ID签名、公证、staple或Gatekeeper；focused与Debug编译不能替代这些门槛。

### 2026-08-28 单次 Host Application Identity 与自动命名派生

- 新增`IntatisHostApplicationIdentity`和进程级`IntatisHostApplication.configure(name:)`。Intatis
  macOS/iOS/CLI入口显式安装`Intatis`；existing focused tests因此继续看到逐字相同的
  `intatis.*`/`INTATIS_*`/`.intatis*` canonical值。identity第一次读取后sealed，不同名称的迟到配置
  明确失败。
- 在`/private/tmp`建立并在验证后删除一个真实外部SwiftPM executable consumer。它只通过public
  Intatis products安装`Mopelium`，随后断言`Mopelium`storage、`mopelium.json`、`MOPELIUM_*`、
  `com.vitemis.mopelium.*`、`.mopelium/browser|git-worktrees`、`.mopelium-rag-*`、
  `mopelium.standard.v5`、`mopelium.codex-mcp.*`、`mopelium:siliconflow-v1`和
  `__mopelium_authorization_context`；同时断言legacy`.intatis-rag-*`仍在mandatory deny floor。
  external package最终输出`HOST_IDENTITY_PROBE_OK`。dependency解析使用本机pinned cache；期间一次
  swift-asn1 cache update出现LibreSSL诊断，随后从cache成功解析并完成build/run，不能记为产品失败。
- 另一份验证后删除的public consumer读取checked-in Intatis Knowledge schema resources，并确认runtime
  只替换产品拥有的string identity/assertion：profile const、reverse-domain identity、schema URL/title与
  `.mopelium-rag` path pattern均为Mopelium，schema keyword/structure/bounds不变；同时验证非法前导separator
  App名被拒绝。最终输出`HOST_SCHEMA_PROBE_OK`。
- 第三份验证后删除的外部consumer只先调用`configure(name: "Mopelium")`，再构造legacy Context/Skills提示；确认
  `Mopelium`、`MOPELIUM_SKILL_CATALOG`与`MOPELIUM_ACTIVATED_SKILLS`生效且不残留
  `INTATIS_SKILL_CATALOG`，最终输出`HOST_CONTEXT_PROBE_OK`。对应当前Intatis兼容回归
  `ContextProjectionTests`23/23与`IntatisSkillsTests|SkillMCPDependencyTests`29/29通过。
- `swift build --target IntatisCore --disable-automatic-resolution`、
  `swift build --target IntatisCodexRuntime --disable-automatic-resolution`、
  `swift build --target IntatisKnowledge --disable-automatic-resolution`、
  `swift build --target IntatisSharedUI --disable-automatic-resolution`和
  `swift build --product translatis --disable-automatic-resolution`均退出0。首次Core build在外层managed
  sandbox的SwiftPM manifest阶段被`sandbox_apply`拒绝；按本文件既有规则在允许SwiftPM自身sandbox的
  host边界重跑通过。
- `swift test --filter CodexRuntimeTests --disable-automatic-resolution`最终61/61、0 failures：包含
  56项runtime、3项plain-public v1 contract、1项bundled Skill和1项installed pinned native child。
  这证明当前Intatis默认identity没有改变fixed App Server provider/config/role/toolset及现有public调用标签。
- 相关focused suites最终合计136 tests、2个host-Keychain opt-in skip、0 failures：
  `PathConfinementTests`10、`AuthorizationSidecarTests`12、`KnowledgeContract/FileSystem/SnapshotStore/
  SourceLocatorTests`50、`MCPImportTests`9、`MCPSecretStoreTests`8（2 skipped）、
  `SkillMCPDependencyTests`9、`MessageRendererModeTests`11、`ToolRegistryLeaseTests`27。首次组合运行唯一
  failure是当前identity正好等于legacy Intatis时，MCP import parser把同一个`$intatisSecretRef`候选加入
  两次而误判mixed field；production parser改为先去重current/legacy候选，`MCPImportTests`随后9/9通过。
- `xcodegen generate`退出0；`TranslatisMac` macOS Debug unsigned build使用
  `ENABLE_DEBUG_DYLIB=NO`和独立DerivedData退出0；`TranslatisiOS` generic Simulator Debug unsigned build
  退出0。输出只有仓库既有unused-result、deprecated`onChange`与Xcode exit-code-0/no-further-output
  diagnostics。
- `.build/debug/translatis selftest`在最终源码上退出0：offline Chat、Code write/read和multi-route Cowork
  inference profile三段均PASS；输出继续使用Intatis/`INTATIS_*`，证明当前产品默认identity兼容。
- 后续产品文案/控制面审计又运行`ChatSessionAutoTitleTests`24、`GoalVerifierControlPlaneTests`12、
  `MCPServerContributorTests`5及Codex developer-instructions精确用例1项，合计42/42通过；CLI`help`、
  `mcp help`与offline`selftest`均退出0。
- 完整`swift test`第一轮让全部target运行到结束；唯一failure是本轮把plain-message accessibility ID
  改为动态表达式后，既有SharedUI源码结构测试找不到Intatis literal。production随后保留逐字相同的
  Intatis分支并为下游使用identity-derived分支，该精确用例复测1/1通过。修正后的第二次完整运行未报告
  test failure，但`IntatisSharedUITests`在异步XCTest waiter中超过六分钟无输出；1秒只读`sample`显示
  main thread等待XCTest expectation、worker queues均idle，故明确中断为exit 130，没有把它写成全量
  green。第一轮已证明同一SharedUI target除上述已修正源码断言外全部完成；最终受影响的Context/Skills、
  title、GoalVerifier、MCP与Codex精确用例均独立通过；另将`MessageRenderingTests`、
  `MessageRendererModeTests`、`ExecutionTracePresentationTests`、`ComposerVoiceInputTests`与
  `ThreadLayoutTests`组合重跑，SharedUI共95/95、0 failures。
- 本轮没有修改测试源码，没有运行真实provider/credential/network、GUI手动命名smoke、Developer ID
  签名、公证、staple、Gatekeeper或发行打包。固定Rust patch字段和binary未修改，因而没有重建Codex
  binary或重跑Rust suite；external identity probe不替代这些发行门。

### 2026-08-28 跨项目 Codex Runtime v1 稳定宿主面

- `IntatisCodexRuntime`继续作为唯一SwiftPM宿主产品，新增机器可读的
  `CodexRuntimeHostContract.publicAPIMajorVersion == 1`，并以
  `docs/CODEX_RUNTIME_INTEGRATION.md`冻结其他Vitemis项目可直接使用的package/product/module、route、
  configuration、session lifecycle、event、approval与dynamic-tool公共符号。没有增加umbrella facade、
  第二runtime、协议adapter、功能fallback或新的外部依赖，也没有修改既有App Server执行语义。
- `CodexRuntimePublicContractTests`只用普通public imports，3/3、0 failures；它实际编译最小外部host构造与
  `events/start/startTurn/runTurn/waitForTurn/interrupt/resolveApproval/shutdown`调用标签，并核对exact
  `codex-cli 0.145.0-intatis.4`派生身份。随后`swift test --filter CodexRuntimeTests
  --disable-automatic-resolution`合计61/61、0 failures，包含本机exact pinned runtime与native child
  integration。另在临时目录创建独立SwiftPM executable package，以本仓库absolute local path和文档列出的
  四个products进行真实外部consumer build；最小route/configuration/session构造编译成功后已删除整个临时
  package及其build/dependency checkout。
- `swift build --product translatis --disable-automatic-resolution`、`xcodegen generate`、`TranslatisMac` macOS
  Debug unsigned build（`ENABLE_DEBUG_DYLIB=NO`）和`TranslatisiOS` generic Simulator Debug unsigned build均
  退出0；iOS dependency graph没有引入`IntatisCodexRuntime`。编译只保留既有unused `try?`与无AppIntents
  metadata extraction warnings。
- 首次SwiftPM聚焦测试在外层managed sandbox中于`sandbox_apply`被拒绝，按本文件既有规则在允许
  SwiftPM自身sandbox的宿主边界原命令重跑后通过。本轮没有启动真实provider、发送模型请求、使用credential、
  修改其他项目、制作发行包、Developer ID签名或公证；验证范围是公共源码契约、当前runtime回归和两端编译。

### 2026-08-27 v0.66版本、双架构本机预览构建与安装

- `project.yml`唯一事实源、macOS/iOS参考Info.plist、README与全部current-spec版本标记已统一为
  `0.66 (66)`；`xcodegen generate`退出0，`scripts/check-version-consistency.sh`输出
  `Intatis version is consistent: 0.66 (build 66)`。生成工程的App target精确为`TranslatisMac`与
  `TranslatisiOS`，没有恢复已删除的Mac App Store产品图。
- `TranslatisMac`在独立DerivedData中以Release、`ARCHS='arm64 x86_64'`、`ONLY_ACTIVE_ARCH=NO`、
  `ENABLE_DEBUG_DYLIB=NO`和`CODE_SIGNING_ALLOWED=NO`构建成功；最终bundle读回`0.66 (66)`，主程序
  是`x86_64 arm64` universal Mach-O，`Contents/MacOS`只含`TranslatisMac`且bundle中没有Debug dylib。
  `TranslatisiOS` generic Simulator Debug unsigned build也退出0并读回`0.66 (66)`；编译输出只有仓库既有
  unused-result、deprecated `onChange`与metadata-extraction warnings。
- 安装用staging bundle以`TranslatisMac.DeveloperID.entitlements`完成ad-hoc Hardened Runtime签名；
  strict/deep codesign通过，runtime flag存在，audio-input=true、allow-jit=false、
  disable-library-validation=false，无quarantine。最终`/Applications/Intatis.app`与staging逐文件
  `diff -qr`一致，bundle ID为`com.Vita0818.TranslatisMac`，主程序SHA-256为
  `b024f5bc279daefa647d8b910730e849470a858b646c701fc2608e50e001fd45`，并从exact安装路径成功启动；
  进程路径观察为`/Applications/Intatis.app/Contents/MacOS/TranslatisMac`。
- 被替换的`0.55 (55)` arm64 App未删除，保留在
  `/Users/vita/.Trash/Intatis-before-v066-20260827-120349.app`。本条是本机开发预览证据，不是Developer ID
  公证发行：当前仍未完成内置双架构Codex/document runtime closure、Developer ID identity签名、Apple
  notarization、staple、Gatekeeper或fresh-account gate。既有v0.65 partial Cowork session也没有原地迁移，
  验证本轮root-authority修复仍须新建Cowork session。

### 2026-08-26–27 macOS fresh Cowork root authority bootstrap回归修复

- 根因是v0.65接入native MCP时，`CoworkViewModel.codexSession`新增了“exact `@main`必须只有一个
  taskless CapabilityLease”的启动校验，但fresh bootstrap仍分步只写settings与agent identity；因此空白
  Cowork页面会在任何user message/provider turn之前以0个root capability lease正确fail closed。当前修复
  保留该安全校验，把空EventLog上的settings、workspace lease、business capability lease和agent identity
  改为一个`appendIfEmptyChecked`四事件批次，并让App Server/native MCP/business host消费同一durable
  lease pair；没有增加fallback、legacy Orchestrator或provider调用。
- settings变更若改变root workspace或read-only/read-write authority，会在同一个session-state事务中撤销
  旧workspace/capability pair、换发新pair并更新agent metadata；普通下一轮模型选择只保留原有live-binding
  rebind语义。既有v0.65 partial session（已有settings/agent/error但无完整pair）不自动补写，也不创建空
  Codex thread，仍明确要求新建session。
- 聚焦现有tests合计93/93、0 failures：`CodexRuntimeTests`所在target 58/58、
  `SessionProjectionStoreTests` 17/17、`CoworkProjectionTests` 5/5、`SessionStateProtocolTests` 4/4、
  `CoworkInferencePresentationTests` 9/9。第一次组合运行中唯一失败是既有source-contract仍要求fresh profile
  直接取自`projectSettings.defaultPermissionProfile`；生产代码恢复该等价且更明确的来源后，独立重跑9/9。
  未修改测试源码。
- `swift build --target IntatisCodexRuntime --disable-automatic-resolution`、
  `swift build --product translatis --disable-automatic-resolution`和`TranslatisMac` macOS Debug unsigned build
  （`ENABLE_DEBUG_DYLIB=NO`、独立DerivedData）均退出0。SwiftPM首次在外层managed sandbox中于manifest
  阶段被`sandbox-exec`拒绝；按本文件既有规则在允许SwiftPM自身sandbox的宿主边界重跑后通过。App build
  只报告仓库既有warnings。
- 未启动App、未修改或删除用户的截图session、未运行真实provider/credential/network、完整SwiftPM suite、
  iOS build、Developer ID、公证或Gatekeeper；因此本条证明源码、持久化投影、Codex host回归与Mac编译，
  不把旧partial session迁移或真实线上turn冒充为已验证。

### 2026-08-23 OpenRouter strict Responses request-shape修复（历史证据）

本段记录当时`.2→.3`窄迁移的验证；当前源码已按用户后续决定改为所有旧runtime/toolset要求新session，
不得把下列旧测试结果解释为当前migration合同。

- 根因确认是`v0.60` App Server接线回归，不是网络或模型选择：host catalog错误宣告reasoning summary，
  upstream Codex又加入`include reasoning.encrypted_content`、`parallel_tool_calls`、
  `prompt_cache_key`、`client_metadata`、web-search与namespace tool；在用户保留
  `require_parameters=true`的OpenRouter route上，这组请求shape没有可接收endpoint。用户实际
  `~/.config/translatis/translatis.json`只做安全字段白名单读取，mtime早于该提交，未被本轮修改。
- 两个仓内Rust patch按序对exact upstream commit通过`git apply --check`；`cargo fmt --check --all`
  通过，`codex-core`的config/provider与HTTP序列化focused tests、`codex-api` WebSocket payload test
  各通过。release arm64 `codex-cli 0.145.0-intatis.3`构建成功，SHA-256为
  `6c4850f4db3ed3e393837b9174ff21257e535f286bd01a923549719c994edd61`；已安装到
  `~/.local/bin/translatis-codex`，旧`.2`分名保留且official `codex`未覆盖。
- 本地假Responses E2E使用真实`.3 app-server`完成turn且完整`provider` object逐值相等；最终request
  只含`input/instructions/model/provider/reasoning/store/stream/tool_choice/tools`，reasoning仅为
  `effort=max`，tools只含ordinary function，且无控制header、真实key、外网或计费。
- `swift test --filter CodexRuntimeTests`：22/22、0 failures；覆盖OpenRouter official config、
  root-thread developer instruction、exact `.2→.3`先resume/同ThreadID后原子record upgrade、`.1`拒绝，
  以及真实installed `.3` offline initialize/thread-start/shutdown handshake。
- `xcodegen generate`通过；`TranslatisMac` Debug以locked package versions、
  `ENABLE_DEBUG_DYLIB=NO CODE_SIGNING_ALLOWED=NO`构建通过。最终
  `dist/Intatis-CodexRuntime-Preview.app`只有一个arm64主Mach-O，`otool -L`无debug/preview dylib，
  ad-hoc Hardened Runtime strict codesign通过；签名后主程序SHA-256为
  `d287bbad2925c0211f9356afd8af1110ca317f2e073f781ab63e6878c19b892a`。LaunchServices从该最终路径
  启动，精确进程路径读回并持续运行；旧`.2`预览以分名路径保留。
- 截图session `cowork_y7i5fcpg`只读核对为schema-v2、0600、单链接、materialized `.2` mapping，
  ThreadID/workspace字段均存在，满足上述窄迁移前提；未读取对话、credential或rollout内容，也未发送
  真实provider请求。用户下次在修复版Send时才由产品执行官方resume与原子升级。
- 本轮未运行完整SwiftPM suite、iOS build、真实外部provider请求或正式Developer ID/公证流程；这些
  不应从focused测试、fake E2E或ad-hoc preview启动外推。

### 2026-08-22 Codex Runtime 第一版

- `swift test --filter CodexRuntimeTests`：20/20 通过。新增覆盖current Code route与Cowork exact binding的
  OpenRouter完整`options.provider` opaque passthrough、未知nested字段逐值保持，以及secret-bearing
  provider object在credential resolution前fail closed；其余覆盖 Responses route/custom endpoint、
  credential redaction、0.145.0 exact model catalog、`shell_snapshot=false` + core/secret-filtered shell
  environment、0600/0700 storage、unsafe directory no-repair、cross-process runtime flock、strict version、
  test-only full turn、server-initiated command approval round-trip、explicit executable override不降级、
  legacy-without-mapping failure、旧shell snapshot目录fail-closed且不删除、untrusted JSON-RPC numeric
  request ID、TERM-resistant version probe的有界强制结束、shutdown等待真实process exit后才释放session flock，
  以及真实 installed `codex-cli 0.145.0-intatis.2` offline initialize/thread-start/shutdown handshake。
- `swift test --filter IntatisProvidersTests`：204/204 通过。
- `swift test --filter TranslatisCLITests`：49/49 通过，8 个显式真实provider/Knowledge/multimodal smoke
  按环境跳过。
- `swift build --product translatis`：通过。
- 完整 `swift test`：Tools 227/227（31 skipped）与 Skills 29/29通过；随后在仓库既有
  SharedUI `ComposerVoiceInputTests` async waiter阶段长期无输出，按既有已知hang人工中断，退出130。
  因此本轮不记为full suite通过；该hang发生在Codex target测试之后的独立SharedUI进程，不能用来
  否定已完成focused结果，也不能被忽略为full pass。
- `xcodegen generate`：通过。
- `xcodebuild ... -scheme TranslatisMac -configuration Debug -destination 'platform=macOS'
  ENABLE_DEBUG_DYLIB=NO build`：通过。
- `xcodebuild ... -scheme TranslatisiOS -configuration Debug -destination 'generic/platform=iOS Simulator' build`：
  arm64+x86_64通过；dependency graph仍为29个Chat子集targets，不含`IntatisCodexRuntime`。
- 派生Rust验证：`codex-model-provider-info` 25/25；config→opaque body provider、Responses JSON、
  WebSocket payload三个focused测试通过；`cargo fmt --check`与release build通过。完整`codex-api`为137/138，
  唯一失败`upload_openai_file_reports_blob_transport_diagnostics_without_sas`在独立未打补丁upstream
  baseline同样失败，不归因本补丁且未修改上游测试凑绿。
- 本地HTTP假Responses E2E：真实`0.145.0-intatis.2 app-server`完成turn，抓包断言path为
  `/v1/responses`，整个`provider` object逐值等于输入，包含`require_parameters`、
  `allow_fallbacks`、`order`与补丁未枚举的nested `future_routing`；请求不含任何`x-intatis-*`
  控制header。无真实key、外网或计费。
- CLI offline startup/exit smoke：exact `codex-cli 0.145.0-intatis.2` ready并正常退出。
- CLI loopback真实内核smoke：本机HTTP假Responses服务返回官方SSE事件，真实Codex App Server完成
  `turn/start`并显示`local Codex turn ok`；退出后同一workspace重启resume同一ThreadID。服务关闭后
  resume仍成功，证明恢复不依赖模型网络。
- materialized storage核对：首个turn后写schema-v2 `runtime.json`；`runtime.json`、`models.json`、
  `runtime.lock`均为0600。对整个新temporary runtime root扫描placeholder provider token为0命中，
  `shell_snapshots`目录不存在。仅start/立即shutdown的真实handshake不写runtime mapping。
- 没有运行真实外部provider/计费请求；没有构建或bundle Codex universal binary；Developer ID、
  nested signing、公证、staple、Gatekeeper和fresh-user release gate未运行。
- 首次gitignored预览错误使用了Xcode 27默认Debug launcher。用户在2026-08-22 16:26提供的真实
  crash report显示进程在进入`main`前由DYLD终止：主程序引用
  `@rpath/TranslatisMac.debug.dylib`，ad-hoc重签名后的主程序和调试dylib因non-platform Team ID不一致被
  library validation拒绝。该包虽然曾通过`codesign --deep --strict`，仍不是可启动证据；问题与
  Codex App Server业务逻辑无关。
- 当前`dist/Intatis-CodexRuntime-Preview.app`已用同一源码、
  `ENABLE_DEBUG_DYLIB=NO`和`CODE_SIGNING_ALLOWED=NO`重建，再以Developer ID entitlements做ad-hoc
  Hardened Runtime签名。`Contents/MacOS`精确只含主`TranslatisMac`，`otool -L`不再引用任何
  `TranslatisMac.debug.dylib`/`__preview.dylib`，strict deep codesign通过；embedded entitlements为
  audio-input=true、allow-jit=false、disable-library-validation=false。最终`dist`包通过`open -n`走
  LaunchServices启动，精确进程路径读回正确并持续运行28秒，
  随后由测试者主动TERM关闭；最终主可执行文件SHA-256为
  `9755310454444845a6613800a6647eff605169fda36771e545975e74bb024265`。该v0.55 arm64 Debug包包含
  新NOTICE，但仍不bundle `codex`，只适合当前已安装exact `0.145.0-intatis.2` runtime的开发机试用，不能作为
  发行产物。

### 2026-08-22 macOS 文件夹项目第一版

- 完整 `IntatisCoreTests` 64/64、0 failures，其中 `ProjectFolderStoreTests` 10/10：覆盖 owner-only
  binary plist、序列化无 bookmark、同模式重复 canonical folder 幂等、相同 path 跨模式独立、
  跨模式 association 拒绝、旧 mixed-mode 草稿拆分、conversation 跨项目唯一归属、24 路并发追加
  无丢失、relative/escape 输入拒绝、
  未知 schema 不被覆盖，以及移除项目后用户文件与 session EventLog bytes 均保持不变；
- 完整 `ThreadLayoutTests` 30/30、0 failures，其中 folder-project composition 1/1；冻结当前模式过滤、
  disclosure folder、无固定高度/项目主页/跨模式菜单、共享 ScrollView/Unfiled、三种既有 runtime
  composition 与“不移动 session 目录”的边界；
- `jq empty Apps/SharedResources/Localizable.xcstrings` 与 `xcodegen generate` 均退出 0；
- `swift build --disable-automatic-resolution` 退出 0；
- `TranslatisMac` macOS Debug unsigned build（`ENABLE_DEBUG_DYLIB=NO`、独立
  `/private/tmp/IntatisDerivedData-folder-project`）退出 0，最终 App 可执行文件存在，Info.plist 读回
  `0.55 (55)`；最终增量构建只输出 multiple matching macOS destinations warning；
- `TranslatisiOS` generic Simulator Debug unsigned build 退出 0，bundle 读回 `0.55 (55)`；source scan
  未发现 iOS/SharedUI Projects UI 接线，既有 Chat-only target 边界不变；
- Computer Use 对最终 macOS Debug bundle 的只读验收确认：Chat folder row 初始 AX value 为
  `Collapsed` 且只占一行；点击后只新增该文件夹的空会话提示，再次点击完全移除子内容；Projects 与
  Unfiled 同属一个 sidebar scroll area。切换 Code 后，Chat 项目不再出现，页面只显示 Code 自己的
  `Projects / No projects yet / Unfiled / New code session`。没有触发 folder picker、创建/删除 session、
  provider 或 workspace 动作，验收后已关闭临时 App；
- 尚未运行完整 SwiftPM suite、真实 App 的 folder picker/right-folder/cancel、Light/Dark、
  多窗口、VoiceOver、Developer ID、notarization 或 Gatekeeper。项目目录没有写入用户文件夹，也未读取
  真实 provider/auth 配置。

### 2026-08-21 macOS 对话 chrome 与 Cowork Tasks 收口

- macOS Chat 与共享 Code/Cowork 用户气泡继续使用官方 SwiftUI `Glass.regular`，只把 continuous
  corner radius 从 16 调为 20。Code/Cowork 删除 user row 内 ordinary submission status renderer，
  同时移除会把短消息撑到最大宽度的内部 status `Spacer`；Submission/EventLog/projection 和右栏
  failure/Retry 未改。Permission card/notice 源码、位置和运行态截图保持原样。
- `IntatisJumpToLatestButton` 改为 `arrow.down` + native large circular glass control，保留本地化 help、
  VoiceOver label 和原 accessibility identifier。Chat/Code/Cowork overlay 改为 `.bottom`；macOS root
  注入当前 window content width，纯 layout policy 再用 detail 与 overlay surface width 补偿真实 sidebar/
  inspector，使最终中心等于整个 app window 中心。Cowork 删除 rail `trailingContentMargin` 偏移，
  ScrollView 仍跨越 thread + rail；standalone fixture offset 为零。Cowork Tasks 把 progress 合并进 header，row 收口为
  单一 marker、两行以内标题和可选 trailing chevron；status 继续通过 accessibility value/help 暴露，
  detail disclosure 仍展示完整 durable facts。
- Agents card 的 header 改为系统 `person.2.fill`；row status 最终从原始 13pt/20pt 明显放大到 20pt/30pt，并使用
  hierarchical 圆形 SF Symbol family。running 不再显示媒体式 `play.circle.fill`，failure/blocked/
  limited/cancelled 也不再混用 triangle、octagon、gauge 或 slash；没有新增自绘 icon 或图片资源。
- `jq empty Apps/SharedResources/Localizable.xcstrings` 通过；新增 Show/Hide task details 的 English/
  简体中文字符串。`ThreadLayoutTests` 29/29、0 failures，新增 source-shape 回归冻结 20pt glass、
  submission status row 缺席、large 圆形且 whole-window 居中的 Jump button 和 compact Tasks；新增纯
  geometry test 冻结 sidebar/inspector compensation 与 nil-host fallback；Agent status follow-up 另与
  `CoworkInferencePresentationTests` 8/8 组合为 37/37、0 failures；`swift build
  --disable-automatic-resolution` 退出 0。
- `xcodegen generate` 退出 0；`TranslatisMac` macOS Debug unsigned build（`ENABLE_DEBUG_DYLIB=NO`、
  独立 `/private/tmp/IntatisDerivedData-ui-pass`）退出 0，只有仓库既有 warnings。另以现有
  `.CoworkAgentConversationFixture` bundle suffix 构建离线 production-surface fixture，退出 0。
  `TranslatisiOS` generic Simulator Debug unsigned build 也退出 0，证明共享 ThreadSurfaces/String Catalog
  没有破坏 iOS Chat 子集；iOS 用户气泡半径未随本次 macOS pass 修改。
- Agent status follow-up 重新运行 `xcodegen generate`，并分别以
  `/private/tmp/IntatisDerivedData-agent-symbols` 与
  `/private/tmp/IntatisDerivedData-ios-agent-symbols` 构建 macOS/iOS Debug，均退出 0；unique
  `.CoworkAgentConversationFixture` 也在 `/private/tmp/IntatisUIAgentStatusFixtureBuild` 构建通过。
- Computer Use 在刚构建的真实 Cowork session 中确认：短用户消息为紧凑胶囊感玻璃气泡且无
  `Completed` 等 status；Tasks 显示 `Tasks 0/1` 与一行 marker/title/disclosure；既有
  `finish_run approved` permission notice 仍存在。离线 fixture 的 Earlier 页同时确认圆形下箭头
  `Jump to latest` 可见、尺寸更实用、位于 fixture 整体横向中线且 AX label 正确；整个 app window 的
  sidebar/inspector 补偿由纯 geometry test 精确验证。真实 app/fixture 均未调用 provider、修改 workspace
  或发送消息。
  Agent status follow-up 的新 fixture 还确认 `person.2.fill` header、20pt/30pt hierarchical
  `ellipsis.circle.fill` running markers 清晰可见，行高、选中背景、名称与模型标签均未挤压；fixture
  关闭前未触发任何数据面动作。
  未验证 Dark、Reduce Transparency、Increase Contrast、VoiceOver 实际朗读、多任务长列表或 iOS 像素；
  这些仍是手动矩阵。

### 2026-08-21 固定只读工具默认放行

- 生产行为只在 `DeterministicPolicyGate` 的两个既有分支中从 `pass` 改为 `allow`：
  `structured_read_only` 固定 reader/OCR 与 local-only `search_knowledge`。没有修改协议、sidecar、
  EventLog、PermissionResponder、reviewer/control plane、工具 descriptor、CapabilityLease 或
  WorkspaceLease；network-backed Knowledge 和其他网络/写入/通用 exec/destructive 工具仍按原路径审查。
- 聚焦 suites 共 169 tests、0 failures：`IntatisPermissionTests.xctest` 56、
  `SearchKnowledgeToolTests` 4、`ToolRegistryLeaseTests` 27、`AgentLoopPolicyTests` 37、
  `DocumentReadToolSplitTests` 4、`AutomaticPermissionReviewTests` 39、
  `ModelDrivenKnowledgeAgentLoopTests` 2。它们覆盖 direct gate、六个固定结构化只读工具的 existing intent、
  local Knowledge 无 `permission_request`、authorization/capability/durable ticket 仍存在、automatic
  reviewer 其他路径不回归，以及 model-driven network/build 路径仍受原权限边界。
- 首次在受管沙箱中运行时，SwiftPM manifest 在源码编译前因
  `sandbox-exec: sandbox_apply: Operation not permitted` 失败；同一聚焦命令在允许 SwiftPM 自身
  sandbox 的宿主环境退出 0。未运行完整 `swift test`、macOS/iOS App build、真实文档 runtime、
  credential/network 或真实 reviewer provider smoke。

### 2026-08-21 `TranslatisMacAppStore` target 删除

- `project.yml` 不再声明 `TranslatisMacAppStore` target 或 scheme，唯一专属文件
  `Apps/TranslatisMac/TranslatisMac.AppStore.entitlements` 已删除；所有 Mac App 源码中的
  `TRANSLATIS_MAC_APP_STORE` 条件编译分支已删除并保留唯一 `.macDeveloperID`/workspace+global/
  Knowledge/managed-stdio 路径。`.macAppStore` 共享 profile 只保留协议解码与隔离测试兼容。
- `xcodegen generate` 退出 0。随后 `xcodebuild -project Translatis.xcodeproj -list` 的 App targets 精确为
  `TranslatisMac`、`TranslatisiOS`；`Translatis.xcodeproj/xcshareddata/xcschemes` 精确含
  `TranslatisMac.xcscheme` 与 `TranslatisiOS.xcscheme`，生成工程、Mac sources 和 entitlements 目录均不含
  `TranslatisMacAppStore`、`TRANSLATIS_MAC_APP_STORE` 或 `TranslatisMac.AppStore.entitlements`。
- `SDKClientOnlySurfaceTests` 3/3、0 failures；新断言验证单一 Mac App、Developer ID target 继续链接
  `IntatisMCP` + `IntatisMCPStdio`、iOS 两者都不链接，并验证 target/macro/entitlements 文件不存在。
  保留的 `.macAppStore` 协议/remote-only 兼容由 `IntatisCoreTests.testProfilePresets` 1/1 与
  `MCPPreparedConfigurationTests` 5/5 覆盖，合计 6/6、0 failures。
  `scripts/check-version-consistency.sh` 输出 `Intatis version is consistent: 0.55 (build 55)`。
- `TranslatisMac` macOS Debug unsigned build（`-disableAutomaticPackageResolution`、
  `ENABLE_DEBUG_DYLIB=NO`）退出 0；`TranslatisiOS` generic Simulator Debug unsigned build也退出 0。
  输出只有仓库既有 unused-result/`onChange` deprecation，以及旧临时 build output 引发的 stale-file
  warnings；没有 target/link/source 编译失败。本轮未运行整仓 `swift test`、universal Release、Developer
  ID 签名、公证、staple、Gatekeeper 或重新安装 `/Applications/Intatis.app`。

### 2026-08-21 macOS 跨 block 选区单一外观 corrective

- 用户提供的真实 Chat 截图暴露旧 mouse-up 路径仍有两套绘制：首个 leaf 保留 `NSTextView` native
  selection，后续 leaf 把 `controlAccentColor` / alternate selected foreground 写入 disposable
  `textStorage`；窗口或截图工具改变 focus 后，native selection 自动变浅而 projection 保持深蓝。
- 当前 `ParagraphNSView` 让 native selection 与 distributed projection 共用一份系统
  `selectedTextAttributes`。coordinator 在 mouse-up 后让所有 leaf 只显示这一个 projection；首个 leaf
  仍保留真实 selected range 以维持 AppKit responder、Edit → Copy 与 Command-C，但临时把 native
  selection attributes 置空，清除 selection 时恢复。没有新 overlay、renderer、依赖或 canonical 文本写入。
- `MarkdownDocumentSelectionCoordinatorTests` 14/14，新增断言逐 leaf background/foreground 与系统
  selection attributes 完全一致、只有 primary 保留真实 range、清除后 native attributes 与原 attributed
  projection 均恢复。完整 vendor 为 79 XCTest + 25 Swift Testing、0 failures；SharedUI
  `MessageRenderingTests` 42/42、`ThreadLayoutTests` 25/25，合计 67/67、0 failures。初次 strict Release
  test 暴露 test-only coordinator observation 被错误包在 `#if DEBUG`；改为 module-internal read-only 后，
  `-strict-concurrency=complete -warn-concurrency -warnings-as-errors` 的完整 Release suite 也以相同
  79 XCTest + 25 Swift Testing、0 failures 通过。
- normal `TranslatisMac` Debug（`ENABLE_DEBUG_DYLIB=NO`）和 unique-bundle code-selection fixture 均构建并以
  ad-hoc Hardened Runtime 签名通过。Computer Use 在 fixture 中真实拖拽正文→代码，并在 active/切换应用
  focus 后都看到一套浅蓝选区；Command-C 后以宿主 `pbpaste` 读回正文与 code prefix，换行、空行和缩进
  完整。随后在更新后的 `/Applications/Intatis.app` 中直接复现用户截图的“经常遇到这几个词”→
  Stride/Padding/Channel 场景，首段和三项列表已显示同一种选区颜色；验证后已清除临时选区。
- 最终安装仍为 `0.55 (55)` arm64 Debug、ad-hoc Hardened Runtime，main executable SHA-256
  `1fdc9785519fd41449431695849a029fc330b7f9ff3b898416f221fe913116c7`；staging/installed bundle
  `diff -qr` 无差异，strict codesign、audio-input=true、allow-jit=false、disable-library-validation=false、
  无 Debug dylib/quarantine 均通过。strict Release test observation 修正前的中间包保留在
  `~/.Trash/Intatis-selection-appearance-intermediate-20260821-121114.app`，executable SHA-256 为
  `65d0a80dff1ac904db31e077703a17c6dda122487a98540ab6a8f7a7560d3130`；实际带双重选区样式的旧包保留在
  `~/.Trash/Intatis-before-selection-appearance-20260821-120049.app`，其 executable SHA-256 仍为
  `659683ef665e8591bdfdfc5257179afba4548c6049c6e377c75ecd3671fc12e9`。本轮未重跑 iOS build（改动
  仅位于 `#if canImport(AppKit)`）、整仓 `swift test`、VoiceOver、Dark、
  Increase Contrast、modifier/double-click、跨消息、拖出 viewport autoscroll 或长 soak。

### 2026-08-20 macOS 单消息直接跨 block 选择

- `DocumentView` 现在在 macOS 为自己的 native TextKit leaves 注入一个
  `MarkdownDocumentSelectionCoordinator`。AppKit pan 只接普通无 modifier 的 primary-button drag；
  ordinary click、double/triple click、modifier selection、right-click 与 link 继续由 native AppKit
  处理。range order 使用稳定 registration，geometry 只负责命中 current leaf；table/code 的 macOS
  plain leaves 改用现有 `ParagraphView`，code 采用 unwrapped natural measurement，iOS 仍用原 SwiftUI
  leaf selection。Intatis macOS render config 的 `textSelectionConfig.isEnabled=false`，不再注入
  `Select more text` menu/modal。
- coordinator 专项 14/14、0 failures：覆盖 forward/reverse、多 paragraph、window point target、
  unequal-height table order、真实 DocumentView table row-major/list participation、same-row tab、combined
  pasteboard、TextKit 2 coordinator injection、unwrapped code、pan recognizer、transient system-accent
  emphasis、ordinary-click exact attributed restore、stream replacement cancel。
- vendor 完整 suite 为 79 XCTest + 25 Swift Testing、0 failures；vendor Release
  `-warnings-as-errors` build 通过。Intatis `MessageRenderingTests` 42/42 与 `ThreadLayoutTests` 25/25，
  合计 67/67；SwiftPM 全图 build、`TranslatisMac` normal Debug（`ENABLE_DEBUG_DYLIB=NO`）和
  `TranslatisiOS` generic Simulator Debug 均退出 0，仅有仓库既有 warnings。
- Computer Use 在 ad-hoc Hardened Runtime、unique bundle ID 的 code-selection fixture 中完成 heading →
  paragraph → code 正向拖拽和 code → heading 反向拖拽；mouse-up 截图中全部参与 leaf 为系统蓝色选区，
  无临时诊断标记。Command-C 后在宿主环境读取 general pasteboard，得到按文档顺序的 heading、paragraph
  与 code prefix，保留代码空行、换行与缩进。table fixture 先暴露 plain native leaf 的 unspecified
  measurement 零宽问题并在修复后实窗确认内容/网格完整；不等高 table 的 frame-order 漏 cell 问题随后
  改为 registration-order，并由真实 DocumentView host test 冻结。full-static fixture 实窗确认 heading、
  paragraph、quote、ordered/unordered/task lists 与 table 均使用正常 production layout；Computer Use
  对该独立窗口出现 `noWindowsAvailable`，未把 full-static 自动 drag 伪报为通过。
- 最终 `/Applications/Intatis.app` 为 `0.55 (55)` arm64 Debug、ad-hoc Hardened Runtime，main executable
  SHA-256 `659683ef665e8591bdfdfc5257179afba4548c6049c6e377c75ecd3671fc12e9`；strict codesign、
  audio-input=true、allow-jit=false、disable-library-validation=false、无 quarantine/Debug dylib均通过。
  更新前 footer build 保留在 `~/.Trash/Intatis-before-selection-20260820-231513.app`。安装后的真实 Chat
  自动 drag 因 Computer Use 只保留 process、连续返回 `noWindowsAvailable` 而未形成新证据；没有新增
  crash report。未运行整仓 `swift test`、跨消息选择、拖出 viewport autoscroll、modifier/double-click
  实际操作、VoiceOver、Light/Dark、Reduce Transparency/Increase Contrast 或 >160 秒 soak。

### 2026-08-20 macOS 逐回复复制与统计 footer

- `TurnStatsPayload` 以 optional `turnID` / `responseMessageID` 追加精确关联，旧 JSON 缺字段仍解码为
  nil；`ConversationProjection` / `CodeProjection` 支持 message-first 与 stats-first，并让 legacy unbound
  stats 只保留 latest session context。pending stats 是 presentation-only，最多保留 64 个未兑现 identity。
- `InferenceProfileProtocolTests` 4/4；组合 focused run 中 `ThreadLayoutTests` 25/25、
  `IntatisConversationCodeTests` + Chat stats + `SessionProjectionPumpTests` 32/32、Agent 多轮 usage 1/1，
  合计本轮直接相关 62 tests、
  0 failures。clipboard 测试使用 unique pasteboard，验证中文、Markdown、代码围栏、公式源文本与换行
  exact 保真；layout source-shape 冻结 icon-only copy、四项指标、三个 Mac composer Context-only 与 iOS
  full-usage 不变，并冻结 Chat/Code/Cowork 最后一行 stats identity 会进入 scroll signature。
- 完整受影响 target：`IntatisProtocolTests` 107/107、`IntatisConversationTests` 209/209、
  `IntatisAgentKernelTests` 221/221、`IntatisCoworkTests` 363/363，合计 900/900、0 failures。
  `IntatisSharedUITests` 本轮只运行直接相关 `ThreadLayoutTests` 25/25；未把仓库已知可能静默停滞的
  SharedUI async 全量 target 或整仓 suite 伪报为通过。
- SwiftPM 首次 focused run 完成完整受影响图 Debug 编译，随后独立 `swift build` 也退出 0。
  `TranslatisMac` macOS Debug unsigned build 在
  `-disableAutomaticPackageResolution` 与既有 resolved package cache 下退出 0；只有仓库既有 warning。
  一次全新 DerivedData 尝试在任何源码编译前因 GitHub EventSource clone 的 LibreSSL
  `SSL_ERROR_SYSCALL` 失败，不能记为产品源码失败。
- Computer Use 只读观察确认当前构建的 assistant footer 暴露 `Copy message` icon action，Mac composer
  只剩 Context。为了显示 synthetic 四项指标另构建了 Debug-only unique bundle fixture；Computer Use
  对该临时 bundle ID 无法可靠取得窗口并与已安装同名 App 混淆，因此四项 footer 的真实像素、窄宽、
  Light/Dark 与 VoiceOver 仍为 `UNKNOWN`，不能由 AX source-shape 或单元测试冒充通过。
- `TranslatisiOS` generic Simulator Debug unsigned build 也退出 0，证明 shared optional stats/projection 类型
  没有扩大 iOS linkage，且 iOS 继续使用完整 composer usage。未运行完整 `swift test`、真实
  provider/credential/network、正式签名、公证或发行打包；该 footer pass 当时未修改跨 block 选择，
  后续同日的上一节已单独实现并验证该能力。
- 本机安装 smoke 先暴露了 Xcode 27 Debug 产物的签名边界：默认 build 生成 launcher、
  `TranslatisMac.debug.dylib` 与 `__preview.dylib`；整个 bundle 以 ad-hoc Hardened Runtime 重新签名并通过
  `codesign --verify --deep --strict` 后，真实启动仍由 dyld 以 `Library not loaded` / non-platform
  Team ID mismatch 拒绝。没有把 `com.apple.security.cs.disable-library-validation` 改为 true；该中间
  App 已移到 `~/.Trash/Intatis-failed-debug-dylib-20260820-211318.app`。
- 随后运行同一 `TranslatisMac` Debug build，并显式设置 `ENABLE_DEBUG_DYLIB=NO`、
  `CODE_SIGNING_ALLOWED=NO` 与临时 `CONFIGURATION_BUILD_DIR`；`xcodebuild` 退出 0，最终 bundle 的
  `Contents/MacOS` 只含主可执行文件，`otool -L` 不再引用 `@rpath/TranslatisMac.debug.dylib`。该 bundle
  再以 `Apps/TranslatisMac/TranslatisMac.DeveloperID.entitlements` 做 ad-hoc `--options runtime` 签名，
  strict codesign 通过，runtime flag 为 `0x10002(adhoc,runtime)`，audio input=true、allow-jit=false、
  disable-library-validation=false，且无 quarantine xattr。
- 已验证 staging 与最终 `/Applications/Intatis.app` 的 bundle identifier 均为
  `com.Vita0818.TranslatisMac`、版本为 `0.55 (55)`、架构为 arm64、Debug dylib 不存在；最终主可执行文件
  SHA-256 为 `6e97d059e4c00b3662b35025a2e5396ba694100017d833e585cd883f0116b8a0`，CDHash 为
  `09baccf2552cabf1a08b3a1019572abd85eef804`。Computer Use 先从临时 bundle、再从 exact
  `/Applications/Intatis.app` 启动成功；最终 App 保持运行，accessibility state 可见 `Copy message`
  action 与 Context 控件。旧 `0.48 (48)` 安装位于
  `~/.Trash/Intatis-before-install-20260820-210656.app`，可恢复。该 smoke 是本机 arm64 Debug
  安装证据，不替代 universal Release、Developer ID、notarization、staple、Gatekeeper 或干净机器验收。

### JetBrains Mono 全局英文字体发布门槛

JetBrains Mono 是 macOS/iOS 第一方统一英文字体。Debug、Release 与发行构建都必须在普通、无参数
启动时使用同一条正式路径，不得存在 system-font opt-out 或实验参数。至少验证：

```sh
swift test --filter IntatisTypographyTests
swift test --filter 'MessageRenderingTests|ThreadLayoutTests|CoworkInferencePresentationTests'
swift test --package-path Vendor/SwiftStreamingMarkdown \
  --filter FirstReleaseContractTests
xcodegen generate
xcodebuild -quiet -project Translatis.xcodeproj -scheme TranslatisMac \
  -configuration Debug -destination 'platform=macOS' \
  COMPILER_INDEX_STORE_ENABLE=NO CODE_SIGNING_ALLOWED=NO build
xcodebuild -quiet -project Translatis.xcodeproj -scheme TranslatisiOS \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  COMPILER_INDEX_STORE_ENABLE=NO CODE_SIGNING_ALLOWED=NO build
```

还必须逐字节核对两端最终 App 中两个 TTF 和 OFL 的 SHA-256；无参数启动至少一个 macOS
fixture 与一个隔离 iOS Simulator，确认正式字体可见且进程不会因 registration/resource mismatch
退出。Core Text
probe 应分别观察英文使用 JetBrains Mono、中文使用系统 CJK fallback。source scan 必须证明第一方
production SwiftUI 的 direct `.font(.system/semantic...)` 已进入 product typography seam；vendor code block
只能读取现有 `MarkdownRenderConfig`，默认配置行为不变。

正式 release 须核对 exact dependency closure；Simulator/fixture 不能替代 Dark、超大 Dynamic Type、VoiceOver、
真实长中英混排、系统 sheet/menu/control、真机和正式签名/公证验证。

2026-08-19 当前直接证据：

- 官方 v2.304 两份 TTF、OFL 与仓库/两端 Debug App bundle 的 SHA-256 分别一致为
  `662a196d...cac016`、`f115aaa1...63f2`、`30f0c136...ac4ad`；最终两个 bundle 均为 `0.55 (55)`；
- 两份 TTF 已收口到 `IntatisSharedUI` 的 `Bundle.module`；四个 App 各自只含一个
  `Intatis_IntatisSharedUI.bundle` 和 exactly 2 个 JetBrains TTF，没有残留 App-root duplicate；
- `IntatisTypographyTests` 在 Debug 与 Release 配置各 2/2；测试冻结 JetBrains Mono 为每个共享
  typography role 的正式 design；
  Debug 下与 `MessageRenderingTests` 41、`ThreadLayoutTests` 22、
  `CoworkInferencePresentationTests` 8 合计 73/73、0 failures；vendored Markdown 完整 suite 为
  79 XCTest + 11 Swift Testing、0 failures；
- macOS/iOS Debug 与 Release unsigned build 均退出 0，只报告仓库既有 warnings；Release macOS
  executable 为 `x86_64 arm64`，四个最终 App 均为 `0.55 (55)`，Release bundles 的两份 TTF/OFL
  hash 也与仓库一致；四个 build 已在正式字体接线后重新执行；
- 当前 iPhone 17 Pro 隔离 Simulator 已在**没有任何字体参数**时启动成功，`New chat`、model label 与
  composer placeholder 均显示 JetBrains Mono；macOS Renderer Fixture 也在没有字体参数时启动并
  稳定存活；
- Core Text run probe 报告英文为 `JetBrainsMono-Regular`、中文为 `PingFangSC-Regular`；
- 尚未完成 Dark、超大 Dynamic Type、VoiceOver、真实长中英混排、系统 sheet/menu/control、真机、
  正式签名/公证；因此本条是字体接线证据，不是整个 v0.55 release GO。

2026-08-19 iOS large title 收窄的直接证据：

- `IOSRootView` 的当前 session 与 Settings 标题继续使用 JetBrains Mono large-title role 和
  `@ScaledMetric(relativeTo: .largeTitle)`，但 iOS-only nominal size 从共享 30pt 收窄为 22pt；
  抽屉品牌字号、共享 `IntatisTypography` 事实源和 macOS 标题均未修改；
- `IntatisTypographyTests` 1/1、0 failures，确认共享 `.largeTitle` 仍为 30pt；
- `TranslatisiOS` generic Simulator Debug unsigned build 退出 0，最终 bundle 为 `0.55 (55)`，只出现
  仓库既有 unused-result / deprecated `onChange` warnings；
- 新构建已安装并启动于 iPhone 17 Pro Simulator。Light 主界面截图确认 `New chat` 标题在 64pt
  header 内保持居中、无截断且未挤压两侧 sidebar/New 按钮，底部 composer 几何未变化；Settings
  使用同一 22pt override。未运行完整 SwiftPM suite、Dark、超大 Dynamic Type、VoiceOver 或真机矩阵。

2026-08-19 iOS Chat 键盘 dismissal 修复的直接证据：

- `IntatisThreadComposer` 的 Send 按钮与键盘提交改为共用同一个 guarded `submit()`；iOS 在调用
  `ChatViewModel.send()` 前先把本地 FocusState 设为 `false`，macOS 条件分支不改变既有焦点行为；
- shared Chat 消息 `ScrollView` 只在 iOS 增加 `.scrollDismissesKeyboard(.interactively)`，模型输出、
  自动滚动与输入重新启用不再拥有重新聚焦入口；
- `ThreadLayoutTests` 22/22、0 failures，新增 source-shape 回归同时冻结 Send/Return 两条提交路径、
  iOS-only FocusState 清理和 interactive scroll dismissal；
- `TranslatisiOS` generic Simulator Debug unsigned build 退出 0，最终 bundle 为 `0.55 (55)`，只出现仓库
  既有 unused-result / deprecated `onChange` warnings；隔离的临时 iPhone 17 Pro Simulator 已成功启动
  当前 App，且未读取或使用真实 provider 配置；
- 当前 Computer Use 服务不能识别 Xcode Simulator，已安装的 `simctl io` 也不提供 touch/HID 注入，
  因此没有把真实 Send 后键盘动画或消息区下拉手势伪报为自动化通过；这两项仍需人工点按确认。

2026-08-11 本机 LibreOffice 26.8 替换与旧 v4 链路历史证据（2026-08-23 v5 后不能作为当前
exact-tool acceptance）：

- 官方 `LibreOfficeDev_26.8.0.0.beta1_MacOS_aarch64.dmg` 为 298,129,546 bytes，SHA-256
  `a56a5af102c78c294b3da48154958ecd9fa52d357589305c54e6e215ce611900`；`hdiutil verify` 和官方
  detached PGP signature 均通过。CLI exact 输出为 `LibreOfficeDev 26.8.0.0.beta1`，固定后端只解析
  `~/Library/Application Support/Intatis/document-runtime/libreoffice/26.8.0.0.beta1/LibreOffice.app`；
- 在不受 Codex 外层 sandbox 干扰的宿主环境，DMG 原件、替换前 staging 和最终固定路径均通过
  `codesign --verify --deep --strict`；签名者为 The Document Foundation Developer ID（Team ID
  `7P5S3ZLCN7`），`spctl --assess --type execute --verbose=4` 返回 `accepted` / `Notarized Developer ID`。
  早先在外层受限环境得到的 Code Signing subsystem internal error 不能作为宿主签名失败证据；
- 一次无 Intatis Seatbelt 的诊断运行确实让内置 Python 改写了签名包内的 `__pycache__/*.pyc`，随后
  `codesign` 正确报告 sealed resource modified。该副本已移入废纸篓，并从仍为只读、已验签的官方
  DMG 重新复制；这与前述外层 sandbox 假阴性是两个不同事件；
- 根因最终收敛为 LibreOffice SingleOffice IPC。`OSL_SOCKET_PATH` 是 LibreOffice bootstrap 值，
  必须以 `-env:OSL_SOCKET_PATH=...` 传入；旧实现只设置普通 process environment，因此无效。长 Darwin
  temp root 还会在 LibreOffice 追加 `OSL_PIPE_*` 后超过 `sockaddr_un.sun_path`，在 `socket()` 前就返回
  `BE_PATHINFO_MISSING`；
- fixed runner 现为每次调用创建 `/private/tmp/intatis-lo-<12 hex>`，创建后以 `lstat` 证明它是
  current-UID、非 symlink、`0700` 目录。Seatbelt 只允许该 root 的文件读写、本地 `OSL_PIPE_*`
  Unix socket bind/connect，并继续拒绝 IP 网络和其他 Unix socket；调用结束清理 exact root。对应
  profile 单元测试 1/1、`DocumentFixedBackendsTests` 4/4；
- `INTATIS_REAL_DOCUMENT_RUNTIME_SMOKE=1 swift test --filter DocumentToolsIntegrationTests/testInstalledDocumentRuntimeCoreToolChainWhenEnabled`
  在干净副本上 1/1：
  DOCX write/read/preview/export/PDF read/render；PPTX write/read/preview/export/PDF read；XLSX write、
  LibreOffice Calc round-trip、公式文本保留、data-only cache 值 `4`、preview/export。真实测试后再次
  `codesign --verify --deep --strict` 与 `spctl`，结果仍为 valid/accepted，证明 Intatis 路径没有修改
  App 签名资源。旧 26.2.4 runtime 已按用户授权移入废纸篓；
- 当前用户 runtime 的旧 smoke 只证明当时这台开发机，不代表 App bundle、双架构、NOTICE、许可证或
  clean-machine distribution closure。EPUB write/EPUBCheck、pdfcpu、preview/recalc/verifier 路径已从
  v5 删除，其旧通过结果不再是当前产品验收证据；当前 OCR/exports/writes 必须按上面的 v5 opt-in
  tests 与新 release roots 重新证明。

2026-08-11 model-driven Knowledge 实现与 live acceptance 证据：

- `IntatisKnowledgeTests.xctest` 118 tests / 0 failures；当前宿主 local-core corpus 指标为
  Recall@1 0.529、Recall@5 0.882、MRR 0.681、nDCG@5 0.698、citation coverage 0.882、citation
  precision 1.000，最近一次离线 Knowledge run 的 deterministic search proxy 200 次平均 1.640 ms；
  这些不是 semantic reranker uplift 报告；
- `KnowledgeModelProviderTests` 11/11、`ToolSpecMetadataTests` 5/5、`CLIProviderAdapterTests` 9/9、
  `ModelDrivenKnowledgeAgentLoopTests` 2/2、`TurnGroundingEvidenceRegistryTests` 7/7、
  `ToolRegistryLeaseTests` 25/25、SecretScanner 精确回归 1/1、checked drain 1/1。
  AgentLoop 用两个 exact external store 跑通 2 build + 2 search，4 个
  prepared/settled correlation 一致，两次 search 均为 `rerank_applied=true`，两个 citation 通过
  current-turn revalidation；随后 fresh host generation 重新打开其中一个 durable external store 并完成
  第三次 query embedding/semantic rerank/citation，最终 query/reranker 各调用 3 次、external scope
  acquire/release 5/5；
- 普通 file mutation 与实际 Seatbelt managed terminal anti-bypass 定向通过；legacy snapshot layout
  writer-only atomic migration、read-only no-mutation、pointer `commitUncertain`、provider route identity/
  redirect/malformed/timeout/cancel/credential failure 均通过；official-shaped provider fixture 还验证了
  embedding token 与 reranker token/billable-search-unit 解析，build descriptor 保持 `.write` 且
  network/model-cost 风险独立存在；
- `TRANSLATIS_REAL_KNOWLEDGE_SMOKE=1` 已使用 OpenRouter exact routes 运行 1/1、0 failures（3.447 秒）：
  `google/gemini-embedding-2` 返回并通过 1536 维校验，provider usage 为 input/total token 7；
  `cohere/rerank-4-pro` 返回完整两候选 permutation、有限 score，provider usage 为 search unit 1；
- `TRANSLATIS_REAL_KNOWLEDGE_QUALITY=1` 运行 1/1、0 failures：冻结 8-query 中英/代码集合的 dense
  embedding baseline 为 MRR 1.000、nDCG@5 1.000、Recall@5 1.000；configured semantic reranker 为
  MRR 1.000、nDCG@5 0.990、Recall@5 1.000。embedding usage 为 343 token，reranker usage 为 8
  search units。该结果证明 100% configured-rerank 调用和独立指标报告，但没有证明 uplift，nDCG@5
  回退 0.010，不能改写成推荐模型优于 baseline；
- `TRANSLATIS_REAL_KNOWLEDGE_AGENT_E2E=1` 运行 1/1、0 failures（32.686 秒）：真实 Agent 调用了
  `list_files` / `read_file` / `write_file` / `build_knowledge` / `search_knowledge`，在隔离外部 store
  完成 read-organize-build-search-cite，最终回答含通过 current-turn revalidation 的 exact evidence ID；
- `TRANSLATIS_REAL_KNOWLEDGE_PDF_E2E=1` 以项目根目录 `test-DS-Algorithm` 为 source 运行 1/1、0 failures
  （110.980 秒）。harness 只复制并读取 `DPV-chap2.pdf` 6–7 页、`DPV-chap4.pdf` 5–7 页、
  `DPV-chap6.pdf` 1–5 页；Agent 实际调用三次 `read_pdf`，写出 3 个 grounded concept，build 生成
  22 chunks，再用 configured query embedding 与 required reranker 搜索并在覆盖 mergesort、Dijkstra、
  LIS 的最终答案中引用 exact evidence。原始 PDF 未修改；
- macOS Debug App 通过 Computer Use 执行真实 Code 交互：用户自然语言给出 workspace 外 exact path 后，
  首次 `search_knowledge` 显示 NSOpenPanel 并只授权该目录，保存 session-owned binary
  `knowledge-access.plist`（mode `0600`、schema 1、revision 1）。退出应用、重新启动、恢复同一 Code
  session 后再次搜索没有出现授权面板，证明 bookmark restore；测试目录为空，因此两次均按设计返回
  typed `KB_INDEX_NOT_READY` 且未写文件；
- 工作区沙箱外精确运行
  `TerminalToolsTests.testManagedTerminalCannotMutateKnowledgePublicationWithEmptyDenyList` 1/1、0 failures，
  证明实际 Seatbelt managed terminal 不能绕过 Knowledge publication deny floor。默认 skipped 的其它
  real provider/browser/Git/document/Keychain 用例不计为真实环境通过；
- `TranslatisMac` macOS Debug 与 `TranslatisiOS` generic Simulator Debug unsigned build均退出 0；Mac 只出现
  仓内既有 warning，未构建 legacy `TranslatisMacAppStore`。本轮整仓 `swift test` 已完成 Tools 与 Skills，
  随后 `IntatisSharedUITests.xctest` 进程持续约 7 分钟 0% CPU 且无新输出，复现既有 async scheduler
  挂起后人工中断，命令退出 130；不得记为整仓全绿，也没有观察到本任务相关 failure。本段所列
  Knowledge/Provider/Agent/Cowork/Permission/terminal 定向 suites 均独立退出 0。账单金额因 provider
  未返回 versioned monetary amount 而不推算。

2026-08-09 OKF / RAG knowledge bundle 本地 core 的直接证据：

- 最终 root run 的 `IntatisKnowledgeTests.xctest`：106 tests / 0 failures / 0 unexpected / 0 skips，
  7.224 秒（wall 7.230 秒）；其中 focused Build/Search/SourceLocator 为 52/52，新增 diagnostic
  init/decode 脱敏回归 1/1；
- 冻结 corpus：Recall@1 0.529、Recall@5 0.882、MRR 0.681、nDCG@5 0.698、citation coverage
  0.882、citation precision 1.000、unanswerable lexical TNR 3/3；deterministic dense+BM25 proxy
  200 次总计 324.994 ms、平均 1.625 ms，serialized index 30,941 B、memory proxy 103,230 B；
- `TurnGroundingEvidenceRegistryTests` 6/6；Cowork local `search_knowledge` durable probe 1/1，证明
  permission request/resolved → prepared → bounded structured tool result → settled → current-turn final
  citation revalidation → close/drain；narrow-mailbox negative 1/1；
- host exact authority/current snapshot/cancel-drain 1/1，concrete search + source-locator + final-grounding
  purge 1/1；本地 dynamic registration intent、DeterministicPolicyGate reviewer boundary 和
  date-only stale UTC boundary各自定向通过；
- `TranslatisMac` unsigned Debug arm64 build 通过；`IntatisKnowledge` / `TranslatisCLI` arm64 与 x86_64
  cross-build 通过。x86_64 只证明编译；Intel 真机、最低支持 macOS、large corpus、真实 remote
  embedding/reranker、hybrid/reranker comparative uplift、签名/公证仍为 `UNKNOWN`；
- urgent purge 的 current-pointer removal 是持久 admission boundary，receipt tombstone 阻止旧回执并发
  复活；它不是 pointer/receipt/physical delete 的跨组件 crash-atomic 事务，也不等于 secure erase。

2026-08-10 Agent durable多模态上下文最小闭环的直接证据：

- `DurableOwnerOnlyFileTests` 2 tests、`ArtifactImageResolverTests` 10 tests、
  `IntatisProvidersToolCallingTests` 36 tests、`AgentToolOutputLoweringTests` 6 tests、
  `DurableMultimodalAgentLoopTests` 9 tests、`CLIAttachmentTests` 4 tests，均为0 failures；
- `ModelHistoryMediaBatchEventLogTests` 7 tests、`SubmittedIntentStoreTests` 13 tests，均为0 failures；前者
  覆盖same-turn/call result与完整settlement identity，后者覆盖Retry planner和outbox payload保真；
- `swift test --filter ModelHistory`覆盖Protocol 14、Conversation 17、AgentKernel 49，共80 tests / 0
  failures；验证v2 direct/checkpoint、append-return binding、原call FCO、active-window summarizer与
  summary-only checkpoint；
- `ComposerAttachmentTests` 2 tests / 0 failures；验证PNG/JPEG扩展到canonical MIME的确定性映射、
  exact bytes读回与非图片typed拒绝。`testChatLoopPersistsAndRehydratesImageAttachmentsAcrossTurns`
  1 test / 0 failures，验证既有Chat跨轮图片持久化未回归；
- 从`v0.41` exact commit `e5f64ed`归档源码并临时编译旧reader fixture：3 tests / 0 failures；旧
  projector拒绝schema-v2 direct item及v1 checkpoint后的schema-v2 direct suffix，旧protocol拒绝
  schema-v2 checkpoint；
- `swift build --disable-sandbox --target TranslatisCLI`退出0；`TranslatisMac` macOS Debug和`TranslatisiOS`
  generic Simulator Debug unsigned build均退出0，只有仓库既有unused-result/deprecation warning；
- 真实端点smoke的opt-in测试壳已编入当前`TranslatisCLITests`；未设置开关时必须skip且不发请求，真实
  credential/network调用仍未执行；
- 当前完整`swift test --disable-sandbox`已成功构建全部targets，并先完成Tools 209 tests（15 skipped）
  与Skills 29 tests、均0 failures；随后在既有SharedUI
  `MarkdownSchedulerTests.testCancelAllDoesNotReleaseSynchronousWorkBeforeFinish`等待超过3分钟。采样显示
  XCTest停在async expectation且无继续工作的worker，因此人工中断，命令退出130。没有观察到多模态
  failure，但完整suite不能据此宣称全绿；本轮未越界修改该无关hang；
- `CLIAttachmentTests`除2个附件loader用例外，还直接覆盖CLI Code复用同一session log/ArtifactStore的
  next-turn，以及CLI Cowork销毁并重建shipping `Orchestrator.runtime`、EventLog与ArtifactStore后的exact
  `@main`图片replay；当前工作树直接运行4 tests / 0 failures；
- 未执行真实OpenAI credential/network smoke；线上多模态FCO仍是release-only外部门，不能从scripted
  provider外推。未重放当时实际分发的旧App制品，但已用exact旧源码编译fixture覆盖reader语义；
  `git diff --check`通过。

2026-08-11 `v0.48 (48)` 版本推进、shipping target 构建与本机开发安装的直接证据：

- `xcodegen generate` 通过；`scripts/check-version-consistency.sh` 通过并输出
  `Intatis version is consistent: 0.48 (build 48)`；
- `TranslatisMac` unsigned universal Release 构建退出 0，最终 bundle 为 `0.48 (48)`，bundle
  identifier 为 `com.Vita0818.TranslatisMac`，可执行文件包含 `x86_64 arm64`；
- `TranslatisiOS` generic Simulator Debug unsigned 构建退出 0，最终 bundle 为 `0.48 (48)`；
  两个构建只报告仓库既有 unused-result / deprecated API warnings；
- staging App 使用 `TranslatisMac.DeveloperID.entitlements` 完成 ad-hoc Hardened Runtime 签名；
  embedded entitlements 为 audio input=true、JIT=false、library validation 未关闭，
  `codesign --verify --deep --strict` 通过；
- `/Applications/Intatis.app` 已原子替换为上述 `0.48 (48)` 构建，版本、bundle identifier、
  双架构、entitlements 和可执行文件 SHA-256 均与 staging 副本一致，且无 quarantine
  xattr。安装前的 `0.40 (40)` 保留在
  `~/.Trash/Intatis-before-install-20260811-201644.app` 作为可恢复备份；
- 本轮版本/安装没有再跑 SwiftPM 测试；同一业务工作树在版本变更前已有 focused
  154/154、完整 SwiftPM 退出 0、Cowork 362/362 和 AgentKernel 210/210 证据。本轮未运行
  Developer ID 正式签名、公证、staple、Gatekeeper、DMG/ZIP 打包或启动后 UI/真实 provider
  smoke，因此这是本机开发安装证据，不是正式 release 证据。

2026-08-08 `v0.40 (40)` 版本推进、shipping target 构建与本机开发安装的直接证据：

- `xcodegen generate` 通过；`scripts/check-version-consistency.sh` 通过并输出
  `Intatis version is consistent: 0.40 (build 40)`；
- `TranslatisMac` unsigned universal Release 构建退出 0，最终 bundle 为 `0.40 (40)`，bundle
  identifier 为 `com.Vita0818.TranslatisMac`，可执行文件包含 `x86_64 arm64`；
- `TranslatisiOS` generic Simulator Debug unsigned build 退出 0，最终 bundle 为 `0.40 (40)`；
  两个构建只报告仓库既有的 unused-result / deprecated `onChange` warning；
- 安装前使用 `TranslatisMac.DeveloperID.entitlements` 对 staging App 完成 ad-hoc Hardened Runtime
  签名；读回 microphone input=true、JIT=false、library validation 未关闭且无 App Sandbox，
  `codesign --verify --deep --strict` 通过；
- `/Applications/Intatis.app` 已安装上述 `0.40 (40)` 开发构建，无 quarantine xattr；安装后
  可执行文件与 staging 副本的 SHA-256 均为
  `617c5b50a5e20e580c0a5a7d2059bc2337b19e92de66dd0779f8ada2d5a44cbe`。安装前的
  `0.36 (36)` 曾移至
  `/Users/vita/.Trash/Intatis-before-install-20260808-163949.app`，随后已按用户要求永久删除；
  精确路径检查为 absent，Finder 复核废纸篓中名称含 `Intatis` 的项目数为 0；
- 本轮没有重跑 SwiftPM 单元测试，也没有启动 App 做 UI/真实 provider smoke；紧随其后的
  Cowork permission authorization context 完整测试证据覆盖同一业务源码。未运行 Developer ID
  正式签名、公证、staple、Gatekeeper 或 DMG/ZIP 打包，因此这是本机开发安装证据，不是正式
  release 证据。

> 以下 2026-08-08 与“authorization reporter 结构化交接”条目仅是 v0.47 历史验证记录；
> Reporter 测试/真实 output-function smoke 已被 2026-08-11 same-call sidecar 流程替代，不能作为
> 当前可运行 gate。当前 gate 见本文件顶部命令和后续 2026-08-11 sidecar 验证条目。

2026-08-12 Cowork same-call permission sidecar corrective focused 直接证据：

- `PermissionReviewControlPlaneTests`：47/47；覆盖完整 transient args/string sidecar + mechanical host facts、
  objective/role/deliverable/userGoal/user/assistant/history/PDF marker 不进入 live prompt、delimiter injection、
  secret input、live/cache/recovery invocation 复验、recovered allow 拒绝、dedicated host admission、伪造
  agentAdmission kind 拒绝、固定 reviewer reason/provider diagnostic 与 durable non-echo；
- `AgentLoopPolicyTests`：37/37；覆盖 ask-only sidecar enforcement、manual reserved-key 拒绝、safe structured
  read failure 继续 batch、fresh-review fuse、in-engine reviewer 误配 fail closed，以及 automatic Cowork
  `tool_search` output 只在下一轮 provider request copy 中装饰；
- `AutomaticPermissionReviewTests`：35/35；覆盖 production Orchestrator/control-plane 接线、provider-required string schema、
  missing → missing → valid 的相同 business args 不触发 permission lifecycle/reviewer fuse、valid sidecar 只留
  current-turn live history、automatic attach 专用入口、allow/deny/cancel/failure 和 Reporter 不再 dispatch；
- `DurableMultimodalAgentLoopTests`：9/9；覆盖 user/FCO image 不再 blanket deny、sidecar 摘要媒体证据、
  raw sidecar 不进入 durable history，以及 missing sidecar 不伪造可跨重启恢复的权限拒绝；
- `AuthorizationSidecarTests`：12/12；`IntatisPermissionReviewerTests`：10/10；
  `PermissionReviewProtocolTests`：12/12；分别覆盖 schema decoration/extraction/binding、strict 发网前
  recursive fail-fast、deferred tool request-copy/durable isolation、plain-text verdict 与
  legacy/additive receipt wire；
- 以上合计 162 tests / 0 failures。strict-schema correction 还单独通过 `SearchKnowledgeToolTests` 4/4，
  并在 `AuthorizationSidecarTests` 中抓取 OpenRouter 与 OpenAI-compatible 最终 HTTP body 验证 wire invariant。
  `ModelHistoryCompactionAgentLoopTests` 另覆盖 deferred schema 对压缩阈值、compactor request 与 durable raw output
  的影响。`swift build --disable-automatic-resolution` 通过；受影响目标完整结果为 `IntatisAgentKernelTests` 217/217、
  `IntatisKnowledgeTests` 118/118、`IntatisCoworkTests` 364/364、`TranslatisCLITests` 45/45（8 skipped）。
  `TranslatisMac` macOS Debug、`CODE_SIGNING_ALLOWED=NO` 构建通过，只出现仓库既有 warnings。完整
  `swift test --disable-automatic-resolution` 完成 Tools 223/223（19 skipped）后挂于仓库既有 SharedUI async
  waiter，连续两分钟无输出后人工中断为 130，不能记为本次全量通过。opt-in 真实 provider sidecar smoke
  成功编译但因未设置计费开关而按设计跳过；本次未运行 UI/manual switch smoke，因此线上 route
  compliance、token、latency 与交互仍未证明；route-derived input ceiling 与
  `review_input_too_large` 仍未实现。

2026-08-08 Cowork automatic permission authorization context 修复的历史直接证据：

- `PermissionReviewProtocolTests`：11 tests / 0 failures；验证 additive optional wrapper、旧事件
  缺字段解码，以及协议没有增加 model-supplied author/latest-user/digest；
- `PermissionAuthorizationContextReporterTests`：7 tests / 0 failures；覆盖 `continue` 语义、同一
  acting provider/model 的 exact request prefix、`tools: []`、canonical evidence closure、worker
  scope 隔离、unknown handle、secret-bearing output、completion marker、timeout、caller cancel 与
  request-owned stream termination；
- `AutomaticPermissionReviewTests`：31 tests / 0 failures；`PermissionReviewControlPlaneTests`：
  40 tests / 0 failures；覆盖合法 report 与 canonical EventLog 原文分栏、缺失/malformed context、
  omitted intervening revocation、unknown future event、每个 tool call 独立 report、hard deny 不调用
  reporter，以及 reviewer provider 前的 typed durable deny；
- `testCancelAllDrainsDataPlaneBeforeShuttingDownPermissionReviewer`：1 test / 0 failures；确认 session
  cancel 会 drain 原始 inference、request-owned report 与 reviewer，不会释放 denial 后继续第三次
  inference 或执行文件写入；完整 `IntatisCoworkTests`：346 tests / 0 failures；
- managed sandbox 中第一次完整 `swift test --disable-sandbox` 因外层 Seatbelt 拒绝既有 browser/
  LaTeX/Git/process 子进程启动而失败；在允许真实子进程边界的宿主环境用同一 working tree 重跑后，
  14 个 XCTest target 合计 1727 tests / 19 conditional skips / 0 failures。`swift build
  --disable-sandbox` 与 `git diff --check` 均通过；
- 本次未修改 App/UI、Xcode 工程或平台 target，因此未另跑 macOS/iOS App build；未执行真实
  provider/credential/network smoke，不能从 scripted provider 测试外推线上模型质量。

2026-08-11 authorization reporter 结构化交接修补的历史直接证据：

- `PermissionAuthorizationContextReporterTests`：7 tests / 0 failures；验证唯一 output-only function
  schema、单 call/无 prose、strict host parse、canonical evidence closure，以及异常输出 fail closed；
- `PermissionReviewProtocolTests`：11 tests / 0 failures；`PermissionReviewControlPlaneTests`：
  40 tests / 0 failures；`AutomaticPermissionReviewTests`：32 tests / 0 failures；新增同一 assistant batch
  两个 ask-class 写操作分别报告、分别审查并分别执行的集成覆盖；
- 在用户明确允许真实网络、计费及向 OpenRouter 发送测试内容后，当前 exact Agent route 运行
  `testRealAgentOutputFunctionShapeWhenEnabled`：1 test / 0 failures，普通单 function request 成功返回
  一个同名结构化 call。探索过程中 forced `tool_choice` 与 `response_format` 均被该 exact route 的上游
  参数兼容性检查拒绝，因此生产合同不依赖这两个可选参数；
- `TranslatisMac` Debug、`CODE_SIGNING_ALLOWED=NO` 构建通过；仅出现既有 unused-result 与 SwiftUI
  deprecation warnings；
- 本节是对 2026-08-08 `tools: []` 报告器测试证据的后续修正，不改变 reviewer 自身无工具判决请求。

2026-08-08 Cowork current-run 终态控制与 correlation-scoped mailbox 修复的直接证据：

- 新增 `finish_run` / `stop_run`、host-bound RunController、`continuation_run_close_requested`
  first-write claim、in-flight admission/authorization tombstone、restore/drain fence，以及 information
  request/reply 的 `conversationID` / `basedOn` 协议和 authority-class 窄租约；普通 message/reply
  receipt 均不 ACK，实质追问使用 fresh RequestID；
- run control、mailbox correlation、协议 round-trip、EventLog CAS/projection、tool registry/legacy lease
  migration、prompt、bundled Skill、permission 与 non-replayable mailbox side-effect focused tests 均通过；
  完整 `IntatisCoworkTests` 为 341 tests / 0 failures；完整 `swift test` 退出 0，其中
  `IntatisAgentKernelTests` 175 tests、`IntatisSharedUITests` 141 tests，所有已运行 target 均为
  0 failures；
- `cowork-agent-orchestration` 通过仓内 `quick_validate.py`；`xcodegen generate` 通过；
  `scripts/check-version-consistency.sh` 输出 `Intatis version is consistent: 0.38 (build 38)`；
- `TranslatisMac` macOS Debug unsigned build 与 `TranslatisiOS` generic Simulator Debug unsigned build
  均退出 0；读回两个最终 bundle 均为 `0.38 (38)`。构建只报告仓库既有的 unused-result /
  deprecated `onChange` warning；
- 按 `computer-use` Skill 通过 Sky 分别尝试按刚构建 App 的绝对路径、bundle ID 启动，并尝试列举
  apps；所有调用都在服务启动层返回 `Sky Computer Use service startup request failed`，因此本轮没有把 UI 启动、真实 provider
  自主调用工具或长时多 agent 会话标为已验证。未安装 App，未运行 Developer ID 正式签名、
  公证、staple、Gatekeeper 或 DMG/ZIP 打包。

2026-08-07 `v0.38 (38)` 版本推进的直接证据：

- `xcodegen generate` 通过；`scripts/check-version-consistency.sh` 通过并输出
  `Intatis version is consistent: 0.38 (build 38)`；
- `TranslatisMac` unsigned universal Release 构建退出码为 0，最终 bundle 为 `0.38 (38)`，
  可执行文件包含 `x86_64 arm64`；
- `TranslatisiOS` generic Simulator Debug unsigned build 退出码为 0，最终 bundle 为
  `0.38 (38)`；两个构建只报告仓库既有的 unused-result / deprecated `onChange` warning；
- 本轮是版本元数据与当前文档变更，未运行 SwiftPM 单元测试；未安装 v0.38 App，
  `/Applications/Intatis.app` 读回仍为 `0.36 (36)`。也未运行 Developer ID 正式签名、
  公证、staple、Gatekeeper 或 DMG/ZIP 打包。

2026-08-07 Cowork terminal/mailbox reconciliation 修复的直接证据：

- 报告要求的 TaskContract、AgentLoop policy、model history、context projection、CodeProjection、
  MessageBus/delegation、orchestration reliability、WorkTask runtime 与 permission reviewer focused
  tests 均通过；完整 `swift test --skip-build` 最终退出 0，其中 `IntatisCoworkTests` 327 tests、
  `IntatisSharedUITests` 141 tests、`IntatisAgentKernelTests` 175 tests，均为 0 failures。真实
  Git/browser/Keychain 等显式 opt-in host smoke 仍按设计 skipped；
- `xcodegen generate` 与 `scripts/check-version-consistency.sh` 通过，版本一致为 `0.36 (36)`；
  `TranslatisMac` macOS Debug、`TranslatisiOS` generic Simulator Debug unsigned build 均退出 0；
- `TranslatisMac` unsigned universal Release 通过；最终 bundle identifier 为
  `com.Vita0818.TranslatisMac`，可执行文件包含 `x86_64 arm64`。临时 staging App 使用仓库
  Developer ID entitlements 完成 ad-hoc Hardened Runtime 签名，embedded entitlements 为
  audio input=true、JIT=false、library validation 未关闭，`codesign --verify --deep --strict`
  通过；
- `/Applications/Intatis.app` 已替换为该构建，版本、bundle identifier、架构和可执行文件
  SHA-256 均与 staging 产物一致，且没有 `com.apple.quarantine` xattr。旧安装保存在废纸篓
  `Intatis-before-install-20260807-1627.app`，可恢复；新进程的实际可执行路径已核对为
  `/Applications/Intatis.app/Contents/MacOS/TranslatisMac`；
- 对截图对应的 `cowork_rqx6cgvb` 事故日志做了只读回放审计：仍为连续 `seq 0...4564`
  （4565 行），冷启动后 mtime 仍为 `2026-08-07 13:09:04 +0800`，没有自动 provider 重跑或
  追加事件。事故链保留 `seq 2873 message_completed`、`2874 model_history_item`、
  `2878 failed turn_outcome`、`2879 task_failed`；新增 projection/history 回归证明前两项会被
  后续 authoritative failure 分别标为未完成和从 provider history 排除；
- 推荐的 Computer Use 已按 skill 通过 `node_repl + @oai/sky` 多次尝试（含 kernel reset 和
  app path/bundle ID 两种目标），均在 Computer Use service startup 阶段失败。fallback
  `screencapture` 被 Screen Recording 拒绝，System Events 也被 Apple Events 权限拒绝，因此本轮
  **没有把失败卡片的真实窗口像素/AX 文本冒充为已验证**；只确认安装包成功启动、进程路径正确、
  冷启动未改写事故日志。此限制不影响上述单元、全量、构建、签名与持久化证据，但运行时视觉
  卡片仍需在具备 Computer Use/Screen Recording 权限的环境补做。

本轮没有运行 Developer ID 正式签名、公证、staple、Gatekeeper 或 DMG/ZIP 打包；以上是本机
开发安装证据，不是正式 release 证据。遗留 `TranslatisMacAppStore` 未构建。

2026-08-07 v0.36 阶段未提交工作树 macOS 本机开发安装的直接证据：

- `xcodegen generate` 与 `scripts/check-version-consistency.sh`：通过，版本一致为 `0.36 (36)`；
- `TranslatisMac` unsigned universal Release：通过；最终 bundle identifier 为
  `com.Vita0818.TranslatisMac`，可执行文件包含 `x86_64 arm64`；
- 使用仓库 Developer ID entitlements 对临时 App 完成 ad-hoc Hardened Runtime 签名；embedded
  entitlements 已读回 microphone input=true、JIT=false、library validation 未关闭，
  `codesign --verify --deep --strict` 通过；
- `/Applications/Intatis.app` 已替换为上述当前工作树构建，版本仍为 `0.36 (36)`，无 quarantine
  xattr；安装后可执行文件与临时验证产物的 SHA-256 一致。旧的同版本 App 已以 timestamped
  `Intatis-before-install-*.app` 移入废纸篓作为可恢复备份；
- 本轮没有运行 Developer ID 正式签名、公证、staple、Gatekeeper 或 DMG/ZIP 打包，也没有自动启动
  App；因此这是本机开发安装证据，不是正式 release 或运行时 UI smoke 证据。

2026-08-07 macOS Chat/Cowork composer 图片附件复用的直接证据：

- `ComposerAttachmentTests`：2 tests / 0 failures；覆盖 security-scoped URL reader、ArtifactStore
  保存/精确 bytes 读回、image provider input 解析，以及非图片文件“本地保留但发送前 typed 拒绝”；
- `testChatLoopPersistsAndRehydratesImageAttachmentsAcrossTurns`：1 test / 0 failures；验证
  `UserMessagePayload.attachments` 只持久化 ArtifactID，并在下一轮把历史图片和当前图片分别恢复到
  provider request；
- 完整 `swift test`：通过（exit 0）；真实 Git/browser/Keychain 等显式 opt-in host smoke 仍按设计
  skipped，构建只报告仓库既有的 unused-result / deprecated `onChange` warning；
- `xcodegen generate`：通过；`TranslatisMac` macOS Debug unsigned build：通过；`TranslatisiOS` generic
  Simulator Debug unsigned build：通过；
- 未执行 macOS 文件选择/拖放/视觉命中手动 smoke，也未执行真实 provider/credential/network 图片
  对话，因此这里只证明共享 UI/runtime 编译、durable attachment/replay 单元回归与 iOS linkage 边界，
  不外推真实 provider 对全部 image MIME 的线上支持。

2026-08-05 `v0.36 (36)` 版本、shipping target 构建与本机安装的直接证据：

- `xcodegen generate`：通过；`scripts/check-version-consistency.sh`：通过并输出
  `Intatis version is consistent: 0.36 (build 36)`；
- `TranslatisMac` unsigned universal Release：通过；最终 bundle 为 `0.36 (36)`，可执行文件包含
  `x86_64 arm64`。安装前以仓库 Developer ID entitlements 完成 ad-hoc Hardened Runtime 签名，
  `codesign --verify --deep --strict` 通过；
- `/Applications/Intatis.app` 已替换为上述 `0.36 (36)` 开发构建，bundle identifier 为
  `com.Vita0818.TranslatisMac` 且无 quarantine xattr；旧 `0.35 (35)` 已移入废纸篓作为可恢复备份；
- `TranslatisiOS` generic Simulator Debug unsigned build：通过；最终 bundle 为 `0.36 (36)`；
- 本轮没有运行 Developer ID 签名、公证、staple、Gatekeeper 或 DMG/ZIP 打包，因此这只是本机
  开发安装证据，不是正式 release 证据。完整离线图片工具测试仍见紧随其后的专项结果。

2026-08-05 `image_model` / `generate_image` / `edit_image` 配置路由的直接证据：

- `CLIProviderAdapterTests`：4 tests / 0 failures；新增用例验证 image-only provider 的空
  `models` 不影响 Chat selection、`image_model` 精确映射到独立 opaque endpoint/model，以及字段
  缺失时无隐藏 fallback；
- `IntatisProvidersMultimodalTests`：17 tests / 0 failures；覆盖 image provider registry、
  `images/generations` JSON、`images/edits` multipart reference、DALL-E 2 的显式 base64 response、
  `b64_json` decode、非法 URL、provider payload error、timeout/retry 与 no-image-model nil route；
- `IntatisToolsTests`：144 tests / 15 skipped / 0 failures；覆盖 `edit_image` schema/registry、单图
  preflight、输入/输出权限资源分离、无副作用拒绝与宿主 service 注入；
- `IntatisAgentKernelTests`：171 tests / 0 failures；其中 provider image service 用例验证编辑调用使用
  configured image model 而非 Chat model，并把结果写回 workspace；
- `CoworkEndToEndTests`、`MessageDelegationSplitTests`、`ToolRegistryLeaseTests`：合计 28 tests /
  0 failures；覆盖 coordinator/read-write worker 的 `generateMedia` 暴露以及 read-only worker 的
  `edit_image` 抑制；
- `TranslatisMac` macOS Debug unsigned build：通过；构建和上述离线测试均不需要 API Key；
- 当前尚未执行真实 provider/credential/network 图片生成或编辑 smoke，因此不声称任何具体线上
  模型、provider 方言、size/count/quality 组合或计费路径已通过。首版编辑只支持单张输入图；mask、
  多参考图和原地覆盖仍未实现。

2026-08-05 Flotis 单模型 recorded-file runtime 迁移后的 composer voice /
`transcription_model` 直接证据：

- `ComposerVoiceInputTests`：6 tests / 0 failures；除空草稿、已有草稿、尾部空白和空转写 no-op
  外，精确验证默认 WAV 为 16-bit little-endian PCM，且 WAV/M4A 设置都不注入
  `AVEncoderBitRateKey`；
- `IntatisProvidersMultimodalTests`：22 tests / 0 failures；覆盖 owner-only disk-backed multipart
  WAV、exact OpenRouter JSON-base64 `input_audio`、25 MiB recorded-file runtime、严格 JSON
  `Content-Type`、timeout/retry 与安全错误 payload；原有 modern/iOS importer focused tests 继续验证
  `transcription_model` 精确保留、transcription-only provider 空 `models`、exact route 与无 hidden
  fallback；
- 完整 `swift test`：退出码 0；真实 provider、credential、browser、Keychain 等显式 opt-in 用例仍
  按各自声明跳过，不将其记为真实环境通过；
- `xcodegen generate` 与 `scripts/check-version-consistency.sh` 通过，后者输出
  `Intatis version is consistent: 0.36 (build 36)`；`TranslatisMac` macOS Debug unsigned build 与
  `TranslatisiOS` generic Simulator Debug unsigned build 均通过，两端只有既有 deprecated `onChange` /
  unused-result 等 warning；
- 最终 macOS/iOS App bundle 都含 `NSMicrophoneUsageDescription` 与 English/简体中文
  `InfoPlist.strings`。macOS Developer ID target 的说明为“turn voice into editable message drafts”；
  shipping entitlements 另含最小 `com.apple.security.device.audio-input=true`，App Sandbox 仍关闭；
  本地 ad-hoc Debug 签名包的 embedded entitlements 已读回该值且
  `codesign --verify --deep --strict` 通过。ad-hoc 不证明正式 Developer ID/Hardened Runtime 或公证；
  遗留 `TranslatisMacAppStore` target 未修改、未构建；
- 当前未启动 App、未授予真实麦克风权限，也未以真实 credential/network 调用线上
  `audio/transcriptions`，因此录音设备、具体 provider 方言、模型可用性、计费与运行态像素仍为
  `UNKNOWN`，需要下一步手动 smoke；本轮未执行签名、公证、staple、Gatekeeper 或发行打包。

2026-08-14 provider streaming reconnect 与 Cowork terminal-Run Retry 最小修复的直接证据：

- `TranslatisMac` macOS Debug unsigned build 通过：
  `xcodebuild -quiet -project Translatis.xcodeproj -scheme TranslatisMac -configuration Debug
  -destination platform=macOS -derivedDataPath /tmp/IntatisDerivedData-retryfix
  COMPILER_INDEX_STORE_ENABLE=NO CODE_SIGNING_ALLOWED=NO build`，仅有多架构 destination 选择 warning；
- `IntatisProvidersToolCallingTests` 36/36、0 failures；覆盖错误型 SSE 后重连、首次语义输出前重连，
  以及 text/完整 tool call/usage/done 已交付后不盲重放。完整 `IntatisProvidersTests` 为
  203/204：唯一失败是旧断言
  `testOpenAIStreamingDoesNotRetryAfterResponseBytes`，其 fixture 只有尚未组成完整 SSE event 的 raw
  fragment，仍把“收到任意 byte”当成 replay fence，与当前批准的 consumer semantic-yield 合同冲突；
  本轮按仓库修改边界未改测试源码，也未把生产实现退回旧合同；
- `ThreadLayoutTests` 21/21、0 failures；完整 `IntatisSharedUITests` filter 在约 70 秒无输出后
  人工中止（exit 130），不记为通过；
- `git diff --check` 通过。未运行真实 provider/credential/network、网络断线注入、GUI 点击、iOS、
  签名、公证或发行打包 smoke。

2026-08-13 Permission Reviewer plain-text verdict 格式修复的直接证据：

- `PermissionReviewTextVerdictParser` 对 241/500/1000 Character 的非敏感 reason 不因长度改判，仍要求
  非空 plain text 与唯一 final-line ASCII `ALLOW` / `DENY`；system/user prompt 都引用同一份合同；
- 完整长 reason 在任何摘要截断前先经过敏感信息检查，尾部 token fixture 会 fail closed 且不进入
  EventLog；live bound settlement 仍使用固定宿主文案；
- 缺 marker、多个 marker、marker 后有文本、空 reason、JSON/code fence、无 completion marker 与
  非成功 finish reason 分别验证 secret-free typed diagnosis；旧 `malformed_verdict` 与
  `provider_still_stopping` 仍可解码；
- 聚焦命令
  `swift test --disable-automatic-resolution --filter 'IntatisPermissionReviewerTests|PermissionReviewProtocolTests|PermissionReviewControlPlaneTests'`
  通过：`PermissionReviewProtocolTests` 13/13、`IntatisPermissionReviewerTests` 14/14、
  `PermissionReviewControlPlaneTests` 51/51，合计 78/78、0 failures；完成相关 package Debug 编译。
  未运行全量 test、macOS/iOS app build、真实 reviewer provider、credential/network 或 GUI smoke。

2026-08-13 Cowork Session 内独立 WorkTask / Run 中断 / 原子委派重构的直接证据：

- `TaskGoalProtocolTests` 12/12 与 `TaskGoalProjectionTests` 7/7：验证 WorkTask schema/事件不含
  Run、Goal、agent owner，dependency 只在当前 Session graph 内成立，`interrupted` Run 为 terminal；
- `WorkTaskRuntimeTests` 21/21：包含 `testTaskCreateDescriptorIsSessionScopedAndHasNoOwnerField`、
  `testDelegationPreflightFailureWritesNoPartialFacts`、stale revision 与 post-append lost-ack 边界；
- `AgentInvocationNonRecursiveTests` 11/11：验证 `delegate_task` 只接受已 attached worker，省略 target
  只选择现有 idle worker，缺 target/Mediator deny 不留下 message、delegation、lease、queue 或隐式 worker；
- `GoalRuntimeControllerTests` 33/33：验证恢复把悬空 active Run 写成 `interrupted`，显式 Resume 创建
  不同 RunID，且 Run/Goal/invocation terminal 不传播 WorkTask 状态；
- `PerAgentInferenceProfileTests.testAutomaticDelegationDoesNotProposeWorkerWhenNoneIsAttached` 1/1：
  验证 automatic delegation 不再 proposed/spawn worker；
- `IntatisProtocolTests` 107/107、`IntatisConversationTests` 212/212、`IntatisAgentKernelTests`
  220/220、`IntatisCoworkTests` 364/364、`IntatisSkillsTests` 29/29、`IntatisToolsTests`
  227/227（另有 19 个显式 opt-in skip）均通过；Cowork 内另确认 `PerAgentInferenceProfileTests`
  21/21、`OrchestrationReliabilityTests` 44/44、`PermissionReviewControlPlaneTests` +
  `RunControlTests` 58/58；
- `swift build` 与 `git diff --check` 通过。一次整仓 `swift test` 在 Tools/Skills 通过后，于既有
  SharedUI async waiter 中超过 60 秒无输出并人工中止（exit 130），因此不记为完整 suite 通过；
  未运行真实 provider、credential/network、GUI、macOS App 或 iOS App smoke。

2026-08-13 AuthorizationSidecar 绑定域分离与副作用完成 cast 删除的直接证据：

- `AgentLoop` 现在只用 stripped canonical business arguments 自身重算并核对
  `businessArgumentsDigest` / Character count；工具自定义的 `authorizationArgumentIdentity` 继续独立生成
  `ResolvedToolAuthorization.normalizedArgumentsDigest` / count。两组摘要各自闭环验证，不再互相比较；
  `PermissionReviewControlPlaneTests.testCustomAuthorizationIdentityDoesNotConflictWithBusinessArguments`
  与 `AutomaticPermissionReviewTests.testSecretSidecarFailsWhileCustomAuthorizationIdentityRemainsBound`
  覆盖 custom identity 与业务 JSON 摘要明确不同但仍可合法审查、执行的回归；
- 已删除 `SideEffectEvidenceLedger`、其 EventLog restore、全部 denied/failed/succeeded 记账、final 前
  unresolved 检查，以及 `toolExecutionRequiresManualReconciliation` /
  `unresolvedDeniedSideEffects` 两个 AgentLoop error 和对应 model-facing prompt。普通权限拒绝或 executor
  失败仍写 typed `tool_result` 并回到同一模型 turn，但不会再被二次 cast 成“整轮不能完成”；
- hard permission deny、`ToolDenialCircuitBreaker`、durable execution ticket、
  `effectDisposition`、`.doNotReplay` 与旧 attempt crash-replay guard 均保留；这些机制分别约束当前调用能否
  执行或旧 attempt 能否自动重放，不得重新组合成 final-completion gate；
- `AuthorizationSidecarTests` 12/12、`AgentLoopPolicyTests` 37/37、
  `AutomaticPermissionReviewTests` 39/39、`PermissionReviewControlPlaneTests` 52/52、
  `AgentInvocationNonRecursiveTests` 11/11、`PerAgentInferenceProfileTests` 21/21 均通过；
  模块级完整结果为 `IntatisAgentKernelTests` 220/220、`IntatisConversationTests` 212/212、
  `IntatisCoworkTests` 365/365，全部 0 failures；
- `swift build --disable-automatic-resolution` 与 `TranslatisMac` macOS Debug unsigned build 通过；Mac 构建只有
  仓内既有 unused-result / deprecated `onChange` warnings。未运行真实 provider、credential/network、
  GUI、iOS App、签名、公证或发行打包 smoke。

2026-08-12 Cowork ordinary-worker WorkTask update 收窄的直接证据：

- `ToolRegistryLeaseTests.testWorkerTaskUpdateSchemaExposesOnlyBoundProgressAndSettlementFields`：
  worker 的 exact property set 为 `task_id/expected_revision/progress_note/status/result/evidence`，
  `additionalProperties=false`，status 只含 `in_progress/blocked/completed/failed`；同一测试同时确认
  manager 的 14 个完整字段与各自 capability grant 均保持不变；
- `WorkTaskRuntimeTests.testMutatingWorkTaskToolsRejectMissingHostManagerAsNotStarted`：worker 窄入口仍
  委托既有宿主执行链，缺失 host-bound manager 时与完整入口一样 fail closed，不伪报成功；
- `IntatisAgentKernelTests.testUnknownToolArgumentsDoNotRequestPermissionOrExecuteTool`：1/1；确认 closed
  schema 的未知字段不会产生 permission request，也不会进入 executor；
- `ToolRegistryLeaseTests` 26/26、`WorkTaskRuntimeTests` 22/22，加上述内核 gate 合计 49/49、
  0 failures；`swift build --disable-automatic-resolution` 通过。未运行全量 test、macOS/iOS app
  build、真实 provider 或 GUI smoke。

2026-08-12 `permission_reviewer_model` 独立控制面 route 的直接证据：

- canonical 顶层字段只接受 `<provider>/<model-id>` 的已配置 inference base profile；字段缺失只继承
  同一 JSON 文档的顶层 `model`，而显式空值、错误类型、未知/禁用 provider、未知 model 与 unresolved
  env/file reference、缺失/未知 top-level compatibility source，以及已选 Mac 配置整体损坏/不可读都
  让 reviewer fail closed。Mac 当前选择、UserDefaults、Cowork session default、
  `TRANSLATIS_MODEL`、live/historical `@main` 与 main rebind 均不是 reviewer fallback；没有新增 UI 或
  session/EventLog schema；
- `AutomaticPermissionReviewTests`：39/39，覆盖独立 main/reviewer exact binding 的原子七事件落盘、
  reviewer tuple missing/mismatch、reviewer catalog TOCTOU 零事件失败，以及既有 reviewer lifecycle；
- `PerAgentInferenceProfileTests`：21/21；`CLIProviderAdapterTests`：13/13，覆盖 JSON-model compatibility、
  环境变量只改变 main 而 reviewer 不漂移、显式非法 reviewer fail closed、缺失 reviewer 时不能从缺失/未知
  JSON default 发明 route、独立 profile lowering 与 main rebind 后 reviewer durable binding 不变；
- `TranslatisCLITests`：49 tests / 0 failures / 8 个显式 opt-in real-provider smoke skipped；未发送真实网络
  请求或产生计费；
- `swift build --disable-automatic-resolution` 与 `TranslatisMac` macOS Debug unsigned build 通过；只有仓内
  既有 unused-result / deprecated `onChange` warning。Mac App 无独立 XCTest target，因此 Mac config
  presence/normalization/writer 与 runtime freeze 还通过源码审计和完整 target 编译验证，不能冒充真实
  GUI/provider smoke；
- 未读取或修改用户的真实 provider/auth 配置，未运行真实 permission-review provider matrix；模型的
  实际 plain-text verdict 稳定性仍需用用户配置的 reviewer route 做手动 smoke。

2026-08-05 Cowork coordinator 主动推进与外部目录恢复提示词的直接证据：

- `ContextProjectionTests`：22 tests / 0 failures；验证 coordinator 会先建立 execution objective、
  检查 bounded Skill catalog、只在用户明确要求持续/跨 run 目标时创建 durable Goal、为非简单工作
  建立最小 WorkTask 图、尽早委派有收益的分支并继续自己的关键路径，同时保留最小 team/lease；也验证
  coordinator 在工具真实可用时
  停止根外直接重试，使用 exact-directory `spawn_agent`、默认 `read_only`、按需
  `read_write`、随后 `delegate_task`，工具/扩展失败则报告 blocker；同一用例验证 worker 与
  Code 默认提示词不宣称 `spawn_agent`；
- `ToolRegistryLeaseTests`：16 tests / 0 failures；验证 Orchestrator 按 coordinator task lease
  生成的真实 provider request 同时含主动推进规则、`spawn_agent` 工具与上述恢复规则，worker lease
  边界不变；
- `IntatisSkillsTests`：29 tests / 0 failures；验证产品内置 `cowork-agent-orchestration` Skill 包含主动
  执行循环，同时继续保留 capability hard gate、最小团队与 exact profile 路由约束；
- `intatis-skill-creator/scripts/quick_validate.py`：`Skill is valid`；目录名/frontmatter、结构、文本安全
  与资源引用校验通过；
- `IntatisAgentKernelTests`：170 tests / 0 failures；`IntatisCoworkTests`：320 tests / 0 failures；
- SwiftPM 测试过程完成受影响源码/CLI package 的 Debug 编译。本次未改 App/UI、协议、权限实现或
  Xcode 工程，未另跑 macOS/iOS app build；也未执行真实模型的外部目录行为 smoke，因此这里只
  证明稳定提示词、工具表面与 lease 集成，不把任一模型一定遵循提示词写成确定性保证。

2026-08-05 Chat 托管搜索路由修订的直接证据：

- `IntatisProvidersTests`：171 tests / 0 failures；覆盖 exact route capability、OpenAI/OpenRouter
  request shape、strict routing options、legacy search route ignore、静默普通 Chat、窄化的同路由
  fallback、partial-response replay guard、两类 citation annotation，以及无效 legacy 搜索字段不
  阻止 Chat/有效 legacy 搜索字段不污染可见模型列表；
- `IntatisConversationTests`：173 tests / 0 failures；
- `TranslatisCLITests`：28 tests / 2 opt-in real-provider tests skipped / 0 failures；
- `IntatisSharedUITests`：133 tests / 0 failures；
- `TranslatisMac` macOS Debug unsigned build：通过；`TranslatisiOS` generic Simulator Debug unsigned
  build：通过。iOS 首次独立依赖解析遇到 GitHub proxy 503，复用已成功解析并缓存的同一
  working-tree dependencies 后构建通过，该网络失败不计为源码失败；
- 未执行真实 provider/credential/network smoke，因此这里只证明离线 wire fixture、planner、
  integration 与两端编译，不声称任何具体厂商当前线上 endpoint 已通过。

2026-08-03 版本校准后的直接证据：

- `xcodegen generate`：通过；
- `scripts/check-version-consistency.sh`：通过，输出 `0.32 (build 32)`；
- `TranslatisMac` unsigned universal Release：通过；最终 bundle 为 `0.32 (32)`，可执行文件为
  `x86_64 arm64`。这是代码与元数据验收，不是签名发行产物；
- `TranslatisiOS` generic Simulator Debug：通过；最终 bundle 为 `0.32 (32)`；
- 两端构建有既有的 unused-result 与 deprecated `onChange` 警告，无构建错误；
- `swift build`：在允许 Swift/Clang 写入用户缓存的宿主环境通过；受限沙箱内首次尝试因
  module cache 无写权限而未进入源码编译，不计为产品失败；
- release script `zsh -n`：通过；无证书 preflight 按预期在任何正式输出前失败；
- 临时非发行探针：App runtime signing command、XML entitlements、UDZO DMG、DMG signing
  command 和 strict codesign 通过，临时目录已删除；
- `IntatisToolsTests`（外层 sandbox 外）：141 tests / 15 skipped / 0 failures；
- `testSharedSoftTokenBudgetReservesBeforeDispatchAndReportsProviderOverrun` 原始 fixture 已先
  稳定复现为 `requestTooLarge(limit: 800, estimatedInput: 889)`，证明生产 pre-dispatch
  保护正常；测试随后改为使用有充足 prompt 余量的命名预算常量，继续精确验证 provider
  忽略 output ceiling 后超支 1 token 的 soft-budget 语义；
- 修正后的 focused 用例：1 test / 0 failures；`IntatisAgentKernelTests`：169 tests /
  0 failures；
- 完整 `swift test`：通过。真实 browser/Git/provider/credential/network 等显式 opt-in
  用例仍按设计 skipped，不计为已执行的真实环境验证；
- Cowork agent-thread Computer Use：8 × 1,000 rows + 500 delta/s 下，1,000 rapid switches 与
  180 秒 soak（1,486 timed switches）均通过，0 warning / 0 incident；结束后 14 个
  `NSTextViewSharedData`、173 个 `GestureNode`，`vmmap` 62.1 MiB physical / 74.8 MiB peak，
  `ps` RSS 约 156.6 MiB；
- 2026-08-04 historical-roster 增量：`CoworkProjectionRegressionTests` 8/8、
  `CoworkAgentThreadPresentationModelTests` 10/10、`CoworkInferencePresentationTests` 6/6、
  `IntatisConversationTests` 172/172；Computer Use 实测 detach 当前 agent 后保持选择、离开再返回
  仍可读，并在 500 delta/s 下追加完成 1,000 rapid switches，0 warning / 0 incident、16 rows。
  当前 Codex managed sandbox 的完整 suite 只因 `IntatisToolsTests` process/Seatbelt/loopback 限制
  失败；一次完整 `IntatisSharedUITests` target 在 build 后无测试输出并被中止，相关定向用例已独立
  通过；
- 2026-08-04 rail lighting/fixed-geometry 增量：
  `ThreadLayoutTests|CoworkInferencePresentationTests|CoworkAgentThreadPresentationModelTests`
  30/30；TranslatisMac macOS Debug 与 TranslatisiOS generic Simulator Debug unsigned build 通过。
  原生 Light fixture 在同一 1372×768 viewport 中切换 `@main` / `@research`，composer 水平像素
  run 完全一致，rail 两态均为 x=1076…1365；旧 `.regular` glass card 的一次性 QA sample
  为 240/255，新系统 `Glass.clear` sample 为 244/255。该数值只用于同机同窗对照，不是颜色 token。
  8×1,000 rows + 500 delta/s 下再次完成 1,000 rapid switches，0 warning / 0 incident、≤16 rows。
  本次未重跑 180 秒 soak、Dark、Reduce Transparency、Increase Contrast、VoiceOver 或完整
  SwiftPM suite；不得从该 Light fixture 外推这些矩阵。
- 2026-08-04 rail window-stability 第一版的 31/31 与截图数据只保留为历史记录；用户随后仍稳定
  复现跳动，真实 Test session 也记录到 viewport preference 同帧重复更新，因此该结论已作废。
- 第二版 corrective pass（删除 GeometryReader/PreferenceKey 坐标链、改用
  `onScrollVisibilityChange`、拆除 shared glass container）的 85/85、360-cycle host 与当时的 AX/
  视觉结论已经被用户在新构建中的稳定复现推翻，不得继续当作 rail 不跳动的通过证据。当前第三版
  必须额外验证：outer-detail canvas 而非 `threadColumn` 直接拥有 trailing rail；selection 不在 rail
  render snapshot；蓝色 selection child 可独立更新；`Glass.clear` backdrop 是 content-independent
  Equatable view；transaction 同时关闭 animation 与 disablesAnimations。当前
  `ThreadLayoutTests|CoworkInferencePresentationTests|CoworkAgentThreadPresentationModelTests`
  31/31 通过，production-shaped host 包含 360 次交错 selection/mode/inspector/window-size 循环；
  TranslatisMac macOS Debug 与 TranslatisiOS generic Simulator Debug unsigned build 通过。按用户要求不使用
  Computer Use 或截图差分，因此最终几像素光学稳定性保留为用户新构建手动验收项，不能由自动化外推。
- 用户普通终端的 `security find-identity -v -p codesigning` 已报告两个有效 identity，发行
  脚本也已进入真实 Developer ID 签名和 App 上传；Codex 托管沙箱无法读取登录 Keychain，
  因而在沙箱内仍返回 `0 valid identities found`，不能覆盖宿主证据。两次 App submission
  已被 Apple 接收但查询时均为 `In Progress`；尚无 Accepted、staple 或 Gatekeeper 证据。

## Release GO 条件

只有以下条件同时满足才能写 release GO：

- 当前 working tree 相关 tests/builds 通过，已知失败有明确处置；
- 最终 App/ZIP/DMG 元数据为当前唯一事实源要求的 `0.72 (72)`；
- Developer ID、notarization、staple、codesign、Gatekeeper 全部通过；
- NOTICE/ThirdPartyNotices 和最终 bundle resource/link inventory 一致；
- 关键真实环境矩阵完成，未完成项以明确的风险接受记录处理。

2026-09-04 v0.72工作树的最新完整SwiftPM运行再次复现SharedUI组合顺序静默等待并有界中止；聚焦矩阵和
两端bundle构建均通过，但最终App仍缺Codex/Document/Browser三套runtime及正式Developer ID/notarization/
staple/Gatekeeper证据。因此当前明确不满足Release GO，聚焦通过不能替代完整稳定性与发行包闭环。

## 2026-10-03：诊断脱敏测试输入与推送保护

- `IntatisDiagnosticExportTests.testDiagnosticTextSanitizerCoversCommonCredentialAndIdentityShapes`
  的 Slack 形状输入改为运行时拼接的明确合成 fixture，不再在测试源码中保存完整 token 样式字面量。
  生产 sanitizer、五个既有断言及其他输入覆盖保持不变。
- 直接复用当前生产 `IntatisHangDiagnosticTextSanitizer` 和该用例的五个断言运行隔离 Swift 检查，
  五项均通过；修改后的测试文件通过 Swift parser 检查，`git diff --check` 通过。
- 本轮未运行完整 SwiftPM suite 或 App 构建；只验证测试输入修复，避免重新生成已按用户要求清理的
  全项目构建缓存。产品版本和运行时行为未变。
- GitHub 推送保护指出该字面量存在于尚未发布的历史提交中；仅修改当前文件不能清除旧提交中的记录。
  对未发布历史的整理必须获得用户针对仓库和目标的明确授权，不使用推送保护豁免。

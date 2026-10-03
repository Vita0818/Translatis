# PROJECT_MAP — Translatis

文档状态：当前仓库地图
最近自查日期：2026-09-08
产品基线：v0.72（build 72）

本文描述当前仓库结构。判断依据来自 `Package.swift`、`project.yml`、`Makefile`、源码、测试文件和脚本。
产品入口和活动路径属于 Translatis；`Intatis*` package/target 名称仅表示共享实现或固定接线合同。

macOS 唯一发行 target 是 Developer ID/direct-distribution `TranslatisMac`。
旧 `TranslatisMacAppStore` target/scheme、编译条件和专属 entitlements 已删除；
当前 XcodeGen 产品图只有一个 macOS App target。分发合同见
`docs/MACOS_DISTRIBUTION.md`。

## 2026-08-30 Cowork纯右侧UI地图

- `Packages/IntatisCoworkUI/Sources/IntatisCoworkContentContract.swift`：v1 marker、secret-free inference
  option、完整right-pane presentation state、voice/Goal draft、structured-user-input state/submission action、
  host-owned thread source与single-action
  callbacks；没有runtime/session/tool owner。
- `Packages/IntatisCoworkUI/Sources/IntatisCoworkContentView.swift`：完整Cowork右侧composition，包含
  selected-agent thread、模型选择、附件/语音、Send/Stop、permission、Agents/Goal/Tasks、Inspector、
  retry、Goal editor、MCP pending context和可选host settings sheet。
- `Apps/TranslatisMac/Sources/TranslatisMacApp.swift`的`CoworkSessionView`只把原App-owned
  `CoworkViewModel` published state/bindings/actions映射给`IntatisCoworkContentView`；
  `CoworkViewModel.swift`、`CoworkProjectSettings.swift`、`Workspace.swift`、session manager及runtime factory
  均留在原App位置。
- `Packages/IntatisSharedUI/Sources/StructuredUserInput.swift`只定义request-local question/options、draft、
  submission、透明描边panel、native single-selection List编号整行与多题导航；`CodeViewModel`/
  `CoworkViewModel`中的App-owned presenter负责把official callback映射为该state。`IntatisCoworkUI`只透传
  pending state和submit action，不依赖CodexRuntime。
- `Packages/IntatisSharedUI/Sources/ComposerAttachmentSurfaces.swift`：原App-owned Chat/Code/Cowork通用
  paperclip/import/drop UI移入既有presentation component层，供TranslatisMac和CoworkUI共同使用；不持有
  ArtifactStore或session。
- `Packages/IntatisCoworkUI/Tests/IntatisCoworkUIPublicContractTests.swift`：普通public import及依赖/source
  ownership gate。完整跨项目合同见`docs/COWORK_UI_INTEGRATION.md`。

## 2026-08-22–09-02 Codex Runtime 接线地图

- `Packages/IntatisCodexRuntime/Sources/CodexAppServerSession.swift`：固定
  `codex-cli 0.145.0-intatis.4` 的 process owner、stable stdio JSON-RPC、thread start/resume、turn
  start/wait/interrupt、item stream、server approval、Goal 与 shutdown；保留官方agent-message
  `commentary`/`final_answer` phase，并把active turn notification的exact wire method与安全scalar字段
  送入UI事件流，不维护host method allowlist；fresh thread另通过official experimental
  `dynamicTools`注册flat function并异步处理`item/tool/call`，resume不重发该字段；另提供presentation-agnostic
  `requestUserInputHandler`，非nil时在同一Code/Cowork流处理official
  `item/tool/requestUserInput`并回传exact answer map，nil时feature明确关闭；Cowork另读取verified
  descendant tree/history，按child thread投影事件，并以`thread/subagent/message`直达native mailbox；
  persisted resume还处理preview-empty relation child、pre-root usage buffer、self-valued child sessionId和
  approved provider config reapplication，active Goal先official pause再resume；initialize后还用official
  `skills/extraRoots/set`接回host用户Skill root；native MCP root配置在process启动前写入isolated home，
  Cowork child resume另用official config重申完整disabled server集合。
- `CodexBusinessToolHost.swift`：从`ToolRegistry.standard.v5`冻结71个现有文档/浏览器registration，并把
  `generate_image`/`edit_image`以同名exact capability和required
  `ImageGenerationToolService`接成73项无搜索基础business catalog；root或任一child exact route有匹配service
  时，复用既有`HostedWebSearchTool`与`ProviderHostedWebSearchToolService`条件式增加
  `hosted_web_search`为74项。当前runtime另注入EventLog-backed `rename_session`（无/有search时Code共
  74/75项；Cowork另含5个WorkTask，共79/80项），可选复用既有`HostToolRegistryAugmenter`加入
  `build_knowledge`/`search_knowledge`（对应Code 76/77、Cowork 81/82项），
  直接复用其schema、permission intent、WorkspaceLease、确定性权限门、permission UI/CLI callback与
  durable execution ticket；verified child使用自己的AgentID、workspace access、PermissionProfile和
  WorkTask manager scope，批准记忆不能跨agent；child虽然因App Server共享surface可见rename schema，
  但rename仍按root-only合同hard deny；Knowledge按host-owned profile/inherited capability为每个verified
  child建立独立registry/lease scope，read-only只有search、read-write才有build+search，未授权仍在audit前
  拒绝；图片工具只向read-write root/child签发`.generateImage`/`.editImage`，hosted search按不可由模型
  author的root/child-role scope选择exact service并只向read-write caller签发`.hostedWebSearch`，read-only/
  unsupported caller在audit或provider前拒绝；旧`.generateMedia`不参与shipping authority；全部Knowledge augmentation lease随runtime
  shutdown drain。不含MCP translator、agent loop、scheduler、shell/Python替代或fallback。
- `CodexRuntimeMCPConfiguration.swift`：把`IntatisMCP` catalog + exact session attachment/grant/consent
  收窄投影为pinned Codex native `[mcp_servers]`。当前接受Code/Cowork exact root的Streamable HTTP完整
  Interactive grant；tool filters、approval、parallel、required/timeouts保真，secret只映射到App Server
  process env。Cowork显式/default child role与persisted resume使用完整secret-free disabled定义阻断继承；
  per-child MCP、partial/TTL/stdio/无法迁移的OAuth明确失败。`MCPProjectSettingsSurfaces.swift`和
  `MCPCLICommands.swift`复用同一native authority validator：产品入口只向exact root保存完整Interactive、
  non-expiring grant，child旧grant只可撤销，CLI native会话也不能提交child/task、partial或TTL。
- `CodexRuntimeSkillConfiguration.swift`：只承载host批准的absolute bounded extra roots；默认把外部
  `$CODEX_HOME/skills`经official `skills/extraRoots/set`接入，不共享该home的login/config/rollout/secret。
  repository `.agents/skills`与isolated system Skills仍由Codex core自己发现。
- `CodexRuntimeExecutable.swift`：shipping macOS bundle只接受
  `Contents/Resources/CodexRuntime/{active-architecture}/codex`；CLI/非产品debug host才可使用显式override、
  env、official local或PATH候选。所有入口都执行strict version + compile-time patch derivation gate，
  外置开发候选不能成为shipping backend fallback。
- `CodexRuntimeStorage.swift` / `CodexRuntimeProcessLease.swift`：session-owned
  `codex-runtime/{codex-home,runtime.json,models.json,runtime.lock}`，owner-only/no-follow/atomic +
  cross-process single-writer flock；`runtime.json`冻结exact runtime derivation与dynamic toolset identity并
  拒绝旧runtime/旧derivation/旧toolset session；0.145.0 exact model catalog把auto-review绑定到selected model；isolated home另写
  secret-free custom-agent role files、完整provider引用、native MCP config与官方Skills discovery副本；
  model catalog为Code/Cowork均启用Skill usage instructions。
- `CodexRuntimeModels.swift`：无 secret 的 host lifecycle/event/approval types；配置 description 永远
  redacted；包括App Server exact dynamic-tool spec/call/content/result类型，
  `CodexRuntimeResponsesUsage`承载每turn的原生Responses usage与duration；`CodexRuntimeChildProfile`冻结
  host-approved role、完整Responses route、workspace、sandbox、Intatis permission profile与Knowledge
  capabilities；只有tool list
  真正含`rename_session`时才生成首任务一次改名、root-only、last-non-run-control developer instructions。
- `CodexRuntimeHostContract.swift`与`docs/CODEX_RUNTIME_INTEGRATION.md`：冻结其他Vitemis项目通过
  SwiftPM local path直接依赖的v1宿主面；API major与exact Codex runtime version/derivation独立。
  `CodexRuntimePublicContractTests.swift`只使用public imports，编译最小route/configuration/session、
  lifecycle/approval closures和dynamic-tools callback，并固定`IntatisCodexRuntime` product名；不新增
  protocol facade、runtime selector或fallback。
- `Packages/IntatisCore/Sources/HostApplicationIdentity.swift`：共享package的单次宿主产品身份安装点。
  `IntatisHostApplication.configure(name:)`把一个安全App名称派生为storage/config/env/defaults/Keychain/
  diagnostics/workspace/Knowledge/registry/sidecar命名；identity第一次读取后锁定。当前Translatis三入口显式
  安装`Translatis`，下游只需在任何共享对象前安装自己的名称。`CodexRuntimeConfiguration`另冻结同一
  `hostApplicationIdentity`到exact session。Swift module/type与fixed Codex patch字段不参与动态改名；
  legacy Intatis路径只保留在deny/secret-recognition floor。
- `Packages/IntatisCowork/Sources/CodexWorkTaskController.swift`与`CodexWorkTaskLinkTool.swift`：只保存
  user-visible WorkTask DAG/revision/result/evidence和verified native child关联；不创建、排队、运行、等待、
  传话或停止agent，也不调用legacy Orchestrator/MessageBus。
- `Packages/IntatisProtocol/Sources/Event.swift` / `Envelope.swift`：additive `MessagePhase`与
  `codex_app_server_event` durable UI fact；legacy message缺phase继续解码为`nil`。后者只容纳exact
  method、type/phase/status、turn/item identity与允许的reasoning/plan delta，不容纳完整payload、
  command output、arguments、paths或credential。
- `Packages/IntatisProtocol/Sources/ResponsesUsage.swift`：additive `responses_usage` durable payload，
  保存exact turn/final-message identity、`thread/tokenUsage/updated.tokenUsage.last`六项App Server
  token usage与duration；不含thread累计total、context window或旧prompt/completion语义。
- `Packages/IntatisConversation/Sources/CodeProjection.swift`与新增
  `CodexActivityPresentation.swift`：前者继续保存exact raw event item；后者只在默认展示边界把
  started/delta/completed按exact turn/item identity归并为typed semantic activity，并把usage/Goal/
  permission/roster/message lifecycle分流到已有专用组件。unknown future event保持通用可见，raw trace
  仍可恢复；不从正文猜状态，也不改EventLog。`SessionProjectionPump.swift`把bounded reasoning/plan
  text delta与assistant delta纳入同一50 ms presentation cadence，其他事件继续immediate barrier。
- `Packages/IntatisSharedUI/Sources/{ExecutionTracePresentation,CodeViews,CoworkViews}.swift`：默认
  Code/Cowork用本地化自然语言、SF Symbols与低chrome正文行显示Command/File changes/Tool/MCP tool/
  Web search/Image/Collaboration/Subagent/Plan/Reasoning/Runtime activity；后台trace开关仍显示原始method/
  scalar。`commentary`保持中间正文，`final_answer`保持正常回答版式，不再挂载合成Thinking。
  `responses_usage`继续按exact message ID绑定footer并显示Input/Cache Hit/Cache Write/Output/Reasoning/
  Total/Duration且不从Input扣除cache；Code/Cowork旧Context不显示。CLI本轮仍使用dim exact输出。
- `Packages/IntatisCodexRuntime/Sources/CodexAppServerSession.swift`：除既有App Server process/JSON-RPC/
  approval/dynamic-tool桥外，负责required `error.willRetry`、安全diagnostic字段、session notification raw
  projection、`currentTime/read`、typed request-user-input callback、handler-qualified persisted toolset identity与
  exact-model reroute fence；结构化问题
  callback绑定root/verified child、拒绝secret/坏answer并在auto-resolve/terminal/shutdown取消。session
  terminal error还覆盖turn waiter登记竞态。
  `Packages/IntatisCodexRuntime/Tests/CodexRuntimeTests.swift`从installed exact `.4`生成experimental JSON
  schema，锁定11种server request/70种notification，并分别验证全部三类approval、dynamic tool、clock、
  transient/terminal error与reroute fail-closed。
- `Apps/TranslatisMac/Sources/{CodeViewModel,CoworkViewModel}.swift`：shipping Codex root submission先写
  `user_message + queued`再启动Runtime，ready后写running，最终写completed/failed/cancelled；terminal Retry
  创建fresh可见continuation submission并保留旧失败。普通root turn error不再误改legacy permission-reviewer
  health，也不重复制造通用runtime error row。
- `Packages/IntatisProviders/Sources/ResponsesRuntimeRoute.swift`：从 macOS/CLI当前 route 或 Cowork
  exact `AgentInferenceBinding` 解析 Responses base/query/bearer与reasoning；exact OpenRouter的完整
  `options.provider`作为request-owned opaque JSON经Codex config进入最终body，不枚举children，也不做
  Chat Completions translation或generic whole-body parsing。
- `Apps/TranslatisMac/Sources/CodeViewModel.swift` / `CoworkViewModel.swift`：保留现有 UI/EventLog shell，
  shipping send/start/cancel/shutdown 只调用 Codex runtime；旧 AgentLoop/Orchestrator入口标成
  `unavailable`；两者为fresh Codex thread注入同一document/browser dynamic tool host和当前session的
  `EventLogSessionNamingService`及可选Knowledge augmenter；Code/Cowork root从exact durable MCP authority
  生成native config，MCP设置变更先drain runtime；macOS fresh Cowork先在空EventLog以一个原子四事件批次
  登记settings、`@main` workspace/capability/identity，runtime与MCP授权面随后消费同一root lease pair，
  partial/ambiguous历史不原地修补；root workspace/access变化在settings事务中撤销并换发租约。Cowork child
  由native role/resume config强制disabled。
  两者还在同一次exact route resolution中取得optional hosted-search route，并把既有service按root/role
  scope交给business host；hosted能力缺失不会切换route或构造替代search实现。
  两者都接入host用户native Skill extra root。Cowork把verified
  Codex descendants接入既有Agents rail、逐agent连续conversation、permission来源、archived历史、
  WorkTask和official thread Goal，并把session里用户批准的role/workspace/inference binding降为preset。
- `Apps/translatis-cli/Sources/CodexRuntimeCLI.swift`：`translatis code|cowork` 共用同一 runtime；
  通过v6 hosted-search salt/session root使用同一dynamic tool host、Knowledge augmenter、EventLog-backed session naming与CLI approval prompt；
  `/mcp`复用既有exact authority管理命令，Code/Cowork root重启后投影native HTTP MCP，Cowork child原生disabled；
  同时通过official extra root恢复host用户Skills。Cowork把配置文件里的safe
  inference profiles降为同workspace的host-approved custom-agent presets，并提供`/agents`、`/thread`、
  `/archive`与`@agent` native control-plane message；`Interactive.swift`只把Chat留在旧Chat REPL。
- `Packages/IntatisCodexRuntime/Tests/CodexRuntimeTests.swift`、`CodexNativeSubagentIntegrationTests.swift`与
  `CodexRuntimeSkillTests.swift`：route/storage/version、test-only fake
  full turn（含phase、reasoning delta、两次exact raw Responses usage累计、duration及无需allowlist的
  新notification）、fake dynamic call完整往返、73-tool无搜索与74-tool hosted-search基础目录、74-tool
  no-search root rename、图片root/read-write child执行、hosted-search root/child exact service分流、
  read-only/unsupported pre-audit或pre-provider deny、同名exact capability、secret pre-authorization
  deny、条件式首任务提示、toolset拒绝，以及installed exact binary的
  experimental dynamicTools offline real App Server handshake；另覆盖native MCP official TOML/filters/
  approval/no-secret、partial grant拒绝、Cowork role/resume child隔离、Knowledge root/child/lifecycle与Skill
  extra roots先于thread start。
  真实`.4`本地Responses server还验证V2
  flat `spawn_agent`、explicit role/workspace preset、child exact route/cwd、root native MCP namespace、child
  MCP隔离、child Knowledge capability callback、完全退出后同child继续隔离，以及child实际调用继承的dynamic
  function与owner-only Skill安装。current patch已用独立clean arm64 binary完成真实`stealth/ox-alpha`
  spawn/tool/model-label/CLI history和完全退出后同child恢复；相同`.4`不同derivation明确拒绝。
- provenance/发行 gate：`ThirdPartyNotices/OpenAICodexRuntime.md`、`NOTICE.md` 与可复现
  `ThirdPartyPatches/OpenAICodexRuntime/`。

Codex rollout 是 model-context authority；EventLog 是 Intatis UI/audit projection。required join 是
`runtime.json`；legacy EventLog without mapping 不自动迁移。当前没有 bundled runtime binary，iOS product
graph不链接此 target。

## 2026-08-22 macOS 文件夹项目地图

- `Packages/IntatisCore/Sources/ProjectFolderStore.swift`：`ProjectID` 对应的文件夹项目记录、
  exact `SessionKind`、同模式 SessionID 引用和 app-global `projects-v1.plist` 事务。文件为 owner-only
  binary plist，使用 `DurableOwnerOnlyFile` 的 no-follow/lock/atomic/durability 边界；只保存 kind/path/
  引用，不保存 bookmark 或会话正文。旧 mixed-mode 草稿由 reader 按 kind 拆分。
- `Apps/TranslatisMac/Sources/TranslatisMacApp.swift`：进程共享项目投影、add/remove/associate、项目内
  同模式新会话 composition 与 expected-kind gate。Chat 只验证文件夹仍存在；Code/Cowork 要求用户
  重新确认 exact 项目文件夹，再复用现有 session-owned `WorkspaceAccess.remember`。
- `Apps/TranslatisMac/Sources/TranslatisMacRootView.swift`：按当前 mode 过滤的 Projects tree、折叠文件夹、
  `Unfiled` session、同模式新会话、会话选择及“移除项目不删文件夹/会话”确认；没有项目主页、
  固定 Projects 高度或跨模式菜单。
- `Packages/IntatisSharedUI/Sources/ThreadSurfaces.swift`：`IntatisSessionHistoryList` 可关闭内部
  ScrollView，使可折叠 Projects 与 Unfiled 共用一个 sidebar 滚动面；默认调用行为不变。
- `Packages/IntatisCore/Tests/ProjectFolderStoreTests.swift` 与
  `Packages/IntatisSharedUI/Tests/ThreadLayoutTests.swift`：存储/并发/损坏/非删除语义及 macOS
  composition source-shape 回归。iOS 不显示文件夹项目 UI，现有 Chat-only target 边界不变。

本功能不在用户项目文件夹内生成 Intatis 元数据，不移动 App Support session 目录，也不等于既有
Cowork `CoworkProjectSettings` project mode。

## 2026-08-19 JetBrains Mono 正式产品字体地图

- `Packages/IntatisSharedUI/Sources/Resources/JetBrainsMono[wght].ttf` 与
  `JetBrainsMono-Italic[wght].ttf` 是官方 JetBrains Mono 2.304 的两份 unmodified variable fonts；
  `Package.swift` 把它们作为 `IntatisSharedUI` resources，使 macOS/iOS App 与 SharedUI tests 使用同一
  `Bundle.module`。它们不是系统安装依赖，也没有 App-only duplicate copy。
- `Packages/IntatisSharedUI/Sources/IntatisTypography.swift` 拥有固定 resource/hash/
  PostScript inventory、Core Text process registration、exact bundle-URL revalidation，以及 shared
  role/direct semantic font lowering。`Apps/TranslatisMac/Sources/TranslatisMacApp.swift` 与
  `Apps/TranslatisiOS/Sources/TranslatisiOSApp.swift` 只负责在 App init 预检和给未显式设置字体的 root Text
  注入默认 product font。
- `Packages/IntatisSharedUI/Sources/MessageRendering/IntatisMicrosoftMarkdownPipeline.swift` 把
  既有 `MarkdownRenderConfig` 的 paragraph/heading/list/table/link/code fonts 变为同一 family；
  `Vendor/SwiftStreamingMarkdown/Sources/MarkdownText/UI/CodeBlockView.swift` 的 patch group 13 只让
  code-block leaves 遵守已经存在的 config font，不引入第二字体 registry。
- macOS/iOS 普通构建、Debug/Release 与发行启动统一使用 JetBrains Mono 英文字体，不存在运行时
  system-font opt-out。中文由 Core Text 系统 CJK glyph fallback 处理。
- provenance/许可证位于 `ThirdPartyNotices/JetBrainsMono.md` 与
  `ThirdPartyNotices/Licenses/JetBrainsMono-2.304-OFL-1.1.txt`。两份 exact TTF 是 v0.55 release
  resource；其 inventory/hash/license/final-bundle gate 必须保持通过。

## 2026-08-10 模型驱动 Knowledge 接线地图

- 配置、route 与 provider-reported Knowledge usage：`Apps/TranslatisMac/Sources/AppConfig.swift`、
  `Apps/translatis-cli/Sources/CLIProviderCatalog.swift`、
  `Packages/IntatisProviders/Sources/KnowledgeModelProviders.swift`。
- Provider/Core bridge：
  `Packages/IntatisKnowledge/Sources/ProviderKnowledgeModelAdapters.swift`。
- exact external authority：`KnowledgeLease.swift`、`KnowledgeStoreAuthority.swift`、
  `SessionKnowledgeAccessStore.swift`；macOS bookmark host 在
  `Apps/TranslatisMac/Sources/KnowledgeAccess.swift`，CLI explicit authorization 在
  `Apps/translatis-cli/Sources/CLIKnowledgeTools.swift`。
- model-facing tools：`Packages/IntatisKnowledge/Sources/PathAwareKnowledgeTools.swift`；build 复用
  `KnowledgeBundleBuildService.swift`，search 复用 immutable mount/search/final-grounding core。
- published-store/anti-bypass：`KnowledgeSnapshotStore.swift` 管理 `.translatis-rag-snapshots`、legacy
  layout migration、writer lock 与 typed commit uncertainty；`Packages/IntatisProtocol/Sources/Leases.swift`
  冻结 managed-store deny floor，`IntatisTools` 的 file/patch/Git/process/managed-terminal 执行边界执行它。
- lifecycle：`HostToolRegistryAugmentation.swift` 提供 checked close，Code/Cowork/CLI composition root
  必须把 drain timeout 当作失败，不得静默结算成功。
- 产品 composition：Mac Code/Cowork 在 `TranslatisMacApp.swift` / `CoworkViewModel.swift`，CLI
  Code/Cowork 在 `Interactive.swift`，Cowork exact-`@main` capability 边界在
  `Packages/IntatisCowork/Sources/Orchestrator.swift`。
- E2E/合同测试：`ModelDrivenKnowledgeAgentLoopTests.swift`、
  `ModelDrivenKnowledgeToolHostTests.swift`、`KnowledgeModelProviderTests.swift` 与
  `CLIProviderAdapterTests.swift`；外部库 fresh-host restore 也在 AgentLoop E2E 内。真实 route 和
  reranked-vs-baseline 质量入口及真实主模型 read-organize-build-search-cite 入口都在
  `RealProviderSmokeTests.swift`，分别由 `TRANSLATIS_REAL_KNOWLEDGE_SMOKE`、
  `TRANSLATIS_REAL_KNOWLEDGE_QUALITY`、`TRANSLATIS_REAL_KNOWLEDGE_AGENT_E2E` 显式开启；会报告 provider
  token/billable units，默认均跳过且不推算金额。

## 2026-08-02 本地诊断日志导出地图

- `Packages/IntatisCore/Sources/IntatisDiagnosticExport.swift`：共享的 owner-only、
  no-follow、bounded 文件尾部读取，以及 EventLog 结构化脱敏投影；不改变
  EventLog/Envelope schema。
- `Apps/TranslatisMac/Sources/TranslatisDiagnosticExportService.swift`：macOS-only 导出
  编排。主线程只取得保存位置与不可变环境快照，实际采集/脱敏/打包在 utility task
  中完成；通过绝对系统工具路径采集 unified log/代理摘要并用 `/usr/bin/ditto`
  生成 ZIP，最后以 owner-only 原子写入用户选择位置。
- `Apps/TranslatisMac/Sources/TranslatisChatScreen.swift`：Settings 最底部的导出卡片、
  `NSSavePanel` 和成功/部分成功/失败状态；
  `Apps/SharedResources/Localizable.xcstrings` 提供英文与简体中文文案。
- `Packages/IntatisCore/Tests/IntatisDiagnosticExportTests.swift`：原始正文、工具数据、
  credential、URL/路径/身份信息脱敏，尾部保留与 symlink 拒绝的回归测试。
- canonical session truth 仍是
  `~/Library/Application Support/Translatis/<session>/events.jsonl`；导出器只读它并生成
  `events.redacted.jsonl`。hang/crash/unified-log 是独立只读诊断源，原始文件不会被
  修改或删除；配置、auth、workspace、artifact 与浏览器目录不在采集地图中。

## 2026-08-02 Apple 应用图标资源

- 根目录 `Translatis.icon/` 是用户提供的 Apple Icon Composer 工程；
  `project.yml` 把它接入 `TranslatisMac` 与 `TranslatisiOS` 的 resources build phase，并以
  `ASSETCATALOG_COMPILER_APPICON_NAME=Translatis` 选择为主图标。
- macOS 构建把它编译为 `Translatis.icns` 与 `Assets.car`，iOS 构建把它编译为
  `Assets.car` 及 iPhone/iPad 主图标 PNG；generated `Info.plist` 分别注入平台所需的
  `CFBundleIconFile` / `CFBundleIconName`。源码树不保存额外导出的 `.icns` 或 PNG。

## 2026-07-28 replacement-history compaction

- `IntatisProtocol` 的 `ModelHistory.swift` / `Event.swift` / `Envelope.swift`
  定义 additive `model_history_compacted` checkpoint、typed replacement item
  和 real/contextual/summary 分类；`IntatisConversation/EventLog.swift` 提供
  complete-known replay 下的 per-agent CAS 与 WAL-safe durable append。
- `IntatisAgentKernel` 的 `AgentModelHistoryProjector.swift` 负责 checkpoint
  chain、coverage、provenance 与 suffix 恢复；`AgentModelHistoryCompactor.swift`
  负责 same-route summary；未知 replacement window 且无显式 token budget 时不
  注入 output ceiling，只有已知 usable window 或显式预算才派生并由 host 执行、
  leading trusted-prefix protection、adjacent call/output 裁剪与
  secret-like summary 拒绝的 summary-only 请求，以及最多 20k 且按 usable
  window 动态收缩的 real-user replacement；
  `AgentTokenEstimator.swift` 提供确定性近似预算，
  `AgentModelHistoryWindowID.swift` 生成 UUIDv7 lineage；`AgentLoop.swift`
  接通稳定 Code conversation / Cowork `@main` pre/mid-turn、每个下一请求 exact dynamic tool
  snapshot 的 freeze/measure/reuse、95% replacement postcondition 与
  durable-first swap。
- `IntatisProviders/AgentModelContextPolicy.swift` 从 exact profile metadata 解析
  context window；raw/max 均缺失时统一使用 1,000,000 token 产品缺省值，并计算
  90% auto / 95% usable threshold。`ProviderRegistry.swift` 为 Code 原子返回
  provider/model/policy，Cowork 从 frozen exact inference binding 取得相同
  policy。完整审计与边界记录在
  `codex-report/07_28_26-10_17-codex-skill-lifecycle-and-history-compaction.md`。

## 2026-07-26 独立 Web renderer parity 实验

- `Experiments/WebRendererParity/` 是 source-tree-only 的 React/Vite 渲染与 session-lifecycle 实验，带独立 npm lockfile、DOM/lifecycle tests、许可证扫描、README 与 native 接入评估。`src/renderer/` 实现 Markdown、bounded KaTeX/MathML 和 read-only CodeMirror；`src/session/` 提供 3 个合成 session fixture 与可取消的 30 秒 warm-residency store；`src/components/ConversationPane.tsx` / `ViewportMessage.tsx` 实现 newest-first 分页、exact-generation subtree replacement 和近视口 mount；`DiagnosticsPanel.tsx` 与 `window.rendererHarness` 提供无消息正文的生命周期计数。它不在 `Package.swift`、`project.yml`、`Makefile`、App target、Swift package 或 release resource graph 中。
- 生产 renderer 仍只有 `IntatisSharedUI` → `Vendor/SwiftStreamingMarkdown` / iosMath 与 `.plainSafe` 两条路径。本实验不能读取或替代 EventLog、session、permission、agent、workspace 或 credential 边界；后续若采用其行为，优先在既有 native renderer seam 内移植。

## 2026-07-23 UI 活跃状态接线

- `Packages/IntatisConversation/Sources/SessionActivityHistoryStore.swift` 是 app-facing recent-session recency projection：一次读取 EventLog，同时统计 event count，并 newest-first 查找 durable `turn_outcome`；只有 legacy session 回退 assistant/agent completion。file size/mtime 只作为 cache invalidation signature，`SessionHistoryStore` 的文件 mtime 不再是 UI 排序权威。
- `Apps/TranslatisMac/Sources/SessionRuntimeManager.swift` 继续持有 exact session runtime，并直接组合各 ViewModel 的 published data-plane activity，发布 active→idle 的低频 settlement；`TranslatisMacRootView.swift` 只重扫该 settlement 所属的 Chat / Code / Cowork 列表。macOS 与 iOS 的 `AppConfig` / `IOSConfig` 都通过 Conversation projection 取得同一排序，iOS 也在 Chat busy→idle 后刷新 history。
- `Packages/IntatisSharedUI/Sources/ThreadSurfaces.swift` 负责 composer 唯一主操作位的 Send↔native destructive Stop 切换，以及 phase-local `IntatisThinkingElapsedLabel`；Mac Chat、共享 Code / Cowork 接入同一 Stop 几何与取消入口。
- `Packages/IntatisSharedUI/Sources/IntatisTypography.swift` 是 macOS/iOS 共用的字体角色事实源：第一方英文统一使用 exact bundled JetBrains Mono 2.304，品牌、标题、正文、caption、metadata 与代码继续由同一组语义角色区分名义字号/字重；中文由 Apple Core Text CJK fallback 处理。iOS 在相同语义角色之上通过 `@ScaledMetric` 保留 Dynamic Type，并对 session/Settings large title 使用 iOS-only 22pt override。

## 目录结构总览

```text
Translatis/
├── .build/            SwiftPM 构建产物（gitignored）
├── .agents/skills/    项目级 Agent Skills；当前含 Translatis 翻译 Skills
├── .git/              Git 仓库（产品版本以 project.yml 为准；commit 标题只记录里程碑）
├── .gitattributes     LF 规范化
├── .gitignore         忽略 .build、Translatis.xcodeproj、dist、*.env、.translatis 本地运行/受管 worktree 状态
├── .swiftpm/          SwiftPM 缓存
├── AGENTS.md          项目常驻上下文与操作协议入口
├── Translatis.icon/   macOS/iOS 共用的 Apple Icon Composer 主图标源（由 Xcode 按平台编译）
├── Apps/              app target
│   ├── SharedResources/ macOS/iOS 共用 English + zh-Hans String Catalog
│   ├── TranslatisMac/    全量 macOS app（默认 DeveloperID/non-sandbox workbench）+ entitlements
│   ├── TranslatisiOS/    Chat-only iOS app（7-product 子集）
│   └── translatis-cli/   CLI
├── ARCHITECTURE.md    兼容入口；当前正文位于 docs/ARCHITECTURE.md
├── Experiments/       不接入生产 build graph 的独立实验；当前含 WebRendererParity
├── Makefile           build/test/release/install/app 便利 target
├── NOTICE.md          项目来源、当前上游采用状态 + 第三方依赖声明
├── ThirdPartyNotices/ OKF/Yams / Markdown / syntax / math / MCP SDK / tool_search / HTTP / Swift Crypto / Codex Runtime/Skill 采用声明
├── ThirdPartyPatches/ fixed upstream commit 可重放的最小源码patch；当前含Codex provider-body透传与strict OpenRouter request-shape派生
├── ThirdPartyStandards/ byte-exact 第三方标准；当前含 Open Knowledge Format v0.2
├── Vendor/            仓内维护的第三方派生源码
│   ├── SwiftStreamingMarkdown/ Microsoft v0.6.0 thin derivative
│   └── MCPClientSDK/  官方 Swift MCP SDK 0.12.1 的 client-only derivative + upstream/patch ledger
├── Package.swift      SwiftPM manifest（16 public libraries + 3 internal C targets + CLI + 16 tests + dev conformance executable）
├── Packages/          Intatis Swift/C targets
│   ├── IntatisKnowledge/ OKF/Profile、build/validation/snapshot、embedding/rerank、KnowledgeLease 与 build/search tools
│   ├── IntatisSkills/ Code/Cowork Skill discovery、snapshot、catalog、产品内置 Cowork 调度 Skill 与专用只读 tools
│   ├── IntatisMCP/    外部 MCP client core、HTTP/OAuth、catalog/content/callback/tasks 与 tests
│   ├── IntatisMCPStdio/ 本地 stdio owner、sandbox/network/exec guard
│   ├── IntatisCodexRuntime/ 官方 Codex App Server 的最薄 Swift process/JSON-RPC/session host + tests
│   ├── IntatisCurlTransport/ libcurl C boundary
│   └── IntatisMCPConformanceClient/ 仅开发期 official/extended client conformance driver
├── README.md          Intatis readme
├── Tests/
│   ├── MCPConformance/ pinned official 0.1.16 + Intatis task interoperability + W10 runner
│   └── MCPBM25ParityOracle/ 不进入产品图的 Codex BM25 Rust 差分 oracle
├── scripts/
│   └── validate-linux-cli.sh 双架构 musl 静态 CLI 交叉构建 gate
├── docs/              项目状态/架构/测试/禁区说明 + Cowork 设计文档
└── project.yml        XcodeGen spec（生成 Translatis.xcodeproj）
```

## Target / 模块

### Intatis public library products（17）+ internal C targets（3）

| Target | 类型 | 依赖 | 职责 |
|---|---|---|---|
| `IntatisCore` | lib | — | 类型化 ID、错误、工作区路径约束、平台能力信封、单次安装且不可中途切换的`IntatisHostApplicationIdentity`产品命名派生、会话类型、`SessionHistoryStore`、无 bookmark 且按 SessionKind 隔离的 app-global `ProjectFolderStore` 分组目录、session-owned `SessionWorkspaceAccessStore`、进程级低开销 performance diagnostics 与 owner-only bounded hang bundle |
| `IntatisProtocol` | lib | Core | 结构化事件/线协议词汇（Event/Envelope/JSONRPC/Command/CoworkEvents/Goal/WorkTask/ContinuationRun/TaskGoalEvents/ModelHistory/SessionStateEvents/InferenceProfile/PermissionIntent/PermissionReview/ToolAuthorization/ToolExecution/MultimodalEvents/TurnStats/MessageCitation/JSONValue） |
| `IntatisProviders` | lib | Core, Protocol | OpenAI-compatible 模型访问、当前 exact Chat route 的 `hosted_web_search` capability/planner、OpenAI `web_search` 与 OpenRouter `openrouter:web_search` dialect encoder、Chat `tool_choice:auto`/typed same-route ordinary fallback，以及shipping Agent `tool_choice:required`/fail-closed hosted-search provider service和将App Server Responses route与同一exact配置optional search route共同冻结的`codexRuntimeRoute`、shipping Chat/Code/Cowork/CLI共用的host-owned图片generation/edit service、结构化 URL citations、bounded/secret-aware `ChatConfigurationImporter`、OpenCode-shaped npm package adapter selection/lowering、Chat/Code lossless model options、Cowork 显式 durable-options schema、exact per-agent inference catalog/resolver 与只读配置展示投影（ProviderRequestAdapter/ProviderRegistry/InferenceCatalog/InferenceCatalogStore/Capability/Endpoints/ChatProvider/OpenAIWireProvider/OpenAIToolCalling/ChatConfigurationImport/ModelConfigurationPresentation/SSE/HTTPDataClient/ImageGeneration/Transcription/VideoGeneration/ToolCalling） |
| `IntatisArtifacts` | lib | Core, Protocol | 文件-backed blob 存储 + JSON 索引；`ArtifactImageResolver` 对 exact ArtifactID 执行 owner-only/no-follow 有界读取、PNG/JPEG 完整解码、尺寸/像素/批量限制与 SHA-256 验证，provider data URL 只在当次 request 生成 |
| `IntatisConversation` | lib | Core, Protocol, Providers, Artifacts | 事件溯源会话 + UI 投影（跨进程锁定、multi-event WAL 与 checked replay 的 EventLog JSONL / schema-v2 `SessionProjectionStore` / 无本地工具且可冻结托管 web-search 请求与 citation 的 ChatLoop / Chat-only `ChatSessionAutoTitle` 隐藏无工具请求、exact route + completed seq 冻结前缀、严格前三 completed 回合投影、single-flight/timeout/stream-start attempt 与 set-if-absent rename / GoalInputParser / Projection / CodeProjection typed per-agent index 与选中 agent 完整连续 Cowork snapshot / Cowork live roster + EventLog-derived historical identity roster / settings/Goal/WorkTask/ContinuationRun/tool-execution recovery projection / TurnStatsProjection / `SessionProjectionPump` 逐 seq exact fold、50 ms delta publication、agent-scoped publication、non-delta barrier 与 session/generation/throughSeq fence） |
| `IntatisPTYLauncher` | internal C helper | libc / macOS `forkpty` | 为 managed terminal 建立真实 controlling PTY；child 在 fork 后只执行 C/POSIX signal/FD/chdir/exec，CLOEXEC error pipe 把启动错误返回父进程；非 macOS 返回不支持 |
| `IntatisTools` | lib | Core, Protocol, PTYLauncher | 哑工具执行器与 task/goal host 接口（ToolProtocol/TaskGoalManagement/FileTools/PatchTool/PathConfinement/ShellGit/TerminalTools/DocumentMediaTools/DocumentTools/DocumentToolContracts/ExactDocumentTools/DocumentInfrastructure/DocumentPythonBackend/DocumentFixedBackends/PDFNativeDocumentService/HTMLDocumentPDFRenderer/BrowserTools/HostedWebSearchTool）；`HostedWebSearchTool` 只有 strict `query` 并依赖 host-bound provider service，与 BrowserTools 分流；`ToolRegistration` / `ToolRegistry` 是 schema、concrete tool、canonical permission、lease resolver、semantic preview 与 executor 的单一事实源；文档与浏览器各使用 typed fixed-backend runner，在 spawn 前完成 WorkspaceLease/touched-path preflight，与 generic shell 分流 |
| `IntatisKnowledge` | lib（non-iOS product） | Core, Protocol, Tools, Providers, Permission, Yams；Linux 条件链接 Crypto | 固定 OKF v0.2 上的 Intatis RAG Profile、strict schemas、canonical writer、deterministic Validator/receipt、build/publish、immutable snapshots、dense/BM25/RRF、source-locator/final grounding；另含 configured provider bridge、exact `KnowledgeLease`/external authority、session bookmark store，以及 host-validated closed-schema path-aware `build_knowledge` / required-semantic-rerank `search_knowledge` host；只经 generic HostToolRegistryAugmenter opt in，不进入 Chat/iOS |
| `IntatisSkills` | lib | Core, Protocol, Tools, Permission | Code/Cowork 的 Codex-like Skill context capability：受限 root discovery、frontmatter 校验、exact-model 自适应 developer catalog、每次 AgentInvocation 的 immutable snapshot、无歧义 `$name` user fragment、严格 `agents/openai.yaml` MCP dependency preflight、随产品 resource bundle 发布的 system-scope `cowork-agent-orchestration`，以及只读 frozen `activate_skill` / `read_skill_resource` tools；不授予文件、shell、网络、通信或委派权限 |
| `IntatisPermission` | lib | Core, Protocol, Providers | 3 层权限门（PermissionTypes/PermissionEngine/DeterministicPolicyGate/ModelPermissionReviewer/SecretScanner） |
| `IntatisCurlTransport` | internal C target | system/SDK libcurl | MCP Streamable HTTP 的 native socket-binding boundary；Darwin 链系统 libcurl，Linux 静态 CLI 链官方 Static Linux SDK closure；iOS 不链接 |
| `IntatisMCP` | lib | Core, Protocol, Tools, MCPClientSDK, CurlTransport(macOS/Linux), Crypto(Linux) | 外部 MCP Server 的 client-only core：配置/import/catalog、authority/session runtime、Streamable HTTP/OAuth、protocol negotiation、tools/resources/prompts/completions/roots、sampling/elicitation、logging/progress/cancel/subscription、tasks、输出安全与可靠性；无 Server target/API/product seam |
| `IntatisMCPStdioGuard` | internal C target | libc/kernel API | Linux stdio 后代 exec/network 的 seccomp/ptrace guard；Apple 平台为空实现，不进入 portable client core |
| `IntatisMCPStdio` | lib | MCP, Core, Protocol, Tools, MCPClientSDK, StdioGuard, Crypto(Linux) | 本地 MCP stdio process ownership：exact launch artifact、direct exec/pipe、Seatbelt 或 Linux bwrap+guard、exact network gateway、TERM→KILL/drain；独立 linkage 隔离 portable client core 与本地进程 ownership |
| `IntatisCodexRuntime` | lib | Core, Protocol, Providers, Tools, Permission, Conversation, Skills, MCP | derived `codex app-server` 0.145.0-intatis.4 external-runtime host：exact executable/version、isolated CODEX_HOME、Responses provider/model catalog与opaque body.provider、显式OpenRouter optional-field收窄、stdio JSON-RPC、thread/turn/item/approval/Goal、verified descendant roster/history/native message、owner-only ThreadID/toolset mapping、host-approved custom-agent/workspace presets、official Skill discovery与`skills/extraRoots/set`，以及official `dynamicTools`→73项文档/浏览器/图片、条件式exact-route hosted search、可选Knowledge/WorkTask/当前session rename registry的薄client executor。另有presentation-agnostic `requestUserInputHandler`：非nil时在现有单一Code/Cowork流启用official structured-question function，按exact root/verified-child request identity回传answer并把启用位计入persisted toolset identity；nil明确关闭。macOS Code/Cowork已注入handler，CLI仍为nil。hosted search使用host-only root/child-role scope与独立lease，不启用Codex built-in web search或fallback。Code/Cowork exact root可把durable HTTP MCP authority投影为native `[mcp_servers]`，secret只进process env，Cowork child通过official role/resume config完整禁用。旧runtime/toolset不迁移，不实现agent core/MCP core/agent manager，非iOS |
| `IntatisAgentKernel` | lib（legacy/manual rollback） | Core, Protocol, Providers, Tools, Permission, Conversation, Artifacts, MCP, Skills | 原共享 headless AgentRuntime/AgentLoop 与兼容测试仍在仓内；Code/Cowork/CLI shipping入口不可调用，不得作为 Codex失败 fallback |
| `IntatisCowork` | lib（Codex product metadata + legacy/manual rollback） | Core, Protocol, Providers, Tools, Permission, Conversation, AgentKernel, Skills | shipping `CodexWorkTaskController`/`task_link_agent`只维护卡片DAG与verified child关联；原 Orchestrator/AgentScheduler/MessageBus/Mediator/Goal控制面仅保留兼容测试/手工源码回退。新 Cowork turn、child、通信和Goal由 Codex root/subagent runtime执行，旧 orchestrator start/send不可调用 |
| `IntatisMultimodal` | lib | Core, Protocol, Providers, Artifacts, Conversation | 图像/视频/转写 → artifacts |
| `IntatisSharedUI` | lib | Core, Protocol, Providers, Conversation, Artifacts, `Vendor/SwiftStreamingMarkdown` thin derivative（Microsoft v0.6.0 basis；传递 exact iosMath 2.5.0，仅 iOS/macOS） | 跨平台 SwiftUI；自身 resource bundle 分发两份 exact JetBrains Mono product TTF，使两端 App 与 tests 使用同一 `Bundle.module`。`ComposerAttachments.swift` 提供 Chat/Code/Cowork 共用的 security-scoped 文件读取、ArtifactStore 保存/读回校验与 image MIME provider 解析，其中PNG/JPEG扩展使用确定性canonical MIME映射、其他格式才查询系统type database，不把 base64 写入 EventLog。`MessageRendering` 以 `.microsoft` / `.plainSafe` 做产品熔断，rich 结构/原生布局与 code-aware `$...$` / `\(...\)` inline、`$$...$$` / `\[...\]` display 公式由经审计的 Microsoft 派生包负责；iosMath 只提供 Apple-native TeX parse/layout，plain-safe 完全绕开二者。公式通过两平台 TextKit 2 live `MTMathUILabel` attachment 以 intrinsic size 展示，不设公式数量、单式字节或固定附件尺寸上限；semantic appearance 与 Dynamic Type revision 控制更新，不保留 raster cache。Intatis 只做语法无关的 64 KiB whole-message admission、process-wide 1-running/32-pending latest-only Markdown parse permits、每 view 最新 raw revision、50 ms incomplete parse debounce、100 ms fixed-window raw leading/trailing projection、stale publication guard与安全链接；window-local scroll coordinator 保持 geometry observation-only、100 ms follow cadence、one-shot rich settle 与每行 150 ms viewport dwell。macOS Chat/Code/Cowork和共享iOS Chat的 transcript 都通过 `IntatisContinuousThreadStack` 展示完整连续时间线，并以最多 16 个 active rich rows 的 viewport budget；Cowork 另由 window-local `CoworkAgentThreadPresentationModel` 管理 historical agent selection/generation/per-agent continuous snapshot，固定 ScrollView 与 visibility-coalesced rich eviction，以 selection/content 300 ms quiet gate 阻止切换或持续增量反复挂载 AppKit rich subtree，并用 stable-ID lazy Agents rail 承载 detached identity。vendored AppKit paragraph 使用 proposal-owned exact width 和 one-entry measurement memo；macOS `DocumentView` 另以一个 coordinator 将 heading/paragraph/list/quote/table/code native leaves 连接成可直接拖拽的单消息选区，iOS 路径不变。`ExecutionTracePresentation.swift` 另在 Code/Cowork 展示边界默认隐藏 verbose tool/patch/note trace 和由 `CodeProjection` 标记的同-task exact `task_completed` 回答镜像，同时保留 `.agentToAgent` 的媒介化 agent 通信；后台启动参数/环境变量仍可 opt in 恢复完整 trace。它不改变 EventLog 或 durable task settlement。当前仍不分发语法高亮或远程 Markdown 图片 |
| `IntatisCoworkUI` | lib（macOS消费面） | Core, Protocol, Conversation, SharedUI | presentation-only完整Cowork右侧content；公开state/bindings/actions/thread source，绘制模型选择、composer、permission、Agents/Goal/Tasks/Inspector/retry，不拥有runtime/session/provider/workspace/MCP/permission engine/dynamic tools。TranslatisMac和其他宿主各自保留原owner并做薄映射 |

`IntatisMCPConformanceClient` 是只供固定 conformance runner 启动的开发期 executable，不是发行 product，也不是 MCP Server。

### App / executable target

| Target | 类型 | 平台 | Bundle ID | 链接 |
|---|---|---|---|---|
| `TranslatisMac` | application | macOS 26+ | `com.Vita0818.TranslatisMac` | Chat 保持 Swift ChatLoop；Code/Cowork链接 `IntatisCodexRuntime`，使用exact Responses route驱动官方App Server；Cowork App层继续拥有ViewModel/runtime/session并把状态与actions映射给presentation-only `IntatisCoworkUI`。fresh Code注册73个第一方文档/浏览器/图片functions + `rename_session`，fresh Cowork再注册5个WorkTask functions，配置Knowledge时再加入build/search；root或任一child exact route明确支持时，共享surface另加`hosted_web_search`。图片与搜索工具分别直接注入既有host-owned provider service；搜索按root/role exact route分流，read-only或unsupported child无authority。Cowork child roster、逐agent history、完整route/workspace preset、permission来源、WorkTask card、thread Goal、native message、root/child Knowledge、native Skills与root首任务自动改名已接通；Code/Cowork root Streamable HTTP MCP走native config，Cowork child原生disabled，无legacy fallback。DeveloperID direct-distribution；当前安装预览缺少Codex/Document/Browser三套runtime，不能作为独立功能包 |
| `TranslatisiOS` | application | iOS 26+ | `com.Vita0818.Translatis` | 7 个 chat 子集 products；iOS root 在唯一原生 `NavigationStack` 内组合 Chat canvas、顶部 sidebar/session/new、82% 的 `Translatis`/Chat/Recent/New/Settings 抽屉与两排 composer（model/usage；paperclip/input/voice/Send-or-Stop）；第一方英文统一使用 JetBrains Mono，标题/正文/控件继续由语义字号与字重区分，中文使用 Apple CJK fallback；Settings 支持系统 Files 导入 Translatis JSON/JSONC；根 `Translatis.icon` 编译为 iPhone/iPad 主图标；与 macOS 共用当前 exact-route hosted-search planner和 Chat-only 自动命名协调器，并通过 per-session revision/seq metadata relay 即时更新对应标题；无可见搜索 UI并支持结构化 citations；通用照片/文件附件尚未接通；无 `IntatisKnowledge`/MCP client runtime/transport/product surface，也无 Tools/Permission/AgentKernel/Cowork |
| `translatis-cli` | executable | CLI（macOS/Linux） | — | Chat 保持 ChatLoop；Code/Cowork进入`CodexRuntimeCLI`与同一App Server host。文字turn、stream、approval、cancel、Goal、73个document/browser/image dynamic functions、条件式exact-route `hosted_web_search`、root/child可选Knowledge、native Skills、当前session rename、Cowork WorkTask、真实child list/history/archive/message和配置文件来源的safe inference presets可用；图片与搜索都走既有host-owned service，搜索不支持时不发布或按共享surface在provider前拒绝。`/mcp`管理exact authority，Code/Cowork root重启后应用native HTTP MCP，Cowork child原生disabled。CLI attachment、`/clear`和旧`translatis exec`明确不可用。missing/mismatched runtime/toolset不回退旧REPL |

Chat 托管搜索的用户确认合同见 `docs/CHAT_HOSTED_SEARCH.md`。目标 runtime 只有当前所选 exact
Chat route；`web_search_model` 旧字段可兼容 decode/preserve，但不参与路由或产生提示。
`IntatisSharedUI/ChatViewModel.send()` 与 CLI Chat 调用 `ProviderRegistry.chatRuntimeRoute()`，后者从
当前 endpoint/model 的普通 adapter、`hosted_web_search` capability 与 exact dialect 原子规划
`ChatLoop.webSearch`。`OpenAIWireProvider` 分别编码 OpenAI/OpenRouter tool type；未规划搜索时只生成
普通 `/chat/completions` 请求。

Code/Cowork 的显式legacy包装位于 `Packages/IntatisTools/Sources/HostedWebSearchTool.swift` 与
`Packages/IntatisAgentKernel/Sources/ProviderHostedWebSearchToolService.swift`。它复用 exact agent
route，使用 required hosted-search request，且只经 `ToolRegistry` / `ToolCapability.hostedWebSearch` /
权限与 durable executor 链出现；不会转发到 `BrowserTools.swift`、MCP 或隐藏搜索模型。当前
`CodexBusinessToolHost`未注册该包装，所以上述文件是未来official dynamicTools重新接线输入，不是shipping
availability。

### 测试 target（17）

`IntatisCoreTests`、`IntatisProtocolTests`（+V02/V03/V04/InferenceProfile/MCP events/results）、`IntatisProvidersTests`、`IntatisArtifactsTests`、`IntatisConversationTests`、`IntatisToolsTests`、`IntatisKnowledgeTests`、`IntatisSkillsTests`、`IntatisPermissionTests`、`IntatisMCPTests`、`IntatisCodexRuntimeTests`、`TranslatisCLITests`、`IntatisAgentKernelTests`、`IntatisCoworkTests`、`IntatisMultimodalTests`、`IntatisSharedUITests`、`IntatisCoworkUITests`。`swift test` 无头；official/extended MCP conformance 另由 `Tests/MCPConformance/` 驱动开发期 executable。

## 关键文件

- Chat/Code/Cowork 滚动与 hang 诊断：
  `Packages/IntatisConversation/Sources/SessionProjectionPump.swift`
  （ordered fold / agent-scoped publication / selected-agent continuous snapshot query / commit fence）；
  `Packages/IntatisConversation/Sources/CodeProjection.swift`
  （typed per-agent all/visible index 与完整连续snapshot）；
  `Packages/IntatisSharedUI/Sources/ThreadSurfaces.swift`
  （三种macOS产品共用的window-local follow state、scope/generation、geometry observation、100 ms
  cadence、rich settle、viewport admission，以及generation-checked/no-op-aware的16-row visibility budget）；
  `Packages/IntatisSharedUI/Sources/MessageRendering/IntatisMessageContentView.swift`
  （per-row 150 ms exact-revision dwell）；
  `Packages/IntatisSharedUI/Sources/CoworkAgentThreadPresentationModel.swift`
  （window-local selection、per-agent continuous snapshot、stale generation、single in-flight + latest follow-up
  snapshot load、300 ms rich quiet gate）；
  `Apps/TranslatisMac/Sources/TranslatisChatScreen.swift`
  （通过SharedUI lifecycle seam接入session-specific bottom anchor与同一scroll coordinator，不使用逐token
  ownerless main-queue animation）；
  `Packages/IntatisSharedUI/Sources/Views.swift`与`Apps/TranslatisiOS/Sources/TranslatisiOSApp.swift`
  （共享Chat壳使用同一continuous stack/16-row budget/scroll coordinator，iOS宿主传入exact session scope）；
  `Apps/TranslatisMac/Sources/CoworkAgentConversationFixtureView.swift`
  （Debug-only 8 × 1,000 rows / 500 delta/s / rapid + soak 验收入口；可由启动参数或专用
  `.CoworkAgentConversationFixture` bundle identifier suffix 激活）；
  `Packages/IntatisCore/Sources/IntatisHangDiagnostics.swift`、
  `Apps/TranslatisMac/Sources/TranslatisProcessDiagnostics.swift` 与
  `Apps/translatis-cli/Sources/HangDiagnosticsCommand.swift`
  （heartbeat/signpost/bounded bundle/进程外采样入口）；vendored
  `ParagraphView+macOS.swift` / `ParagraphNSView.swift`
  （单一 width owner 与 one-entry exact-width measurement）。

以下详细条目中的 AgentKernel/Orchestrator/PermissionEngine/Knowledge/MCP execution path 记录仓内
legacy/manual-rollback源码与兼容测试；除Codex Runtime接线地图明确列出的部分外，不代表当前
Code/Cowork shipping turn仍可调用它们。特别是类型、descriptor、provider service或focused test存在，
不能替代production入口与authoritative dynamic tool list的可达性证明。

- 入口：`Apps/TranslatisMac/Sources/TranslatisMacApp.swift`、`Apps/TranslatisiOS/Sources/TranslatisiOSApp.swift`、`Apps/translatis-cli/Sources/TranslatisCLI.swift`
- Skills：`Packages/IntatisSkills/Sources/SkillTypes.swift`（root/limit/metadata/snapshot、Codex Core-style 2%/8k catalog budget、count-only metrics/mention）、`BundledSkills.swift`（SwiftPM `Bundle.module` 内产品 Skill roots）、`SkillCatalogService.swift`（canonical discovery、frontmatter、no-follow bounded freeze）、`SkillMCPDependencies.swift`（严格 `agents/openai.yaml` MCP-only metadata 与 locator fingerprint）、`SkillTools.swift`（snapshot-bound dynamic tools、request-owned MCP preflight、registry revision）；`Packages/IntatisSkills/Resources/BundledSkills/cowork-agent-orchestration/` 保存 coordinator 的主动执行循环、调度正文与按需读取的 dated model-routing reference（capability hard gate、新 generation preference、cost modes、multimodal companion、11-provider 正式 recommendation matrix）。`Packages/IntatisCowork/Sources/Orchestrator.swift` 的 runtime-only `InferenceProfileRoutingMetadata` 与 `list_inference_profiles` 把 macOS/CLI 用户 JSON 已声明 capability 安全投影给 coordinator，不进入 EventLog/binding。`Packages/IntatisTools/Sources/MCPToolAvailabilitySnapshot.swift` 冻结不披露 endpoint/command 的 exact server/tool/dependency host assertion，`Packages/IntatisAgentKernel/Sources/AgentRequestToolSnapshot.swift` 把它与同一 provider request 的 dynamic registry/specs 绑定，`MCPEventLogHostAdapters.swift` 只从 capability/policy-filtered agent-visible tool entries 派生 production assertion（每个 server 至少一个可见 tool）。`ContextBuilder.swift` 负责 system → developer catalog → history/context → explicit user Skill → current user 的角色排序，要求 coordinator 先建立 execution objective、检查/激活明确相关的 exact Skills、为非简单工作维护最小 WorkTask 图并尽早委派有收益的分支，同时继续自己的关键路径；请求真实暴露 `spawn_agent` 时，外部目录工作还必须从直接越界重试改路由为目录绑定子 agent + `delegate_task`。Code hosts 与 `Orchestrator.run` 负责每次 send/invocation 的独立冻结。
- 项目级 Skill：`.agents/skills/intatis-skill-creator/` 是面向 Intatis
  Code/Cowork 的创建与验证 Skill，含 `SKILL.md`、两个 reference 和三个
  Python 标准库 helper；以独立名称避免与
  `$CODEX_HOME/skills/.system/skill-creator` 歧义。固定上游、修改与许可证见
  `ThirdPartyNotices/OpenAICodexSkillCreator.md`。
- App 本地化：`Apps/SharedResources/Localizable.xcstrings` 由 `project.yml` 同时加入 TranslatisMac / TranslatisiOS 主 bundle，source/development language 为 English，支持 `en` / `zh-Hans`；`Packages/IntatisSharedUI/Sources/IntatisLocalization.swift` 为普通 `String` 展示值提供 `Bundle.main` 查表与 English fallback。iOS 系统设置页另读 `Apps/TranslatisiOS/Resources/Settings.bundle/{en,zh-Hans}.lproj/Root.strings`；两端生成式 Info.plist 的麦克风说明分别读 `Apps/TranslatisMac/Resources/{en,zh-Hans}.lproj/InfoPlist.strings` 与 `Apps/TranslatisiOS/Resources/{en,zh-Hans}.lproj/InfoPlist.strings`。语言由系统/App Language 在启动时选择，不持久化 Translatis 自有语言偏好。
- Per-agent inference profile：`Packages/IntatisCore/Sources/IDs.swift`（profile/connection exact ID + revision）、`Packages/IntatisProtocol/Sources/InferenceProfile.swift`（safe `AgentInferenceBinding`）、`Packages/IntatisProviders/Sources/InferenceCatalog.swift`（immutable connection/profile definitions、top-level显式allowlist + provider子树opaque/secret-scanned/bounded的durable-options schema、reconcile、含 safe route/trust/egress 的 exact resolve）、`InferenceCatalogStore.swift`（owner-only versioned store、corruption/schema/permission fail closed、稳定 sidecar 上的进程内 + Darwin/Linux 跨进程独占锁、锁内 revision allocation、原子替换）、`ProviderRegistry.swift`（同一 resolution 原子返回 binding/model/provider；当前只实例化 OpenAI-compatible wire）、`ProviderURLSession.swift`（provider traffic 禁止 HTTP redirect）、`OpenAIWireProvider.swift` / `OpenAIToolCalling.swift`（所有 Chat/Agent request 移除 config `stream_options`/多候选字段并固定 `n = 1`）、`Packages/IntatisAgentKernel/Sources/Agent.swift` 与 `Packages/IntatisProtocol/Sources/{Task,CoworkEvents,TurnStats,ToolAuthorization}.swift`（additive optional binding/frozen invocation/安全归因；diagnostic URL + secret redaction）、`Packages/IntatisCowork/Sources/Orchestrator.swift`（strict attach/restore/invocation、只接受 atomic resolved tuple 的 shipping runtime、host-approved explicit profile、exact spawn inheritance、delegate target snapshot、catalog update/admission lock、resolver suspension 后 revalidation、GUI local-admission/execution-readiness split、CLI control-plane startup gate 与 unresolved-worker invocation isolation、host-only idle durable rebind、next-main submission/live-binding root admission guard）。完整契约见 `docs/PER_AGENT_INFERENCE_PROFILES.md`。
- Cowork 链路：`Packages/IntatisCowork/Sources/Orchestrator.swift`（生产 `runtime` session writer lease、fresh empty session 固定 `@main` restricted bootstrap admission + admission-wait 后 exact profile/empty-session recheck、普通 reviewed attach + allow 后 catalog snapshot/exact profile revalidation、真实 root AgentInvocation、Session-scoped WorkTask manager 与 optional invocation binding、exact RunID in-flight close tombstone + durable first-write claim/pre-wait fence/drain/restore、`delegate_task` exact attached-target preflight + pure mediation + 单 EventLog admission batch、单审批 `spawn_agent` admission batch、permission reviewer 逐 generation exact provider factory、bounded scheduler/watchdog、non-replayable crash guard、durable-first detach/revoke、恢复/取消/超时/重试、mailbox wake、lease lifecycle、Task Report、idle recycle）、`RunControlTools.swift`（只对 exact `@main` root 暴露 host-bound `finish_run` / `stop_run`）、`GoalRuntimeController.swift`（普通 turn run scope、host-only durable Goal create/edit/pause/resume/clear、host continuation、scheduler barrier、checkpoint/recovery、active Run 中断结算、显式 Resume 新建 Run、budget/usage/no-progress/blocked policy）、`AgentScheduler.swift`（queue/claim/single-flight/snapshot/mailbox）、`WorkTaskTools.swift`（`task_create/update/get/list`）、`GoalTools.swift`（模型只读/提交验证候选的 `get_goal/update_goal`）、`GoalVerifierControlPlane.swift`（独立 no-tools Goal audit，不以 WorkTask 终态作为 completion authority）、`AgentPermissionResponder.swift`（普通 automatic tool 的 bound-invocation 协议，以及仅供 Orchestrator 使用的 host-agent-admission 入口）、`PermissionReviewControlPlane.swift`（reviewer 独立 FIFO/single-flight/timeout/soft usage warning/typed allow-deny failure、request generation、首 terminal/late-result guard、fresh-provider recovery）、`CommunicationDelegationTools.swift`（只含 send/request/reply 与 `delegate_task`，无请求委派工具）、`CoordinatorTools.swift`（`spawn_agent` 无 raw model 参数，只接受可选 approved profile ID）、`MessageBus.swift`、`Mediator.swift`、`AskAgentTool.swift`
- Cowork 独立协议/投影：`Packages/IntatisProtocol/Sources/Goal.swift`（durable user objective + audit）、`WorkTask.swift`（当前 Session 可见计划节点 + revision/DAG/agent-reported evidence，不含 Run/Goal/agent owner）、`ContinuationRun.swift`（host continuation checkpoint + terminal `interrupted`）、`TaskGoalEvents.swift`（各自追加事件与 `ContinuationRunCloseRequestedPayload`）、`Task.swift` / `TaskGraph.swift`（保留的 AgentInvocation execution layer 与可选 Goal/run/WorkTask binding）、`CoworkEvents.swift`（mailbox consumed/discarded 生命周期与 additive `conversationID` / `basedOn` correlation）、`Leases.swift`（含 main-only `controlRun`）、`PermissionIntent.swift`、`Event.swift` / `Envelope.swift`；`Packages/IntatisConversation/Sources/CoworkProjection.swift` 分别折叠 Goal、Session WorkTask、ContinuationRun close claim、执行任务、agent roster、mailbox、report/attempt/retry 与未决 tool execution，`EventLog.swift` 负责 append-only replay、cross-process flock、multi-event WAL/父目录同步、session identity/known payload checked replay、run-close first-write CAS、session writer lease 与 crash-tail 防护。
- Mailbox/turn settlement：`Packages/IntatisProtocol/Sources/Task.swift` 的 optional additive `mailboxMessageIDs` 冻结 exact delivery identity；information request/reply 用 fresh RequestID、stable conversation root、`inReplyTo` 与 `basedOn` 表达多轮 correlation；`Packages/IntatisAgentKernel/Sources/AgentLoop.swift` 将普通工具错误结算为 model-visible failed observation，不再把 denied/failed call 登记为副作用完成债务，并在 provider 正常 final 时原子提交 final terminal；`ContextProjection.swift` / `ContextBuilder.swift` 负责 exact mailbox 投影与 no-ACK/fresh-follow-up 提示。
- Agent 内核：`Packages/IntatisAgentKernel/Sources/AgentRuntime.swift`（Code/Cowork 共用 headless runtime）、`AgentLoop.swift`（stable history、用户/FCO 图片的 canonical append-return 物化、pre/mid-turn compaction、授权与 durable tool ticket）、`AgentImageResolution.swift`（model ref 与 verified artifact 逐字段绑定）、`AgentToolOutputLowering.swift`（structured-result 唯一 canonical text + source-order image refs）、`AgentModelHistoryProjector.swift`（strict v1/v2 direct/checkpoint、等长 media sidecar、lineage/provenance/coverage/suffix 恢复）、`AgentModelHistoryCompactor.swift`（summarizer 看完整 active media window、summary-only checkpoint）、`AgentTokenEstimator.swift`（确定性预算与每图 4096 charge）、`AgentModelHistoryWindowID.swift`、`AgentThreadHistoryProjector.swift`、`EventLogSessionNamingService.swift`、`AgentExecutionBudget.swift`、`Agent.swift`、`ContextBuilder.swift`、`ContextProjection.swift`、`PermissionResponder.swift`、`ProviderImageGenerationToolService.swift`
- Mailbox runtime：`Packages/IntatisCowork/Sources/Orchestrator.swift` 的 message admission/wake/retry/restore 路径按 exact MessageID 去重并保留同 TaskID bounded attempts；专用 preparation 只按 ordinary one-way、information request reply-only、information reply fresh-request-only 三类生成窄 lease，全部无 delegation grant；一个 RequestID 只接受一个 terminal reply，实质 follow-up 必须 fresh RequestID + `basedOn`，receipt 不 ACK；successful task terminal、candidate WorkTask progress 与 consumed events 单批提交，runtime ack 在后。`WorkTaskTools.swift` 提供 task create/update 的 bounded semantic permission preview，以及 WorkTask/AgentInvocation ID namespace 和 latest-revision 引导。
- 稳定 Code conversation / Cowork `@main` 模型历史协议与回归：`Packages/IntatisProtocol/Sources/ModelHistory.swift`、`Event.swift`、`Envelope.swift`；`Packages/IntatisConversation/Tests/ModelHistoryCompactionEventLogTests.swift`；`Packages/IntatisAgentKernel/Tests/ModelHistoryProjectionTests.swift`、`AgentModelHistoryCompactorTests.swift`、`ModelHistoryCompactionAgentLoopTests.swift`、`CodeModelHistoryCompactionTests.swift`、`SkillDurableActivationTests.swift`，并与 `SubmittedIntentHistoryTests.swift`、`ContextProjectionTests.swift` 和 Cowork main continuity / worker isolation 回归组合运行。
- `model_history_item` / `model_history_compacted` 展示边界：`Packages/IntatisConversation/Sources/Projection.swift`、`CodeProjection.swift`、`CoworkProjection.swift` 对这两个 provider-facing event 执行 no-op；用户可见消息仍来自原消息事件，不会因恢复事实链多渲染一份 assistant/tool 气泡。
- Cowork 编排可靠性回归：`Packages/IntatisCowork/Tests/OrchestrationReliabilityTests.swift`、`SchedulerMailboxTests.swift`、`TaskGraphSchedulerIntegrationTests.swift`、`ToolRegistryLeaseTests.swift`、`PermissionReviewControlPlaneTests.swift`、`AutomaticPermissionReviewTests.swift`、`AgentInvocationNonRecursiveTests.swift`、`SpawnAgentPermissionTests.swift`；per-agent inference 回归：`Packages/IntatisProtocol/Tests/InferenceProfileProtocolTests.swift`、`Packages/IntatisProviders/Tests/InferenceCatalogTests.swift`（durable schema 与 safe route/trust/egress mismatch）、`IntatisProvidersTests.swift` / `InferenceCatalogStoreResolverTests.swift`（unconditional single-candidate request clamp 与 HTTP redirect no-follow；后者另含 32 个并发 reconciler 的 revision 保留/无碰撞，以及 lock owner/权限/符号链接/普通单链接校验）、`Packages/IntatisCowork/Tests/PerAgentInferenceProfileTests.swift`（attach review-await / bootstrap admission-wait exact revalidation、catalog mutation、suspended resolver、rebind/spawn TOCTOU、recovered worker frozen/live mismatch 在 provider 前 durable failure）、`Packages/IntatisSharedUI/Tests/CoworkInferencePresentationTests.swift`；CLI offline coverage 在 `Apps/translatis-cli/Sources/SelfTest.swift` 验证 multi-route/model/variant、旧 revision、route-scoped credentials、unique-model route 与 reasoning mismatch；explicit restore-main 当前由 `Interactive.swift` command boundary 承担，最终 CLI recovery smoke 以 `docs/TESTING.md` 为准；`Packages/IntatisProtocol/Tests/PermissionReviewProtocolTests.swift` 覆盖 diagnostic complete-URL redaction；authorization wire/compatibility 也由该 suite 覆盖；Goal/WorkTask runtime：`WorkTaskRuntimeTests.swift`、`GoalManagerRuntimeTests.swift`、`GoalVerifierControlPlaneTests.swift`、`GoalRuntimeControllerTests.swift`；Agent completion/lease/budget/context 回归：`Packages/IntatisAgentKernel/Tests/AgentLoopOutcomeTests.swift`、`AgentLoopPolicyTests.swift`、`ContextProjectionTests.swift`；Goal/WorkTask 协议与回放：`Packages/IntatisProtocol/Tests/TaskGoalProtocolTests.swift`、`Packages/IntatisConversation/Tests/TaskGoalProjectionTests.swift`，Goal 创建入口边界由 `ToolRegistryLeaseTests.swift` 与 GUI/CLI `/goal` 路径覆盖，旧 Cowork replay 继续由 `CoworkProjectionRegressionTests.swift` 与 Protocol lease/task tests 覆盖。
- mailbox/terminal/run-control 专项回归分布在 `TaskContractTests.swift`、`AgentLoopPolicyTests.swift`、`ModelHistoryProjectionTests.swift`、`ContextProjectionTests.swift`、`IntatisConversationCodeTests.swift`、`MessageDelegationSplitTests.swift`、`MailboxCorrelationTests.swift`、`RunControlTests.swift`、`ContinuationRunCloseClaimTests.swift`、`CommunicationCorrelationProtocolTests.swift`、`OrchestrationReliabilityTests.swift`、`WorkTaskRuntimeTests.swift`、`ToolRegistryLeaseTests.swift` 与 `PermissionReviewControlPlaneTests.swift`；覆盖 legacy decode、failed/interrupted history/UI、1–8 exact projection、authority-class 窄 lease、单 terminal reply/fresh follow-up/no-ACK、first-write run close、恢复 drain、原子 consume、live/restore 同 TaskID retry、legacy poison lineage、新 ID 独立投递及 reviewer semantic preview。
- Agent session / Terminal / Shell / Git / 文档 / 媒体/托管搜索工具：`SessionNamingTool.swift`、
  `HostedWebSearchTool.swift`、`TerminalTools.swift`、`IntatisPTYLauncher` 与 `ShellGit.swift`
  保留原有职责；`ShellGit.swift` 的 document lane 现固定 Python/LibreOffice/Tectonic executable、
  bundle active-architecture root、CLI/debug development root、default-network-deny、timeout/cancel/
  descendant cleanup、generated-output budgets 与 2 GiB aggregate RSS。
  `DocumentMediaTools.swift` 包含 PDFKit `inspect_pdf` / `read_pdf`、fixed Tectonic
  `compile_latex` 及未变的 image tools；`DocumentTools.swift` 包含五个 Docling reader + 五个
  continuation、`ocr_pdf`、`pdf_render_page` 与业务语义盲 staging glue；
  `ExactDocumentTools.swift` 是四个 exact PDF export 与 29 个 exact Office write registrations；
  `DocumentToolContracts.swift` 只定义闭合 schema；`DocumentInfrastructure.swift` 负责
  identity/SHA/CAS/staging/atomic commit；`DocumentPythonBackend.swift` 的固定 route table 直接调用
  Docling/python-docx/python-pptx/openpyxl public API；`DocumentFixedBackends.swift` 只保留三个
  LibreOffice PDF filter；`PDFNativeDocumentService.swift` / `HTMLDocumentPDFRenderer.swift`
  分别封装 PDFKit 与 `WKWebView.createPDF`。production registry 是 `intatis.standard.v5`，
  不注册任何 aggregate document tool。
- Document runtime release contract：`Packages/IntatisTools/Runtime/document-runtime/{README.md,release-spec.json}`
  固定 direct components/layout/2 GiB RSS；`scripts/validate-document-runtime.sh` 检查 manifest、全文件
  SHA-256、SPDX/license closure、model/tessdata pins、Mach-O architecture/load commands/RPATH/signature；
  `scripts/package-macos-release.sh` 在 bundle stage 前后及 outer App seal 后复验 arm64/x86_64 roots；
  `ThirdPartyNotices/DocumentReadingRuntime.md` 记录 provenance/license/未完成发行证据。旧
  `Runtime/rbook-helper`、`Runtime/epubcheck-wrapper` 与 `DocumentRBookHelper.md` 已随 EPUB
  write removal 删除。
- Managed terminal 回归：`Packages/IntatisTools/Tests/TerminalToolsTests.swift`（真实 cwd/pipe/TTY/controlling `/dev/tty`/Ctrl-C、凭据环境、不可移除且大小写无关的凭据路径 floor、workspace/owner isolation、拆分输入、真实 zsh cursor/escape/keymap 拒绝、partial-write teardown、timeout descendant cleanup、大型 build artifact、有界输出 tail、延迟回显清洗、无人轮询自动收口、workspace replacement 后无需 poll 收口、same-sandbox signal、schema/opt-in registry）、`Packages/IntatisAgentKernel/Tests/TerminalAgentLoopTests.swift`（durable prepare/settle 且 stdin 不落 EventLog）、`Packages/IntatisPermission/Tests/ShellPermissionTests.swift`（`write_stdin` 不能绕过危险命令 hard deny）、`Packages/IntatisCowork/Tests/ToolRegistryLeaseTests.swift` 与 `Packages/IntatisProtocol/Tests/CapabilityLeaseTests.swift`（read-write worker/host exposure 与 read-only/reviewer suppression）
- Agent 网络/浏览器工具：`Packages/IntatisTools/Sources/BrowserTools.swift`（`web_fetch` / `browser_diagnostics` / `browser_profiles` / `browser_profile_delete` / `browser_history` / `browser_navigate` / `browser_snapshot` / `browser_handoff` / `browser_reload` / `browser_back` / `browser_forward` / `browser_click` / `browser_type` / `browser_submit` / `browser_select_option` / `browser_press_key` / `browser_scroll` / `browser_wait` / `browser_screenshot` / `browser_upload_file` / `browser_download` / `browser_downloads` / `browser_search`，通过 URLSession 或已安装 Node.js + Playwright persistent context；Playwright 缺失时用 Node.js 内置 WebSocket + Chrome DevTools Protocol 驱动已安装 Chromium/Chrome/Edge profile；页面快照和动作结果返回可定位交互元素摘要，并可跟随 click/type-submit/select/submit/press 打开的新 tab/window；profile inventory 只列安全 metadata 和 runtime marker 存在性；profile 删除是显式 `.destructive` 清理工具，删除前只概括提示 runtime marker 状态；表单提交作为 exec+network browser action 暴露）、`Packages/IntatisPermission/Sources/DeterministicPolicyGate.swift`（exec+network/destructive 权限顺序）、`Packages/IntatisProtocol/Sources/Leases.swift`（`browse_web`）
- Provider-hosted search 专项回归：`Packages/IntatisTools/Tests/HostedWebSearchToolTests.swift`、`Packages/IntatisAgentKernel/Tests/ProviderHostedWebSearchToolServiceTests.swift`、`Packages/IntatisProviders/Tests/IntatisProvidersTests.swift` / `InferenceCatalogStoreResolverTests.swift`、`Packages/IntatisCowork/Tests/ToolRegistryLeaseTests.swift` 与 `Packages/IntatisProtocol/Tests/CapabilityLeaseTests.swift`；分别覆盖 query-only strict schema、network/model cost intent、exact route + required/fail-closed request、citation/output bound、adapter/capability gate、service/lease 双门和 browser/MCP 独立性。
- 权限门：`Packages/IntatisProtocol/Sources/PermissionIntent.swift`、`PermissionReview.swift`（`PermissionRequestContext.reviewInvocationEvidence` 以 additive metadata 保存 generation/snapshot/digest/status receipt；`PermissionReviewTask` 不复制 raw transient；旧 `PermissionAuthorizationContext` 仅保留 decode/replay）、`ToolAuthorization.swift`（宿主解析的 concrete tool/membership/lease/args digest/preview 不可变快照）、`Packages/IntatisPermission/Sources/PermissionEngine.swift`、`DeterministicPolicyGate.swift`、`ModelPermissionReviewer.swift`、`PermissionReviewTextVerdict.swift`、`SecretScanner.swift`。`Packages/IntatisAgentKernel/Sources/AuthorizationSidecar.swift` 在 Cowork request-owned provider schema 上增加 required string `__intatis_authorization_context`，递归验证 strict function 的 `required == properties.keys` 与 `additionalProperties:false` 并在发网前 typed fail closed；原 ToolDescriptor/business required/executor schema 不变。`AgentLoop.swift` 还只在 provider-bound message copy 中装饰 `tool_search_output` 的 deferred function/namespace children，durable output 不变。codec 按 call 拆分并绑定 session/turn/task/call/tool/provider generation/tool snapshot/digests，只有 gate 到达 automatic ask 时宿主才消费并验证该字段。`AgentLoop.swift` 在 original business validation/durable history/EventLog/authorization/executor 前移除 sidecar；valid sidecar 只留在当前 turn 的 acting-model 内存 history。`PermissionReviewControlPlane` 只接收 complete safe business args、complete string sidecar 与 mechanical host facts，不接收 objective/role/deliverable/userGoal/user/assistant history/PDF/image 原文。missing/malformed/secret-bearing sidecar 只写 failed/runtimeFailed `tool_result`，不创建 permission lifecycle、不调用 reviewer、不消耗 denial fuse；binding mismatch 单独 typed fail closed。manual/nonautomatic 保留字段与误配 in-engine reviewer 均在 business execution 前拒绝。不存在第二次 acting-model Reporter request；deterministic allow/deny 仍直接结算。
- 事件日志与输入投影：`Packages/IntatisConversation/Sources/EventLog.swift`（JSONL、multi-event WAL、`replayChecked` / `isEmptyChecked`、session/seq 校验）、`ChatSessionAutoTitle.swift`（Chat-only 轻量 admission、最早三轮 strict projector、user/assistant 正文字段合计 6,000-Character 预算的 JSON 上下文、独立无工具 request、严格输出验收、15 秒 request-owned consumer、per-session attempt/single-flight/close fence、双平台共用 display-name watermark 与 verified commit）、`SessionProjectionStore.swift`（跨进程锁内 Chat-only set-if-absent rename）、`GoalInput.swift`（Chat/Code legacy Goal metadata 与 Cowork durable `/goal` 明确入口共用的语法解析；普通自然语言不触发 Goal）、`Projection.swift`（Chat 用户消息保留 optional ArtifactID 附件引用）、`CodeProjection.swift`、`CoworkProjection.swift`
- assistant/agent 回答时间展示：`Projection.swift` / `CodeProjection.swift` 把首个对应 message envelope 的 `ts` 保留为 presentation timestamp，后续 delta/completion 只补缺不覆盖；`Packages/IntatisSharedUI/Sources/ThreadSurfaces.swift` 提供按滚动 24 小时 / 7 天分层且遵循系统 locale/calendar/time-zone/12–24 小时偏好的公共格式，`Views.swift`、`CodeViews.swift` 与 `Apps/TranslatisMac/Sources/TranslatisChatScreen.swift` 在 agent 名称右侧消费。Cowork 复用 `CodeItemRow`，不新增 EventLog event/schema 或独立时间存储。
- Phase S session 状态：`Packages/IntatisProtocol/Sources/SessionStateEvents.swift`（版本化完整 settings 快照、`session_settings_updated`、幂等 `session_storage_migrated`、rename source/operation ID；canonical encoding 不写 legacy `defaultProviderID`）、`Packages/IntatisConversation/Sources/EventLog.swift` / `SessionProjectionStore.swift`（append/stream 发布落盘反解 canonical Envelope；`events.jsonl` → schema-v2 `session.json`；full-fold EventLog-wins；legacy name append-before-rebuild；exact rename retry first-write-wins、冲突 operation fail closed、A→X/B→Y/retry-A 不覆盖 Y；严格 revision helper；owner-only atomic projection）、`Packages/IntatisCore/Sources/SessionWorkspaceAccessStore.swift`（session-owned schema-v1 binary plist、`0600`、no-follow lock、原子写、primary 默认拒删与显式事务回滚）、`Apps/TranslatisMac/Sources/Workspace.swift` / `CoworkProjectSettings.swift` / `CoworkViewModel.swift` / `TranslatisMacApp.swift`（RAII scope、shared 零引用清理、primary UI/方法/store 三层保护、scope-first symlink alias→canonical settings-before-marker migration、精确 reauthorization）、`Packages/IntatisCowork/Sources/Orchestrator.swift`（fresh 七事件 bootstrap 与严格历史 main CAS 恢复）、`Apps/translatis-cli/Sources/Interactive.swift`（专用 `/agent restore-main`）。对应测试：`SessionStateProtocolTests.swift`、`SessionProjectionStoreTests.swift`、`SessionRenameAgentLoopTests.swift`、`SessionNamingToolTests.swift`、`IntatisConversationTests.swift`、`IntatisCoreTests.swift`、`AutomaticPermissionReviewTests.swift`。
- Phase A Cowork submitted intent：`Packages/IntatisProtocol/Sources/Event.swift` / `Task.swift`（`SubmissionID` 关联的 user/status/task additive protocol；`UserMessagePayload.mainAgentInferenceBinding` 冻结每次 Send 的 optional-schema/non-nil-new-main exact binding）、`Goal.swift`（新式 durable Goal 保存同一 binding 供 continuation/restart 使用）、`Packages/IntatisConversation/Sources/SubmittedIntentStore.swift`（session-owned outbox、canonical `user_message + queued` transaction、状态机校验与纯 `SubmittedIntentRetryPlanner`；restored queued exact resume不增attempt，restored running durable requeue只对齐exact下一attempt，只有failed/cancelled whole-task retry递增）、`CodeProjection.swift` / `CoworkProjection.swift`（提交状态 fold）、`Packages/IntatisAgentKernel/Sources/ContextProjection.swift`（accepted submission 顺序与 fail-closed 归属过滤）、`Packages/IntatisCowork/Sources/Orchestrator.swift`（FIFO、exact root retry、restored-task fence、main rebind + root/retry queue atomic admission batch）、`GoalRuntimeController.swift`（Goal create/每轮 continuation 传递 durable binding）、`Apps/TranslatisMac/Sources/CoworkViewModel.swift`（冻结 draft/附件/route/Goal/next-main binding、durable admission、main/Goal nil fail-closed、drain/retry）、`Packages/IntatisSharedUI/Sources/CoworkViews.swift` / `ThreadSurfaces.swift`（始终可编辑的 composer；普通 queued/running/completed/cancelled 状态不再渲染进用户气泡，失败/Retry 继续只在右栏错误卡，durable 状态不变）。附件 durability 由 `Packages/IntatisCore/Sources/DurableOwnerOnlyFile.swift` 与 `Packages/IntatisArtifacts/Sources/ArtifactStore.swift` 提供。对应测试：`SubmissionProtocolTests.swift`、`SubmittedIntentStoreTests.swift`、`SubmissionProjectionTests.swift`、`SubmittedIntentHistoryTests.swift`、`ContextProjectionTests.swift`、`OrchestrationReliabilityTests.swift`、`AutomaticPermissionReviewTests.swift`、`IntatisArtifactsTests.swift`。
- macOS Chat/Code/Cowork composer 附件：`Packages/IntatisSharedUI/Sources/ComposerAttachments.swift` 统一 security scope、文件读取与 ArtifactStore 保存/读回校验；`Packages/IntatisSharedUI/Sources/ComposerAttachmentSurfaces.swift` 提供共享 paperclip/import/drop/draft-menu presentation。Chat 继续由 `ChatViewModel` / `ChatLoop` 按 ArtifactID 恢复；Code/Cowork 将 IDs 交给 AgentLoop 的 durable media resolver，stable history规则见 Agent内核条目。macOS Chat不再提供独立提示词生图composer action；iOS能力边界不随此接入扩张。对应测试：`ComposerAttachmentTests.swift`、`IntatisConversationTests.swift`、`DurableMultimodalAgentLoopTests.swift`。
- Phase B permission reviewer request isolation：`Packages/IntatisCowork/Sources/PermissionReviewControlPlane.swift`（`{reviewTaskID, nonce}` generation、provider/timeout first-terminal race、exact-generation claim、request-owned cancellation、late/duplicate drop、verdict/delivery cancel guard；live model call 复核 receipt、session/turn/task/call/tool/generation/snapshot/business/context digest、string sidecar、secret 与 exact authorization snapshot；provider prompt 只投 exact args + sidecar + mechanical host facts；raw transient 只存活于 request-local 调用/active Job；terminal 使用固定宿主文案）、`AgentPermissionResponder.swift` / `Orchestrator.swift`（automatic-only transient overload、dedicated host-agent-admission overload、冻结 reviewer exact binding、逐代 fresh-resolve provider wrapper）、`Packages/IntatisPermission/Sources/PermissionReviewTextVerdict.swift`（非空 plain-text reason + 唯一 final-line ASCII ALLOW/DENY；约 240 Character 仅为共享 prompt 建议；完整 reason 先做敏感信息检查；结构/transport failure 使用 secret-free 细分诊断）、`Packages/IntatisProviders/Sources/ToolCalling.swift`（request-owned stream/cancellation）。旧 Reporter protocol types、`authorization_context_unavailable`、`malformed_verdict` 与 `provider_still_stopping` 仅保留 legacy decode/reconciliation。acting model 自行写入 ordinary assistant text 与 malformed provider-error preview 仍分别服从既有消息持久化和通用 diagnostic sanitizer；live 没有固定 sidecar byte ceiling 或 `review_input_too_large` admission。2026-08-12 strict-schema corrective gate 为 `AuthorizationSidecarTests` 12/12、`PermissionReviewControlPlaneTests` 47/47、`AutomaticPermissionReviewTests` 35/35、`AgentLoopPolicyTests` 37/37、`DurableMultimodalAgentLoopTests` 9/9、`IntatisPermissionReviewerTests` 10/10、`PermissionReviewProtocolTests` 12/12，合计 162/162；另有 `SearchKnowledgeToolTests` 4/4，以及覆盖 deferred schema 压缩阈值、compactor request 与 durable raw output 的 `ModelHistoryCompactionAgentLoopTests`。`swift build --disable-automatic-resolution`、`TranslatisMac` macOS Debug unsigned build 与受影响目标 `IntatisAgentKernelTests` 217/217、`IntatisKnowledgeTests` 118/118、`IntatisCoworkTests` 364/364、`TranslatisCLITests` 45/45（8 skipped）通过；完整测试完成 Tools 223/223 后挂于既有 SharedUI async waiter并人工中断，不能记为本次全量通过。opt-in `RealProviderSmokeTests.testRealAgentAuthorizationSidecarShapeWhenEnabled` 已编译但真实计费请求与 UI/manual switch smoke 尚未运行。
- Phase C permission/turn outcome：`Packages/IntatisProtocol/Sources/TurnOutcome.swift` 与 `PermissionReview.swift` / `Event.swift` / `Envelope.swift`（稳定 TurnID、typed call/turn outcome、failure source、approve/decline/cancel-turn action、manual/automatic mode 和 legacy-decodable correlation）；`Packages/IntatisConversation/Sources/EventLog.swift` / `Projection.swift` / `CodeProjection.swift`（RequestID first-write、first-terminal CAS、FIFO pending 投影与 typed failure projection）；`Packages/IntatisAgentKernel/Sources/AgentLoop.swift`、`ChatLoop.swift`（Decline call 继续、Cancel turn 中断且无伪 tool result、每轮 terminal）；`PermissionReviewControlPlane.swift`（同 RequestID duplicate/reconnect 共享 owner generation/terminal）；`ToolProtocol.swift` / `ShellGit.swift`（可信 wrapper-startup sandbox denial 分类）；`CodeViewModel.swift` / `CoworkViewModel.swift` / SharedUI permission card / CLI（结构化人工动作与自动审查不可操作状态）。DEBUG-only 离线验收入口为 `Apps/TranslatisMac/Sources/PhaseCPermissionFixtureView.swift`。对应测试：`TurnOutcomeProtocolTests.swift`、`PermissionSettlementTransactionTests.swift`、`PermissionProjectionTests.swift`、`AgentLoopOutcomeTests.swift`、`SandboxDenialOutcomeTests.swift`、`WorkspaceSandboxDenialTests.swift`、`PermissionReviewControlPlaneTests.swift`、`OrchestrationReliabilityTests.swift`。
- Phase L app/runtime lifecycle：`Apps/TranslatisMac/Sources/SessionRuntimeManager.swift`（进程级 exact `{SessionKind, SessionID}` Chat/Code/Cowork ownership、Cowork creation single-flight、runtime status/removal 发布、exact deletion drain、全局 bounded shutdown，以及按 exact session 的低频 display-name publisher/revision+seq watermark）、`TranslatisMacApp.swift`（窗口级 selection + shared manager、AppKit terminate-later/Command-Q、model-tool rename verified commit bridge）、`TranslatisMacRootView.swift`（切换不 stop、exact busy/delete、跨窗口 removal 与手工/model rename 的单行摘要更新）、`ChatViewModel.swift` / `CodeViewModel.swift` / `CoworkViewModel.swift`（idempotent shutdown、operation admission/drain、permission/subscription/workspace release）、`Packages/IntatisCore/Sources/BoundedSessionRuntimeShutdown.swift`（concurrent stop、monotonic deadline、settled/timed-out report、single-flight）、`GoalRuntimeController.swift` 与 CLI `Interactive.swift`（冷启动只 reconcile/pause，显式 Resume/data-plane boundary）。DEBUG-only 离线验收入口为 `PhaseLSessionLifecycleFixtureView.swift`。对应测试：`BoundedSessionRuntimeShutdownTests.swift`、`GoalRuntimeControllerTests.swift`；Computer Use 矩阵见 `docs/TESTING.md`。
- Phase T tool outcome / task-local recovery：`Packages/IntatisProtocol/Sources/ToolExecution.swift` / `ToolExecutionRejection.swift` 定义 additive effect disposition 与 typed no-effect rejection；`Packages/IntatisConversation/Sources/CoworkProjection.swift` / `EventLog.swift` 负责 exact prepare/settlement、重复 ID/冲突终态 fail-closed 与 complete-known history；`Packages/IntatisAgentKernel/Sources/AgentLoop.swift` 原子记录 model-visible failure + no-effect settlement；`Packages/IntatisCowork/Sources/WorkTaskTools.swift` / `Orchestrator.swift` 负责 production `task_create` / `task_update` pre-first-append proof，以及 delegation 全预检后的单 EventLog admission batch；`GoalRuntimeController.swift` 负责 active Run 的 `interrupted` 结算和显式 Resume 新建 Run。`ContextBuilder.swift` 与 bundled `cowork-agent-orchestration` Skill 另冻结 multi-call 非事务/非并发、依赖成功 ToolResult 后分轮，以及 Task create → confirmed spawn → confirmed attached-target delegation 的模型合同；`delegate_task` 不隐式创建 worker。对应测试：`ToolExecutionProtocolTests.swift`、`ToolExecutionProjectionTests.swift`、`AgentLoopPolicyTests.swift`、`ContextProjectionTests.swift`、`IntatisSkillsTests.swift`、`WorkTaskRuntimeTests.swift`、`GoalRuntimeControllerTests.swift`、`AgentInvocationNonRecursiveTests.swift`、`OrchestrationReliabilityTests.swift`。
- 对话内容渲染：`IntatisMessageRendererMode.swift`（无偏好默认 `.microsoft`，未知值 fail closed `.plainSafe`，固定持久键，新/旧启动 override 和旧 `rich` 迁移）、`IntatisMessageContentView.swift`（角色/mode facade、facade-lifetime latest raw projection、append-compatible active rich retention与安全链接）、`IntatisMicrosoftMarkdownPipeline.swift`（64 KiB whole-message admission、50 ms incomplete parse debounce、100 ms raw fixed-window leading/trailing throttle、同message/style/appearance/typography/config的未完成append-only rich→rich replacement、correction/truncation/oversize立即raw、timer generation guard、view 内 `bufferingNewest(1)`、MainActor document ownership、stale guard、图片/animation/citations 关闭，并在 macOS 关闭旧 select-more modal）、`IntatisLatestOnlyPermitScheduler.swift`（output-free、全局 concurrency 1 / pending 32、每 key latest-only/fair permit；不保存 work/result/document）、`ThreadSurfaces.swift`（macOS/iOS 连续 thread stack、最多 16 个 active rich rows 的 viewport budget 与 offscreen rich eviction）。vendor 的 macOS selection 入口为 `UI/TextSelection/MarkdownDocumentSelectionCoordinator+macOS.swift`、`DocumentView.swift`、`ParagraphNSView.swift`、`ParagraphView+macOS.swift`、`TableView.swift` 与 `CodeBlockView.swift`；它保持一个 DocumentView 一个 coordinator、稳定注册顺序、geometry target、单一 `selectedTextAttributes` transient snapshot、无重复绘制的 primary native range 与合并 Copy。公式面由 `MathRenderConfig.swift`、`InlineMathCatalog.swift`、`MathAttachmentData.swift`、`InlineMathPreprocessor.swift`、`UI/Paragraph/InlineMathAttachment.swift`、Markdown parser/config/inline bridge 和两平台 paragraph host 组成；处理 protected-context-aware `$...$` / `\(...\)` inline 与 `$$...$$` / `\[...\]` display，原始 TeX 和 presentation 随 attachment 保留，不设公式数量、单式字节或固定附件尺寸上限。接入点为 macOS/iOS Settings（Picker 也将 legacy `rich` resolved 为 Microsoft）、macOS `RendererFixtureView`、`TranslatisChatScreen.swift` 与共享 `{Views,CodeViews,CoworkViews}.swift`；旧 `IntatisRenderDocument.swift` / `IntatisCodeBlockView.swift` / `IntatisMathView.swift`、旧 regex `LaTexPreProcessor.swift` 和 highlight.js/CSS 资源仍保持删除。
- macOS公式占位遮蔽只位于`IntatisMessageContentView.swift`的`IntatisRichDocumentVisibilityGate`：它按新
  `RenderableDocument`对象identity把rich真实挂载但隐藏一个owner-bound main-queue turn，随后无动画
  reveal；不修改`Vendor/SwiftStreamingMarkdown`、不解析公式、不影响iOS，也不持有document graph。
- Code/Cowork execution trace 展示策略：`Packages/IntatisConversation/Sources/CodeProjection.swift`（用 per-agent active `{TaskID, attempt}` + 该 invocation 最后一个完整 message index 判定 exact `task_completed` 镜像；迟到旧 attempt 不清除新 attempt，不匹配时保留 conversation fallback；通用 agent message 与 information request/reply 投影为 `.agentToAgent`，统一生成 `sender->recipient` identity 与 envelope timestamp）、`Packages/IntatisSharedUI/Sources/ExecutionTracePresentation.swift`（默认保留 conversation、`.agentToAgent` 与 error，仅隐藏 tool/patch/note 等 trace；后台 `-IntatisShowExecutionTrace` / `INTATIS_SHOW_EXECUTION_TRACE=1` 恢复完整 trace）、`ThreadSurfaces.swift`（在任何 thread filter 前从 raw page 收集 error/失败 trace/recovery/submission failure，再生成不含错误 chrome 的 presentation-only transcript copy）、`CodeViews.swift` / `CoworkViews.swift`（清理后的 items 才进入 thread、auto-scroll 与 thinking；错误列表只进入右栏，`.agentToAgent` 复用普通 agent 无外框回答版式）。该 UI 路由不删除或改写 EventLog/`CodeProjection` facts。测试为 `Packages/IntatisConversation/Tests/IntatisConversationCodeTests.swift`、`Packages/IntatisSharedUI/Tests/ExecutionTracePresentationTests.swift` 与 `ThreadLayoutTests.swift`。
- iOS 预渲染救援资源：`Apps/TranslatisiOS/Resources/Settings.bundle/Root.plist` 通过系统 Settings 写入同一 renderer key，values 为 `microsoft` / `plainSafe` 且默认 Microsoft；`project.yml` 将该目录只加入 iOS app resource phase。最终 `TranslatisiOS.app/Settings.bundle/Root.plist` 必须存在，plain-safe 仍须可在打开问题 session 前选择。
- 开源声明入口：`NOTICE.md`、`ThirdPartyNotices/MarkdownRendering.md`、`ThirdPartyNotices/SyntaxHighlighting.md`、`ThirdPartyNotices/MathRendering.md`；`Packages/IntatisSharedUI/Sources/ThirdPartyNoticesView.swift` 在设置 UI 暴露声明，`project.yml` 将根 NOTICE 与三份 notice 复制到 macOS/iOS app bundle。
- 渲染测试/fixture：`MarkdownSchedulerTests.swift`、`MessageRendererModeTests.swift`、`MessageRenderingTests.swift` 与 vendor formula/parser/platform/`MarkdownDocumentSelectionCoordinatorTests.swift` 共同覆盖模式、背压、raw/final、delimiter/code/currency/fallback、attachment source、两平台 TextKit 2 paragraph/live-provider integration、Dynamic Type、semantic appearance、正反向跨 leaf range、table/list order、transient style restore 与合并 Copy；既有 vendored AppKit/UIKit stable-width invalidation 与 `DocumentView`/ParagraphView equality/selection contracts 继续保留。当前 `MessageRenderingTests` 39/39、`ThreadLayoutTests` 32/32；vendor full 为 79 XCTest + 25 Swift Testing。AppKit `ParagraphNSView` 还冻结 TextKit 2 root content-storage retention、wholesale replacement 后 primary-manager restoration、coalesced viewport layout、flexible intrinsic width、exact proposal ownership 与 one-entry measurement；`InlineMathAttachment` 冻结专用动态 UTI、direct provider 与无 generic attachment cell。`Tests/Fixtures/incident-1249-sanitized-v1.json` 是脱敏的 17-message / 1,249-delta 固定样本，SHA-256 `fb548849d0b708d31e8c6d055805f29f5c09ee4c8306bf9adc537a48e95707f1`，不得因 selection/公式功能改写；validation-only host 除 formula/thread-burst/message-footer stages 外，Debug bundle suffix `.DocumentSelectionFixture` / `.DocumentSelectionTableFixture` / `.DocumentSelectionFullFixture` 可分别隔离 code/table/full-static selection workload，不触碰真实 session/provider。旧 lazy 容器曾完成三次 180 秒 soak、60 秒显式 AX 滚动和约 90 秒 Hangs/Time Profiler，这只保留为历史证据；当前 continuous timeline/16-active-rich-row budget 已完成 180 秒 soak，direct selection 的跨消息/modifier/autoscroll 仍未覆盖。2026-07-18 三实例事故的最终 retaining edge 仍以 `UNKNOWN` 历史 evidence 保留；当前证据仍不等于 VoiceOver、modifier/autoscroll 或低端真机通过，plain-safe 也不能冒充 no-math baseline。
- macOS UI 信息架构：`Apps/TranslatisMac/Sources/TranslatisMacRootView.swift`（系统 `NavigationSplitView` sidebar 内的 `Intatis` 标题、带 SF Symbol 的 Chat/Code/Cowork 竖向三行导航且仅当前项使用 interactive Liquid Glass、mode history/New、底部 Settings；session display name 解析；新建 Cowork session 选择主 workspace）、`Apps/TranslatisMac/Sources/TranslatisChatScreen.swift`（session-title Chat header；完整连续 transcript、viewport-bounded rich rendering 与普通滚动；仅用户消息保留 trailing 原生 `Glass.regular` 气泡 cap/gutter，且无自定义蓝色描边；assistant/agent/system 包括失败/中断回复均无外层卡片；无通用 agent 头像/Agent badge；名称旁稳定消息时间；composer 第一排 40pt、关闭态仅模型名的 model/variant glass 菜单左、会话 Context 右；已完成回复正文下方接 icon-only copy + Input/Cached/Output/Time footer；第二排复用 Cowork paperclip 附件 surface）、`Packages/IntatisSharedUI/Sources/ComposerAttachmentSurfaces.swift`（Chat/Code/Cowork 共用的 40pt paperclip、文件选择、URL 拖放、附件数量菜单和逐项删除）、`Packages/IntatisCoworkUI/Sources/IntatisCoworkContentView.swift`（presentation-only完整Cowork右侧composition：模型选择、两排composer、permission、Agents/Goal/Tasks、Inspector、retry与Goal editor；只消费宿主state/actions）、`Packages/IntatisSharedUI/Sources/CodeViews.swift`与`CoworkViews.swift`（continuous timeline、viewport-rich-budget、仅用户消息regular Liquid Glass气泡、permission-first rail、Agents/Goal/Tasks与可选Stop）、`Apps/TranslatisMac/Sources/TranslatisMacApp.swift` / `MCPProjectSettingsSurfaces.swift` / `AppInferenceCatalog.swift` / `CoworkViewModel.swift` / `CoworkProjectSettings.swift`（App继续拥有runtime/session/settings并薄映射UI；MCP内容收进Project Settings；busy next-`@main` binding、future-agent default和异常恢复语义不变）、`Packages/IntatisSharedUI/Sources/ThreadSurfaces.swift`与`ProviderModelMenu.swift`（共享composer、message footer、model menu与布局合同）。
- Code/Cowork 错误展示路由：`Apps/TranslatisMac/Sources/TranslatisMacApp.swift` 把 Code 的
  voice/composer 与 Cowork 的 voice/composer/inference/projection/session-storage 错误完整传入
  SharedUI；`ThreadSurfaces.swift` 从当前连续 transcript 收集 `.error`、失败 execution row、
  `recoveryAdvice`、失败 submission 与全部 host 文案，按规范化消息去重，并生成不含错误 chrome
  的 presentation-only transcript copy；`CodeViews.swift` / `CoworkViews.swift` 只在右栏最底部
  生成一张非空“错误信息”卡片，Cowork 通过 exact `SubmissionID` 保留 Retry。EventLog、
  projection、runtime 与 permission 语义不变。
- macOS full-window Jump 几何：`TranslatisMacRootView.swift` 以 window-local `GeometryReader` 向 subtree
  注入完整 content width；`Packages/IntatisSharedUI/Sources/LayoutProfiles.swift` 的
  `IntatisWindowCenteredOverlayLayoutPolicy` 用 window/detail/overlay-surface 三个 finite width 纯计算
  offset。Chat/Cowork 的 surface 是完整 detail，Code 的 surface 是 inspector 左侧 thread，因此都能
  补偿实际 sidebar/inspector 宽度并落在整个 app window 横向中线；standalone fixture 缺 host width
  时回退自身中线。该路径不读取 global frame、不建立 PreferenceKey/scroll geometry 回写，也不改变
  Cowork rail、bottom-anchor 或 EventLog。
- iOS UI 信息架构：`Apps/TranslatisiOS/Sources/TranslatisiOSApp.swift` 保持单一
  `NavigationStack` + Chat-only root；顶部为 sidebar、JetBrains Mono session title 与 New，约
  82% 左抽屉复用 `IntatisSessionHistoryList`，组织 JetBrains Mono `Intatis`、选中 Chat、Recent/New
  和底部 Settings。底部通过 `ThreeColumnShell` 参数化共享两排 composer：第一排是
  model glass `Menu` 与可用 usage，第二排是 paperclip Chat 功能菜单、输入、voice 和唯一
  Send/Stop；voice 紧邻主操作左侧，iOS 的 glass merge spacing 固定为 0，使各个 8pt 间隔的
  控件保持独立形状；composer 专用 icon modifier 给 action/voice/Send/Stop 统一 40×40 外框，并在
  iOS 使用 `.small` native control size 纠正 `.regular` glass 的可见膨胀，macOS 仍使用 `.regular`。
  关闭状态支持从 24pt 左缘水平右滑打开抽屉；侧栏内水平左滑关闭，两者都用
  方向优势阈值避免抢占聊天和 Recent 的垂直滚动。第一方英文统一使用 JetBrains Mono，标题/正文/原生控件继续由语义字号与字重区分，中文使用 Apple CJK fallback；
  根 `Translatis.icon` 由 iOS target 编译为主图标。产品图仍不链接本地 agent/workspace。
- 2026-07-31/08-02 conversation chrome（由 2026-08-13 用户气泡表面收口补充）：`ThreadSurfaces.swift` 还定义 user-header policy、低对比结构化 surface、可选 subtitle 的 workspace thread header、单行 session history row 与原生 `GlassEffectContainer`/glass surface helper；`Views.swift` / `TranslatisChatScreen.swift` / `CodeViews.swift` 统一省略 user sender label，并只让 user row 使用原生 regular Liquid Glass 气泡，assistant/agent/system 对话行直接继承 canvas；active Chat/Code/Cowork header 只显示 session title。`CodeViews.swift` 的 `PermissionCard` / `PermissionResolutionNoticeView` 使用默认折叠、structured secret-safe details、窄宽自适应 actions，并支持由 Cowork rail 接管外层 surface；`CoworkViews.swift` 把 pending/resolved permission 放到 glass rail 第一位；`TranslatisMacRootView.swift` 的 sidebar 品牌块只保留 `Intatis`，Recent item 只传 session name 而不生成 event/date/path/runtime detail；`PhaseCPermissionFixtureView.swift` 提供不接 provider/EventLog/executor 的真实生产组件视觉验收面。
- 当前 UI 配色规范：`docs/CURRENT_UI_COLOR_SYSTEM.md`（系统原生表面 + Liquid Glass：动态 macOS window / sidebar、仅用户消息使用 regular glass 气泡、其余 conversation row 继承 canvas、专用结构化内容 Material、导航与交互功能层玻璃、系统语义色、iOS 边界与验收清单）
- 上一版 UI 配色底稿：`docs/UI_COLOR_SYSTEM.md`（保留迁移前 macOS 香槟金/暖中性色与玻璃体系、明暗模式、语义状态色及 iOS 差异，供历史对照）
- GUI token/turn stats：Chat/iOS Chat继续由`TurnStats.swift`绑定optional `turnID` / `responseMessageID`；shipping Code/Cowork改用`ResponsesUsage.swift`从App Server `tokenUsage.last`与`durationMs`绑定final answer并显示七项原生指标，不再发布旧Context。`AgentLoop`写`turn_stats`只属于legacy/manual rollback与历史解码。`Projection.swift` / `CodeProjection.swift`继续支持message-first/stats-first兼容，legacy unbound stats不猜消息归属。
- Chat/Code/Cowork session/history：`Packages/IntatisCore/Sources/SessionKind.swift`（`SessionSummary` / `SessionHistoryStore`，读取 EventLog-derived schema-v2 `session.json` 与执行安全删除）、`Apps/TranslatisMac/Sources/TranslatisMacRootView.swift`（mode history、右键 Rename/Delete）、`Apps/TranslatisMac/Sources/TranslatisMacApp.swift`、`Apps/TranslatisiOS/Sources/TranslatisiOSApp.swift`。macOS 与 iOS 共享最近会话扫描和 `events.jsonl` / `artifacts` 路径生成；平台层只传不同 root 与 `SessionID`。手工 Rename 与 Code/Cowork `@main` 的 `rename_session` 都先追加 EventLog settings event 再刷新 projection，不改变目录名、`SessionID` 或既有 envelope；model schema 不接受目标 session 字段。Cowork 的 `CoworkProjectSettings.swift` 负责 GUI projection 与 legacy UserDefaults migration；canonical project/workspace/future-agent exact default/default permission/token budget metadata 已由 session settings events 持久化，bookmark bytes 独立保存在 session-owned `workspace-access.plist`。
- macOS folder projects：`ProjectFolderStore.swift` 只维护文件夹 path 与 conversation reference；
  每个 record 固定一个 kind，跨模式 association 拒绝。`TranslatisMacRootView.swift` 只从当前 mode 的
  `SessionSummary` 投影可折叠文件夹和 Unfiled，缺失 session 引用不生成伪 row。项目新建只创建
  同模式 session；Code/Cowork 仍先经 exact folder picker，再进入原 `makeCodeViewModel` /
  `makeCoworkViewModel` 及 session bookmark 路径；项目删除不调用 runtime/session delete。
- Provider：`Packages/IntatisProviders/Sources/ProviderRequestAdapter.swift`（保留 raw npm identity，reviewed compatible/OpenRouter lowering，unknown/unsupported fail closed）、`Endpoints.swift`（Chat/Code 兼容路径按 provider/model 保存 exact adapter 与任意 JSON `modelRequestOptions`，旧 Codable 缺 adapter 保持 legacy）、`InferenceCatalog.swift` / `InferenceCatalogStore.swift`（Cowork versioned immutable connection/profile catalog、adapter revision identity、OpenCode-style deep merge + explicit durable option schema）、`ModelConfigurationPresentation.swift`（只读识别原始 reasoning/thinking effort/level/budget 供 UI 展示，不参与请求）、`OpenAIWireProvider.swift` / `OpenAIToolCalling.swift`（package-aware Chat/Agent body lowering、runtime structural fields、config usage/candidate fields 清除与 host-owned `n = 1`）、`ProviderRegistry.swift`（兼容全局角色 provider + exact agent inference resolver）
- Legacy/manual-rollback GUI/CLI Cowork恢复与自动权限审查：`CoworkViewModel.swift`、`Interactive.swift`、`PermissionReviewControlPlane.swift`、`GoalRuntimeController.swift`和旧七事件bootstrap仍保留兼容测试，但shipping新turn不调用这些Orchestrator入口；当前使用App Server official auto_review、四事件root bootstrap、official Goal与native descendants。
- Cowork macOS current project mode：`CoworkProjectSettings.swift`继续提供EventLog-backed settings、legacy UserDefaults migration与workspace UI；`CoworkViewModel.swift`当前shipping先以四事件批次登记settings/root lease pair/root identity，再启动App Server并把native roster/Goal/WorkTask/submission投影给`IntatisCoworkUI`。同文件中的七事件reviewer bootstrap、scheduler恢复与旧outbox/Orchestrator细节只属于legacy/manual rollback。
- macOS shipping Agent business tools：`CodeViewModel.swift`/`CoworkViewModel.swift`把71个document/browser
  registration、两个exact image registration、条件式exact-route hosted-search及可选Knowledge/rename/
  WorkTask交给`CodexBusinessToolHost`；两处都显式注入`ProviderImageGenerationToolService`，并按
  root/child-role scope注入既有`ProviderHostedWebSearchToolService`，因此图片与搜索能力都由shipping
  App Server dynamic catalog和executor证明，不再引用旧Loop作为完成证据。旧`AgentLoop`/`Orchestrator`
  路径仍只保留兼容实现。
- GUI provider/model catalog：`Apps/TranslatisMac/Sources/AppConfig.swift`、`Apps/TranslatisiOS/Sources/IOSConfig.swift`（provider 保存 Base URL + Chat endpoint + secret ref 元数据；model 保存 id + 展示名；macOS 外部配置额外把 `models.<id>.options` 与 `variants` 保真到内存，不写 UserDefaults，并把顶层 `permission_reviewer_model` 解析为独立授权控制面 base route、把顶层 `image_model` 解析为独立宿主 image route；reviewer 字段缺失只继承该 JSON 的 top-level model，显式非法保留存在性并 fail closed，当前聊天 selection 不覆盖它；显式 image-only provider 可为空模型列表且不进入 inference menu；variant 作为同一 model 的请求参数预设，选择时只保存 identity并以原始字段覆盖基础 options；macOS 额外支持 `TRANSLATIS_CONFIG` 显式指定文件、Translatis-owned JSON/JSONC discovery 与模板创建；iOS 通过 `Packages/IntatisProviders/Sources/ChatConfigurationImport.swift` + 系统 Files picker 显式导入同 shape JSON/JSONC，把 base model options/adapter/capabilities 保存到 app-owned protected `Translatis/imported-chat-configuration.json`，将 literal key 迁入 protected `Translatis/auth.json`，不监视原文件、不把 raw options/key 写入 UserDefaults，variants 当前显式警告后忽略；两端均不自动发现任何 `opencode.json` 或 OpenCode app 配置，旧 `config.json` 和 direct `providers` 数组兼容读取）；modern CLI 对应解析位于 `Apps/translatis-cli/Sources/CLIProviderCatalog.swift` / `CLIConfig.swift`；设置 UI：`IntatisSettingsPanel`（macOS，含 Open Translatis Config 按钮；无 reviewer picker）、`IOSRootView.settingsSheet`（iOS，含 Import Translatis Config）；Chat 模型菜单：`TranslatisChatScreen`（macOS）、`IOSRootView` 底部 composer 第一排（iOS）；配置文件 secret 桥接：`Apps/TranslatisMac/Sources/Keychain.swift`、`Apps/TranslatisiOS/Sources/Keychain.swift`（历史文件名；真实请求不读写 OS Keychain，只按 auth JSON / Translatis-owned OpenCode-compatible config `options.apiKey` / env / file 懒加载并缓存 secret）
- Composer 语音输入：`Packages/IntatisSharedUI/Sources/ComposerVoiceInput.swift`（macOS/iOS 共用的
  `ComposerVoiceInputController`、process-wide microphone lease、Flotis-derived recorded-file generation
  state machine、WAV/16 kHz/mono AVAudioRecorder、120 秒/25 MiB 上限、owner-only audio/stale cleanup、
  shutdown/cancel drain 与只追加 draft merge）；`Packages/IntatisProviders/Sources/Transcription.swift`
  （普通/extension/size 校验、owner-only disk-backed multipart/JSON body、严格 JSON response 与
  `TranscriptionFileRequest`）；`HTTPDataClient.swift` / `ProviderRuntimePolicy.swift`（no-redirect file upload、
  timeout/retry/cancel）；`ProviderRequestAdapter.swift` / `ProviderRegistry.swift`（exact adapter →
  compatible multipart 或 OpenRouter JSON-base64 runtime plan）、`ThreadSurfaces.swift`
  （voice trailing action 固定在唯一 Send/Stop 左侧）、`ChatViewModel.swift`、
  `Apps/TranslatisMac/Sources/{CodeViewModel,CoworkViewModel,TranslatisChatScreen,TranslatisMacApp}.swift` 和共享
  `{Views,CodeViews,CoworkViews}.swift`（四个产品 composer 接线及 lifecycle drain）。
  `Apps/TranslatisMac/TranslatisMac.DeveloperID.entitlements` 只为 shipping Hardened Runtime target 增加
  `com.apple.security.device.audio-input=true`；`project.yml` 同步声明 Audio Input resource access，
  不启用 App Sandbox，也不生成第二个 macOS App target。
  `Apps/TranslatisMac/Sources/AppConfig.swift`、`Apps/TranslatisiOS/Sources/IOSConfig.swift` 与
  `Packages/IntatisProviders/Sources/{ChatConfigurationImport,ProviderRegistry}.swift` 只通过顶层
  canonical `transcription_model` 建立 exact route；专用 provider 可为空 `models`，不进入 inference
  menu，未配置/unsupported adapter 时无 hidden fallback。没有新设置页；macOS/iOS 继续分别用高级
  配置与显式 Files import。未迁入 Flotis 的多模型对比、设置 UI、全局快捷键、剪贴板或输入法 target。
- Cowork 设计文档：`docs/COWORK_AGENT_ARCHITECTURE.md`、`COWORK_TASK_CONTEXT_MODEL.md`、`COWORK_AGENT_INVOCATION_MODEL.md`、`COWORK_CURRENT_FINDINGS.md`、`COWORK_MIGRATION_PLAN.md`、`COWORK_V0_10_SMOKE.md`、`COWORK_V0_10_STATUS.md`；当前 per-agent inference durable 契约：`docs/PER_AGENT_INFERENCE_PROFILES.md`
- 开源复用政策：`docs/OPEN_SOURCE_REUSE.md`（允许的复用形式、许可证准入、provenance、NOTICE、Apple-first 集成、OpenCode 当前 research-only 状态与上游升级规则）

## 生成物 / 产物

- SwiftPM 构建产物：`.build/`（含 release 可执行）
- Xcode 工程产物：`Translatis.xcodeproj`（xcodegen 生成，gitignored）
- App bundle：`TranslatisMac.app` / `TranslatisiOS.app`（Xcode 构建产物）

## 脚本与工具

| 脚本 | 用途 | 调用方式 |
|---|---|---|
| `Makefile` | version/build/test/release/install/app/clean 便利 target；常用构建入口先核对版本 | `make version` / `make build` / `make test` / `make app` 等 |
| `project.yml` | XcodeGen 工程规格 | `xcodegen generate`（`make app` 内调用） |
| `scripts/check-version-consistency.sh` | 核对工程、参考 plist、当前文档和生成工程版本 | `scripts/check-version-consistency.sh` |
| `scripts/package-macos-release.sh` | Developer ID 直分发 ZIP/DMG 严格流水线；可在签名后切换网络，并以 owner-only state 有界等待/恢复同一 App 或 DMG submission | 首次设置 `TRANSLATIS_PAUSE_BEFORE_NOTARIZATION=1`；超时后按脚本打印的 `TRANSLATIS_RESUME_RELEASE_DIR` 命令恢复 |
| `scripts/RendererValidationWatchdog.swift` | hash-pinned 单实例 renderer/session replay、telemetry、runtime-log audit 与 TERM→KILL containment | 通过经批准的 Release validation 命令调用 |

## 不确定项

- 当前仓库没有 Git tag；HEAD/origin main 的里程碑提交不替代 `project.yml` 这一产品版本
  唯一事实源。
- `Apps/translatis-cli/Sources/Interactive.swift` 已由 `TranslatisCLI.main` 经 `runMode` 接入，
  不再列为未知。
- 最终 notarization/staple/Gatekeeper、最低支持设备、第三方 provider/MCP/OAuth 与长时
  性能矩阵仍是环境证据缺口，详见 `CURRENT_STATE.md` 和 `TESTING.md`。

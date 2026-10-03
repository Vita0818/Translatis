# CURRENT_STATE — Translatis

文档状态：当前源码摘要
最近核对：2026-09-08
产品基线：v0.72（build 72）

## Translatis 宿主命名空间

本仓库的产品身份是 `Translatis`，三个产品入口分别是 `TranslatisMac`、`TranslatisiOS` 和
`translatis`。App/CLI 的 Bundle ID、配置文件、环境变量、隐藏 workspace 目录、Knowledge/诊断
目录、临时目录、runtime cache、发行工程和 macOS release artifacts 均由
`IntatisHostApplication.configure(name: "Translatis")` 派生，因此活动数据不会与 Intatis 默认宿主的
路径混用。

`IntatisCore`、`IntatisCodexRuntime`、`IntatisHostApplicationIdentity` 等 `Intatis*` Swift
module/type 名称，以及 `0.145.0-intatis.4`、`intatis_responses_provider`、
`intatis_agent_workspaces`、`--intatis-derivation-id` 和 `INTATIS_CODEX_DERIVATION_ID`，是共享实现、
供应链或固定外部协议合同，不能因为宿主改名而改写。旧 `.intatis*`/`INTATIS_*` 名称只保留为
legacy/deny-floor 识别，Translatis 不将其作为活动写入空间。

## 2026-08-30 Cowork完整右侧UI跨项目边界

当前新增presentation-only SwiftPM product `IntatisCoworkUI`。它公开
`IntatisCoworkContentView`以及state/actions/thread-source合同，绘制Intatis Cowork去掉App左侧导航后的
完整右侧内容；不公开或拥有`CoworkViewModel`、session lifecycle、runtime、provider、workspace、MCP、
permission engine或dynamic tools。

此前尝试把完整`CoworkViewModel`与runtime ownership一起移入跨项目Feature的方案已全部撤回：
`CoworkViewModel.swift`、`CoworkProjectSettings.swift`、workspace/bookmark和runtime factory均保持在
`TranslatisMac`原位置与原owner。TranslatisMac现在只是把这些已有published state、bindings与actions薄映射给
`IntatisCoworkContentView`；其他宿主可保留自己的session和per-session tools做同样映射。

`IntatisCoworkUI`的直接依赖只有Core、Protocol、Conversation与SharedUI；public contract测试同时检查
target/source不出现CodexRuntime、AgentKernel、Cowork runtime、Tools、Permission、MCP、
`CoworkViewModel`或`dynamicTools`。完整合同见`docs/COWORK_UI_INTEGRATION.md`。`TranslatisiOS`不链接该产品。

## 2026-08-22–09-02 Codex Runtime、strict routing 与原有能力重新接线

用户已明确把 Code、Cowork 与 CLI Code/Cowork 的 shipping 内核切换为官方开源
OpenAI Codex App Server；Chat 与 iOS Chat 保持现状。当前实现固定
`rust-v0.145.0` / commit
`25af12f7e61572b0bc18ddb1008be543b91519b0`，并应用仓内三项最小Rust patch set生成
`codex-cli 0.145.0-intatis.4`；host同时校验exact版本与0003 patch derivation identity，同版本不同源码也
明确拒绝。`Packages/IntatisCodexRuntime` 是最薄宿主：负责进程/版本、稳定
stdio JSON-RPC、thread/turn/item/interrupt/approval/Goal 生命周期、owner-only thread
映射和 UI 投影；agent loop、工具编排、sandbox、auto-review、上下文与 subagent 均由
Codex runtime 执行。Code/Cowork 的旧 `AgentLoop` / `Orchestrator` 发送和启动函数只保留为
编译期 `unavailable` 的手工源码回退点，生产入口不可调用，也没有运行时 fallback。

2026-08-28 已把现有 `IntatisCodexRuntime` SwiftPM product明确冻结为其他Vitemis项目可直接
path-depend的共享内核宿主面。新增`CodexRuntimeHostContract`把公开API major与exact external-runtime
version/derivation分开；v1只承诺route/configuration、session start/event/turn/interrupt/approval/shutdown、
结果类型及optional dynamic-tools callback。`CodexRuntimePublicContractTests`只使用public imports，编译
最小外部宿主并冻结SwiftPM product名和调用标签；没有新增Codex协议facade、第二agent loop、provider
adapter或runtime fallback。接入合同见`docs/CODEX_RUNTIME_INTEGRATION.md`。

同日共享产品身份已从各package内的硬编码`Intatis`命名抽成
`IntatisHostApplicationIdentity`。宿主在进程入口只调用一次
`IntatisHostApplication.configure(name:)`；第一次读取后identity锁定，不能在同一进程中途换名。
App Support/config/auth、环境变量、UserDefaults、Keychain service、hang/diagnostic、临时目录、
workspace browser/Git state、Knowledge publication、Skill/registry/policy/toolset、MCP、provider adapter、
permission sidecar和Codex host/provider/role名称均由该值派生。Intatis macOS/iOS/CLI显式安装`Intatis`，
现有写出值保持逐字兼容；外部public-consumer probe安装`Mopelium`后验证
`Mopelium`/`mopelium`/`MOPELIUM_*`、`.mopelium*`、`mopelium.*`、
`__mopelium_authorization_context`与`mopelium:*`全链一致。Swift module/type、固定
`0.145.0-intatis.4`派生身份、`intatis_responses_provider`、`intatis_agent_workspaces`和
`--intatis-derivation-id`仍是实现/外部协议常量；旧Intatis敏感路径只继续作为deny floor，不自动迁移、
合并或删除其他产品数据。

2026-08-23 已通过 pinned App Server 的官方实验扩展 `thread/start.dynamicTools` 把第一方业务工具
直接接回 shipping Code/Cowork/CLI。host在`initialize.capabilities.experimentalApi=true`后把
`IntatisTools.ToolRegistry.standard.v5`中71个既有文档/浏览器function原样注册：PDF检查/读取/OCR/
单页渲染、DOCX/PPTX/XLSX/HTML/EPUB初读与续读、4个PDF导出、29个exact Office写操作、fixed
Tectonic编译，以及`web_fetch`和完整`browser_*`集合。App Server仍负责模型工具选择与turn循环；
选择后以`item/tool/call`请求Intatis client执行，client只做官方response所需的最薄接线，直接复用
既有descriptor/schema、WorkspaceLease、DeterministicPolicyGate、permission card/CLI prompt、durable
`tool_execution_prepared/settled`与原executor。只读工具按既有确定性规则运行；写入与网络按既有ask规则
请求用户，可选择记住当前session中同一个exact business tool。没有MCP中转、shell/Python替代、旧
AgentLoop/Orchestrator、第二registry或失败fallback；注册工具失败时把明确ToolResult返回App Server。

这里的71项是2026-08-23最初接线基线，不等于当前authoritative catalog。2026-09-01已把
`generate_image`与`edit_image`作为两个exact function接到同一official dynamic-tools入口，并把既有
`ProviderImageGenerationToolService`作为required host service注入；因此当前基础business catalog为73项。
shipping lease只给read-write root/child签发同名`.generateImage`/`.editImage` capability，read-only child
在permission/audit/executor之前拒绝；旧aggregate `.generateMedia`没有被用作新路径authority。缺少
`image_model`或provider不兼容时明确失败，不回退legacy AgentLoop、当前推理模型或第二backend。

2026-09-02又把既有strict query-only `hosted_web_search`与
`ProviderHostedWebSearchToolService`接到同一official dynamic-tools入口。`ProviderRegistry`在runtime启动前
冻结同一exact provider/model配置的Responses route与optional hosted-search route；host再按root或显式child
role保存不可由模型填写的service scope。没有任何route支持时基础目录保持73项；root或任一child支持时，
App Server要求所有fork共享的目录条件式增加该工具为74项。read-only、unsupported、unknown role或无法证明
parent chain的caller在permission/provider dispatch前拒绝。专用provider请求固定`tool_choice:required`和
unsupported fail-closed，不改走普通模型回答、browser、MCP、shell、旧Loop、另一provider或第二search
backend；App Server内建`web_search`仍固定为disabled。Cowork generation已提升到`codex-native-v6`，CLI使用
新的v6 hosted-search session salt，旧toolset/session不静默迁移。

2026-09-03又把official `item/tool/requestUserInput`接到macOS Code/Cowork现有单一产品流，没有向用户暴露
Plan/Default模式。`IntatisCodexRuntime`保留exact question/option/request/response类型和optional
`requestUserInputHandler`；handler非nil时才在现有单一Code/Cowork流中设置
`default_mode_request_user_input=true`，nil明确false。callback支持root及official parent chain证明的verified
child AgentID，回答按原RequestID/thread/turn/item返回并成为同一Codex turn的function output；auto-resolve、
turn terminal、身份变化、shutdown与process exit取消pending host task。secret问题/答案、坏schema、错误
answer mapping与跨root caller在presentation或回传前fail closed，问题/答案原文不进EventLog。macOS
`CodeViewModel`/`CoworkViewModel`现在各自拥有request-local FIFO presenter，并把纯presentation state/action
映射给SharedUI/IntatisCoworkUI。界面保留透明底、system-separator细描边的bounded question panel，不套
Material/Glass/模糊；选项使用SwiftUI native single-selection `List`的编号整行和系统选中高亮，不使用
radio/checkbox；非空description直接在选项标题下一行以secondary小字显示，不增加info图标。多题每次只
显示一题并提供`N of M`与前后导航，Other按需展开文本框，`⌘↩`提交；不显示
“需要你的选择”，也不增加mode、设置、说明卡或第二协议。一个request可有1–3题，每题2–3个互斥选项且
exact一个answer；Other是自由文本替代项，不是multi-select/补充说明。CLI handler仍为nil。handler启用位
已经计入persisted toolset identity，旧macOS thread要求新session，不能resume-time改变交互面。

2026-08-24 同一官方dynamic-tools入口又接回既有`rename_session`。没有hosted-search service时，Code加
1个当前会话改名工具后共74项，Cowork再加5个WorkTask卡片工具共79项；存在至少一个exact hosted-search
service时分别为75与80项。配置Knowledge时同一request-owned registry再加入
`build_knowledge`/`search_knowledge`，对应无/有hosted search的目录为Code 76/77、Cowork 81/82项。Code
root与Cowork exact
root `@main`使用同一个EventLog-backed命名服务，成功后侧栏、标题与`session.json`从canonical settings
event刷新。固定App Server要求所有fork继承同一dynamic surface，所以child可能看见`rename_session`
schema；这不构成权限：developer instructions明确要求descendant永不调用，Swift host还在任何审计、授权
或执行前按verified child identity直接拒绝。Chat与reviewer不获得该能力。

2026-08-26 已完成内核切换后Knowledge与Skills的shipping接线。Knowledge不被改造成MCP或第二套检索
backend：macOS/CLI的Code与Cowork把既有`HostToolRegistryAugmenter`交给同一个
`CodexBusinessToolHost`，仅在exact配置/route/authority成立时把原`build_knowledge`与
`search_knowledge` descriptor加入official `thread/start.dynamicTools`。执行仍复用原
`KnowledgeLease`、WorkspaceLease、CapabilityLease、PermissionEngine、durable ticket与executor。root和
每个verified child使用各自AgentID、exact workspace/access与host-owned Knowledge capability建立独立
request scope；read-only只签发search，read-write才可签发build+search。显式child profile与省略
`agent_type`的继承策略都由host在App Server callback前冻结，model参数不能扩大；未获grant的child仍在
audit前拒绝。root/child augmentation lease由runtime shutdown统一drain；准备或关闭失败均明确报错，不退回
旧AgentLoop或另一个Knowledge实现。

Skills完全交还给Codex native discovery：0.145.0 exact model catalog现在为Code与Cowork都设置
`include_skills_usage_instructions=true`；workspace `.agents/skills`由App Server按当前cwd原生发现，Cowork
内置`cowork-agent-orchestration`仍以owner-only文件进入isolated `CODEX_HOME/skills`。由于每session隔离
`CODEX_HOME`会隐藏用户原有`$CODEX_HOME/skills`，host在`initialize`成功后、`thread/start/resume`之前只
调用官方`skills/extraRoots/set`接回该exact root；不共享login/config/rollout/credential，也不把legacy
`activate_skill`/`read_skill_resource`放回shipping inference path。已用exact installed binary实测：隔离
home下repository Skill可发现，设置extra root后用户Skill也进入同一official `skills/list`结果。

外部MCP已完成Code与Cowork exact root的原生接线，而不是把旧Intatis MCP client伪装成新内核工具。host从当前session
EventLog读取exact attachment、同Agent/CapabilityLease grant与durable connect consent，只把可由pinned
Codex config精确表达的Streamable HTTP server投影到isolated `config.toml`的官方`[mcp_servers]`；Codex
负责discovery、tool call、resource、approval与transport lifecycle。tool allow/deny、server/per-tool
approval mode、required、parallel声明与startup/call timeout均保真；bearer和secret header先由Intatis secret store懒解析，
只进入App Server process environment的随机稳定变量名，不写TOML、EventLog、runtime files或description。配置authority
改变时macOS先drain当前App Server；CLI `/mcp`复用既有管理命令并明确要求重启应用新authority。

产品授权入口已与该native边界收口：macOS Code/Cowork Project Settings只允许exact Code root或Cowork
`@main` session-root保存完整Interactive、non-expiring grant，界面不再提供partial capability、TTL或child
grant编辑；历史child grant仍显示但只能撤销，历史root partial/expiring grant显示为`Needs upgrade`并可一键
改写为当前exact shape。Codex CLI会话绑定同一root identity，`/mcp grant`默认生成完整Interactive且拒绝
child/task、partial与TTL；standalone legacy-client管理命令只有显式`--native-interactive`才采用该shape。

2026-08-26 同时修正了macOS fresh Cowork启动时的root authority登记回归。brand-new、经用户明确选择
primary workspace的空session现在以一个`appendIfEmptyChecked`批次连续写入settings、`@main` workspace
lease、`@main` business capability lease与`@main` identity；App Server只在这四项durable事实完成且严格
读回匹配后启动，仍不产生provider turn。runtime、native MCP授权页与business-tool host消费同一对
root leases，不再由启动代码临时猜CapabilityLeaseID。primary workspace或read-only/read-write边界改变时，
settings、旧lease revoke、新lease grant和更新后的agent metadata在同一个EventLog事务提交；MCP绑定到旧
capability lease的authority不会流入新权限边界。已经由旧回归写成settings/agent/error但缺少租约的partial
session不做静默修补，也不创建空Codex thread，必须新建Cowork session。

Cowork不再因为root存在MCP而整体停用。固定版上游custom-agent role文件是官方完整高优先级config layer；
host因此给每个显式role和省略`agent_type`时使用的`default` role写入同一批完整、secret-free且
`enabled=false`的server定义。新child spawn时由Codex自己加载该role；persisted child恢复时，host还在
official `thread/resume.config.mcp_servers`重申同一disabled集合。真实fixed binary loopback验证root请求
含native MCP namespace、child请求不含；App Server完全退出并恢复同一child后仍不含。child默认MCP authority
仍为零，当前没有把session root grant冒充为per-child grant。

该MCP投影坚持fail closed：partial capability grant会扩大到Codex integrated surface，因此只接受完整
Interactive capability set；TTL无法由静态native config在到期点撤销，故expiring grant拒绝；pinned schema
无法精确表达Intatis stdio process/network policy、retired client OAuth account、confidential client secret、
非默认redirect/proxy/TLS pin时也拒绝。public-client OAuth metadata可以写入native config，但App内native
OAuth login/rebind尚未接线。exact per-child attachment/grant、native elicitation、stdio process authority与
上述不可表示策略仍停止并请求后续决定；没有legacy MCP runtime、dynamic-tool translator、proxy、adapter
或静默降级。

该experimental使用是pinned `0.145.0-intatis.4`的exact协议能力，不冒充stable API：dynamic tools只存在于
`thread/start`，`thread/resume`不会重发。`runtime.json`现在冻结动态toolset identity；缺失或不同toolset、
任何旧runtime版本和旧session都明确要求新建session，不做迁移。CLI也使用新salt/session root，旧CLI
thread保留但不会被当作当前工具面继续运行。agent管理没有被包装成business tool：Cowork固定使用
Codex MultiAgent V2原生`spawn_agent/send_message/followup_task/wait_agent/list_agents/interrupt_agent`。
派生runtime的显式`flat_tools=true`只让这些既有协作工具保持top-level function，因此OpenRouter与其他
Responses route收到同一普通function shape；它不根据provider名称/URL猜测，也不做协议翻译。
模型产生的V2 task/message使用Codex mailbox普通文本，不使用第三方Responses provider无法解开的
OpenAI内部encrypted-content。

同日已完成Cowork子代理产品层重新接线。App Server的`thread/started`、`thread/status/changed`、
`thread/list(ancestorThreadId:)`与`thread/read(includeTurns:true)`是唯一child identity/ancestry/status/history
来源；任意非当前root后代线程均拒绝。每个真实child使用稳定ThreadID→AgentID映射，右侧Agents、父子关系、
状态、逐agent连续对话、快速切换、双窗口、archived只读历史及CLI`/agents`/`/thread`均复用既有产品层。
child实时正文、工具、usage和approval按来源thread分流，不污染`@main`。用户明确消息通过派生App Server
`thread/subagent/message`直接进入同一root的AgentControl mailbox，不经过root模型、provider、旧MessageBus
或旧Orchestrator。

恢复路径按App Server persisted spawn graph取后代：relationship-filtered list允许只有inter-agent input、
preview为空的spawned child，普通全局线程列表过滤不变。App Server descendant `sessionId`表示child自己的
rollout session，Intatis不把它当root identity；树归属只来自relation filter或逐级`thread/read`父链证明。
child `thread/resume`重新携带host批准的完整provider/model/workspace/sandbox config，roleless nested child
沿真实父链继承。根resume response前重放的child usage先有界缓存，root确认与roster恢复后再按child分流。

用户配置的`CoworkCodexAgentProfile`是一套完整且secret-free的role identity：role只引用已冻结的
inference binding与已批准workspace；启动时host解析exact model/provider/base/query/credential/options，
credential仅进入独立child env key，role file不含secret。模型只能选择`spawn_agent`列出的`agent_type`
和同名`workspace` preset；raw model/reasoning override已隐藏。选中workspace后runtime复核其cwd/root仍属于
parent已批准roots并应用read-only或workspace-write sandbox。所有fork模式原生继承同一dynamic tool
surface；Intatis business host再按verified child identity、exact workspace lease和PermissionProfile执行。
同路径不同读写档位也不能共享记忆批准。

WorkTask现在由独立`CodexWorkTaskController`管理卡片DAG、revision、dependency、result/evidence与显式
`task_link_agent`关联；所有读-校验-图变换-append在同一个EventLog跨进程锁内事务完成，同revision并发
更新只有一个winner。root authority在controller初始化时冻结，child只能更新最后一条durable link event
指向的任务；in-progress合同/DAG/priority冻结。它不创建或调度agent。Goal卡直接读取/修改Codex thread Goal。现有
`cowork-agent-orchestration` Skill通过官方isolated `CODEX_HOME/skills`发现，指导模型只选择host批准的
role/workspace并使用V2控制面；production没有重新启用旧AgentLoop、Orchestrator、MessageBus或Goal续跑器。

`rename_session`不是宿主自行猜标题。只有authoritative dynamic tool list实际含它时，Code/Cowork
developer instructions才要求当前session的第一项用户任务在工作完成并验证、或确认真实blocker后，final
回复前调用一次具体任务/结果标题；日期、时间、SessionID和泛化`Session`占位词均禁止，后续轮次只在用户
明确要求时改名。Cowork提示同时声明只有exact root `@main`可调用，并要求其作为最后一个非run-control
call，之后才可`finish_run`/`stop_run`。输入标题在durable tool-call/model-history arguments中固定redact，
authorization identity只记录字符数，secret名称在authorization/prepared前拒绝；被接受的标题仍按设计进入
canonical settings event及成功ToolResult。

2026-08-30 用户明确把2026-08-23的exact-method直出定义为临时接线，而不是长期产品界面。
host仍把固定0.145.0 App Server的exact `method`、`type`/`phase`/`status`、turn/item identity与允许的
reasoning/plan delta作为bounded、redacted EventLog事实；默认macOS Code/Cowork presentation则在
execution-trace gate内使用typed semantic reducer。`item/started`、text delta与`item/completed`按exact
item identity归并为一条Command/File changes/Tool/MCP tool/Web search/Image/Collaboration/Subagent/
Plan/Reasoning活动；`thread/tokenUsage/updated`、Goal、permission、roster和message lifecycle只更新各自
专用组件，不再制造第二条transcript row。未知future method不静默丢弃，而显示本地化通用Runtime activity，
raw method与安全scalar保留为技术详情；backend `-IntatisShowExecutionTrace` / 环境开关继续恢复完整原始行。
官方`phase`仍原值决定消息分类：`commentary`是小号灰色中间文本，`final_answer`是正常回答，`nil`沿用
legacy样式；不得从正文猜phase。reasoning/plan text delta与assistant delta一样逐seq完整fold，只把
MainActor publication纳入50 ms fixed-window cadence；terminal与其他非delta仍立即barrier。Cowork child
live/durable event使用同一event ID，不再生成双份活动。CLI当前仍保留dim的exact event输出。
完整App Server payload、command output、arguments、paths与credential继续不持久化；语义展示是可丢弃的
UI projection，不是Responses provider translator、协议adapter、第二runtime或新的模型事实源。

同日补齐App Server重试与submission恢复接线。固定0.145.0的`error.willRetry=true`现在只形成一条
`Reconnecting`中间活动并随后续retry notification原位更新，不再误写普通`runtime_error`；official
turn terminal到达后该临时活动消失。`willRetry=false`才形成terminal failure。Code与shipping Cowork
`@main`都先原子保存`user_message + queued(attempt 1)`，只有Runtime启动/附件解析完成后才追加`running`，
因此bundle缺失、启动失败或发网前失败不再表现为“发送按钮无反应”，草稿只在本地提交已durable后清除。
root成功/失败/取消继续追加completed/failed/cancelled；retryable terminal只给当前thread最新submission提供
Retry，Retry创建一条固定可见的fresh continuation message与fresh SubmissionID，依赖official thread continuity
继续未完成工作，不盲目重放旧用户请求、附件或一次性context，也不改写旧失败事实。

bridge同时保留`error.message/additionalDetails/willRetry`、warning/config/deprecation/guardian、MCP progress/
startup、auto-approval、hook与structured thread status；无turn/thread的session notification也保存bounded
method projection；`item/agentMessage/delta`按唯一typed message path进入正文，不额外制造raw event row。
默认transcript会消费账户、搜索、平台与高频output类事件，backend trace仍可查看其接收的bounded事件事实。
`model/rerouted`因破坏exact inference binding而停止当前Session并fail closed；`currentTime/read`按官方schema
返回whole Unix seconds。固定experimental schema的11种server request与70种notification已加入inventory
gate：command/file/permissions approval、dynamic tool、currentTime与handler-gated `requestUserInput`为已接路径；
MCP elicitation、ChatGPT token refresh、attestation及两个legacy approval method继续明确unsupported/fail closed。
process/protocol若恰在`turn/start`确认与waiter登记之间终止，Session现在记忆同一terminal error并立即交给
late waiter，不再留下永久running。

同日已把 shipping Code/Cowork 的统计切到App Server真实可用的公开事件。host只读取固定0.145.0
schema的`thread/tokenUsage/updated.tokenUsage.last`：`inputTokens`、`cachedInputTokens`、
`cacheWriteInputTokens`、`outputTokens`、`reasoningOutputTokens`、`totalTokens`，并读取
`turn/completed.turn.durationMs`。只接受当前App Server thread的exact active turn；resume重放usage不
绑定新回答。同turn多次通知只保留最后一次官方`last`快照，不累计`last`，也不从thread累计`total`做
差分。随后用官方`final_answer` item ID（旧provider未给phase时只接受该turn最后一个non-commentary
回答）关联最终消息。新增additive EventLog事实`responses_usage`；Code/Cowork footer依次显示Input、
Cache Hit、Cache Write、Output、Reasoning、Total、Duration。Input保持官方完整`inputTokens`，不会再
减去Cache Hit。事件缺失时不虚构零值；malformed/负数让协议fail closed。internal-only
`rawResponse/completed`不是shipping依赖或fallback。CLI输出同七项原生字段。

本轮明确不接上下文窗口：Code/Cowork composer的旧Context条与Cowork `Last Turn`旧统计已移除；
固定catalog中的context metadata不作为当前UI事实。旧`turn_stats`、TTFT和context投影只保留给Chat、
iOS Chat与历史JSONL兼容，不再定义新Codex turn的统计语义。

认证边界已经纠正为“Intatis provider，而非 Codex 产品账号”：每个 session 使用隔离
`CODEX_HOME`，thread config 固定 `model_provider = "intatis"`、
`wire_api = "responses"`、`requires_openai_auth = false`。Intatis 已有 resolver 在内存中取得
exact credential，只通过子进程环境变量交给 runtime；不读取 ChatGPT login，不把 secret 写入
命令行、`runtime.json`、`models.json`、EventLog 或文档。owner-only `models.json` 通过官方
`model_catalog_json` 扩展点把 `auto_review_model_override` 绑定到当前选择的 Responses model，
避免第三方 endpoint 被隐式请求另一个 OpenAI model；这不是 Intatis 自写 reviewer。
采用Responses wire协议并不要求OpenAI API Key；真实turn只使用用户所选exact Intatis provider自己的
credential（例如第三方Responses provider的key），离线schema/fixture/build验证不读取任何provider key。

每个新 Code/Cowork session 在既有 session 目录内拥有：

- `codex-runtime/codex-home/`：Codex rollout/context/thread store；
- `codex-runtime/runtime.json`：schema-v2、owner-only 的 Intatis SessionID→已materialize Codex thread
  ID + exact runtime derivation + dynamic toolset映射；普通turn在首个`turn/start`接受后写入，Goal-first则在official
  `thread/goal/set`成功并验证返回Goal后写入；仅start、从未接受turn/Goal的空thread不落mapping；
- `codex-runtime/models.json`：无 secret 的 fixed model catalog。

`runtime.json`只接受当前exact `0.145.0-intatis.4`、当前0003 derivation和当前dynamic toolset identity。
same-version/different-derivation、`.3`及更早runtime、缺失/不同toolset、workspace/mode/ThreadID不一致或
resume失败都fail closed并要求新session；当前阶段
没有旧session迁移或兼容分支。

Codex rollout 是后续模型上下文的权威；EventLog 继续保存 Intatis UI/审计投影，但第一版只镜像
assistant 文本与 bounded/redacted tool presentation，不宣称能从 EventLog 重建完整 Codex command
history。旧 Intatis agent session 若已有 EventLog、却没有 `runtime.json`，不会静默丢上下文并新建
thread：Code/Cowork 明确失败并要求新建 session。可以回退源码版本，但没有隐藏旧 backend。

当前已经接通 macOS Code、macOS Cowork 与 `translatis code|cowork` 的文字 turn、streaming
assistant、工具状态、turn cancel、server-initiated command/file/permission approvals、自动审查、
thread resume 和 `/goal`→Codex thread Goal。macOS 图片附件可转为 App Server `localImage`；模型也可通过
shipping `generate_image`/`edit_image` business tools把新图片写入当前workspace。
macOS Cowork打开时会启动/恢复本地App Server并读取child/Goal控制面。固定App Server恢复active official
Goal前，Cowork host先通过official `thread/goal/get`与`thread/goal/set(status=paused)`持久化暂停，再调用
`thread/resume`；后续只在用户显式Resume时恢复active。UI只消费official Goal/turn事件，不再用legacy
EventLog Goal覆盖或额外调用第二个`turn/start`。第一方文档/浏览器、WorkTask卡、Goal卡、Agents与逐agent历史
均已接回；Knowledge、native Skills与Code/Cowork root Streamable HTTP MCP也已按上述边界接回。per-child
MCP、CLI attachment、`/clear`与旧exact-MCP `translatis exec`仍明确不可用，不会借旧runtime补齐；`translatis exec`
入口和旧实现都被禁用。
Codex binary 当前是
开发机 external runtime，尚未进入 App bundle；universal build、Cargo license closure、nested
Developer ID signing/notarization 是新的 release blocker，详见
`ThirdPartyNotices/OpenAICodexRuntime.md`。

针对exact OpenRouter配置，`ResponsesRuntimeRoute`恢复旧链路的request-owned
`options.provider` opaque passthrough：不枚举、解释、重命名或丢弃其provider-owned子字段，经
`intatis_responses_provider`进入`0.145.0-intatis.4`并原样写入`ResponsesApiRequest.provider`。
该通道不是generic whole-request `extra_body`，不能覆盖`model/input/tools/stream/reasoning`等host字段；
跨进程前仍做递归secret/transport-key扫描与结构资源边界。控制header、协议translator和proxy均不存在。
`.4`继续只在显式OpenRouter marker存在时省略上游额外制造、但exact route未声明的optional OpenAI controls：
`include reasoning.encrypted_content`、`parallel_tool_calls`、`prompt_cache_key`、`client_metadata`，并去掉
未声明的reasoning summary。Swift host通过Codex官方`web_search=disabled`关闭未配置搜索，并显式启用
V2 flat collaboration；普通business functions与协作control functions保持。用户的
`require_parameters`及完整provider routing object不修改。OpenRouter Cowork不再有root-only分支，也
没有协议翻译或另一provider fallback。
可复现patch与退出条件位于
`ThirdPartyPatches/OpenAICodexRuntime/`。

当前`.4`最终验证：0003 patch SHA-256为
`9cd57fc61366cb7410f6e551aa48ec762094e9a4edbfcbf0ae4670b7ba1f2285`；独立clean arm64 release-profile
validation binary SHA-256为`880dbbbd97ad3077a54296940c0c219a33ac153979126be7129a8998a4ff5685`，并自报同一
derivation。本机Translatis专用`~/.local/bin/translatis-codex`现已安装该exact binary；此前same-version、
different-derivation binary SHA-256
`61350e40759975bb4ae3669ddbbb73b1d25c4beddb34f2233abde7f7196cbde3`已备份为
`~/.local/bin/translatis-codex.before-cowork-reconnection-20260824`。official `~/.local/bin/codex`未改，
仍为`codex-cli 0.145.0`。

最终Rust在当前patch上完成MultiAgent V2 68/68、`codex-state` 153/153、App Server relationship-list
真实协议测试、apply/diff/fmt检查与release build。Swift Runtime/Skill/native integration现为58/58、CLI
process-owner 11/11、WorkTask 5/5、逐agent presentation 10/10、projection 8/8、inference presentation
9/9与Session protocol 4/4通过；`SessionNamingToolTests` 5/5、`SessionRenameAgentLoopTests` 2/2、
`IntatisPermissionTests` 56/56、`ToolRegistryLeaseTests` 27/27通过。CLI product、`TranslatisMac`无签名Debug
及`TranslatisiOS` Simulator无签名Debug build退出0。

真实`stealth/ox-alpha`验收没有换provider：root创建`ox_probe` child，child以自己的ThreadID精确调用
`browser_profiles({})`，durable outcome为`succeeded/committed`，返回`CHILD_TOOL_OK`，root返回`ROOT_OK`；
`/agents`显示`intatis/stealth/ox-alpha · effort max`，`/thread ox_probe`显示child完整历史。CLI完全退出后
重开同一session，仍恢复exact child/parent/model/effort/cwd/history，且恢复本身不发模型请求。

Finder/Xcode Debug GUI随后暴露并修复两个本地集成遗漏：应用发现到了同版本但旧derivation的
`~/.local/bin/translatis-codex`，以及`CodexBusinessToolHost.dynamicTools()`曾只弱持有实际executor、导致
注册工具可见但调用时报host unavailable。前者通过安装exact Intatis专用helper并保留旧文件备份解决，
后者改为request-owned dynamic tool closure强持有host，并新增生命周期回归。真实GUI新session使用
`stealth/ox-alpha`完成原生子代理树创建；其中两个后代子代理各自调用`browser_profiles({})`，两份durable execution均为
`succeeded/committed`，root等待完成并汇总两者成功；宽窗口roster显示main与各child的Ox Alpha标签，
选择child可独立看到其tool call与final回复。首次用免费Gemma route的尝试创建了两个child，
但child provider请求收到429；这次外部限流不作为runtime失败证据。

同一最终Debug App又以全新Cowork session `cowork_io2khx37`和免费`stealth/ox-alpha`完成首轮命名实测。
用户只发送“请计算17 × 19，并用一句话说明计算过程”，没有要求改名；模型先调用`rename_session`，侧栏与
页面标题实时从raw SessionID变为“17×19=323 口算问答”，随后才调用`finish_run`并给出最终答案。
EventLog顺序为rename function call→deterministic allow→prepared→`session_settings_updated(renamed,
displayNameSource=model_tool)`→succeeded/committed→`finish_run`，最后`turn_outcome(completed)`；rename的
durable input arguments保持redacted。这个实测证明当前提示、工具、命名服务和UI刷新整条链路已接通，
不是隐藏宿主自动命名。

历史gitignored `dist/Intatis-CodexRuntime-Preview.app`曾用`.3` host重建：Xcode 27
Debug build显式使用`ENABLE_DEBUG_DYLIB=NO`，bundle只含单一主Mach-O且不引用
`TranslatisMac.debug.dylib`；ad-hoc Hardened Runtime/strict codesign及最终交付路径真实启动均通过。主
可执行文件已随本补丁重建并签名，SHA-256为
`d287bbad2925c0211f9356afd8af1110ca317f2e073f781ab63e6878c19b892a`；LaunchServices从最终路径
启动后精确进程路径读回且持续运行。旧`.2`预览保留为
`dist/Intatis-CodexRuntime-Preview-0.145.0-intatis.2.app`。这些旧host预览不满足当前`.4` version gate，
不能作为当前shipping验收。当前外置arm64 `intatis-codex` SHA-256为
`880dbbbd97ad3077a54296940c0c219a33ac153979126be7129a8998a4ff5685`；此前same-version旧derivation与
`.3`均以分名备份保留，official `codex`未覆盖。
当前仍未bundle runtime，正式发行blocker不变。

本轮另生成gitignored `dist/Intatis-Responses-Events-Preview.app`供事件直出试用。该0.55 arm64 Debug
包使用`ENABLE_DEBUG_DYLIB=NO`，`Contents/MacOS`精确只有`TranslatisMac`，`otool -L`无debug/preview
dylib；ad-hoc Hardened Runtime strict codesign通过，最终主可执行文件SHA-256为
`8c553d6d631acd7334cf52ea3d77b58689d840ff81ec0fa76d918ea799d7c3c9`。LaunchServices已从该最终
路径启动，精确进程路径读回并持续运行。该预览仍依赖开发机已安装的exact external runtime，不替代
binary distribution closure。

本轮再生成gitignored `dist/Intatis-Responses-Usage-Preview.app`供七项原生usage footer试用；使用独立
`com.Vita0818.TranslatisMac.ResponsesUsagePreview` bundle identifier、单一arm64主Mach-O及ad-hoc
Hardened Runtime签名。离线`message-footer` fixture已由Computer Use真实读回全部七项：Input 18,420、
Cache Hit 15,280、Cache Write 3,140、Output 826、Reasoning 412、Total 19,246、Duration 7.40s。
该预览不读取配置、credential或session，也不替代正式签名/公证门槛；它只证明footer布局，不能证明
production App Server事件接线。

随后真实Cowork会话暴露第一版接线错误：EventLog确实收到`thread/tokenUsage/updated`，但没有
`rawResponse/completed`，因此没有生成任何`responses_usage`。固定0.145.0 schema与同一Codex rollout
证明公开notification的`tokenUsage.last`已经包含完整六项数值，`turn/completed`也包含`durationMs`。
当前源码已删除对internal-only raw event的统计依赖，改为上述公开事件。新增gitignored
`dist/Intatis-Token-Usage-Event-Preview.app`是生产界面/配置路径的独立bundle-ID试用包，不是renderer
fixture；单一arm64主Mach-O、ad-hoc Hardened Runtime strict codesign均通过，主程序SHA-256为
`d68e95c532c6cc88d57299988e055c43f18343c29a4dfe42abd828eba9645d6e`。该包尚未替用户发送真实provider
turn，避免擅自读取credential或产生计费；旧EventLog也不会被补写，必须以新turn验证。

本节覆盖本文后面所有把 Code/Cowork shipping path 描述为 `AgentRuntime.code`、`AgentLoop`、
`Orchestrator`、Intatis PermissionEngine 或 EventLog-only model history 的旧段落；这些段落现在只描述
仍在仓内的 legacy/manual-rollback 实现与兼容测试，不能作为当前产品行为引用。

## 版本与发行状态

- 本轮开始时当前分支为 `main`，并跟踪 `origin/main`。仓库没有 Git tag；commit标题不是产品版本
  事实源，`project.yml` 把当前工作树的产品基线定义为 `0.72 (72)`。
- `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` 已推进为 `0.72 (72)`。两个仓库参考
  Info.plist、README、文档入口和发行脚本使用同一基线。
- v0.72版本一致性门与覆盖图片、hosted search、official `request_user_input`、Providers、Protocol、CLI及
  Cowork/SharedUI的聚焦矩阵通过；其中Codex Runtime为77/77、SharedUI选中44/44、CLI为50项且8项真实付费
  smoke按设计skip。CLI product、`TranslatisMac` universal Release与`TranslatisiOS` generic Simulator Debug均
  构建成功，两个bundle读回`0.72 (72)`；Mac主程序是`x86_64 arm64` universal Mach-O，`Contents/MacOS`
  只含`TranslatisMac`且不引用Debug dylib。完整`swift test --disable-automatic-resolution`再次在SharedUI组合
  顺序中静默等待，约90秒无新输出后按有界规则中止；这与既有间歇性XCTest async waiter缺口一致，不能
  记为完整通过，CI必须继续保留wall-clock timeout与sample。
- 本机`/Applications/Intatis.app`已安装同一v0.72 universal Release staging，并使用
  `TranslatisMac.DeveloperID.entitlements`完成ad-hoc Hardened Runtime签名；deep strict codesign通过，
  audio-input=true、allow-jit=false、disable-library-validation=false，无quarantine。安装包与staging逐文件
  一致，bundle identifier为`com.Vita0818.TranslatisMac`，主程序SHA-256为
  `10084be0087c45ac67bda624c08dbd66044267063867bdd62aa77516e6f34adc`；Computer Use从最终路径启动成功，
  进程路径读回`/Applications/Intatis.app/Contents/MacOS/TranslatisMac`。被替换的`0.71 (71)`保留在
  `/Users/vita/.Trash/Intatis-before-v072-20260904-230340.app`。
- 该安装是本机开发预览，不是Developer ID公证发行：内置arm64+x86_64 Codex/document runtime closure、
  Developer ID secure-timestamp签名、公证、staple、Gatekeeper与干净账户安装仍是独立release gate。
- macOS 只发行 `TranslatisMac` Developer ID/direct-distribution 产品；不做 Mac App Store。
  旧 `TranslatisMacAppStore` target/scheme、`TRANSLATIS_MAC_APP_STORE` 条件编译分支和
  `TranslatisMac.AppStore.entitlements` 已于 2026-08-21 删除；`.macAppStore` 仅保留共享协议解码/
  隔离测试兼容，不生成第二个 App。
- 当前宿主有一个可由发行脚本精确选取的 Developer ID Application identity；
  `Intatis-Notary` Keychain profile 可访问。2026-08-18 只读查询确认历史两条 submission 均为
  `Accepted`、`In Progress=0`；v0.72 尚未提交 Apple，也尚未取得 App/DMG staple 与 Gatekeeper
  全链路证据，因此仍不得描述为正式 release。

## 当前产品面

### macOS

macOS 是完整产品：Chat、Code、Cowork、Settings 和本地诊断导出。

- macOS 现有侧栏增加了第一版文件夹项目：用户选择一个现存本地文件夹后，Intatis 只在
  app support 的 owner-only binary `projects-v1.plist` 中保存稳定 ProjectID、规范化路径和
  单一 `SessionKind` 与同模式 SessionID 引用；不会在用户文件夹内创建隐藏数据库，也不会移动或
  复制 session 目录、EventLog、artifact 或 runtime。Chat、Code、Cowork 各自显示独立项目目录，
  相同文件夹可在不同模式分别登记，但任何项目和会话都不得跨模式。项目在当前模式侧栏中是默认
  收起、按需展开的单行文件夹，不再有固定高度 Projects 区域或项目主页；归入项目的会话只显示在
  对应文件夹，其他会话显示在 `Unfiled`。文件夹内新建只创建当前模式会话，执行语义不变：Chat
  不获得文件夹能力，Code/Cowork 每次新建时由用户重新确认 exact 项目文件夹，然后仍只把
  security-scoped bookmark 写入该会话自己的 `workspace-access.plist`。移除项目只删除分组记录，
  不删除项目文件夹或任何会话；本版尚不提供把既有 Unfiled 会话移入项目、项目级记忆、共享
  context、设置继承、任务/Goal/Agent 所有权、文件索引或项目文件夹 rename/move 跟踪；文件夹
  改址后需移除并重新添加项目，既有 session 数据仍保留。
- Chat 使用无 Intatis Tools 的 `ChatLoop`，支持 OpenAI-compatible streaming、provider/model/
  variant 配置、provider-hosted search wire、citations、会话历史和本地图片附件。macOS Chat 已移除
  composer 中独立的“按提示词生成图片”入口，改为直接复用 Cowork 的 paperclip、系统文件选择器、
  多文件拖放和草稿附件菜单；旧 `artifact_added` / `artifact_progress` 仍可回放，不改历史协议。
  附件先进入 session `ArtifactStore` 并读回校验，`user_message` 只保存 `ArtifactID`；当前轮及后续
  历史重建时再解析为 provider `ImageAttachment`，不会把 base64 图片写入 EventLog。
  每次 Send 只按当前 exact route 的显式 capability 与 adapter dialect 可选地提供 hosted search；
  不支持、未知或未适配时在同一路由静默发送普通 Chat。
- macOS/iOS Chat 在成功回合落盘后可启动独立、无工具、无 web search 的隐藏标题请求，复用该
  回合冻结的 exact provider/model 与 `turn_outcome(completed)` seq 水位；后台重放只能读取该水位
  及以前的 EventLog，后续由其他 route 完成的内容不会泄入旧标题请求。它从该冻结前缀中只读取
  session 起点可证明串行的最早三个
  completed Chat 回合，不写入消息历史、turn stats 或 busy/Stop 状态；每进程、每 session 最多
  三个逻辑 generation，前两次可精确返回 `NO_TITLE`，第三次必须给出标题。输出通过严格 stream、
  长度、格式、路径/长标识与敏感内容验收后，才在跨进程锁内执行 Chat-only set-if-absent rename。
  stream 只接受一个完成标记与正常 EOF；usage 是元数据，可出现在完成标记前或后，以兼容官方
  provider 的尾随 usage chunk，但完成后的正文、citation 或重复完成标记仍会拒绝整次标题。
  手工 Rename 永远优先，自动命名不改变 recent-session 排序；生成、验收或 EventLog append 前的
  失败、取消、超时与旧/歧义历史均静默保留默认名称。若 rename 已 append、仅 projection/通知失败，
  EventLog 中标题已是 canonical truth，UI 可在刷新或重启后恢复。
- Code 与 Cowork 不增加宿主自动命名触发器。Code system prompt 与 Cowork coordinator/exact `@main`
  system prompt 要求模型在当前 session 第一轮用户任务完成验证或确认真实 blocker 后，若 authoritative
  tool list 含 `rename_session`，以具体任务/结果标题调用一次；标题不得使用日期、时间、SessionID 或
  泛化占位词。后续轮次只在用户明确要求时改名。当前App Server共享developer instruction与dynamic
  surface，因此Cowork child可能看到相关文字/schema；同一提示明确写明descendant永不调用，host也会在
  audit前拒绝。exact `@main`把`rename_session`作为最后一个非 run-control tool，若还需
  `finish_run` / `stop_run`，只能在改名成功后调用。
- Code shipping path 使用固定 Codex App Server thread/turn 与其原生 workspace tools、sandbox、
  approval/auto-review 和 context store；第一方document/browser通过官方dynamicTools callback复用既有
  WorkspaceLease/Permission/executor链；Knowledge通过同一dynamicTools host与既有Knowledge authority
  接回，Skills由Codex native discovery接回，Code/Cowork root Streamable HTTP MCP通过isolated native
  config接回并对Cowork child原生禁用。
  原共享`AgentRuntime.code`、Intatis managed terminal、legacy Skill tools与旧MCP client仍不在新Code
  inference path；无法精确表达的入口明确失败，不会转回旧内核。
- 非 iOS 的 IntatisTools 文档控制面已升级为 registry v5，并严格按外部依赖原子操作拆分。当前
  Code/Cowork shipping inference 仍由官方Codex App Server负责；文档/浏览器registration只经
  `thread/start.dynamicTools`直接注入，不经MCP且不会被旧内核当作fallback。IntatisTools的新session
  registry 不再注册 `document_ocr`、`document_render`、`document_export_pdf`、
  `document_write` 或旧 `document_read`。
- Office/HTML/EPUB 初读固定为 `read_docx` / `read_pptx` / `read_xlsx` /
  `read_html` / `read_epub`，续读固定为对应五个 `continue_*_read`。初读 schema 只有
  `path` 与可选 `maxCharacters`；续读另要求 host 生成的 opaque cursor。实现固定调用
  Docling 2.117.0 `DocumentConverter`、`iterate_items`、ranged
  `export_to_markdown` 与 `HierarchicalChunker`；cursor 绑定 exact format、source SHA-256、
  element 与 character offset，来源变化时 fail closed。Intatis 不建立文档 AST、raw Docling dict
  parser 或格式对象遍历。五组 reader/continuation 均为 `structured_read_only` +
  `safeToReplay`，继续沿用 Intatis deterministic allow；独立解析失败只形成 failed observation。
- PDF 面固定为 PDFKit `inspect_pdf` / `read_pdf`、Docling +
  Tesseract 5.5.3 英语/PSM 3/full-page/Markdown 的 `ocr_pdf`，以及 PDFKit
  `PDFPage.draw` crop-box/144 DPI/白底/annotations/单 PNG 的 `pdf_render_page`。
  inspect/read 返回 host SHA-256、字节数和页数；image-only read 返回 typed `ocr_required`；
  OCR 必须带 exact `expected_source_sha256` 且 `doNotReplay`。没有 searchable-PDF、
  OCR engine/language/PSM selector、多页 bundle 或非 PDF 隐式 render pipeline。
- PDF 导出拆为 `docx_export_pdf`、`pptx_export_pdf`、`xlsx_export_pdf`、
  `html_export_pdf`：前三者分别固定 LibreOffice Writer/Impress/Calc PDF filter，HTML 只把
  PathConfinement 审查并冻结的源文件/显式本地资源机械复制到私有 staging 后直接调用
  `WKWebView.createPDF`。HTML 不再经过 lxml 语义清洗/改写；导出后不自动 render，也没有
  pdfcpu/PDFKit preview 或第二层 semantic verifier。
- 写入面只有 17 个 DOCX、7 个 PPTX 和 5 个 XLSX exact tools。每个名称固定到
  python-docx、python-pptx 或 openpyxl 的一个公开 API/不可再分生命周期操作；model schema
  不含 `format`、`mode`、`operation(s)`、`backend` 或 `engine`。HTML/EPUB 写、
  PPTX/XLSX chart、range/style/table/name、公式创建/解释、recalc、preview 和写后 verifier
  均不再存在。Python route table 只把 host-owned concrete tool 名映射到 concrete function；
  Swift 只冻结来源/辅助资产、做 CAS/staging/原子提交并封装真实 ToolResult。
- `compile_latex` schema 已移除 engine，只解析固定 runtime 的 `bin/tectonic` 0.15.0，
  使用 `--untrusted --only-cached --outdir` 的固定 argv；没有 `command -v`、shell string、
  latexmk/xelatex/pdflatex 探测或 fallback。Tectonic 缺失、版本不符、离线 cache 缺失或编译失败
  均 typed fail closed。
- 共享 document process lane 继续保留 WorkspaceLease/CapabilityLease/PathConfinement、输入身份与
  SHA-256、owner-only same-parent staging、CAS、默认断网、Seatbelt/受控 LibreOffice socket、
  timeout/cancel/descendant cleanup、stdout/stderr/生成物预算与 durable execution；另增加独立
  2 GiB aggregate RSS ceiling。共享层不知道段落、幻灯片、cell、OCR 语言或 HTML 渲染策略。
- TranslatisMac release 现在必须由 `TRANSLATIS_DOCUMENT_RUNTIME_ARM64_ROOT` 与
  `TRANSLATIS_DOCUMENT_RUNTIME_X86_64_ROOT` 提供两个 fixed roots，并在 bundle stage 前后及外层
  App 签名后复验 manifest、全文件 hash、SPDX SBOM、license closure、Mach-O architecture/load
  commands/RPATH 与自底向上 Developer ID 签名。运行时由 active architecture 只选 bundle root；
  CLI/debug 才可使用受控 user-managed development root。当前仓库只有 release spec、validator 与
  staging gate，没有真实双架构已签名 roots、notarized App 或 clean-machine acceptance 证据，
  因此发行制品仍是明确 blocker，不能把本机旧 runtime smoke 当作 shipping proof。
- 历史 `ToolCapability` raw values、旧 aggregate tool names、PermissionIntent 和 EventLog 继续可
  decode；legacy `documentRead` 最窄映射到五组 reader/continuation，其他 aggregate capability
  最窄映射到对应 concrete v5 registrations。fresh lease 不再签发这些旧 raw values；除
  `inspect_pdf` / `read_pdf` 按产品合同共享 `readPDF` 外，每个 exact tool 使用同名 concrete
  capability 与独立 exact PermissionIntent action。registry identity 是
  `intatis.standard.v5` / `intatis.cowork.v5`，因此 v4 durable authorization 不能重绑到 v5。
  read-only Cowork worker 获得 inspect/read、五组 reader/continuation 与 `ocr_pdf`；render/export/
  write 仍只向 read-write worker/coordinator 签发。iOS Chat target 继续存在且不链接 IntatisTools
  或任何 macOS document runtime。
- 顶层`image_model`解析与`ProviderImageGenerationToolService`现在也是shipping
  `generate_image`/`edit_image`的唯一host-owned route。`CodexBusinessToolHost`直接注册两个exact
  descriptor并把service注入`ToolContext`，Code/Cowork/CLI均通过App Server `item/tool/call`进入既有
  permission/durable executor。generation调用`images/generations`，edit调用multipart `images/edits`；
  edit仍只接受单张PNG/JPEG/WebP、最多50 MiB、输出新PNG，不支持mask、多参考图或原地覆盖。model不能在
  arguments中选择provider/model，配置或route失败时也不允许旧AgentLoop、另一provider/backend或隐藏
  fallback。legacy Loop里仍存在同名工具不再被当作完成证据；shipping动态目录与executor测试才是证据。
- macOS shipping Code/Cowork的用户图片附件走session `ArtifactStore`验证后转换为App Server
  `localImage`，不会把base64或路径写入EventLog；CLI attachment仍明确不可用。旧AgentLoop的durable
  active-history descriptor、FCO图片与sidecar/compaction规则只保留兼容测试，不定义新Codex rollout历史。
- Cowork显式Retry仍先由纯`SubmittedIntentRetryPlanner`按canonical task状态决定：outbox
  canonicalization继续保持attempt 1；restored queued exact task不递增attempt或改写queued事件，
  restored running已经由Orchestrator durable requeue到下一attempt时只对齐该exact attempt；
  created/assigned/running或不一致状态fail closed。failed/cancelled root若没有ContinuationRun，仍可在
  同一SubmissionID/root task上递增attempt；若绑定的ContinuationRun已经terminal，GUI不会复活旧Run
  或调用`Orchestrator.retry`，而是通过现有outbox/EventLog admission创建一条可见的短continuation
  message、全新SubmissionID、root task和Run，并复用原提交冻结的`@main` exact binding。旧Run与旧失败
  submission保持terminal；新提交出现后，旧错误仍可审计但不再保留可重复点击的Retry按钮。
- macOS Chat/Code/Cowork 与 iOS Chat 的 composer 已在 Send/Stop 左侧接入同一个语音输入按钮。
  第一次点击开始录音，第二次点击停止并通过顶层 canonical `transcription_model` 指定的 exact
  provider/model 调用 `audio/transcriptions`；转写结果追加到完成时仍然可编辑的当前草稿，不自动
  发送。单模型 recorded-file runtime 已按 Flotis 当前实现迁入：默认 WAV/16 kHz/mono，录音 generation、
  stale-file 清理、stop/file-size 校验、取消/cleanup 与 disk-backed upload body 均保留；不再强制设置
  AAC bitrate。compatible adapter 使用 multipart，exact OpenRouter adapter 使用 JSON-base64
  `input_audio`。字段缺失或 adapter 不受支持时明确失败，不使用当前 Chat 模型或固定模型 fallback。
  专用 transcription provider 可为空 `models`，不会进入推理模型菜单；没有新增设置页或第二套模型
  配置。录音只使用 owner-only、有时长/大小边界且必清理的临时文件，Send 前不进入 EventLog 或
  ArtifactStore。Flotis 的多模型对比、全局快捷键、review/clipboard 与输入法未迁入。macOS shipping
  target 同时保留 TCC usage description 与 Hardened Runtime 最小 audio-input entitlement；不启用
  App Sandbox，也不重新引入已删除的 App Store target。
- Cowork shipping path 使用 Codex root thread 和 upstream collaboration/subagent runtime；Intatis
  `Orchestrator`、FIFO scheduler、MessageBus/Mediator与独立reviewer/verifier不再处理新turn。
  右侧Agents/WorkTask/Goal复用既有UI壳，但数据分别来自verified Codex descendants、事务化
  `CodexWorkTaskController`卡片与official root thread Goal；逐child history/usage/permission已接通。仓内
  legacy AgentLoop 不同步递归调用另一个 AgentLoop。右侧 Agents 区域中的 legacy ordinary agent 可作为
  当前窗口的只读对话选择；列表保留 session 历史上所有 durable agent，detached identity 继续
  可点击并由原状态图标显示已移除，当前选择不会跳回 `@main`。新窗口默认显示 `@main`，
  `@permission-reviewer` 等控制面 identity 仍为不可选择的状态项。

以下从`permission_reviewer_model`到single-pass sidecar、ContinuationRun/mailbox的细节只描述仓内
legacy/manual-rollback AgentKernel/Orchestrator兼容路径。shipping Codex使用official auto_review、root Goal、
native child/mailbox与App Server rollout；不得把下列配置或协议当成新turn必须再包的一层本地控制面。

- macOS/CLI 高级配置已接入 canonical 顶层 `permission_reviewer_model`，只接受已配置的
  `<provider>/<model-id>` base profile；没有新增 UI。字段缺失时仅在配置解析层一次性继承同一 JSON
  文档的顶层 `model`；兼容来源缺失/未知、显式空值、错误类型、未知/不可解析 route 或整份已选配置
  损坏/不可读均 fail closed，不会回退 UI
  selection、Cowork session default、live/historical `@main` 或后续 rebind。fresh 七事件 bootstrap 与
  restore/re-enable 都使用独立冻结的 reviewer exact binding；每个审查 generation 仍从该 binding
  fresh-resolve provider wrapper。GoalVerifier 继续冻结首个可解析的 exact `@main` binding，与 reviewer
  配置互不替代；未增加 session/EventLog schema 字段。
- Cowork automatic 权限请求使用 single-pass same-call sidecar。request-owned provider-facing business schema
  增加 required string `__intatis_authorization_context`；对 `strict:true` function，装饰后的 `required` 必须覆盖
  全部 `properties`，同时保留 `additionalProperties:false`；装饰器递归验证 strict object，并在发网前
  typed fail closed。`tool_search` 本身不改，但其 provider-bound `tool_search_output` 内延迟发现的 function/
  namespace 子工具同样装饰，durable output 保留原始 schema。原 `ToolDescriptor`、registry/business required 与
  executor schema 不变；宿主仅在 deterministic gate 实际进入 automatic ask 时消费并验证该字段，
  deterministic allow/deny 忽略它。acting model 在原业务 function call 中用这一句话概括为什么 exact action 服务当前任务，
  不再二次调用 acting provider，也不复制 `request.messages`、完整 PDF/tool output 或全量图片。宿主在任何
  原业务 schema 校验、durable model history、EventLog 或 executor 之前拆除 sidecar，只用 canonical
  business arguments 计算 intent/path/network/action preview。sidecar 的 business digest 始终绑定这份 stripped
  canonical arguments；`ResolvedToolAuthorization.normalizedArgumentsDigest` 则独立绑定 registration 的
  `authorizationArgumentIdentity`，允许知识库等工具使用 host-resolved identity。两个 digest 各自复核自己的
  canonical representation，不再互相比较。valid sidecar 只在当前
  turn 的 acting-model 内存 conversation 中保留，作为下一次 function call 的正确格式示例；durable history
  仍只保存 stripped business call。automatic ask 的 reviewer 收到完整 canonical safe business arguments、
  完整 same-generation sidecar，以及 request/task/call/tool、ResolvedToolAuthorization、gate、lease、intent
  等机械宿主事实。live prompt 明确不发送 TaskContract objective/role/deliverable、causal userGoal、用户消息、
  assistant/history、PDF 或图片原文。raw sidecar 与 reviewer transient exact-args 副本均不落 EventLog 或
  permission lifecycle；`permission_request.context` 只保存 generation/snapshot/digest/status receipt。
  missing/malformed/secret-bearing sidecar 是 acting-model tool-input failure：只追加 failed/runtimeFailed
  `tool_result`，不创建 `permission_request` / `permission_resolved`、不调用 reviewer，也不消耗 permission
  denial fuse；同一 business args 后续补正仍能进入 reviewer。failed/denied tool result 作为 observation 返回
  当前模型轮次，不再登记、恢复或在 final 前检查副作用完成 ledger，也不会把随后正常的 final cast 成整轮失败。
  sidecar 与 exact call/generation/business digest 无法绑定时仍单独 typed fail closed。manual/nonautomatic flow
  不接收 transient input，若模型仍发送
  保留字段则在 business execution 前以 redacted audit + `authorization_context_mode_mismatch` 拒绝。图片存在
  本身不再 blanket deny。最终 reviewer 仍无工具，只接受非空 plain-text reason +
  末个非空行唯一 exact ASCII `ALLOW` / `DENY`。共享 prompt 建议 reason 约 240 Character，但 parser 不再
  因超长单独拒绝；宿主先扫描完整 reason 的敏感信息，再有界化任何需要交付的摘要。旧 JSON/code fence、
  缺失/重复/非末行 marker、空 reason、tool call、无 completion marker、非成功 finish、
  timeout/provider/cancel/persistence failure 均以 secret-free 细分类型 fail closed，risk 始终来自 host gate。live bound review 的
  model-authored reason 与 provider diagnostic 可能复述 transient input，因此 durable settlement/tool-result
  只使用固定宿主文案。automatic responder 缺 bound-invocation overload、cached/active duplicate 缺失或更换
  transient invocation、recovered automatic allow 再交付，以及 Cowork 误配 in-engine reviewer 均 fail closed。
  唯一没有 acting-model invocation 的 automatic `agent.attach` 只能由 `Orchestrator` 通过 dedicated host-admission
  entry 提交，并复核 exact task/tool/authorization/workspace identity 与先行 durable attach/lease events。
  acting model 仍可把相同文字作为普通 assistant 文本输出并按既有消息规则持久化，malformed acting-provider
  error preview 仍依赖通用 bounded/secret sanitizer。live 也没有固定 sidecar byte ceiling 或
  `review_input_too_large` admission；未来只能从真实 route budget 推导整份拒绝上限。真实 provider sidecar
  smoke 尚未运行。
- Cowork final turn 在 provider 正常完成且没有 tool call 时，原子发布 final message/model-history、idle
  与 completed outcome；不存在基于既往 tool denial/failure 的二次副作用完成拦截。旧日志中其他原因造成的
  failed/interrupted turn，其先行完成气泡仍会被展示投影纠正，失效的
  final assistant 也不再进入下一次 provider history。exact `@main` root 另可见模型主动调用的
  `finish_run` / `stop_run`：参数只有有界 reason，session/run/Goal/submission/root TaskID 全由宿主绑定；
  close installation 先形成 actor-local admission/authorization tombstone，EventLog 对每个 RunID 安装
  first-write durable claim 后才等待既有 admission 并 drain 同 run 的其余 task/message，恢复也先兑现该
  fence。普通自然语言 final 不伪造显式 claim；root failure/timeout、用户取消与 session shutdown 分别
  保留 runtime/user/hostLifecycle source，并在 provider/tool cleanup 前关闭精确 run。
- mailbox wake contract 冻结 1–8 个 exact MessageID，并只按 ordinary message、information request、
  information reply receipt 三类分配窄 authority。ordinary message 是 one-way、
  无通信工具；information request 只允许对 frozen RequestID 做一次 `reply_message(inReplyTo:)`；
  reply receipt 不允许 ACK，但允许在确有新问题时用 `request_information(based_on:)` 建立 fresh
  RequestID，并保留同一 conversation root。这样 `information_replied` 只终结一个 correlation，
  不终结长期协作。失败只在同一 TaskID 上有界重试；task completion、candidate progress 与 consumed
  IDs 同批落盘后才 ack。legacy nil binding 的歧义或耗尽 lineage 保持 pending/fail closed，新消息仍
  可独立投递。委派只由 coordinator 显式调用 `delegate_task`，worker 不再拥有请求委派工具或对应
  mailbox authority。WorkTask 工具的 reviewer preview 已补齐 bounded semantic fields，并明确 `wt_…`、
  AgentInvocation `task_…` 与 latest revision 的边界。普通 worker 的同名 `task_update` 现由
  `update_bound_work_task` capability 投影为窄业务 schema，只提供 `task_id`、
  `expected_revision`、`progress_note`、允许的 `status`、`result` 与 `evidence`；manager 的完整
  状态、DAG、priority、retry/cancel 更新面保持不变。worker 未知/管理字段由 closed schema
  在授权与执行前拒绝，宿主仍继续核对当前 invocation binding、revision 与真实状态转换；automatic
  模式既有的 request-owned authorization sidecar 装饰不变，不属于 WorkTask 业务字段。
- Cowork 中每个 agent 的文件、Git、文档、浏览器文件与 terminal 工具仍只作用于自己的单一
  `workspaceRoot`。具有 `spawn_agent` 的 coordinator 提示词会在预知目标位于根外或收到
  out-of-workspace denial 后停止直接重试，改为按目标绝对目录创建默认只读的子 agent，再用
  `delegate_task` 交付目录内工作；确需修改时才请求 `read_write`。工具不可用或扩展被拒时只报告
  所需目录/访问级别的 blocker，不伪称完成；Code 与普通 worker 不宣称该恢复能力。`spawn_agent`
  schema 不再接受 raw `model`：省略 `inference_profile_id` 时继承调用者 exact binding，显式填写时只
  接受 host-approved profile ID。普通工具 executor error 会结算为 failed/unknown observation 并返回
  同一 turn，不再升级成通用整轮终止；旧 task attempt 的 `doNotReplay` 边界只禁止自动重放，继续时
  由用户创建新 Run。
- Cowork coordinator 的固定提示词以主动执行为默认：每轮先建立 execution objective、交付物、约束
  与验证方式，检查 catalog 并激活/读取明确相关的 exact Skills；非简单任务维护最小 WorkTask DAG，
  在开始时识别适合并行、专业复核、多模态或独立 workspace 的分支并在收益成立时尽早委派，child
  运行期间继续自己的关键路径，最终验证报告、结算 WorkTask 并持续推进到验证完成或真实 blocker。
  该行为不自动创建 durable Goal，也不改变最小团队、工具、lease、权限或 worker 能力边界。
- Settings 已收敛为渐进披露结构，保留 provider、模型、MCP、renderer、声明、配置和本地
  诊断 ZIP。诊断包尝试采集系统/App/session 诊断源，但排除原始会话、工具参数/结果、
  endpoint、credential、workspace、artifact、browser profile 与 bookmark；不远程上传。

### iOS

iOS 是结构性 Chat 子集，只链接 Core、Protocol、Providers、Conversation、Artifacts、
Multimodal 与 SharedUI。它支持 provider 配置导入、Chat/history、当前托管搜索 wire、
citations、Chat 自动命名、图片生成、输入栏语音转写和当前系统原生界面，但不链接 Tools、
Permission、AgentKernel、Cowork、MCP 或本地 workspace/shell。其 Chat 与 macOS 共用同一个
exact-route hosted-search planner；自动标题通过 exact-session metadata relay 更新对应 header/row，
切换到其他 session 不会把迟到标题写到当前会话。

### CLI

Swift-native `translatis` 提供 Chat/Code/Cowork REPL、managed execution、Skills、per-agent
profiles 与外部 MCP client。macOS/Linux 的 stdio、sandbox、bwrap/guard 和 PTY 能力按
实际 host 支持情况 fail closed。

## OKF / RAG knowledge bundle 当前状态

- 仓库已固定 Open Knowledge Format v0.2 的 `SPEC.md` / `LICENSE.md` / SHA-256 inventory，
  并新增非 iOS `IntatisKnowledge` product。该模块实现 Intatis OKF RAG Profile 0.1、九份冻结
  JSON Schema、bounded Yams OKF reader、deterministic Validator、validation receipt、
  `KnowledgeBundleBuildService`、immutable multi-version store、embedding/dense/BM25/RRF/reranker
  runtime contracts、mount registry、source-locator replay 和 `search_knowledge`。
- 高级 JSON/JSONC 配置现有 canonical `embedding_model` 与 `reranker_model` 两个独立 role；Mac、
  CLI 和共享 provider catalog 将它们解析为与 Chat/Agent route 无关的 exact binding。两者任一缺失
  时 Code/Cowork 不广告 Knowledge tools，并在现有状态面明确提示配置；不会退回当前聊天模型、
  Apple NaturalLanguage 或 embedding-cosine seam。首发 native adapter 为 OpenAI-compatible /
  OpenRouter embeddings 与显式 `translatis:siliconflow-v1` / `translatis:cohere-v2` / OpenRouter rerank
  dialect，credential 只在
  真实网络 dispatch 时解析。Mac/CLI 在广告工具或显示 `knowledge ready` 前，复用真实 provider
  构造器的同步 route 预检；缺 endpoint、维度或合规 adapter 时工具保持缺席且显示具体配置错误，
  预检不解析 credential、不联网、不取得目录 authority。adapter 现在还会校验并返回 provider 报告的
  token 与 billable units。Knowledge role 的 model-level adapter/options 会保留到 exact route，但同一
  provider 下的 embedding/reranker model 不会进入 Mac/CLI 普通 inference profile 或模型菜单；
  opt-in smoke/quality harness 可按 exact route 汇总这些原始计数，但不根据可变价目表臆算金额。
- Code、Cowork exact `@main` 与 macOS CLI 已通过 `HostToolRegistryAugmenter` 接入 closed-schema
  `build_knowledge` 和 path-aware `search_knowledge`。模型继续使用已有文件/文档工具阅读与整理，
  写出 OKF draft；build 工具只负责 deterministic canonicalization、configured document embedding、
  validate 与 atomic publish。两个工具都走原有 CapabilityLease、PermissionEngine、durable
  prepared/result/settled 和参数脱敏链，未新增 Knowledge 管理 UI。Chat、iOS、permission reviewer、
  GoalVerifier 与普通 Cowork worker 不获得这两个工具。
- `store_path` 可位于当前 WorkspaceLease 内，也可为用户自然语言点名的外部绝对目录。外部目录不
  扩大 WorkspaceLease，而由 exact `KnowledgeLease` 授予单一 root/operation/agent/session authority；
  Mac bookmark 只写入 session-owned、binary、owner-only `knowledge-access.plist`，CLI 在权限通过后
  生成 exact authorization reference。过宽/敏感目录、父目录替代、root replacement、只读 lease
  mutation 与 identity drift 均 fail closed；bookmark 文件及 sidecar lock 都执行 no-follow、owner、
  regular-file、single-link 边界，bookmark 可按 exact path 撤销，活动 scope 仍须先 drain。
- 建库与查询保持分离。build service 接收 workspace 内已授权的 OKF draft root，以及 workspace store
  或独立 KnowledgeLease 绑定的外部 store；它在任何 embedding 前做 secret scan，用 host chunker
  生成 grounded chunks，只在完整 Validator 通过后原子 publish。更新既有 store 必须在 writer lock
  内同时命中 `expected_store_id` 与 `expected_snapshot_id`。相同完整
  embedding/chunker/normalization identity 可按 canonical text 复用 vector；修改、删除或任一支持的
  模型身份字段变化会精确重建，冻结不支持的 scalar/quantization/metric 等组合直接拒绝。
- 发布布局现为 `.translatis-rag-store.json` + `.translatis-rag-snapshots/` + `.translatis-rag-host/`。
  WorkspaceLease 和 managed terminal 把三者作为不可移除、大小写无关 deny floor；普通 file/patch/
  Git/process/terminal 不能绕过 writer/Validator 改写发布库，Knowledge 内部只派生解除 exact managed
  patterns 的最小 projection。旧 `snapshots/` 只由 read-write build/update 在 store lock 内原子迁移；
  read-only open 不创建基础设施。pointer/layout rename 后 durability 无法确认时返回 non-retryable
  `commitUncertain`，不自动重试。
- build boundary 现在由 host-owned canonical v0.2 writer 重写 Agent draft：任意层非保留
  Markdown 都作为 concept，任意层 `index.md` / `log.md` 都按 OKF reserved shape
  验证；legacy `timestamp` / `# Citations` 只读兼容后迁移为 v0.2；source ID 由
  canonical resource 生成 opaque ID，bundle path 和 scope descriptor 分开处理，私有绝对路径
  不进入 portable snapshot 或 model-facing evidence。exact-slice `chunks.jsonl` 不包含运行时
  wall clock，相同 canonical bytes/config 跨时钟重建为 bit-stable。
- multi-source concept 只把显式 footnote 对应的 source ID 归给该 chunk；仅 exactly-one source
  concept 允许 concept-level fallback，歧义段不会被伪装成 grounded chunk。`generated` 若出现则
  必须同时具有 valid `by` / `at`，footnote claim、definition 与 `sources[].id` 必须机械闭合。
- local-core 仍保留 Apple NaturalLanguage English sentence embedding revision 1 / 512-d 的 exact
  runtime binding、`Float32` L2/cosine exact KNN、Intatis 多语言/代码 tokenizer、BM25/RRF 以及
  embedding-cosine test seam；这些都不代表 shipping 产品 fallback。model-driven 产品 snapshot
  固定 configured embedding identity 与 required semantic reranker identity；query 使用兼容 embedding，
  授权过滤发生在远端 rerank 前，只有实际 semantic rerank 后的 `rerank_applied=true` 才能成功。
  当前宿主冻结中英/代码 corpus 的历史 Apple local route 为
  Recall@5 0.882、MRR 0.681、nDCG@5 0.698、citation precision 1.000；这些数字只代表当前宿主与
  小型冻结 corpus，Intel 真机、最低支持 macOS 和大规模真实知识仍是 `UNKNOWN`。
- 旧的 snapshot-bound `KnowledgeSearchToolHostAdapter` 继续兼容；shipping surface 使用
  `ModelDrivenKnowledgeToolHost`，每次按 `store_path` 获取 exact authority、读取 current pointer、
  mount exact immutable snapshot，并把 mount/bookmark scope 保留到当前 turn grounding 完成后 drain。
  一个 AgentLoop turn 的离线 E2E 已对两个外部 store 完成 build/search/rerank/citation，证明证据与
  snapshot 不串库；随后用 fresh host generation 重新取得 external authority、打开 durable current
  pointer 并再次 search/rerank/citation，证明不依赖进程内旧 handle。
- local-only `search_knowledge` 不写文件、不联网，复用现有只读默认放行路径；deterministic gate 对
  exact local instance intent 直接 `allow`，不创建权限请求或调用 reviewer，但仍保留 ToolRegistry、
  CapabilityLease、authorization correlation 与 durable execution lifecycle。network-backed
  `search_knowledge` 继续按网络工具进入权限审查。
- successful evidence 在返回前复核 concept/source/hash/可选 source locator；AgentLoop 又把它限制为
  current-turn citation，并在 final commit 前通过 exact registration 重新打开 snapshot 做异步机械
  重验。urgent purge 会关闭 admission、cancel/drain、使 current pointer 持久失活并清 receipt；不会
  擦除既有 EventLog/tool history，也不宣称物理 secure erase。
- build service 继续复核外层 exact resolved authorization；model-facing `build_knowledge` 已有真实
  registration 和 AgentLoop durable caller，不允许 service 或 raw terminal 旁路。
- Host augmentation close 现在有 checked drain：timeout/active access 会成为可见的 Code/Cowork/CLI
  runtime failure，不能误报成功；重复 close 保持 single-flight/idempotent。
- `IntatisKnowledgeTests` 最终精确计数见 `docs/TESTING.md` 本轮验证记录，覆盖 schema、OKF safety、filesystem、
  checksum/index corruption、secret/injection、build cancellation/timeout/reuse、snapshot/receipt/
  purge、hybrid/rerank/budget/ACL/source locator/final grounding 和质量/性能代理。AgentKernel 的
  current-turn citation registry 另有独立回归。OpenRouter 上 configured
  `google/gemini-embedding-2`（1536 维）与 `cohere/rerank-4-pro` 的最小 smoke、8-query 冻结质量集、
  真实 Agent 自主 read-organize-build-search-cite 及三份 DS-Algorithm PDF E2E 均已通过。macOS Code
  真实触发 exact-directory NSOpenPanel，生成 session-owned `0600` binary bookmark；应用退出重启并恢复
  同一 session 后再次搜索未重新弹窗。功能性模型驱动 Knowledge RAG 验收已闭环；质量集没有证明
  reranker uplift（dense nDCG@5 1.000，reranked 0.990），不能把功能完成外推为推荐模型质量优于 baseline。

## 当前架构事实

- 根 SwiftPM 图包含 17 个公共 library products、3 个内部 C/guard targets、CLI、开发期
  MCP conformance executable 和 17 个 test targets。精确清单以 `Package.swift` 为准。
- `EventLog` 的 append-only JSONL 是 session canonical truth；`session.json` 是可重建的
  schema-v2 projection，artifact 使用独立 blob/index store。
- `projects-v1.plist` 只是 macOS 按 `SessionKind` 隔离的跨 session 文件夹分组目录，不是 session、
  消息或 workspace capability 的事实源；它不保存 bookmark，不能扩大或连通 Chat/Code/Cowork 的
  既有权限、history 和恢复边界。
- Chat/Code/Cowork 都从稳定 `TurnID` 和结构化事件投影 UI。App 窗口只持有选择；macOS
  runtime 由进程级 `AppSessionRuntimeManager` 按 exact session key 持有。
- Code/Cowork 的工具调用必须经过 ToolRegistry、CapabilityLease、WorkspaceLease、
  PathConfinement、DeterministicPolicyGate、ModelPermissionReviewer、PermissionEngine 和
  durable tool execution。明确 hard deny 不能被 reviewer 放宽。
- production registry 不暴露 raw `run_shell`；shell-capable host 使用 runtime-owned
  `exec_command` / `write_stdin` managed terminal，默认断网并保留进程清理与输入清洗。
- Skills 只提供冻结上下文，不授予权限；外部 MCP 是 client-only，HTTP/stdio transport、
  OAuth/callback/task 和 process ownership 仍受产品边界与权限控制。
- Provider catalog 保留 model options/variant/adapter 语义；credential 只从受控 reference
  懒加载，不进入 EventLog、projection、诊断包或文档。
- OpenAI-compatible Chat 与 Agent streaming 现在默认允许首次请求后最多5次reconnect，退避为
  1/2/4/8/16秒；non-streaming仍只做一次retry。流式重放围栏以consumer实际收到text、完整tool call、
  usage或done为准，raw byte、heartbeat/status或尚未交付的tool-call fragment不再误阻断重连；一旦已交付
  任一语义输出，就保持partial并失败，不盲目重放。

## Chat 与 Agent 托管搜索

- 搜索只属于当前所选 exact Chat route。该 route 明确支持时，向当前模型
  提供厂商对应能力并以 `tool_choice: auto` 让它自行决定是否搜索；不支持、未知或未适配时，当前
  模型静默发送普通 Chat，不显示提示或错误，不执行任何模型/服务/tool fallback。
- v0.31 引入的 `web_search_model` / `webSearchModel` 后台路由行为已取消。runtime 不读取它
  覆盖当前选择或发起额外模型请求；为旧配置兼容可继续 decode/preserve，但字段运行时无效、无
  警告，新生成配置不再主动加入。
- `Capability.hostedWebSearch` 与 MCP `toolSearch` 已分离；`ProviderRegistry.chatRuntimeRoute()` 先验证
  普通 Chat adapter，再按 exact model capability 与 exact adapter 规划 dialect。OpenRouter 使用
  `openrouter:web_search`，OpenAI Responses encoder 使用 `web_search`，compatible/legacy/custom
  默认关闭，因此不会再为了探测能力先发送可能失败的搜索请求。
- 只有 provider-specific 结构化 unsupported code/parameter 且首个有效 payload 尚未被接受时，
  provider 才允许在同一 provider/model/variant 上重发一次普通 Chat；裸 404、自由文本和 partial
  payload 都不会触发重放。
- `HostedWebSearchTool`、exact-route service、capability与`tool_choice:required`实现已通过shipping
  `CodexBusinessToolHost`条件式发布。Code root与Cowork root/显式child role分别绑定同一exact
  provider/model配置解析出的service；model-facing参数只有`query`，host-only scope不进入JSON-RPC或日志。
  任一route支持时固定fork共享目录含该schema，但只有匹配service且read-write的caller获得独立
  `.hostedWebSearch` lease；其他caller在permission/provider前拒绝。App Server内建`web_search`继续
  disabled，provider明确拒绝shape时typed fail closed，不回退普通回答、browser/MCP/shell/第二模型。
  完整Chat与Agent双路径合同见`docs/CHAT_HOSTED_SEARCH.md`。

## UI 与内容渲染

- macOS/iOS 当前使用系统语义表面和原生 Liquid Glass；只有用户消息保留外层对话气泡，
  该气泡使用原生 `Glass.regular` 且不再叠加 accent 蓝色描边。assistant/agent/system 对话正文
  （包括失败/中断回复）直接落在 conversation canvas；tool、error、permission、Goal/Task 等
  专用结构化状态继续使用 Material 边界。
- macOS Chat/Code/Cowork 的用户气泡现使用 20pt continuous rounded rectangle；单行消息接近胶囊，
  多行/附件消息仍保持圆角矩形。Code/Cowork 不再在用户气泡内显示 queued/running/completed/
  cancelled submitted-intent 生命周期标签，底层 SubmissionID/status/EventLog/projection 与失败/Retry
  右栏路由不变。共享 `Jump to latest` 使用稍大的原生 large 圆形 glass 下箭头，并保留 help/VoiceOver
  标签；macOS root 注入每个窗口的完整 content width，Chat/Code/Cowork 再结合各自 detail/thread
  surface width 计算 offset，使按钮落在包含 sidebar 的整个 app window 横向中线，不再按 transcript、
  inspector 或 Cowork rail clearance 偏移。standalone fixture 缺 window host 时安全回退自身中线。
  Cowork `Tasks` 卡默认只显示标题内完成分数，以及每行一个状态 marker、任务名和有详情时的
  trailing disclosure；durable WorkTask status、详情、result/evidence/dependencies/invocation links 不变。
  `Agents` header 与每行状态标记全部直接使用 SF Symbols；header 为 `person.2.fill`，状态标记使用
  20pt 系统 symbol font、30pt 固定槽位和 hierarchical rendering，并统一为圆形语义符号，不包含
  自绘 icon、图片资源或自定义圆底。durable agent status、创建顺序、选择与控制面 status-only 边界不变。
- iOS 与 macOS 的标题/正文继续共享语义字号、字重和 Dynamic Type 层级。macOS Chat composer
  继续保留model与legacy Context；Code/Cowork composer不再显示尚未接通的Context。每条已完成
  assistant/agent回复在正文下方显示无文字的`doc.on.doc`复制按钮。Chat/历史回复继续兼容
  Input/Cache Hit/Output/Total/Duration；新Codex回复则从`responses_usage`显示完整Input/Cache Hit/
  Cache Write/Output/Reasoning/Total/Duration。
  legacy `turn_stats` 以可选 `TurnID + responseMessageID` 追加关联，Chat/Agent两种事件到达顺序均可投影；
  旧日志缺关联时继续解码但不猜测归属。复制直接写 EventLog/projection 的 raw message text，不使用
  Markdown 派生文本，也没有点赞/点踩等反馈控件。iOS Chat 本轮继续使用既有 model/full-usage 第一排。
  两端第二排仍为 action/input/voice/Send-or-Stop；voice 始终紧邻主操作左侧，
  不占用或复制唯一的 Send↔Stop 槽位。composer 的 compact secondary/voice control 另显式固定
  40pt 外层布局与圆形 `contentShape`，使屏幕上完整圆形控件与真实点击区域一致，而不是只让内部
  SF Symbol 字形响应点击。macOS Chat 与 Cowork 的 paperclip、附件数量/移除菜单、文件 importer
  和 URL drop modifier 现在是同一套共享 surface；Code 与 iOS Chat 的现有能力边界不随之扩大。
- 2026-08-19 用户已批准把 JetBrains Mono 保留为正式全局英文字体：macOS/iOS 普通构建和启动把第一方
  SwiftUI role/direct font、plain/rich message 与现有 Markdown configuration 路由到官方 JetBrains
  Mono 2.304 variable fonts，不再保留实验参数或 system-font opt-out。两份 TTF 由
  `IntatisSharedUI` 的 `Bundle.module` 单一持有，使两端 App 和 tests 使用
  同一 bytes；启动时会校验 bundle hash、PostScript
  inventory、process registration 与 exact resource URL，失败不回退用户安装字体或另一 family。
  中文继续通过 Core Text glyph fallback 使用系统 CJK font。字体决定已收口；发布仍须完成正常的
  无障碍、中英混排、许可证和最终 bundle gate。
- rich text 使用仓内经审计的 Microsoft SwiftStreamingMarkdown thin derivative 与
  exact iosMath Apple-native 数学排版；plain-safe 仍是运行时救援路径。
- macOS rich Markdown 的直接拖拽选择由每个 `DocumentView` 自有的
  `MarkdownDocumentSelectionCoordinator` 协调。标题、段落、列表正文、block quote、表格单元格与
  代码正文仍是各自真实 TextKit 2 `ParagraphNSView`；鼠标落点按窗口几何解析，连续范围按稳定文档
  注册顺序分发，因此不等高表格不会按 frame 高度乱序。拖动期间使用各 native selected range；
  mouse-up 后只在 view-owned disposable `textStorage` 快照上施加该 view 的 exact 系统
  `selectedTextAttributes`。首个 leaf 保留真实 selected range 以维持 AppKit responder/Copy 语义，但其
  native temporary selection attributes 在 selection lifetime 内置空，因此不会再和跨 leaf projection
  形成两套随焦点变化的浅/深选区。普通点击、流式内容替换或 view dismantle 会恢复逐属性相同的原投影
  与系统 native selection attributes。Command-C 按显示顺序合并 plain text，跨
  block 用换行、同一表格行用 tab，并恢复 inline-math literal；raw Markdown、EventLog、projection 与
  provider history 不变。Intatis macOS 关闭旧 `Select more text` 菜单/弹窗，用户直接拖拽；plain-safe
  的单一 SwiftUI Text 与 iOS 既有 leaf selection 不变。当前边界是一条 rendered message document，
  不把一次选择跨到另一条消息或 footer。
- macOS Chat/Code/Cowork history 是一条无 Earlier/Newer/Latest 的完整连续时间线。顶层 row
  使用 lazy materialization；`16` 只作为 active rich-row budget，屏幕附近最多 16 条保留重型
  native rich-document graph，离屏 row 释放该 graph并继续以 exact raw text留在滚动历史中。
  geometry observation、bottom restore 和 rich dwell 继续防止旧 session-entry layout cycle。
  旧分页与旧 lazy 性能数字只保留在 Git/report 历史，不是当前 release readiness 证明。
- macOS Chat和共享iOS Chat现与Code/Cowork共用同一个window-local `IntatisThreadScrollCoordinator`：initial restore、
  streaming follow、completion、width/rich correction与手动Jump都绑定exact presentation scope和generation，
  使用100 ms fixed-window leading/trailing cadence，最多一个executor request和一个可替换pending request。
  两个Chat壳都已删除逐token的ownerless `DispatchQueue.main.async`与重叠0.18秒动画；长thread先完成raw bottom
  restore，再按既有per-row dwell准入rich graph，用户离开底部后仍不会被live/rich更新抢回。
  continuous rich-row visibility flush另增加lifecycle generation/cancellation与duplicate observation no-op，
  旧scope task不能干扰同scope重新激活。Cowork选中agent的snapshot读取也改为单一in-flight load加一个
  latest follow-up marker；持续50 ms publication不再反复取消读取或来回发布已有内容上的loading状态。
- assistant/agent的流式Markdown与公式显示已从逐token `rich → raw → rich`切换为monotonic rich
  replacement。首份rich之前仍显示latest raw；一旦同一未完成message已有rich，后续同style/appearance/
  typography/config、64 KiB内且逐字append-only的successor会在下一exact parse期间保留当前单份rich，完成后
  直接rich→rich替换。correction、truncation、completed-message mutation、semantic/style变化、oversize、
  suspension、offscreen或dismantle仍立即回current raw。没有新增document/native-view cache，raw
  EventLog/copy/provider history不变。macOS新`RenderableDocument`另先在不可见状态完成一个owner-bound
  main-queue attachment-hosting turn，再无动画显示；这会遮蔽TextKit 2 live公式provider安装前的系统文稿
  占位，不修改vendor、公式parser/attachment、依赖或iOS路径，也不保留旧document graph。
- Cowork 不再把完整 `CodeProjection.items` 发布给 MainActor，也不在点击时扫描/过滤完整
  历史。Conversation actor 在 fold 时维护 typed per-agent index；每个窗口只持有选中 agent
  的完整连续有序快照和 stale-request generation，其他 agent rows 继续留在 actor。非选中 agent 的增量
  不会刷新当前 transcript，查看选择也不改变 runtime、scheduler、mailbox、lease 或发送目标。
- Cowork roster 现分成 EventLog-derived historical identity catalog 与 live operational roster：
  前者驱动 stable-ID lazy Agents 列表和只读 conversation selection，后者独占 send/delegate/
  message/ask/rebind/remove、settings 与 workspace/capability 操作。presentation 会先按 agent
  线性聚合 task/lease/status，避免历史 agent 数量增长后形成 agent×task/lease 重扫。Agents
  使用 durable 首次 admission 的创建顺序；status、消息、detach 或 reattach 不会触发重排。
- Cowork thread header 只显示 session durable name。宽屏 rail 继续作为同一 conversation canvas
  的 trailing overlay；outer rail 固定 348pt、glass card 固定 318pt，并使用系统 `Glass.clear`
  降低独立光块感，不增加整栏背景、手绘阴影或渐变。Agents 使用更大的系统文字，选中态只保留
  accent 蓝色背景，不再叠加勾选图标；顶部 compact permission 只显示状态、tool、安全摘要与必要
  action，不展示 risk chip、raw arguments 或默认展开详情。
- Cowork thread header 不再提供独立 MCP Content 快捷按钮；内容浏览保留在
  `Project Settings → MCP → Browse Content`。右侧 status rail 显隐开关使用系统 compact 圆形
  glass/bordered icon control；这两项只改变 header chrome，不进入 rail overlay、固定宽度或
  render-boundary 输入。
- Code/Cowork 的会话错误统一由 SharedUI presentation 收集：当前选中连续 thread 中的
  `.error`、失败 execution row、`recoveryAdvice`、失败 submission，以及 Code 的 voice/composer
  和 Cowork 的 voice/composer/inference/projection/session-storage 页面级错误都会进入同一列表；
  相同规范化文案只显示一次。右侧 rail 最底部只生成一张沿用现有 section 样式的“错误信息”
  圆角卡片，无错误时不渲染卡片或占位。失败 submission 的 Retry 一并迁入该卡片，但只允许当前
  thread中最新的submitted intent携带按钮；创建新continuation后旧失败仍显示审计信息而不再可重试。
  主 thread
  仅保留用户原文和已有 partial agent 正文，不再显示 `Needs attention`、错误行、失败 trace 或
  恢复建议。该收口只生成 presentation copy，不修改 EventLog、projection 或 durable failure facts。
- rail 现在是 thread 上不参与布局协商的 `.overlay(alignment: .trailing)`，并关闭 inspector
  transaction 的隐式动画。rail 由只包含 rail 输入的 Equatable render boundary 隔离；thread 的
  empty/loading/rich 状态不能重新物化 cards。每个 passive `Glass.clear` 都位于自己的稳定
  backdrop，独立 status cards 不再放入会融合/重组 shape 的 `GlassEffectContainer`；系统动态
  separator 的单物理像素 `strokeBorder` 继续作为轮廓锚点，不使用固定 RGB、渐变、投影或自绘高光。
- Code/Cowork 的 raw bottom-anchor 恢复不再通过 GeometryReader、屏幕全局坐标或
  `PreferenceKey` 回写布局；系统 `onScrollVisibilityChange` 只在 anchor 可见性真正变化时提交
  observation。窗口移动、focus 或全屏变化因此不会仅因 screen origin 改变而触发 thread 布局链。
- Cowork transcript 复用一个固定 ScrollView 根和连续 lazy rows。`IntatisContinuousThreadRenderBudget`
  只准入最多 16 个当前可见 row 的 rich graph；agent切换及选中 agent 的连续增量期间先显示轻量
  raw text，同一选择和内容静止 300 ms 后才重新准入 rich
  Markdown，避免快速点击或 streaming 为每次更新挂载新的 AppKit 文本/选择子树。content/raw
  frame 在 ScrollView 扩展到 overlay 下方前固定，因此 Agent 内容、空态和 scroller 可见性都不会
  改变中栏或 composer 的水平边界。
- 当前连续会话focused组合回归120 tests / 0 failures，macOS与iOS Simulator Debug build通过。
  8×1,000 rows、500 delta/s离线production surface已从第991–1,000条连续跳到第1–10条且无pager；
  1,000 rapid switches与180秒soak均为warning 0 / incident 0。soak中/后RSS为
  184,368/184,384 KiB，`vmmap` physical footprint 67.0 MiB、peak 124.4 MiB，heap保留
  `NSTextViewSharedData` 5与`GestureNode` 86；这证明当前presentation资源plateau，不替代真实
  EventLog/provider、VoiceOver、正式签名或低端设备验收。

## 持久化与安全边界

- session EventLog、workspace bookmark、artifact、browser profile、inference catalog 和
  provider/auth 配置各有独立 owner、权限和 schema 边界；bookmark bytes 不进 JSONL。
- SecretScanner、Mediator、Keychain/credential resolver、Hardened Runtime、managed
  terminal Seatbelt/default-network-deny 与 iOS linkage boundary 均保留。
- 旧 schema 与未知 future event 的兼容/fail-closed 规则不得因文档或版本更新而改变。
- 第三方代码、prompt、字体和依赖来源以 `NOTICE.md`、`ThirdPartyNotices/`、vendor ledger
  与 `docs/OPEN_SOURCE_REUSE.md` 为准。JetBrains Mono 两份 unmodified font resource 已按 v2.304
  exact commit、SHA-256 与 OFL-1.1 登记；它们是正式 product resources，不是 executable runtime。

## 最近验证状态

- 2026-09-02 shipping Agent hosted-search接线验收：focused矩阵覆盖
  `CodexRuntimeTests`、`HostedWebSearchToolTests`、`ProviderHostedWebSearchToolServiceTests`、
  Providers/Inference route、Protocol lease/session、CLI与Cowork presentation，全部退出0；其中Codex target
  71/71、hosted Tool 4/4、provider service 3/3，CLI 50项中8项真实provider smoke按设计skip。覆盖条件式
  74项基础catalog、root与read-write child exact service分流、roleless继承、
  read-only/unsupported pre-permission拒绝、missing service host-construction拒绝、secret pre-dispatch、
  durable prepared/settled、no-root-fallback，以及fake App Server真实
  `item/tool/call(hosted_web_search)`进入exact business host service。随后完整
  `swift test --disable-automatic-resolution`正常退出0，
  所有已运行suite为0 failures；`swift build --product translatis`、`xcodegen generate`、macOS Debug unsigned与
  iOS Simulator Debug unsigned build也退出0，版本一致性门输出`0.71 (build 71)`。全部search调用使用
  fake/loopback service，没有读取或请求OpenAI API key，没有发真实provider请求或产生计费；真实route
  兼容性仍须用户显式opt in验证。历史SharedUI间歇性hang风险仍保留为下一目标。
- 2026-09-01 shipping图片工具接线验收：最终工作树的`CodexBusinessToolHost` focused suite 67/67与
  `CapabilityLeaseTests` 8/8通过，覆盖73项基础
  authoritative catalog、root generate/edit、read-write child执行、read-only child在permission前拒绝、
  同名exact capability、durable prepared events、secret边界、shutdown drain，以及installed exact `.4`
  App Server offline handshake；Protocol/CLI focused suites通过，CLI其中8项真实provider smoke按设计skip。
  Tools与`ProviderImageGenerationToolService`图片专项5/5通过。本轮较早一次
  `swift test --disable-automatic-resolution`完整退出0且无失败；最终重跑则在SharedUI组合顺序挂起并按
  上述证据中断，不能把较早成功覆盖为最终全量稳定。`swift build --product translatis`、macOS Debug unsigned
  和iOS Simulator Debug unsigned build均退出0。所有新增图片执行使用injected fake service，没有读取
  API key、没有发真实provider请求，也没有产生计费。
- 2026-09-01文档纠错前的较早审计：`scripts/check-version-consistency.sh`通过并输出`0.71 (build 71)`；当前
  `/Applications/Intatis.app`读回`0.71 (71)`，但其Resources中`CodexRuntime`、`DocumentRuntime`与
  `BrowserRuntime`三项均缺失。`swift test --disable-automatic-resolution`在允许SwiftPM真实sandbox/cache的
  宿主边界完成编译并通过多个suite后，`IntatisSharedUITests.xctest`约5分46秒仍为0% CPU且无新输出；
  sample显示XCTest async waiter等待，最终人工中断为130。中断后ExecutionTrace 17、Typography 2、
  MarkdownScheduler 6、MessageRendererMode 11、MessageRendering 39、ThreadLayout+ThreadScroll 63，合计
  138/138、0 failures；挂起前另外六个SharedUI suite 36/36也已输出通过。结论是断言可分组通过，但完整
  组合进程当时不稳定；本轮最终重跑再次复现同类挂起，因此该证据仍是当前风险，而不是被较早一次成功
  覆盖。
- 2026-08-22 macOS 文件夹项目第一版：完整 `IntatisCoreTests` 64/64，其中
  `ProjectFolderStoreTests` 10/10，覆盖 owner-only binary
  plist、同模式重复文件夹幂等、相同路径跨模式独立、跨模式归属拒绝、旧混合草稿按模式拆分、
  跨项目唯一会话归属、并发追加不丢失、损坏/未知 schema fail closed，
  以及移除项目不修改用户文件或 session EventLog；序列化结构明确不含 `bookmarkData`。
  完整 `ThreadLayoutTests` 30/30（含 folder-project composition 1/1），冻结当前模式过滤、可折叠
  文件夹、无固定 230pt 区域、无项目主页/跨模式菜单，以及 Chat/Code/Cowork 既有会话入口。
  String Catalog 通过 `jq empty`；`swift build
  --disable-automatic-resolution`、`xcodegen generate`、`TranslatisMac` Debug unsigned 与
  `TranslatisiOS` generic Simulator Debug unsigned build 均退出 0，两个最终 bundle 均读回
  `0.55 (55)`。Computer Use 在最终 macOS build 中确认 Chat 项目默认一行收起、展开/再收起只增删
  子内容、Projects 与 Unfiled 共用滚动面；切到 Code 后 Chat 项目完全缺席且只出现 Code 的新建入口。
  本轮尚未运行完整 SwiftPM suite、真实文件选择/多窗口视觉交互、完整 VoiceOver 朗读、签名或发行验证。
- 2026-08-21 固定只读工具默认放行：`DeterministicPolicyGate` 仅把两个既有
  `pass` 结果改为 `allow`，使 `structured_read_only` 集合中的
  `read_docx` / `read_pptx` / `read_xlsx` / `read_html` / `read_epub`、对应五个
  `continue_*_read` 与 `ocr_pdf`，以及 local-only `search_knowledge` 不再创建权限请求或调用
  reviewer；`inspect_pdf` / `read_pdf` 继续走既有 native read-only allow。
  network-backed Knowledge、写入、通用 exec、destructive、协议、sidecar、EventLog、responder、
  reviewer 与 Cowork 控制面均未修改。聚焦 suites 共 169 tests、0 failures：
  IntatisPermission 56、SearchKnowledge 4、ToolRegistryLease 27、AgentLoopPolicy 37、
  DocumentReadToolSplit 4、AutomaticPermissionReview 39、ModelDrivenKnowledgeAgentLoop 2。
  首次受管沙箱内运行在 SwiftPM manifest 的 `sandbox-exec` 初始化前失败；同一命令在允许真实
  SwiftPM sandbox 的宿主环境重跑通过。未运行完整 `swift test`、App build 或真实 provider smoke。
- 2026-08-21 `TranslatisMacAppStore` target 删除：`project.yml` 已删除 App Store application target 与
  shared scheme，`Apps/TranslatisMac/TranslatisMac.AppStore.entitlements` 已删除，Mac App 源码中的
  `TRANSLATIS_MAC_APP_STORE` 条件编译分支已收敛为唯一 Developer ID 路径；`Package.swift`/MCP stdio
  注释与当前文档同步为单一 Mac 产品事实。共享 `.macAppStore` profile 仅保留协议解码和隔离测试，
  没有恢复为 target。`xcodegen generate` 通过；`xcodebuild -list` 只列出 `TranslatisMac` 与
  `TranslatisiOS` 两个 App targets，shared app schemes 也只有这两个。版本一致性检查通过；更新后的
  `SDKClientOnlySurfaceTests` 3/3 通过，冻结单一 Mac App、Developer ID stdio+HTTP 与 iOS 零 MCP
  linkage。`TranslatisMac` macOS Debug（`ENABLE_DEBUG_DYLIB=NO`）及 `TranslatisiOS` generic Simulator
  Debug unsigned build 均退出 0；保留的 `.macAppStore` profile 兼容测试 6/6 通过。构建仅有仓库既有
  unused/deprecation 与旧临时 build-dir stale-file warnings。
- 2026-08-21 macOS 跨 block 选区单一外观 corrective：用户截图证明 2026-08-20 版本在 mouse-up
  后仍同时保留首个 `NSTextView` 的 native selection 和其他 leaf 的 `controlAccentColor` projection；
  窗口/截图工具改变 focus 后前者变浅、后者保持深蓝，造成同一选择范围出现两种样式。当前源码把所有
  leaf 收敛到 exact `selectedTextAttributes` projection，并只保留一个不再绘制 temporary attributes 的
  native selected range 维持 responder/Copy。coordinator 14/14、vendor Debug/strict Release 各
  79 XCTest + 25 Swift Testing、SharedUI 42 + 25（67/67）全部 0 failures；normal macOS Debug 与签名
  unique-bundle fixture 均构建通过。strict Release 首次还发现并修正了 coordinator test observation
  被错误限制为 `#if DEBUG`、导致 Release test target 无法编译的问题；该观察口仍是 module-internal read-only。
  Computer Use 在 fixture 的正文→代码、以及已安装 App 的用户原始“核心关键术语”正文→三项列表场景
  都得到单一浅蓝选区；切换应用焦点后仍一致。fixture Command-C 的宿主 general pasteboard 读回完整
  跨 block plain text，保留代码换行/空行/缩进。更新后的 `/Applications/Intatis.app` executable SHA-256
  为 `1fdc9785519fd41449431695849a029fc330b7f9ff3b898416f221fe913116c7`；strict codesign、Hardened
  Runtime、audio-input=true、allow-jit=false、disable-library-validation=false、无 Debug dylib/quarantine
  均通过。紧邻的中间包可从
  `~/.Trash/Intatis-selection-appearance-intermediate-20260821-121114.app` 恢复；实际带双重选区样式的
  旧包保留在 `~/.Trash/Intatis-before-selection-appearance-20260821-120049.app`。
- 2026-08-20 macOS 单消息 document 直接跨 block 选择：新增 document-scoped AppKit coordinator，
  macOS table/code text 复用 native paragraph leaf，Intatis 关闭 `Select more text` modal。最终
  coordinator 14/14、SharedUI `MessageRenderingTests` 42/42、`ThreadLayoutTests` 25/25；vendor
  完整 suite 为 79 XCTest + 25 Swift Testing、0 failures，Release warnings-as-errors build 通过。
  SwiftPM 全图、`TranslatisMac` normal Debug 和 `TranslatisiOS` generic Simulator Debug 均通过。
  Computer Use 在签名的 unique-bundle fixture 中正向/反向跨标题、正文、代码得到统一系统蓝色选区；
  Command-C 的宿主剪贴板读回按文档顺序保留代码换行/缩进的完整 synthetic 文本，临时 AX/日志诊断
  已移除。表格 native layout 实窗可见；不等高 row-major、列表参与、样式逐属性恢复、stream cancel
  与 table tab separator 由真实 `DocumentView` host tests 覆盖。更新后的 `/Applications/Intatis.app`
  strict codesign 通过、无 quarantine/Debug dylib；Computer Use 在安装后受 `noWindowsAvailable` 影响，
  未把真实用户 session 的最后一次自动 drag 伪报为通过。跨消息选择、拖出 viewport autoscroll、
  modifier/double-click、VoiceOver、Light/Dark 与长 soak 仍需独立人工/设备验收。
- 2026-08-20 macOS 逐回复复制与统计 footer：new `turn_stats` optional `TurnID + responseMessageID`
  精确绑定 Chat/Code/Cowork 的最终回复，投影支持 message-first / stats-first；旧 unbound stats 不猜
  归属。macOS composer 只保留 Context，每条已完成 assistant/agent 回复以 icon-only copy 开始并显示
  可证明的 Input/Cached/Output/Time；iOS full usage 不变。直接相关 62 tests / 0 failures；完整
  Protocol/Conversation/AgentKernel/Cowork 目标合计 900/900、0 failures。SwiftPM 受影响图编译和
  `TranslatisMac` Debug unsigned build 通过。unique pasteboard 验证 raw Markdown/代码/
  公式/中文复制 exact。Computer Use 可确认 copy action 与 Context-only composer，但隔离 synthetic
  metrics fixture 因临时 bundle/window 识别冲突未完成可靠像素捕获，因此四项 footer 的真实
  Light/Dark/窄宽/VoiceOver 仍为 `UNKNOWN`。`TranslatisMac` 与 `TranslatisiOS` Debug unsigned build 均通过；
  未运行完整 suite 或真实 provider。
- 2026-08-20 本机开发安装：Xcode 27 默认 Debug launcher + `TranslatisMac.debug.dylib` 产物在 ad-hoc
  Hardened Runtime 下虽通过静态 codesign，启动时仍被 dyld 的 library validation 以不同 Team ID
  拒绝。没有关闭 library validation；同一源码改以命令行 `ENABLE_DEBUG_DYLIB=NO` 重新构建，使完整
  程序回到单一主 Mach-O，再以 Developer ID entitlements 做 ad-hoc Hardened Runtime 签名。最终
  `/Applications/Intatis.app` 为 `0.55 (55)` arm64、无 Debug dylib、strict codesign 通过、无
  quarantine；Computer Use 从 exact 安装路径启动成功并确认 `Copy message` action 与 Context 控件。
  安装前的 `0.48 (48)` 与启动失败的中间 `0.55` 分别保留在
  `~/.Trash/Intatis-before-install-20260820-210656.app` 和
  `~/.Trash/Intatis-failed-debug-dylib-20260820-211318.app`，均未永久删除。本条仍不是 Developer ID、
  universal、notarization 或 Gatekeeper 发行证据。
- 2026-08-19 JetBrains Mono 正式英文字体接线：SharedUI typography/render/layout focused
  73/73，vendored Markdown 79 XCTest + 11 Swift Testing，全部 0 failures；macOS/iOS Debug 与
  Release unsigned builds 均通过，Release macOS 为 `x86_64 arm64`，四个 App 读回 `0.55 (55)`。
  两份 TTF/OFL 在仓库及四个 App bundle 中 hash 一致；隔离 iOS Simulator 和 macOS renderer
  fixture 均已无字体参数启动，Core Text probe 观察到英文 JetBrains Mono、中文 PingFang fallback。
  未验证 Dark、超大 Dynamic Type、VoiceOver、真机或正式签名/公证；这些仍是正常 release gate，
  因而当前证据不等于整个 v0.55 release GO。
- 2026-08-13 AuthorizationSidecar 绑定域分离与副作用完成 cast 删除：business-args digest 只核对
  stripped canonical business arguments，custom authorization identity digest 只核对宿主授权快照；两者
  不再交叉比较。AgentLoop 已删除 denied/failed side-effect ledger、EventLog restore、final completion
  guard 与对应 error/prompt。权限拒绝和真实 tool outcome 仍持久化，但普通失败 observation 不再把随后
  正常 final 改判失败。`AuthorizationSidecarTests` 12/12、`IntatisAgentKernelTests` 220/220、
  `IntatisConversationTests` 212/212、`IntatisCoworkTests` 365/365，全部 0 failures；`swift build
  --disable-automatic-resolution` 与 `TranslatisMac` macOS Debug unsigned build 通过。未运行真实 provider、
  credential/network、GUI、iOS App、签名或发行 smoke；详见 `docs/TESTING.md`。
- 2026-08-13 Cowork Session 内独立 WorkTask / Run 中断 / 原子委派重构：WorkTask 已删除
  Run、Goal、agent owner 字段和跨 Run dependency/carry-forward 路径；Goal 与 WorkTask 状态不再
  相互传播。provider、网络和 runtime 中断把旧 Run 终结为 `interrupted`，显式 Resume 创建新
  RunID。`delegate_task` 只使用已经 attached 的 data-plane worker；纯 Mediator/exact-provider 检查在
  admission lock 外等待，随后在 lock 内重新复核全部可变状态并以一个 EventLog batch 提交 message、
  delegation、lease、invocation、queue 与必要的 WorkTask linkage。提交前拒绝保持 EventLog 零变化并
  结算 `not_started`。当前验证：`IntatisProtocolTests` 107/107、`IntatisConversationTests` 212/212、
  `IntatisAgentKernelTests` 220/220、`IntatisCoworkTests` 364/364、`IntatisSkillsTests` 29/29、
  `IntatisToolsTests` 227/227（另有 19 个显式 opt-in skip），`swift build` 通过。整仓
  `swift test` 仍受既有 SharedUI async waiter 停滞影响，未记为全量通过；详见 `docs/TESTING.md`。
- 2026-08-13 Permission Reviewer plain-text verdict 格式修复：240 Character 从有效性硬上限改为共享
  prompt 的简洁度建议；241/500/1000 Character 的非敏感 `ALLOW` 与 `DENY` reason 均保留原决定。
  完整 reason 在任何摘要截断前先做敏感信息检查；live bound settlement 继续只写固定宿主文案。
  缺失/重复/非末行 marker、空 reason、JSON/code fence、无 completion 与非成功 finish 分别保留 typed、
  secret-free failure kind，旧 `malformed_verdict` / `provider_still_stopping` 继续可解码。
  `PermissionReviewProtocolTests` 13/13、`IntatisPermissionReviewerTests` 14/14、
  `PermissionReviewControlPlaneTests` 51/51，合计 78/78、0 failures。未运行全量 test、macOS/iOS app
  build、真实 provider 或 GUI smoke。
- 2026-08-12 Cowork ordinary-worker WorkTask update 收窄：worker 继续使用稳定的 `task_update`
  名称与既有执行/权限/持久化链，但业务字段仅保留当前任务的进度、允许状态、结果和证据；
  manager 的完整更新字段未收窄。`ToolRegistryLeaseTests` 26/26、`WorkTaskRuntimeTests` 22/22，
  另有 closed-schema pre-permission/execution gate 1/1，相关合计 49/49、0 failures；
  `swift build --disable-automatic-resolution` 通过。未运行全量 test、macOS/iOS app build、真实
  provider 或 GUI smoke。
- 2026-08-11 fixed-format document reader 拆分与瘦身 gate（历史证据；已被 2026-08-23
  registry v5 取代，rbook/EPUBCheck/pdfcpu 生产闭包现已删除）：完整 `IntatisToolsTests` 223/223
  （19 skipped）、`AgentLoopPolicyTests` 36/36、`CapabilityLeaseTests` 7/7、
  `ToolRegistryLeaseTests` 25/25、`MessageDelegationSplitTests` 10/10，均 0 failures。用户提供的
  外部 Intatis-test 目录只作为输入；测试把 1 份稀疏 XLSX 与 3 份 PPTX 复制到临时
  workspace 后运行，4/4 读取成功且不修改原目录。installed core runtime 与 EPUB write/read smoke
  各 1/1 通过；rbook write-only helper 的 fmt/check/test/clippy 全门通过（7 unit + 2 integration）。
  `swift build --disable-automatic-resolution`、版本一致性检查、macOS `TranslatisMac` Debug unsigned 与
  iOS generic Simulator Debug unsigned build 均退出 0，仅报告仓库既有 warning。一次整仓
  `swift test --disable-automatic-resolution` 在完成 Tools 后挂于既有 SharedUI async waiter，采样后
  人工中断为 130；不能记为本轮全量通过，也未观察到 document reader 相关 failure。
- 2026-08-12 Cowork single-pass permission sidecar corrective gate：
  `PermissionReviewControlPlaneTests` 47/47、`AgentLoopPolicyTests` 37/37、
  `AutomaticPermissionReviewTests` 35/35、`DurableMultimodalAgentLoopTests` 9/9、
  `AuthorizationSidecarTests` 12/12、`IntatisPermissionReviewerTests` 10/10、
  `PermissionReviewProtocolTests` 12/12，合计 162 tests / 0 failures。覆盖 same-call string sidecar 拆包与
  绑定、ask-only host requirement、valid sidecar 的 current-turn in-memory formatting example、raw/transient
  durable isolation、missing → missing → corrected same-args 调用可达 reviewer、tool-input failure 不消耗
  permission denial fuse、live reviewer prompt 不含 user/task semantic narrative、manual 保留字段拒绝、
  dedicated host admission、active/cached/recovered invocation 复验、固定宿主 reason/provider-failure 文案及
  in-engine reviewer 误配 fail closed。新增 strict-schema 回归还使用真实 shipped Skill/Knowledge descriptor，
  并抓取 OpenRouter 与 OpenAI-compatible 两种最终 Chat Completions HTTP body，递归断言所有 strict
  function 的递归 `required == properties.keys` 与 `additionalProperties:false`，以及 request-owned deferred
  MCP function 装饰与 durable output 不变；其中一条贯通 automatic Cowork `tool_search` 执行到下一轮
  `AgentRequest`。上述 162 计数只代表 focused
  permission suites；本次 strict-schema 修正另有 `SearchKnowledgeToolTests` 4/4。
  snapshot-bound `search_knowledge` 迁至 input schema v2；v1 resource 原样保留，v2 将 `limit` 表示为
  provider-required integer-or-null，null 映射宿主默认 8。
  `swift build --disable-automatic-resolution` 通过；受影响目标分别为 `IntatisAgentKernelTests` 217/217、
  `IntatisKnowledgeTests` 118/118、`IntatisCoworkTests` 364/364、`TranslatisCLITests` 45/45（8 skipped）。
  `TranslatisMac` macOS Debug、`CODE_SIGNING_ALLOWED=NO` 构建通过；只出现仓库既有 unused-result 与 SwiftUI
  deprecation warnings。
  完整 `swift test --disable-automatic-resolution` 完成 Tools 223/223（19 skipped）后再次挂于仓库既有
  SharedUI async waiter，连续两分钟无输出后人工中断为 130，不能记为本次全量通过。opt-in 真实 provider
  strict-sidecar smoke 已成功编译但按设计跳过；未运行真实计费请求或 UI/manual switch smoke。
- 2026-08-11 model-driven Knowledge live acceptance：OpenRouter 最小 smoke 1/1，embedding 为
  1536 维并报告 input/total token 7，reranker 返回完整 permutation、有限 score 和 search unit 1；
  8-query 冻结集的 dense baseline 为 MRR/nDCG@5/Recall@5 = 1.000/1.000/1.000，configured reranker
  为 1.000/0.990/1.000，embedding usage 343 token、reranker usage 8 search units。真实 Agent 对测试
  文本在 32.686 秒内完成 read → OKF draft → external build → required-rerank search → exact evidence
  citation；另一个 110.980 秒的 E2E 用 `read_pdf` 读取 `DPV-chap2.pdf`、`DPV-chap4.pdf`、
  `DPV-chap6.pdf` 的冻结页段，形成 3 个 concept / 22 chunks 后检索并引用。macOS Code 首次外部搜索
  出现 exact-directory NSOpenPanel，保存 session-owned `knowledge-access.plist`（binary、`0600`、revision
  1）；退出、重启、恢复同一 session 后再次调用未出现授权框。空库按设计返回 `KB_INDEX_NOT_READY`，
  没有修改文件。Knowledge 118/118、Knowledge Provider 11/11、tool wire metadata 5/5、CLI 9/9、
  AgentLoop 2/2、grounding 7/7、Cowork lease 25/25、SecretScanner 1/1，以及工作区沙箱外
  managed-terminal publication anti-bypass 1/1 均通过；macOS/iOS Debug unsigned build退出 0。
  本轮整仓 `swift test` 在完成 Tools/Skills 后，于既有 SharedUI async scheduler 测试进程中持续约
  7 分钟 0% CPU/无新输出并被人工中断为 130，不能记为全量通过，也未观察到本任务相关 failure。
  provider 没有返回完整货币金额，项目仍不按可变价格表推算账单。
- 2026-08-05 Flotis 单模型语音 runtime 迁移：`ComposerVoiceInputTests` 6/6，覆盖 draft merge、
  WAV 16-bit PCM 及 WAV/M4A 均不注入 `AVEncoderBitRateKey`；
  `IntatisProvidersMultimodalTests` 22/22，覆盖 owner-only disk-backed multipart WAV、OpenRouter
  JSON-base64 `input_audio`、exact runtime route、严格 JSON Content-Type、timeout 与错误 payload。
  完整 `swift test`、XcodeGen、版本一致性检查、`TranslatisMac` macOS Debug 和 `TranslatisiOS` generic
  Simulator Debug unsigned build 均通过；两端最终 bundle 含麦克风 usage description。先前本地
  ad-hoc macOS Debug 签名包已读回 `com.apple.security.device.audio-input=true` 且 strict codesign
  verify 通过，但这不替代正式 Developer ID/Hardened Runtime/公证验证。未执行真实麦克风或线上
  transcription provider smoke，也未启动 App 做视觉检查，因而真实权限交互、设备录音、具体
  provider/model 可用性、计费和像素表现仍为 `UNKNOWN`。
- 2026-08-03：`xcodegen generate` 与 `scripts/check-version-consistency.sh` 通过。
- `TranslatisMac` unsigned universal Release 构建通过；最终 bundle 为 `0.32 (32)`，可执行文件
  同时包含 `arm64` 与 `x86_64`。该构建用于源码与元数据验收，不是可分发签名产物。
- `TranslatisiOS` generic Simulator Debug 构建通过；最终 bundle 为 `0.32 (32)`。两端构建仅有
  既有的 unused-result / deprecated `onChange` 警告，没有构建失败。
- `swift build` 在允许 Swift/Clang 写入用户缓存的宿主环境通过，覆盖 CLI 与 SwiftPM
  products；受限沙箱内的首次尝试仅因 module cache 无写权限而未进入源码编译。
- 上一轮外层 sandbox 外的 `IntatisToolsTests`：141 tests / 15 skipped / 0 failures。
- focused `IntatisAgentKernelTests`：169 tests / 0 failures。过期的 800-token soft-budget
  fixture 已改为保留充足真实 prompt 余量，同时继续验证 provider 忽略输出 ceiling 后的
  soft-budget overrun；生产 `requestTooLarge` 保护未修改，独立 admission/concurrency 回归仍保留。
- 完整 `swift test` 已在允许 Swift/Clang cache、process 与 loopback 测试的宿主环境通过；
  需要真实 browser/Git/provider/credential/network 的 opt-in 用例仍按声明跳过，不能冒充已验证。
- 2026-08-03 Cowork agent-thread 专项：Debug fixture 使用 8 个 selectable agent、每个 1,000
  条记录、4-agent 合计 500 canonical delta/s，先完成 1,000 次 rapid switch，再完成 180 秒
  10 Hz nominal soak（实际 1,486 次 timed switch）；Computer Use 观测为 0 main-thread warning、
  0 incident，结束时仍只挂载 16 条，`NSTextViewSharedData` 为 14、`GestureNode` 为 173。
  `vmmap` physical footprint 为 62.1 MiB、峰值 74.8 MiB；`ps` RSS 为约 156.6 MiB。两者口径
  不同，均未出现旧实现的线性增长。本 fixture 是 offline presentation stress，不替代真实
  provider/EventLog/低端设备长时矩阵。
- 2026-08-04 historical roster 修正：512 identity 投影用例在 detach 500 个后仍保留 512 个
  历史项且 live roster 仅 12 个；detached selection、512-ID presentation catalog、lazy/unfiltered
  rail 与 read-only operation fence 的定向测试通过，IntatisConversationTests 172/172、TranslatisMac
  Debug unsigned 构建通过。Computer Use 实测 detach 当前 `@research` 后不跳回 main，离开再返回
  仍可查看 985–1,000 / 1,000；随后在 500 delta/s 下完成 1,000 rapid switches，0 warning / 0
  incident，仍只挂载 16 rows。
- 2026-08-04 rail lighting/fixed-geometry 修正：`ThreadLayoutTests`、
  `CoworkInferencePresentationTests` 与 `CoworkAgentThreadPresentationModelTests` 组合共 30 tests /
  0 failures；TranslatisMac 与 TranslatisiOS Simulator Debug unsigned build 通过。1372×768 原生 Light
  对照中，`@main` / `@research` 的 composer 像素边界一致，rail 均位于 x=1076…1365；8×1,000
  rows + 500 delta/s 下再次完成 1,000 rapid switches，0 warning / 0 incident、最多 16 rows。
  该次没有重跑 180 秒 soak、Dark、Reduce Transparency、Increase Contrast 或完整 SwiftPM suite。
- 2026-08-04 rail window-stability 第一版结论已被用户复现结果推翻，不再作为当前通过证据。
  后续真实 Test session 日志证明旧 `IntatisThreadViewportFramesPreferenceKey` 在全屏变化时仍会同帧
  重复更新；仅做像素相位修正不能解决问题，相关旧截图/数值只保留为历史排查记录。
- 2026-08-04 上述第二版 corrective pass 随后也被用户在新构建中稳定复现结果推翻：删除 viewport
  preference 与 shared glass container 仍不够，因为 trailing overlay 的几何宿主仍是会随 transcript
  更新的 `threadColumn`，且 `selectedAgentID` 仍在整个 rail 的 Equatable snapshot 中；每次点击都会
  让所有原生 glass section 重新进入更新周期。当前源码改为由 exact outer-detail canvas 分别托管
  leading thread 与 trailing rail，thread 不再是 rail 的 alignment guide；selection 从 rail snapshot
  中移除并通过独立轻量状态只更新蓝色行背景/无障碍 value；每个 `Glass.clear` backdrop 也成为
  content-independent Equatable view。`ThreadLayoutTests|CoworkInferencePresentationTests|
  CoworkAgentThreadPresentationModelTests` 31/31 通过，其中 production-shaped host 完成 360 次
  agent selection/mode/inspector/window-size 交错变化；TranslatisMac macOS Debug 与 TranslatisiOS generic
  Simulator Debug unsigned build 通过。按用户要求不使用 Computer Use 或截图采样，真实视觉是否消除
  数像素光学跳变仍需用户在新构建中确认，不能沿用前两版的截图/AX 结论。
- 同日 Codex managed sandbox 内的完整 `swift test --disable-sandbox --quiet` 仍只有
  `IntatisToolsTests` 的 process/Seatbelt/loopback 用例受宿主限制失败；单独完整
  `IntatisSharedUITests` 一次在 build 后无用例输出并被中止，当前修改直接覆盖的 SharedUI 定向
  用例均独立通过。不得把这次 sandbox 运行记成全量通过。
- 直分发脚本已在用户宿主环境进入真实 Developer ID 构建/签名链路；一次开启代理/VPN的
  运行在 Apple notarization 网络阶段未完成，另一次先关闭代理/VPN的运行则在 SwiftPM
  克隆 `swift-system` 时因 GitHub 专用代理 `127.0.0.1:1082` 已停而失败。脚本现在支持
  `TRANSLATIS_PAUSE_BEFORE_NOTARIZATION=1`：保持代理完成构建/签名，暂停后切换网络，并在不
  重建的情况下探测及重试 Apple notarization。
- Apple `notarytool history` 已确认两次 `Intatis-notary-upload.zip` 完整到达服务端，但查询时
  均长时间停在 `In Progress`；用户中断的是本地 `--wait`，没有取消服务端任务。旧脚本把
  JSON 结果重定向且无限等待，隐藏了实时状态，并在 Control-C 后删除临时签名 App。脚本现
  改为可见 upload + submission ID、默认 30 分钟有界 wait，以及 owner-only recovery state；
  超时/中断后可复用同一 App/DMG submission，不再重建或重复上传。旧的两条任务发生在持久
  recovery 加入前，即使之后 Accepted，也没有本地原 App 可直接完成 staple。最终 Accepted、
  staple 和 Gatekeeper 证据仍未取得。

## 当前已知缺口

1. Cowork subagent本地功能、真实Ox Alpha线路、active Goal冷启动暂停、current-patch provenance与完全
   退出后的child恢复均已通过；不再列为已知缺口。Codex仍是独立外置thin arm64 validation binary，App
   bundle没有它，也没有x86_64/hash、完整Cargo license/NOTICE closure、nested Developer ID、公证/
   staple/Gatekeeper/fresh-user证据。用户已明确把这组发行工作留到后续；正式发布前仍必须完成，不能让
   App悄悄依赖用户机器上的Codex或回退旧AgentLoop。
2. 仓库最后记录的两条App submission在当时仍为`In Progress`；2026-09-01没有读取用户Keychain或Apple
   私有状态，因此其当前terminal结果为`UNKNOWN`。恢复发行前应先由用户侧`notarytool history`核对，
   不得盲目重复上传；随后只运行一次可恢复两阶段流程，完成App/DMG notarization、staple、codesign与
   Gatekeeper assessment，并记录最终ZIP/DMG和SHA-256。在这些证据齐全前不能发布。
3. `request_user_input`已在macOS Code/Cowork完成原生presenter接线；CLI仍没有交互presenter并明确关闭。
   native MCP elicitation/public-client OAuth、exact per-child MCP与可证明的stdio authority也尚未接线。
   CLI attachment与`/clear`仍不可用。所有剩余缺口保持typed fail closed。
4. 完整SwiftPM suite仍有间歇性：2026-09-03同一工作树先正常退出0，随后在本次纯UI修正后的重跑又使
   `IntatisSharedUITests.xctest`与`swift-test`父进程持续0% CPU、无新输出；1秒sample再次落在XCTest async
   waiter/CoreFoundation run loop，有界诊断后退出130。相关focused SharedUI/CoworkUI测试及macOS/iOS构建
   均单独通过，因此目前仍是既有组合顺序生命周期缺口，尚无稳定最小复现；需要继续异步资源审计、连续
   有界重跑与CI wall-clock timeout，不能把一次成功写成“已经稳定”。
5. macOS/iOS初始EventLog或ArtifactStore打开失败仍以`fatalError`终止整个App；需要保留数据
   fail-closed的session-scoped恢复/诊断界面，避免损坏session造成启动循环。
6. 真实 provider/key、第三方 MCP/OAuth、长时 browser/profile、VoiceOver/clipboard、低端
   iPhone/iPad 与长 soak 仍有环境矩阵空白；不得用离线 fixture 冒充。
7. macOS 27/Xcode 27 当前仍是 beta toolchain evidence；最低支持系统/设备的正式矩阵需要
   独立验证。
8. `@ai-sdk/openai` 的普通 Chat adapter 仍未实现，所以该 exact adapter 即使声明
   `hosted_web_search` 也会按既有规则在网络前 config fail closed；在普通 adapter 完成前不能把
   已有 OpenAI Responses search encoder 宣传为完整native OpenAI **Chat** route支持。这不否定
   Codex原生Responses Agent route的条件式search service；两条产品路径必须继续分开验证。真实厂商
   smoke仍待用户凭据环境验证。
9. Knowledge 的功能性真实 E2E 已完成，但当前 8-query 冻结集没有证明推荐 reranker 相对 dense
   baseline 的质量 uplift，nDCG@5 反而从 1.000 降至 0.990。它仍需要更难、更大、独立标注的领域集合
   做模型选择；large-corpus latency/memory/disk/cost ceiling、Intel/最低 macOS 与 Linux provider matrix
   仍为 `UNKNOWN`。provider usage 可报告 token/search units，但没有 versioned price evidence 时不推算金额。

## 文档治理

当前文档入口和历史分类见 `docs/README.md`。2026-09-02再次核对，先前错误主要来自：Codex切换时只在文件
顶部增加“覆盖旧内核”的总声明，后部legacy段落仍使用“当前/已接入”语气；版本收口脚本又只校验
`0.72 (72)`元数据，没有校验production入口、dynamic tool catalog、bundle runtime inventory或完整测试
是否真正退出0。仓内继续保留legacy类型/service/tests，使简单源码搜索进一步把“存在”误判成“shipping
可达”。当前规范已增加局部legacy标签与语义门；后续完成事项应留在Git历史和dated reports，不再以
未标范围的旧段落覆盖当前摘要。

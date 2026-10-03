# PER_AGENT_INFERENCE_PROFILES

文档状态：当前 durable inference binding 契约
最后核对：2026-08-03
产品基线：v0.72（build 72）

## 1. 状态与范围

Intatis Cowork 已实现同一 session 内按 agent 绑定不同推理配置的第一阶段。绑定对象不是单独的 model 字符串，而是一个指向不可变 catalog revision 的精确引用；该 revision 同时固定 connection、wire、model、variant、有效 request options、credential reference 元数据和安全路由标签。由此可以表达：

- 同一 model、不同 reasoning/thinking effort 或 token budget；
- 同一 model、不同上游 connection、credential reference 或 endpoint；
- 不同 model 与不同 variant；
- 将来新增 wire adapter 后，不同请求协议或端点族。

当前 shipped resolver 只执行 OpenAI-compatible wire。不同 agent 可使用不同 OpenAI-compatible connection/profile；Anthropic、Gemini、OpenAI Responses 等其他 wire adapter 尚未实现。本文只描述当前源码中的 durable 契约和明确的未完成边界。

该能力只改变推理请求路由，不改变 `PermissionProfile`、`CapabilityLease`、`WorkspaceLease`、browser profile 或 agent 的工具权限。它们必须继续独立建模和授权。

## 2. 核心不变量

1. **精确绑定，不跟随默认值漂移。** 已存在 agent 持有完整 `AgentInferenceBinding`；catalog 的 current/default 指针只用于创建未来 agent。
2. **不可变 revision。** connection/profile 的语义内容变化必须创建新 revision，旧 revision 保留供恢复和现有 agent 使用，不允许原地覆写。
3. **严格恢复，解析失败即关闭。** exact revision 缺失、definition digest 不匹配、connection/model/variant、安全 route label/trust domain/egress classification 不一致、wire 不支持或已声明的必需能力不兼容时，不得回退到当前默认、相似 model 或其他 provider。
4. **一次 invocation 冻结一次绑定。** `TaskContract` 保存本次调用的 exact binding；执行前同时核对 durable roster、task snapshot 和 catalog。运行中的调用不会被 catalog 刷新或 rebind 改写。
5. **默认值只影响未来 agent。** session/project default 是 creation template；修改它不能重写 `@main`、已有 worker、queued/running task 或控制面。
6. **创建时继承是精确继承。** `spawn_agent` 未指定 profile 时复制请求者的 exact binding；显式 profile 只能从 host-approved 列表选择。
7. **rebind 是显式的 durable 状态迁移。** 只有 host 可对 idle agent rebind；必须先解析候选配置，再 durable 记录 previous/new binding，最后更新内存 roster。
8. **安全投影不泄露 route material。** agent/event/UI 只携带 profile/connection 的 opaque identity、revision、model/variant、安全 route label/trust domain/egress classification 和不可逆 definition digest；不携带 raw endpoint、credential、headers、query 或任意 options。
9. **恢复不以今天的默认值补历史缺口，也不让一个坏 worker 冻结全局。** non-empty CLI session 若缺失或无法 exact resolve `@main`，必须由 host 显式选择 workspace/profile 恢复主控，启动门禁不会套用当前默认。普通 worker unresolved 时不阻止其他 agent 或 GoalRuntime/data-plane scheduler 恢复；只让该 worker 的 queued invocation 在 provider request 前 exact-resolution fail closed，并把该 invocation durable 结算为 failed。其队列/active fence 清除、agent 回到 idle 后，host 才能显式 rebind。

## 3. 数据模型

### 3.1 Connection definition

`InferenceConnectionDefinition` 固定：

- `InferenceConnectionID + InferenceConnectionRevision`；
- wire；
- base URL 与 chat endpoint；
- credential reference，而不是 secret value；
- trust domain / egress classification；
- connection-level default request options。

Connection revision 的任何语义变化，包括 endpoint、wire、credential reference、trust metadata 或默认 options 变化，都会产生新 revision。

### 3.2 Profile definition

`InferenceProfileDefinition` 固定：

- `InferenceProfileID + InferenceProfileRevision`；
- 精确 connection reference；
- model ID 与可选 variant ID；
- 已合并的有效 request options；
- declared capabilities；
- 不含 URL/secret 的安全显示标签。

Profile 是 agent 选择的最小单元。两个 profile 可以有相同 model ID，但不同 reasoning effort、connection、credential reference 或 endpoint；它们仍是不同的推理配置。

### 3.3 Agent binding

`AgentInferenceBinding` 是进入 roster、task contract、permission target 和归因事件的安全快照，至少包含：

- exact profile reference；
- exact connection reference；
- model / opaque durable variant identity；macOS/CLI 本地配置中的 raw variant key 只留在非 durable presentation selector，不进入 binding/EventLog；
- 可选安全路由标签；
- 可选的安全 `trustDomain` / `egressClassification` 分类；
- opaque immutable-definition digest。

Binding 不是对 catalog current 指针的动态引用。resolver 必须用它反向核对 exact definition，不能只按 profile ID 或 model ID 找“最新”配置。

### 3.4 Resolved profile

`ResolvedInferenceProfile` 在一次 resolver 调用中原子地返回已验证 binding、model 和 provider，避免先取 provider、后读 mutable binding/model 形成 torn route tuple。严格 per-agent runtime 不能使用旧的 provider-only public factory；Orchestrator 会在 admission/preflight 和 provider dispatch 边界逐项要求 `Agent.model == AgentInferenceBinding.modelID`、resolved binding 与 agent binding 完全相等、resolved model 与 agent model 完全相等，任一不一致都在 provider 收到请求前 fail closed。macOS、CLI 与 CLI self-test 均使用该 atomic resolver seam；仅 isolated `@testable` internal initializer 保留 legacy seam。Credential secret 只在真实 provider 解析阶段按 reference 懒加载，不进入 catalog、binding、EventLog 或 UI projection。

## 4. Catalog 编译与持久化

`InferenceCatalog` schema v1 同时保存：

- 所有历史 immutable connection revisions；
- 所有历史 immutable profile revisions；
- 只供未来绑定使用的 mutable current-reference map。

macOS app 将现有 provider/model/variant 配置编译为 connection/profile draft：connection ID/trust domain 使用不暴露 URL 的 opaque hash，egress classification 当前固定为 `user-configured-external`；用户写入配置的 raw variant key 仅用于本地查找与安全标题，durable `variantID` 是 provider/model/variant tuple 的 opaque stable digest。CLI 读取同一 Intatis-owned OpenCode-compatible 配置形状，把所有启用的 OpenAI-compatible route、model 与 named variant 编译为 profiles；connection/trust identity 与 credential reference 都按 exact route configuration 隔离，resolver 始终使用目标 connection revision 自己的 env/file/auth/config reference，绝不拿当前所选 route 的 key 替代。Modern CLI 的 unqualified model 只有在全 catalog 唯一时才自动切到其唯一 route；有歧义且当前显式 route 也不含该 model 时必须要求 provider-qualified ID。显式 reasoning effort 必须匹配 selected model 的 configured variant（或 base options 已明确声明同一 effort），不能临时合成一个 variant。Catalog reconciliation 保留旧 revision，因此仍被历史 binding 引用的 route revision 与其 exact credential reference 可继续解析。Reconciler 对语义相同的 draft 复用旧 revision；语义变化时追加 revision并保留旧定义。

进入 durable Cowork catalog 的 `baseURL` / `chatEndpoint` 还必须是没有 user-info、query 或 fragment 的绝对 HTTP(S) URL。鉴权和路由参数只能由 exact connection revision 的受控 credential/adapter 契约表达，不能藏进 URL 后持久化或绕过安全投影；不满足该约束的 draft 在写入 catalog 前 fail closed。该收口不改变 Chat/Code 独立兼容配置路径的开放 JSON 契约。

`InferenceCatalogStore` 的当前持久化契约是：

- 不存在的文件代表空 catalog；
- 现有文件必须是受支持 schema、owner-only 权限且小于大小上限；
- corruption、未知 schema 或不安全权限 fail closed，不静默重建覆盖；
- 每次 reconcile 的“锁内读取完整旧 catalog → 分配 immutable revisions → 校验 snapshot → 写入”是一个串行化事务：同进程多个 store instance 先经过进程内互斥，Darwin/Linux 再用稳定 sidecar inode 上的阻塞式 POSIX 独占 record lock 实现跨进程互斥；未知平台不允许无锁降级；
- sidecar lock 永不主动删除；打开时使用 no-follow/close-on-exec，并逐项确认当前用户所有、`0600`、普通文件且单一硬链接。符号链接、外来 owner、宽松权限、非普通文件、多链接或系统调用失败均以不含路径/material 的 `storeIO` fail closed，不能自动“修复”既有不安全锁；
- 写入使用同目录 owner-only 临时文件、内容同步和原子替换；lock 覆盖旧值读取、revision allocation 与替换，避免并发 reconciler 丢失 revision 或分配碰撞；只读 snapshot 依靠原子替换读取完整文件，不参与 mutation lock；
- app 与 CLI 使用各自 App Support 下的 `inference-catalog-v1.json`。

该 store 是 versioned catalog，不是 session transcript。Session 通过 durable agent/event binding 引用其中的 exact revision；catalog refresh 必须保留仍被历史 session 或 agent 引用的旧 revision。

## 5. Options 合并规则

Catalog 编译阶段采用浅覆盖，顺序固定为：

1. connection defaults；
2. model base options；
3. selected variant options；
4. profile overrides。

调用阶段采用：

1. resolved profile options；
2. host 允许的少量 invocation values；
3. runtime policy clamp；
4. runtime structural fields 最后覆盖。

当前 bound Cowork agent 的 reasoning/options 由 profile 所有；session-wide `reasoningEffort` 只用于没有 binding 的兼容路径。Cowork durable catalog **不是**开放 JSON 通道：只有显式 schema 中的有界字段可进入 revision，包括数值型 sampling/token/logprob 参数、`logprobs` / `parallel_tool_calls` 布尔值、安全 token 字符串 `reasoning_effort` / `verbosity` / `service_tier`，以及受限的 `reasoning`、`thinking`、`output_config` 和 provider routing 子结构。未知 key、错误 JSON shape、过深/过大容器、runtime structural fields、secret/auth/header/query/URL/endpoint transport material、`stream_options` 与 `n` / `best_of` / `num_return_sequences` / `candidate_count` 等多候选控制都在 catalog admission 时 fail closed；新增 durable option 必须先显式扩展 schema 与测试。

这与 Chat/Code 的兼容配置路径不同：`ProviderEndpoint.modelRequestOptions` 仍保留任意 model/variant JSON，不按厂商枚举丢弃未知字段；多层 options 使用 OpenCode/Remeda `mergeDeep` 语义，只有共享 plain object 递归，array/scalar/null 由后层替换。`provider.npm` 与 model `provider.npm` 分别冻结 provider adapter 和 model override；最终 request builder 只让 exact adapter 解释已知选项，禁止全局 reasoning alias 规范化或未知 package fallback。`@ai-sdk/openai-compatible` 与 `@openrouter/ai-sdk-provider` 的 reasoning wire shape 不同，历史缺 adapter 值继续走 legacy 行为。Builder 最终拥有 `model`、`messages`、`tools`、`stream` 等结构；对所有 Chat/Agent 请求都会无条件移除配置提供的 `stream_options`、`n`、`best_of`、`num_return_sequences`、`candidate_count`。新式 `@ai-sdk/openai-compatible` / `@openrouter/ai-sdk-provider` adapter 按 pinned OpenCode package 语义省略 `n`，依赖 API 的默认单候选行为，也不会因为 Intatis tool metadata 声明 parallel-safe 就自动合成 `parallel_tool_calls`；只有 legacy Intatis wire 继续显式写入 `n = 1` 和 call-level parallel 开关。显式配置并经 adapter lowering 的 `parallel_tool_calls` 仍可保留。只有 host 的 `includeUsage` 可以重新加入受控 `stream_options.include_usage`。当 host 另给 output-token ceiling 时，还会按忽略大小写及 `_` / `-` / `.` 分隔差异的 normalized key 清除全部竞争 token aliases，再写入 host-owned `max_tokens`。因此即使兼容 Chat/Code 配置是开放 JSON，配置也不能通过候选数量字段改变单候选、usage 或 host ceiling 请求形状；Cowork profile 更早在 durable schema admission 就会拒绝候选数量字段。

## 6. Agent 生命周期语义

### 6.1 新 session 与恢复

- fresh Cowork session 的 `@main` 使用用户当前选择的 exact default binding。
- project setting 保存 `defaultInferenceProfileBinding`，其含义始终是“未来新 agent 默认值”。旧 provider/model 字段只作兼容镜像。
- legacy project setting 可按原 provider/model 迁移到 base profile；不能猜测一个当前 variant。
- 恢复时，durable `agentAttached` 是 binding 的权威来源；旧事件没有 binding 时解码为 unresolved，而不是自动套用当前默认。
- strict production runtime 中，unresolved `@main` 或普通 agent 不能发起模型调用，必须由 host 显式 rebind；区别是 `@main`/控制面 unresolved 阻止启动，ordinary worker unresolved 只隔离并 durable-fail 自己被调度到的 invocation，不冻结无关 agent。
- strict production runtime 只能通过 atomic `resolvedInferenceFor` 构造；`requiresInferenceBindings = true` 与 provider-only factory 的组合在 runtime 创建时直接拒绝。
- non-empty CLI session 若 durable roster 缺失 `@main`，不得用当前 default profile/workspace 自动重建；只能由 host 运行 `/agent restore-main <path> <profile-id>` 走普通 reviewed attach。随后显式 `/auto` 使用配置冻结的 permission reviewer binding；GoalVerifier 才冻结首个可解析的 exact `@main` binding。

### 6.2 Spawn

- 未传 `inference_profile_id`：精确继承调用者 binding，包括 revision、connection、variant 和 definition digest。
- 显式传入：只能使用 runtime 的 host-approved profile map，且在 admission 前完成 exact resolve。
- coordinator 可先调用 `list_inference_profiles` 查看 host-approved
  profile ID、安全 label、model 与 variant。`spawn_agent` / list tool 的
  model-facing descriptor 明确把“省略并继承 exact caller profile”列为默认
  推荐；只有某个安全 label/model/variant 明确适配被委派工作时才选择不同
  profile。当前没有硬编码按任务类型推荐特定厂商/model 的 policy tags，不能
  把模型自己的 label 判断写成 host-guaranteed recommendation。
- raw model 与 profile 不能同时提交；worker 不能通过 raw model 字段绕过 host-approved profile。
- 新 agent 的完整 binding 随 durable spawn/attach 事件落盘后才进入可运行 roster。

### 6.3 Delegate

委派给已有 agent 时不复制或改写目标 agent 的 binding。权限目标包含目标 agent 当前 exact binding、host-approved catalog snapshot 与 agent/lease fingerprint 的安全快照。执行器取得同一 target reservation 后，host rebind 必须把它视为 busy fence；即使 Mediator 或 exact resolver 发生异步等待，也必须在最终 admission lock 内再次复核 authorization、caller leases、catalog、target binding/model/workspace/fingerprint，且生成的 `TaskContract` binding 必须等于 reviewed binding，之后才可持久化/入队。任一变化都 fail closed 且不产生 worker provider request。

`delegate_task` 不创建或 proposed 新 worker。显式 target 与 automatic target 都必须解析为已经 attached 的 data-plane agent；automatic 只在现有 idle workers 中选择。需要新 worker 时，coordinator 必须先单独调用 `spawn_agent`，等待成功 ToolResult 后再在后续 tool-call round 委派。

### 6.4 Rebind

当前 rebind 契约为：

- host-only；普通 agent 不能自我切换；
- `@permission-reviewer` 不允许 rebind；
- 目标必须存在，且处于 idle：没有 running invocation，也没有 queued invocation；
- 候选 binding 必须与 host-approved catalog entry 完全相等，并可在 secret/network access 前完成结构解析；
- 候选 exact resolve 可以在锁外异步执行，但进入 admission lock 后必须再次检查 host-approved map、busy state 与原 binding；catalog candidate 更新与 rebind 使用同一把 admission lock，不能让 resolver suspension 后的旧候选越过已更新 catalog；
- 先 append durable `agentAttached` snapshot（含 previous/new binding 与 change reason），成功后再更新内存；
- 只影响后续 task，不改写已冻结的 `TaskContract`。

UI 的 rebind 控件与 CLI `/agent rebind` 都调用同一 Orchestrator 边界。UI 可为了减少无效操作在全局工作时禁用控件，但安全性依赖 Orchestrator 的 per-agent idle recheck，而不是界面状态。

Cowork composer 底部的模型 selector 是另一条 main-only submitted-intent 路径：选择动作只更新“下一次 `@main`”的暂存值，即使 current task/worker 正在运行也保持可用，不直接调用 rebind。按下 Send 时把当时的 secret-free exact binding 冻结进 immutable `UserMessagePayload`，并随 outbox、EventLog、FIFO、恢复与 Retry 保持 first-write-wins；新式 main/Goal Send 无 exact binding 时保留草稿并 fail closed。FIFO 到达该 submission 的空闲 execution boundary 后，Orchestrator 在一个 admission-lock hold / EventLog batch 内同时提交可选 `@main` rebind 与该 root 的 created/assigned/queued，持久化成功后才提交 live roster 和 scheduler；Retry 的 rebind/queue 同样原子。新式 Goal 还 durable 保存该 binding，后续 continuation/重启不读取 mutable live/default。Direct ordinary-worker message 不携带该字段；候选撤销或不再可解析时 fail closed，不回退 current/default，也不改 worker、reviewer、GoalVerifier 或 future-agent default。

## 7. Runtime、并发与控制面

Provider resolution 发生在 agent invocation 边界，而不是 session 启动时把一个 provider 全局注入所有 agent。`ProviderRegistryBox` 按 agent binding 取得 provider；Orchestrator 在模型调用前验证：

- live roster binding 存在且可 exact resolve；
- `TaskContract` binding 与 live binding 一致；
- catalog 中的 connection/profile revision、safe route label、trust domain、egress classification 与 binding snapshot 一致；
- 当前 wire adapter 可用；
- profile 显式声明能力时，tool-calling 能力满足当前 agent runtime。

同一 session 中不同 agent 因此可以并发使用不同 resolved providers。Agent single-flight、session concurrency limit、token budget 和 scheduler 规则不因 profile 不同而放宽。

GUI/CLI recovery 的启动门禁只要求 `@main` exact-resolved、自动 reviewer/control plane 就绪并完成既有 Goal recovery；之后才显式调用 `resumePendingTasks`。普通 worker 的 legacy/unresolved/missing revision 会继续显示在 roster，但不能形成全局 scheduler gate：scheduler 可以运行其他 agents，并 claim 该 worker 已有的 queued invocation；Orchestrator 在真正 provider request 前核对 live + frozen binding 并 exact resolve，失败时把该 invocation durable 结算为 failed、撤销 task lease 并清除 queued/active fence。这样 host 随后可在 worker idle 时显式 rebind，也不会让一个损坏 route 阻塞整个 session。

Host 更新可选 profile catalog 时必须取得与 attach/spawn/delegate/rebind 相同的 admission lock；更新只替换未来 admission 使用的 approved map，既有 exact binding 与已冻结 task 不变。Spawn/delegate 的真实执行边界若跨过异步 profile resolver 或 Mediator，会在返回后重新运行同步的 authorization/lease/target/binding/model/workspace/fingerprint/catalog 检查，并在最终 admission lock 内再比较一次；这样无需把 admission lock 持有到外部 `await`，也能阻止 catalog 或 roster 在 suspension 期间变化形成 TOCTOU。AgentLoop 的 execution revalidation hook 必须在 durable tool-execution prepare 前完成 exact resolve，并在 await 返回后再次校验；若变化已发生，当前调用 fail closed 且不能先写 prepared ticket。

Agent admission 也遵守同一规则。Ordinary attach 在 permission review 前保存目标 exact binding 对应的 host-catalog snapshot；review allow 后先在锁外再次 exact-resolve，再进入 admission lock 比较 review 前、resolve 前和 commit 前的 snapshot，变化时 durable deny 而不写 `agent_attached`。Fresh `bootstrapMainAgent` 不调用模型 reviewer，但首次 empty-session preflight 与最终 commit 之间仍有 admission/resolver suspension：实现会在锁内检查空 roster/EventLog并记录 catalog snapshot，锁外二次 exact-resolve，随后重新取得锁并再次检查 empty-session 与 catalog facts，全部一致后才提交 leases/roster。

自动 permission reviewer 和 GoalVerifier 属于两个独立控制面。当前 GUI/CLI 从 canonical 顶层
`permission_reviewer_model` 编译并冻结 reviewer 的 exact base-profile binding；字段缺失只在配置解析层
一次性继承同一 JSON 文档的顶层 `model`，显式非法 route fail closed，不能读取 UI/session/default、
`INTATIS_MODEL` 或 live/historical `@main`。Permission reviewer 会在该冻结 binding 上为每个 request
generation 重新 exact-resolve provider wrapper。GoalVerifier 另行冻结首个可解析的 exact `@main`
binding，并保留自己的 provider lifecycle。后续 data-plane rebind 不会悄悄 retarget 任一控制面；若需改变
reviewer 配置，应修改顶层配置并显式停止/重建对应 runtime，不能复用普通 agent rebind。

## 8. Permission、EventLog 与安全

推理 profile 是新的审计维度，但不是新的授权豁免：

- `ResolvedToolAuthorization` 可包含目标 agent exact binding 的安全快照；permission request/settled、durable tool prepare/settle 延续现有 durable-first 顺序。
- Spawn/delegate 的 permission intent 还携带由 exact binding 派生的 `targetInferenceFingerprint`，并带安全 route label、trust domain 与 egress classification。Review 后和 durable prepare 后都要用结构化 binding 重新计算并比较；missing/changed fingerprint 或 binding 变化立即 fail closed，executor 不能重新选择 profile/target。
- profile ID/revision、connection ID/revision、model/variant、安全 route/trust/egress 分类和 opaque digest 可用于归因；不得记录 raw base URL/chat endpoint、credential value/ref 细节、headers、query 或完整 options。
- Provider/model 提议的 tool arguments 在进入 `.tool_call` EventLog 前仍是不可信输入。新 writer 只持久化有界、secret-scrubbed `args`、`argsCharacterCount` 和可选 `argsRedacted`：unknown tool、schema-invalid input，以及作为 inference-control surface 的所有 `spawn_agent` 调用使用固定 redacted placeholder，且**不写 raw-value digest**，避免把低熵 endpoint/credential 变成离线猜测 verifier；其他 schema-valid、未脱敏/未截断的非控制参数才可附加 canonical `argsDigest`。旧事件的 raw `args` 继续兼容解码，但新路径不得让模型把 endpoint/header/api_key 等 material 通过未知字段或失败调用抢先写入日志。
- definition digest 只作为一致性比较和审计关联的不可逆值；文档、UI 和错误信息不得输出其完整实际值。
- catalog/resolve 错误必须是裁剪和净化后的 reason；不能回显可疑 option value、secret material 或完整 endpoint。
- Provider diagnostics 在 formatter 层先脱敏；diagnostic path 还会把普通完整 HTTP(S) URL（即使没有 credential/query secret）替换为 `[REDACTED_URL]`，因为 endpoint 可暴露私有基础设施。`RuntimeErrorPresentation` 在错误写成 durable `ErrorPayload`/task-failure 事实前使用同一 diagnostic sanitizer 再次 URL/secret-redact 和限长；普通 permission action preview 的 URL 语义不因此被全局改写。Custom provider 绕过上游 formatter 时也不能把未信任错误字符串写进 EventLog。
- Provider traffic 使用 no-redirect `URLSession`；任何 HTTP 300...399 都作为原 endpoint 的净化失败返回，不能自动向 `Location` 发起第二次请求。否则已审批的 exact connection 可能把 prompt/credential 转发到未进入 binding/trust/egress review 的 endpoint。若未来允许 redirect，必须先增加显式 route authorization，而不是依赖 URLSession 默认行为。
- credential value 旋转且 reference 不变时不要求 agent rebind；connection 的 credential reference 本身变化则形成新 revision。

Endpoint/trust-domain 变化本质上是数据出口变化。当前第一阶段依靠 versioned exact binding、host-approved profile、permission target snapshot 和 fail-closed revalidation；**尚未实现独立的 `InferenceRouteLease`、跨 trust-domain 专用审批原语或 per-task route lease**。后续增加此类能力时不能把现有 `CapabilityLease`/`WorkspaceLease` 偷换为 route approval。

## 9. 产品表面

### macOS Cowork

- 新 session 使用当前 provider/model/variant 对应的 exact profile 创建 `@main`。
- composer 底部菜单显示并暂存下一次发送给 `@main` 的 exact profile；忙时仍可选择，选择不改变当前 invocation，Send 才把当时值冻结进该 submission，FIFO 到执行边界才 main-only rebind。
- Project Settings 中的默认 profile 只标注为未来新 agent 默认。
- roster 显示每个 ordinary agent 的安全 profile label、model/variant 和 resolved/unresolved 状态。
- host 可从安全列表为 idle agent rebind；UI 不展示 endpoint、options 或 credential。
- catalog/config 刷新更新可供未来选择的 profiles；已有 agent 保持原 revision。初始 catalog 无法构建时 session fail closed；已有有效 snapshot 后的 refresh 失败保留上一份有效 snapshot并显示错误。

### CLI Cowork

- CLI 会从 Intatis-owned OpenCode-compatible 配置编译所有启用的 route/model/variant，而不是只暴露当前单一 connection；每个 option 保留本地 route/model/variant selector，但 durable binding 只含 opaque exact identity/revision；
- unqualified model 仅在唯一 route 匹配时自动选择该 route；显式 reasoning 若没有匹配的 configured variant/base effort，则配置 fail closed，不生成 synthetic profile；
- 每个 connection revision 保存自己的 exact credential reference；懒加载 resolver 支持 env/file/auth/config reference，且不能把当前 selected route 的 credential 替换到其他 route 或保留的旧 revision；
- `/profiles` 列出 host-approved 的安全 profile；
- `/profile [id]` 查看或设置未来 agent default；
- `/agent add ... [--profile <id>]` 使用显式 profile，否则使用未来-agent default；
- `/agent restore-main <path> <profile-id>` 只用于 non-empty recovered session 缺失 `@main` 的显式 host 修复；不能由启动流程代填 current default；
- `/agent profile <name>` 显示安全 binding；
- `/agent rebind <name> <id>` 走 host-only、idle-only durable rebind；
- `/model` 仅作兼容展示，不重写 agent route。

### Chat 与 Code

本阶段的 durable per-agent binding 面向 Cowork。Chat 仍使用当前全局 provider/model/variant selection；Code 仍是单 agent 产品面，不应据此宣称已经提供多 agent profile UI。

## 10. 当前未完成边界

以下项目仍是后续工作，不得在状态文档或 UI 中声称已完成：

- Anthropic、Gemini、OpenAI Responses 或其他非 OpenAI-compatible wire adapter；
- 独立 `InferenceRouteLease`、per-task route approval、跨 trust-domain 专用审批；
- app catalog 中完整且可信的 model capability metadata；当前 app compiler 的 declared capabilities 为空，resolver 只能验证显式声明的能力；
- provider/model-specific 的通用 capability negotiation 与自动降级；
- fallback chains、负载均衡、provider-native session/response handle 迁移；
- 让 agent 直接输入 raw endpoint、credential、arbitrary options 或每次 task 任意覆盖 route；
- 将 control plane 当作普通 data-plane agent 动态 rebind；
- 真实多上游、多 endpoint、不同 reasoning profile 的网络 E2E 和长期恢复/credential rotation 矩阵。

## 11. 回归测试要求

最低自动化覆盖应包括：

- protocol round-trip 与 legacy optional-field decode；
- Chat/Code `ProviderEndpoint` arbitrary JSON options 保真；Cowork durable schema 只接受显式 allowlisted 字段，并对 unknown key、错误 shape、secret/auth/header/query/URL/endpoint、structural/stream/multi-candidate fields fail closed；
- 所有 OpenAI-compatible Chat/Agent request 都移除配置 `stream_options` 与多候选参数；新式 package adapter 省略 `n` 并依赖默认单候选，legacy wire 才显式写入 `n = 1`。新式 adapter 也不得从 parallel-safe tool metadata 自动合成 `parallel_tool_calls`；host `includeUsage` 才能重建受控 usage shape，host token ceiling 另清除竞争 aliases；
- 语义相同复用 revision、语义变化追加 revision、旧 revision 保留；
- store owner-only 权限、corruption/schema/permission failure 不覆盖原文件；
- exact resolution 不回退 current，且 profile/connection revision、model/variant、safe route/trust/egress/digest 任一 mismatch 都在 secret/network 前失败；
- 相同 model 的不同 variant、connection 和 credential reference 隔离；
- strict runtime 拒绝 unbound agent 与 frozen task mismatch；
- 两个 agent 解析各自 provider/model；
- explicit spawn allowlist、exact inheritance、delegate target snapshot；
- busy rebind 拒绝、idle durable rebind 只影响未来 task；
- bottom selector busy 可选但不 live rebind；A/B 连续 Send 各自冻结 exact binding，outbox/replay/Retry 保真，direct worker message 为 nil，unavailable profile no fallback，且 worker/reviewer/GoalVerifier/future default 不变；
- catalog update 与 admission/rebind 串行化，异步 resolver suspension 后重新验证 approved map/roster/fingerprint，阻止 TOCTOU；
- ordinary attach 在 permission review `await` 后、durable admission 前重新 exact-resolve并核对 review/resolve/commit host-approved catalog snapshots；fresh `bootstrapMainAgent` 在 admission wait 前后复核 empty-session facts，并以锁外二次 resolve + 锁内 catalog recheck 关闭竞态；
- `.tool_call` audit 在 append 前分类参数：unknown/invalid/inference-control args 只落 redacted placeholder + count/redacted，不保留 raw-value digest；其他有效参数也 secret-scrub/限长，只有未脱敏/未截断的 canonical 参数可带 additive digest；旧事件继续兼容解码；
- CLI 多 route/model/variant 编译、旧 exact revision 保留、route-scoped credential reference 与 atomic provider resolution；
- CLI unqualified unique-model route 选择、ambiguous/missing reasoning variant fail closed、non-empty missing-main 显式 restore；
- GUI/CLI 只以 exact-resolved `@main` 和 reviewer/control plane 作为 startup gate；ordinary unresolved worker 的 queued invocation 在 provider request 前 durable failed、清除 busy fence且不阻止其他 agents，之后才能显式 rebind；
- macOS raw variant config key 不进入 durable binding/EventLog，diagnostics 对普通完整 HTTP(S) URL 也脱敏，provider HTTP 30x 不跟随；
- UI/CLI 只展示安全字段，URL/credential-shaped 值不能进入 roster label。
- provider/custom runtime 错误在 durable boundary 再脱敏，route/trust/egress permission metadata 不泄露 URL 或 credential。

对应 focused suites 和命令见 `docs/TESTING.md`。真实产品验收至少要用两个 profile 在一个 session 中启动两个 agent，观察各自真实上游/model/effort，同时验证修改未来-agent default 不改变现有 agent，并验证 Project Settings/CLI 的 busy rebind 被拒绝、idle rebind 后只有下一次调用改变；还要在 current work 期间用底部 selector 连续冻结两个不同的 next-main submission，确认当前 work、direct worker、控制面与 future default 均不变化。

2026-07-16 在本轮终审追加项之前的验证基线是：per-agent focused run 62/62、CLI offline `intatis selftest`、完整 SwiftPM 734 tests（14 skipped，0 failures）、IntatisMac macOS Debug 与 IntatisiOS Simulator Debug build 均通过。Computer Use 在当时最新 Debug app 中确认旧 session 对 unresolved `@main` fail closed、composer/Send disabled，以及 Project sheet 的 future default profile 和逐 agent `Legacy`/Rebind menu；未保存 rebind、未发送 provider 请求。随后新增的 diagnostic URL redaction、HTTP 30x no-follow、CLI restore-main/selection fail-closed、main/control-plane startup gate + unresolved-worker invocation isolation、opaque durable variant ID 与 attach/bootstrap TOCTOU 收口，其最终复跑结果以本轮总体验证记录为准，不能沿用上述基线冒充新改动已验证。

## 12. 设计来源与 provenance

本实现是 Intatis 原创实现，设计调研见 `codex-report/07_16_26-17_53-per-agent-inference-profile-research.md`。该报告只作为公开产品/仓库行为的 reference-only 研究；本功能未复制或翻译第三方源码、prompt、UI 资产，也未引入新依赖，因此本阶段无需更新 `NOTICE.md`。若后续实际复用上游实现，必须另按 `docs/OPEN_SOURCE_REUSE.md` 固定 commit、核对许可证并记录 provenance。

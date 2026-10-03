# OPEN_SOURCE_REUSE

文档状态：当前开源复用政策
生效日期：2026-07-12
最近核对：2026-08-31
产品基线：v0.72（build 72）

## 项目立场

Intatis 是 Apple-first、Swift-native 优先的本地 AI workbench。项目不再采用“禁止直接复用外部源码”的严格 clean-room 政策；允许在许可证兼容、来源清晰、归属完整、安全边界不降级的前提下，选择性复制、翻译、修改、链接或以独立进程复用成熟开源实现。

允许复用不等于无条件搬运。Translatis 的产品身份、Apple 平台体验、权限模型、持久化协议和安全边界仍由本项目控制；共享 Intatis module/target 名称与固定外部协议不随产品改名。

## 允许的复用形式

```text
reference       只研究公开行为、架构与测试，不复制表达
derived         复制、翻译或改写具体源码/公开 prompt；视为派生复用
vendored        把上游源码或资源放入仓库
dependency      通过 SwiftPM、系统库、包管理器或动态/静态链接使用
external-runtime 以独立 helper/process/service 运行上游实现
```

逐行把 TypeScript、Rust、Go 等源码翻译成 Swift 仍属于 `derived`，必须保留来源与许可证记录，不能标成独立 clean-room 实现。

## 许可证准入

- MIT、BSD-2-Clause、BSD-3-Clause、ISC、Apache-2.0 等宽松许可证可在完成文件级和依赖级核对后采用。
- GPL、AGPL、LGPL、MPL、SSPL、BSL、Commons Clause、source-available、双重许可或自定义许可证必须在引入前单独评估传播义务、链接边界、网络服务条款和商业限制，并取得用户明确批准。
- 缺少许可证、许可证范围不清、文件头与根许可证冲突、来源不明或仅来自代码片段转载的内容不得复制。
- 根仓库许可证不自动覆盖 vendored 依赖、生成物、字体、图标、截图、模型权重、数据集或第三方资产；必须逐项确认。
- MIT 等宽松许可证通常允许闭源商业使用，但仍须保留其要求的版权和许可声明；许可证合规不等于获得商标或品牌授权。

## 永久禁止项

- 不使用泄露、反编译、绕过访问控制获得的源码或私有 prompt。
- 不复制第三方产品名称、Logo、图标、截图、UI 资产、商标性外观或品牌文案作为 Intatis 产品身份。
- 不把上游许可证、版权声明或来源记录删除、模糊化或错误标成 Intatis 原创。
- 不得让未经 exact 审查的外部实现绕过当前 shipping path 的安全/审计边界。2026-08-22 用户明确批准
  Codex App Server 在 Code/Cowork/CLI 中**替换**旧 Intatis AgentLoop/PermissionEngine/Orchestrator
  execution core；因此该 exact runtime 使用其官方 sandbox/approval/auto-review/thread store，而不是在
  外面再包一层同等 Intatis core。Intatis 仍负责 workspace 选择、provider credential、process/thread
  lifecycle、UI 与 bounded EventLog audit projection。该例外只适用于固定 Codex release/范围；不能推广到
  Chat、iOS、其他 dependency 或把 legacy core当 fallback。
- 不让外部 runtime 扩大 iOS 平台边界；iOS 仍不得获得本地 workspace Agent、shell、Git 或 Cowork 执行能力。

## Prompt、文案与资产

- 公开仓库中由兼容许可证覆盖的 model-facing prompt 可以按 `derived` 复用，但必须固定上游 commit、记录来源、移除上游品牌/支持链接，并重新核对 Intatis 的工具名、权限语义和安全边界。
- 私有、泄露或许可证不明确的 prompt 永久禁止使用。
- 用户可见文案默认由 Intatis 自己编写；若确需复用开源文案，按源码同等记录来源，但不得造成官方关联或商标混淆。
- UI 图标、Logo、截图、产品名称和品牌视觉不因源码采用 MIT 等许可证就自动进入允许范围；没有单独确认时不得复用。

## Apple-first 实现规则

- App shell、SwiftUI/AppKit 界面、workspace bookmark、Intatis session/UI audit 与 iOS/macOS 平台边界
  优先保持 Swift 原生。若用户明确批准 external runtime 作为 execution kernel，其官方 permission、
  scheduler 与 context store 可成为该产品面的权威，但事实源拆分和迁移必须持久化、可审计且 fail closed。
- 从非 Swift 项目复用时，先判断是“选择性翻译核心逻辑”还是“隔离为外部 runtime”更合适，不做无边界的整仓移植。
- Node/Bun/Rust/Go 等 helper 默认只可作为 macOS DeveloperID 路径的隔离组件评估；引入前必须设计签名、Hardened Runtime、sandbox、更新、进程清理、资源占用和失败降级。不得把它们隐式带入 iOS target。
- 外部 runtime 必须通过受控官方协议接入 Intatis。权限/上下文若由上游 runtime 权威执行，必须明确记录
  其版本、存储、ThreadID join、approval UI 与 EventLog投影边界；不得形成没有 identity mapping、无法
  解释恢复语义的隐藏第二事实源。

## OpenAI Codex App Server 当前准入结论

- 官方仓库：`https://github.com/openai/codex`；采用 `rust-v0.145.0` peeled commit
  `25af12f7e61572b0bc18ddb1008be543b91519b0`，Apache-2.0，含 upstream NOTICE 的 Ratatui-derived
  attribution。复用分类为 `derived external-runtime` + official App Server API + narrow derived
  experimental control-plane extension。
- 仓内只保存按序应用的 `0001-responses-provider-passthrough.patch`、
  `0002-openrouter-strict-routing-shape.patch` 与 `0003-cowork-subagent-reconnection.patch`。
  前者增加一个
  request-owned、只占据Responses `provider`子树的opaque JSON config seam；不枚举provider-owned
  children；后者只在该显式OpenRouter marker存在时省略exact route未声明的optional OpenAI controls，
  不用URL/name猜测adapter。两者都不使用控制header、不提供generic whole-body或proxy/adapter。
  第三项窄改Codex既有MultiAgent V2/App Server接线：所有fork模式的子代理继承父thread已注册
  `dynamic_tools`；模型只能选择host配置的`intatis_agent_workspaces` preset ID，preset固定absolute cwd、
  exact parent-approved runtime roots、安全描述和`read-only`/`workspace-write`；显式`flat_tools=true`使
  V2协作与动态业务工具在OpenRouter等exact route上保持顶层普通function，不按provider名称/URL猜测；
  `thread/subagent/message`经双重后代核验后直接进入既有`AgentControl` mailbox，不调用root provider或
  恢复旧MessageBus。模型产生的V2任务/消息使用普通mailbox text，不使用第三方provider无法解开的
  OpenAI内部encrypted-content；relationship-filtered thread list保留只有inter-agent input、preview为空的
  spawned child。派生版本为`0.145.0-intatis.4`；0003 SHA-256为
  `9cd57fc61366cb7410f6e551aa48ec762094e9a4edbfcbf0ae4670b7ba1f2285`，且不增加dependency/Cargo.lock漂移。
- Intatis 不复制/翻译其余 Rust core，不实现 agent loop/tool/sandbox/reviewer/context/subagent替代品；本地 Swift
  仅负责进程/版本/JSON-RPC/Responses provider、动态业务工具执行、host-approved workspace/profile、
  owner-only mapping与UI/EventLog projection。
- 身份验证固定 `requires_openai_auth=false`，使用 per-session isolated `CODEX_HOME` 与 Intatis exact
  Responses credential environment injection；不得读取 ChatGPT login。
- 当前source tree不分发Codex binary。2026-08-24已在独立源码/target目录clean build当前patch的
  `codex-cli 0.145.0-intatis.4` thin arm64 validation binary，SHA-256为
  `880dbbbd97ad3077a54296940c0c219a33ac153979126be7129a8998a4ff5685`，且自报exact 0003 derivation。
  同一exact binary已安装为Intatis专用`~/.local/bin/translatis-codex`；原same-version Intatis binary因
  derivation不符而以分名备份保留，official `codex-cli 0.145.0`未改。该证据不等于bundle：正式发行仍须完成fixed Cargo
  closure、全部许可证/NOTICE、arm64+x86_64/universal产物、nested Developer ID签名/公证与clean-user gate。
- `.4` owner-only runtime record只接受exact `.4`和一致dynamic-toolset identity，所有旧runtime record均
  fail closed并要求新session。`.2 -> .3`曾是旧两补丁host的历史迁移政策，不是当前事实。
- 完整 provenance、第一版功能边界、持久化/迁移与 upgrade procedure 位于
  `ThirdPartyNotices/OpenAICodexRuntime.md`。缺条件时停止能力，不回退旧 Swift kernel。

## 每次复用前的检查清单

1. 固定上游仓库 URL、tag/commit 和具体文件路径；不得直接跟随浮动 `main`/`dev` 作为可重复构建依据。
2. 读取根许可证、目标文件头、NOTICE、依赖清单和相关资产许可证。
3. 选择 `derived` / `vendored` / `dependency` / `external-runtime` 之一，并说明为何适合 Apple 平台。
4. 评估 SwiftPM/Xcode target、macOS Developer ID 签名/公证/直接分发、
   iOS 子集、binary size、更新和供应链影响；不得仅为已取消的 Mac App Store
   产品面引入替代依赖或裁剪能力。
5. 说明外部实现如何接入现有 Permission/EventLog/Lease/PathConfinement 边界。
6. 在 `NOTICE.md` 增加当前实际采用项；需要分发完整第三方声明时新增 `ThirdPartyNotices/<project>.md`。
7. 对直接复制或翻译的文件，在文件头或相邻来源清单中记录上游 URL、commit、原许可证、本地修改摘要；不得把许可证全文散落复制到每个源码文件。
8. 添加与复用风险相称的测试，并对照上游测试覆盖输入校验、错误路径、取消、并发和安全边界。
9. 最终报告明确区分“直接复制”“翻译/改写”“仅参考行为”和“独立实现”。

## OKF / knowledge retrieval 当前准入结论

- Intatis 已把 GoogleCloudPlatform `knowledge-catalog` 的 Open Knowledge Format v0.2
  `okf/SPEC.md` 固定在 commit `3fcbb9f828c2f23d109c855ee403c3a4c81f3a96`，以
  byte-exact `vendored standard documentation` 形式保存于
  `ThirdPartyStandards/OpenKnowledgeFormat/0.2/`。规范 SHA-256 为
  `5a3311d270bebb16d558010e75064f5b75323f284992641732b1c8097511f948`；许可证为
  Apache-2.0，固定 license SHA-256 为
  `8c6db340475136df3c1201d458fa5755698eace76e510471ecc9d857d6083dac`。
  `UPSTREAM.md`、`SHA256SUMS`、`NOTICE.md` 和
  `ThirdPartyNotices/OpenKnowledgeFormat.md` 是同一 adoption record，不得只更新其中一处。
- 本次没有采用或执行上游 reference agent、Python package、prompt、sample bundle、viewer、
  HTML/CSS/JavaScript 或品牌资产。Intatis 的 Profile、Validator、snapshot/index 和 tool contract
  是独立 Swift 集成代码；OKF 本身不定义 embedding、vector store、rerank、ACL 或 RAG runtime。
- non-iOS `IntatisKnowledge` target 通过 SwiftPM 使用 Yams 6.2.2，固定 commit
  `a27b21e0c81c5bf42049b897a62aaf387e80f279`。复用类型为 `dependency`，许可证 MIT；运行闭包
  是 Yams 及其同包 CYaml/libYAML，无外部 package dependency。完整记录与许可证位于
  `ThirdPartyNotices/KnowledgeRetrieval.md` 和
  `ThirdPartyNotices/Licenses/Yams-6.2.2-MIT.txt`。Yams 只负责 bounded YAML AST；alias、custom
  tag、node/depth/scalar limits 和不执行输入仍由 Intatis host safety profile 强制。
- Apple NaturalLanguage、Accelerate 和系统加密/文件 API 属系统框架，不新增第三方 NOTICE。
  P0 dense exact KNN、BM25 tokenizer/scorer、RRF 与 embedding-cosine reranker 是仓内 Swift 实现；
  没有复制或链接 SwiftIndex、MLXEmbedders、sqlite-vec、USearch、VecturaKit、Wax、llama.cpp 或
  其它调查项目的源码、模型和 runtime。以后若采用其中任何实现，必须重新固定 commit、license、
  transitive closure、universal macOS/iOS target 边界并更新 NOTICE。

## OpenCode 当前准入结论

- 官方活跃仓库：`https://github.com/anomalyco/opencode`
- 调研时根许可证：MIT
- 当前状态：`research-only`，截至本政策生效时尚未把 OpenCode 源码、公开 prompt 或 UI 资产加入 Intatis。
- 后续允许选择性复用其具体实现，但每批必须固定 commit、核对目标文件与传递依赖，并按本政策记录 provenance。
- Intatis 不使用 OpenCode 名称、Logo、图标或 UI 品牌；若复用 TypeScript 实现，优先选择可验证的逻辑/测试进行 Swift 派生实现，或作为 macOS-only 隔离 runtime 评估。

## OpenCode provider adapter 与 AI SDK wire 参考记录

- OpenCode 上游：`https://github.com/anomalyco/opencode`；本机实际版本
  `1.18.8`，固定 release commit
  `3c81a5d1ddceab377d9ad71c14899e6935333fdd`（调研日期
  2026-07-28，MIT）。同时核对当日 dev commit
  `017a5977d2107092007623e507fc5c6eb337d3b2`，相关 provider/request/transform
  文件与 release 内容一致。
- 阅读范围为
  `packages/opencode/src/provider/provider.ts`、
  `provider/transform.ts`、`session/llm/request.ts`、`session/llm.ts` 与
  `test/provider/cf-ai-gateway-e2e.test.ts`。确认 custom provider 的 package
  selection、defaults → model → agent → variant deep merge、namespaced
  provider options 和最终 SDK dispatch；“配置保真”不等于 raw options 直接
  拼入 HTTP body。
- 对应 wire 行为固定核对
  `@ai-sdk/openai-compatible@2.0.41`，Vercel AI commit
  `99327b1d7b3d172ed0aae7230ae153f2d32b0ebb`（Apache-2.0），以及
  `@openrouter/ai-sdk-provider@2.9.0`，OpenRouter provider commit
  `5cef3c562b12c89c7ddbf1c88565e1219af6a302`（Apache-2.0）。另参考 Remeda
  `mergeDeep` 的公开 plain-object recursion/array-scalar replacement 行为；
  本地没有引入 Remeda runtime。
- 本轮复用形式是 `reference`：Intatis 以 Swift 独立实现 raw npm identity、
  reviewed adapter selection/lowering、deep merge、durable revision 与
  fail-closed 边界；没有复制、逐行翻译、vendor、链接或分发 OpenCode、
  Vercel AI SDK、OpenRouter SDK、Remeda 的源码、测试、prompt、文案、名称、
  Logo 或 UI 资产。因此没有新增第三方依赖/分发物，`NOTICE.md` 无需修改。
  将来若直接采用其源码、fixture 或 runtime，必须按固定目标文件重新分类为
  `derived` / `vendored` / `dependency` 并补齐许可证与 NOTICE。

## Codex CLI managed terminal 参考记录

- 上游：`https://github.com/openai/codex`
- 固定 commit：`1a817bb95d942d4ca93f6ed09c97968713ff6d2a`（调研日期 2026-07-24）
- 核对结果：根许可证为 Apache-2.0，仓库包含 NOTICE；本轮阅读了 `codex-rs/core/src/unified_exec/process_manager.rs`、`async_watcher.rs`、`head_tail_buffer.rs`、`codex-rs/utils/pty/src/pty.rs`、`process.rs`、`codex-rs/core/src/tools/handlers/unified_exec/write_stdin.rs`、`codex-rs/protocol/src/shell_environment.rs` 与 `codex-rs/sandboxing/src/seatbelt_base_policy.sbpl`。
- 本轮复用形式是 `reference`：参考了“长进程返回 session、后续继续写 stdin/轮询”“真实 PTY/controlling terminal”“持续 drain 且有界保留 head+tail”“process/session manager 负责取消与清理”“sandbox 与环境由 host 冻结”等行为和测试方向。
- Intatis 的 `ProcessTerminalSessionManager`、Swift tool/lease/permission/EventLog 接线和 `IntatisPTYLauncher` C helper 均为独立实现；没有复制、逐行翻译、vendor 或链接 Codex Rust/C 源码、prompt、测试、文案、名称、Logo 或 UI 资产。因此本轮没有新增第三方分发物，也没有修改 `NOTICE.md`。如果后续直接采用任何 Codex 文件或表达，必须把对应批次改记为 `derived` / `vendored` / `dependency`，重新核对该 commit 的目标文件、依赖、Apache-2.0 NOTICE 与本地修改摘要后再更新 NOTICE。

## Codex CLI 模型历史参考记录

- 上游：`https://github.com/openai/codex`
- 固定 commit：`4c43465133428898aa84f0bfc02c306ed65fb66a`（调研日期 2026-07-25）
- 核对结果：根许可证为 Apache-2.0，仓库包含 NOTICE；本轮重点阅读 `codex-rs/core/src/state/session.rs`、`context_manager/history.rs`、`context_manager/normalize.rs`、`codex-rs/core/src/session/turn.rs`、`session/rollout_reconstruction.rs`、`codex-rs/protocol/src/models.rs`、`protocol.rs`、`codex-rs/rollout/src/policy.rs` 以及对应 context/history/compaction tests。
- 本轮复用形式是 `reference`：参考同一 thread 持有有序 model items、completed item 单次入历史、function call/output 按 call ID 配对、请求前对 missing/orphan pair 做 prompt-only 归一化、resume 从 rollout 重建，以及 compaction 保存完整 `replacement_history` 的行为。
- Intatis 的 `ModelHistoryItemPayload`、EventLog wire event、Swift projector、legacy bridge、AgentLoop 接线和测试均为独立实现；没有复制、逐行翻译、vendor 或链接 Codex Rust 源码、prompt、测试、文案、名称、Logo 或 UI 资产。因此本轮没有新增第三方分发物，也没有修改 `NOTICE.md`。后续若直接采用上游任何文件或表达，必须重新按目标 commit 核对来源与 Apache-2.0 NOTICE，并把复用类型改为 `derived` / `vendored` / `dependency`。

## Codex CLI Skill 生命周期与 replacement-history compaction 参考记录

- 上游：`https://github.com/openai/codex`
- 固定 commit：`bd2de422aa287b97b06ca6425a10935bcf1b3731`（调研日期
  2026-07-28）；根许可证为 Apache-2.0，仓库包含 NOTICE。
- Skill 生命周期重点核对
  `codex-rs/core-skills/src/{render,injection,skill_instructions,service}.rs`、
  `codex-rs/skills/src/model.rs`、
  `codex-rs/app-server/src/skills_watcher.rs`、
  `codex-rs/core/src/session/{turn,context_window}.rs` 和
  `codex-rs/core/src/mcp_skill_dependencies.rs`。确认 Codex 没有 Session 级
  activated ledger/TTL：当前 Turn 解析并注入 Skill，物理正文进入普通历史，
  后续由通用 compaction 管理；watcher 只使下一 Turn 的 metadata cache 失效。
- catalog/MCP 对照还核对了 Core renderer 与
  `codex-rs/ext/skills/src/{dynamic_skill_selector,shadow_selection_experiment}.rs`。
  Core 路径以 exact raw primary `context_window` 的 2% 作为 metadata token
  budget，缺失时回退 8,000 characters；ext/skills 的 resolved/max-window +
  4k cap 是另一条路径，不能混写成 CLI Core 合同。MCP dependency 正式范围是
  `agents/openai.yaml` 中的 MCP tools，并包含用户确认、配置/OAuth 与 runtime
  refresh 流程；Intatis 只独立实现了更窄的 metadata + request-owned
  fail-closed preflight，没有复制或声称实现该外部变更流程。
- Intatis 的 OpenCode-compatible profile parser 会在 `context_window` 缺失时
  把显式 `limit.context` 归一到 canonical primary `contextWindowTokens`；
  catalog 对该 canonical primary 应用同一 2% 公式，但仍拒绝
  `max_context_window`、compaction threshold 或 model slug 猜测。这是本地
  compatibility adapter，应与上游 Core 原始字段事实分开记录。
- compaction 重点核对 `codex-rs/core/src/compact.rs`、
  `session/rollout_reconstruction.rs`、`state/auto_compact_window.rs`、
  `codex-rs/protocol/src/{openai_models,protocol,compacted_item}.rs` 及
  `core/tests/suite/{compact,compact_remote}.rs`。参考事实包括 90% auto /
  95% usable window、pre/mid-turn 触发、最多 20k token 真实用户消息 +
  continuation summary、完整 replacement history、UUIDv7 window chain 与
  latest-checkpoint-plus-suffix 恢复；同时记录 remote persistence 测试 ignored
  与 network-dependent 测试 skip，未把它们写成上游已完整证明。
- 本轮复用形式为 `reference`。Intatis 的 Swift protocol/EventLog event、
  compactor、projector、token estimator、profile policy、catalog budget/
  metrics、`agents/openai.yaml` parser、MCP locator fingerprint、
  request-owned host availability assertion、AgentLoop 接线与测试均为独立实现；没有
  复制或逐行翻译 Rust 源码，没有复制 compact/Skill prompt、snapshot、
  fixture、产品文案、名称、Logo 或 UI 资产，也没有 vendor、链接或分发 Codex
  crate。Intatis 还保留了比上游更强的 EventLog-first
  commit-before-live-swap 与 per-agent CAS。
- 因此没有新增第三方分发物或依赖，`NOTICE.md` 无需修改。若以后直接采用
  Codex prompt、源码表达、测试 fixture 或 remote compact wire 实现，必须按
  目标文件和固定 commit 重新分类为 `derived` / `vendored` / `dependency`，
  复核 Apache-2.0 NOTICE 并更新 provenance 与 `NOTICE.md`。

## Codex CLI Skills 参考记录

- 上游：`https://github.com/openai/codex`
- 固定 commit：`fbe65995bbcd4da249cfdafe0300ac3cb2cb3b3c`（调研日期
  2026-07-27）
- 核对结果：根许可证为 Apache-2.0，仓库包含 NOTICE；本轮阅读
  `codex-rs/core-skills/src/render.rs`、`injection.rs`、
  `skill_instructions.rs`，并定位 `codex-rs/core/src/session/mod.rs` /
  `session/turn.rs` 的 developer catalog 与 user contextual injection
  接线。参考事实包括标准 root 类别、canonical 去重、hidden/depth/directory/
  entry bounds、64/1024 metadata limits、8k/2% catalog budget、system→admin→
  repo→user budget order、无歧义 `$name`、完整 `SKILL.md` 激活和 child
  独立加载。
- 本轮复用形式是 `reference`。`IntatisSkills` 的 Swift loader、snapshot、
  catalog 文案、dynamic tools、permission/durable execution 接线与测试均为
  独立实现；没有复制、逐行翻译、vendor 或链接 Codex Rust 源码、公开 prompt、
  测试、文案、名称、Logo 或 UI 资产。Intatis 还增加了自己的
  WorkspaceLease、SecretScanner、48 KiB durable output、iOS linkage 与
  stricter no-symlink 边界。历史 App Store 分支不是当前复用准入条件。
- 因此本轮没有新增第三方分发物或依赖，`NOTICE.md` 无需修改。若以后复制
  Codex prompt/源码、支持其 plugin runtime 或改变当前严格 symlink 策略，必须
  按具体文件和 commit 重新登记 `derived` / `vendored` / `dependency`、
  Apache-2.0 NOTICE 与本地修改。

## OpenAI Codex `skill-creator` 实际采用记录

- 采用日期：2026-07-28。上游为 `https://github.com/openai/codex` 的
  `rust-v0.145.0`，固定 commit
  `25af12f7e61572b0bc18ddb1008be543b91519b0`；根许可证为
  Apache-2.0，仓库包含 NOTICE。该固定 release 与本机已安装的 Codex CLI
  0.145.0 对应。
- 实际采用路径为 `.agents/skills/intatis-skill-creator/`，复用类型从上面的
  早期纯调研批次明确变为 `vendored` + `derived`。本批采用
  `SKILL.md`、三个 Python helper 和 `references/openai_yaml.md` 的公开结构与
  表达，并把设计指导重组为本地 `references/design-guide.md`。
- 本地派生改名是有意的：DeveloperID/CLI 同时发现
  `$CODEX_HOME/skills/.system`，若再放置同名 `skill-creator`，显式
  `$skill-creator` 会因跨 root 歧义 fail closed。派生版本还改为
  `.agents/skills` 默认路径、Python 标准库实现、48 KiB 资源边界、
  WorkspaceLease/普通权限链语义，并移除会触发 Intatis SecretScanner 的
  credential-shaped 示例。
- 没有复制上游 `agents/openai.yaml`、icon/image/品牌资产、其他系统 Skill
  或 Codex runtime。生成 `agents/openai.yaml` 只是 opt-in
  cross-harness metadata；Intatis 只消费其中严格的 MCP dependency 子集，
  interface/policy 字段不授予能力。
- 完整文件级 provenance、上游 Git blob、修改摘要、执行边界和升级流程在
  `ThirdPartyNotices/OpenAICodexSkillCreator.md`；复用现有完整许可证
  `ThirdPartyNotices/Licenses/Codex-61a44880-Apache-2.0.txt`，并已同步更新
  `NOTICE.md`。以后升级必须重新固定 commit、核对目标 blob、许可证/NOTICE、
  本地修改和验证结果。

## Gemini CLI / Pi Skills 对照记录

- Gemini CLI 上游：`https://github.com/google-gemini/gemini-cli`；固定
  commit：`3818efbbfbf8ef029ef53a6ab1093db39971ce83`（调研日期
  2026-07-27）。根许可证与目标文件头均为 Apache-2.0。本轮阅读
  `packages/core/src/skills/skillLoader.ts`、`skillManager.ts`、
  `packages/core/src/tools/activate-skill.ts` 和
  `tools/definitions/coreTools.ts`。其实现把 metadata discovery、带优先级的
  manager、专用 `activate_skill`、完整正文和资源目录分层，并让非 built-in
  Skill 激活经过确认；激活后会把 Skill 目录加入 workspace context。
- Pi 上游：`https://github.com/earendil-works/pi`；固定 commit：
  `99e34013d13a71c2aef1958fd5ab44fa9bfc75dd`（调研日期 2026-07-27）。
  根许可证为 MIT。本轮阅读
  `packages/coding-agent/src/core/skills.ts`、`system-prompt.ts` 和
  `resource-loader.ts`。其实现校验 Agent Skills metadata、发现多类 root、
  把 catalog 放入 system prompt，并要求模型用通用 `read` 工具读取
  `SKILL.md` 与相对资源。
- 两条对照均为 `reference`。Intatis 采用“专用激活 + 渐进披露”的结构判断，
  但没有复制两者的源码、prompt、测试或文案；同时明确不采用 Gemini 激活后
  扩大 workspace context、Pi 依赖 generic read/path 的读取方式。
  `IntatisSkills` 只暴露 snapshot-bound `activate_skill` /
  `read_skill_resource`，不把 Skill 目录变成新权限根，也不以 `read_file`
  兜底。没有新增第三方分发物或依赖，因此 `NOTICE.md` 无需修改。

## 官方 Swift MCP SDK 当前准入结论

- 上游：`https://github.com/modelcontextprotocol/swift-sdk`
- 固定版本与 commit：`0.12.1` /
  `a0ae212ebf6eab5f754c3129608bc5557637e605`
- 复用形式：`vendored` + `derived`；本地 client-only package 位于
  `Vendor/MCPClientSDK`。
- 许可证：上游处于许可迁移期；完整组合文本同时保留 Apache-2.0、未完成
  relicensing 的既有 MIT contribution，以及非 specification 文档的
  CC-BY-4.0 声明。不得把整批源码简写成单一许可证。
- 最终 SwiftPM 依赖闭包固定为 `swift-system 1.4.0`、
  `swift-log 1.6.2` 与 Apple 平台 `EventSource 1.1.0`；精确 revision
  由本地 manifest 和根 `Package.resolved` 双重固定。`swift-nio`、
  docc plugin、swift-atomics 与 swift-collections 不进入 MCP 产品依赖图。
- Linux CLI/MCP 图额外使用官方 `apple/swift-crypto 4.5.1`
  （commit `47d3869a7291f085c1fb9fb1e6d3b97a793f45c6`）的 `Crypto`
  product，替代 Linux 不存在的 CryptoKit；所有 root target dependency
  都有 `.linux` 平台条件，macOS/iOS 继续只链接系统 CryptoKit。
  其传递闭包包括 `swift-asn1 1.7.1`，且 swift-crypto 内 vendored
  BoringSSL `0226f30467f540a3f62ef48d453f93927da199b6` 和 XKCP
  `11297f566178023faba59ff14b6b399241488283` 的完整许可证/NOTICE、
  精确来源和完整性散列均登记在 `ThirdPartyNotices/SwiftCrypto.md`
  与 `ThirdPartyNotices/Licenses/`；不得换成自制散列/加密 fallback。
- 上游 `MCP` product 同时含 client/server API，不满足 Intatis
  client-only 边界。因此本地衍生包排除 `Server` actor、HTTP Server
  transports、conformance executables、paired in-memory/custom network
  transports 与 server-side OAuth publishing/validation types；只保留
  Client、Base client closure 以及客户端必须使用的 tools/resources/
  prompts/completion/logging wire schema。
- `Vendor/MCPClientSDK/UPSTREAM.md` 固定源码 inventory，
  `Vendor/MCPClientSDK/PATCHES.md` 记录逐项修改与升级重放要求，
  `ThirdPartyNotices/MCPClient.md` 和 `ThirdPartyNotices/Licenses/`
  提供分发声明与完整许可证。根 `NOTICE.md` 已登记本次实际采用项。
- 任何升级都必须重新验证 client-only 编译闭包、per-server version
  patch、HTTP/OAuth/stdio/tasks conformance、Swift/macOS/Linux compatibility
  和无 Server API/target/binary/seam；Linux 还必须重跑 portable crypto
  KAT 与 glibc/musl 双架构静态构建。不能直接切回上游单一 `MCP`
  product。

## Codex MCP tool_search 派生复用记录

- 上游：`https://github.com/openai/codex`，固定 commit
  `61a44880a85d2fd0d8770908dea5733495e571c8`；许可证 Apache-2.0。
- 复用形式：公开 `tool_search` wire/history 合同、MCP 搜索文本字段和
  stdio schema cache 行为按 `derived` 登记；未采用 Codex MCP Server、
  UI、品牌资产、私有 prompt 或 Rust runtime。
- Codex 固定使用 `bm25 2.3.2` 的 English default tokenizer。Intatis
  对 scoring/embedder/tokenizer/Snowball/fxhash 做 Swift 派生实现，
  base64 封装 deunicode 1.6.2 未修改数据，并复制 stop-words 0.9.0 的
  179 项英文表。对应 MIT/BSD-3-Clause/Apache-2.0 来源、crate
  checksum、文件级修改和完整声明见
  `ThirdPartyNotices/MCPToolSearch.md`。
- `Tests/MCPBM25ParityOracle` 是不进入产品 target 的 source-only Rust
  差分工具；语料由代码生成，不分发 `rust-stemmers/test_data`。Swift
  测试固定 tokenizer、stemmer、逐位 BM25 分数和 10,000 文档压力结果。
- 任何 Codex 或 tokenizer 依赖升级都必须重新固定源码/包 checksum，
  运行 Rust oracle 与 Swift digest/bit-pattern 对照，并重新核对
  `tool_search_output` history、deferred tools 不进入后续顶层 `tools`、
  stale catalog fail-closed 及 32-entry/30-minute stdio LRU 边界。

## MCP 原生 HTTP transport 准入结论

- `Packages/IntatisCurlTransport` 是 Intatis 自有的 C/Swift 边界实现；
  没有复制 curl、BoringSSL 或 zlib 源码。复用形式是 `dependency`：
  macOS 链接 Apple SDK/系统提供的 libcurl，Linux CLI 链接官方 Swift
  Static Linux SDK 提供的静态 archive。iOS 不链接该 target。
- Apple 路径不 vendor 或随 App bundle 复制 Darwin libcurl；release
  必须用最终 App linkage/bundle inventory 复核这一点。Linux 路径会把
  实际使用的 object code 合入单文件静态 CLI，因此必须随 CLI 提供完整
  第三方声明，不能把 SDK 中的库误当成终端用户系统库。
- Linux 构建制品固定为官方
  `swift-6.3.3-RELEASE_static-linux-0.1.0` artifact，Swift.org 公布的
  archive SHA-256 为
  `87c3eaf908e67c0e13a84367119e12273cec1d2cd3d81f7d74bb36722d6b607b`；
  提取后的 SPDX SBOM SHA-256 为
  `bef245e3aa47c9623dfc7e5d4df01510f283722b6e8d9a80a38cc3c1cb4040a0`。
  `libcurl.pc` 的静态闭包是
  `-lcurl -lssl -lcrypto -lz`，两套 architecture archive 的逐文件
  hash 见 `ThirdPartyNotices/MCPHTTPTransport.md`。
- curl 的 SBOM 条目为 `8.15.0`/`MIT`，但 SDK 自带
  `curlver.h`/`libcurl.pc` 标成 `8.15.0-DEV`，后者文件头使用精确
  SPDX `curl`。准入采用更保守的 curl 原始 `COPYING` 条款，不能只按
  泛化 MIT 处理。zlib 由 SBOM 与 header 共同确认是 1.3.1 / `Zlib`。
- SDK 的 `libssl.a` / `libcrypto.a` headers 明确是 BoringSSL，SBOM
  许可证表达式为 `OpenSSL AND ISC AND MIT`，但 `versionInfo` 为空。
  该 SBOM 缺项已通过 Swift 官方 Static Linux SDK 构建 recipe
  `swiftlang/swift-docker@cdfdf30bef6f1529ad34662274db00781d87ab61`
  与双架构 header 字节身份交叉校验收口：curl 固定
  `curl-8_15_0` / `cfbfb65047e85e6b08af65fe9cdbcf68e9ad496a`，
  BoringSSL 固定
  `817ab07ebb53da35afea409ab9328f578492832d`，zlib 固定 `v1.3.1` /
  `51b7f2abdade71cd9bb0e7a373ef2610ec6f9daf`。SDK 中 `aarch64` 与
  `x86_64` 的 `curlver.h`、`openssl/base.h`、`zlib.h` Git blob
  分别与上述固定源码完全一致；详细 blob ID 见
  `ThirdPartyNotices/MCPHTTPTransport.md`。
- Swift Crypto 4.5.1 的 BoringSSL commit
  `0226f30467f540a3f62ef48d453f93927da199b6` 是另一套依赖，不能与
  Static Linux SDK 的
  `817ab07ebb53da35afea409ab9328f578492832d` 相互冒充。官方 artifact
  checksum、SBOM hash、Swift recipe/source pins、headers/pkg-config
  与逐 architecture archive hash 共同构成可复验 provenance；SDK 未
  提供单 archive 的 signed source attestation 或 reproducible-build
  声明，文档不能把 header identity 夸大为 `.a` 的逐位复现证明。
  Linux 分发仍须附带 OpenSSL、Original SSLeay、ISC 与 fiat-crypto
  MIT 的完整组合文本及必要 acknowledgement。
- 完整来源、二进制 hash、许可证文本和分发义务位于
  `ThirdPartyNotices/MCPHTTPTransport.md` 与
  `ThirdPartyNotices/Licenses/curl-8.15.0-COPYING.txt`、
  `ThirdPartyNotices/Licenses/zlib-1.3.1-LICENSE.txt` 与
  `ThirdPartyNotices/Licenses/BoringSSL-817ab07ebb53da35afea409ab9328f578492832d-LICENSE.txt`；
  根 `NOTICE.md` 已区分 Apple system library、Linux static archive
  与 Swift Crypto 的另一套 BoringSSL closure。
- 升级 Swift toolchain/Static Linux SDK、替换 archive、改变 link
  flags 或新增 TLS/compression backend 时，必须重新下载核验官方
  checksum、读取完整 SBOM/pkg-config/headers、重算双架构 archive
  hash、比较许可证/NOTICE、更新上述记录，并重跑双架构静态 build。
  仅复用旧 notice 或仅看到库名相同不构成升级准入。

## Flotis 第一方兄弟项目语音 runtime 迁移记录

- 来源仓库：`https://github.com/Vita0818/Flotis`；本地兄弟工作树
  `/Users/vita/Vitemis/Flotis`，迁移时 Git base commit 为
  `e998c9dbe2ceb9d9b4973c250530e9d6e5dabe52`。该工作树存在未提交改动，因此仅记录 base commit
  不足以复现本轮来源；实际读取文件的 SHA-256 为：
  `AudioRecorder.swift` = `d1cdfdb81b33509d44b1cf737ba6e1c937a4361894f9588f16ca35b91d209c31`，
  `VoiceInputController.swift` = `02f2822bafdd3f8c39eaaf56af228cd3e8a7a683e6060bd2fb485cc05b954123`，
  `TranscriptionAdapterRegistry.swift` = `db4e35993aad1191747d8574f86affc048df9dcffe842f11c3aaec68e92483cb`，
  `OpenAICompatibleTranscriber.swift` = `e0d92850431e7f5cb99029e4a8c26c35df876fab389d3739402c44fa6a96d22b`，
  `TranscriptionAdapterRuntimeTests.swift` = `49fc745656792494374f0758d3d92860fe592ea115e1d4b8067ed3847ec35c1c`。
- Flotis 根目录当前没有 `LICENSE` / `NOTICE`。本批不是把无许可证第三方代码作为开源上游准入；
  用户在本任务中以两个本地项目所有者身份明确要求把该第一方兄弟项目实现迁入 Intatis。因此本批
  仅在该明确第一方授权前提下按 `derived` 记录；若未来无法继续证明同一权利主体或授权范围，必须
  立即按“缺少许可证”规则停止升级/分发，不得把本记录冒充开放许可证。
- 实际迁移范围是单模型 recorded-file 子系统：录音 format/settings、permission-pending generation、
  stop/cancel/temp cleanup、runtime configuration、普通文件/扩展/大小校验、disk-backed multipart、
  OpenRouter JSON-base64 `input_audio`、严格 JSON response 与对应 tests。Swift 文件头保留相邻来源说明；
  Intatis 另外保留 exact `transcription_model`/adapter、credential lazy resolution、process-wide microphone
  lease、no-redirect provider runtime、bounded shutdown 和 composer draft-only 边界。
- 明确未采用 Flotis 的多模型并发对比、候选选择、provider/语音设置页、floating panel、全局快捷键、
  review/clipboard、Accessibility 注入、InputMethodKit target、品牌、图标、文案或其他 provider/realtime
  runtime。没有新增 package、外部 runtime、二进制或视觉资产。
- OpenRouter JSON 请求/响应另外只按官方 Speech-to-Text 文档作协议核对；没有复制其 SDK 源码或示例。
  本批没有新增第三方分发物，因而 `NOTICE.md` 不增加 Flotis 第三方条目。若后续把 Flotis 作为独立
  第三方发布物或引入其其他文件，必须先补齐权利/许可证结论并重新评估 NOTICE。

## 固定文档 external runtime 当前准入结论

- 生产源码只调用固定公开接口：Docling 2.117.0 的 converter/iteration/ranged Markdown/chunker、
  python-docx 1.2.0、python-pptx 1.0.2、openpyxl 3.1.5、Tesseract 5.5.3、Tectonic 0.15.0、
  LibreOfficeDev 26.8.0.0.beta1，以及 Apple PDFKit/WebKit。直接版本、Heron model revision、
  English tessdata hash、layout、2 GiB RSS 和 release evidence schema 固定在
  `Packages/IntatisTools/Runtime/document-runtime/release-spec.json`；详细 provenance/license
  见 `ThirdPartyNotices/DocumentReadingRuntime.md` 与 `NOTICE.md`。
- Tectonic pin 使用官方 tag `tectonic@0.15.0`、commit
  `0a8e2f52b895e2fd60cb461c1859b927a18e024d`。Tectonic 自身为 MIT，但它派生/分发的
  XeTeX/TeXLive offline resource closure 具有多种许可证，不能只用顶层 MIT 覆盖；runtime SBOM 与
  license bundle 必须逐项登记。工具只使用 `--only-cached`，不允许在线下载或另一个 TeX runtime。
- Docling/Python/LibreOffice/Tesseract/Tectonic 不作为 Swift package 链接，也不进入 iOS。shipping
  macOS 仅从 App bundle 的 active-architecture root 读取；CLI/debug user-managed root 只是开发
  seam。所有 native libraries 与 nested executables 必须先完成 exact hash、Mach-O architecture/
  dependency/RPATH、bottom-up Developer ID signature 与外层 App seal 验证。
- 当前仓库新增的是 source integration、release spec、validator 和 release staging gate，没有提交
  runtime binary、双架构 SBOM/license roots、notarized App 或 clean-machine proof。因此当前状态是
  “依赖准入与 fail-closed 合同已记录，发行闭包未完成”，不得声称制品已经可发布。
- EPUB 写已经从产品工具面删除；`DocumentEPUBBackends.swift`、rbook helper、EPUBCheck wrapper 与
  `ThirdPartyNotices/DocumentRBookHelper.md` 同步删除。pdfcpu 与旧 write verifier 也不再是生产
  dependency。保留 `read_epub` 只因为它直接使用固定 Docling reader。今后不得以 legacy/fallback
  名义恢复这些依赖；若重新提出 EPUB write 或 PDF semantic validation，必须作为新 exact 能力重新
  完成产品决定、license/provenance、安全和发行审查。
## JetBrains Mono 英文字体正式采用结论

- 用户于 2026-08-19 先要求全局试用 JetBrains Mono，随后明确批准保留为 macOS/iOS 第一方统一
  英文字体。上游固定为
  `https://github.com/JetBrains/JetBrainsMono` tag `v2.304`、commit
  `cd5227bd1f61dff3bbd6c814ceaf7ffd95e947d9`；官方页面与仓库均声明 SIL Open Font License
  1.1，可用于商业与非商业应用。
- 复用类型为 `vendored`、unmodified font binaries。只采用两个官方 variable TTF：
  `fonts/variable/JetBrainsMono[wght].ttf`（303,144 bytes，SHA-256
  `662a196d58f1183bf2d77428b6d5283fe3f45161ab021bea4036bc98e5cac016`）和
  `fonts/variable/JetBrainsMono-Italic[wght].ttf`（308,888 bytes，SHA-256
  `f115aaa12113718c02ce72864fe6823b87241bc23d3e44cf1220155f861063f2`）。完整 OFL 原文
  SHA-256 为 `30f0c136e3c88e422d0791acd97238870f9054a9729bc34cf2ff0d4ed8cac4ad`。
- 没有采用上游源码、构建脚本、static/web font 全集、IDE integration、Logo、截图或品牌文案。
  完整 file-level provenance、PostScript inventory 与运行边界见
  `ThirdPartyNotices/JetBrainsMono.md`；根 `NOTICE.md` 和完整许可证已同步登记。
- 产品接线只使用 Apple Core Text 官方 process registration API。普通启动、Debug/Release 与发行构建
  使用同一条 JetBrains Mono 路径，没有 system-font opt-out 或实验参数；使用前验证 bundle bytes、
  完整 descriptor 集与注册后 URL identity。任一缺失、冲突或漂移都使 App 启动 fail closed，不读取
  用户安装的同名字体，也不切换另一字体。
- JetBrains Mono 不覆盖中文。Core Text probe 已确认英文 run 为 `JetBrainsMono-Regular`、中文 run
  为 `PingFangSC-Regular`；这只是当前 Apple 平台的 glyph fallback 观察，不把 PingFang vendor 成
  Intatis 资源。正式字体接线不改变文本字节、本地化、EventLog、provider prompt、权限或 iOS 产品边界。
- 两份 exact TTF 已获产品采用批准。正式发布仍须完成大小、Dynamic Type、VoiceOver、中文 fallback、
  两端最终 bundle 与许可证验收；任何 exact dependency closure 漂移须重新审查，但无需删除已批准资源。

## 上游升级规则

- 每个已采用上游维护一个 pinned commit 和本地 patch/translation 摘要。
- 升级时先比较许可证、NOTICE、依赖和安全边界，再比较源码；不能只做版本号替换。
- 上游的新权限默认、工具能力或网络/文件访问不能自动继承到 Intatis；必须重新映射到 CapabilityLease、WorkspaceLease 和 PermissionEngine。
- 无法确认行为或许可证变化时标记 `UNKNOWN` 并停止合入，不得猜测。

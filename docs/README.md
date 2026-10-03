# Translatis 文档索引

当前产品基线：**v0.72**（build 72）
最近核对：2026-09-08

Translatis 是产品/宿主身份；`Intatis*` 名称在本文档中表示共享实现、供应链或固定协议合同。
这个索引区分“当前规范”和“历史证据”。版本、产品状态或下一步判断只允许从当前规范
读取；带旧版本号的历史文件保留用于解释迁移和兼容性，不能覆盖当前源码。

## 当前规范

| 文档 | 权威范围 |
|---|---|
| `VERSIONING.md` | 产品版本与 build number 的唯一治理规则 |
| `CURRENT_STATE.md` | 当前能力、验证状态、已知缺口 |
| `PROJECT_MAP.md` | 当前目录、target、入口、关键文件和脚本 |
| `ARCHITECTURE.md` | 当前运行时链路、数据模型、安全与平台边界 |
| `CODEX_RUNTIME_INTEGRATION.md` | 其他Vitemis项目直接依赖同一Codex内核的SwiftPM路径与v1稳定宿主合同 |
| `COWORK_UI_INTEGRATION.md` | 其他macOS项目只复用完整Cowork右侧UI、保留自身runtime/session/tools的v1合同 |
| `CHAT_HOSTED_SEARCH.md` | Chat 模型自主托管搜索，以及shipping Codex Agent strict hosted-search tool的exact-route合同 |
| `DO_NOT_BREAK.md` | 协议、持久化、权限、工具与 UI 回归禁区 |
| `TESTING.md` | 当前测试矩阵、命令和最近一次证据 |
| `MACOS_DISTRIBUTION.md` | Developer ID 直接分发合同 |
| `OPEN_SOURCE_REUSE.md` | 第三方源码、prompt、依赖和 NOTICE 准入 |
| `COWORK_PRINCIPLES.md` | legacy/manual-rollback Cowork/AgentKernel 编排原则；Codex shipping path 以 ARCHITECTURE 顶部新节为准 |
| `PER_AGENT_INFERENCE_PROFILES.md` | per-agent exact inference binding 契约 |
| `CURRENT_UI_COLOR_SYSTEM.md` | 当前 Apple 原生表面与 Liquid Glass 规范 |
| `NEXT_TARGET.md` | 唯一活跃目标：定位并消除完整SwiftPM回归的SharedUI间歇性挂起；不保存已完成里程碑流水账 |
| `TRANSLATIS_BASELINE.md` | Intatis v0.72 源树基线、翻译 Skills、Translatis 宿主命名边界与本轮验证摘要 |

Codex Runtime 的第三方采用、认证/持久化边界与二进制发行 gate 位于
`../ThirdPartyNotices/OpenAICodexRuntime.md`；可复现provider-body passthrough与strict request-shape派生位于
`../ThirdPartyPatches/OpenAICodexRuntime/`。它们是供应链证据，不替代上述架构与状态文档。

Document Runtime 的 direct pins/provenance/license gate 位于
`../ThirdPartyNotices/DocumentReadingRuntime.md`，机器可读发行合同位于
`../Packages/IntatisTools/Runtime/document-runtime/release-spec.json`，机械 validator 位于
`../scripts/validate-document-runtime.sh`。这些文件不代表双架构 signed runtime 已经存在。

根 `README.md` 是产品入口，但不是运行时、工具面或发行状态的权威来源；与本索引中的当前规范或
源码冲突时，以源码和当前规范为准。2026-09-01已按用户单独授权修正其中旧`.3` runtime、root-only
Cowork、能力状态与发行root示例。根 `ARCHITECTURE.md` 仅为兼容链接，架构正文只维护在
`docs/ARCHITECTURE.md`。`AGENTS.md` 及 Claude/Gemini shims 是操作政策，不表达产品版本。

## 当前事实的语义门

版本一致性只证明 `0.72 (72)` 等元数据相同，不能证明功能可达、runtime 已进包或测试稳定。任何文档
准备写“当前可用”“已接回”“完整通过”前，必须同时核对与该断言对应的事实：

- production 入口真实调用哪条 runtime path，不能从仓内仍可编译的 legacy 类型/服务推断 shipping 行为；
- model-facing authoritative tool list 或 App Server dynamic tool catalog 中是否真的含该工具；
- 最终 App bundle 是否含 shipping locator 强制要求的 runtime/resource inventory；
- 最近一次完整测试是否真正退出 0；定向测试通过不能覆盖组合顺序挂起；
- 旧实现若仍保留，相关段落必须在本段或标题处直接标成 `legacy/manual rollback`，不能只依赖文件顶部的
  总体覆盖声明。

## 操作政策与供应链资料

下列文件不是产品状态页，不应复制当前版本号：

- 根目录与 `docs/` 下的 `AGENTS.md`、`CLAUDE.md`、`GEMINI.md`：agent 操作规则或继承入口；
- `NOTICE.md`、`ThirdPartyNotices/` 和依赖附带的 README/LICENSE：来源与许可证证据；
- `.agents/skills/` 下的文档：项目级 skill 说明；
- `codex-report/`、`claude-report/`、`gemini-report/`：按日期冻结的执行报告。

这些资料保留自己的规则、依赖版本或历史日期。不得为追齐 Intatis marketing version 而
批量替换其中的版本数字。

## 历史设计与验证

以下文件冻结旧阶段，不再作为当前事实源：

- `COWORK_AGENT_ARCHITECTURE.md`
- `COWORK_AGENT_INVOCATION_MODEL.md`
- `COWORK_CURRENT_FINDINGS.md`
- `COWORK_MIGRATION_PLAN.md`
- `COWORK_TASK_CONTEXT_MODEL.md`
- `COWORK_V0_10_SMOKE.md`
- `COWORK_V0_10_STATUS.md`
- `UI_COLOR_SYSTEM.md`
- 根 `design-qa.md`
- `codex-report/`、`claude-report/`、`gemini-report/` 中的 dated reports

历史文档里的版本、测试数量、截图路径和环境结果只能说明当时发生过什么。若它们与
当前源码、工程配置或上方当前规范冲突，以源码/配置和当前规范为准，并记录冲突。

## 维护纪律

- 当前状态文档保持摘要化；完成事项留在 Git 历史和 dated report，不继续无限追加。
- `NEXT_TARGET.md` 只保留一个正在推进的目标，完成后删除或替换。
- `TESTING.md` 保存当前命令和最新证据；旧性能数字或事故细节留在报告中。
- 当前 capability/runtime/toolset 文案必须通过上面的语义门；`scripts/check-version-consistency.sh` 不承担
  这类检查。
- 不批量替换依赖、协议、schema、历史里程碑中的版本号。
- 修改产品版本后必须运行 `scripts/check-version-consistency.sh`。

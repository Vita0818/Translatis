# Translatis 项目常驻上下文

本项目继承 `/Users/vita/Vitemis/AGENTS.md` 中的 Vitemis 通用 Agent 规则。外部依赖选择与接入同时继承 `/Users/vita/Vitemis/docs/DEPENDENCY_POLICY.md`；若本文件与通用规则冲突，在不违反系统和用户指令的前提下，以更具体、更严格的项目规则为准。

本文是 AI Agent 每轮进入 Translatis 仓库时的入口文件。执行任何代码、配置、构建脚本、测试或项目文档修改之前，必须先按顺序阅读并核对：

0. `/Users/vita/Vitemis/AGENTS.md`
1. `docs/CURRENT_STATE.md`
2. `docs/PROJECT_MAP.md`
3. `docs/ARCHITECTURE.md`
4. `docs/DO_NOT_BREAK.md`
5. `docs/TESTING.md`
6. `docs/NEXT_TARGET.md`（如果存在）
7. `docs/AGENTS.md`（在 `docs/` 内工作时）

如果文档与当前源码、工程配置、测试或脚本冲突，必须以当前源码和配置为准，并在最终报告中指出冲突位置和采用源码为准的原因。未知项目事实必须写成 `UNKNOWN` 或“需要后续确认”，不得根据项目名称臆造。

## 工作目录检查

每轮开始先在项目根目录执行：

```sh
pwd
git rev-parse --show-toplevel
git status --short
```

要求：

- `pwd` 与 `git rev-parse --show-toplevel` 都必须是 `/Users/vita/Vitemis/Translatis`。
- Translatis 是位于 `/Users/vita/Vitemis` 父仓库目录下的独立嵌套 Git 仓库；不得把 Translatis 文件误作为父仓库改动处理。
- 如果当前目录不是 Translatis 的 Git root，停止修改并报告路径问题。
- 读取 `git status --short` 后，先区分本项目已有改动与本轮计划改动；不得覆盖、回退、格式化或清理已有改动。

## 修改边界

截至 2026-09-08，本仓库处于新项目接入和文档初始化阶段。当前已确认的项目边界只有：

- 本项目根目录及其自己的 `.git/` 元数据。
- `AGENTS.md`、`CLAUDE.md`、`GEMINI.md` 和 `docs/` 下的治理与项目说明文档。
- Git 远程 `origin` 应指向 `https://github.com/Vita0818/Translatis.git`。

当前没有从源码或工程清单确认的产品 target、模块、入口、数据模型、构建系统、测试框架、运行平台或外部服务接线；这些内容均为 `UNKNOWN`。未来常规任务可按用户明确要求修改业务源码，但在只要求项目自查或文档维护时，只允许修改 `AGENTS.md`、审查入口和 `docs/` 下的项目文档。不得修改 `/Users/vita/Vitemis` 父仓库或其他项目。

## 禁止事项

- 不执行破坏性 Git 操作：`git reset --hard`、`git clean`、`git checkout -- <path>`、`git restore --source`、rebase、强制 push、历史重写或删除用户未提交文件。
- 未经用户在当前任务中明文要求具体 Git 操作，不执行 `add`、`commit`、`push`、`tag`、`branch`、remote 修改或 PR 创建。用户已明确授权的 Git 操作仍只能作用于 Translatis 当前 Git root。
- 若用户要求提交或推送，只暂存、提交和推送 Translatis 当前 Git root 中属于任务范围的文件；不得递归进入父仓库、其他子项目、submodule、nested Git repo 或依赖 checkout。
- 不直接修改 `.git/` 内部文件，不把生成物或未知项目资源冒充源码。
- 不读取、打印、摘要、复制、传输或写入 `.env`、API key、token、密码、cookie、session、私钥、证书、provisioning profile、SSH key、Keychain 内容、账号凭据或无关私人文件。
- 不把尚未从源码、配置或可复现实验确认的技术栈、能力、接口、平台或安全机制写成已实现事实。

## 外部依赖优先与禁止功能兜底

本节是 Vitemis 强制合同，不是建议：

- 当用户指定、仓库已经采用，或经许可证、provenance、安全与平台审查可采用的外部依赖提供同等能力时，必须直接集成该依赖的官方 API 或官方扩展点。
- 不得自行重写同等能力，不得新增替代 adapter、shim、compatibility layer、wrapper、proxy、facade、协议翻译层、parallel backend、preview backend、shadow implementation 或“先兜底、以后再换”的实现。
- 本地代码只允许保留官方 API 必需的最薄生命周期、类型、权限、配置和 bundle 接线；不得重新实现、解释、扩展或替代依赖的核心能力。
- exact 依赖因版本、构建、签名、许可证、平台、安全或官方 API 限制无法接入时，必须停止该能力、明确失败、报告 blocker 并请求用户决定；不得静默降级、切换 legacy、另一 provider/backend、cache、mock、简化路径或不完整替代实现。
- 现有 fallback、adapter 或重复实现不构成先例，后续不得扩展。安全 fail-closed 与明确要求的旧数据解码/迁移不是功能兜底，但必须保持最窄范围。
- 只有用户针对 exact 依赖、exact 范围和退出条件作出的新明文决定才能例外。

在实现任何外部能力前，必须在 `docs/ARCHITECTURE.md` 记录依赖的固定身份或版本、官方能力证据、许可证/来源/安全/平台/分发约束、最薄本地接线边界和依赖不可用时的明确失败行为。`docs/TESTING.md` 必须说明相应失败路径不会调用第二实现或运行时 fallback。

## 项目理解要求

进入任何代码任务前，至少确认：

- 当前源码、工程清单、测试目录、脚本和资源是否已经出现。
- 真实 target / module / 入口、平台、数据格式、外部接口和安全机制；目前这些项目事实均为 `UNKNOWN`。
- `origin` 是否仍为 `https://github.com/Vita0818/Translatis.git`。
- 当前提交、分支、tag 与远程状态；不得把远程状态猜测为已同步。

## 文档索引

- `docs/PROJECT_MAP.md`：目录、target、入口、关键文件和生成物地图。
- `docs/ARCHITECTURE.md`：当前架构结论、主要链路、数据模型、安全边界和外部依赖决策。
- `docs/CURRENT_STATE.md`：当前真实状态、已有能力、未完成项、风险和工作区分类。
- `docs/TESTING.md`：环境、构建、测试、lint/format、手动验证和依赖失败验证方式。
- `docs/DO_NOT_BREAK.md`：Git 边界、数据/协议/路径禁区、不可降级项和回归要求。
- `docs/NEXT_TARGET.md`：仅在存在一个明确临时下一目标时创建；目标完成或不再有效后删除。
- `docs/AGENTS.md`：`docs/` 目录级入口 shim。

## 下一目标

`docs/NEXT_TARGET.md` 只用于记录一个已经明确的临时下一目标。当前没有额外 active target，因此本次初始化不创建空的 `NEXT_TARGET.md`；未来有具体目标时再创建。

## 完成标准

完成任务前至少做到：

- 说明实际阅读或检查过的源码、配置、测试和文档；对空仓库明确说明检查结果。
- 只修改 Translatis 内、且属于用户当前任务范围的文件，保留已有改动。
- 运行与改动相称的检查；纯文档或仓库初始化至少运行 `git diff --check`、`git status --short`，并核对 remote / commit / tag 状态。
- 将本轮完成的持久性项目事实及时回写到相关项目文档；若无需更新文档，最终报告说明原因。
- 如未运行构建或测试，最终报告明确写“未运行构建/测试”及原因。

## 最终报告格式

最终报告建议包含：

1. `MODEL_CHECK_RESULT`：当前模型名称；无法确认时写 `unknown`。
2. `PATH_CHECK_RESULT`：`pwd`、Git root 及是否匹配预期。
3. `FILES_WRITTEN`：新增或修改文件。
4. `PROJECT_AUDIT_SUMMARY`：实际识别到的项目结构、模块和关键链路。
5. `DOCS_CONTENT_SUMMARY`：文档内容摘要。
6. `VALIDATION_RESULT`：实际运行的命令和结果。
7. `UNCERTAINTIES`：无法确认或需要人工确认的内容。
8. `NEXT_RECOMMENDED_ACTION`：下一步建议；不要自动扩展到未授权的业务实现。

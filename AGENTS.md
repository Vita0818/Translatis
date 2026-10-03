# Translatis 项目常驻上下文

Translatis 是独立 Git 仓库 `/Users/vita/Vitemis/Translatis`。本仓库当前以完整
Intatis v0.72 源树为产品基线，并在 Intatis 原生 Skills 机制中加入 Translatis 翻译
Skills。项目继承 `/Users/vita/Vitemis/AGENTS.md` 与
`/Users/vita/Vitemis/docs/DEPENDENCY_POLICY.md`；若规则冲突，以更具体、更严格的本文件
和当前源码为准。

## 每轮入口

在任何源码、配置、构建脚本、测试、Skill 或项目文档修改前，依次阅读并核对：

0. `/Users/vita/Vitemis/AGENTS.md`
1. `docs/VERSIONING.md`（如果存在）
2. `docs/CURRENT_STATE.md`
3. `docs/PROJECT_MAP.md`
4. `docs/ARCHITECTURE.md`
5. `docs/DO_NOT_BREAK.md`
6. `docs/TESTING.md`
7. `docs/OPEN_SOURCE_REUSE.md`（如果存在）
8. `docs/MACOS_DISTRIBUTION.md`（如果存在）
9. `docs/NEXT_TARGET.md`（如果存在）
10. `docs/AGENTS.md`（在 `docs/` 内工作时）
11. 当前任务涉及的 Skill 完整 `SKILL.md` 及其直接引用资源。

源码、工程清单、测试和可复现实验优先于历史报告或设计文档。未知事实写为 `UNKNOWN`
或“需要后续确认”，不得把 Intatis 历史报告中的能力直接当作当前可达能力。

## 工作目录和仓库边界

每轮开始运行：

```sh
pwd
git rev-parse --show-toplevel
git status --short
```

两条路径必须都是 `/Users/vita/Vitemis/Translatis`。本轮只允许修改 Translatis 当前
Git root；不得修改 `/Users/vita/Vitemis` 父仓库、sibling Intatis checkout、其他项目、
submodule 或依赖 checkout。未获得当前任务的明确 Git 操作授权，不执行 add、commit、push、
branch、tag、remote 修改、PR、reset、clean、restore、checkout、rebase 或历史重写。

用户已授权本仓库进行 Intatis 整体基线迁移与翻译 Skill 接入；这不扩大到任何其他仓库。

## 当前产品基线

- Intatis 的 Chat、Code、Cowork、CLI、SwiftPM products、XcodeGen 配置、权限、workspace、
  document/browser tools、Knowledge、EventLog、ArtifactStore、MCP、NOTICE 和测试源树属于
  当前 Translatis 产品基线。
- Code/Cowork/CLI shipping agent kernel 仍是 Intatis 固定的官方 Codex App Server 派生 runtime；
  不复制第二 agent loop、provider adapter、协议 translator 或 fallback backend。
- Intatis 产品固定 runtime、第三方依赖、许可证、source provenance、bundle/release gate 和
  no-fallback 合同继续有效；Translatis 只能通过官方接线和当前产品 Skill 机制扩展任务语义。
- 翻译 Skills 的 workspace 入口是 `.agents/skills/`；Intatis bundled Skills 的产品入口是
  `Packages/IntatisSkills/Resources/BundledSkills/`。Skill 只提供上下文和流程，不授予工具、
  lease、workspace、网络、MCP 或权限能力。
- 当前已安装的翻译 Skills：
  - `translatis-translation-workflow`
  - `translate-cs-ai-pdf-book`

## 迁移边界

Intatis 的源代码和依赖清单是本仓库内产品源码，不是运行时生成物。以下内容不得从 sibling
checkout 复制进来或提交：

- 任一 `.git/` 元数据、nested Git checkout 或 submodule 的工作树内容；
- `.build/`、`.swiftpm/`、`.intatis/`、`.translatis/`、`dist/`、临时目录、Xcode 用户数据和本机 runtime；
- 用户签名规则、证书、Keychain、凭据、`.env`、token、私钥或 account data；
- dated `claude-report/`、`gemini-report/` 或其他副驾驶报告；Codex 工作报告若确有需要只写
  当前仓库 `codex-report/`；
- `OpenSource/` 下的 nested Git submodule checkout。其 gitlink/provenance 只能在用户明确
  授权并完成当前仓库的独立依赖接线时处理；不能把 sibling 工作树冒充为当前源码。

## 外部依赖与禁止兜底

当 exact 外部依赖或 Intatis 官方 API 已提供能力时，直接使用其官方 API/扩展点。不得新增
替代 adapter、shim、wrapper、proxy、facade、协议翻译层、parallel backend、shadow implementation、
第二 parser/writer/provider、cache/mock fallback 或“先做简化版以后再换”的路径。

exact 依赖因版本、构建、签名、许可证、平台、安全或官方 API 限制无法接入时，停止受影响
能力，报告 blocker 并请求用户决定；不得静默切换 provider/backend、旧内核、系统工具或另一
翻译实现。安全 fail-closed 与明确要求的数据迁移保持最窄范围。

## 敏感信息

不得读取、打印、摘要、复制、传输或写入 `.env`、API key、token、password、cookie、session、
私钥、证书、provisioning profile、SSH key、Keychain 内容、账号凭据或无关私人文件。

翻译 Skill 不得把原始 secret-bearing 文档、credential、private bookmark 或 provider diagnostic
写入 Skill、README、EventLog 摘要、报告或测试 fixture。

## 完成标准

- 只修改 Translatis 当前仓库且属于本任务范围的文件；保留无关用户改动。
- 说明实际阅读、复制或修改过的源码、配置、Skills、测试和文档。
- 运行与改动相称的检查；至少运行 `git diff --check`、路径/Git 状态检查以及 Skill validator。
- 若未运行构建或测试，最终报告明确写出原因。
- Intatis runtime、document runtime、provider、MCP、Skill discovery 或发布能力的状态必须
  以当前可复现实验和 bundle inventory 为准，不能仅根据源码存在来宣称可运行。

## 最终报告字段

最终回复包含：

1. `MODEL_CHECK_RESULT`
2. `PATH_CHECK_RESULT`
3. `FILES_WRITTEN`
4. `PROJECT_AUDIT_SUMMARY`
5. `DOCS_CONTENT_SUMMARY`
6. `VALIDATION_RESULT`
7. `UNCERTAINTIES`
8. `NEXT_RECOMMENDED_ACTION`

# docs/AGENTS.md

本文是 Translatis `docs/` 目录级 Codex 入口 shim。项目事实和项目专属要求应写在项目根 `AGENTS.md` 以及项目内文档中。

开始在 `docs/` 内工作前必须先读：

1. `/Users/vita/Vitemis/AGENTS.md`
2. `../AGENTS.md`
3. 与当前任务相关的 `docs/` 文档。

基本规则：

- Codex 是主工作者，只能按用户任务和 Translatis 项目边界修改文档。
- 已完成的持久性改动必须及时回写到相关项目文档；若无需更新文档，最终报告说明原因。
- `docs/NEXT_TARGET.md` 只在存在一个明确的 active target 时保留；目标完成或不再有效后删除。
- Git 版本控制默认只读；只有用户当前任务明文要求具体 Git 操作时，Codex 才能按要求操作，而且只能操作 Translatis 当前 Git root，不得涉及父仓库或其他嵌套仓库。
- 不得读取、打印、摘要或写入密钥、token、证书、Keychain、`.env` 等敏感信息。
- 未知事实统一写成 `UNKNOWN` 或“需要后续确认”，不要用模板占位符冒充项目结论。

## 外部依赖优先与禁止兜底

本目录文档继承 `/Users/vita/Vitemis/docs/DEPENDENCY_POLICY.md`。当外部依赖已经提供同等能力时，项目必须记录并直接使用其官方 API 或官方扩展点；不得在文档或实现方案中引入第一方重写、替代 adapter、shim、wrapper、proxy、facade、parallel backend、preview backend、shadow implementation 或运行时 fallback。exact 依赖无法接入时，文档必须记录明确 blocker、停止受影响能力并请求用户决定。

## 报告要求

Codex 报告只能写入 `../codex-report/`，文件名采用 `MM_DD_YY-HH_MM-xxxx.md`。报告正文先写 `MODEL_CHECK_RESULT`，并包含路径、文件、摘要、验证、`UNCERTAINTIES` 和下一步建议。不得为了写报告修改本目录以外的项目文件。

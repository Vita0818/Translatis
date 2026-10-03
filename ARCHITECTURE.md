# Translatis Architecture

当前产品基线：v0.72（build 72）

此根文件只保留兼容入口。Translatis 复用共享 Intatis 源树与官方 Codex Runtime；早期 draft-0 架构在 v0.1–v0.3 阶段编写，已经不能描述当前
AgentKernel、durable permission、MCP、Skills、managed terminal、per-agent inference、
AppSessionRuntimeManager 和 iOS 产品边界。

当前架构正文唯一维护在 [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)。同时参阅：

- [`docs/PROJECT_MAP.md`](docs/PROJECT_MAP.md)：target、入口和关键文件；
- [`docs/DO_NOT_BREAK.md`](docs/DO_NOT_BREAK.md)：不可破坏的协议与安全合同；
- [`docs/COWORK_PRINCIPLES.md`](docs/COWORK_PRINCIPLES.md)：多 agent 编排原则；
- [`docs/VERSIONING.md`](docs/VERSIONING.md)：产品版本事实源。

旧 draft 的完整内容仍保留在 Git 历史中，不得再作为当前实现依据。

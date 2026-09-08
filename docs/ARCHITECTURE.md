# ARCHITECTURE

最近自查日期：2026-09-08

## 总体架构

当前没有产品源码或工程清单，因此不存在已确认的产品架构。现阶段只能确认仓库治理层：

```text
Translatis Git root
├── Agent / reviewer entrypoints
│   ├── AGENTS.md
│   ├── CLAUDE.md
│   └── GEMINI.md
└── Project documentation
    └── docs/
        ├── CURRENT_STATE.md
        ├── PROJECT_MAP.md
        ├── ARCHITECTURE.md
        ├── DO_NOT_BREAK.md
        └── TESTING.md
```

产品层的用户输入、业务模块、持久化、UI、外部服务和运行时入口均为 `UNKNOWN`。后续不得把上述治理层误认为产品运行时。

## 主要链路

- **仓库治理链路**：Agent 进入 Translatis → 读取 `/Users/vita/Vitemis/AGENTS.md` 与项目文档 → 执行项目根路径和 Git 状态检查 → 仅在任务范围内修改 Translatis → 按用户明文授权执行 Git 操作。
- **产品业务链路**：`UNKNOWN`。当前没有可确认的入口、核心类型、业务处理、持久化或外部调用。

任何未来新增的业务链路都必须从实际源码、工程配置和测试中确认起点、关键模块、终点、失败行为和安全约束后再写入本文。

## 数据模型

| 类型 | 职责 | 持久化方式 | 关键字段约束 |
|---|---|---|---|
| 产品领域对象 | UNKNOWN | UNKNOWN | UNKNOWN；当前不存在源码证据 |
| 项目治理文档 | 记录 Agent、架构、状态、测试和禁区 | Git 文件 | 文件名和内容应与实际仓库状态一致，不存储 secret |

## 同步 / 通信机制

产品同步、IPC、网络协议、消息总线和跨端通信均为 `UNKNOWN`。当前唯一确认的外部连接是 Git 的 `origin`，其地址为 `https://github.com/Vita0818/Translatis.git`；该连接属于版本控制基础设施，不是产品通信协议。

## 安全机制

- **仓库边界**：Translatis 是独立嵌套 Git 仓库；不得越过 `/Users/vita/Vitemis/Translatis` 修改或提交父仓库及其他项目。
- **敏感信息**：项目文档和提交不得包含 `.env`、token、密码、cookie、session、私钥、证书或其他凭据。
- **Git 历史**：不使用破坏性 reset、clean、历史重写或强制 push；远程冲突必须显式报告。
- **产品安全**：认证、授权、加密、Keychain、沙箱、权限和数据保护机制均为 `UNKNOWN`，不得编造已实现的安全保证。

## 模式开关 / 内核切换

当前不存在已确认的新旧内核、模式开关、渐进式迁移或回切路径。若未来引入，必须记录模式枚举、默认模式、行为边界和显式失败策略；不得用备用内核或隐式 fallback 掩盖主依赖失败。

## 与文档/源码的关系

- 已确认事实：来自本次对空项目目录、独立 `.git` 初始化结果、Git root、状态和 remote 的检查。
- 规范来源：`/Users/vita/Vitemis/AGENTS.md` 与 `/Users/vita/Vitemis/docs/DEPENDENCY_POLICY.md`。
- 推断 / 未知：产品技术栈、target、运行链路、数据模型、协议和安全实现均未由源码确认，统一标为 `UNKNOWN`。
- 冲突处理：如果后续文档与源码、配置或测试冲突，以源码和可复现验证为准，并记录修正。

## 外部依赖决策与禁止兜底

- 当前没有已选外部依赖，也没有需要接入的产品外部能力；因此不存在可声明为已采用的 provider、版本或官方 API。
- 未来只要某个用户指定、已采用或经许可证、来源、安全与平台审查批准的外部依赖提供所需能力，就必须直接使用该依赖的官方 API 或官方扩展点。
- 架构中不得并存第一方重写、替代 adapter、shim、compatibility layer、wrapper、proxy、facade、协议翻译层、parallel backend、preview backend、shadow implementation 或运行时 fallback。
- 本地实现只能是官方 API 所需的最薄生命周期、类型、权限、配置和 bundle 接线，不得复制或重新解释依赖核心逻辑。
- exact 依赖无法因版本、构建、签名、许可证、平台、安全或官方 API 限制接入时，必须将受影响能力标为 blocked，明确失败并请求用户决定；不得静默切换 legacy、另一 provider/backend、cache、mock、简化实现或不完整路径。
- 安全 fail-closed 和明确要求的数据迁移必须与产品能力分开记录，且不能演化成备用产品实现。

# DO_NOT_BREAK

本文列出 Translatis 当前不可破坏的工程禁区、数据格式、协议、路径和回归要求。修改前必须确认不违反下列任一条目。

## 工程禁区

- 不执行 `git reset --hard`、`git clean`、`git checkout -- <path>`、`git restore --source`、rebase、强制 push、历史重写或删除未提交文件。
- 未经用户在当前任务中明文要求具体 Git 操作，不执行 add、commit、push、tag、branch、remote 修改或 PR 创建。
- 用户要求 Git 操作时，只能操作 `/Users/vita/Vitemis/Translatis` 当前 Git root 中与任务相关的文件；不得暂存、提交或推送父仓库、其他项目、submodule、nested Git repo 或依赖 checkout。
- 不直接修改 `.git/` 内部文件。
- 未经用户明确要求，不引入依赖、不改构建脚本、不改测试源码、不创建发布工程；当前这些边界均为 `UNKNOWN`。
- 不绕过尚未确认的安全机制；未来新增安全检查必须 fail-closed，不能以功能 fallback 代替。

## 外部依赖与禁止兜底禁区

- 当外部依赖已经提供同等能力时，必须直接使用其官方 API/扩展点；不得自行重写，也不得新增替代 adapter、shim、compatibility layer、wrapper、proxy、facade、协议翻译层、parallel backend、preview backend、shadow implementation 或临时 fallback。
- exact 依赖不可用或不兼容时必须明确失败并停止该能力；不得静默切换 legacy、另一 provider/backend、缓存、mock、简化实现或不完整路径。
- 本地代码只能是官方 API 必需的最薄生命周期、类型、权限、配置和 bundle 接线，不能复制或重新解释依赖核心行为。
- 现有 fallback 或重复实现不得扩张。安全 fail-closed 与明确要求的旧数据解码/迁移必须保持最窄范围，不能成为备用产品实现。

## 数据格式禁区

- 持久化文件格式：`UNKNOWN`；当前没有产品数据文件。
- 配置文件格式：`UNKNOWN`；当前没有项目配置或 manifest。
- 跨端/跨进程报文格式：`UNKNOWN`；当前没有产品通信协议。
- 资源/资源包格式：`UNKNOWN`；当前没有产品资源目录。

未来任何 schema、编码、单位、字段顺序或版本变更都必须先确认真实消费者、迁移策略和回归验证，不能只依据文档猜测。

## 协议禁区

- 产品通信协议：`UNKNOWN`。
- 同步协议：`UNKNOWN`。
- 迁移协议：`UNKNOWN`。
- Git 远程地址契约：`origin` 应保持为 `https://github.com/Vita0818/Translatis.git`，除非用户明确要求更换并提供新的 exact 地址。

## 路径禁区

- Translatis 当前 Git root：`/Users/vita/Vitemis/Translatis`。
- 父工作区 `/Users/vita/Vitemis` 及其其他项目不属于本仓库提交范围。
- 项目文档：`/Users/vita/Vitemis/Translatis/docs/`。
- Agent 报告（如需要）：`/Users/vita/Vitemis/Translatis/codex-report/`，不得写入其他审查副驾驶报告目录。
- 构建产物、缓存、DerivedData、依赖 checkout 和发布产物路径：`UNKNOWN`，在真实工程出现前不得创建或提交。

## 回归要求

- 每轮工作前，`pwd` 与 `git rev-parse --show-toplevel` 必须都指向 Translatis Git root。
- 文档必须区分已验证事实、设计意图和 `UNKNOWN`；不得把空仓库描述为已实现产品。
- 父仓库及其他项目既有改动必须保持原样，不能因 Translatis 的提交或推送而被纳入。
- dependency-first / no-fallback 规则必须同时保留在项目入口、架构、禁区和测试文档中。

## 不可降级项

- 不得用任何替代实现掩盖未来 exact 依赖的缺失或不兼容。
- 不得把 mock、缓存、legacy 路径或简化路径当作产品能力的运行时后备实现。
- 不得为了推送成功而强制覆盖远程历史或修改远程之外的仓库状态。

## 验证要求

- 文档或仓库初始化：`git diff --check`、`git status --short`。
- 路径边界：`pwd`、`git rev-parse --show-toplevel`。
- remote：`git remote -v`；需要确认远程 refs 时使用非破坏性的 `git ls-remote origin`。
- 提交 / tag / 推送：使用 `git log`、`git show`、`git tag --list` 和 `git ls-remote` 复核，不使用强制 push。
- 产品构建和测试：`UNKNOWN`；待工程清单和测试入口出现后补充精确命令。

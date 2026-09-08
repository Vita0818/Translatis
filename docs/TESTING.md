# TESTING

最近自查日期：2026-09-08

## 环境

- 操作系统 / 平台：当前工作区运行环境可确认是 macOS；Translatis 产品目标平台为 `UNKNOWN`。
- 工具链版本：`UNKNOWN`；当前没有语言或工程清单。
- 依赖管理：`UNKNOWN`；当前没有 manifest 或 lockfile。
- 凭据 / 配置：产品凭据配置为 `UNKNOWN`。文档、测试和命令输出不得读取或保存真实 secret；GitHub 推送使用现有安全认证环境，不在项目文件中记录凭据。

## 构建

当前没有可执行构建命令：

```sh
UNKNOWN  # 尚未发现 Package.swift、xcodeproj、package.json、pyproject.toml 或其他构建清单
```

- 配置：`UNKNOWN`
- 目标：`UNKNOWN`
- 产物位置：`UNKNOWN`

产品源码和工程清单出现后，必须以真实配置为依据补充精确构建命令、目标、平台和产物路径。

## 测试

当前没有可执行测试命令：

```sh
UNKNOWN  # 尚未发现测试框架、测试目录或测试入口
```

- 单元测试：`UNKNOWN`
- UI 测试：`UNKNOWN`
- 集成测试：`UNKNOWN`
- 只跑特定测试：`UNKNOWN`

本次文档初始化不运行构建或产品测试，因为仓库没有产品代码和测试入口。

## Lint / Format

当前没有已确认的 lint 或 format 工具：

```sh
UNKNOWN
UNKNOWN
```

文档初始化使用 Git 的格式检查作为最小验证，不引入新的格式化工具或依赖。

## 手动验证矩阵

| 场景 | 步骤 | 预期 | 状态 |
|---|---|---|---|
| 项目路径边界 | 在 Translatis 根目录运行 `pwd` 和 `git rev-parse --show-toplevel` | 两者均为 `/Users/vita/Vitemis/Translatis` | 本次验证 |
| 工作区范围 | 运行 `git status --short`，并与父仓库状态分开检查 | 只识别 Translatis 当前文件；不触碰父仓库改动 | 本次验证 |
| 文档格式 | 运行 `git diff --check` | 无空白错误或 patch 格式错误 | 本次验证 |
| 远程连接 | 运行 `git remote -v`，必要时运行 `git ls-remote origin` | `origin` 指向用户指定 URL；远程 refs 状态以命令结果为准 | 本次任务验证 |
| 首个发布基线 | 运行 `git log`、`git tag --list` 和 `git ls-remote --tags origin` | 本地与远程可见用户请求的 `v0.0` tag | 本次任务验证 |
| 产品运行 | 等待源码、入口和测试出现后按项目命令运行 | 以真实需求定义预期 | 未开始 |

## 验证边界声明

- 本次是文档与仓库初始化任务；实际验证重点是路径、Git root、文档格式、remote、commit、tag 和 push。
- 当前没有源码、构建 manifest 或测试框架，因此**未运行构建/测试**。
- 父仓库 `/Users/vita/Vitemis` 的既有改动不在本次验证或提交范围内。

## 外部依赖与禁止兜底验证

- 未来 exact 外部依赖可用时，只调用其官方 API/扩展点，不调用第一方重复实现。
- 依赖缺失、版本不兼容、构建/签名/许可证/平台/安全条件不成立时，必须产生明确、可诊断失败并停止受影响能力。
- 失败路径不得切换到 legacy、另一 provider/backend、adapter/shim、cache、mock、简化实现或不完整路径。
- test double 只能存在于测试 target，不得进入 production selection 或 runtime fallback。
- Review 必须检查新增 wrapper/adapter/facade 是否只是官方 API 必需的最薄接线；任何核心能力复制都必须拒绝。

## 常见问题

- 如果未来发现产品源码或 manifest 与本文件的 `UNKNOWN` 不一致，应以当前源码和配置为准，更新 `PROJECT_MAP.md`、`CURRENT_STATE.md` 和本文件，并在报告中说明证据。
- 如果远程已有不可快进历史，不能使用强制 push；应报告远程冲突并等待用户决定合并或其他明确策略。

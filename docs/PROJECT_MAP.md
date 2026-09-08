# PROJECT_MAP

最近自查日期：2026-09-08

本文描述 Translatis 当前仓库结构。依据为初始化时对项目根目录的只读检查：目录在文档初始化前为空，未发现源码、工程清单、测试文件、脚本或资源；本次任务新增了项目治理入口和 `docs/` 文档。

## 目录结构总览

```text
Translatis/
├── AGENTS.md             # Codex 项目入口与项目边界
├── CLAUDE.md             # Claude 只读审查入口
├── GEMINI.md             # Gemini 只读审查入口
└── docs/
    ├── AGENTS.md         # docs 目录级入口 shim
    ├── ARCHITECTURE.md   # 架构与外部依赖决策记录
    ├── CURRENT_STATE.md  # 当前真实状态与风险
    ├── DO_NOT_BREAK.md   # 禁区、契约与回归要求
    ├── PROJECT_MAP.md    # 本目录地图
    └── TESTING.md        # 构建、测试与验证边界
```

`.git/` 是 Translatis 自己的 Git 元数据，不属于业务源码；不得直接修改其内部文件。父目录 `/Users/vita/Vitemis` 是另一个 Git 仓库，不能纳入 Translatis 的提交或推送。

## Target / 模块

| Target / 模块 | 类型 | 平台 | 入口 | 职责 |
|---|---|---|---|---|
| Translatis 产品 target | UNKNOWN | UNKNOWN | UNKNOWN | 当前没有源码或工程清单，待项目范围确认 |
| 项目治理文档 | 文档 | 与宿主无关 | `AGENTS.md` / `docs/` | 记录 Agent 边界、项目事实、架构、禁区和验证合同 |

## 关键文件

- 入口：`AGENTS.md`；产品入口为 `UNKNOWN`。
- 核心链路：UNKNOWN；当前没有可确认的业务源码链路。
- 配置：UNKNOWN；当前没有发现项目配置或 manifest。
- 测试：UNKNOWN；当前没有发现测试目录或测试入口。
- 远程：Git `origin` 应为 `https://github.com/Vita0818/Translatis.git`。

## 生成物 / 产物

- 构建产物：UNKNOWN；尚未发现构建系统或构建命令。
- 脚本生成物：UNKNOWN；尚未发现脚本。
- 报告：如后续按规则生成 Codex 审查或工作报告，应写入 `codex-report/`；该目录不属于当前文档初始化内容。

## 脚本与工具

当前没有发现 `Scripts/` 或等价脚本目录。工具链、依赖管理器、构建工具和发布工具均为 `UNKNOWN`。

## 当前边界与不确定项

- 产品名称虽为 Translatis，但产品目标、用户流程、技术栈、目标平台、模块拆分、数据格式、外部接口和安全机制均需要后续确认。
- 没有依据把空仓库解释为某一种语言、框架或应用类型。
- 新增文档只建立治理基线，不表示任何产品功能已经实现。

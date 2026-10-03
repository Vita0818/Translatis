# TRANSLATIS_BASELINE

文档状态：Translatis 当前迁移增量
最近核对：2026-09-08

## 基线

Translatis 当前仓库已接入 Intatis v0.72（build 72）的可复现源树基线，包括 SwiftPM
products、macOS/iOS/CLI 源码、XcodeGen 配置、测试、第三方声明、固定 Codex patches、Vendor
源码、文档 runtime release specifications 和验证脚本。

迁移来源是 sibling checkout `/Users/vita/Vitemis/Intatis` 的当前 Git `HEAD`，迁移使用其
tracked source tree；没有复制 sibling 的 `.git/`、`.build/`、`.swiftpm/`、`.intatis/`、`.translatis/`、`dist/`、
临时状态、Xcode 用户数据、dated reviewer reports 或 nested `OpenSource/` submodule checkout。

Translatis 自己仍是独立 Git root。迁移不修改 sibling Intatis、父仓库或任何 submodule。

## 宿主命名迁移

产品层已经从 Intatis 的活动命名空间切换为 Translatis：

- XcodeGen 工程、macOS/iOS targets、CLI executable、Bundle ID、App/CLI 入口路径和 macOS release
  artifacts 使用 Translatis 命名；产品控制的环境变量使用 `TRANSLATIS_*`，活动隐藏目录为
  `.translatis`。
- 三个入口在创建共享对象前安装一次 `IntatisHostApplication.configure(name: "Translatis")`，由共享
  `IntatisHostApplicationIdentity` 统一派生 config、UserDefaults、Keychain、诊断、Knowledge、MCP、
  workspace 和 runtime cache 命名，避免手写第二套 namespace 替换表。
- `Packages/Intatis*`、`IntatisCodexRuntime` 及固定 Codex 版本/字段仍保持 Intatis 身份；这是共享实现和
  外部协议合同，不是产品活动路径。旧 `.intatis*` 与 `INTATIS_*` 只作为 legacy/deny floor 保留。

## Skills

翻译 Skills 同时安装到两个 Intatis 支持的发现面：

- workspace Skills：`.agents/skills/`
- bundled product Skills：`Packages/IntatisSkills/Resources/BundledSkills/`

当前 Skills：

- `translatis-translation-workflow`：基于 Intatis exact document tools、Knowledge、workspace
  lease、permission 和 EventLog 的通用翻译流程；不增加第二 provider/parser/writer/agent loop。
- `translate-cs-ai-pdf-book`：针对 text-bearing CS/AI/ML/EE/数学技术书籍 PDF 的逐页翻译、公式/代码/图表
  保真、可搜索 PDF 生产和覆盖率/QA 流程。

Skill 只提供上下文与流程，不能授予工具、网络、MCP、workspace、lease、权限或 provider 能力。
新建或修改 Skill 后，Intatis 会在下一次 Code/Cowork invocation 冻结新 snapshot；Skill 可见性
不代表对应 document runtime、provider 或发布 bundle 已经可运行。

## 验证边界

本轮已运行 workspace 与 bundled 两份 Skill 副本的 `quick_validate.py`，四次均通过；SwiftPM
`dump-package` 解析成功（18 products、40 targets）；`swift build --product translatis
--disable-automatic-resolution` 通过；新增 `TranslatisRuntimeIntegrationTests` 2/2 通过。
`xcodegen generate`、XcodeGen target/scheme 清单、`TranslatisMac` macOS Debug unsigned build
（`ENABLE_DEBUG_DYLIB=NO`）和 `TranslatisiOS` generic Simulator Debug unsigned build 均通过。
尚未运行完整 SwiftPM、Developer ID 正式签名/公证、真实 provider 或 document/browser runtime
smoke；这些状态必须继续以 `docs/TESTING.md` 和实际 bundle inventory 为准。

## 后续迁移约束

- 保持 Intatis 官方 Codex App Server、document runtime、Knowledge、permission、workspace、EventLog
  和 no-fallback 合同。
- 不通过翻译 Skill 引入模型、parser、writer、provider 或权限的第二实现。
- `OpenSource/` 的 gitlink 依赖不在本轮复制范围内；若未来需要在 Translatis 初始化 submodule，必须
  作为独立、明确授权的 Git/依赖任务处理。

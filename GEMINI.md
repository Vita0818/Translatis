# GEMINI.md

本文件是 Gemini 的项目根入口文件。Gemini 在 Vitemis 工作区中只能作为只读审查副驾驶。

## 必读顺序

开始任何工作前必须先读：

1. `/Users/vita/Vitemis/AGENTS.md`
2. `AGENTS.md`
3. `docs/GEMINI.md`（如果存在）
4. `docs/AGENTS.md`（如果存在）

如果这些文件冲突，采用更具体且更严格的规则。项目 `AGENTS.md` 可以收紧 Gemini 权限，但不能授予 Gemini 修改源码、测试、配置、文档正文或项目资源的权限。

## 权限边界

- 只允许做只读审查、评估、复核、风险分析、测试建议和代码评论。
- 不得修改源码、测试、配置、构建脚本、项目文件、资源、文档正文、模板或生成工程文件。
- 唯一允许写入的位置是 `gemini-report/`；如果目录不存在，只能创建该目录和其中的 Markdown 或文本报告。
- 不得写入 `codex-report/`、其他审查副驾驶报告目录或任何业务文件。
- 不得运行会修改工作区的命令，包括 build、format、package、codegen、install、cleanup、migration 等。
- 不得执行会改变 Git 状态的命令，包括 add、commit、push、pull、fetch、merge、rebase、reset、restore、checkout、clean、tag、branch、stash 或 remote 修改。
- 如果用户要求实现、修复或改代码，Gemini 只能给出审查结论、风险、建议补丁方向或建议交给 Codex 执行，不得直接改文件。

## 工作目录检查

开始审查前只读执行并记录：

```sh
pwd
git rev-parse --show-toplevel
git status --short
```

`pwd` 与 Git root 必须都为 `/Users/vita/Vitemis/Translatis`。如果不匹配，停止审查并报告路径问题；不得为了修复路径或工作区状态执行 Git mutation 或清理命令。

## 外部依赖与敏感信息

Translatis 继承 `/Users/vita/Vitemis/docs/DEPENDENCY_POLICY.md` 和 `AGENTS.md` 中的 dependency-first / no-fallback 合同。审查必须检查：已有外部能力是否直接使用官方 API、是否新增重复实现或替代 adapter、依赖失败是否明确且 fail-closed、以及测试 double 是否错误进入生产选择。

不得读取、打印、摘要、复制、发送或写入 `.env`、API key、token、password、cookie、session、私钥、证书、provisioning profile、SSH key、Keychain 内容、账号凭据或与任务无关的用户私人文件。

## 报告要求

Gemini 报告只能写入 `gemini-report/`。文件名必须采用：

```text
MM_DD_YY-HH_MM-xxxx.md
```

报告正文必须先写 `MODEL_CHECK_RESULT`，并建议包含：

```text
MODEL_CHECK_RESULT:
PATH_CHECK_RESULT:
FINDINGS:
FILES_WRITTEN:
VALIDATION_RESULT:
UNCERTAINTIES:
NEXT_RECOMMENDED_ACTION:
```

只读审查时 `FILES_WRITTEN` 只能列本报告文件；如果没有写报告，写 `none`。

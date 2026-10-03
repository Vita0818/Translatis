# VERSIONING

文档状态：当前版本规则
最近核对：2026-09-08
产品版本：`0.72`
构建号：`72`

## 唯一事实源

Translatis 的产品版本由根目录 `project.yml` 的两项全局设置唯一决定：

- `MARKETING_VERSION`：用户可见的产品版本；
- `CURRENT_PROJECT_VERSION`：单调递增的构建号。

XcodeGen 生成的工程、macOS/iOS App 的最终 `Info.plist`、诊断导出和发行文件名都必须
从这两个值派生。`Apps/TranslatisMac/Info.plist` 与 `Apps/TranslatisiOS/Info.plist` 当前不是
XcodeGen shipping target 的输入，但作为仓库参考文件也必须保持相同值，避免搜索和人工
检查得到冲突答案。

Git commit 标题中的 `v0.x` 只记录里程碑，不是版本事实源；仓库当前没有 Git tag。
历史设计文档中的 v0.10、v0.12、v0.16 等表示当时引入能力或冻结证据的版本，不应批量
改写成当前版本，也不能用来推断构建产物版本。

## 当前基线

当前工作树的产品基线为 `v0.72`。工程元数据此前已从长期停留的 `0.12 (1)` 校准为
`0.32 (32)`，后续推进为 `0.36 (36)`、`0.38 (38)`、`0.40 (40)`、`0.48 (48)`、`0.55 (55)`、
`0.66 (66)`、`0.69 (69)`、`0.70 (70)`、`0.71 (71)`，本轮进一步推进为 `0.72 (72)`。构建号继续保持单调增加，但不要求永远
等于 marketing version 的 minor。

## 更新步骤

每次版本变化必须作为同一个改动完成：

1. 修改 `project.yml` 中的 `MARKETING_VERSION` 与 `CURRENT_PROJECT_VERSION`；
2. 同步两个仓库参考 `Info.plist`；
3. 更新 `README.md`、`docs/README.md`、`docs/CURRENT_STATE.md` 和
   `docs/PROJECT_MAP.md` 的当前基线；
4. 运行 `xcodegen generate`；
5. 运行 `scripts/check-version-consistency.sh`；
6. 构建 macOS/iOS shipping target，并从最终 App bundle 读取
   `CFBundleShortVersionString` / `CFBundleVersion`；
7. 直分发时只允许 `scripts/package-macos-release.sh` 使用最终 bundle 元数据命名产物。

不得只修改提交标题、README 或发行文件名，也不得在打包命令行临时覆盖版本而不回写
`project.yml`。历史报告、供应链版本和协议 schema 版本不随产品版本批量替换。

`make version` 可单独运行同一检查；`make build`、`make test`、`make release` 与 `make app`
也已接入版本门，避免常规工作流继续携带彼此冲突的版本元数据。

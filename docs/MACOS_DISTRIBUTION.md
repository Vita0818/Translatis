# macOS 分发与沙箱边界

文档状态：当前发行合同
生效日期：2026-07-28
最近核对：2026-09-08
产品基线：v0.72（build 72）

## 产品决策

Translatis 的 macOS 产品只通过 Developer ID 签名、公证和直接下载分发。项目不再
规划、发布或验收 Mac App Store 版本，也不再把 Mac App Store 的 App Sandbox
限制作为产品设计、功能裁剪、依赖选择或测试矩阵的约束。

用户已于 2026-08-21 明确要求删除旧 Mac App Store target。当前源码和 XcodeGen
工程定义已不再包含 `TranslatisMacAppStore` target/scheme、`TRANSLATIS_MAC_APP_STORE`
编译条件或 `TranslatisMac.AppStore.entitlements`。`.macAppStore` profile 只在共享协议
解码和隔离测试中保留兼容语义，不对应可构建 App，也不得据此恢复第二个产品图。
历史测试记录继续按发生时事实保留，不改写为当前构建能力。
仓库根 `README.md` 和旧 `codex-report/` 中若仍有“双 macOS 构建”或 App Store
规划文字，均被本文件和 `docs/CURRENT_STATE.md` 的新决策取代，只能作为历史
背景读取。

## 当前 macOS 产品面

- 唯一发行 App target：`TranslatisMac`。
- 分发方式：Developer ID 签名、公证、直接下载或用户自建。
- 产品源码面：完整 Chat UI 与 Codex Runtime-backed Code/Cowork workspace shell。Code/Cowork通过
  App Server官方experimental `dynamicTools`接入Intatis既有business-tool registry；Cowork的verified
  MultiAgent V2 descendants在所有fork模式继承同一注册工具面，但每次调用仍按exact agent/profile/
  workspace独立授权。native Skills与Code/Cowork exact root的Streamable HTTP MCP已经走Codex官方扩展点；
  per-child MCP、native OAuth/elicitation与无法精确表达的stdio authority仍保持fail closed，不能走旧内核。
  当前本机v0.72预览没有三套bundled runtime，因此本条描述源码产品面，不等于当前安装包可独立运行
  Code/Cowork或全部文档/浏览器工具。
- `IntatisCoworkUI`是源码级presentation-only library，TranslatisMac仍由App层拥有Cowork runtime/session；
  该product不创建第二个App或独立发行制品，也不改变Codex nested-binary签名顺序。
- 默认 macOS 验收：SwiftPM/CLI、`TranslatisMac` Developer ID 产品图，以及与改动
  相关的签名、公证、Hardened Runtime、entitlements 和 bundle/link inventory。
- 生成的 Xcode 工程不得重新出现 `TranslatisMacAppStore` target 或 scheme。

iOS 当前仍是独立的 chat 子集。本决策不自动删除或扩大 iOS 产品面，也不改变
iOS 自身的系统 sandbox 与 target-linkage 限制。

## Codex Runtime auxiliary executable gate

当前OpenAI Codex App Server external runtime固定基于source commit
`25af12f7e61572b0bc18ddb1008be543b91519b0`，按序应用仓内0001 provider-body、0002 strict
OpenRouter request-shape与0003 Cowork subagent reconnection补丁，exact版本为
`codex-cli 0.145.0-intatis.4`。0003让所有fork模式的child继承App Server `dynamicTools`，只允许选择
host预设的absolute cwd/exact roots/读写sandbox workspace ID，以显式`flat_tools=true`让OpenRouter等
route继续接收顶层普通V2协作/业务function，并以ancestry-checked `thread/subagent/message`直接进入
Codex `AgentControl` mailbox。

2026-08-24已从独立源码/target目录clean build当前patch的thin arm64 release-profile validation
binary，SHA-256为`880dbbbd97ad3077a54296940c0c219a33ac153979126be7129a8998a4ff5685`；0003 patch
SHA-256为`9cd57fc61366cb7410f6e551aa48ec762094e9a4edbfcbf0ae4670b7ba1f2285`，binary自报并由
Swift host核对同一derivation ID。同一exact binary已安装为本机Translatis专用
`~/.local/bin/translatis-codex`；原same-version/different-derivation文件SHA-256
`61350e40759975bb4ae3669ddbbb73b1d25c4beddb34f2233abde7f7196cbde3`以分名备份保留。旧`.3`与official
`codex-cli 0.145.0`同样未改。普通Xcode build与当前本机 `TranslatisMac` 预览仍未把validation binary复制进
App bundle；`project.yml`也不把runtime作为普通resource输入。正式打包脚本已经实现显式的
`TRANSLATIS_CODEX_RUNTIME_ARM64_ROOT` / `TRANSLATIS_CODEX_RUNTIME_X86_64_ROOT` staging与前后validator，目标位置是
`Contents/Resources/CodexRuntime/{arm64|x86_64}/codex`；当前阻塞点是尚未提供并闭环验证两份发行root，
不是打包脚本缺少复制入口。该发行工作按用户决定后续处理，不影响已完成的子代理源码功能验收。

正式恢复 `scripts/package-macos-release.sh` 输出前仍必须完成并验证：

1. fixed source/Cargo.lock + checked-in patch set的独立可复现arm64+x86_64 build与每架构hash；现有
   local arm64 hash只是单机证据，不能替代x86_64或reproducibility gate；
2. exact Rust dependency closure的全部license/NOTICE，包含upstream Ratatui-derived attribution；
3. architecture-correct nested `Contents/Resources/CodexRuntime/{arm64|x86_64}/codex`与final bundle inventory；
4. nested executable先以同一Developer ID team签名并启用适用Hardened Runtime，再签outer App；
5. outer App和DMG的notarization/staple/Gatekeeper后，在无用户预装Codex、无`~/.codex`登录的fresh
   account中验证Translatis isolated CODEX_HOME、custom Responses provider与`codex --version`；
6. update/rollback必须以整个已签名App版本为单位，不能从PATH悄悄切到另一Codex版本。

任一门槛缺失必须阻断release；不得把external开发依赖静默当成用户先决条件，也不得bundle未审计
单架构binary、关闭library validation、放宽entitlements或回退旧AgentLoop。

开发预览不是正式release，但只要交给用户运行，也必须显式使用`ENABLE_DEBUG_DYLIB=NO`，确认
`Contents/MacOS`只有主可执行文件且`otool -L`无`TranslatisMac.debug.dylib`引用，再按现有Developer ID
entitlements做ad-hoc Hardened Runtime签名并从最终交付路径真实启动。Xcode 27默认Debug launcher即使
通过deep/strict codesign，仍可能因主程序与debug dylib的non-platform Team ID不一致被DYLD拒绝；不得
通过关闭library validation规避。

2026-09-04本机安装的v0.72预览按上述路径使用universal Release、`ENABLE_DEBUG_DYLIB=NO`和ad-hoc
Hardened Runtime签名；strict codesign、entitlements、staging/installed一致性、无quarantine及exact安装
路径启动均通过。该App仍不含`CodexRuntime`、`DocumentRuntime`或`BrowserRuntime`目录，因此只证明主App/
Chat壳，不证明Code/Cowork或固定文档/浏览器能力可独立运行，也不是Developer ID公证发行物。被替换的
v0.71 App保留在废纸篓中的时间戳备份。

2026-08-31本机安装的v0.71预览按上述路径使用universal Release、`ENABLE_DEBUG_DYLIB=NO`和ad-hoc
Hardened Runtime签名；strict codesign、entitlements、staging/installed一致性、无quarantine及exact安装
路径启动均通过。2026-09-01只读inventory进一步确认该App不含`CodexRuntime`、`DocumentRuntime`或
`BrowserRuntime`目录；shipping locator又禁止正式bundle退回外置开发runtime。因此它只证明主App启动与
Chat壳，不证明Code/Cowork或固定文档/浏览器能力可运行，也仍不是Developer ID公证发行物。

2026-08-19 用户已批准 JetBrains Mono 为 macOS/iOS 统一的第一方英文字体。两份 exact v2.304 TTF
随 `IntatisSharedUI` resources 进入 Debug、Release 与正式 bundle；没有 system-font opt-out 或实验打包
分支。正式 release build 必须核对 exact resource inventory/hash、OFL、bundle size、Dynamic Type、
VoiceOver 与中英混排，并在任一漂移时 fail closed。字体选型不再单独阻断发行；签名、公证、Gatekeeper
和 clean-machine 等其余发行门槛仍须全部满足，且不得覆盖既有 notarization recovery artifact。

## 直分发打包入口

仓库唯一正式打包入口是 `scripts/package-macos-release.sh`。它只构建
`TranslatisMac`，并且在以下所有条件成立后才把产物写入 `dist/`：

1. 当前 Keychain 存在有效的 `Developer ID Application` identity；
2. `TRANSLATIS_NOTARY_PROFILE` 指向用户已通过 `notarytool store-credentials`
   保存的 Keychain profile；
3. `TRANSLATIS_DOCUMENT_RUNTIME_ARM64_ROOT` / `TRANSLATIS_DOCUMENT_RUNTIME_X86_64_ROOT`
   指向已完成 provenance/license/SBOM/hash 和 bottom-up Developer ID 签名的 fixed roots；
4. 两套 roots 在 stage 前后通过 manifest、完整 SHA-256 inventory、Heron/English tessdata pins、
   SPDX/license closure、target Mach-O architecture/load commands/RPATH 与 exact identity 静态校验；
5. universal Release build 同时包含 `arm64` 与 `x86_64`，并把两套 roots 放在
   `Contents/Resources/DocumentRuntime/<architecture>`；
6. 使用 Developer ID entitlements、secure timestamp 与 Hardened Runtime 完成签名；outer App
   strict resource seal 与 exact identity 通过后，才执行两套 runtime 的 fixed version probes；
7. App 公证状态为 `Accepted`，staple/validate、严格 codesign 与 Gatekeeper assessment
   全部通过；
8. DMG 包含 `/Applications` 拖放入口，以 Developer ID 单独签名，再次公证并完成
   staple/validate、codesign 与 Gatekeeper assessment。

使用方式：

```sh
TRANSLATIS_DOCUMENT_RUNTIME_ARM64_ROOT=<absolute-reviewed-arm64-root> \
TRANSLATIS_DOCUMENT_RUNTIME_X86_64_ROOT=<absolute-reviewed-x86_64-root> \
TRANSLATIS_NOTARY_PROFILE=<本机 profile 名称> \
  scripts/package-macos-release.sh
```

如果当前网络必须通过本机代理/VPN 才能访问 GitHub，但该代理/VPN 会阻断 Apple
notarization，使用交互式两阶段模式：

```sh
TRANSLATIS_PAUSE_BEFORE_NOTARIZATION=1 \
TRANSLATIS_DOCUMENT_RUNTIME_ARM64_ROOT=<absolute-reviewed-arm64-root> \
TRANSLATIS_DOCUMENT_RUNTIME_X86_64_ROOT=<absolute-reviewed-x86_64-root> \
TRANSLATIS_NOTARY_PROFILE=<本机 profile 名称> \
  scripts/package-macos-release.sh
```

运行命令时保持代理/VPN 开启，让 Xcode/SwiftPM 完成依赖解析、Release 构建和 Developer
ID 签名。脚本提示 `GitHub is no longer used after this point` 后保持终端打开，关闭会阻断
Apple 的代理/VPN，再按 Return。脚本会用当前 Keychain profile 探测 Apple notarization；
若仍不可达，会保留已经签名的临时 App 并原地等待重试，不重新构建。不要为了这个流程删除
Git 的 GitHub 专用 proxy 配置；该配置在暂停点之后不再参与后续步骤。

上传使用 `notarytool submit --no-wait --progress`，终端持续显示上传进度并在上传结束后记录
submission ID。随后 `notarytool wait` 默认最多等待 30 分钟；可通过
`TRANSLATIS_NOTARY_TIMEOUT=2h` 等正时长显式调整。超时不代表失败，Apple 会继续处理；若状态
仍是 `In Progress`，脚本以非零状态安全退出并把签名 App、上传日志、submission ID 和后续
DMG 状态保存在 owner-only 的 `.translatis/release-recovery/<run>/`。不得因此重复上传。按脚本
打印的精确命令恢复同一提交，例如：

```sh
TRANSLATIS_NOTARY_PROFILE=<本机 profile 名称> \
TRANSLATIS_RESUME_RELEASE_DIR=<脚本打印的绝对 recovery 路径> \
  scripts/package-macos-release.sh
```

恢复模式重新核对版本、universal 架构、Developer ID、Hardened Runtime 和 entitlements，
然后复用已记录的 App/DMG submission ID；不会重新构建或重新上传。签名完成后的 Control-C、
TERM、网络错误、Apple 长时间处理或 Invalid 也保留 recovery 目录，成功输出最终产物后才自动
清理。`TRANSLATIS_RESUME_RELEASE_DIR` 只接受仓库 `.translatis/release-recovery/` 下当前用户拥有、
模式为 `0700` 且 state/App 均非 symlink 的绝对路径。

如果 Keychain 中存在多个 Developer ID Application identity，额外设置
`TRANSLATIS_DEVELOPER_IDENTITY` 为目标证书的完整 common name。可用
`TRANSLATIS_OUTPUT_DIR` 改变输出目录。证书、私钥、Apple 账号/App Store Connect
凭据和 profile 内容都不得进入仓库；脚本只接收 identity/profile 名称。

文档 runtime 不由发行脚本下载或安装。

- `Packages/IntatisTools/Runtime/document-runtime/release-spec.json` 是 exact compatibility contract；
  `scripts/validate-document-runtime.sh` 是 gate，不是 binary builder；provenance/license 见
  `ThirdPartyNotices/DocumentReadingRuntime.md`。
- shipping `TranslatisMac` 只使用 bundle 内 active-architecture root。缺失、损坏或版本漂移时 fail
  closed，不得回退 Application Support、Homebrew、系统 LibreOffice/TeX 或另一个 parser/backend。
  CLI/debug 的 user-managed root 不满足 release gate。
- validator 的 `static` phase 不执行 runtime；`execute` 只接受已处于最终 sealed App layout 的 root，
  并要求 exact outer Developer ID identity。正常发行只能由打包脚本按该顺序调用。
- 截至 2026-08-24，源码/spec/validator/staging gate与本机`.4` arm64 Codex release-profile evidence
  已存在，但没有完整arm64+x86_64 signed document/Codex roots、包含它们的notarized App或clean-machine
  evidence；上文Codex runtime也尚未bundle，正式发行仍被阻断。门禁或单架构binary完成不等于发行制品完成。

输出包括 stapled App 的 ZIP、已单独公证并 stapled 的 DMG，以及两者的 SHA-256
清单。任一门槛失败都不得把 ad-hoc/未公证包发布为正式产物。

## “不再考虑 App Store 沙箱”的精确定义

以后不得仅为兼容 Mac App Store App Sandbox 而：

- 移除或禁用 managed terminal、PTY、spawn-based Git、浏览器 helper、stdio
  MCP、global Skill roots 或其他直接分发版能力；
- 新增进程内 Git/MCP/脚本替代实现；
- 把 Code/Cowork 降级成 chat-only 或 HTTP-only；
- 重新引入 `TranslatisMacAppStore`、App Store scheme、编译条件或专属 entitlements；
- 将 App Store entitlement/linkage/build 结果列为发布阻塞项。

这项决策只移除 **Mac App Store 分发所强加的 App Sandbox 产品约束**，不移除
Intatis 自己的安全边界。以下要求继续有效：

- `DeterministicPolicyGate` / `ModelPermissionReviewer` /
  `PermissionEngine` 三层权限门；
- `CapabilityLease`、`WorkspaceLease`、`PathConfinement`、
  `SecretScanner`、Mediator 和 EventLog/durable tool ticket；
- managed terminal 的 workspace-scoped Seatbelt、默认断网、凭据环境过滤、
  进程清理和输出边界；
- Developer ID Hardened Runtime、代码签名、公证、Keychain 与最小必要
  entitlements；输入栏语音使用系统 TCC 麦克风授权，并在 shipping Developer ID target 只增加
  Hardened Runtime 所需的 `com.apple.security.device.audio-input=true`，不启用 App Sandbox；
- iOS target 的 chat-only linkage 边界。

因此，后续文档和报告提到 `sandbox` 时必须说明具体含义。`App Sandbox` /
`Mac App Store sandbox` 仅可用于历史记录或遗留 target 说明；`Seatbelt
runtime sandbox`、测试宿主 sandbox、Linux bwrap 和权限/工作区围栏仍是当前
产品安全合同，不能因为本决策而弱化。

## 验证规则

默认产品验证矩阵为：

1. 与改动相称的 SwiftPM focused/full tests；
2. `swift build` 与受影响的 CLI product；
3. `xcodegen generate`；
4. `TranslatisMac` macOS build；
5. 文档 runtime 变更必须追加 validator/release-script `zsh -n`、release spec `plutil`、focused
   reader/cursor/PDF identity/RSS tests，以及 iOS no-link inspection；
6. 触及实际发行时让两套 document roots 通过 static/final execute gate，并完成 Developer ID 签名、
   公证、Hardened Runtime、entitlements、runtime/resource 和 bundle/link inventory；
7. 触及 iOS 子集或共享依赖边界时追加 `TranslatisiOS` build/test。

工程生成后必须检查 target/scheme 清单，确认只有 `TranslatisMac` macOS App 与
`TranslatisiOS` iOS App，不得静默恢复已删除的 `TranslatisMacAppStore`。旧历史报告中的
同名构建结果不进入当前验证矩阵，也不能触发第二套产品修复。

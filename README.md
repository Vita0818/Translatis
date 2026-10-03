# Translatis

当前版本：**v0.72**（build 72）
状态：pre-1.0；Code/Cowork/CLI 已完成 Codex Runtime 第一版与主要产品投影接线。当前发行阻断项是
三套双架构 runtime bundling/签名/公证；剩余功能缺口主要在部分 MCP/interaction。Agent
`hosted_web_search`已于2026-09-02通过official dynamic tools接回。本轮图片、搜索、结构化提问、
Providers、Protocol、CLI与UI聚焦矩阵通过；完整SwiftPM suite再次在SharedUI组合顺序中静默等待并按
有界窗口终止，因此CI仍必须保留wall-clock timeout与诊断采样。

Translatis 是 Apple-first、Swift-native 优先的本地 AI 工作区。macOS 提供 Chat、Code、
Cowork 三个产品面；iOS 是严格的 Chat 子集；CLI 提供 headless Code/Cowork。Chat 继续使用
Swift ChatLoop；Code、Cowork 与 CLI Code/Cowork 通过最薄 Swift host 直接运行基于官方开源 Codex
App Server 0.145.0 的窄派生 runtime `0.145.0-intatis.4`。Translatis保留自己的 UI、provider、workspace与审计投影，不使用 ChatGPT login，
也不在 Codex失败时回退旧 AgentKernel。

当前文档入口见 [`docs/README.md`](docs/README.md)，版本规则见
[`docs/VERSIONING.md`](docs/VERSIONING.md)。历史 v0.1–v0.16 里程碑不代表当前产品版本。
其他Vitemis项目不复制runtime源码，而是按
[`docs/CODEX_RUNTIME_INTEGRATION.md`](docs/CODEX_RUNTIME_INTEGRATION.md)
直接依赖本仓库的`IntatisCodexRuntime`稳定v1宿主面。只复用Cowork完整右侧UI的macOS宿主使用
`IntatisCoworkUI`，并保留自己的runtime/session与per-session tools；合同见
[`docs/COWORK_UI_INTEGRATION.md`](docs/COWORK_UI_INTEGRATION.md)。

## 命名边界

Translatis 是本仓库的产品与宿主身份：产品 App/CLI、Bundle ID、命令、配置文件、环境变量、
隐藏 workspace 目录、Knowledge/诊断目录和运行时缓存都从 `Translatis` host identity 派生，
不会写入或默认复用 Intatis 的活动路径。`Packages/Intatis*`、`IntatisHostApplicationIdentity`、
`IntatisCodexRuntime` 以及 `0.145.0-intatis.4`、`intatis_responses_provider`、
`intatis_agent_workspaces`、`--intatis-derivation-id` 是共享实现或固定外部协议身份，按官方
接线合同保留；其中旧 Intatis 名称只作为受保护的 legacy/deny floor，不是 Translatis 的活动命名空间。

## 当前产品面

### macOS

- Chat：OpenAI-compatible streaming、provider/model/variant 配置、透明 hosted web search、
  citations、会话历史、多模态产物和本地诊断导出。
- Code：保留现有单 workspace UI，执行内核为 Codex thread/turn、原生工具、sandbox和
  approval/auto-review；macOS图片附件可作为 App Server local image，`generate_image`与
  `edit_image`也已通过official dynamic tools接入既有图片provider service。exact Agent route明确声明
  受审托管搜索能力时，同一入口还发布strict query-only `hosted_web_search`并绑定该route的既有
  provider-hosted search service。
- Cowork：保留现有项目/agent/thread UI shell，执行内核为一个 Codex root thread及其官方
  collaboration/subagent runtime。verified child roster/history、WorkTask、thread Goal、native message、
  root/child Knowledge、native Skills与Code/Cowork exact root Streamable HTTP MCP均已接回；Cowork child
  默认原生禁用MCP。official `request_user_input`已在macOS Code/Cowork接到原生SwiftUI：同一请求可显示
  1–3道单选题，每题支持2–3个互斥选项与Other自由文本，并以`⌘↩`提交；CLI仍明确关闭该交互能力。
  per-child MCP与native OAuth/elicitation也仍明确不可用，
  且这些能力都不走旧Orchestrator或自制兜底。
- Projects：Chat、Code、Cowork 各自维护独立的文件夹项目；当前模式下一个项目对应一个现存
  本地文件夹，以可折叠目录归组同模式会话。它不移动会话数据、不在用户文件夹写 Translatis 元数据，
  也不增加项目级记忆、任务或权限。
- 设置：provider catalog、Translatis JSON/JSONC 配置、MCP、renderer fallback、第三方声明，
  以及只在本机生成且不上传的脱敏诊断 ZIP。

macOS 唯一发行 target 是 `TranslatisMac`，通过 Developer ID、Apple notarization 和直接下载
分发。旧 `TranslatisMacAppStore` target、scheme、编译条件和专属 App Sandbox entitlements 已从
当前源码与 XcodeGen 工程定义中删除；项目不提供 Mac App Store 产品。

当前本机v0.72预览不含`CodexRuntime`、`DocumentRuntime`或`BrowserRuntime`。shipping locator又只接受
App内active-architecture sealed root，所以该预览只证明主App/Chat壳启动，不证明Code/Cowork或完整
document/browser工具可运行。

### iOS

iOS 只链接 Core、Protocol、Providers、Conversation、Artifacts、Multimodal 和 SharedUI。
它支持 Chat、provider 配置导入、会话历史、托管搜索、citations 和图片生成，但不链接
Tools、Permission、AgentKernel、Cowork、MCP 或本地 workspace/shell。

### CLI

`translatis` 支持 Chat/Code/Cowork REPL。Chat 使用 ChatLoop；`code` / `cowork` 与 macOS 共用
Codex App Server runtime、Responses provider、streaming、approval、cancel和Goal。CLI attachment、
`/clear`第一版明确不可用；`/mcp`可管理exact root authority，重启Code/Cowork runtime后投影native
Streamable HTTP配置。CLI发布与macOS相同的`generate_image`/`edit_image`，并在exact route明确支持时
条件式发布`hosted_web_search`。

## 核心不变量

- Chat 的 EventLog合同不变。Code/Cowork中，Codex rollout是模型上下文权威，EventLog是Translatis
  UI/audit投影权威；`codex-runtime/runtime.json` 必须精确连接两者。
- Chat 无工具；Code/Cowork工具、sandbox、approval与auto-review由固定官方 Codex runtime执行。
  Translatis不得复制这些能力，也不得调用旧 AgentLoop/Orchestrator作为 fallback。
- 每个 Codex process使用 isolated session-owned CODEX_HOME、`requires_openai_auth=false`和
  Translatis Responses credential；不读取 ChatGPT login。
- secret 只从受控 credential reference 懒加载，不进入 EventLog、诊断包或仓库文档。
- iOS 是结构性子集，不靠运行时开关隐藏本地 agent 能力。
- 第三方源码和依赖必须固定 provenance、许可证并更新 `NOTICE.md`。

详细合同见 [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) 和
[`docs/DO_NOT_BREAK.md`](docs/DO_NOT_BREAK.md)。

## 仓库结构

```text
Apps/                 macOS、iOS 与 CLI 入口
Packages/             17 个公共库、内部 C/guard target 与测试（含 IntatisCodexRuntime/CoworkUI）
Vendor/               经审计并固定的第三方派生源码
ThirdPartyNotices/    许可证、来源与资源清单
ThirdPartyPatches/    固定上游commit可复现应用的最小第三方源码补丁
Tests/                MCP conformance 与独立 parity fixtures
docs/                 当前规范和已标记的历史设计文档
scripts/              构建、验证、诊断和发行脚本
project.yml           XcodeGen 及产品版本唯一事实源
Package.swift         SwiftPM 产品、target 与测试图
```

精确 target 和入口见 [`docs/PROJECT_MAP.md`](docs/PROJECT_MAP.md)。

## 开发与验证

要求 Xcode 27 / Swift 6.x、XcodeGen，以及 Code/Cowork开发试用所需的 exact
`codex-cli 0.145.0-intatis.4`与当前0003 derivation。CLI/非产品debug host可发现
`~/.local/bin/translatis-codex`或使用`TRANSLATIS_CODEX_RUNTIME`；正式TranslatisMac bundle identity会拒绝外置
override/env/PATH并只接受`Contents/Resources/CodexRuntime/{active-architecture}/codex`。普通Xcode build
不会自动stage三套runtime。常用命令：

```sh
scripts/check-version-consistency.sh
swift test --disable-automatic-resolution
xcodegen generate

xcodebuild -project Translatis.xcodeproj -scheme TranslatisMac \
  -configuration Debug -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO build

xcodebuild -project Translatis.xcodeproj -scheme TranslatisiOS \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

当前测试状态和环境限制以 [`docs/TESTING.md`](docs/TESTING.md) 为准，不以 README 中的
历史测试数量判断 release readiness。2026-09-02最终工作树的完整SwiftPM运行正常退出0；历史上曾出现
SharedUI组合顺序间歇性挂起，这项稳定性风险并未因单次通过而被抹除。

## macOS 直接分发

正式发行需要本机 Keychain 中有效的 `Developer ID Application` identity、用户自行保存的
`notarytool` profile，以及Codex/Document/Browser各自arm64+x86_64六个已验证runtime roots：

```sh
TRANSLATIS_CODEX_RUNTIME_ARM64_ROOT=/absolute/codex/arm64 \
TRANSLATIS_CODEX_RUNTIME_X86_64_ROOT=/absolute/codex/x86_64 \
TRANSLATIS_DOCUMENT_RUNTIME_ARM64_ROOT=/absolute/document/arm64 \
TRANSLATIS_DOCUMENT_RUNTIME_X86_64_ROOT=/absolute/document/x86_64 \
TRANSLATIS_BROWSER_RUNTIME_ARM64_ROOT=/absolute/browser/arm64 \
TRANSLATIS_BROWSER_RUNTIME_X86_64_ROOT=/absolute/browser/x86_64 \
TRANSLATIS_NOTARY_PROFILE=<profile-name> \
  scripts/package-macos-release.sh
```

如果GitHub需要代理/VPN、Apple notarization又需要直连，在同一组六个runtime roots与notary profile上
额外设置两阶段开关：

```sh
TRANSLATIS_PAUSE_BEFORE_NOTARIZATION=1 \
TRANSLATIS_CODEX_RUNTIME_ARM64_ROOT=/absolute/codex/arm64 \
TRANSLATIS_CODEX_RUNTIME_X86_64_ROOT=/absolute/codex/x86_64 \
TRANSLATIS_DOCUMENT_RUNTIME_ARM64_ROOT=/absolute/document/arm64 \
TRANSLATIS_DOCUMENT_RUNTIME_X86_64_ROOT=/absolute/document/x86_64 \
TRANSLATIS_BROWSER_RUNTIME_ARM64_ROOT=/absolute/browser/arm64 \
TRANSLATIS_BROWSER_RUNTIME_X86_64_ROOT=/absolute/browser/x86_64 \
TRANSLATIS_NOTARY_PROFILE=<profile-name> \
  scripts/package-macos-release.sh
```

保持代理/VPN 开启完成依赖解析、构建和签名；脚本明确提示后保持终端打开，关闭代理/VPN
再按 Return。它会先验证 Apple 可达性，失败时原地等待重试，不重新构建。上传进度和
submission ID 会直接显示；Apple 处理默认等待 30 分钟，仍为 `In Progress` 时保留签名
产物并打印 `TRANSLATIS_RESUME_RELEASE_DIR` 恢复命令。恢复同一 submission，不要重复上传。

该脚本只有在 universal Release、Hardened Runtime、Developer ID 签名、App/DMG 公证、
staple、codesign 和 Gatekeeper assessment 全部通过后，才向 `dist/` 输出 ZIP、DMG 与
SHA-256 清单。不要把证书私钥、Apple 密码或 app-specific password 写入仓库或对话。

## 配置与数据

- macOS/CLI 高级配置读取 `TRANSLATIS_CONFIG`、Translatis-owned JSON/JSONC 路径及兼容 fallback；
  不默认读取 OpenCode app 配置。
- 新 Codex Cowork 的自动权限审查由 App Server `auto_review`执行，并通过官方 model catalog绑定
  当前 selected Responses model；顶层 `permission_reviewer_model` 只为 legacy/manual-rollback源码与
  兼容配置保留，不再阻止新 Cowork启动，也不会产生第二次 Translatis reviewer dispatch。
- 顶层`image_model`是shipping `generate_image`/`edit_image`唯一的host-owned图片路由。两个工具已通过
  official `thread/start.dynamicTools`进入Code/Cowork/CLI，并直接注入既有
  `ProviderImageGenerationToolService`；模型不能在tool arguments里另选provider/model。没有配置时明确
  失败，不回退legacy AgentLoop、当前推理模型或第二图片backend。
- macOS Chat/Code/Cowork 与 iOS Chat 的输入栏语音按钮共用顶层 `transcription_model` 宿主路由；
  再次点击会停止录音并转写，结果只追加到当前可编辑草稿，不会自动发送。未配置时在本地明确
  提示，不会回退到当前 Chat 模型，也不会为此增加另一套设置页面。
- session 数据默认位于用户 App Support 下，每个 session 使用 append-only EventLog。
- browser profile、workspace artifact、credential 和 bookmark 不应提交到 Git，也不会进入
  本地诊断 ZIP。
- 日志导出当前不做远程上传；Apple notarization 仅在用户显式运行发行脚本时发生。

最小配置示例（图片、语音和 Knowledge provider 也可与 Chat provider 相同）：

```json
{
  "$schema": "https://opencode.ai/config.json",
  "model": "chat/chat-model",
  "image_model": "images/gpt-image-1",
  "transcription_model": "speech/whisper-1",
  "embedding_model": "knowledge/BAAI/bge-m3",
  "reranker_model": "knowledge/BAAI/bge-reranker-v2-m3",
  "provider": {
    "chat": {
      "npm": "@ai-sdk/openai-compatible",
      "options": {
        "baseURL": "https://chat.example.com/v1",
        "apiKey": "{env:CHAT_API_KEY}"
      },
      "models": {
        "chat-model": { "name": "Chat Model" }
      }
    },
    "images": {
      "npm": "@ai-sdk/openai-compatible",
      "options": {
        "baseURL": "https://images.example.com/v1",
        "apiKey": "{env:IMAGE_API_KEY}"
      },
      "models": {}
    },
    "speech": {
      "npm": "@ai-sdk/openai-compatible",
      "options": {
        "baseURL": "https://speech.example.com/v1",
        "apiKey": "{env:SPEECH_API_KEY}"
      },
      "models": {}
    },
    "knowledge": {
      "npm": "translatis:siliconflow-v1",
      "options": {
        "baseURL": "https://your-knowledge-provider.example/v1",
        "apiKey": "{env:KNOWLEDGE_API_KEY}"
      },
      "models": {}
    }
  }
}
```

Codex Runtime 恢复了旧链路对 OpenRouter `options.provider` 的
request-owned opaque passthrough：

```json
"stealth/ox-alpha": {
  "name": "Ox Alpha",
  "provider": { "npm": "@openrouter/ai-sdk-provider" },
  "options": {
    "reasoningEffort": "max",
    "provider": {
      "require_parameters": true
    }
  }
}
```

`0.145.0-intatis.4` 不枚举或解释 `provider` 的子字段，而是把整个object原样写入原生
Responses body；未来provider-owned字段不需要再改补丁。该通道不是generic `extra_body`，不能覆盖
`model`、`input`、`tools`、`stream`、`reasoning`等host-owned字段；跨进程前仍执行递归
secret/transport-key扫描与结构资源边界，非OpenRouter adapter或非object shape继续fail closed。
对显式OpenRouter adapter，host不会关闭`require_parameters`来换取成功，而是从请求中省略该exact
model未声明的Codex optional controls，并通过Codex官方config关闭未配置的web search。普通business
functions与MultiAgent V2 control functions都以provider-agnostic top-level function shape保留；所有fork
模式继承同一dynamic tool surface，不存在OpenRouter root-only shipping分支。不要给只有单一endpoint的
模型照抄其他provider的`order`。

`permission_reviewer_model`只为legacy/manual-rollback本地Permission Reviewer继续兼容解析；shipping
Codex不会用它创建第二个审查控制面。App Server official auto_review通过exact model catalog绑定当前
selected Responses model；目标provider若不支持原生Codex tool shape就明确失败，不做协议转换。

`image_model` 是 Translatis 的顶层扩展字段，格式为 `<provider>/<model-id>`。专用图片 provider
可保持空 `models`，因此不会混入 Chat/Code/Cowork 的推理模型菜单；当前 backend 要求该 route
兼容 `POST <baseURL>/images/generations` 与 multipart `POST <baseURL>/images/edits`，并返回
`data[].b64_json`。`edit_image` 当前支持单张 PNG/JPEG/WebP 输入（最多 50 MiB）并写出新的 PNG；
尚不支持 mask、多参考图或原地覆盖输入图。shipping Code/Cowork/CLI 已通过official
`thread/start.dynamicTools`发布这两个exact工具；执行仍走现有WorkspaceLease、CapabilityLease、权限和
durable executor。只有read-write root/child获得同名exact capability，read-only child会在审计前拒绝。

`transcription_model` 同样是 Translatis 的顶层扩展字段，格式为 `<provider>/<model-id>`。专用语音
provider 可保持空 `models`，不会混入推理模型菜单；输入栏按 Flotis 的单模型 recorded-file runtime
录制 WAV/16 kHz/mono。compatible provider 使用 multipart，exact OpenRouter adapter 使用 JSON-base64
`input_audio`，两者都调用 `POST <baseURL>/audio/transcriptions`。录音和 upload body 使用有界、
owner-only 的临时文件，转写完成、失败或取消后即清理；用户按下 Send 前，音频和转写草稿都不会写入
EventLog 或 ArtifactStore。该接入不包含多模型对比，也没有新增设置页。

`embedding_model` 与 `reranker_model` 是 Knowledge 的两个独立必填 route，均只接受
`<provider>/<model-id>`；缺少任意一个时，Code/Cowork 不会获得 `build_knowledge` 和
`search_knowledge`。上例中的 URL 和模型 ID 是需要替换的配置值；`translatis:siliconflow-v1`
表示该 provider 同时使用 OpenAI-compatible `POST <baseURL>/embeddings` 和显式
`POST <baseURL>/rerank`。若 reranker 使用 Cohere v2，应为它建立独立 provider 并将 `npm` 写为
`translatis:cohere-v2`。Knowledge-only provider 的 `models` 可保持空对象，不会进入普通推理模型菜单；
若使用没有内置维度定义的 embedding 模型，则必须在对应 model 的 `options.dimensions` 中显式声明
正整数维度。若配置使用 `enabled_providers`，也必须把 Knowledge route 的 provider ID 加入其中。
Knowledge 工具仅接入 macOS/CLI 的 Code 与 Cowork，不进入 Chat 或 iOS。
用户无需学习挂载命令或新增管理页面：可以用自然语言要求 Agent 读取当前 workspace 的文本、PDF
或其它文档，整理为有来源的 OKF draft，并把库建立在 workspace 内或用户点名并精确授权的外部目录。
成功 build/query 会分别使用这里配置的 embedding route；每次成功 search 还必须实际使用这里配置的
semantic reranker，并要求最终回答引用本轮返回的 exact evidence ID。

使用同一个 OpenRouter provider 的已验收配置片段如下。即使 provider 默认仍用于普通
OpenAI-compatible Chat，这两个 model 也应以 model-level `@openrouter/ai-sdk-provider` 冻结 Knowledge
协议；顶层 role 引用的 exact model 会保留 adapter/options，但不会进入 Chat/Cowork 推理模型菜单。

```json
{
  "embedding_model": "OpenRouter/google/gemini-embedding-2",
  "reranker_model": "OpenRouter/cohere/rerank-4-pro",
  "provider": {
    "OpenRouter": {
      "npm": "@ai-sdk/openai-compatible",
      "options": {
        "baseURL": "https://openrouter.ai/api/v1",
        "apiKey": "{env:OPENROUTER_API_KEY}"
      },
      "models": {
        "google/gemini-embedding-2": {
          "name": "Gemini Embedding 2",
          "provider": { "npm": "@openrouter/ai-sdk-provider" },
          "options": { "dimensions": 1536 }
        },
        "cohere/rerank-4-pro": {
          "name": "Cohere Rerank 4 Pro",
          "provider": { "npm": "@openrouter/ai-sdk-provider" }
        }
      }
    }
  }
}
```

## 许可证

Translatis 自有代码和第三方采用状态见 [`NOTICE.md`](NOTICE.md)、
[`ThirdPartyNotices/`](ThirdPartyNotices/) 与
[`docs/OPEN_SOURCE_REUSE.md`](docs/OPEN_SOURCE_REUSE.md)。

# Codex Runtime 跨项目接入合同

文档状态：当前共享内核接入规范
最近核对：2026-09-08
宿主 API：v1
外部 runtime：`codex-cli 0.145.0-intatis.4`

## 目标

Vitemis 的其他项目不复制 `Packages/IntatisCodexRuntime`。它们把本仓库作为一个
SwiftPM 本地依赖，直接编译同一份共享源码；项目自己的 instructions、工具、UI、
workspace 和持久化组合留在自己的仓库。

```text
唯一 Intatis checkout
  -> IntatisCodexRuntime SwiftPM product
       -> Intatis host
       -> Project A host
       -> Project B host
```

共享的是只读源码与 exact Codex executable。每个宿主在进程入口只安装一次自己的
`IntatisHostApplicationIdentity`；共享 packages随后从该identity统一派生产品拥有的路径、配置、
环境变量、defaults、Keychain、诊断、workspace metadata、registry/policy/toolset和model-facing
reserved-field名称。每个宿主仍必须为每个session分配自己的isolated `CODEX_HOME`、workspace、
credential和权限状态。不得让两个项目共用一个可写session runtime root。

只需要复用Intatis Cowork完整右侧UI的宿主另依赖`IntatisCoworkUI`并遵守
`docs/COWORK_UI_INTEGRATION.md`。该UI product不会创建或替换本文件定义的runtime/session，也不会迁移
宿主已有的per-session dynamic tools。

## 单次宿主身份安装

在构造任何 Intatis storage、provider、tool、MCP、Knowledge、SharedUI 或 Codex Runtime 对象前，
宿主只调用一次：

```swift
import IntatisCore

let applicationIdentity = try IntatisHostApplication.configure(
    name: "Mopelium")
```

该identity在第一次读取后锁定；同一进程之后安装不同名称会明确失败，防止已经派生了一部分路径后
又把其余状态切到另一产品。名称必须以ASCII字母开头、以字母或数字结束，最多64个字符；只允许
ASCII字母、数字，以及位于名称片段之间且不连续的空格、`-`和`_`。例如`Mopelium`自动得到：

| 类别 | 派生值 |
|---|---|
| App Support目录 | `Mopelium` |
| config stem / command | `mopelium` |
| config文件 | `mopelium.json` / `mopelium.jsonc` |
| 环境变量prefix | `MOPELIUM_*` |
| UserDefaults/registry prefix | `mopelium.*` |
| Keychain service | `com.vitemis.mopelium.*` |
| workspace state | `.mopelium/` |
| Knowledge publication | `.mopelium-rag-*` |
| permission sidecar | `__mopelium_authorization_context` |
| provider adapters | `mopelium:siliconflow-v1` / `mopelium:cohere-v2` |

`IntatisHostApplicationIdentity`还提供`applicationSupportRoot`、`userConfigurationDirectory`、
`userDataDirectory`、`environmentVariable`、`userDefaultsKey`、`namespacedIdentifier`和
`keychainService`等派生API；下游不得另写一套字符串替换表。当前Translatis三个入口显式安装
`name: "Translatis"`，因此活动路径和新写字段统一使用Translatis派生值；旧Intatis路径只保留为
legacy/deny floor。
macOS shipping识别同时接受Vitemis现有的`com.Vita0818.<App>`与
`com.Vita0818.<App>Mac`/同名可执行候选；Translatis 的 macOS target 使用
`com.Vita0818.TranslatisMac`，iOS target 使用 `com.Vita0818.Translatis`，两者都由同一个
Translatis host identity 校验，不会因此放宽到无关 bundle。

这项参数化不动态改写Swift package/module/type名称，也不改写固定external-runtime协议：
`IntatisCodexRuntime` product、`codex-cli 0.145.0-intatis.4`版本、
`intatis_responses_provider`、`intatis_agent_workspaces`和`--intatis-derivation-id`仍是共享实现及
exact派生依赖身份，不是宿主数据命名空间。历史Intatis敏感路径/Knowledge publication仍保留在
deny/secret-recognition floor，但下游不会向其写新数据；本接线不自动迁移、合并或删除旧产品数据。
`CFBundleIdentifier`、`CFBundleDisplayName`、target/executable名称、Info.plist、Settings.bundle与本地化
资源属于宿主App的build-time产品配置，仍由各项目自己的target设置；运行时App名称不会改写已签名bundle。

## SwiftPM 本地依赖

目标项目的 `Package.swift` 使用指向唯一 Intatis checkout 的相对路径：

```swift
dependencies: [
    .package(path: "../../Intatis"),
]
```

宿主 target 声明它直接使用的产品：

```swift
.target(
    name: "ProjectAgentHost",
    dependencies: [
        .product(name: "IntatisCore", package: "Intatis"),
        .product(name: "IntatisProtocol", package: "Intatis"),
        .product(name: "IntatisProviders", package: "Intatis"),
        .product(name: "IntatisCodexRuntime", package: "Intatis"),
    ]
)
```

然后只导入所需模块：

```swift
import IntatisCore
import IntatisProtocol
import IntatisProviders
import IntatisCodexRuntime
```

本地 path dependency 使用路径处的当前源码；内核修改会在消费项目下一次构建时生效。
已构建或正在运行的 App 不会热替换，仍须重新构建或重启。

## v1 稳定宿主面

机器可读身份是 `CodexRuntimeHostContract`：

```swift
precondition(CodexRuntimeHostContract.publicAPIMajorVersion == 1)
```

以下声明组成 v1 的稳定接入口：

- SwiftPM package/product/module：`Intatis` / `IntatisCodexRuntime` /
  `IntatisCodexRuntime`；
- exact executable：`CodexRuntimeHostContract`、`CodexRuntimeExecutable`；
- route/configuration：`ResponsesRuntimeRoute`、`CodexRuntimeMode`、
  `CodexRuntimeApprovalReviewer`、`CodexRuntimeConfiguration`；
- host identity：`IntatisHostApplicationIdentity`、`IntatisHostApplication.configure(name:)`、
  `IntatisHostApplication.identity`；`CodexRuntimeConfiguration.hostApplicationIdentity`冻结当前session
  的exact宿主身份；
- session lifecycle：`CodexAppServerSession.init(configuration:)`、`events()`、
  `start()`、`startTurn(text:localImageURLs:)`、
  `runTurn(text:localImageURLs:)`、`waitForTurn(_:)`、
  `interruptCurrentTurn()`、`interruptTurn(turnID:)`、
  `resolveApproval(requestID:decision:)`、`shutdown()`；
- result/event types：`CodexRuntimeIdentity`、`CodexRuntimeEvent`、
  `CodexRuntimeTurnResult`、`CodexRuntimeResponsesUsage`、
  `CodexRuntimeApprovalRequest`、`CodexRuntimeRequestID`、
  `CodexRuntimeApprovalDecision`、`CodexRuntimeError`；
- optional first-party tool callback：`CodexRuntimeDynamicToolSpec`、
  `CodexRuntimeDynamicToolCall`、`CodexRuntimeDynamicToolResult`、
  `CodexRuntimeDynamicToolContentItem`、`CodexRuntimeDynamicTools`；
- optional official structured-question callback：`CodexRuntimeUserInputOption`、
  `CodexRuntimeUserInputQuestion`、`CodexRuntimeUserInputRequest`、
  `CodexRuntimeUserInputResponse`、`CodexRuntimeUserInputHandler`；通过
  `CodexRuntimeConfiguration.requestUserInputHandler`接入，nil保持关闭；
- 上述签名使用的 `SessionID`、`ModelID`、`JSONValue` 和
  `ProviderRequestAdapter`。

该清单之外的 public declarations 目前服务 Intatis 自身的 Cowork、Goal、native MCP、Skills、
Knowledge 和 child presentation 接线；其他项目在明确需要并把它们加入稳定合同前，不应把这些
内部产品细节当作跨项目兼容 API。

## 最小宿主

```swift
try IntatisHostApplication.configure(name: "ProjectAgent")

let route = ResponsesRuntimeRoute(
    endpointID: "project-provider",
    model: ModelID(rawValue: "project-model"),
    baseURL: responsesBaseURL,
    bearerToken: credential)

let configuration = CodexRuntimeConfiguration(
    sessionID: SessionID.new(),
    mode: .code,
    workspaceURL: workspaceURL,
    runtimeRootURL: sessionDirectory
        .appendingPathComponent("codex-runtime", isDirectory: true),
    route: route,
    executableOverride: sharedCodexExecutableURL)

let session = CodexAppServerSession(configuration: configuration)
let events = await session.events()
let eventTask = Task {
    for await event in events {
        switch event {
        case .approvalRequested(let request):
            let decision = await presentApproval(request)
            try await session.resolveApproval(
                requestID: request.requestID,
                decision: decision)
        case .assistantDelta(_, let text, _):
            presentStreamingText(text)
        case .assistantCompleted(_, let text, _):
            presentFinalText(text)
        case .runtimeError(_, let message, _):
            presentRuntimeError(message)
        default:
            break
        }
    }
}

do {
    _ = try await session.start()
    let result = try await session.runTurn(text: userText)
    guard result.succeeded else {
        throw CodexRuntimeError.turnFailed(
            result.errorMessage ?? result.status)
    }
} catch {
    presentRuntimeError(error.localizedDescription)
}

await session.shutdown()
eventTask.cancel()
_ = await eventTask.result
```

`responsesBaseURL` 必须是真正的 Responses API base，credential 只在内存和 App Server
子进程环境中存在。宿主不得把它写入 argv、runtime files、EventLog、日志或文档。

## 可选动态工具

项目特有能力通过官方 App Server `dynamicTools` extension 接入，不修改共享 runtime：

```swift
let tools = CodexRuntimeDynamicTools(
    toolsetID: "project.agent-tools.v1",
    specs: [
        CodexRuntimeDynamicToolSpec(
            name: "project_lookup",
            description: "Read one project-owned record.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
                "additionalProperties": .bool(false),
            ])),
    ],
    handler: { call in
        await projectToolHost.execute(call)
    },
    shutdownHandler: {
        await projectToolHost.shutdown()
    })
```

把 `tools` 传给 `CodexRuntimeConfiguration.dynamicTools`。工具 schema、授权、workspace
边界、执行和持久化仍由宿主负责；App Server继续拥有 agent loop 和工具选择。不得在失败时改走
旧 AgentLoop、MCP translator、shell/Python 替代实现或另一 provider。

Intatis自身的Agent hosted search也只使用这条extension：host在thread启动前把同一exact Responses
provider/model配置解析出的既有search service绑定到host-only root/child-role scope，再发布strict
query-only function。scope不在model arguments或App Server wire中；不支持的route不获得service，且不会
启用Codex built-in web search、浏览器/MCP别名或普通模型fallback。其他宿主若不具备同等exact route与
authority证据，应省略该工具而不是复制搜索实现。

## 可选结构化问题callback

宿主若已有自己的presentation owner，可把一个
`CodexRuntimeUserInputHandler`传入`CodexRuntimeConfiguration.requestUserInputHandler`。非nil时，
shared runtime只在现有单一Code/Cowork流中开启pinned App Server的
`default_mode_request_user_input`并处理official `item/tool/requestUserInput`；它不创建Plan/Default
产品模式、不注册同名dynamic tool。handler收到exact RequestID/thread/turn/item、可选verified child
AgentID和typed questions，并返回question-id→answers map；App Server把它作为原function call output继续
同一turn。当前exact schema允许一个request包含1–3题，每题2–3个mutually-exclusive options且只回一个
answer；Other是自由文本替代项，不是multi-select或附加note。宿主presenter不得扩写这套协议。

nil必须把feature显式写为false。问题/答案只在request-local callback内存中流动；secret问题/答案、
坏schema、错误answer mapping与跨root caller会在callback或wire response前fail closed。
`serverRequest/resolved`、turn terminal、child identity变化与runtime shutdown会取消pending handler。
宿主尚未具备presentation时必须保持nil，不能提供一个永不完成的callback，也不能用普通assistant文本、
MCP或旧AgentLoop模拟回答。handler是否存在属于persisted thread surface identity：从nil改为非nil时必须让
旧thread要求新session，不能在resume时注入；Intatis用handler-qualified toolset identity落实该边界。

## Runtime executable

开发宿主可以把共享 runtime kit 中当前架构的 executable 作为
`executableOverride` 明确传入：

```text
<Intatis>/.intatis/runtime-kit/0.66/CodexRuntime/arm64/codex
<Intatis>/.intatis/runtime-kit/0.66/CodexRuntime/x86_64/codex
```

host在启动时仍通过 `CodexRuntimeExecutable.verifiedVersion`核对 exact version和derivation；
同版本但不同patch identity也会拒绝。DocumentRuntime和BrowserRuntime是可选业务工具运行时，
不是启动Codex内核的前置依赖。

正式分发的App最终仍须把适配架构的exact executable放入自己的
`Contents/Resources/CodexRuntime/{active-architecture}/codex`并完成该App自己的签名/公证流程。
shipping bundle identity会拒绝`executableOverride`、env、local或PATH候选；本地共享路径只定义开发期
源码与runtime复用，不是发行fallback。

## 兼容性规则

- v1清单中的名称、参数标签和既有语义不得直接删除、改名或改成新的必填参数；
- 新配置必须优先使用带默认值的additive参数或新overload；
- 新事件可以additive加入，消费者的event switch必须保留`default`；
- source-breaking变更必须先提升
  `CodexRuntimeHostContract.publicAPIMajorVersion`并提供迁移说明；
- `pinnedRuntimeVersion`和`pinnedRuntimeDerivationID`是独立的external-runtime身份，升级它们
  不自动代表Swift宿主API发生major change；
- project-specific代码只放在消费项目的Host/Profile/Tools/UI层，不直接修改共享内核文件；
- 每次内核改动必须通过`CodexRuntimePublicContractTests`。该suite只使用public imports，
  不得增加`@testable import`。

这套合同冻结的是跨项目源码接入口，不新增Codex协议facade、第二套runtime、fallback或功能翻译层。

# Cowork 右侧 UI 跨项目接入合同

文档状态：v1 公共宿主合同
最近核对：2026-09-03
产品基线：v0.71（build 71）

## 唯一目标

`IntatisCoworkUI`只提供Intatis Cowork去掉App左侧导航后的完整右侧SwiftUI composition。它不拥有、创建、
恢复、替换或关闭宿主的session/runtime，也不注册dynamic tools。

```text
TranslatisMac runtime/ViewModel ─┐
                             ├─ state + bindings + actions
Kuzio runtime/8 tools ───────┘             │
                                           v
                              IntatisCoworkContentView
```

因此TranslatisMac继续使用自己的`CoworkViewModel`、`AppSessionRuntimeManager`、provider、bookmark、MCP和
business tools；Kuzio继续使用自己的`KuzioCoworkHarnessHostModel`、session root和每session注册的学习库
工具。复用UI不能顺便更换上述owner。

## SwiftPM

```swift
dependencies: [
    .package(path: "../../Intatis"),
]

.target(
    name: "ProjectApp",
    dependencies: [
        .product(name: "IntatisCore", package: "Intatis"),
        .product(name: "IntatisCoworkUI", package: "Intatis"),
    ])
```

公共入口为：

- `IntatisCoworkUIContract.publicAPIMajorVersion == 1`；
- `IntatisCoworkContentView`；
- `IntatisCoworkContentState`；
- `IntatisCoworkContentActions`；
- `IntatisCoworkThreadSource`；
- `IntatisCoworkInferenceOption`；
- `IntatisCoworkVoicePresentation`；
- `IntatisCoworkGoalEditDraft`。

`IntatisCoworkContentState.pendingUserInput`和
`IntatisCoworkContentActions.onSubmitUserInput`承载可选的结构化问题presentation。问题、选项与submission类型
来自`IntatisSharedUI`，不包含Codex RequestID、thread/turn/item身份或runtime handler；这些仍由宿主ViewModel
保存在request-local内存中。

宿主在自己的observable runtime model更新时重建`IntatisCoworkContentState`，把composer和inspector作为
bindings传入，并把已经存在的single-operation actions交给`IntatisCoworkContentActions`：

```swift
IntatisCoworkContentView(
    state: contentState,
    threadSource: threadSource,
    actions: contentActions,
    projectSettingsContent: optionalHostSettings,
    input: $model.input,
    showsInspector: $showsInspector)
```

`projectSettingsContent`是宿主authority的可选内容插槽；UI product拥有打开sheet的右侧交互，但不会为了
显示设置而接管宿主provider、workspace bookmark、MCP account或session配置。

## 纯 UI 边界

`IntatisCoworkUI`直接绘制并驱动下列presentation：

- session header和可选history/new actions；
- selected-agent continuous thread；
- next-model/provider/variant selector；
- attachment、voice、Send/Stop；
- pending permission与resolution；
- pending structured user input（透明描边panel、native single-selection List编号整行、多题导航、按需Other
  文本框与`⌘↩`提交）；
- Agents、Goal、Tasks、status/error rail；
- Goal edit/pause/resume/clear；
- task/submission retry；
- inspector、MCP pending-context control和host settings sheet入口。

它不得：

- import或依赖`IntatisCodexRuntime`、`IntatisAgentKernel`、`IntatisCowork`、`IntatisTools`、
  `IntatisPermission`或`IntatisMCP`；
- 引用`CoworkViewModel`、`CodexAppServerSession`或`ProviderRegistry`；
- 创建isolated `CODEX_HOME`、EventLog、ArtifactStore、workspace lease或bookmark；
- 启动/恢复/中断/关闭thread或turn；
- 注册、解释、合并或替换dynamic tools；
- 解释或扩展official question schema（例如把互斥选项改成multi-select或附加note协议）；
- 在宿主action失败时提供另一runtime、mock、cache或简化实现。

状态与action的业务真实性仍由宿主负责。UI不会把`reviewed`标签当成授权，也不会因为显示permission卡而
绕过宿主的实际approval/permission路径。

## TranslatisMac 与其他宿主

TranslatisMac的`CoworkSessionView`是当前参考适配器：它保留原`CoworkViewModel`，只把已有published state、
thread source、bindings和方法映射给`IntatisCoworkContentView`。该适配器不得重新出现第二份UI composition。

其他宿主也只允许做同类薄映射。尤其不能：

- 为减少参数创建第二套Cowork state machine；
- 复制Intatis右侧view源码；
- 用`CoworkShell`加宿主自制模型菜单冒充完整接入；
- 为复用UI把宿主既有session owner或per-session tools迁给TranslatisMac ViewModel。

## 验证

至少运行：

```sh
swift build --target IntatisCoworkUI --disable-automatic-resolution
swift test --filter IntatisCoworkUIPublicContractTests \
  --disable-automatic-resolution
xcodegen generate
xcodebuild -project Translatis.xcodeproj -scheme TranslatisMac \
  -configuration Debug -destination 'platform=macOS' \
  ENABLE_DEBUG_DYLIB=NO CODE_SIGNING_ALLOWED=NO build
```

合同测试必须使用普通`import IntatisCoworkUI`并检查target/source中没有runtime/session/tool owner。iOS
产品图仍不得出现`IntatisCoworkUI`。

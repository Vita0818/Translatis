# NEXT_TARGET

文档状态：唯一活跃目标
最近核对：2026-09-03
产品基线：v0.72（build 72）

## 目标：消除完整 SwiftPM 回归的 SharedUI 间歇性挂起

Agent `hosted_web_search`已经通过pinned Codex App Server official `dynamicTools`接回，不再是下一目标。
当前最先需要关闭的工程质量阻碍，是整仓`swift test --disable-automatic-resolution`在不同运行中曾出现的
SharedUI组合顺序间歇性静默等待：2026-09-02最终工作树运行正常退出0，但2026-09-01及更早证据曾在
XCTest async waiter中长期0% CPU等待。单次通过不能证明该竞态已经消失。

## 必须完成

1. **取得可重复、可归因的证据**

   - 为完整suite保留wall-clock timeout；超时后只读记录exact test process、当前用例（若可得）、
     `sample`栈和最近输出，不用无界等待掩盖问题。
   - 用固定测试顺序或逐步缩小的suite组合定位最小触发集合；单测单独通过不能作为组合挂起已解决。
   - 区分Swift Testing、XCTest、MainActor、AppKit全局状态、异步任务清理和测试进程退出阶段，不能从
     “最后打印的用例”直接猜根因。

2. **修复真实生命周期缺口**

   - 若根因是未结束的Task、continuation、timer、notification、MainActor工作或AppKit资源，必须由对应
     owner在tear-down/shutdown中对称取消并等待；不能用额外`sleep`、扩大timeout或强制退出进程伪装修复。
   - 不得删除、skip、串行化全部SharedUI测试来隐藏竞态。只有证据证明某组API本身要求串行全局owner时，
     才能在最窄范围加明确的序列化合同和回归测试。
   - 不改变产品renderer、thread presentation或runtime行为来迎合测试，除非复现证明同一生命周期问题也
     存在于production owner。

3. **完成稳定性验收**

   - 修复后至少连续三次运行完整`swift test --disable-automatic-resolution`，每次都在有界时间内退出0；
     同时保留直接相关focused suite。
   - 重新运行`swift build --product translatis`、XcodeGen、macOS Debug与iOS Simulator Debug构建，确认测试
     生命周期修复没有破坏产品图或iOS子集。
   - 把最小复现、根因、修复边界、三次完整结果和仍未覆盖的环境风险写入`docs/TESTING.md`与
     `docs/CURRENT_STATE.md`；没有三次有界成功前不把风险从当前状态中删除。

## 完成判据

- 有一个可解释的最小触发序列或明确的退出阶段根因；
- 修复由真实资源owner负责，不依赖sleep、无限timeout、全局skip或外部kill作为正常完成路径；
- 三次连续完整SwiftPM suite均有界退出0，相关focused测试和两端App构建也通过；
- CI保留超时与诊断采样作为回归围栏，而不是继续依赖人工观察。

## 明确非目标

- 不在本目标中重写SharedUI renderer、引入第二渲染backend或降低既有断言；
- 不把一次2026-09-02完整通过写成“已稳定”；
- 不顺带恢复per-child MCP、native OAuth/elicitation、CLI attachment/`/clear`或runtime bundling/公证；也不
  扩展已经完成的macOS `request_user_input` presenter或为CLI另造交互协议。这些仍按`CURRENT_STATE.md`
  分别保持已完成、fail closed或release-blocked；
- 不运行真实provider、读取用户凭据或产生模型调用费用。

目标完成后删除本文件或替换为下一个单一目标，不继续追加里程碑流水账。

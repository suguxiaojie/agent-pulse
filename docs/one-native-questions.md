# One Native 异步提问接入

## 范围与来源

本机 Codex 0.166.0 的共享 daemon 可以通过 `codex app-server proxy` 建立 WebSocket 连接。One Native 现有 CoreRuntime 的 `cli_agents/native/codex_runtime.py` 使用同一入口查询运行中的线程。

Codex Pulse 使用原生 Swift 实现，只启动自己的 proxy 子进程，不启动或重启 daemon，不修改 One Native、Codex 配置、Hook、账号或历史会话文件。该通道也适用于使用同一默认 Codex home／daemon 的 CLI 会话；不是通过窗口名称判断来源。

该接入不代表任意 OneNative Codex 终端都可接入。2026-11-01 本机排查确认：此前 OneNative 的适配器新建默认传入 `--no-daemon`，恢复时也仅在原线程已由共享 daemon 加载的情况下使用 `--remote`。现场独立 CLI PID 28052 确有 `--no-daemon`；默认 proxy 的控制 Socket 不存在，另一个现存 daemon 的 `thread/loaded/list` 返回空列表。该旧进程不会热迁移；切换到空 daemon、重启 Pulse 或从日志还原按钮均不能补上原请求的回答通道。

用户授权联调后，OneNative 0.7.7 在消费受管启动凭证后，为其未来 Codex 启动建立终端独立 App Server，再由 TUI 经官方 `--remote unix://…` 连接；服务沿用同一启动环境与已有配置覆盖，不复制凭据、不修改账户配置、不恢复 Pulse Hook。guardian 保持为原 TUI 的子进程，TUI 退出后停止本次服务并清理自建目录；已有共享恢复及直接手动启动保持原路径。实现位于 OneNative 的 `native/codex_surface.py` 与 `cli_runtime/host_exec.py`。

Pulse 的 `CodexSurfaceEndpoints.swift` 只读发现 `/private/tmp/one-native-codex-<UID>/surface-*/runtime.json`，拒绝非私有目录／文件、死进程、跨 UID、错误父子链及非同一 Codex 可执行文件。官方自定义 Socket 实际可能是指向私有哈希监听的链接；解析后复核目标权限及实际 peer PID／UID。端点身份包含进程启动时间与 Socket 身份，替换后创建新 epoch；只连接已有服务，不创建、恢复或开启轮次。不同端点的同一线程问题出现冲突时不显示，不把失效连接的请求路由到另一服务。回答仍使用下述带 `expectedTurnId` 的原生通道，不模拟终端输入。现场证据保存在 `.tmp/codex-grok-live/`；旧独立进程与真实新会话验收必须区分。

接口依据为本机 `codex app-server generate-ts --experimental` 导出的协议，以及 [官方 App Server 文档](https://learn.chatgpt.com/docs/app-server)。实现入口：`CodexProxyTransport.swift`、`CodexSharedQuestions.swift`、`MonitorStore.swift`。

## 显示与回答

- 只观察本地日志已识别为用户会话、且 `thread/loaded/list` 仍包含的线程；要求 `canAcceptDirectInput=true` 和可识别的原生来源，不将内部线程混入。
- 读取最新轮次和 `thread/items/list` 的原生 `agentMessage.questions`，复用桌面提问解析器识别带 `questionItemId` 的真实回答；工具输出 `accepted:true` 不是用户回答。
- 每 5 秒轮询，按轮次缓存已读项目，仅补读新项目与尾页。分页不完整、异常、混入其他轮次、断线或超过容量限制时不发布部分问题。超过 15 秒未刷新则禁止回答；断线重连使用新 epoch。
- 岛内复用现有选项、自定义文本、隐私模式与草稿控件。当前活动轮次可以直接回答；已结束轮次只引导回 One Native，不隐式开启新一轮。
- 用户显式提交后重新读取完整当前轮次，核对 epoch、线程、轮次、原问题／选项和未回答状态。只调用带 `expectedTurnId` 的 `turn/steer`，不调用 `thread/resume` 或 `turn/start`。
- 回答使用 Codex 原生 `<send_user_message_question_reply>` JSON 包装，保留问题精确 ID／正文与回答。RPC 回执不等同于送达，只有原生历史中出现精确回答才提示确认送达；其他情况明确显示受理或结果未确认。
- 写入一旦尝试，不自动重试。该进程内对同一问题的重复提交在断线重连后仍被阻止；需要回原客户端核对不确定结果。
- 不支持接管其他客户端拥有的同步审批 RPC；本轮接入的是用户报告的 `request_user_input_async`。

## 验证入口

`zsh scripts/test-shared-questions.sh` 已纳入 `scripts/test.sh`。全部模型请求均由隔离 fixture 替代；覆盖陈旧／跨轮次／已回答请求、选项变化、内部线程、加载状态、答案边界、多题、重复点击、未知回执、分页异常、WebSocket 握手／分片／ping／大小上限／关闭与方法白名单。

只读实机探针：`.tmp/shared-question-tests/transport --live` 与 `.tmp/shared-question-tests/questions --live`，只查询运行中的 daemon，不发送模型任务、回答或启动新轮次。

真实岛内点击回传需用户在真实等待中的问题上操作，不能用测试程序自动回答真实任务来代替验收。

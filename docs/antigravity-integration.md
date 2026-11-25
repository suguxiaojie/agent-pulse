# Google Antigravity 接入说明

## 覆盖范围与数据来源

Agent Pulse 支持在同一套监控中心、菜单栏玻璃面板与灵动岛界面中接入本机 Google Antigravity 三端：

1. **Antigravity 2.0 桌面端**：`/Applications/Antigravity.app` → `~/.gemini/antigravity/`
2. **Antigravity IDE**：`/Applications/Antigravity IDE.app` → `~/.gemini/antigravity-ide/`
3. **Antigravity CLI (`agy`)**：`~/.local/bin/agy` → `~/.gemini/antigravity-cli/`
4. **全局共享配置层**：`~/.gemini/config/`

接入默认关闭，可在监控中心「Antigravity」页面启用。

- **官方额度与 AI Credits**：通过可选的 `agy` CLI `statusLine` 转发采集（`~/.gemini/antigravity-cli/settings.json`）及同用户 `agy-statusline` 运行时快照。Helper 仅按白名单记录 `quota`（如 `gemini-5h`、`gemini-weekly` 及合作模型池的 `remaining_fraction`、`reset_time`、`reset_in_seconds`）、`plan_tier`、`credits`、`useG1Credits`、`model`、`context_window`、`agent_state` 与 `cwd`；**显式丢弃 `email` 及未知顶层字段**，不读取任何 `.pbtxt`、OAuth Token、Cookie 或钥匙串。AI Credits 余额与订阅比例窗口分开展示。
- **本机三端用量与成本**：`AntigravityScanner.swift` 只读扫描三端 `brain/<conversation-id>/.system_generated/logs/transcript.jsonl`，按 `step_index` 去重统计 `PLANNER_RESPONSE` 的 `input_tokens + cache_read_tokens + output_tokens`；**不读取 `thinking` 正文或 `transcript_full.jsonl`**。对已公布官方标准费率的模型（包括 Gemini 4 Neon／Carbon／Argon／Hydrogen／Orchestrator、Gemini 3.8／3.5／3.1／2.5、Claude Sonnet／Opus 5.5 及 GPT-OSS）按公开 API 单价估算等价成本，并支持同会话状态栏模型线索补全早期未写入 `model` 字段的转录步骤；未公开单价或未标明模型的步骤保留金额未知并以 `≥` 下界展示，不伪造 `$0`。
- **子代理与实时任务边界**：结合只读 SQLite `conversation_summaries.db`（识别 `nesting_depth > 0` 或非空 `parent_conversation_id` 的子代理，避免在灵动岛产生子会话幽灵卡片）、`presence/<conversation-id>.lock` 内核 `flock` 独占锁存活验证，以及可选全局生命周期 Hook。

## 配置备份、隔离与安全边界

- **全局 Hook（`~/.gemini/config/hooks.json`）**：
  - 首次写入前自动备份 `hooks.json.codex-pulse-backup`。
  - 仅管理顶层命名键 `"codex-pulse"`，保留用户及其他插件的全部命名 Hook；停用时仅移除 `"codex-pulse"`。
  - **可选 `PreToolUse` 灵动岛审批与提问回答**：开启「灵动岛审批与提问回答」时注册受控 `PreToolUse` 匹配器，结合客户端本地策略（CLI 的 `always-proceed`、桌面端的 `Turbo` 及工作区内常规读写均毫秒级放行不打扰）仅在真正需要确认的工具调用或 `ask_question` 多选／输入提问时唤醒灵动岛卡片；关闭该开关时不注册 `PreToolUse`。
  - **Fail-Safe 安全兜底与旧版本协议兼容（严禁静默自动批准）**：安装器按事件槽位显式写入 `--event <EventName>`，同时 `ClaudePulseHelper` 在 `--antigravity-hook` 模式下按 `stdin.hookEventName` → `--event` 参数 → `HookArgs` 载荷字段结构（兼容 `agy < 1.5.4` 未携带 `hookEventName` 与 `cwd` 的存量进程）三重解析事件类型；无论配置缺失、断线、2 分钟等待超时或点击「在原客户端处理」，均保证对 `PreToolUse` 输出 `{"decision":"allow"}`（交回 Antigravity 自身权限引擎处理，绝不输出空 `{}` 触发无原因拒绝，也绝不越权自动批准）、对 `Stop` 输出 `{"decision":"stop"}`、对其余事件输出 `{}`。仅当用户在灵动岛明确点击「批准一次」时才返回 `{"decision":"auto_approve"}`。
- **CLI 状态栏（`~/.gemini/antigravity-cli/settings.json`）**：
  - 首次写入前自动备份 `settings.json.codex-pulse-backup` 并保持原有文件权限（如 `0600`）。
  - 若已有自定义 `statusLine`，先将其保存至私有通道目录并在每次运行中原样转发标准输入与输出；关闭采集或停用接入时完整恢复原 `statusLine`。
- **灵动岛交互提问与工具审批**：
  - **`ask_question` 提问回答**：支持在灵动岛直接单选、多选或自由输入回答；用户提交后通过 `PreToolUse` 将确认答复直接注入当前轮次继续执行，避免原终端／桌面端重复弹窗；点击回原客户端或超时则放行交由原客户端原生弹窗处理。
  - **工具权限审批**：支持在灵动岛执行「批准一次」（`auto_approve`）、「拒绝」（`deny`）、查看完整参数 JSON 详情或一键切回原客户端（`Antigravity`、`Antigravity IDE` 或终端）处理。

## 验证入口

隔离测试脚本为 `zsh scripts/test-antigravity.sh`（已接入完整回归 `scripts/test.sh`），在临时目录覆盖：

- 多模型池额度解码（含合作池 `3p-5h`／`3p-weekly` 与秒级时间戳 `resets_at`）、OneNative 同用户 `0700` 私有 `agy-statusline/<pid>.json` 实时快照合并（兼容启动早于 Pulse 配置的存量 `agy` 会话并继承套餐／AI Credits 元数据）、过期隐藏、未来时间偏移拒绝与 `useG1Credits` 严格布尔校验；
- 内部代号模型显示名映射与未定价 `≥` 下界保护；
- 三端 SQLite 摘要解析（含 `Esc` 取消后 `CASCADE_RUN_STATUS_IDLE / CANCELING` 终态收起）、URL 编码工作区解码、子代理过滤、`presence/*.lock` 真实 `flock` 存活检测、增量转录与原子重写恢复；
- `hooks.json` 与 `settings.json` 备份／安装／卸载往返、原 `statusLine` 转发、`email` 与敏感命令剥离，以及断路情况下的 Fail-Closed 安全 JSON 输出；
- `AntigravityRuntime` 状态机、历史完成记录禁礼花保护、四端来源切换、296pt 玻璃面板双行头部与灵动岛专属浮游星核桌宠渲染。

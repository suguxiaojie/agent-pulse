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
  - **不注册 `PreToolUse`**：Antigravity 的 `PreToolUse` 若返回 `{}` 或 `"allow"` 可能绕过客户端原有的交互审批提示，因此 Pulse 仅挂载非权限覆盖型生命周期事件（`SessionStart`、`PreInvocation`、`PostInvocation`、`PostToolUse`、`Stop`），严格遵循「不自动批准」原则。
  - **Fail-Closed 安全兜底**：Antigravity Hook 同步执行且要求合法 JSON 输出。`ClaudePulseHelper` 在 `--antigravity-hook` 模式下无论配置缺失、断线或输入异常，均保证对 `Stop` 输出 `{"decision":"stop"}`、对其余事件输出 `{}`，绝不阻塞客户端执行循环。
- **CLI 状态栏（`~/.gemini/antigravity-cli/settings.json`）**：
  - 首次写入前自动备份 `settings.json.codex-pulse-backup` 并保持原有文件权限（如 `0600`）。
  - 若已有自定义 `statusLine`，先将其保存至私有通道目录并在每次运行中原样转发标准输入与输出；关闭采集或停用接入时完整恢复原 `statusLine`。
- **交互提问与审批回退**：
  - 当检测到 `ask_question` 待回复状态时，灵动岛自动切为高优「待回复」焦点，并提供按来源精准跳转的按钮（「在 Antigravity 中处理」「在 Antigravity IDE 中处理」或「回终端处理」），所有交互回答与权限批准均在原客户端完成。

## 验证入口

隔离测试脚本为 `zsh scripts/test-antigravity.sh`（已接入完整回归 `scripts/test.sh`），在临时目录覆盖：

- 多模型池额度解码（含合作池 `3p-5h`／`3p-weekly` 与秒级时间戳 `resets_at`）、OneNative 同用户 `0700` 私有 `agy-statusline/<pid>.json` 实时快照合并（兼容启动早于 Pulse 配置的存量 `agy` 会话并继承套餐／AI Credits 元数据）、过期隐藏、未来时间偏移拒绝与 `useG1Credits` 严格布尔校验；
- 内部代号模型显示名映射与未定价 `≥` 下界保护；
- 三端 SQLite 摘要解析（含 `Esc` 取消后 `CASCADE_RUN_STATUS_IDLE / CANCELING` 终态收起）、URL 编码工作区解码、子代理过滤、`presence/*.lock` 真实 `flock` 存活检测、增量转录与原子重写恢复；
- `hooks.json` 与 `settings.json` 备份／安装／卸载往返、原 `statusLine` 转发、`email` 与敏感命令剥离，以及断路情况下的 Fail-Closed 安全 JSON 输出；
- `AntigravityRuntime` 状态机、历史完成记录禁礼花保护、四端来源切换、296pt 玻璃面板双行头部与灵动岛专属浮游星核桌宠渲染。

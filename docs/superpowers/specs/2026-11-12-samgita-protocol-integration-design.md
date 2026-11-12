# Samgita 协议集成（第一期）设计

日期：2026-11-12

## 1. 意图

`docs/design.md` §4 规定：所有跨 agent 通信统一使用 samgita_protocol。本期是集成的起点，**两条线并行，各自跑通即可**，后续还有大量工作（coordinator 闭环、Sigma、把 Samgita Task 交给本机 agent 执行等）。

- **线 A：连上 Samgita。** 本机 Synapsis 注册为 Samgita Agent，用 samgita_protocol 收 Samgita 推来的项目事件，并通过 Samgita management API 回报。
- **线 B：本地 agent 管理。** 在 Synapsis 网页上管理本机 agent：看进程状态、起停，并直接与它对话。第一个接入的是 Codex；Sigma 正在同步开发 samgita_protocol host，本期做完后接入；将来还会接入更多 agent。

## 2. 目标 / 非目标 / 反目标

**目标**

- A：Samgita（本机已运行，`http://10.100.10.28:4870/`，源码在 `../Samgita`）能连上 Synapsis 的 `/app-server`，完成 `connection/initialize`（schema `1.0`），投递 `project_events.v1` 事件并查询状态；Synapsis 能用 Bearer 凭证 `POST /api/agent/connect`，并按 management API 对派给自己的 Task 完成 claim → start → progress → report。
- B：网页上有"本地 Agent"页面：列出本机 agent 及其进程状态，能启动/停止；能对 Codex 开会话（thread）、发消息（turn）、看流式输出、打断；能列出并恢复已有会话。
- B 的上层（页面、会话状态、PubSub 事件）只依赖统一的本地 agent 接口，Codex 是第一个实现。

**非目标（本期不做）**

- 不把 Samgita 事件/Task 交给本机 Codex 执行（两条线不接起来）。
- 不做 coordinator（manager）的拆解/assign 逻辑（P6）。
- 不写任何 Sigma 代码；只保证接口不写死 Codex。
- 不做审批 UI / 权限门（`docs/design.md` §5，默认 yolo）。
- 不做远端设备、SSH。
- 不修改 `../Samgita` 仓库。
- 不做 attempt 的重启恢复（持久执行日志、rebind、对账）。

**反目标（技术上能跑但算失败）**

- 回 `acceptance: durable` 但事件实际只在内存里；Synapsis 重启后同一 `event_id` 查不到或被当成新事件。
- 把 Codex 塞进现有 Backplane `Conversation` 会话页，或让统一接口直接暴露 Codex wire 形状，导致接 Sigma 时要改页面。
- 本地绕过上游包的缺陷而不提 issue。
- 在日志里打印 Bearer 凭证、Codex 原生 payload（可能含密钥）。

## 3. 约束

- 依赖 hex 上已发布的 `samgita_protocol`、`samgita_protocol_websocket`、`samgita_codex_driver`（当前均为 `0.4.0`，<1.0 为实验版本；`samgita_protocol_codex` 由 driver 传递依赖）。
- 遵守 `AGENTS.md`：无数据库；持久状态经 `synapsis_data` 的 Concord / TOML store API；进程受监管、所有外部操作有显式超时、处理 `:DOWN`；外部进程用 `Port`（Codex driver 的 Stdio transport 自带进程管理，视为满足）；结构化日志、不记密钥；server/web 只是展示层，依赖向内。
- 上游问题按 `upstream-issue-routing` 处理：阻塞即停该任务，不本地绕过。
- 本机 `codex-cli 0.167.0`（`~/.local/bin/codex`）。
- Samgita 只允许**回环地址**走明文：本机演示时 Samgita 的 destination 为 `ws://127.0.0.1:4657/app-server`，并在 Samgita 运行环境的 `SAMGITA_EVENT_DESTINATIONS` 中设 `"allow_insecure": true`、`"addresses": ["127.0.0.1"]`；出站凭证经 `SAMGITA_EVENT_CREDENTIALS` 提供。这是 Samgita 侧运维配置，不改其代码；Synapsis 侧需给出可照做的操作步骤。
- Synapsis 端点运行在 Gaoxy（`Gaoxy.PhoenixAdapter`，`gaoxy_websock_adapter`），`samgita_protocol_websocket` 的 Plug 基于 Gaoxy/WebSockAdapter，可挂到现有 endpoint。
- 测试不连真实 Samgita、真实 LLM；Codex 用 driver 提供的脚本化/假 transport 或 fake app-server 测试。真实 Samgita/Codex 只用于手工演示。

## 4. 已定的部分

### 4.1 线 A：Samgita 连接

方向（来自 Samgita `docs/redesign/integrations/synapsis.md`）：

```
Samgita ──wss/ws──▶ Synapsis /app-server     （Samgita 是协议 client，Synapsis 是 host）
Synapsis ──HTTPS/HTTP──▶ Samgita /api/agent/* （Synapsis 是 management API 客户端）
```

- **协议 host**：在 Synapsis endpoint 挂 `SamgitaProtocolWebSocket.Plug` 于 `/app-server`，带入站认证（Samgita 出站凭证，Bearer）。Handler 实现 `SamgitaProtocol.Handler`，本期只声明 `project_events.v1`，`methods/0` 覆盖该组全部请求方法：`project/event.receive`、`project/event.status`、`project/event.report`（字段/结果见 Samgita `docs/redesign/protocol-phase-2.md`）。其余组不声明；未支持方法显式报错。
- **持久 inbox**：事件以 `event_id` 为键写入 Concord（经 `synapsis_data` 新增的 store API），写入提交后才回 `acceptance: durable`。同 `event_id` 重投（新 `delivery_attempt_id`）去重；同 `event_id` 内容不同则拒绝。`project/event.status` 从 inbox 读取。重启后状态可查。
- **事件处理（本期）**：只记录并展示，不执行。收下后 `processing_status` 为 `pending`；网页上提供"标记已处理"操作，由操作者把状态改为 `completed`（附说明文字）。Samgita 每次投递/查询都新开连接、不常驻，因此本期不发 `project/event.updated` 通知。Samgita 收到 `durable` 后把投递置为 `accepted` 且不再轮询，所以"标记已处理"在本地完成后，经 REST `POST /api/agent/projects/:pid/deliveries/:id/report` 回报 `completed`（连接不可用时只在本地完成并提示）。`project/event.report` 作为协议方法照常实现（记录 decision/result，重复相同报告幂等、不同报告 `conflict`）。Synapsis 不自动声称已处理（用户决定）。处理状态与 report 记录存在 inbox 条目中。
- **management API 客户端**：配置 Samgita base URL 与入站 Bearer 凭证；`POST /api/agent/connect` 取得 connection UUID，后续调用带 `x-agent-connection`。覆盖本期需要的接口：project context、Task 列表/详情、execution session 创建（claim 前必需）、`claim`、attempt `start`/`renew`/`progress`/`report`。HTTP 调用有超时，用 `Gaoxy.Test` 测试。
- **Task 推进方式（用户决定）**：由操作者在网页上逐步点按钮（claim → start → progress → report），手填进度摘要与回报内容（含是否 `effects_resolved`）。Synapsis 不自动 claim 或回报。
- **租约续期**：Samgita attempt 租约为 120 秒（`Samgita/apps/samgita/lib/samgita/attempts.ex`），claim 后由受监管的后台进程自动 `renew`，直到 report 或失败；续期失败在页面上显示。
- **重启恢复（用户决定：本期不做）**：attempt 状态只在内存中。Synapsis 重启后重新 connect 得到新 connection，旧 attempt 留在 Samgita 直到租约过期；不做持久执行日志、owner proof 存储、rebind 与对账（以后把 Task 交给本机 agent 执行时再做）。同一进程生命周期内，不确定结果的写请求以相同 `command_id` 和请求体重试。
- **配置**：Samgita URL、凭证引用、入站凭证摘要等存 TOML（`Synapsis.Config.Store`）；凭证值使用 `synapsis_data` 已有的加密字段机制，不明文落盘、不进日志。
- **网页**：一个 Samgita 连接页：配置 URL/凭证、显示 connect 状态与当前 connection、收到的事件列表（含 acceptance/processing 状态）、派给本机的 Task 及其 attempt 状态。

### 4.2 线 B：本地 agent 管理

- **统一接口**（行为/协议由 builder 定形）：覆盖
  - 进程：启动、停止、状态（stopped / starting / running / crashed + 最近错误）；
  - 会话：列出 thread、开 thread、读取/恢复 thread；
  - 回合：开 turn（文本输入）、steer、interrupt；
  - 输出：turn started/completed、消息增量等，统一为 Synapsis 自己的领域事件，经 `Synapsis.PubSub` 广播。
  - 接口词汇向 samgita_protocol `sessions.v1` / `streaming.v1` 对齐（thread/turn/item），使将来 Sigma（原生 samgita_protocol host，经 `samgita_protocol_websocket` client 接入）是"另一个实现"而非新模型。
- **Codex 实现**：用 `SamgitaCodexDriver.Session` + Stdio transport 拉起 `codex app-server --listen stdio://`，进程挂在 Synapsis 的监管树下。Stdio transport 默认不继承 `HOME`，配置中显式给出 `codex_home`（默认 `~/.codex`，以复用本机登录）与 `HOME`；它依赖 `python3` 管理进程组（本机已有）。Codex 需要回应的交互请求（approval 等）在本期按 yolo 自动同意（与 `docs/design.md` §5 一致），并在会话中显示发生过的交互。
- **状态归属**：
  - 本机 agent 的定义（种类、可执行文件路径、cwd、环境变量）存 TOML。
  - 运行状态在监管进程中；Synapsis 重启后按配置决定是否自动拉起（默认手动启动）。
  - Codex thread 历史以 Codex 自身为准，通过 `thread/list`、`thread/read`、`thread/resume` 取回；Synapsis 不复制存储 transcript。
- **网页**：新增"本地 Agent"页面，左侧 agent 列表（状态 + 起停），右侧会话列表与对话区（输入、流式输出、打断）。沿用现有 DuskMoon / 会话页视觉风格。不复用 Backplane `Conversation` 会话页。

### 4.3 代码组织（我的决定）

- 新增 umbrella app `synapsis_samgita`：线 A 的协议 Handler、inbox 服务、management API 客户端、连接监管。依赖 `synapsis_data`、`synapsis_core`。
- 新增 umbrella app `synapsis_local_agents`：线 B 的统一接口、Codex 实现、进程监管。依赖 `synapsis_data`、`synapsis_core`。
- `synapsis_server` 挂 `/app-server` Plug（依赖 `synapsis_samgita`）；`synapsis_web` 新页面依赖两个新 app。
- `synapsis_data` 只增加数据 API（inbox 记录、两类 TOML 配置 schema），不含运行时逻辑。

## 5. 留给 builder

- 统一接口的具体形状（behaviour、struct、事件命名）、模块划分、监管树结构。
- Codex driver 事件到统一领域事件的映射细节；driver 未覆盖的 Codex 通知如何降级显示。
- inbox 的 Concord key 设计与保留策略（在 ADR-006 约束内）。
- 页面细节布局、路由路径、导航入口位置。
- Samgita 侧演示配置的操作文档写在哪里（建议 `docs/` 下一页简短操作说明）。

## 6. 完成标准（可演示场景）

**A**

1. 按操作说明在 Samgita `/agents` 注册本机 Synapsis（protocol `samgita` / `1.0`，transport `websocket`，advertised `project_events.v1`），配置 destination 与凭证，绑定到一个 Project 并设为 responsible manager。
2. Synapsis Samgita 页配置 URL 与入站凭证，connect 成功并显示 connection。
3. 在 Samgita 触发一个项目事件 → Synapsis 页面出现该事件，`acceptance: durable`；Samgita 侧查询状态一致。
4. 重启 Synapsis 后，同一事件状态仍可查；重投不产生第二条记录。
5. 在事件上点"标记已处理" → Samgita 侧查询状态为 `completed`。
6. Samgita 中把一个 Task assign 给本机 Synapsis → Synapsis 页面可见 → 操作者逐步点 claim/start/progress/report（report 时 `effects_resolved: true`），过程超过 2 分钟租约不丢 → Samgita 中 Task 进入 `awaiting_review`。

**B**

1. "本地 Agent"页看到 Codex（stopped）→ 启动 → running。
2. 新建会话，发消息，看到流式回复；长回复中途打断，回合显示 interrupted。
3. 刷新页面/重启 Synapsis 后能在会话列表中找到并恢复该会话继续对话。
4. 停止 Codex → stopped；Codex 进程意外退出时页面显示 crashed 与原因。

**通用**：新增模块有聚焦测试；`mix test`、`mix compile --warnings-as-errors`、`mix format --check-formatted` 通过；`devenv processes restart synapsis` 后 `/api/health` 就绪。

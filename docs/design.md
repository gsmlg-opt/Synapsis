# Synapsis 设计（2026-11-10 重置）

本文取代此前的 OpenClaw 工具对齐计划及历史 PRD/设计/计划文档（均已删除，可在 Git 历史中查阅）。

## 1. 定位

Synapsis 是一个**常驻的个人 agent**，每台机器运行一个实例，通过 Web UI 使用。

- 管理本机的设备与数据资源、软件升级、代码项目。
- 与开发 agent（Codex、Sigma）交互，把开发工作委派给它们。
- 接入控制平台 [Samgita](https://github.com/gsmlg-opt/Samgita)，接受项目级的统一管理。

OpenClaw 只作为**产品形态参考**（常驻、记忆、技能、自动化、常用工具），不对齐其工具清单，也不以其行为作为验收标准。不做 Telegram/Slack 等消息渠道。

## 2. 运行时

- Agent 执行统一使用 Backplane 系列（`backplane_agent_runtime`、`backplane_ai_protocol`、`backplane_mcp_protocol`、`backplane_skill_protocol`）。会话回合由 Backplane `Conversation` 执行。
- Skills、MCP、Memory 与 Sigma 等其他 Backplane agent 共享相同的运行时代码和调用方式，Synapsis 不另造一套协议。
- 存储沿用 ADR-006：会话进程是在途回合的读权威，Concord 保存每回合快照，配置为 TOML，记忆为文件。

## 3. 工具范围

| 档位 | 工具族 |
| --- | --- |
| 启用 | 本地命令与补丁（`exec_command`/`write_stdin`/`apply_patch`/`view_image`）、filesystem、进程查看、web fetch/search、memory、skills、MCP、子代理协作、ask_user、会话状态/摘要、automations/heartbeat |
| 暂缓（不默认启用） | browser、会话目录/历史/状态、Code Mode |
| 删除 | 其余全部 |

新增工具需要说明它服务于第 1 节的哪个用途。

## 4. 委派与 Samgita

所有跨 agent 通信统一使用 **samgita_protocol**。

- **项目级工作走 Samgita**：每台 Synapsis 都注册为 Samgita Agent。
  - 每个实例都是 executor（`worker`），声明本机能力（如 `device:<hostname>`），claim 并执行派给自己的 Task。
  - 每个项目由一个实例担任 coordinator（`manager`）：接收 `project_events.v1`，拆解 Task 树，assign 给 Codex/Sigma/其他 Synapsis。
  - `reviewer`（自动验收）默认不授予，由用户人工验收。
- **日常小活直连**：从 Web UI 直接委派给本机的 Codex（`samgita_codex_driver`）或 Sigma（需 Sigma 实现 samgita_protocol host）。
- 设备管理只针对本机；SSH 查看远端设备状态以后再做。

## 5. 权限

默认 yolo，本期不做审批。以后的方向：危险动作交给专门的 agent 执行；用户授意的操作直接通过，agent 自行决定的操作才交给用户裁决。

## 6. 阶段

| 阶段 | 内容 | 依赖 |
| --- | --- | --- |
| P1 | 删除范围外工具、夹具、vendored 依赖与死测试；`mix test` 全绿 | — |
| P2 | 主链路冒烟：Web UI 会话中读/改文件、跑命令、查网页、写记忆均真实成功 | P1 |
| P3 | 常驻能力：automations、heartbeat、memory、skills 端到端 | P2 |
| P4 | Codex 直连：Web UI 委派本机 Codex | P2 |
| P5 | 接入 Samgita：connect、`project_events.v1`、executor claim/report | P2 |
| P6 | coordinator 闭环 | P5；Samgita design §10（assign、结果通知）实现 |
| P7 | Sigma 直连 | Sigma 实现 samgita_protocol host |

P4 优先于 P3/P5。上游阻塞按 `AGENTS.md` 的依赖规则提 issue，不在本地绕过。

## 7. 工作方式

- 每个阶段写一份简短计划；完成标准是可演示的用户场景，而不是能力清单的覆盖率。
- 每批改动运行相关测试；阶段结束时 `mix test` 必须全绿。
- 文档只记录当前事实与决策，不记录逐批流水证据。

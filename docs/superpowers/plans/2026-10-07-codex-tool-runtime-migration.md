# Codex Tool Runtime Migration Implementation Plan

> **For agentic workers:** 使用 `subagent-driven-development` 或 `executing-plans` 按任务执行；独立任务并行，存在依赖的任务串行。任务使用 `- [ ]` 跟踪。所有开发 worktree 放在 `.trees/<branch-name>`。

**Goal:** 删除 Synapsis 现有全部内置工具及旧执行内核，以 `backplane_agent_runtime` 的 Codex profiles 作为唯一工具定义、准入与执行机制。

**Architecture:** Synapsis 保留 session、Daemon、配置、Provider、Concord、workspace 和 UI；Backplane `Conversation` 成为每个运行中对话回合的唯一 provider/tool 执行 owner。宿主适配器提供存储、权限、事件投影和服务能力，Code Mode、动态 MCP、子代理共用同一授权与生命周期。

**Tech Stack:** Elixir/OTP 28、Phoenix LiveView、Concord.Turso、`backplane_agent_runtime`、现有 `backplane_ai_protocol` / `backplane_mcp_protocol`、Linux command backend、Deno Code Mode、DuskmoonBundler。

**状态：** 待评审开发计划；本轮仅新增本文件，未修改运行代码、依赖或配置。完整工具体系是本计划的范围假设；尚未指定另一个 Codex 版本。

---

## 1. 当前证据与迁移基线

调查时间：2026-10-07。Synapsis：`main` / `a5c5ea8`，调查开始时工作区干净。

| 项目 | 当前事实 | 对计划的影响 |
| --- | --- | --- |
| 内置工具 | `tool/builtin.ex` 注册 34 个；`computer` 已禁用 | 全部旧名称退出可执行 catalog；不能只更换文件工具 |
| 执行入口 | QueryLoop、Worker.IOHandler、ToolDispatcher、Sandbox reverse call | 必须收敛全部入口，不保留旁路 |
| Provider | `backplane_ai_protocol 1.5.0`，已有 canonical codec 和工具名称编码 | 复用 transport，新增 runtime adapter，不复制 provider HTTP/SSE |
| MCP | `backplane_mcp_protocol 0.6.2`；实际代码不是旧文档的 anubis_mcp | 复用 MCP transport，替换动态工具 catalog 接入 |
| Runtime | Synapsis 尚未依赖 `backplane_agent_runtime` | 先验证 artifact，再增加依赖 |
| 可用 artifact | Hex 最新查询为 `1.10.11`；相邻源树 package version 为 `1.9.0` | 发布包与邻接工作树分开记录，不以本地 version 推断发布内容 |
| Codex pin | runtime inventory 指向 `46fdd5ef39735f4159cdcf0ec5e85c10521494e5` | 相同性按此 pin 的名称、schema、grammar、行为验证，不宣称等于滚动最新 Codex |
| 上游验证状态 | `1.10.11` artifact 的 `EMBEDDING.md` 包含 R22 未闭环警告；有关源码与邻接源树一致 | artifact 存在不代表迁移门槛通过 |
| 存储 | `Session.Store.commit_turn/4` 原子保存 turn + meta；旧 Executor 的 `persist_tool_call` 是 no-op | 需要独立执行意图记录，不能把现有整轮快照包装后宣称 durable runtime |

上游文档 `docs/agent-runtime/codex-tools/runtime-repairs-validation.md` 报告 Linux runtime suite **510 tests / 3 failures**：确认未启动的 workspace/capacity 拒绝，以及 ambiguous launch 的旧 continuation 预期。本轮核对文档和 artifact，没有重新运行该 suite；这个数字是上游报告，不是本轮测试结果。迁移不能绕过 `unknown_outcome`、弱化回归，或沿用此前修复批次的成功证明。

候选 `1.10.11` Hex release API checksum：`ea452d3486a6693f524353deb4dbf55ac93924606814470731186c39ba9857e0`。实施时重新获取最终版本并核对，不将本调查值当作未来版本的 checksum。

```sh
curl -fsSL https://hex.pm/api/packages/backplane_agent_runtime/releases/1.10.11
gh api repos/gsmlg-opt/backplane/commits/main --jq '.sha'
```

权威参考：当前源码、ADR-006、ADR-008，以及 runtime 包的 `README.md`、`CODEX.md`、`EMBEDDING.md`、`PERSISTENCE.md`、`SCHEMAS.md`、`priv/codex/profile.json`、`source-inventory.json`。现有 `docs/prd/tool_system.md` 与 `05_TOOLS.md` 有旧数据库、工具数量和执行方式描述，不能直接作为实现依据。

## 2. 方案选择和明确边界

| 方案 | 优点 | 代价 | 结论 |
| --- | --- | --- | --- |
| Conversation 管理完整回合，Worker 保留 session 外壳 | 嵌套调用、动态 catalog、交互等待、子代理、预算、取消共用上游机制 | 需要 provider/store/event adapter，修订回合内部 owner 边界 | **推荐，用于完整工具体系** |
| 保留 QueryLoop，用公共 Execution API 替换工具 | 本地命令、补丁接入范围较小 | Code Mode callbacks、nested settlement、交互暂停、catalog commit 和 cleanup 需要宿主重新实现 | 仅适合明确缩小到核心编码工具的项目 |
| 旧 Registry/Executor 包装新工具 | 初期改动较少 | 两套授权、执行和恢复逻辑长期并存；旧旁路仍存在 | 不采用 |

完整体系按宿主能力启用，不将所有定义无条件发送给模型：选用 `:configured`，组合 local、interactive、collaboration_v2、extensions、dynamic、code_mode、services。V1 collaboration、Backplane compatibility-only web aliases 和 provider-hosted `web_search` 只在明确需要时启用，不把 inventory 中所有条目当作默认工具列表。

服务 profiles 需要 web/image host adapters 与凭据，dynamic plugins 需要安装/审批 adapter，interactive context工具需要可信 token/readiness来源。本计划包含这些适配接口与 fake-service契约测试；有真实宿主能力才宣告相应profile可用。当前 Code Mode `wait` 是 generator continuation，本计划不能将它宣称为当前 Codex所有运行中cell调度语义。与指定客户端的额外差异须通过上游契约测试处理。

宿主承担业务服务；删除的是旧 model-callable tools 和旧执行内核。记忆、workspace、Daemon inbox、技能、会话历史继续存在，通过 Codex extension host adapters、动态 MCP 或提示上下文使用。不能为删除的旧名称保留可执行别名。

## 3. 目标调用与持久化模型

```text
用户 / CLI / LiveView / Daemon
  -> Synapsis Session.Worker（session 身份、输入队列、live view、turn snapshot）
  -> Synapsis Runtime.SessionAdapter（run 创建、订阅、取消、resolve）
  -> Backplane Conversation（一个 active run，一个回合执行 owner）
       -> Runtime.ProviderAdapter -> 现有 Synapsis.Provider / AiProtocol.Codec
       -> Codex.profile -> ToolCatalog -> Execution commit -> Codex backend
            -> LocalCommand / ResourceRegistry / CodeMode / MultiAgent
            -> MCP、memory、skills、web/image 等宿主 adapters
       -> Runtime.StoreAdapter -> synapsis_data Runtime.Store -> Concord.Turso
  -> Runtime.EventMapper -> Synapsis live parts / PubSub -> 原子 turn snapshot
```

Worker 与 Conversation 不能同时推进同一 provider/tool 回合。Worker 是 session 的展示/输入 authority；Conversation 是 active run 的执行 authority。迁移时删除旧 graph/QueryLoop 在该链路里的 provider/tool 调度，不额外保留第二个 conversation controller。Daemon 仍经 Session.Worker 运行，不能直接调用 backend。

### 数据层边界调整

- 在 `synapsis_data` 新增 data-only `Synapsis.Runtime.Store`，只提供 Concord CAS、load、atomic transaction 和 fencing；不依赖 runtime 包，不执行工具。
- 在 `synapsis_agent` 实现 `Backplane.AgentRuntime.Store` adapter，依赖 runtime 包并调用上述 data API，避免 runtime concerns 下沉到 data 或产生 app cycle。
- 建议 namespace：`runtime/runs/<run_id>/aggregate`。在一个 aggregate 中原子保存 run、revision、incarnation、transition、effects、outbox；通过 Concord.Turso 条件事务校验 expected revision/incarnation。具体编码遵守 runtime conformance，不拆成非原子 read-then-write。
- 执行意图记录与 session transcript 分开。意图提交必须确认后才执行外部副作用；UI delta 仍实时广播，完整 turn + session meta 仍在 turn boundary 保存。
- 修改 ADR-006/guardrails：允许独立的 runtime execution journal；原有“durable session state 只有 turn snapshot”不再被误用为禁止必要的执行意图记录。此项是必要的架构调整，应先评审再实现。
- Store acknowledgment 丢失时 load/reconcile；不盲目重试 commit 或工具。重启提升 incarnation，保留 dispatched/unknown identities，等待宿主处理，不自动重放 mutation。
- 序列化只包含身份、状态、预算、效果证据；不持久化 PID、Port、closure、registry 对象、credentials 或 grants。真实 Concord backend 通过 `StoreConformance` 后才能声明 durable；ETS 仅用于测试。

### 权限与隔离

- 由宿主 policy 生成精确 run/caller/tool revision grants。Runtime 执行 schema validation、approval 和 invocation fencing；宿主保留现有 deny/无人值守策略语义，最终退出旧 Gateway/Grant 实现。
- 审批绑定 run、incarnation、tool revision、argument digest 和 interaction ID；拒绝、过期、重复、跨 session 回答均不能 dispatch。
- `exec_command` 不是 `bash` 的 read-only 替身。read_only/reflect/heartbeat 等 profile 不授予通用写入 shell；确实需要只读命令时，必须先具备宿主 OS 只读隔离证明。
- LocalCommand 不提供 OS sandbox；PathGuard 限制 cwd/patch/image 路径不能限制 shell 的全部文件与网络访问。复用现有 sandbox transport 不等于已实现 OS 隔离。生产安全 profile 需要具体 OS sandbox backend 与越界/网络拒绝测试；不能只靠命令字符串过滤。
- Linux LocalCommand/Code Mode 的 `/proc`、`setsid`、`kill`、Coreutils、Deno readiness 必须可验证。当前 `tty: true` 会拒绝；不承诺 PTY/macOS/Windows parity。若这些能力成为交付要求，先按上游 issue 流程处理缺口。
- command session和cell归属run，在run终止时清理；不以较长的Session.Worker生命期证明命令可以跨terminal run继续。若产品要求跨run存活，先设计和验证上游资源转移契约。

## 4. 工具退役与能力去向

| 当前旧入口 | 新入口/能力 | 验收重点 |
| --- | --- | --- |
| file_read、grep、glob、list_dir | exec_command 调用 rg/sed/ls 等 | 没有额外发明 Codex 不包含的旧文件工具；权限范围明确 |
| file_edit、file_write、multi_edit、file_delete、file_move | apply_patch；必要的 shell 操作经 exec_command | freeform grammar、rename、局部/不确定 mutation 证据 |
| bash | exec_command + write_stdin | command session/cursor、输出截断、stdin、timeout、取消和 cleanup |
| todo_write、todo_read、enter_plan_mode、exit_plan_mode | update_plan；plan mode 由宿主会话策略管理 | todo 数据显式迁移；update_plan 不自动扩权 |
| ask_user | request_user_input / request_user_input_async | root/subagent/无人值守资格与回答归属 |
| task、teammate、team_delete、send_message | collaboration_v2 spawn/send/followup/interrupt/list/wait | 父子身份、独立 run、预算/权限继承、取消清理 |
| agent_send、agent_ask、agent_reply、agent_handoff、agent_discover、agent_inbox、agent_status | Daemon 保留宿主服务；active child 交互用 collaboration_v2；其他信息经 context/extension adapter | 不把持久 Daemon 等同于短期子代理；handoff 语义需要新的业务流程回归 |
| skill、memory_save/search/update、session_summarize | Codex skills/memories/history extension host adapters；摘要通过宿主 hook | 持久业务后端不换成 ephemeral reference state |
| sleep | clock::sleep | deadline 与取消语义 |
| tool_search + mcp:* 动态 tools | Codex dynamic profile + ToolCatalog | 下一 provider batch 生效；失效、撤权、同名替换受 revision fence 保护 |
| @synapsis/ VFS | workspace 真实文件投影 + 宿主导入/刷新 | 迁移前确定读写同步；不把 patch 操作当成理解虚拟 URI |
| computer（已禁用） | 删除旧入口；本计划不新增电脑控制服务 | catalog 中不出现假可用能力 |

workspace 方案：向项目内受控目录投影当前 session 有权限访问的文档；模型收到实际路径。使用现有 Projection/FileDocuments 服务，验证写入后回收、索引刷新、冲突和权限。若现有 projection 无法安全写回，相关功能阻塞并走上游/架构评审，不用裸复制冒充双向同步。只读阶段不得宣称 workspace 编辑已经迁移。

## 5. 文件职责和允许修改范围

新模块名均为本计划拟新增，现有路径为当前已核对路径。

| 所属 app | 新增或修改 | 职责 |
| --- | --- | --- |
| data | 新增 `lib/synapsis/runtime/store.ex`；修改 toolset/toolsets、part/tool_use、part/tool_result | execution aggregate data API、显式配置迁移、structured result 保留 |
| agent | 新增 `lib/synapsis/runtime/{session_adapter,store_adapter,provider_adapter,catalog,policy,event_mapper}.ex` | 单一运行 owner 接入、store/provider 契约、catalog/权限、domain 投影 |
| agent | 新增 `runtime/{interactions,extensions,mcp_adapter}.ex` | 交互 routing、持久业务扩展、动态 MCP host callbacks |
| agent | 新增 `runtime/services.ex`，以及所选 OS sandbox 的 command host adapter | web/image/plugin/context capabilities、可信运行环境；只启用已验证backend |
| agent | application、session supervisor/worker/io_handler/config、query_loop*、nodes/tool_*、daemon/toolsets/execution、heartbeat/local_scheduler | 替换全部入口、监督/预算、无人值守 profiles |
| core | config、agent/resolver、prompt_builder、tool*；复用 memory、skills、agent messaging 服务 | 更新默认配置和 prompts，删除旧工具内核，保留业务服务 |
| provider | `lib/synapsis/provider/{message_mapper,event_mapper,tool_name,adapter}.ex` 及对应 tests | function/custom定义、freeform原始输入/历史保真、Provider名称映射；复用现有transport |
| mcp | `lib/synapsis/mcp/server.ex` 及 facade | transport lifecycle 和 discovery events；不能反向依赖 agent |
| sandbox | `lib/synapsis/sandbox/bridge.ex` | 注入 session/run 绑定的 dispatcher；删除旧 yolo/missing-session 绕过 |
| workspace | workspace/projection/file_documents/permissions；删除空 workspace/tools | 文件投影，权限与同步 |
| server/web/cli | session channel/controller、health controller、agent tools/daemon/sessions UI、MCP UI、CLI SSE display | 接入新事件和 catalog，历史只读兼容 |
| repository | mix.lock；agent mix.exs；devenv.nix；Docker/release/CI 中实际运行环境文件 | 包版本、Deno/Coreutils/sandbox readiness；不修复无关 PostgreSQL 遗留配置 |
| docs | ADR-006、ADR-008、04_BOUNDARIES、05_TOOLS、07_AGENT_SYSTEM、GUARDRAILS、tool_system PRD | 更新最终行为和边界；AGENTS.md 只做过期工具约束的最小更正，不放计划 checklist |

只修改以上迁移相关代码和对应测试。Mixin/Devenv 构建串行；测试按文件/路径限定。无关失败记录并停止该验证，不修复范围外问题。发布、push、生产部署是后续独立交付范围。

## 6. 分阶段任务与依赖

### Task 0：锁定 artifact、契约和上游准入门槛

**文件：** 新增 `apps/synapsis_agent/test/synapsis/runtime/artifact_contract_test.exs`、`test/fixtures/runtime/codex_contract.json`；准入后修改 `apps/synapsis_agent/mix.exs` 与 `mix.lock`。

- [ ] 读取 Hex 发布元数据并下载指定 artifact，记录 package version、checksum、profile/source pin；验证最终锁文件与 artifact 一致，不使用本机绝对 path dependency。
- [ ] 复现文档所列 command lifecycle 问题，以及 direct/nested mutation 的 unknown outcome；区分 confirmed non-start 和已可能 dispatch。
- [ ] 复现后先查已有 issue；缺失则在 `gsmlg-opt/backplane` 创建 `[internal]`、type Bug、label `internal request`、severity blocker，附 Synapsis remote/branch、最小复现和期望。在适配调用点标记 `# TODO(upstream): ...`。阻塞执行切换；其他无依赖工作继续。
- [ ] 修复发布后更新到该**已验证版本**，跑 artifact contract 和上游 package verifier。`1.10.11` 是候选基线，不能因当前最新就跳过门槛。
- [ ] 生成工具 contract fixture：canonical names、JSON schemas、freeform grammar、profile exposure conditions；失败应清晰指出缺失/重复/漂移条目。

**验收：** artifact、锁文件、契约一致；确认未启动可安全拒绝、未知执行不可继续成成功；package verifier 通过。上游 suite 只在隔离的 runtime package 环境跑，不跑 Backplane 全 umbrella。

### Task 1：数据层 execution journal 和持久 store adapter

**文件：** data/runtime/store；agent/runtime/store_adapter；新增 `apps/synapsis_data/test/synapsis/runtime/store_test.exs`、`apps/synapsis_agent/test/synapsis/runtime/store_adapter_test.exs`；ADR-006/GUARDRAILS。

- [ ] 先写 CAS 冲突、重复提交、atomic record、旧 incarnation 拒绝测试，证明 read-then-write 不能满足合同。
- [ ] 实现单 aggregate 条件事务，提供 commit/load/fence data API；Store adapter 实现 `mode/capabilities/new/load/store/acknowledge_commit/fence` 对应 callback。
- [ ] 在**真实 Concord.Turso** 上运行 `StoreConformance`，覆盖 restart、失败注入、dependent effect count。不得只用 fake store 宣称持久化成功。
- [ ] 测试“提交成功但 reply 丢失”后 load/reconcile，unknown mutation 不重放；对编码后的 atom/string keys 做 round-trip 测试。
- [ ] 描述实际事务/flush/power-loss acknowledgment 边界，修订 ADR 和 guardrails；保留 session snapshot 的 broadcast-before-turn-snapshot 语义。

**验收：** 未确认的 journal commit 后，工具/Provider side effect 次数为 0；重启、revision/incarnation fencing 和真实 backend conformance 全通过。

### Task 2：单一 Conversation owner 与 Provider/Event adapters

**文件：** agent/runtime/session_adapter、provider_adapter、event_mapper；session supervisor/worker/io_handler；query_loop/executor 与 nodes/build_prompt/tool_dispatch/tool_execute；新增 `runtime/session_adapter_test.exs`、`provider_adapter_test.exs`、`event_mapper_test.exs`。

- [ ] 用 deterministic provider 测试一轮 tool call → tool result → provider continuation 只执行一次，Worker 不再同时驱动 QueryLoop。
- [ ] SessionAdapter 在监督树中创建 bounded run，传入 store/context/provider/registry/authority/subscriber 和有限 work/run/effect/commit/cleanup timeout；prompt/resolve admission 不阻塞 Worker mailbox。
- [ ] ProviderAdapter 实现 `ConversationAdapter.stream/2`，调用现有 Provider facade，保留 tool IDs、usage、终止事件、thinking、附件和 fallback 后 active provider。
- [ ] 验证 apply_patch/exec freeform；provider wire 不支持 custom tool 时在 provider 层做明确编码/解码并契约测试，不篡改 canonical grammar。若 `backplane_ai_protocol` 缺能力，按内部依赖 issue 规则阻塞相关 provider，禁止旧工具兜底。
- [ ] EventMapper 保留 structured output、image content、command session ID、cursor/truncation、interaction、cleanup、unknown outcome；旧 tool result 字符串仍可读，不能 stringify 丢掉新证据。
- [ ] 覆盖 steer/follow-up/cancel、stream DOWN、重复 tool ID、断流、超时、epoch fencing；完成 run 后从 canonical history 开新 run，不复用已 terminal run。

**验收：** session 的公共交互流程仍工作；唯一 execution owner；Provider mock/Bypass 成功，工具续轮后的 fallback provider 不回退到陈旧配置。

### Task 3：Catalog、宿主 policy 和核心 Codex tools

**文件：** runtime/catalog、policy；agent application；core config/prompt_builder；新增 `runtime/catalog_test.exs`、`policy_test.exs`、`local_tools_test.exs`；对应运行环境文件。

- [ ] 使用 `Codex.profile/4` 返回的 registry/tools/authority 完整 bundle；不与旧 registry 手动拼接。初始化必要的 ResourceRegistry、LocalCommand、Plan。
- [ ] 精确枚举授权工具和 revisions，严格 schema admission；动态外部工具可隔离拒绝并给诊断，但不能 silently broaden grants。
- [ ] 测试 exec → yield → write_stdin → exit、输出 token budget 与 backend output limit 分离、UTF-8 截断/cursor、stdin、cancel、资源释放确认。
- [ ] apply_patch 覆盖 add/update/delete/rename、context hunks、EOF、部分失败、symlink/路径逃逸；view_image 覆盖类型与路径；update_plan 保留宿主计划状态。
- [ ] 配置 Linux/Deno/Coreutils/sandbox backend readiness，记录 `tty` 和平台限制。先写跨 root、只读 profile 写入、子进程/网络越权测试，再开放 shell authority。

**验收：** 核心 coding profile 的工具名称/schema 与 fixture 一致；旧 builtin 不参与这条新链路；权限 deny 和 unsupported readiness 都发生在副作用前。

### Task 4：用户交互、Code Mode 和 collaboration_v2

**文件：** runtime/interactions/session_adapter/catalog/policy；web sessions UI、server session channel；新增 `runtime/interactions_test.exs`、`code_mode_test.exs`、`collaboration_test.exs`。

- [ ] 实现 root UI interaction IDs 的回答验证、撤销和重复拒绝；子代理和 unattended profiles 按合同拒绝不适用的人类交互。
- [ ] 为 permission/environment/context host callbacks提供可信grant、readiness和token数据；编写web/image/plugin fake adapter的成功、错误、取消、缺配置测试。真实服务未配置时不暴露对应工具。
- [ ] Code Mode 的 `exec/wait` 使用上游 Deno worker，nested tools 进入 admitted dispatcher；不给 Deno ambient filesystem/network，不新增本地 JS 执行器或 Denox migration。
- [ ] 检查等待期间剩余预算暂停/恢复、过期 timer generation、cell ownership、nested tool cancel、mutation unknown outcome 不被外层 JS catch 转成成功。
- [ ] 由上游 MultiAgent 启动 child Conversation；宿主生成 child_options、独立 run/incarnation、父子关系和不放宽的 authority。限制深度、并发和总预算，followup 保留历史并创建新 execution run。
- [ ] 测试父 cancel、child DOWN、interrupt、wait 超时、close/settlement 后资源泄漏，以及陈旧 callback不能回写新 run。

**验收：** 顶层、nested 和子代理调用通过同一审计/权限/取消链；无双重 execution owner，无后台遗留 Port/cell/child。

### Task 5：MCP dynamic catalog 与 Sandbox reverse calls

**文件：** runtime/mcp_adapter/catalog；mcp/server 与 facade；sandbox/bridge；新增 runtime/dynamic_catalog_test；修改 MCP、Sandbox 对应已有 tests。

- [ ] MCP app 发布 discovery/lifecycle 数据，宿主 adapter 订阅并产生 descriptors；不能让 mcp app 反向依赖 agent。
- [ ] resources/templates/read/search 经 dynamic profile，tool discovery 在当前 batch 成功提交后发布到**下一 batch**；registry、tools、authority、catalog revision 一起更新。
- [ ] server disable/disconnect/restart 撤销能力；旧请求、同名 replacement、失败 nested producer、撤权 race 不能越权执行。保留 annotation trust 和 TOML freshness 行为。
- [ ] Sandbox Bridge 接收注入的受信 session dispatcher，绑定 run/incarnation/deadline；无 session 的旧 `allow_missing_session/yolo` 调用明确拒绝，不能直接调用 Codex backend。

**验收：** fake MCP/Sandbox integration 覆盖资源、调用、动态发现、撤权；新目录中不存在 process-tool 旧 registry 旁路。

### Task 6：持久 extensions、workspace 和 Daemon profiles

**文件：** runtime/extensions/policy/catalog；workspace/projection/file_documents/permissions；daemon/toolsets/execution、heartbeat/local_scheduler、core memory/prompts；新增 runtime/extensions_test、workspace_projection_test；修改 daemon 和 workspace 对应 tests。

- [ ] skills/memories/history/notes/goal 使用现有持久 host services；先测试重启后仍可读取，禁用或未配置后不暴露工具。不能用上游 ephemeral reference state替代当前业务数据。
- [ ] workspace projection 测试 scoped visibility、路径逃逸、编辑同步、删除/move、冲突、索引刷新；更新 prompt 为真实路径，旧 @synapsis URI 不再发给模型。
- [ ] 重写 assistant/read_only/reflect/heartbeat/coding/maintenance/dream profile 和提示，删除 `allow_todo_write` / `assistant_dream_todo` 硬编码依赖；dream task 输出接 update_plan 或宿主 work-item 服务。
- [ ] Daemon 长期身份/inbox/heartbeat 保留；映射为 context/hook/extension 服务，不以短期 collaboration agent 冒充。agent_ask/reply/handoff 的流程写成显式新 contract tests。

**验收：** workspace 读写、记忆持久化、dream/heartbeat、Daemon communication 的业务结果保持；所有模型入口来自新 profile。

### Task 7：配置、历史和 UI/API/CLI 切换

**文件：** data/toolset/toolsets、agent_config/config store；core config/agent resolver；agent/tool_scoping/session config；server health/session API/channel；web agent/MCP pages/core_components；CLI main；对应 tests。

- [ ] 新 TOML catalog/profile schema带版本；旧工具名字报逐项迁移诊断，提供显式转换清单，保留 provider/agent `.opencode.json` 兼容。
- [ ] 不将旧 `file_read/grep` 自动提升为 unrestricted exec；旧 restrictive toolset 必须先获得新 policy 验证。切换不支持旧工具执行 fallback。
- [ ] 旧历史 tool_use/tool_result 原样只读显示；不重写旧 transcript 或由旧名字恢复 mutation；新增 structured results/unknown outcome/cleanup 在 UI、API 和 SSE 里保留。
- [ ] UI 显示 command running/session、plan、approval、子代理和错误状态；health 从 catalog/readiness 获取，MCP 页面退出旧 registry 查询。
- [ ] 跑相关 LiveView/Channel/Controller/CLI tests；实际浏览器验证审批/拒绝、长命令、cancel、子代理、图片、历史会话。若 assets有改动，用 `mix assets.build` 验证。

**验收：** 新配置不会静默扩权；所有公共客户端可理解新状态；旧会话可读取且不会自动执行。

### Task 8：停用并删除旧工具系统

**文件：** core/tool*、core/agent/tool_dispatcher；agent/query_loop* 与旧 tool nodes中失去调用者的部分；workspace/tools；对应旧专用测试和 docs/AGENTS 过期条目。

- [ ] 确认所有正式入口已经切换后，删除 34 个旧具体工具、Builtin、deprecated behaviour、旧 registry/executor/gateway、旧 capability/grant 执行实现和 tool-only VFS/path validator。
- [ ] 对旧 QueryLoop fork、legacy graph/tool dispatcher 分支逐个查 caller；迁移必要 host hook，删除不再使用的旧执行循环，不删除仍服务其他业务的纯函数。
- [ ] 将有意义的安全与行为测试迁移到 runtime adapter tests 后再删除实现耦合测试，不能靠删除旧测试消除权限覆盖。
- [ ] 保留共享 TaskSupervisor、memory/agent messaging/workspace 服务；仅删除本迁移造成的孤立模块。旧工具专用服务经 caller audit后移除。
- [ ] 添加 catalog/callsite audit：旧 34 名称在生产 definitions、默认 prompt、config 和 dispatcher中均不可执行；历史展示/显式迁移 fixture中的字符串允许存在。

**验收：** 全 repo caller audit 没有旧执行内核旁路；新 catalog 单一来源；不存在双轨开关或可执行的旧名字兼容别名。

### Task 9：验收、文档和交付证据

**文件：** runtime 相关测试、docs/architecture/04_BOUNDARIES、05_TOOLS、07_AGENT_SYSTEM、ADR-006/008、GUARDRAILS、tool_system PRD；迁移 runbook与agent note。

- [ ] 对下面验收矩阵逐项保留 proof，修订文档为最终实现；保存 `project: synapsis` 的 agent note，只记录已验证边界和实际决定。
- [ ] 记录 artifact version/checksum/pin、OS/Deno/sandbox readiness、scoped tests、assets/browser evidence、仍不支持的 profile/平台；不要以工具数量或 HTTP 200 宣称 Codex parity。
- [ ] 按阶段 logical commit，保留 unrelated work；全 checklist 与 scoped tests 通过即结束本开发范围。push/release/deploy 单独按后续授权执行。

## 7. 并行安排与里程碑

```text
Task 0（artifact 与上游验证）
  ├─ Task 1（存储） ─┐
  └─ Task 3（catalog/policy/local tools，可先做隔离测试）
                    └─ Task 2（单 owner 接入）
                         ├─ Task 4（interaction / code mode / collaboration）
                         ├─ Task 5（MCP / Sandbox）
                         └─ Task 6（extensions / workspace / Daemon）
                              -> Task 7（公开配置与客户端切换）
                              -> Task 8（旧系统删除） -> Task 9（验收）
```

Task 0 有上游阻塞时可继续 data-only contract、配置迁移设计和 fake provider/event mapping；不得切换正式 execution。Task 3 的 policy/catalog 测试可并行准备，完整集成依赖 Task 1/2。Task 4–6 分配独立模块 owner，公共 catalog/policy 由一个协调者合并修改，避免多个 agent同时覆盖同文件。

- **M0：** artifact、Codex pin、store contract、架构调整审定。
- **M1：** bounded Conversation + 核心编码工具在隔离 integration tests跑通。
- **M2：** Code Mode、协作、MCP/Sandbox、持久扩展和 Daemon集成通过。
- **M3：** UI/API/config 切换，旧系统删除，scoped验收完成。

## 8. 验证命令与验收矩阵

从 repo root运行；同一 build tree 的 Mix命令串行。下面目录在对应任务创建后运行，不能把不存在的测试目录当成“零测试通过”。每阶段只执行自己修改范围对应的命令。

```sh
devenv shell --no-tui -- mix test apps/synapsis_data/test/synapsis/runtime/
devenv shell --no-tui -- mix test apps/synapsis_agent/test/synapsis/runtime/
devenv shell --no-tui -- mix test apps/synapsis_agent/test/synapsis/session/worker_test.exs apps/synapsis_agent/test/synapsis/session/worker/io_handler_test.exs
devenv shell --no-tui -- mix test apps/synapsis_agent/test/synapsis/agent/daemon_toolsets_test.exs apps/synapsis_agent/test/synapsis/agent/daemon_tools_integration_test.exs
devenv shell --no-tui -- mix test apps/synapsis_sandbox/test/synapsis/sandbox/bridge_test.exs
devenv shell --no-tui -- mix test apps/synapsis_mcp/test/synapsis/mcp/server_test.exs
devenv shell --no-tui -- mix test apps/synapsis_web/test/synapsis_web/live/agent_live/sessions_test.exs apps/synapsis_web/test/synapsis_web/live/agent_live/toolsets_test.exs
devenv shell --no-tui -- mix test apps/synapsis_server/test/synapsis_server/channels/session_channel_test.exs apps/synapsis_server/test/synapsis_server/controllers/session_controller_test.exs
git diff --check
```

新 data/config/workspace/provider/CLI tests用任务清单中的精确文件追加 scoped命令。格式只检查更改的 Elixir文件；assets有改动时从 `apps/synapsis_web` 执行 `devenv shell --no-tui -- mix assets.build`。不因本计划运行整个 Synapsis umbrella，也不修复已有范围外红测。

| 验收项 | 必须证明 |
| --- | --- |
| Codex contract | 指定 pin的工具名、schema、freeform grammar、暴露条件一致；无旧模型工具 |
| Commit-before-effect | intent commit失败/不确定后不启动dependent effect；reply丢失后reconcile |
| Unknown outcome | direct/nested/child mutation的不确定结果保留证据，不能变成成功或自动重放 |
| 权限 | deny优先、审批精确绑定、只读 profile不因shell升级、旧catalog调用受fence保护 |
| 隔离 | cwd/path guard与OS sandbox分别验证；shell/child不可越界访问与扩网权限 |
| 生命周期 | prompt/steer/followup/resolve/cancel与timer fencing、DOWN、cleanup均有证明 |
| 持久化 | 真实Concord conformance、restart、旧epoch拒绝、无credentials/PID序列化 |
| 业务能力 | workspace同步、memory/skills持久化、Daemon heartbeat/dream/communication通过 |
| Provider | deterministic/Bypass、freeform、名称round-trip、fallback续轮；不调用真实LLM |
| 客户端 | structured结果/图片/计划/command session/approval/child/unknown状态正确，旧历史可读 |
| 删除完整性 | 34个旧工具实现和旧执行内核退出；共享业务服务保留；caller audit通过 |

## 9. 本次计划的待评审决策

1. 采用完整 Codex 工具体系和 package pin；如需指定另一个 Codex客户端版本，先调整 Task 0契约基线。
2. 接受 Conversation成为active run唯一执行owner，Worker保留session外壳的边界。
3. 接受 data-only runtime journal与ADR-006/008修订，保证commit-before-dispatch和可恢复的不确定结果。
4. 按能力启用profiles；需要OS sandbox、PTY、非Linux、真实web/image/provider-hosted服务时，将其作为可验证交付条件，缺失能力不冒充可用。

评审通过后按阶段执行；本计划本身不构成未验证上游包可直接生产切换的结论。

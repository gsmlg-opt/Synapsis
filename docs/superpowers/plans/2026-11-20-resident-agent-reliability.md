# Synapsis 常驻 Agent 可靠性修复计划

> 执行者可使用 `executing-plans` 按复选框实施。每项均有独立的复现和验收条件。

**目标**　用户能从 Web UI 委派本机工作，周期任务在一次明确失败后仍按期执行。进程或容器重建后，用户能读回已确认接收的结果和会话，也能查到长期积累的记忆。项目级委派最终向人工验收交付可核查的结果。

**架构**　会话进程拥有在途状态，`synapsis_data` 提供持久化接口。Samgita 负责项目事实和授权，Synapsis 负责规划与本地执行。OpenClaw `v2026.11.6` 是常驻 Agent 的产品参考，产品范围和优先级以 Synapsis 的现行设计为准。[产品设计](../../design.md) · [持久化决策 ADR-006](../../decisions/ADR-006-in-process-sessions-and-concord-storage.md)

**技术栈**　Elixir/OTP、Phoenix LiveView、Backplane Conversation、Concord/Turso、TOML、samgita_protocol、Gaoxy.Test、Docker Compose。

**复现基线**　评审针对 `main@210dad55` 加当时的工作区改动，包含尚未提交的 Sigma、Memory 和 Samgita 代码。上次评审实际运行 26 个仓库测试，13 个通过，8 个因 Local Agents 页面崩溃失败，5 个停在过时的契约断言。四个额外的隔离探针分别复现了周期任务停摆、忙碌会话漏收公告、大目录记忆检索失败和缺 Web 配置导致普通对话失败。Compose 的结论来自配置检查，容器重建是待执行的验收。

## 实施顺序

| 顺序 | 交付 | 前置条件 |
| --- | --- | --- |
| 1 | 恢复本机 Codex / Sigma 委派入口 | 优先处理 P4 主入口 |
| 2、3 | 恢复五个契约用例的检验能力，修复 Web 工具装配 | 可以分别实施，配置正确的 Web 工具使用第 2 项断言验收 |
| 4、5 | 恢复周期调度，保证结果持久投递 | 两个独立缺陷，分别通过后合跑一次实际调度到会话的用例 |
| 6、7 | 长期记忆检索，Compose 数据持久化 | 均可独立实施 |
| 8A → 8B | P5 执行结果，P6 项目协调闭环 | 8A 可独立开始，8B 使用已验证的执行结果和上游分派契约 |

### 1. 恢复本机委派页面（P4）

- [x] 在 `apps/synapsis_web/test/synapsis_web/live/local_agent_live_test.exs` 复现首次访问的 `KeyError :sigma_url`。在已有列表用例断言 Codex 行和 Sigma 表单的默认 URL `ws://127.0.0.1:4580/app-server` 同时可见，覆盖初次 HTTP 渲染和 LiveView 连接。
- [x] 在 `apps/synapsis_web/lib/synapsis_web/live/local_agent_live/index.ex` 的 `mount/3` 中将已有模块属性赋给 socket，即 `sigma_url: @sigma_url`。表单的 React 初值和原生输入框共用该 assign。
- [x] 运行下面命令。验收原有 8 个 LiveView 用例全部通过，覆盖启动、打开线程、消息、打断及崩溃恢复。重启本地服务后实际访问 `/local-agents`，要求 HTTP 200 且渲染 Codex 列表和 Sigma URL。通过受控适配器从页面发起一次委派并看到终态。真实 Codex/Sigma 的执行分别记录所用客户端和结果。

```sh
devenv shell -- mix test apps/synapsis_web/test/synapsis_web/live/local_agent_live_test.exs
devenv shell -- mix test apps/synapsis_local_agents/test/synapsis_local_agents/sigma_test.exs
curl -fsS http://127.0.0.1:4657/local-agents | rg 'sigma-url'
```

### 2. 修正五个过时的测试断言

- [x] 在 `apps/synapsis_agent/test/synapsis/session/native_readable_web_fetch_functional_test.exs` 修正三个参数化用例。按 Responses 的 `function_call_output` 检查有序的 `call_id` 和 `output`，从 `output` 解码文档。同步修改最后一轮 wire 输出与 `ToolResult.content` 的比较。保留文档内容、时间、缓存、HTTP 请求次数、持久化和 Worker 重开的断言。
- [x] 在 `apps/synapsis_agent/test/synapsis/session/memory_capture_functional_test.exs` 从 Host Agent 事件的 `payload["tool_call_id"]` 校验同一调用身份，保留事件内容和结果版本检查。在 `apps/synapsis_agent/test/synapsis/session/native_skill_search_functional_test.exs` 将 search/read 的描述符版本断言改为实现已发布的 `2`，保留后续排序、引用、历史与无重复执行的回放检查。
- [x] 用下列命令重跑三个文件。五例都必须走到末尾。如修正第一处断言后暴露新的内容或回放差异，按新的可复现问题单独诊断。Responses 工具结果可直接与下列期望形状比对。[提供方协议约定](../../design.md)

```elixir
tool_results = Enum.filter(parts, &match?(%ToolResult{}, &1))
assert length(results) == length(tool_results)

for {message, call, result} <- Enum.zip([results, calls, tool_results]) do
  assert message == %{"type" => "function_call_output", "call_id" => call.id, "output" => result.content}
end
```

```sh
devenv shell -- mix test --include functional \
  apps/synapsis_agent/test/synapsis/session/native_readable_web_fetch_functional_test.exs \
  apps/synapsis_agent/test/synapsis/session/memory_capture_functional_test.exs \
  apps/synapsis_agent/test/synapsis/session/native_skill_search_functional_test.exs
```

### 3. 缺少 Web 配置时仍可对话（P2）

- [x] 以 `apps/synapsis_agent/test/synapsis/session/native_web_fetch_functional_test.exs` 和同目录的 `native_web_search_functional_test.exs` 为入口。给 Agent 选中 `web::fetch` 但留空 `web_allowed_hosts`，向 Worker 发送 “say hello”。先复现模型零请求和会话失败。修复后测试模型收到一次普通请求、会话正常结束、Web 端零请求。对选中的 `synapsis::web_search` 缺提供方配置覆盖同一情形。
- [x] 修改 `apps/synapsis_agent/lib/synapsis/agent/tools/web/fetch.ex`、`apps/synapsis_agent/lib/synapsis/agent/tools/web/search.ex` 及其在 `apps/synapsis_agent/lib/synapsis/agent/runtime/session_adapter.ex` 和 `apps/synapsis_agent/lib/synapsis/agent/tools/profiles.ex` 的装配。**建议行为**为每个缺配置的已选工具提供本轮无网络副作用的 unavailable 描述符，调用时返回缺少的配置项。可参照 `apps/synapsis_agent/lib/synapsis/agent/tools/host_memory.ex`。只处理可识别的配置不可用。保留 authority、描述符绑定和其他装配错误。单纯返回空 bundle 会在 `Profiles.available/3` 再次失败。
- [x] 在 `apps/synapsis_web/lib/synapsis_web/live/agent_live/agents.ex` 的工具设置显示就绪状态，以及 fetch 所需主机或 search 所需提供方和对应凭据引用。**新装默认建议**是在上述降级生效后，让新建 Main 预选这两个工具并显示「待配置」。在 `apps/synapsis_data/lib/synapsis/agent_configs.ex` 仅改新建种子。已保存的勾选、取消勾选、主机与凭据引用应逐项保持。
- [x] 正向验收使用明确允许的测试主机和一个配置完整的搜索提供方。实际工具各命中受控 HTTP 服务，结果进入下一轮模型历史。再移除配置，下一轮恢复待配置状态，未列入允许清单的主机始终零请求。运行下列用例。

```sh
devenv shell -- mix test --include functional \
  apps/synapsis_agent/test/synapsis/session/native_web_fetch_functional_test.exs \
  apps/synapsis_agent/test/synapsis/session/native_web_search_functional_test.exs
devenv shell -- mix test apps/synapsis_data/test/synapsis/agent_config_seed_test.exs \
  apps/synapsis_web/test/synapsis_web/live/agent_live/agents_test.exs
```

### 4. 周期任务一次失败后继续调度（P3）

- [x] 在 `apps/synapsis_agent/test/synapsis/agent/heartbeat/native_typed_schedule_functional_test.exs` 添加有界用例。注册 300 ms 的 typed `every`，让第一次执行明确失败，第二次成功。当前症状是任务仍启用，截止时间已过，timer 的 `ref` 为 `nil`，reload 后也不再运行。以实际 Run 和调度时刻做断言，给等待设置超时。
- [x] 在 `apps/synapsis_agent/lib/synapsis/agent/heartbeat/local_scheduler.ex` 的 terminal 处理、`typed_outcome/4` 和 reload 对账中区分结果。仅对**同一 generation、按期触发、明确失败**的 `every` / `cron` 记录本次失败，并按既有间隔锚点或 cron 时区计算严格在未来的时刻，持久化并安装 timer。复用 `apps/synapsis_agent/lib/synapsis/agent/heartbeat/schedule.ex` 的计算。原 occurrence 保留原幂等键和失败记录。
- [x] 用同一 fixture 验证运行中 reload、Scheduler 进程替换，以及读取旧版本留下的「已失败 + 过去时刻」记录。通过相同 generation、slot 和持久 Run 确认旧失败后恢复。真正尚未执行的到期 slot 仍按既有语义处理。验证手动周期触发保留原日程，一次性 `at` 沿用原完成/保留策略，未知外部效果和并发修改过的 generation 继续走既有对账路径。
- [x] 验收观察到两个不同 slot、两个不同 Run，失败时刻只执行一次。保存的下次时间、运行中的 timer 和实际下一次执行一致。

```sh
devenv shell -- mix test --include functional \
  apps/synapsis_agent/test/synapsis/agent/heartbeat/native_typed_schedule_functional_test.exs \
  apps/synapsis_agent/test/synapsis/agent/heartbeat/local_scheduler_test.exs
```

### 5. 自动化公告在确认后可恢复（P3）

- [x] 在 `apps/synapsis_agent/test/synapsis/session/automation_functional_test.exs` 挂起来源会话的 provider 流，投递公告并获得 `:deferred`，立即替换来源 Worker，按原会话 ID 重开。复现公告在 pending 和 transcript 中同时消失。保留现有顺序约束，即活动回合先结束，公告先于下一条排队的用户提示进入历史。
- [x] 从 `apps/synapsis_agent/lib/synapsis/agent/automation/execution.ex` 经 `apps/synapsis_core/lib/synapsis/sessions.ex` 和 `apps/synapsis_agent/lib/synapsis/session/worker.ex` 向 `apps/synapsis_agent/lib/synapsis/session/worker/automation.ex` 传递稳定的投递身份。**建议**以来源会话、Run ID 和 `announce` 共同确定身份，首次接纳时分配并保存消息 UUID。同一投递重复到达返回同一 UUID。不同 Run 即使正文相同也各自显示。保留现有无 Run ID 的显式追加调用语义。
- [x] 在 `apps/synapsis_data/lib/synapsis/session/pending_input_store.ex` 为「已完成的 assistant 消息」建独立条目类型。复用 `apps/synapsis_data/lib/synapsis/session/store.ex` 的 `read_pending_inputs/2`、`compare_put_pending_inputs/4`，先持久接纳再回复 `:deferred`。在 `apps/synapsis_agent/lib/synapsis/session/worker/pending_inputs.ex` 的启动恢复和消费路径接入该类型，存储工作仍在受监督任务中。已排队的 prompt、steer、system event 继续按各自类型解码。
- [x] 消费时复用 `Store.commit_pending_completion/8` 的事务条件，将一条 assistant 消息、会话元数据和该投递的完成收据一起提交，确认后才广播。现有 `append_automation_turn/4` 只写消息和元数据，事后单独写收据会留下重复窗口。现有事务支持在 pending 条目中写完成收据。若消费后压缩队列，应在同一事务中保留按投递身份可查的轻量收据。已确认的 CAS 冲突可重读，事务结果未知则用同一身份只读对账，未判清时保留未知状态。
- [x] 分别在接纳之后、最终事务提交之后但回复之前替换 Worker，再重复投递同一身份。验收历史中同一 UUID 恰有一条，来源 provider 的请求数等于对照组。公告本身增加零次请求。覆盖存储拒绝时调用方收不到成功确认。第 4 项通过后合跑真实调度到来源会话的用例。

```sh
devenv shell -- mix test --include functional \
  apps/synapsis_data/test/synapsis/session/pending_input_store_test.exs \
  apps/synapsis_data/test/synapsis/session/automation_append_functional_test.exs
devenv shell -- mix test --include functional \
  apps/synapsis_agent/test/synapsis/session/automation_functional_test.exs \
  apps/synapsis_agent/test/synapsis/agent/heartbeat/native_automation_delivery_functional_test.exs
```

### 6. 长期工作区记忆可分批检索（P3）

- [x] 在 `apps/synapsis_core/test/synapsis/memory/workspace_reader_test.exs` 准备 `MEMORY.md` 和 126 份日报，再加第 127 份。断言首页仍能命中主文件。另在第二批才访问的旧文件或嵌套文件上放唯一词，沿返回的续查信息能读到其真实路径和一基行号。用该路径和行号实际读回原句。
- [x] **建议方案**是在 `apps/synapsis_core/lib/synapsis/memory/workspace_reader.ex` 给 search/list 增加可选的不透明游标。首页先读取主文件，对 `memory/` 逐批枚举。每页最多检查 128 个目录项，沿用一秒、堆、每文件/输出 64 KiB、最多 20 条命中等预算。先取已找到的结果，再返回 `complete` 与 `next_cursor`。游标绑定工作区、查询及目录位置，必要时包含文件内的续查行。在目录变化或游标失效时返回明确原因。
- [x] 实现枚举时验证同一宽目录可从上页位置继续。现有 `File.ls/1` 会先分配全目录，简单截前 128 个或每页从头跳过都无法满足预算。可利用发行版已有 Node 的 `fs.opendir()` / `Dir.read()` 按需读目录名，在 `apps/synapsis_core/lib/synapsis/memory/supervisor.ex` 下管理短时、有数量上限的游标。沿用单页完整结果现有的路径和行号排序，正文仍走已有文件身份、大小和路径校验。游标耗尽、过期或被取消时关闭句柄。用宽目录 fixture 验证每页实际枚举量和最终可达性。
- [x] 在 `apps/synapsis_agent/lib/synapsis/agent/tools/workspace_memory.ex` 和 `apps/synapsis_agent/lib/synapsis/agent/tools/memory_domain.ex` 的 workspace 分支同步输入 schema、工具修订和可见提示。部分扫描零命中提示「本页无匹配，可继续」，完成扫描后才给出全局无匹配结论。对应 `apps/synapsis_web/lib/synapsis_web/live/memory_live/index.ex` 的工作区文件列表支持继续加载。Host Memory 与 records 仍走各自的来源契约。
- [x] 运行下列用例。用「全部无匹配」「首页有结果但还有下一页」「旧文件只在后页命中」分别验收。现有读取行数、Unicode 截断、路径拒绝、超时和输出大小用例继续通过。

```sh
devenv shell -- mix test apps/synapsis_core/test/synapsis/memory/workspace_reader_test.exs
devenv shell -- mix test apps/synapsis_agent/test/synapsis/agent/tools/workspace_memory_test.exs \
  apps/synapsis_agent/test/synapsis/agent/tools/memory_domain_test.exs \
  apps/synapsis_web/test/synapsis_web/live/memory_live/index_test.exs
```

### 7. Compose 重建后仍能读回原会话

- [x] 在 `docker-compose.yml` 保留 `app_data:/app/data`，将 `SYNAPSIS_CONCORD_DATA_DIR` 默认设为 `/app/data/concord`。`SYNAPSIS_CONFIG_DIR`、`SYNAPSIS_MEMORY_DIR`、容器默认的 `SYNAPSIS_WORKSPACE_ROOT` 分别指向卷内的 `config`、`memory`、`workspace` 子目录，保留部署方显式覆盖和已有项目挂载。`config/runtime.exs` 已支持 Concord 路径并同步设置 `turso.db`，直接启动时沿用原有默认值。若部署使用 workspace blob，利用既有 `:blob_store_root` 将 blob 与引用它的状态一起持久化。
- [x] 在 `README.md` 的 Compose 用法说明已有安装如何保留数据。重建前从旧进程读取实际 Concord、配置、记忆及工作区路径并记录卷映射。停止写入后从**仍然存在的旧容器或原挂载**复制完整数据目录和 SQLite 附属文件，保留原加密密钥。已有目标目录先备份并核对，读回原会话后再退役旧容器。该步骤由现有安装的负责人按需执行。
- [x] 新增 `scripts/test-compose-persistence.sh`，用独立 Compose 项目名、唯一容器名和专用卷执行下列验收。先在该项目下构建当前 checkout 的 `app` 镜像，再用 `docker compose run -d --no-deps --name` 启动服务。两次均使用同一项目且不发布服务端口，避免占用现有 `synapsis_app` 或 4657。在容器内等待 `GET /api/health`，通过 `POST /api/sessions` 创建有唯一标题的会话，记录 ID。停止并移除第一个测试容器，以同一卷创建第二个，核对容器 ID 已变、挂载到 `/app/data` 的卷名相同、`GET /api/sessions/<id>` 返回同一 ID 和标题。用配置与文件记忆各一个标记验证另外两个路径，脚本只清理自己创建的资源。
- [x] 本地 Docker 使用同一个卷创建了两个不同的容器。第二个容器从应用接口读回相同的会话 ID 和标题、TOML Agent 及文件记忆。

```sh
docker compose config --quiet
bash scripts/test-compose-persistence.sh
```

### 8. Samgita 先交付执行证据，再实现项目协调（P5 → P6）

**8A · 完善现有 executor 的报告**

- [x] 从工作区中现有的 `apps/synapsis_samgita/test/synapsis_samgita/execution_test.exs` 出发。它用注入的 Runtime 和 API 测过 Synapsis、Codex、Sigma 三类身份下的 claim/start/progress/report 编排。扩展它以捕获实际 `report.result`，再用真实 `Execution.Runtime` 消费受控的终态事件，为三条路径分别提供不同的最终回答或失败原因。当前报告只有 `Execution succeeded` / `Execution failed`。
- [x] 在 `apps/synapsis_samgita/lib/synapsis_samgita/execution/runtime.ex` 从匹配的会话、线程和 turn 获取最终公开输出或终态错误，在 `apps/synapsis_samgita/lib/synapsis_samgita/execution/worker.ex` 形成有界报告。**建议最小字段**为 `summary`、本次执行的会话或线程/turn 引用，以及截断标志。仅在确有产物时附已有产物引用。复用 `apps/synapsis_data/lib/synapsis/samgita/executions.ex` 在发送前保存同一 report command ID 与其载荷。缺少文字时标明已观察到的终态和可核对的引用。
- [x] 验收成功、失败、子 agent 未收敛、报告响应丢失和同一事件重送。报告只包含本次执行的公开证据，保留现有 `effects_resolved`、设备归属和 `recovery_required` 语义。两次不同运行应能凭报告区分。检查不产生第二次执行或替换原命令。

```sh
devenv shell -- mix test apps/synapsis_samgita/test/synapsis_samgita/execution_test.exs \
  apps/synapsis_samgita/test/synapsis_samgita/inbound_test.exs
```

**8B · 实现 coordinator 的首个用户场景**

- [x] 上游已有 Task 分派接口和结果事件。首个端到端 fixture 从一个 `manual.triggered` 事件开始，由持有 `manager` 角色且订阅 `responsible` 的 Synapsis 接收并拆出两个子任务。用现有 Backplane 会话异步产出结构化分解，在测试中由受控 provider 给出确定答案。执行者从项目内已注册且具备能力的身份选择。[管理 API](https://github.com/gsmlg-opt/Samgita/blob/68d8f5c3990db3aabadba91e4c4cc5e70f9a82ba/docs/redesign/management-api.md) · [协调设计 §10](https://github.com/gsmlg-opt/Samgita/blob/68d8f5c3990db3aabadba91e4c4cc5e70f9a82ba/docs/redesign/design.md)
- [x] 在 `apps/synapsis_samgita/lib/synapsis_samgita/app_server/handler.ex` 复用按设备落盘的 inbox，保留现有 `task.assigned` executor 入口。拟新建 `apps/synapsis_samgita/lib/synapsis_samgita/coordinator.ex` 承接 manager 事件，接入 `apps/synapsis_samgita/lib/synapsis_samgita/application.ex`。在 `apps/synapsis_samgita/lib/synapsis_samgita/api.ex` 加入实际的 Task create/assign 调用，传入 `parent_task_id`、目标 Agent、稳定 command ID 和服务端要求的版本。生产路径检查项目角色与订阅，按当前设备的凭据和连接代际调用。
- [x] 继续由 `apps/synapsis_data/lib/synapsis/samgita/inbox.ex` 保存接收事实，拟新增 `apps/synapsis_data/lib/synapsis/samgita/coordination.ex` 保存按设备、项目、事件归属的分解结果、每条命令和已知结果。用同目录数据层的 Concord 接口，将命令身份与载荷在发出前写入。接收确认后进程重启仍可恢复。已执行的步骤按收据去重，响应丢失或版本冲突先对账。重送同一输入事件、子任务的 `task.assigned` 或 `attempt.reported` 均不能触发第二次拆分。
- [x] manager 消费 `attempt.reported` 时用 `task_ref`、Attempt ID 和服务端状态更新对应子任务。在 `apps/synapsis_web/lib/synapsis_web/live/samgita_live/index.ex` 展示归属、结果状态与可读取的证据。上游事件 envelope 提供状态和引用，完整的 `report.result` 存在执行报告中。需要跨机展示产物时，读取对应 Task 的 `artifact_references` 并按 Attempt ID 匹配。缺证据时明确显示可见范围。按上游实际响应构造测试，普通成功用例的 Attempt 是 `succeeded`，Task 是 `awaiting_review`，交由用户人工验收。[事件载荷](https://github.com/gsmlg-opt/Samgita/blob/68d8f5c3990db3aabadba91e4c4cc5e70f9a82ba/apps/samgita/lib/samgita/events.ex#L601) · [报告后的状态流转](https://github.com/gsmlg-opt/Samgita/blob/68d8f5c3990db3aabadba91e4c4cc5e70f9a82ba/apps/samgita/lib/samgita/attempts.ex#L185)
- [x] 新增 `apps/synapsis_samgita/test/synapsis_samgita/coordinator_test.exs`。复用 `apps/synapsis_samgita/test/support/ingress_host.ex` 提供受控 WebSocket，管理端 HTTP 使用 `Gaoxy.Test` 和 `apps/synapsis_samgita/test/support/samgita_stub.ex` 的响应工具。断言一个来源事件只生成一棵任务树，两个子任务各有明确 assignee，executor 回报后 manager 收到对应结果。无 manager 角色时管理写入为零，事件重送或进程半途重启后子任务数保持不变。既有入站独立 token/连接与可选出站模式分别保留覆盖。

```sh
devenv shell -- mix test apps/synapsis_samgita/test/synapsis_samgita/api_test.exs \
  apps/synapsis_samgita/test/synapsis_samgita/app_server/handler_test.exs \
  apps/synapsis_samgita/test/synapsis_samgita/coordinator_test.exs \
  apps/synapsis_web/test/synapsis_web/live/samgita_live_test.exs
```

### 9. 优化会话页的桌面与移动布局

- [x] 缩短会话头部和空输入框。桌面限制消息列宽，移动端默认收起侧栏。空的子代理面板在无任务、无权限请求且无告警时收起。
- [x] 生成开始时只显示状态提示，保留流式协议的回复锚点。模型选择、排队、转向、停止和异常状态继续走现有交互。
- [x] 构建前端资产并跑会话 LiveView 测试。在宽屏和手机宽度打开实际页面，检查消息、模型栏、输入框和侧栏。

## 集成验收

- [x] 串行执行范围内测试，405 项通过，含会话、工具、调度、记忆、委派和 Samgita 功能用例。Provider HTTP 使用 `Gaoxy.Test`。Samgita 场景经过真实 WebSocket 客户端和会话 Worker，规划模型及上游管理服务由 fixture 提供。跨 Concord 分页的 journal 测试在相邻设备都有记录时只读回目标设备的 101 条记录。
- [x] 前端资源构建成功。`devenv processes restart synapsis` 后服务回到 `ready`，`/api/health`、`/local-agents` 和截图中的会话页返回 200。实际 LiveView 在 1440×900 和 390×844 下没有横向溢出，手机侧栏可打开和关闭。
- [x] 全量默认测试已运行，仍有 15 项失败，集中在旧 routine/调度、Daemon 恢复及 MCP 选择用例。范围内新增的 typed schedule、公告恢复及 Samgita 分页回归均通过。
- [x] 端到端验证覆盖受控 Codex/Sigma 适配器、Samgita 测试服务和独立 Compose 容器。真实 Codex/Sigma 执行、已部署 Samgita 和既有 Compose 安装的数据迁移仍待现场验证。

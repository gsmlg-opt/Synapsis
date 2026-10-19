# Provider、模型、MCP 与远程 Skill 配置设计

日期：2026-10-19

状态：用户于 2026-10-19 确认设计；已实现并通过范围内验证，随后授权合并 main 并发布下一版本。

## 目标与已确认语义

Provider 独立保存连接信息；模型、MCP 和远程 skill 来源引用同一 provider。
用户配置可用模型及各自默认上下文窗口，agent 保存默认模型，会话可以选择其他已配置模型。
用户已确认：`context` 指上下文窗口的 token 数，用于上下文预算与压缩阈值。

MCP 工具目录来自实时服务端发现。Agent 可以使用默认全部工具，也可以按组配置全部、指定或全部取消。
Skill 配置可以选择 Backplane provider，并复用现有远程技能发现、分配与按需读取机制。

## 当前实现与缺口

以下结论来自当前 `main` 的源码核查。

| 位置 | 当前行为 | 本次需要改变的行为 |
|---|---|---|
| `Synapsis.ProviderConfig`、`Synapsis.Providers` | 连接记录已存入 `providers.toml`；模型发现结果与启用列表嵌在 provider 的 `config` 中 | 连接与用户配置的模型目录分开管理 |
| `/settings/models` | 只有 fast/default/expert 层级说明 | 编辑真正的模型目录，包括 provider、模型 ID、上下文窗口和启用状态 |
| Agent 模型选择 | 与 provider 页面使用不同的模型列表解析规则 | 与会话及运行时共用同一个可用模型目录 |
| `Session.Worker.Config` | 切换模型接口存在，但后续刷新 agent 默认值会覆盖会话选择 | 新会话采用默认值，已有会话保留自己的模型选择 |
| 上下文预算 | 压缩、skill 与 memory 预算主要读取静态 registry 或固定默认值 | 使用所选模型的有效上下文窗口 |
| `Synapsis.MCP.Server` | 启动时发现一页工具，之后主要使用内存缓存；Backplane 工具还受持久化工具列表过滤 | 按需执行完整、实时的工具发现，再发布目录 |
| Toolset | “全选”存成当时工具名称的枚举 | 持久化能包含未来新增工具的选择规则 |
| Backplane 连接 | 独立保存 endpoint、凭据和同步状态，并向 provider/MCP 复制连接信息 | Provider 成为连接及凭据的唯一配置来源 |
| 远程 skill | 已有发现、稳定来源身份、revision/digest、分配和远程 loader | 增加 provider 来源选择与分组入口，复用现有运行路径 |

实际 MCP 依赖是 `backplane_mcp_protocol`，当前锁定版本为 1.10.19。
仓库部分旧说明仍描述 `anubis_mcp`；本次设计以现有源码为依据。

## 方案选择

### 方案 A：统一 Provider 引用，独立模型目录（建议采用）

Provider 是连接配置来源；模型、MCP 和远程 skill source 通过稳定 UUID 引用它。
保留既有 Backplane source UUID 和同步运行状态，逐步移除重复的连接信息。
优点是配置修改能一致生效，模型目录和工具选择有清晰的权威来源；代价是需要明确的数据迁移与兼容读取。

### 方案 B：保留 Provider 与 Backplane 两份连接配置，通过关联字段同步

可以减少首批改动，但 endpoint、凭据、启用状态仍存在两个可编辑来源。
URL 覆盖和凭据轮换需要持续处理双向同步；后续仍需迁移。

本设计按方案 A 展开。实现分为四个切片，模型会话与 MCP/skill 共享 Provider 基础。

## 1. Provider 连接

继续使用 `providers.toml`、`ProviderConfig` 和 `Providers` API。
保留现有协议 `type`；增加明确的 preset/vendor 身份，Backplane 继续使用 OpenAI-compatible LLM 协议。

Provider 页面管理：名称、preset、协议、endpoint、凭据和启用状态。
Provider 不再承载“用户允许使用哪些模型”的编辑入口；发现得到的模型元数据可以保留为导入候选。
支持 MCP/skills 的 provider 提供对应默认地址；本次远程 skill 接入使用既有 Backplane Skill Protocol。

Backplane 的 LLM `/v1`、MCP `/mcp` 和 skill 协议地址通过统一 endpoint 解析得到。
已保存的 LLM base URL 必须保持原意，包括自定义路径前缀。
MCP 的 URL 覆盖保存到 MCP 配置；后续 provider 同步不会覆盖用户填写的值。
发现、snapshot 和运行时配置使用同一个解析结果。

Provider 凭据在请求时解析；MCP 与 skill source 保存 `provider_id`，避免新增凭据副本。
已有自定义 MCP headers、stdio 配置及独立 MCP 连接继续沿现有路径解析。
凭据变更、清除和 provider 禁用须同步失效相关运行连接与远程读取资格。

保留 Backplane 连接记录中的 source UUID、同步状态、revision、错误、信任与可用性元数据。
已有 `backplane://<source-id>/...` locator 及关联资源身份保持稳定。
建立 provider 关联后，旧连接 API 通过同一连接来源读写，避免出现两份可编辑凭据。
新建 provider 本身不隐式建立 MCP/skill source；在对应页面选择 provider 时建立关联。

## 2. 独立模型目录

在 `synapsis_data` 增加 `ModelConfig`、`Models` 和 `Config.Store` 的 `:model` 类型，保存到 `models.toml`。
数据层负责模型记录与校验；网络发现和 provider 协议处理继续留在 `synapsis_provider`。

每条模型记录包含：

- `id`：稳定 UUID。
- `provider_id`：连接 UUID。
- `model`：发给服务端的原始模型 ID。
- `name`：可选的显示名称。
- `context_window`：正整数，单位 token。
- `enabled`：是否进入可选择的模型目录。

同一 provider 下原始模型 ID 唯一；不同 provider 可以配置同名模型。
输出 token 上限继续使用现有配置，不与上下文窗口混用。

`/settings/models` 支持选择 provider、导入发现到的模型、手工新增模型、编辑上下文窗口和启用/禁用。
发现结果用于提供候选与初始值；刷新不会覆盖用户编辑过的上下文窗口或重新启用已禁用模型。
无法发现元数据的手工模型需要填写有效的上下文窗口。

Agent 默认选择、会话选择、运行时准入和上下文预算统一通过模型目录解析。
只有模型与关联 provider 都可用时，模型才可被新选择；配置中的名称不是运行时准入依据。
现有静态 `ModelRegistry` 继续提供能力和默认元数据，不再独自决定实际上下文窗口。

## 3. Agent 默认模型与会话当前模型

Agent 中的模型配置在产品界面明确标为“默认模型”。
创建会话时从 agent 默认模型初始化；之后由会话保存的选择决定有效 provider/model。
继续刷新 system prompt、工具及其他 agent 配置时，不覆盖会话模型。

会话界面增加模型选择器，按 provider 分组展示所有已配置且可用的模型。
切换仅在会话空闲时接受；运行中禁用选择，同时由服务端统一检查 native 与 legacy 运行状态。
模型被禁用或删除时，展示不可用原因，由用户重新选择，不自动切到另一模型。

切换通过已有 `Sessions.switch_model` 与会话 worker 完成：

1. 解析目标模型及 provider，检查可用性。
2. 为目标 provider/model 校验可发送的历史视图。
3. 由 worker 串行处理切换，沿现有会话持久化 API 保存元数据。
4. 一致更新会话、有效 agent provider/model、provider config、engine/graph context 和预算配置。
5. 成功后广播 `model_switched`；失败保留原选择。

持久化继续保留现有 provider/model 字段以兼容旧配置和 API；新增目录引用使用稳定 ID。
旧记录按原 provider 与模型对解析，不把其中一个字段单独替换为默认值。

有效上下文窗口同时用于 compactor、skill 元数据预算、memory 预算和 turn preparation。
切到更小窗口时，发送前按目标窗口执行现有上下文预算与压缩规则。

### 跨模型历史中的签名 reasoning

现有 AiProtocol 会严格拒绝把绑定于原 provider/model 的签名状态发给其他模型。
当前依赖没有自动转换这种历史的 API。

建议明确引入 Synapsis 的目标请求历史投影：持久化原始历史保持完整；面向目标模型构造请求时，
保留可移植的用户/助手内容及工具调用与结果配对，排除不能跨来源重放的 opaque reasoning 状态。
这属于新增、需要本设计确认的会话行为，必须在 provider 边界实现并测试。
AiProtocol 的来源校验继续执行；无法生成目标协议可接受的视图时返回明确错误，保留原模型。

来源仍兼容的签名状态原样保留；投影不能伪造或重标签名来源，也不能破坏工具调用 ID、次序及结果配对。
Google 的签名还可能绑定可见文本或工具调用，并不限于隐藏 reasoning。
现有 codec 接受无签名的普通工具历史，但这不能证明每个远端模型都会接受转换后的历史。
相关验收须区分 codec 契约测试与目标服务端的实际接受能力；遇到要求原签名的目标模型时明确拒绝继续，
不自动加入摘要边界或改写持久化历史。

## 4. MCP 配置与实时工具目录

MCP 创建表单支持选择 provider 或使用现有手工配置。
选择 Backplane 后填入其 MCP 默认地址，允许覆盖 URL，并复用 provider 凭据。

现有 `MCP.Server` 负责目录刷新与注册，不再创建第二套 provider 专用 MCP runtime。
以下操作触发实时 `tools/list`：打开 MCP 工具页、打开 agent/toolset 的 MCP 选择界面、
显式刷新、重连，以及每轮构造 MCP 工具集合之前。
并发刷新可合并为一次进行中的发现，但不能直接把持久化工具缓存返回为新结果。
每轮已开始后使用该轮确定的目录与权限集合，下一轮再读取最新变化。

刷新必须完成 `nextCursor` 分页，并设置超时、最大页数及重复 cursor 检查。
远程操作放在受监督的异步任务中，UI 显示加载状态，会话 worker 不等待网络调用。
完整成功后发布同一版本的目录，协调新增、变更和移除的 registry 条目。
不完整响应或请求失败不会被当作有效的空目录。

配置中的旧 `backplane_tools` 列表不再限制发现结果。
Provider/source 的启用状态、来源可用性、权限和 annotation 信任检查仍独立执行。
刷新失败时界面显示错误；已有目录只可标示为上次结果，不宣称实时成功。
该来源本轮不向模型提供过期定义，保留用户选择规则，允许后续重试。

当前依赖支持带 cursor 的 `list_tools`。Legacy list-changed 通知只产生 telemetry，
因此本设计的实时性通过上述显式发现保证，不依赖尚未接通的通知转发。

## 5. Agent MCP 选择规则

保留现有内置工具与 toolset 配置，增加明确的 MCP 选择规则。
组身份使用 MCP 配置 UUID，组内工具使用服务端原始名称；显示名称变化不会丢失选择。

| 层级 | 模式 | 实际语义 |
|---|---|---|
| Agent 默认 | 全部 | 包含所有已启用、可用 MCP 来源的当前及以后新增工具 |
| Agent 默认 | 指定 | 只使用显式配置的来源/工具 |
| 某个 MCP 组 | 全部 | 该组实时发现的工具全选，后续新增也包含 |
| 某个 MCP 组 | 指定 | 仅使用该组保存的原始工具名称集合 |
| 某个 MCP 组 | 不选 | 该组贡献零个工具 |

组规则覆盖默认规则。界面提供组全选、组指定与整组取消，指定模式显示复选框及部分选中状态。
“不选”是显式策略，不能因解析为空触发现有 legacy 工具 fallback。
用户保存的指定名称暂时消失时显示不可用并保留选择；新工具不会自动加入指定集合。

每轮以同一次刷新的目录解析规则，向模型提供的定义和实际调用允许集合来自同一解析结果。
已有 permission、read-only 与执行路径继续约束最终工具资格。
Daemon 原有可信只读 MCP 补充逻辑也必须尊重明确的来源排除，避免把取消的工具重新加入。

新建 agent 的 MCP 选择提供默认全部模式。
迁移现有 agent 时保留原来的有效选择，不能把已有的指定工具列表扩成全部。
MCP 的全部模式只选择已有已启用来源，不会创建或启用新的连接。

## 6. 通过 Provider 使用远程 Skill

Skill 设置页增加来源选择：本地技能或支持 skill 的 provider。
选择 Backplane 后，复用对应 provider 连接与既有 source，同步其远程技能目录。
目录与 agent 分配界面按 provider/source 分组，显示启用状态与同步错误。

继续使用现有 `Backplane.Sync`、`SkillCatalog`、agent `skill_ids`、`skill` 工具与 `Backplane.SkillLoader`。
目录暴露技能摘要与来源 locator；正文和引用资源按需通过原来源读取。
保留 source UUID、远程 skill ID、revision 和 digest；不同来源同名技能不会合并。
Provider 禁用、凭据变化与远程读取失败沿既有资格检查与错误路径处理。
Skill 来源选择不自动给所有 agent 分配全部远程技能。

## 7. 迁移与兼容

迁移以现有稳定 ID 和来源标记为依据，支持重复执行，并通过 `Config.Store` 写入。

1. 从 provider 已启用模型与现有 agent 默认模型建立初始模型目录。
   旧 `enabled_models = []` 按其现有“全部发现模型”含义导入，保留手工模型名称和已配置上下文值。
2. 保留 provider UUID、名称和旧 provider/model 字段读取，支持 `.opencode.json` 的现有配置入口。
3. 关联已有 Backplane connection 与其受管理 provider，保留 source UUID 与远程资源身份。
   不按显示名称合并独立连接；凭据不一致时报告待处理冲突，不猜测覆盖。
4. MCP 保存 provider 引用和显式 URL 覆盖；运行时使用统一 endpoint/credential 解析。
5. 把现有枚举工具选择映射为指定规则，保留现有排除和不可用名称。
6. 迁移成功后停止向旧字段写入重复权威数据；失败保留可恢复的原始配置，报告具体记录。

## 8. 实现边界与验证

| 切片 | 主要责任边界 | 验收 |
|---|---|---|
| Provider 与模型目录 | data 的 schema/store；provider 的连接/模型 API；provider/model 设置页 | provider 重用、模型增删与上下文编辑、导入不覆盖用户值、配置重载与迁移幂等 |
| 会话模型切换 | core Sessions/预算；agent worker/runtime；会话与 agent 模型选择器 | 跨 provider 切换后发送、排队下一轮、worker 重启仍保留选择；agent 默认不变；上下文实际生效；运行中拒绝切换；签名历史视图合法 |
| MCP 实时目录与规则 | MCP runtime；data 选择规则；core resolver；agent/daemon 工具准入；MCP/toolset/agent 页面 | 多页目录；远端工具增删改；失败不发布半页；URL 覆盖保留；全部包含新工具；指定/取消稳定；模型定义与调用资格一致 |
| 远程技能来源 | Backplane sync/loader；skill catalog；skill 设置和 agent 分配页面 | 同一 provider 凭据生效；来源分组；摘要目录与按需读取；同名隔离；revision/digest；禁用与轮换失效 |

沿现有各 app 对应的测试文件运行 scoped checks，补充模型目录与选择规则的契约测试。
Provider/MCP/skill HTTP 用 Bypass，不访问真实模型服务。
UI 用对应 LiveView 测试；涉及 hooks 时构建 DuskmoonBundler assets，并检查实际页面交互。
实现完成后写 Agent Note，添加 `project: synapsis` 标签。

## 源码导航

- Provider 模型缓存与资格：`apps/synapsis_provider/lib/synapsis/providers.ex`。
- 模型设置入口：`apps/synapsis_web/lib/synapsis_web/live/model_tier_live/index.ex`。
- 会话模型默认值和切换：`apps/synapsis_agent/lib/synapsis/session/worker/config.ex`。
- 会话界面：`apps/synapsis_web/lib/synapsis_web/live/agent_live/sessions.ex`。
- 上下文预算：`apps/synapsis_core/lib/synapsis/session/compactor.ex`、`apps/synapsis_agent/lib/synapsis/agent/context_builder.ex`。
- Provider 签名状态契约：`docs/architecture/06_PROVIDERS.md`、`apps/synapsis_provider/test/synapsis/provider/message_mapper_test.exs`。
- MCP 目录：`apps/synapsis_mcp/lib/synapsis/mcp/server.ex`。
- Backplane 身份与同步：`apps/synapsis_mcp/lib/synapsis/backplane/connection.ex`、`apps/synapsis_mcp/lib/synapsis/backplane/sync.ex`。
- 工具选择：`apps/synapsis_web/lib/synapsis_web/live/agent_live/toolsets.ex`、`apps/synapsis_core/lib/synapsis/agent/resolver.ex`。
- Skill 目录与读取：`apps/synapsis_core/lib/synapsis/skill_catalog.ex`、`apps/synapsis_mcp/lib/synapsis/backplane/skill_loader.ex`。

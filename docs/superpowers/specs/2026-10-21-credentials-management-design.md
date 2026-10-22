# 独立 Credentials 与 Provider 凭据引用

日期：2026-10-21

状态：用户于 2026-10-21 确认按本设计实施。

## 目标与范围

用户希望像 Sigma 一样，使用独立 Credentials 菜单管理 API key。
本设计采用独立凭据记录与稳定引用：Credentials 保存密钥，Provider 保存连接和凭据引用，模型、MCP 和远程 Skill 继续引用 Provider。

本次管理手工填写的 API key 与 Backplane 客户端访问令牌。现有 OpenAI OAuth 登录、刷新和退出保留原来的入口及生命周期；OAuth token 的集中管理与存储改造不纳入本次。
环境变量和 `.opencode.json` 的既有兼容读取继续保留，不自动将环境密钥写入凭据文件。
独立自定义 MCP 的 headers、env、stdio 参数仍按原路径处理，本次不新增通用密钥模板语言，也不猜测提取其中的秘密。

## 已核对的实现

Sigma `main @ 4e161809` 已有 `/settings/credentials`，以列表和 modal 管理名称与 Key。
Provider 保存 `credential_id`；Provider-backed MCP 与 Skills 在解析连接时沿用该引用。
Sigma 的 pi `auth.json` 布局、旧 Key 回填、删除后清空引用和已有会话的更新行为不直接移植。

Synapsis 目前没有独立 Credential 类型：

- `ProviderConfig.api_key_encrypted` 与 Provider 记录一起保存。
- `Providers` 使用 `Synapsis.Encrypted.Binary` 做 AES-256-GCM 加密，持久化为 `enc:v1:` 文本。
- `ProviderSource` / `Connection` 已为关联 MCP 和 Skill 提供统一凭据解析。
- `Config.Store` 已有串行写锁、引用检查、仅更新已有记录的 API 和文件 watcher。
- 当前相同 Provider 的会话请求可能复用 `state.provider_config`，只更新 Provider Registry 不足以更新既有会话的 Key。
- Store 文件重载目前只更新 ETS；没有通用的配置变更通知。

## 方案选择

| 方案 | 收益 | 代价 |
|---|---|---|
| 独立加密 Credentials，Provider 通过 UUID 引用（建议） | 凭据可以复用、集中轮换，界面与数据所有权一致 | 需要迁移和运行时失效处理 |
| 只增加 Credentials 菜单，仍编辑 Provider 内的 Key | 改动较少 | 仍无法共享同一凭据，多个连接要分别修改 |
| 同时统一 API key、OAuth 和任意工具秘密 | 管理范围更广 | 涉及新的登录、刷新和工具注入契约，超过这次需求 |

以下设计采用第一种。

## 用户操作

### Credentials

Settings 增加 `/settings/credentials`，与 Providers、Models 并列。
默认显示已配置的凭据列表，包含名称、掩码、关联 Provider、更新时间和编辑/删除操作。
添加、编辑使用既有 DuskMoon modal form；删除使用确认对话框。

表单只有名称和 Secret Key。新增要求非空 Key；编辑时 Key 输入保持空白，留空保留原值，填写新值更新同一凭据 UUID。
列表仅展示掩码；长度大于 8 的 Key 可展示末四位用于辨识，短值全部掩码。表单、页面 payload 和普通 API 响应不回填完整旧 Key。
凭据名称用于显示，不参与连接身份匹配。

### Providers

非 OAuth Provider 的新增/编辑表单把 API Key 输入改为 Credential 选择器，提供明确的“无凭据”选项和 Credentials 管理入口。
同一 Credential 可以供多个 Provider 引用。Provider 仍管理名称、协议、preset、URL、启用状态和 OAuth 登录。
新增或修改凭据后，已打开表单刷新候选项，并保留尚未保存的其他字段。

Models 仍选择 Provider；关联 MCP 和远程 Skill 仍通过 Provider 使用同一凭据，不保存 Key 副本。
现有 MCP URL 覆盖、来源 UUID、Skill locator/revision/digest 和工具选择规则保留。

## 存储和依赖方向

在 `synapsis_data` 增加 `CredentialConfig`、`Credentials` 和 Store 的 `:credential` 类型，保存到 `credentials.toml`。
记录包含 UUID、显示名称、加密 Key、创建/更新时间，以及用于更新判定的版本信息。
继续使用现有 `Encrypted.Binary` 和 `enc:v1:` 加密格式；不得引入明文 JSON 密钥文件。
Secret 的加解密、元数据读取与按 ID 解析通过 Credentials API 完成，避免上层直接读取 TOML。

Provider 增加 `credential_id`。显式引用的凭据必须存在；Provider 与 Credential 的写入、删除检查共用 Store 写锁。
Provider 更新不能把旧副本重新写回，也不能通过更新操作创建已删除的凭据。
普通列表与详情读取只返回安全元数据；实际密钥仅由运行时解析接口读取。

数据层负责持久化、校验、引用查询和删除保护，不依赖 provider/core/Phoenix/MCP。
沿用已有应用启动时注入回调的方式提供凭据变更通知，只传类型与 ID，不传秘密。
通知在 Store.Server 调用返回后执行，覆盖成功写入和文件重载；上层负责 Registry、PubSub 与连接失效。
网络重连与发现交给现有受监督任务，不能放进 Store GenServer 或配置写锁。

## 更新和删除

### 更新 Key

1. 先持久化新 Key，再失效关联 Provider 的运行时认证快照，并通知相关设置页。
2. Provider Adapter 在每次新请求前，根据 Provider UUID 重新解析当前认证字段；保留会话自己的模型和请求参数。
3. 已打开会话的下一次请求使用新 Key，不依赖重新创建会话。已经开始的请求按原生命周期结束，不重放请求。
4. 关联 MCP 的 generation 包含凭据版本；旧连接和工具注册失效，再由现有刷新路径建立新连接。旧发现结果不能发布成新版本结果。
5. Skill 继续在使用时解析最新凭据，原有来源资格检查继续生效。

接口操作和外部 TOML 重载都要触发失效；即使外部编辑没有同步修改更新时间，也必须识别 Key 内容变化。请求与调用边界仍检查当前引用和版本，正确性不能只依赖广播是否及时到达。

### 删除与无凭据

仍被 Provider 引用的 Credential 不允许直接删除，界面显示关联项，用户先解除或更换引用。
这样删除不会隐式把一个已认证连接切换成无认证连接。
未被引用的 Credential 经确认后删除持久化记录，并清理对应缓存。

删除 Provider 时保留 Credential，因为其他 Provider 可能共用它。
外部编辑产生缺失 `credential_id` 记录时，关联连接显示“凭据不可用”，禁止回退到旧 Key、环境变量或无认证。
只有用户明确选择“无凭据”才省略认证头；这是有效配置，不预设本地 Backplane 必须有令牌。

## 迁移与兼容

旧 Provider 内的手工 Key 迁移为独立 Credential，并将 Provider 改为 UUID 引用；没有 Key 的 Provider 保持无凭据。
OAuth 管理的访问令牌不得按手工 API key 导入。
迁移保留 Provider、模型、MCP、远程 Skill 和历史会话身份，不重新发现或导入模型，也不修改 agent 默认模型。
不同 Provider 的旧 Key 不因字符串相同而自动合并；用户可以之后明确共享同一 Credential。

迁移必须可重复执行、可从中断恢复，并为迁移记录保存稳定对应关系：

1. 通过 Store API 先保存加密 Credential；成功后再保存 Provider 引用并移除旧 Key 字段。
2. 在写入 Provider 引用前失败时保留旧字段，报告失败记录，重试复用同一 Credential，不生成重复项或覆盖用户已轮换的 Key。
3. 迁移完成后不再从旧字段恢复已清除的凭据，也不维护两份可编辑的权威数据。

TOML 跨文件写入不宣称为崩溃原子事务；迁移前保留受保护的备份，失败结果可见。
Provider REST API 支持 `credential_id` 引用，并保留 `api_key` / `api_key_encrypted` 输入的兼容适配。首次显式设置 Key 时创建该 Provider 自己的 Credential；只被该 Provider 引用时，兼容更新可以修改这条 Credential。若凭据已被多个 Provider 共用，旧式 Key 更新返回明确校验错误，用户通过 Credentials API 显式轮换共享 Key，或创建另一凭据并更换引用。
既有明确清除 Key 的操作改为解除该 Provider 的凭据引用，保留 Credential 本身；空输入仍按既有表单语义保留当前值。
Provider API 输出引用和“已配置”状态，不输出明文 Key。

## 验收

- Credentials 列表、新增/编辑 modal、删除保护、名称更新、掩码与空 Key 编辑语义通过对应 LiveView 测试及浏览器检查。
- 同一 Credential 供两个 Provider 使用；轮换后两个 Provider 的下一次发现/请求都携带新 Key。
- 已存在会话与 MCP 连接能正确失效旧认证；缺失引用不发送网络请求，也不回退旧秘密或无认证。
- Provider 删除保留共享 Credential；引用中的 Credential 删除被拒绝，解除全部引用后才可删除。
- 文件重载与界面操作遵循相同更新语义，过期的异步结果不能恢复旧凭据或注册。
- 迁移覆盖重试、中途失败、旧字段清除、OAuth 排除、无凭据 Provider 和不同 Provider 的相同 Key。
- 磁盘仅保存加密 Key，DOM/普通响应/日志不出现完整旧 Key。
- HTTP 认证行为使用 Bypass 和协议 fixture；只运行相关 data/provider/agent/MCP/server/web scoped tests，不调用真实模型服务。

## 源码参考

- Sigma：`apps/sigma_web/lib/sigma_web/live/settings_live.ex`、`apps/sigma_session/lib/sigma_session/config_manager.ex`。
- Synapsis 数据：`apps/synapsis_data/lib/synapsis/{provider_config.ex,config/store.ex,encrypted/binary.ex}`。
- Synapsis 运行时：`apps/synapsis_provider/lib/synapsis/{providers.ex,provider/adapter.ex}`、`apps/synapsis_agent/lib/synapsis/session/worker/io_handler.ex`。
- 关联服务：`apps/synapsis_mcp/lib/synapsis/backplane/{provider_source.ex,connection.ex,skill_loader.ex}` 与 `mcp/{server.ex,transport.ex}`。

本草案只确定 Credentials 功能；Backplane 无令牌认证异常继续由 gsmlg-opt/backplane#73 跟踪。

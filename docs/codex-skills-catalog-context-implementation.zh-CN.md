# Codex Skills 目录上下文加载机制

> 从技能发现、元数据筛选，到模型可见目录、自动选择和按需读取的源码说明。

| 项目 | 基线 |
|---|---|
| 核查日期 | 2026-09-22 |
| 仓库 | `openai/codex` |
| 源码版本 | `30daed37ad8035f041f65a4c4615fbc590dc8552`，核查时的 `main` |
| 关注范围 | **把 skills 列表载入模型上下文，使模型能够自动判断何时使用 skill** |
| 核查方式 | 阅读固定提交的源码，辅以官方文档；未在本地编译或运行 Codex 测试 |

本文描述上述提交的开源实现，不将 `main` 等同于某个已发布 CLI 版本，也不推定所有桌面端、云端配置都走完全相同的路径。源码引用均固定到该提交。[S00]

## 1. 核心结论

Codex 的基本机制是：**运行时构建有预算限制的技能目录，将目录作为 `developer` 上下文提供给模型；模型根据当前任务与技能描述决定是否读取某个 `SKILL.md`。** 目录发现、目录展示和技能正文读取，是三个不同阶段。[S01], [S02], [S03], [S04]

初始目录并不是所有技能正文，也不是原样拼接各个文件的 YAML。当前实现把目录渲染为 Markdown，以 `<skills_instructions>` 包裹。YAML 是 `SKILL.md` frontmatter 和 `agents/openai.yaml` 的存储格式；目录是解析元数据后重新生成的模型输入。[S01], [S02], [S05], [S06]

“session start 时载入”可以描述首次使用体验，但不是完整的实现模型。当前源码还支持通过 world-state 上下文维护目录：首次出现时发出目录片段，状态不变时不重复追加，目录变化或被隐藏时再发出更新。[S07], [S08]

## 2. 总体数据流

下面是模块之间的职责关系，不是声称所有入口都经过同一条同步调用栈。

```text
有效配置、cwd、插件技能根目录、所选执行环境
    │
    ├─ HostSkillsService
    │    ├─ 解析技能根目录
    │    ├─ 发现 SKILL.md，解析 frontmatter 与附加元数据
    │    └─ 生成或复用 HostSkillsSnapshot
    │
    └─ 各来源 SkillProvider
         └─ 将技能转换为 SkillCatalogEntry
              │
              ├─ enabled / prompt_visible 筛选
              ├─ 按来源策略排序、选择描述
              ├─ 计算目录预算
              ├─ 分配描述空间、必要时省略条目
              └─ 比较完整路径与别名路径的渲染结果
                   │
                   ▼
         developer 上下文：<skills_instructions>…</skills_instructions>
                   │
                   ▼
         主模型结合用户任务与 description 选择技能
                   │
                   ▼
         按来源读取选中的 SKILL.md，再按需读取引用资源
```

Host 发现与缓存位于 `HostSkillsService`；provider 将来源转换成统一目录；`render.rs` 处理展示预算；context contributor 将结果交给上下文系统；模型的使用规则来自 `catalog_prompt.rs`。[S01], [S03], [S04], [S09], [S10]

## 3. 关键数据结构

| 结构或字段 | 在这条链路中的作用 |
|---|---|
| `HostSkillsLoadInput` | 携带 cwd、有效插件技能根目录、配置层，以及可复用的插件技能快照 |
| `HostSkillsSnapshot` | Host 发现结果的快照，供目录映射和后续读取使用 |
| `SkillMetadata` | 解析后的技能元数据，包括名称、描述、路径、scope、policy 等 |
| `SkillCatalogEntry` | 跨 Host、Executor、Cloud 等来源的统一目录条目 |
| `SkillAuthority`、`SkillPackageId` | 标识技能属于哪个来源及哪个包，支持正确的读取路由 |
| `enabled` | 技能是否启用 |
| `prompt_visible` | 技能是否允许进入默认模型目录 |
| `AvailableSkillsInstructions` | 把已渲染目录封装成上下文片段 |
| `SkillRenderReport` | 记录候选数、展示数、省略数和描述截断情况 |

这些结构分别出现在 host service、catalog、provider、render 和 fragments 模块中。[S02], [S03], [S09], [S10], [S11]

### 3.1 三个不同的集合

理解实现时，应始终区分：

| 集合 | 含义 |
|---|---|
| 已发现的技能目录 | 运行时知道哪些技能存在，以及它们的来源和配置状态 |
| 允许自动展示的候选集 | 已启用，而且允许出现在默认模型上下文中 |
| 实际渲染的目录 | 候选集经过预算和路径压缩之后，模型实际看到的条目 |

在 `SkillCatalogEntry` 中，候选可见性条件是 `enabled && prompt_visible`。渲染器随后再处理预算。因此，**已发现不代表模型已看到；未显示也不等于技能已禁用或删除。**[S03], [S11]

### 3.2 名称不是唯一身份

显式选择逻辑使用 `authority + package` 去重，而不是只按名称去重。技能名称相同时，路径或包标识对于消歧仍然重要。这里的身份问题与目录中显示的名称问题应当分开处理。[S12]

## 4. 技能发现、解析与缓存

### 4.1 Host 技能来自哪里

`resolve_skill_roots` 根据配置层、当前目录和插件信息收集来源，再按根路径去重。[S13]

| 来源 | 当前实现中的处理 |
|---|---|
| 项目技能 | 查找项目根目录到 cwd 路径上各级 `.agents/skills`；项目配置层也可贡献技能根目录 |
| 用户技能 | 加入用户主目录下的 `.agents/skills` |
| 兼容旧位置 | 仍读取 `$CODEX_HOME/skills`，源码标注这是兼容性位置 |
| 内置技能 | 从 Codex 的 system skills 缓存根目录发现；是否参与发现受 bundled 配置控制 |
| 管理员技能 | 从系统配置层对应的技能目录发现 |
| 插件与额外根目录 | 由有效插件根目录和 extra roots 加入发现输入 |

项目发现受运行时可用的文件系统以及项目根标记配置影响。不能简单归纳成“无条件扫描整个仓库”，也不能认为所有根目录都对应相同的 scope。[S13], [S09]

### 4.2 从磁盘格式到元数据

`parse_skill_frontmatter_metadata` 从 `SKILL.md` 开头的 `---` 区块解析 YAML，提取名称、描述和可选的 `metadata.short-description`，并将文本中的空白归一化为单行。当前解析器要求非空 description；名称缺失或为空时，会使用调用方提供的默认名称。[S05]

这是一处实现细节：官方编写规范要求填写 `name` 和 `description`，而当前解析器对 name 有兼容回退。编写技能时仍应显式填写，不应把回退行为当成推荐格式。[D01], [S05]

附加的 `agents/openai.yaml` 可提供调用 policy 等配置。Host provider 会把解析结果映射到目录条目；如果技能不允许隐式调用，就将其标记为不进入默认 prompt。[S06], [S10]

这里所谓“只加载元数据”，指的是**初始模型上下文只包含目录元数据**，并不承诺运行时发现阶段绝不读取文件正文对应的磁盘字节。文件读取、元数据解析、把文本放入模型上下文，是不同层次的操作。[S05], [S09], [S10]

### 4.3 缓存与快照

`HostSkillsService` 将发现和缓存独立于 prompt 渲染。其 `snapshot_for_config` 按有效的技能相关配置生成缓存键，而不是只用 cwd；源码明确说明，这是为了避免同目录下不同角色或 session 的技能覆盖设置相互串用。[S09]

服务还支持 cwd 缓存、请求范围内共享根扫描、插件加载阶段的快照复用、强制重载和额外根目录变更后的缓存清理。普通技能根目录与插件根目录的失效生命周期也有区别。[S09]

因此，**每轮重新计算“应该展示什么”，不等于每轮重新读取并解析所有技能文件。** 这是缓存层与上下文层分离后的结果。[S07], [S09]

## 5. 筛选规则：禁用、手动调用与预算省略

Host provider 将启用状态映射到 `enabled`，将 `allows_implicit_invocation()` 的结果映射到 `prompt_visible`。目录渲染器只保留两者都为真的条目。[S10], [S11]

| 状态 | 默认目录中的行为 | 显式选择的行为 |
|---|---|---|
| 启用、允许隐式调用、预算足够 | 展示名称、描述和定位符 | 可以选择 |
| 启用，但 `policy.allow_implicit_invocation: false` | 不进入默认目录 | 仍可通过显式 mention 或选择器定位 |
| `enabled: false` | 不进入默认目录 | 所审查的显式选择器也会排除 |
| 启用且允许隐式调用，但预算不足 | 可能缩短描述，或完全省略条目 | 预算省略本身不会把底层目录条目标为禁用 |

显式选择器针对原始目录筛选 enabled 条目，不以 `prompt_visible` 为条件；扩展的 turn-input 路径也是先收集显式 mentions，再执行目录渲染。以上“可以选择”仍以条目可定位、来源可访问为前提，不是读取必定成功的保证。[S04], [S10], [S12]

`policy.allow_implicit_invocation` 未配置时默认为 true；设置为 false 是“默认不交给模型自动选择”，而不是文件系统权限隔离。若要限制底层文件访问，需要另行依靠沙箱或资源访问权限。[D01], [S06], [S10]

## 6. 目录如何进入模型上下文

### 6.1 片段类型和消息角色

`AvailableSkillsInstructions` 的实现明确给出：[S02]

| 项目 | 值 |
|---|---|
| 消息角色 | `developer` |
| 内部 content kind | `skills.catalog` |
| 开始标记 | `<skills_instructions>` |
| 结束标记 | `</skills_instructions>` |
| 正文格式 | Markdown 标题、说明和技能条目 |

这里的 `skills.catalog` 是这个上下文片段的内部分类；不要把它误写成调用外部模型 API 时必需的自定义字段。world-state 路径也使用 developer 角色及同一对文本标签。[S02], [S08]

### 6.2 模型可见的结构示例

下面保留结构和条目形状，技能名称、路径及中文规则是说明性示例，**不是某次真实请求的抓包，也不是官方提示词全文**。[S01], [S02], [S03]

```text
<skills_instructions>
## Skills
以下列出可用技能的名称、用途和读取位置。

### Available skills
- elixir-dev: 修改 Elixir、OTP 或 Phoenix 代码时使用。 (file: /skills/elixir-dev/SKILL.md)
- pr-review: 审查代码变更的正确性及测试覆盖时使用。 (file: /skills/pr-review/SKILL.md)

### How to use skills
根据用户任务与技能描述选择相关技能。
选中后先读取完整 SKILL.md，再执行相关任务。
仅按需读取该技能引用的其他资源。
</skills_instructions>
```

未压缩的条目由名称、描述、来源类型和定位符组成。没有描述空间时，条目仍可以保留名称及定位符。当前来源标签包括 `file`、`executor package`、`cloud package` 和 `custom resource`。[S03]

`### How to use skills` 并非所有路径都无条件追加。扩展会读取模型元信息中的 `include_skills_usage_instructions`，决定是否附加这部分规则。因此，不应依靠“完整使用规则是否出现在同一个块中”判断目录是否加载成功。[S02], [S04], [S07]

### 6.3 路径别名压缩

对于具有公共前缀的路径或包定位符，渲染器可以增加 `### Skill roots`，再用短别名替代每一行重复的根路径。别名展开依据根表；对路径匹配时，别名逻辑优先使用匹配的最长根前缀。[S01], [S14]

别名不是无条件启用。渲染器会比较未压缩与别名版本，并计入根表等额外成本：优先保留更多条目，再减少描述丢失，最后比较空间成本。多来源目录还会比较仅压缩部分来源或压缩所有来源的方案。[S03]

当前别名前缀按来源区分：Host 使用 `r`，Executor 使用 `e`，Cloud 使用 `c`，从 0 开始编号。例如，Host 目录可以采用下面的结构；这里的名称、路径仍是示例。[S03], [S14]

```text
### Skill roots
- `r0` = `/skills`

### Available skills
- elixir-dev: 修改 Elixir、OTP 或 Phoenix 代码时使用。 (file: r0/elixir-dev/SKILL.md)
- pr-review: 审查代码变更时使用。 (file: r0/pr-review/SKILL.md)
```

这属于文本表示压缩，不是语义摘要，也不是一次额外的模型调用。[S03], [S14]

## 7. 上下文预算算法

### 7.1 预算从哪里来

`skill_metadata_budget` 的分支如下。W 指调用方传入的、已解析的模型上下文窗口；不是随意选择某个宣传参数。[S03], [S07]

| 条件 | 预算 |
|---|---|
| 配置了正整数 `skills.max_context_tokens = N` | `min(N, 10000)`，单位是估算 token |
| 未配置，且上下文窗口 W 已知且有效 | `max(1, floor(W × 2 / 100))`，单位是估算 token |
| 未配置，且窗口未知或无效 | 8,000 个字符 |

**10,000 的限制只出现在显式配置分支；该函数没有给默认的 2% 分支再加统一的 10,000 上限。**[S03]

以假设的输入窗口为例：W 为 128,000 时预算为 2,560；W 为 400,000 时为 8,000；W 为 1,000,000 时为 20,000。这是上述函数的算术结果，不是对特定模型窗口或已安装 Codex 版本的声明。[S03]

配置项的用户入口由官方配置参考确认；内部实现使用 `Tokens` 与 `Characters` 两种预算类型。[D02], [S03]

### 7.2 token 计数与预算范围

渲染器调用 `approx_token_count` 估计条目成本。逐字符分配描述时，还使用 UTF-8 字节数和每 token 约 4 字节的估算。因此它不是调用目标模型 tokenizer 得到的精确计费 token 数。[S03]

该预算主要约束技能目录条目及别名所增加的相关开销，不是对整条 developer 消息做一次完整、精确的 tokenizer 上限检查。不能据此断言：包括固定标题、说明、使用规则在内的整个块，必定严格小于模型窗口的 2%。[S01], [S03]

目录预算也不等于后续技能正文或工具结果的大小限制；后者属于另一阶段。[D01], [S03]

### 7.3 描述和条目的分配顺序

在进入预算分配前，渲染器先把过长的单条 description 截至最多 1,024 个字符，包含截断后追加的 `...`。之后，`allocate_skill_lines` 为每个候选计算完整条目成本，以及去掉描述后的最小条目成本，再按以下顺序分配。[S03]

| 情况 | 行为 |
|---|---|
| 所有完整条目都能放下 | 保留进入分配器时的全部描述 |
| 完整条目放不下，但所有最小条目能放下 | 保留全部条目，把剩余预算轮流分配给各条描述 |
| 所有最小条目也放不下 | 去掉描述，按现有顺序尝试放入最小条目；放不下的条目标记为 omitted |

第二种情况中，`allocate_description_chars` 按 round-robin 方式逐字符增加每条描述的保留长度，并检查增加后的成本。它保留的是描述前缀，不是重新生成一个更短的语义摘要。[S03]

第三种情况也不是“遇到第一个放不下的条目就停止”。代码继续考察后面的条目；较短的后续条目仍可能利用剩余空间。因此，输出也不一定是原列表的严格连续前缀。[S03]

### 7.4 排序会影响极端预算下的可见性

`CoreCompatible` 按 scope 排序，再按名称和主资源路径排序；scope 顺序是 System、Admin、Repo、User，最后是未指定 scope。`ExtensionCompatible` 则保留输入顺序，并优先使用可选的 `short_description`；没有短描述时使用 description。[S03]

在当前 world-state 的组合渲染中，Host 使用 `CoreCompatible`，Executor 和 Cloud 使用 `ExtensionCompatible`。组合目录把 Executor、Cloud、Host 的条目接起来，共用一次预算分配；并不是每个来源各自获得完整的 2% 预算。[S03], [S07]

这些是渲染顺序与空间分配策略，**不是针对当前用户任务计算出的相关性排序**。不能将“排在前面”解释为“更适合这个任务”。[S03]

### 7.5 可观测结果

`SkillRenderReport` 包含 `total_count`、`included_count`、`omitted_count`、`truncated_description_chars`、`truncated_description_count`。当出现省略条目时，当前报告会生成以 `Exceeded skills context budget` 开头的警告；仅缩短描述而没有省略技能时，这个 warning 方法不会生成同样的警告。[S03]

这些统计描述的是本次参与渲染的候选集合，不应直接当作所有磁盘技能的总量。world-state 路径还在 turn 内对重复的预算警告做去重。[S03], [S07]

部分来源策略还会在模型可见目录内保留“另有若干技能被省略”的说明。说明本身也占预算；为放入说明，渲染器可能进一步移除已选的尾部条目。不要仅根据初次条目分配推算最终展示数。[S03]

## 8. 模型如何自动使用技能

### 8.1 语义选择由主模型完成

目录提示词规定：当任务与某项技能的描述明显匹配，或者用户指定技能时，应使用该技能；选择后，由主 agent 先读取完整 `SKILL.md`，再开展任务，并仅按需读取相关引用资源。[S01]

对于本文关注的目录驱动路径，可以理解为：

```text
用户：检查这个 Phoenix 项目的 supervision tree
    ↓
模型已看到 elixir-dev 的用途描述和读取位置
    ↓
模型判断该技能与当前任务相关
    ↓
模型通过可用工具读取对应 SKILL.md
    ↓
技能内容进入后续上下文，指导具体分析或修改
```

这是流程示例，不是保证某个模型每次都会选对技能。目录使自动选择成为可能，调用规则要求其遵循流程，但匹配结果仍依赖模型对任务和描述的理解。[S01]

### 8.2 读取方式由来源决定

| 来源 | 目录如何指导读取 |
|---|---|
| Host / `file` | 打开给出的文件路径；若用了别名，先按根表展开 |
| Executor / Cloud package | 使用对应 package 调用 `skills.read`；可以直接读取主文档，不必为已知 package 再调用一次 `skills.list` |
| Custom resource | 使用该 provider 对应的访问机制 |

provider 契约要求维持来源边界：由哪个 authority 列出的资源，就应通过相应的来源读取或搜索，而不是把任意包标识转换成当前主机上的文件路径。[S01], [S04], [S15]

### 8.3 不要把调用检测器当作自动匹配器

`detect_implicit_skill_invocation` 接收的是命令、工作目录和环境信息；它识别命令是否访问了技能文档或技能脚本，并返回调用归属信息。它不是拿用户自然语言去匹配技能描述的分类器。[S16]

换句话说：**模型先决定并发出技能相关访问，运行时再识别和记录这次访问；这与运行时先用关键词算法替模型选技能，是两回事。**[S01], [S16]

### 8.4 当前源码中的 selector 与 search 应如何理解

源码存在 `shadow_selection_enabled` 和相关 selector 逻辑，但配置注释明确：这是 shadow mode，运行便宜的选择器而不改变实际 prompt。不能据此声称主路径已经默认使用它做任务相关的 Top-K 目录裁剪。[S04], [S17]

同样，`SkillProvider` 存在 search 接口，并不意味着 Host 自动目录已经使用全局语义搜索。当前 `HostSkillProvider::search` 返回空的默认结果。本文的结论仅限所审查的 Host 目录路径，不据此否定其他 provider 或客户端拥有独立发现能力。[S10], [S15]

## 9. 注入时机：首次上下文、每轮与状态更新

### 9.1 Thread 生命周期不等于直接拼接 Host 目录

`on_thread_start` 初始化 skills session/thread 状态和配置。独立的 `contribute_thread_context` 路径可以贡献目录，但其查询显式关闭 Host 技能来源。因而不能把这个回调直接画成“扫描本机全部 skills 并注入”的唯一入口。[S04]

### 9.2 当前 world-state 路径

`contribute_world_state` 通过 `CatalogContext` 获取不同来源的目录，按组合预算渲染，再构造上下文分区。当前分区 ID 包括 `skills`、`cloud_skills` 和 `host_skills`。[S07], [S08]

world-state 的片段生成会比较前后快照中的目录正文、`includeInstructions` 和相关启用状态：[S08]

| 状态变化 | 生成行为 |
|---|---|
| 首次出现且有可见目录 | 发出目录片段 |
| 前后目录和相关开关相同 | 不生成新的重复片段 |
| 目录或开关发生变化 | 发出更新后的片段 |
| 以前有目录，现在为空或隐藏 | 发出“无可用技能”或“不自动展示”等状态说明 |
| Host 候选存在，但全部因预算省略 | 可发出因预算未展示的专门说明 |

变更时生成的是相应分区的新正文或状态说明，不是逐条 skill 的增删补丁。这里讨论的是上下文片段生成与历史状态维护，不是承诺网络请求只发送这一小段文本。[S08]

**不重复追加目录，不代表该目录之后不再占模型上下文。** 如果它仍存在于保留的历史或构造出的请求上下文中，就仍是模型需要处理的上下文内容；是否命中模型服务端缓存是另一层问题。[S08]

### 9.3 Turn-input 路径与去重

扩展还实现 `TurnInputContributor::contribute`。当 Host 目录已经由 world-state 提供时，会通过 `HostSkillsCatalogInWorldState` 标记避免再走相应的目录注入分支；否则，符合条件的来源可以在 turn-input 路径提供目录。[S04], [S07]

因此，正确的概括是：**首次可见上下文中提供目录，后续由上下文贡献器和状态快照维护；不是每次用户发言都无条件附加一份相同列表。** 不同入口、来源和配置决定具体走哪个分支。[S04], [S07], [S08]

## 10. 与选中技能正文的边界

默认目录使用 `<skills_instructions>`，其目的是让模型知道“有哪些技能、何时使用、去哪里读”。显式选中技能后的正文注入是另一种片段：`SkillInstructions` 使用 `user` 角色和 `<skill>` 标签，并包含 name、path 和 contents；资源型技能还可附加访问元数据。[S02]

不能由此推导出“所有自动读取正文都会变成 `<skill>` user 消息”。在目录驱动的隐式路径中，模型通过文件或资源工具读取正文，读到的内容通过相应工具交互进入上下文。这两条路径应分开描述。[S01], [S02]

目录预算也不负责删除历史中已经读过的正文。提示词中“不自动沿用上一轮的技能”是一条使用规则，而不是证明系统会在每轮结束时物理清除该技能的所有文本。[S01], [S03]

## 11. 复用这一机制时的职责边界

以下是从上述实现提炼的设计划分，不是新增的 Codex API，也不是对其他项目当前实现的描述。

| 层 | 应保留的职责 |
|---|---|
| 发现与解析 | 从文件或 provider 获得带稳定身份和来源的元数据 |
| 策略筛选 | 分开表达禁用、允许显式调用、允许默认展示 |
| 纯渲染与预算 | 从目录快照、展示策略和预算生成文本及统计报告 |
| 上下文生命周期 | 决定何时发送片段，维护版本、去重和清空状态 |
| 模型选择 | 根据用户需求与目录描述选择技能，不把目录顺序当作相关性 |
| 按来源读取 | 读取技能正文与引用资源，并保留访问控制及调用记录 |

这几层可以按“不可变快照 → 筛选 → 排序 → 预算分配 → 渲染结果”的函数式流水线组织；文件访问、缓存和消息追加作为外层副作用处理。这样可以单独测试目录渲染，不必启动模型或读写实际项目。[S03], [S09], [S11]

对于大量技能，特别需要注意：当前预算算法的目标是限制上下文占用，不是维持语义召回率。描述被截短、删除或条目被省略后，模型从该目录获得的选型信息会减少。任务相关检索、Top-K 候选和分层路由应当作为额外设计，不要标注为本文已证实的 Codex Host 默认机制。[S03], [S17]

## 12. 实现核对清单

以下是依据源码机制整理的检查点，**不是本次已经执行并通过的测试记录**。

| 检查项 | 应验证的结果 |
|---|---|
| 目录与正文分离 | 初始片段只有技能摘要、来源定位符和使用规则，不包含所有正文 |
| 消息结构 | 目录为 developer 上下文，使用 `<skills_instructions>` 和 Markdown |
| 手动专用技能 | 不进入默认目录，但仍可显式定位；与 disabled 状态区分 |
| 预算边界 | 分别测试完整条目能放下、只够短描述、只能保留部分最小条目的情况 |
| 预算单位 | 区分估算 token 与字符；检查显式配置上限和默认 2% 分支 |
| 中文与长路径 | 截断不破坏字符边界，别名成本不抵消压缩收益 |
| 目录状态更新 | 未变不重复追加；变化、清空、隐藏时模型收到正确状态 |
| 多来源身份 | 同名不同来源不因只按 name 去重而错误合并 |
| 来源读取 | 不把 Executor 或 Cloud 的包标识误当作 Host 文件路径 |
| 调用归因 | 不把访问检测器当作自动选择器，也不把 shadow 结果当作主模型决策 |

## 附录：源码导航与引用

所有 S 类链接都固定到同一提交。D 类链接是核查时读取的官方在线文档，后续可能更新。

| 引用 | 文件／资料 | 建议查看的位置 |
|---|---|---|
| [S00] | 固定提交 | 本文源码基线 |
| [S01] | `ext/skills/src/catalog_prompt.rs` | 模型可见目录正文、使用规则和来源读取说明 |
| [S02] | `ext/skills/src/fragments.rs` | `AvailableSkillsInstructions`、`SkillInstructions` |
| [S03] | `ext/skills/src/render.rs` | `skill_metadata_budget`、`allocate_skill_lines`、`allocate_description_chars`、`render_combined_available_skills` |
| [S04] | `ext/skills/src/extension.rs` | thread/context/world-state/turn-input 贡献入口 |
| [S05] | `skills/src/parser.rs` | frontmatter 解析和单行化 |
| [S06] | 内置 skill-creator 的 `references/openai_yaml.md` | `allow_implicit_invocation` 的语义 |
| [S07] | `ext/skills/src/world_state_catalogs.rs` | 多来源目录发现、组合渲染与去重标记 |
| [S08] | `ext/skills/src/world_state.rs` | 前后快照比较、developer 片段和空目录状态 |
| [S09] | `ext/skills/src/host_service.rs` | 快照、缓存、失效与有效配置隔离 |
| [S10] | `ext/skills/src/provider/host.rs` | Host metadata → catalog，enabled/prompt_visible 映射 |
| [S11] | `ext/skills/src/catalog.rs` | 跨来源身份、目录字段和模型可见性 |
| [S12] | `ext/skills/src/selection.rs` | 显式技能选择、enabled 过滤和身份去重 |
| [S13] | `ext/skills/src/host_roots.rs` | 项目、用户、内置、管理员和插件根目录 |
| [S14] | `ext/skills/src/aliases.rs` | 根别名生成与最长前缀匹配 |
| [S15] | `ext/skills/src/provider.rs` | 来源保持、list/read/search 契约 |
| [S16] | `ext/skills/src/invocation.rs` | 命令中的技能访问检测和调用归属 |
| [S17] | `ext/skills/src/config.rs` | 目录开关、预算、shadow selection 的配置含义 |
| [D01] | 官方 Build skills 文档 | 目录渐进加载、隐式调用和作者配置 |
| [D02] | 官方 Configuration Reference | `skills.max_context_tokens` 配置入口 |

[S00]: https://github.com/openai/codex/commit/30daed37ad8035f041f65a4c4615fbc590dc8552
[S01]: https://github.com/openai/codex/blob/30daed37ad8035f041f65a4c4615fbc590dc8552/codex-rs/ext/skills/src/catalog_prompt.rs
[S02]: https://github.com/openai/codex/blob/30daed37ad8035f041f65a4c4615fbc590dc8552/codex-rs/ext/skills/src/fragments.rs
[S03]: https://github.com/openai/codex/blob/30daed37ad8035f041f65a4c4615fbc590dc8552/codex-rs/ext/skills/src/render.rs
[S04]: https://github.com/openai/codex/blob/30daed37ad8035f041f65a4c4615fbc590dc8552/codex-rs/ext/skills/src/extension.rs
[S05]: https://github.com/openai/codex/blob/30daed37ad8035f041f65a4c4615fbc590dc8552/codex-rs/skills/src/parser.rs
[S06]: https://github.com/openai/codex/blob/30daed37ad8035f041f65a4c4615fbc590dc8552/codex-rs/skills/src/assets/samples/skill-creator/references/openai_yaml.md
[S07]: https://github.com/openai/codex/blob/30daed37ad8035f041f65a4c4615fbc590dc8552/codex-rs/ext/skills/src/world_state_catalogs.rs
[S08]: https://github.com/openai/codex/blob/30daed37ad8035f041f65a4c4615fbc590dc8552/codex-rs/ext/skills/src/world_state.rs
[S09]: https://github.com/openai/codex/blob/30daed37ad8035f041f65a4c4615fbc590dc8552/codex-rs/ext/skills/src/host_service.rs
[S10]: https://github.com/openai/codex/blob/30daed37ad8035f041f65a4c4615fbc590dc8552/codex-rs/ext/skills/src/provider/host.rs
[S11]: https://github.com/openai/codex/blob/30daed37ad8035f041f65a4c4615fbc590dc8552/codex-rs/ext/skills/src/catalog.rs
[S12]: https://github.com/openai/codex/blob/30daed37ad8035f041f65a4c4615fbc590dc8552/codex-rs/ext/skills/src/selection.rs
[S13]: https://github.com/openai/codex/blob/30daed37ad8035f041f65a4c4615fbc590dc8552/codex-rs/ext/skills/src/host_roots.rs
[S14]: https://github.com/openai/codex/blob/30daed37ad8035f041f65a4c4615fbc590dc8552/codex-rs/ext/skills/src/aliases.rs
[S15]: https://github.com/openai/codex/blob/30daed37ad8035f041f65a4c4615fbc590dc8552/codex-rs/ext/skills/src/provider.rs
[S16]: https://github.com/openai/codex/blob/30daed37ad8035f041f65a4c4615fbc590dc8552/codex-rs/ext/skills/src/invocation.rs
[S17]: https://github.com/openai/codex/blob/30daed37ad8035f041f65a4c4615fbc590dc8552/codex-rs/ext/skills/src/config.rs
[D01]: https://developers.openai.com/codex/skills/
[D02]: https://developers.openai.com/codex/config-reference/

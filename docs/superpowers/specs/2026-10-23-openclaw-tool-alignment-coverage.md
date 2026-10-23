# OpenClaw 能力参考：基于 Backplane 契约的覆盖矩阵

固定来源：`openclaw/openclaw@488631c18fae7cc541ba8fc8beff6cbb0438787b`。最后静态核对：2026-10-23。

本附件是上游能力参考清单，不是本地可执行工具目录或完成报告。扫描174份插件manifest，其中34份声明工具；67个核心目录名字与109个唯一插件工具名合并去重后为170项。名称、schema、alias和默认值属于来源事实，不能直接决定Synapsis接口；实际工具以 `backplane_agent_runtime` 的原生契约为准。已有逐工具初步映射，逐 action 参考行为与验收仍待 P0 补齐；允许多对一和一对多，不要求新增170个同名工具。没有运行全部factory或验证全部backend。

[设计](2026-10-23-openclaw-tool-alignment-design.md) · [实施计划](../plans/2026-10-23-openclaw-tool-alignment.md) · [机器可读来源、hash与条件](2026-10-23-openclaw-tool-alignment-baseline.json) · [逐工具能力映射](../../../apps/synapsis_agent/test/fixtures/openclaw/488631c/capability-map.json)

当前 [参考采集夹具](../../../apps/synapsis_agent/test/fixtures/openclaw/488631c/capture.json) 已保存 voice-call、Canvas、llm-task 的 5 个 schema/factory recipe，并将来源及 schema hash 链接到能力映射；Canvas 与 llm-task 的实际 factory 返回元数据与 schema 定义一致。所有目标能力的实现、行为与外部验证状态仍未完成；这些样本不改变下表的完成状态。

## 1. 按任务分配的170个上游参考项

| # | OpenClaw 来源键 | Core 分组 | 声明插件 | 任务 | 评估状态 |
| --- | --- | --- | --- | --- | --- |
| 1 | `agents_list` | agents | — | P5 | 宿主扩展；待实现 |
| 2 | `agents_wait` | sessions | — | P5 | 原生复用候选；action 待证 |
| 3 | `apply_patch` | fs | — | P3 | 原生复用候选；action 待证 |
| 4 | `ask_user` | agents | — | P6 | 原生复用候选；action 待证 |
| 5 | `automations` | automation | — | P6 | 宿主扩展；待实现 |
| 6 | `autoreview` | — | autoreview | P13 | 宿主扩展；待实现 |
| 7 | `browser` | ui | browser | P8 | 宿主扩展；待实现 |
| 8 | `canvas` | ui | canvas | P12 | 宿主适配；待实现 |
| 9 | `code_execution` | runtime | xai | P10 | 宿主扩展；待实现 |
| 10 | `codex_endpoint_probe` | — | codex | P13 | 宿主扩展；待实现 |
| 11 | `codex_plugins` | — | codex | P13 | 宿主扩展；待实现 |
| 12 | `codex_session_interrupt` | — | codex | P13 | 宿主扩展；待实现 |
| 13 | `codex_session_read` | — | codex | P13 | 宿主扩展；待实现 |
| 14 | `codex_session_send` | — | codex | P13 | 宿主扩展；待实现 |
| 15 | `codex_sessions_list` | — | codex | P13 | 宿主扩展；待实现 |
| 16 | `codex_threads` | — | codex | P13 | 宿主扩展；待实现 |
| 17 | `computer` | nodes | — | P12 | 宿主扩展；待实现 |
| 18 | `conversations_list` | sessions | — | P11 | 宿主扩展；待实现 |
| 19 | `conversations_send` | sessions | — | P11 | 宿主扩展；待实现 |
| 20 | `conversations_turn` | sessions | — | P11 | 宿主扩展；待实现 |
| 21 | `crabbox` | — | crabbox | P13 | 宿主扩展；待实现 |
| 22 | `create_goal` | agents | — | P6 | 宿主扩展；待实现 |
| 23 | `dashboard` | ui | — | P12 | 宿主适配；待实现 |
| 24 | `decision_evaluate` | agents | — | P6 | 宿主扩展；待实现 |
| 25 | `diffs` | — | diffs | P13 | 宿主扩展；待实现 |
| 26 | `dir_fetch` | — | file-transfer | P12 | 宿主扩展；待实现 |
| 27 | `dir_list` | — | file-transfer | P12 | 宿主扩展；待实现 |
| 28 | `discussion` | — | clickclack | P13 | 宿主扩展；待实现 |
| 29 | `dismiss_task` | sessions | — | P5 | 宿主扩展；待实现 |
| 30 | `edit` | fs | — | P3 | 宿主扩展；待实现 |
| 31 | `exec` | runtime | — | P3 | 原生复用候选；action 待证 |
| 32 | `facetime_call` | — | facetime | P11 | 宿主扩展；待实现 |
| 33 | `feishu_app_scopes` | — | feishu | P11 | 宿主扩展；待实现 |
| 34 | `feishu_bitable_create_app` | — | feishu | P11 | 宿主扩展；待实现 |
| 35 | `feishu_bitable_create_field` | — | feishu | P11 | 宿主扩展；待实现 |
| 36 | `feishu_bitable_create_record` | — | feishu | P11 | 宿主扩展；待实现 |
| 37 | `feishu_bitable_get_meta` | — | feishu | P11 | 宿主扩展；待实现 |
| 38 | `feishu_bitable_get_record` | — | feishu | P11 | 宿主扩展；待实现 |
| 39 | `feishu_bitable_list_fields` | — | feishu | P11 | 宿主扩展；待实现 |
| 40 | `feishu_bitable_list_records` | — | feishu | P11 | 宿主扩展；待实现 |
| 41 | `feishu_bitable_update_record` | — | feishu | P11 | 宿主扩展；待实现 |
| 42 | `feishu_chat` | — | feishu | P11 | 宿主扩展；待实现 |
| 43 | `feishu_doc` | — | feishu | P11 | 宿主扩展；待实现 |
| 44 | `feishu_drive` | — | feishu | P11 | 宿主扩展；待实现 |
| 45 | `feishu_perm` | — | feishu | P11 | 宿主扩展；待实现 |
| 46 | `feishu_wiki` | — | feishu | P11 | 宿主扩展；待实现 |
| 47 | `file_fetch` | — | file-transfer | P12 | 宿主扩展；待实现 |
| 48 | `file_write` | — | file-transfer | P12 | 宿主扩展；待实现 |
| 49 | `firecrawl_scrape` | — | firecrawl | P8 | 宿主扩展；待实现 |
| 50 | `firecrawl_search` | — | firecrawl | P8 | 宿主扩展；待实现 |
| 51 | `gateway` | automation | — | P13 | 宿主适配；待实现 |
| 52 | `get_goal` | agents | — | P6 | 宿主扩展；待实现 |
| 53 | `github_identity_status` | sessions | — | P13 | 宿主扩展；待实现 |
| 54 | `github_publish` | sessions | — | P13 | 宿主扩展；待实现 |
| 55 | `github_read` | — | github | P13 | 宿主扩展；待实现 |
| 56 | `github_search` | — | github | P13 | 宿主扩展；待实现 |
| 57 | `google_meet` | — | google-meet | P11 | 宿主扩展；待实现 |
| 58 | `image_generate` | media | — | P10 | 原生复用候选；action 待证 |
| 59 | `intent` | — | memory-core | P4 | 宿主扩展；待实现 |
| 60 | `llm-task` | — | llm-task | P13 | 宿主扩展；待实现 |
| 61 | `lobster` | — | lobster | P13 | 宿主扩展；待实现 |
| 62 | `local_image` | — | llama-cpp | P10 | 宿主扩展；待实现 |
| 63 | `ls` | fs | — | P3 | 宿主扩展；待实现 |
| 64 | `mcp_events` | — | mcp-events | P9 | 宿主扩展；待实现 |
| 65 | `memory_forget` | — | memory-lancedb | P4 | 宿主扩展；待实现 |
| 66 | `memory_get` | memory | memory-core | P4 | 宿主扩展；待实现 |
| 67 | `memory_recall` | — | memory-lancedb | P4 | 宿主扩展；待实现 |
| 68 | `memory_search` | memory | memory-core | P4 | 宿主扩展；待实现 |
| 69 | `memory_store` | — | memory-lancedb | P4 | 宿主扩展；待实现 |
| 70 | `message` | messaging | — | P11 | 宿主扩展；待实现 |
| 71 | `mobile_ui` | nodes | — | P12 | 宿主扩展；待实现 |
| 72 | `music_generate` | media | — | P10 | 宿主扩展；待实现 |
| 73 | `node_inference` | — | ollama | P12 | 宿主扩展；待实现 |
| 74 | `nodes` | nodes | — | P12 | 宿主扩展；待实现 |
| 75 | `onepassword` | — | onepassword | P13 | 宿主扩展；待实现 |
| 76 | `openclaw` | automation | — | P13 | 宿主适配；待实现 |
| 77 | `pdf` | media | — | P10 | 宿主扩展；待实现 |
| 78 | `personal_instructions` | memory | — | P4 | 宿主适配；待实现 |
| 79 | `plugins` | automation | — | P13 | 宿主扩展；待实现 |
| 80 | `portal` | ui | — | P12 | 宿主适配；待实现 |
| 81 | `presence` | sessions | — | P5 | 宿主适配；待实现 |
| 82 | `process` | runtime | — | P3 | 原生复用候选；action 待证 |
| 83 | `progress_card` | agents | — | P6 | 宿主扩展；待实现 |
| 84 | `qa_restart_unsafe_probe` | — | qa-lab | P15 | 仅隔离测试；不生产暴露 |
| 85 | `qa_restart_wait` | — | qa-lab | P15 | 仅隔离测试；不生产暴露 |
| 86 | `read` | fs | — | P3 | 宿主扩展；待实现 |
| 87 | `screen` | ui | — | P12 | 宿主适配；待实现 |
| 88 | `secrets` | runtime | — | P7 | 宿主扩展；待实现 |
| 89 | `session_status` | sessions | — | P5 | 宿主扩展；待实现 |
| 90 | `sessions` | sessions | — | P5 | 宿主扩展；待实现 |
| 91 | `sessions_create` | sessions | — | P5 | 宿主扩展；待实现 |
| 92 | `sessions_history` | sessions | — | P5 | 宿主扩展；待实现 |
| 93 | `sessions_list` | sessions | — | P5 | 宿主扩展；待实现 |
| 94 | `sessions_search` | sessions | — | P5 | 宿主扩展；待实现 |
| 95 | `sessions_send` | sessions | — | P5 | 宿主扩展；待实现 |
| 96 | `sessions_spawn` | sessions | — | P5 | 原生复用候选；action 待证 |
| 97 | `sessions_yield` | sessions | — | P5 | 缺口；待补齐 |
| 98 | `show_widget` | ui | — | P12 | 宿主适配；待实现 |
| 99 | `skill_workshop` | agents | — | P4 | 宿主扩展；待实现 |
| 100 | `skills_read` | agents | — | P4 | 宿主扩展；待实现 |
| 101 | `skills_search` | agents | — | P4 | 宿主扩展；待实现 |
| 102 | `slack_huddles` | — | slack-huddles | P11 | 宿主扩展；待实现 |
| 103 | `subagents` | sessions | — | P5 | 原生复用候选；action 待证 |
| 104 | `suggest_task` | sessions | — | P5 | 宿主扩展；待实现 |
| 105 | `talk_voice` | — | talk-voice | P11 | 宿主扩展；待实现 |
| 106 | `tavily_extract` | — | tavily | P8 | 宿主扩展；待实现 |
| 107 | `tavily_search` | — | tavily | P8 | 宿主扩展；待实现 |
| 108 | `teams_meetings` | — | teams-meetings | P11 | 宿主扩展；待实现 |
| 109 | `terminal` | ui | — | P3 | 宿主扩展；待实现 |
| 110 | `theme` | ui | — | P12 | 宿主适配；待实现 |
| 111 | `transcripts` | media | — | P11 | 宿主扩展；待实现 |
| 112 | `tts` | media | — | P10 | 宿主扩展；待实现 |
| 113 | `update_goal` | agents | — | P6 | 宿主扩展；待实现 |
| 114 | `video_generate` | media | — | P10 | 宿主扩展；待实现 |
| 115 | `view_image` | media | — | P10 | 原生复用候选；action 待证 |
| 116 | `visitor_invite` | — | visitor-access | P13 | 宿主扩展；待实现 |
| 117 | `visitor_list` | — | visitor-access | P13 | 宿主扩展；待实现 |
| 118 | `visitor_revoke` | — | visitor-access | P13 | 宿主扩展；待实现 |
| 119 | `voice_call` | — | voice-call | P11 | 宿主扩展；待实现 |
| 120 | `web_fetch` | web | — | P8 | 原生复用候选；action 待证 |
| 121 | `web_search` | web | — | P8 | 原生复用候选；action 待证 |
| 122 | `whatsapp_call` | — | whatsapp | P11 | 宿主扩展；待实现 |
| 123 | `whatsapp_login` | — | whatsapp | P11 | 宿主扩展；待实现 |
| 124 | `wiki_apply` | — | memory-wiki | P4 | 宿主扩展；待实现 |
| 125 | `wiki_get` | — | memory-wiki | P4 | 宿主扩展；待实现 |
| 126 | `wiki_lint` | — | memory-wiki | P4 | 宿主扩展；待实现 |
| 127 | `wiki_search` | — | memory-wiki | P4 | 宿主扩展；待实现 |
| 128 | `wiki_status` | — | memory-wiki | P4 | 宿主扩展；待实现 |
| 129 | `workboard_attachment_add` | — | workboard | P13 | 宿主扩展；待实现 |
| 130 | `workboard_attachment_delete` | — | workboard | P13 | 宿主扩展；待实现 |
| 131 | `workboard_attachment_read` | — | workboard | P13 | 宿主扩展；待实现 |
| 132 | `workboard_block` | — | workboard | P13 | 宿主扩展；待实现 |
| 133 | `workboard_board_archive` | — | workboard | P13 | 宿主扩展；待实现 |
| 134 | `workboard_board_create` | — | workboard | P13 | 宿主扩展；待实现 |
| 135 | `workboard_board_delete` | — | workboard | P13 | 宿主扩展；待实现 |
| 136 | `workboard_boards` | — | workboard | P13 | 宿主扩展；待实现 |
| 137 | `workboard_claim` | — | workboard | P13 | 宿主扩展；待实现 |
| 138 | `workboard_comment` | — | workboard | P13 | 宿主扩展；待实现 |
| 139 | `workboard_complete` | — | workboard | P13 | 宿主扩展；待实现 |
| 140 | `workboard_create` | — | workboard | P13 | 宿主扩展；待实现 |
| 141 | `workboard_decompose` | — | workboard | P13 | 宿主扩展；待实现 |
| 142 | `workboard_dispatch` | — | workboard | P13 | 宿主扩展；待实现 |
| 143 | `workboard_heartbeat` | — | workboard | P13 | 宿主扩展；待实现 |
| 144 | `workboard_link` | — | workboard | P13 | 宿主扩展；待实现 |
| 145 | `workboard_list` | — | workboard | P13 | 宿主扩展；待实现 |
| 146 | `workboard_move` | — | workboard | P13 | 宿主扩展；待实现 |
| 147 | `workboard_notify_advance` | — | workboard | P13 | 宿主扩展；待实现 |
| 148 | `workboard_notify_events` | — | workboard | P13 | 宿主扩展；待实现 |
| 149 | `workboard_notify_list` | — | workboard | P13 | 宿主扩展；待实现 |
| 150 | `workboard_notify_subscribe` | — | workboard | P13 | 宿主扩展；待实现 |
| 151 | `workboard_notify_unsubscribe` | — | workboard | P13 | 宿主扩展；待实现 |
| 152 | `workboard_promote` | — | workboard | P13 | 宿主扩展；待实现 |
| 153 | `workboard_proof` | — | workboard | P13 | 宿主扩展；待实现 |
| 154 | `workboard_protocol_violation` | — | workboard | P13 | 宿主扩展；待实现 |
| 155 | `workboard_read` | — | workboard | P13 | 宿主扩展；待实现 |
| 156 | `workboard_reassign` | — | workboard | P13 | 宿主扩展；待实现 |
| 157 | `workboard_reclaim` | — | workboard | P13 | 宿主扩展；待实现 |
| 158 | `workboard_release` | — | workboard | P13 | 宿主扩展；待实现 |
| 159 | `workboard_runs` | — | workboard | P13 | 宿主扩展；待实现 |
| 160 | `workboard_sessions_board_move` | — | workboard | P13 | 宿主扩展；待实现 |
| 161 | `workboard_sessions_board_read` | — | workboard | P13 | 宿主扩展；待实现 |
| 162 | `workboard_sessions_board_update` | — | workboard | P13 | 宿主扩展；待实现 |
| 163 | `workboard_specify` | — | workboard | P13 | 宿主扩展；待实现 |
| 164 | `workboard_stats` | — | workboard | P13 | 宿主扩展；待实现 |
| 165 | `workboard_unblock` | — | workboard | P13 | 宿主扩展；待实现 |
| 166 | `workboard_worker_log` | — | workboard | P13 | 宿主扩展；待实现 |
| 167 | `write` | fs | — | P3 | 宿主扩展；待实现 |
| 168 | `x_search` | web | xai | P10 | 原生复用候选；action 待证 |
| 169 | `zalouser` | — | zalouser | P11 | 宿主扩展；待实现 |
| 170 | `zoom_meetings` | — | zoom-meetings | P11 | 宿主扩展；待实现 |

## 2. 插件来源与启用默认值

默认值unspecified表示上游manifest未声明，不能推断为默认开启；完整auth/config/optional/profiles/activation字段保留在JSON。它们是OpenClaw来源事实，不自动迁为Synapsis默认值；enabledByDefault也不授予调用权限。

| 插件 | 声明数 | manifest 默认 | 任务 | 来源 |
| --- | --- | --- | --- | --- |
| autoreview | 1 | unspecified | P13 | [manifest](https://github.com/openclaw/openclaw/blob/488631c18fae7cc541ba8fc8beff6cbb0438787b/extensions/autoreview/openclaw.plugin.json) |
| browser | 1 | true | P8 | [manifest](https://github.com/openclaw/openclaw/blob/488631c18fae7cc541ba8fc8beff6cbb0438787b/extensions/browser/openclaw.plugin.json) |
| canvas | 1 | true | P12 | [manifest](https://github.com/openclaw/openclaw/blob/488631c18fae7cc541ba8fc8beff6cbb0438787b/extensions/canvas/openclaw.plugin.json) |
| clickclack | 1 | unspecified | P13 | [manifest](https://github.com/openclaw/openclaw/blob/488631c18fae7cc541ba8fc8beff6cbb0438787b/extensions/clickclack/openclaw.plugin.json) |
| codex | 7 | unspecified | P13 | [manifest](https://github.com/openclaw/openclaw/blob/488631c18fae7cc541ba8fc8beff6cbb0438787b/extensions/codex/openclaw.plugin.json) |
| crabbox | 1 | unspecified | P13 | [manifest](https://github.com/openclaw/openclaw/blob/488631c18fae7cc541ba8fc8beff6cbb0438787b/extensions/crabbox/openclaw.plugin.json) |
| diffs | 1 | unspecified | P13 | [manifest](https://github.com/openclaw/openclaw/blob/488631c18fae7cc541ba8fc8beff6cbb0438787b/extensions/diffs/openclaw.plugin.json) |
| facetime | 1 | false | P11 | [manifest](https://github.com/openclaw/openclaw/blob/488631c18fae7cc541ba8fc8beff6cbb0438787b/extensions/facetime/openclaw.plugin.json) |
| feishu | 14 | unspecified | P11 | [manifest](https://github.com/openclaw/openclaw/blob/488631c18fae7cc541ba8fc8beff6cbb0438787b/extensions/feishu/openclaw.plugin.json) |
| file-transfer | 4 | true | P12 | [manifest](https://github.com/openclaw/openclaw/blob/488631c18fae7cc541ba8fc8beff6cbb0438787b/extensions/file-transfer/openclaw.plugin.json) |
| firecrawl | 2 | unspecified | P8 | [manifest](https://github.com/openclaw/openclaw/blob/488631c18fae7cc541ba8fc8beff6cbb0438787b/extensions/firecrawl/openclaw.plugin.json) |
| github | 2 | true | P13 | [manifest](https://github.com/openclaw/openclaw/blob/488631c18fae7cc541ba8fc8beff6cbb0438787b/extensions/github/openclaw.plugin.json) |
| google-meet | 1 | true | P11 | [manifest](https://github.com/openclaw/openclaw/blob/488631c18fae7cc541ba8fc8beff6cbb0438787b/extensions/google-meet/openclaw.plugin.json) |
| llama-cpp | 1 | true | P10 | [manifest](https://github.com/openclaw/openclaw/blob/488631c18fae7cc541ba8fc8beff6cbb0438787b/extensions/llama-cpp/openclaw.plugin.json) |
| llm-task | 1 | unspecified | P13 | [manifest](https://github.com/openclaw/openclaw/blob/488631c18fae7cc541ba8fc8beff6cbb0438787b/extensions/llm-task/openclaw.plugin.json) |
| lobster | 1 | unspecified | P13 | [manifest](https://github.com/openclaw/openclaw/blob/488631c18fae7cc541ba8fc8beff6cbb0438787b/extensions/lobster/openclaw.plugin.json) |
| mcp-events | 1 | false | P9 | [manifest](https://github.com/openclaw/openclaw/blob/488631c18fae7cc541ba8fc8beff6cbb0438787b/extensions/mcp-events/openclaw.plugin.json) |
| memory-core | 3 | unspecified | P4 | [manifest](https://github.com/openclaw/openclaw/blob/488631c18fae7cc541ba8fc8beff6cbb0438787b/extensions/memory-core/openclaw.plugin.json) |
| memory-lancedb | 3 | unspecified | P4 | [manifest](https://github.com/openclaw/openclaw/blob/488631c18fae7cc541ba8fc8beff6cbb0438787b/extensions/memory-lancedb/openclaw.plugin.json) |
| memory-wiki | 5 | unspecified | P4 | [manifest](https://github.com/openclaw/openclaw/blob/488631c18fae7cc541ba8fc8beff6cbb0438787b/extensions/memory-wiki/openclaw.plugin.json) |
| ollama | 1 | true | P12 | [manifest](https://github.com/openclaw/openclaw/blob/488631c18fae7cc541ba8fc8beff6cbb0438787b/extensions/ollama/openclaw.plugin.json) |
| onepassword | 1 | unspecified | P13 | [manifest](https://github.com/openclaw/openclaw/blob/488631c18fae7cc541ba8fc8beff6cbb0438787b/extensions/onepassword/openclaw.plugin.json) |
| qa-lab | 2 | unspecified | P15 | [manifest](https://github.com/openclaw/openclaw/blob/488631c18fae7cc541ba8fc8beff6cbb0438787b/extensions/qa-lab/openclaw.plugin.json) |
| slack-huddles | 1 | false | P11 | [manifest](https://github.com/openclaw/openclaw/blob/488631c18fae7cc541ba8fc8beff6cbb0438787b/extensions/slack-huddles/openclaw.plugin.json) |
| talk-voice | 1 | true | P11 | [manifest](https://github.com/openclaw/openclaw/blob/488631c18fae7cc541ba8fc8beff6cbb0438787b/extensions/talk-voice/openclaw.plugin.json) |
| tavily | 2 | unspecified | P8 | [manifest](https://github.com/openclaw/openclaw/blob/488631c18fae7cc541ba8fc8beff6cbb0438787b/extensions/tavily/openclaw.plugin.json) |
| teams-meetings | 1 | true | P11 | [manifest](https://github.com/openclaw/openclaw/blob/488631c18fae7cc541ba8fc8beff6cbb0438787b/extensions/teams-meetings/openclaw.plugin.json) |
| visitor-access | 3 | unspecified | P13 | [manifest](https://github.com/openclaw/openclaw/blob/488631c18fae7cc541ba8fc8beff6cbb0438787b/extensions/visitor-access/openclaw.plugin.json) |
| voice-call | 1 | unspecified | P11 | [manifest](https://github.com/openclaw/openclaw/blob/488631c18fae7cc541ba8fc8beff6cbb0438787b/extensions/voice-call/openclaw.plugin.json) |
| whatsapp | 2 | unspecified | P11 | [manifest](https://github.com/openclaw/openclaw/blob/488631c18fae7cc541ba8fc8beff6cbb0438787b/extensions/whatsapp/openclaw.plugin.json) |
| workboard | 38 | false | P13 | [manifest](https://github.com/openclaw/openclaw/blob/488631c18fae7cc541ba8fc8beff6cbb0438787b/extensions/workboard/openclaw.plugin.json) |
| xai | 2 | true | P10 | [manifest](https://github.com/openclaw/openclaw/blob/488631c18fae7cc541ba8fc8beff6cbb0438787b/extensions/xai/openclaw.plugin.json) |
| zalouser | 1 | unspecified | P11 | [manifest](https://github.com/openclaw/openclaw/blob/488631c18fae7cc541ba8fc8beff6cbb0438787b/extensions/zalouser/openclaw.plugin.json) |
| zoom-meetings | 1 | true | P11 | [manifest](https://github.com/openclaw/openclaw/blob/488631c18fae7cc541ba8fc8beff6cbb0438787b/extensions/zoom-meetings/openclaw.plugin.json) |

## 3. 非普通目录项

| 表面 | 名字 | 计划要求 |
| --- | --- | --- |
| Structured Tool Search | `tool_search/tool_describe/dispatch_action` | P9；映射到原生dynamic/宿主发现能力，同一个已授权catalog；不强制参考名字，搜索不授权 |
| Swarm collector | `structured_output` | P5/P9；参考collector能力，按原生上下文与结果协议映射，不自动新增同名工具 |
| Code Mode | `exec/wait` | P9；优先复用原生CodeMode工具名/等待/恢复协议；不照搬同名外观或装配互斥规则，continuation不重放副作用 |
| runtime事实认可名 | `search/find/grep/glob` | 仅recognition记录；本pin未找到core factory，不算四个默认工具 |
| 别名 | `bash/cron/apply-patch/tool_call` | 上游canonical分别为exec/automations/apply_patch/dispatch_action；仅记录来源，不自动注册本地别名或改写已准入调用 |
| MCP/client | 动态 | P9；以实际source+schema revision追踪，数量开放，不混入170静态计数 |

## 4. 验收记录规则

每项后续维护“参考action → Backplane工具/服务映射 → 处置 → 行为差异 → 验证证据”，上游样本与原生契约样本分开保存。处置使用native-reuse、host-extension、host-adapted或gap；实际目标包含descriptor/profile、权限上限、admitted context、readiness、owner/revision及success/deny/unavailable/cancel/timeout/recovery证据。另维护implemented/local_contract_verified/live_verified/blocked状态；映射完成不等于交付完成，可选能力未覆盖仍是缺口，缺凭据或设备也不代表实现或真实E2E已完成。

P0实际装配发现额外动态注册时追加有来源的差异记录，不修改计数来掩盖缺项。QA能力只在隔离验证构造。宿主映射（例如gateway/openclaw）标host-adapted；尚无等价能力保持gap。验收要求全部参考项得到评估和映射、实际工具通过Backplane原生契约验证，并如实记录未完成能力；不以工具名/schema/数量相同宣称兼容。

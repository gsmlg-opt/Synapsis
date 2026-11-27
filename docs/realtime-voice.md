# 实时语音 Agent

在 **Agents → New Agent** 的 **Agent type** 选择 **Voice Agent**（浏览器音频）或 **Device Voice Agent**（宿主音频），页面会切换到
**Voice setup**。原有 Agent 的默认类型为
**Standard**，现有普通 Provider 和 Responses 配置继续可用。

## 配置与通话

1. 先填写 **Required settings** 中的名称、Backplane 连接和 Realtime 模型。编辑时会校验
   字段格式，错误显示在对应字段下方。选择配置为 Backplane 根地址或根 `/v1` 的
   Provider 连接。语音使用这条连接的服务端
   bearer。从 **Refresh Realtime models** 读取独立目录，选择或输入包含 Provider
   限定名的模型，例如 `openai/gpt-realtime`。直通路由允许手工输入资格模型，实际准入
   由网关决定。命名端点地址和 OAuth 连接会返回配置错误。
2. 在 **Voice setup** 选择声音和 VAD。在 **Audio** 选择该类型使用的麦克风和扬声器，
   并拖动滑块设定各自音量。Host 音量应用到所选宿主设备，最高 150%。Web 音量调节页面内
   增益，最高 200%。选择 **Use default volume** 可恢复端点默认值。**Discover browser devices**
   请求麦克风权限以列出可用设备。浏览器设备 ID 受站点和浏览器权限约束。
   保存前可用 **Test microphone** 查看本机采集峰值，或用 **Test speaker** 播放短提示音。
   测试采用草稿中的设备和音量，在所选端点本地运行。Host 测试结束会恢复设备原音量。
3. 如需委派，在 **Tools & delegation** 启用 `spawn_agent`，指定已保存且启用的普通 Agent
   为默认目标。普通 Agent 使用自己的模型、提示、工作区、工具和技能。其工具权限受
   父级授权上限约束。语音向普通 Agent 委派使用明确的文字任务和
   `fork_turns="none"`。可用 `agent_type` 指定其他已保存的普通 Agent。
4. 普通 Voice Agent 可以创建多个浏览器会话。Device Voice Agent 的 **Open conversation** 始终进入同一个固定会话，
   首次进入时建立，后续打开、挂断再拨和服务重启均沿用同一会话和历史。选择 **Start call** 才开始通话，
   并读取该类型当前保存的设备及音量。Device Voice Agent 启动后持续通话，关闭页面后仍然在线。
   重新打开固定会话可静音、取消静音或挂断；静音仅关闭麦克风输入，仍可听到播报。
   保存和打开会话不会启用采集。Web 音频启动时会请求系统麦克风权限。
   会话聊天区可在通话中发送文字和 PNG、JPEG 或 WebP 图片，
   并显示语音转写与播放状态。**Manual** 模式使用 **Send audio** 提交录音缓冲。
   麦克风按帧实时发送。网关确认一段语音后，聊天立即显示该段，转写到达后原地更新。连续说话时，
   新片段进入同一通话上下文，按当前话语回复；停止说话后不会逐段补答。文字和图片仍可排队。
5. **Stop playback** 停止播报并按设备确认的进度截断。**Cancel task** 对应列表里的确切
   子任务运行。**Hang up** 释放媒体和上游连接。已经独立运行的子任务继续归档，结果在
   下一次有效响应边界由原生协作队列交给该会话。

语音配置使用既有 `agents.toml`。包含 `kind`、`voice_model`、`voice`、
`voice_turn_detection`、由类型确定的通话端点 `audio_mode`、以 `host_audio_` 和 `browser_audio_`
开头的设备和音量字段，以及 `voice_delegate`。原有共用音频字段归入原来 `audio_mode`
对应的设置。缺省 `kind` 的配置以普通 Agent 载入。模型、系统提示和工具以
逻辑会话的运行快照为准。

每套宿主配置最多有一个 `kind = "host_voice"`，停用后仍占用名额。固定会话沿用该 Agent 的 UUID，
不能单独删除或复制。升级后已有 `kind = "voice"` 使用浏览器端点，原宿主设备设置予以保留。
需要继续使用宿主设备时，可将指定的 Voice Agent 原地改为 Device Voice Agent。原有会话历史保留，
宿主通话统一进入该 Agent 的固定会话。

## 端点支持

| 端点 | 环境及依赖 |
| --- | --- |
| Host | Linux，包括 NixOS，使用 Synapsis 进程所在主机的麦克风和扬声器。需要 Python 3、`pactl`、`libpulse-simple.so.0`、用户 PulseAudio 或 PipeWire-Pulse 服务及可加载的 WebRTC `module-echo-cancel`。 |
| Browser | HTTPS 或 localhost，支持 `getUserMedia` 和 AudioWorklet 的浏览器。支持 `AudioContext.setSinkId` 时可选扬声器，其余浏览器使用系统默认输出。 |
| macOS、Windows 宿主 | 本版可使用浏览器端点。Host 后端仅实现 Linux。 |

Devenv 提供宿主 helper 的外部依赖。OTP 发布包包含 `synapsis_agent/priv/voice/pulse_audio.py`，
宿主需提供同样的运行依赖。有条件地用 `SYNAPSIS_PULSE_LIBRARY` 指定库路径。以能访问用户
音频服务的身份运行，设备权限和用户音频服务必须可用。容器、SSH 或系统服务可能没有该会话
的音频权限。配置错误会报告端点不可用。单节点同一时刻只租用
一套宿主采播设备。普通 Voice Agent 的浏览器控制连接消失时会释放其浏览器端点。

可在运行 Synapsis 的 IEx 会话里调用 `Synapsis.VoiceSession.start(session_id, mode: "host")` 启动宿主通话。
服务端持有设备；调用进程退出后仍然在线。用 `Synapsis.VoiceSession.devices(:host)` 枚举设备、`status(session_id)` 读状态、
`mute(session_id, true | false)` 控制麦克风，`stop_playback(session_id)` 停播，`stop(session_id)` 挂断并取消自动重连。

## 运行时边界

Synapsis 服务端持有长期 Realtime WebSocket 和音频控制器。VAD 自动出响应及自动中断关闭。
**Server VAD** 使用 700 毫秒静音判定句尾，避免在句中短暂停顿时提交片段。
检测到开口时，Synapsis 开始准备原生 Conversation 的响应。上一轮完成语音回复后，下一段
可以在网关确认输入时用同一份工具目录立即请求回复。本地运行时随后按输入标识、连接代次、
工具、指令及历史核对并接管同一个响应。工具调用通过核对后才交给 Conversation 执行。Realtime 的函数参数描述省略其接口拒绝的顶层 JSON Schema 组合与约束关键字，
例如 `anyOf`。Realtime 只接收 JSON 函数工具，自定义语法工具（如 `apply_patch`）仅在支持它的协议上提供。
语音提示保留 Agent 指令、身份与记忆；函数说明随工具发送一次。选用技能搜索工具时，
提示按 Backplane 来源列出已分配的可见技能名称，模型按需搜索描述和读取细节。Conversation 执行前仍按工具原始 schema 验证参数。
媒体通道独立传递有界 PCM16、24 kHz、mono 帧，租约、代次、序号用于隔离浏览器
和设备切换。宿主使用 Pulse 播放时钟和回声参考设备，浏览器使用设备输出时间戳。
宿主起播时最多等待 360 毫秒，以吸收 Realtime 音频包的到达抖动；已有足够的 PCM 帧时立即播放。
宿主等待播放的 PCM 上限为 45 秒，用于容纳生成速度快于声卡播放速度的回复。
无法取得可靠进度时，UI 标记进度未知，截断保守使用零，避免把未确认的内容保留为已听。

持久记录包含类型化已提交输入、生成的语音转写、经确认的设备播放进度和任务关联。
每个逻辑会话的 `VoiceSession` 提供聊天快照，包含已准入输入、正在生成的回复、队列和语音事实。
文字输入在 Conversation 准入后进入聊天列表，助手回复从流式显示到归档沿用同一消息 ID。
用户转写晚到时更新原消息。通话面板显示连接、播放与任务控制。刷新页面读取当前会话进程的
快照，进程退出后从 Concord 恢复历史。连接中原生工具输出按原 `call_id` 发送一次。重新开始
会建立新的上游会话并使用带来源的历史转写及已确认播报；旧 PCM、未确认写入和有副作用的
工具结果不会自动重放。媒体连接断开时，当前响应会结束。宿主通话立即尝试重连，连续失败后逐步延长间隔，
最长 10 秒。服务重启也会恢复已启动的宿主通话及其静音设置。用户挂断后，通话保持离线，直到再次选择 **Start call**。
普通浏览器通话可点击同一会话的 **Start call** 重拨。Realtime 停止发送该响应的事件时，语音层先结束该响应并关闭媒体连接。
模型明确报告本次回复失败或未完成时，通话会结束这一轮并继续监听下一次输入。
模型返回无效或重复的工具调用时，当前响应的工具批次被拒绝，已经生成的完整播报保留，通话可继续。
服务重启后，已确认中断且没有待处理工作的语音会话可以原地重拨。如果旧连接在等待模型回答时消失，
运行日志能确认唯一未完成的操作属于该轮麦克风输入，且没有待处理的工具、子任务或队列工作，
则保留原会话和历史，等下一次输入开始新的响应。旧录音不会重新提交。
如果普通 Voice Agent 的旧会话运行记录要求恢复，通话控件会显示 **Copy chat and continue**。新会话保留已保存的
文字、图片、语音转写和播放状态，使用独立的运行记录，并等待用户开始通话和提交新输入。
Device Voice Agent 遇到结果不确定、需要恢复的运行记录时，在原会话提示恢复，不自动重放或复制。

Synapsis 锁定 `backplane_agent_runtime 1.10.98`，使用有限响应的
`:response_interrupted`、`:response_activity` 和独立 total/idle 时限。网关建议使用
Backplane `v1.10.95` 或兼容新版，运行其迁移并给 Realtime 服务配置独立的会话输入和
输出预算。旧路由迁移会保留原有额度。连续 24 kHz 音频需要显式检查额度和时长。
启用 Backplane 的全局客户端鉴权旁路时，网关使用 `v1.10.97` 或更新版本。 [Backplane #185](https://github.com/gsmlg-opt/backplane/issues/185)

## 子任务结果交接

Backplane 1.10.98 在根 Conversation 退役时保留子任务结果与投递回执。Synapsis 的集成测试
验证普通子 Agent 在语音挂断后完成，结果由同一逻辑会话下一次连接的 Realtime 响应取用。
[Backplane #184](https://github.com/gsmlg-opt/backplane/issues/184) · [Backplane v1.10.98](https://github.com/gsmlg-opt/backplane/releases/tag/v1.10.98)

## 验收范围

本地 WebSocket 和 HTTP fixture 可证明 Synapsis 会话、共享运行时和上游协议的接线，
Node/Python 测试覆盖媒体和时钟算法。实机验收仍需在目标部署使用实际 Backplane 路由、
可听的扬声器和麦克风，并在浏览器设备验证权限、播放游标与换端。宿主扬声器的声学回声
抑制效果受设备、房间和回声处理模块影响，需在目标设备实际说话和播音时验收。

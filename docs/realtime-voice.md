# 实时语音 Agent

在 **Agents → Add Agent** 选择 **Realtime voice**。原有 Agent 的默认类型为
**Standard**，现有普通 Provider 和 Responses 配置继续可用。

## 配置与通话

1. 选择配置为 Backplane 根地址或根 `/v1` 的 Provider 连接。语音使用这条连接的服务端
   bearer。从 **Refresh Realtime models** 读取独立目录，选择或输入包含 Provider
   限定名的模型，例如 `openai/gpt-realtime`。直通路由允许手工输入资格模型，实际准入
   由网关决定。命名端点地址和 OAuth 连接会返回配置错误。
2. 选择声音、VAD 和默认音频端点。**Manual** 模式使用 **Send audio** 提交当前录音缓冲。
   可选设备 ID 属于所选端点。浏览器设备 ID 受站点和浏览器权限约束。
3. 如需委派，在语音 Agent 的工具设置启用 `spawn_agent`，指定已保存且启用的普通 Agent
   为默认目标。普通 Agent 使用自己的模型、提示、工作区、工具和技能。其工具权限受
   父级授权上限约束。语音向普通 Agent 委派使用明确的文字任务和
   `fork_turns="none"`。可用 `agent_type` 指定其他已保存的普通 Agent。
4. 保存后打开此 Agent 的 Sessions，创建会话并选择 **Start call**。保存和打开会话
   不会启用采集。浏览器模式会在这一操作后请求系统麦克风权限。切换设备时会停止原端点，
   丢弃尚未提交的输入并继续同一逻辑会话；媒体端点代次随之变更。
5. **Stop playback** 停止播报并按设备确认的进度截断。**Cancel task** 对应列表里的确切
   子任务运行。**Hang up** 释放媒体和上游连接。已经独立运行的子任务继续归档，结果在
   下一次有效响应边界由原生协作队列交给该会话。

语音配置使用既有 `agents.toml`。包含 `kind`、`voice_model`、`voice`、
`voice_turn_detection`、`audio_mode`、`audio_input_device`、`audio_output_device`
和 `voice_delegate`。缺省 `kind` 的配置以普通 Agent 载入。模型、系统提示和工具以
逻辑会话的运行快照为准。编辑后可创建新语音会话使用新设置。

## 端点支持

| 端点 | 环境及依赖 |
| --- | --- |
| Host | Linux，包括 NixOS，使用 Synapsis 进程所在主机的麦克风和扬声器。需要 Python 3、`pactl`、`libpulse-simple.so.0`、用户 PulseAudio 或 PipeWire-Pulse 服务及可加载的 WebRTC `module-echo-cancel`。 |
| Browser | HTTPS 或 localhost，支持 `getUserMedia` 和 AudioWorklet 的浏览器。支持 `AudioContext.setSinkId` 时可选扬声器，其余浏览器使用系统默认输出。 |
| macOS、Windows 宿主 | 本版可使用浏览器端点。Host 后端仅实现 Linux。 |

Devenv 提供宿主 helper 的外部依赖。OTP 发布包包含 `synapsis_agent/priv/voice/pulse_audio.py`，
宿主需提供同样的运行依赖。有条件地用 `SYNAPSIS_PULSE_LIBRARY` 指定库路径。以能访问用户
音频服务的身份运行，设备权限和用户音频服务必须可用。容器、SSH 或系统服务可能没有该会话
的音频权限。配置错误会报告端点不可用，保留手动选择另一端点的能力。单节点同一时刻只租用
一套宿主采播设备。浏览器控制连接消失时会释放其租用的端点。

可在运行 Synapsis 的 IEx 会话或长寿命控制进程里直接控制宿主通话。调用
`Synapsis.VoiceSession.start(session_id, mode: "host")` 的进程持有租约，后续控制用同一个
进程。用 `Synapsis.VoiceSession.devices(:host)` 枚举设备、`status(session_id)` 读状态、
`stop_playback(session_id)` 停播，以及 `stop(session_id)` 挂断。退出控制进程会释放租约。

## 运行时边界

Synapsis 服务端持有长期 Realtime WebSocket 和音频控制器。VAD 自动出响应及自动中断关闭。
每次原生 Conversation provider attempt 请求一个有限 response，沿同一 Conversation 审核和
执行工具。媒体通道独立传递有界 PCM16、24 kHz、mono 帧，租约、代次、序号用于隔离浏览器
和设备切换。宿主使用 Pulse 播放时钟和回声参考设备，浏览器使用设备输出时间戳。
无法取得可靠进度时，UI 标记进度未知，截断保守使用零，避免把未确认的内容保留为已听。

持久记录包含类型化已提交输入、生成的语音转写、经确认的设备播放进度和任务关联。
用户转写晚到时补充界面和归档。连接中原生工具输出按原 `call_id` 发送一次。重新开始
会建立新的上游会话并使用带来源的历史转写及已确认播报；旧 PCM、未确认写入和有副作用的
工具结果不会自动重放。活动响应的断连在无法确认取消时使用原生失败和恢复语义。

Synapsis 锁定 `backplane_agent_runtime 1.10.95`，使用有限响应的
`:response_interrupted`、`:response_activity` 和独立 total/idle 时限。网关建议使用
Backplane `v1.10.95` 或兼容新版，运行其迁移并给 Realtime 服务配置独立的会话输入和
输出预算。旧路由迁移会保留原有额度。连续 24 kHz 音频需要显式检查额度和时长。

## 验收范围

本地 WebSocket 和 HTTP fixture 可证明 Synapsis 会话、共享运行时和上游协议的接线，
Node/Python 测试覆盖媒体和时钟算法。实机验收仍需在目标部署使用实际 Backplane 路由、
可听的扬声器和麦克风，并在浏览器设备验证权限、播放游标与换端。宿主扬声器的声学回声
抑制效果受设备、房间和回声处理模块影响，需在目标设备实际说话和播音时验收。

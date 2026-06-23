import { ScrollBottomHook } from "./scroll-bottom"
import { StreamingTextHook } from "./streaming-text"
import { AgentBackupModelPickerHook, AgentModelPickerHook } from "./agent-model-picker"

export const Hooks = {
  AgentBackupModelPicker: AgentBackupModelPickerHook,
  AgentModelPicker: AgentModelPickerHook,
  ScrollBottom: ScrollBottomHook,
  StreamingText: StreamingTextHook,
}

export { ScrollBottomHook } from "./scroll-bottom"
export { StreamingTextHook } from "./streaming-text"
export { AgentBackupModelPickerHook, AgentModelPickerHook } from "./agent-model-picker"

import { ScrollBottomHook } from "./scroll-bottom"
import { StreamingTextHook } from "./streaming-text"
import { AgentBackupModelPickerHook, AgentModelPickerHook } from "./agent-model-picker"
import { ChatImageInputHook } from "./chat-image-input"
import { MCPFormModalHook } from "./mcp-form-modal"

export {
  observeChatInputFieldSemantics,
  syncChatInputFieldSemantics,
} from "./chat-input-field-semantics"

export const Hooks = {
  MCPFormModal: MCPFormModalHook,
  AgentBackupModelPicker: AgentBackupModelPickerHook,
  AgentModelPicker: AgentModelPickerHook,
  ChatImageInput: ChatImageInputHook,
  ScrollBottom: ScrollBottomHook,
  StreamingText: StreamingTextHook,
}

export { ScrollBottomHook } from "./scroll-bottom"
export { StreamingTextHook } from "./streaming-text"
export { AgentBackupModelPickerHook, AgentModelPickerHook } from "./agent-model-picker"
export { ChatImageInputHook, encodeChatImages } from "./chat-image-input"

export { createSynapsisReactFormHook } from "./react-form"
export { createSynapsisReactChat } from "./react-chat"

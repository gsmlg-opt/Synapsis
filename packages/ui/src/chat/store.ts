import { configureStore, createSlice, type PayloadAction, type Middleware } from "@reduxjs/toolkit"

export interface Message {
  id: string
  role: "user" | "assistant" | "system"
  parts: MessagePart[]
  timestamp?: string
}

export interface MessagePart {
  type: "text" | "tool_use" | "tool_result" | "reasoning" | "file" | "agent"
  content?: string
  tool?: string
  tool_use_id?: string
  input?: Record<string, any>
  is_error?: boolean
  status?: string
}

export interface ToolCall {
  id: string
  tool: string
  tool_use_id: string
  input: Record<string, any>
  status: "pending" | "approved" | "denied" | "completed" | "error"
  result?: string
}

export interface PermissionRequest {
  tool: string
  tool_use_id: string
  input: Record<string, any>
}

interface ChatState {
  messages: Message[]
  streamingText: string
  streamingType: "text" | "thinking" | null
  pendingToolCalls: ToolCall[]
  permissionRequests: PermissionRequest[]
  status: "idle" | "streaming" | "tool_wait"
  error: string | null
}

const initialChatState: ChatState = {
  messages: [],
  streamingText: "",
  streamingType: null,
  pendingToolCalls: [],
  permissionRequests: [],
  status: "idle",
  error: null,
}

const chatSlice = createSlice({
  name: "chat",
  initialState: initialChatState,
  reducers: {
    hydrate(state, action: PayloadAction<{ messages: Message[] }>) {
      state.messages = action.payload.messages || []
      state.streamingText = ""
      state.streamingType = null
      state.pendingToolCalls = []
      state.permissionRequests = []
      state.status = "idle"
      state.error = null
    },
    sendMessage(state, action: PayloadAction<string>) {
      state.messages.push({
        id: crypto.randomUUID(),
        role: "user",
        parts: [{ type: "text", content: action.payload }],
        timestamp: new Date().toISOString(),
      })
      state.status = "streaming"
      state.streamingText = ""
      state.streamingType = null
      state.error = null
    },
    appendChunk(state, action: PayloadAction<{ type: "text" | "thinking"; text?: string; content?: string }>) {
      const text = action.payload.text || action.payload.content || ""
      state.streamingText += text
      state.streamingType = action.payload.type
      state.status = "streaming"
    },
    addToolCall(state, action: PayloadAction<ToolCall>) {
      state.pendingToolCalls.push({
        ...action.payload,
        status: "pending",
      })
      // Flush streaming text as a message part if there is any
      if (state.streamingText) {
        const lastMsg = state.messages[state.messages.length - 1]
        if (lastMsg && lastMsg.role === "assistant") {
          lastMsg.parts.push({
            type: state.streamingType === "thinking" ? "reasoning" : "text",
            content: state.streamingText,
          })
        }
        state.streamingText = ""
        state.streamingType = null
      }
      state.status = "tool_wait"
    },
    resolveToolCall(state, action: PayloadAction<{ tool_use_id: string; content: string; is_error: boolean }>) {
      const tc = state.pendingToolCalls.find((t) => t.tool_use_id === action.payload.tool_use_id)
      if (tc) {
        tc.status = action.payload.is_error ? "error" : "completed"
        tc.result = action.payload.content
      }
    },
    addPermissionRequest(state, action: PayloadAction<PermissionRequest>) {
      state.permissionRequests.push(action.payload)
      state.status = "tool_wait"
    },
    approveToolCall(_state, _action: PayloadAction<string>) {
      // Handled by middleware — pushes to channel
    },
    denyToolCall(_state, _action: PayloadAction<string>) {
      // Handled by middleware — pushes to channel
    },
    cancel(_state) {
      // Handled by middleware — pushes to channel
    },
    setStatus(state, action: PayloadAction<"idle" | "streaming" | "tool_wait">) {
      state.status = action.payload
    },
    setError(state, action: PayloadAction<string>) {
      state.error = action.payload
      state.status = "idle"
    },
    completeTurn(state) {
      // Flush remaining streaming text into the assistant message
      if (state.streamingText) {
        let assistantMsg = state.messages[state.messages.length - 1]
        if (!assistantMsg || assistantMsg.role !== "assistant") {
          assistantMsg = {
            id: crypto.randomUUID(),
            role: "assistant",
            parts: [],
            timestamp: new Date().toISOString(),
          }
          state.messages.push(assistantMsg)
        }
        assistantMsg.parts.push({
          type: state.streamingType === "thinking" ? "reasoning" : "text",
          content: state.streamingText,
        })
      }

      // Flush tool calls into assistant message parts
      for (const tc of state.pendingToolCalls) {
        let assistantMsg = state.messages[state.messages.length - 1]
        if (!assistantMsg || assistantMsg.role !== "assistant") {
          assistantMsg = {
            id: crypto.randomUUID(),
            role: "assistant",
            parts: [],
            timestamp: new Date().toISOString(),
          }
          state.messages.push(assistantMsg)
        }
        assistantMsg.parts.push({
          type: "tool_use",
          tool: tc.tool,
          tool_use_id: tc.tool_use_id,
          input: tc.input,
          status: tc.status,
        })
        if (tc.result !== undefined) {
          assistantMsg.parts.push({
            type: "tool_result",
            tool_use_id: tc.tool_use_id,
            content: tc.result,
            is_error: tc.status === "error",
          })
        }
      }

      state.streamingText = ""
      state.streamingType = null
      state.pendingToolCalls = []
      state.permissionRequests = []
      state.status = "idle"
    },
    completeMessage(state, action: PayloadAction<Message>) {
      // Replace or append the completed message
      const idx = state.messages.findIndex((m) => m.id === action.payload.id)
      if (idx >= 0) {
        state.messages[idx] = action.payload
      } else {
        state.messages.push(action.payload)
      }
      state.streamingText = ""
      state.streamingType = null
      state.status = "idle"
    },
  },
})

interface UIState {
  theme: "dark" | "light"
  sidebarCollapsed: boolean
  activePanel: "sessions" | "files"
}

const uiSlice = createSlice({
  name: "ui",
  initialState: {
    theme: "dark" as const,
    sidebarCollapsed: false,
    activePanel: "sessions" as const,
  } as UIState,
  reducers: {
    update(state, action: PayloadAction<Partial<UIState>>) {
      Object.assign(state, action.payload)
    },
    toggleSidebar(state) {
      state.sidebarCollapsed = !state.sidebarCollapsed
    },
    setTheme(state, action: PayloadAction<"dark" | "light">) {
      state.theme = action.payload
    },
  },
})

interface SessionState {
  id: string
  agentMode: "build" | "plan"
  provider: string
  model: string
}

const sessionSlice = createSlice({
  name: "session",
  initialState: {
    id: "",
    agentMode: "build" as const,
    provider: "",
    model: "",
  } as SessionState,
  reducers: {
    setSession(state, action: PayloadAction<Partial<SessionState>>) {
      Object.assign(state, action.payload)
    },
    setAgentMode(state, action: PayloadAction<"build" | "plan">) {
      state.agentMode = action.payload
    },
  },
})

export type RootState = {
  chat: ChatState
  ui: UIState
  session: SessionState
}

export const chatActions = chatSlice.actions
export const uiActions = uiSlice.actions
export const sessionActions = sessionSlice.actions

interface StoreOptions {
  preloadedState?: Partial<RootState>
  middleware?: Middleware[]
}

export function createChatStore(options: StoreOptions = {}) {
  return configureStore({
    reducer: {
      chat: chatSlice.reducer,
      ui: uiSlice.reducer,
      session: sessionSlice.reducer,
    },
    preloadedState: options.preloadedState as any,
    middleware: (getDefaultMiddleware) => {
      const mw = getDefaultMiddleware({ serializableCheck: false })
      if (options.middleware) {
        return mw.concat(options.middleware)
      }
      return mw
    },
  })
}

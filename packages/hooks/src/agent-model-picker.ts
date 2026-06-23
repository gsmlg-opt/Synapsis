import { h, render } from "preact"
import { useMemo, useState } from "preact/hooks"

type ModelOption = {
  value: string
  label: string
}

type ProviderOption = ModelOption & {
  children: ModelOption[]
}

type AgentModelPickerProps = {
  id: string
  options: ProviderOption[]
  initialProvider: string
  initialModel: string
  providerInputId: string
  modelInputId: string
  stateInputId: string
}

type AgentBackupModelPickerProps = {
  id: string
  options: ProviderOption[]
  initialValue: string
  valueInputId: string
  stateInputId: string
}

function parseOptions(raw: string | undefined): ProviderOption[] {
  if (!raw) return []

  try {
    const parsed = JSON.parse(raw)
    return Array.isArray(parsed)
      ? parsed.map(normalizeProviderOption).filter(isProviderOption)
      : []
  } catch {
    return []
  }
}

function normalizeProviderOption(option: unknown): ProviderOption | null {
  if (!option || typeof option !== "object") return null

  const record = option as Record<string, unknown>
  const value = normalizeText(record.value)
  if (!value) return null

  const children = Array.isArray(record.children)
    ? record.children.map(normalizeModelOption).filter(isModelOption)
    : []

  return {
    value,
    label: normalizeText(record.label) || value,
    children,
  }
}

function normalizeModelOption(option: unknown): ModelOption | null {
  if (!option || typeof option !== "object") return null

  const record = option as Record<string, unknown>
  const value = normalizeText(record.value)
  if (!value) return null

  return {
    value,
    label: normalizeText(record.label) || value,
  }
}

function isProviderOption(option: ProviderOption | null): option is ProviderOption {
  return option !== null
}

function isModelOption(option: ModelOption | null): option is ModelOption {
  return option !== null
}

function normalizeText(value: unknown): string {
  return typeof value === "string" ? value.trim() : ""
}

function parseModelList(raw: string | undefined): string[] {
  return (raw || "")
    .split(",")
    .map((value) => value.trim())
    .filter((value) => value.length > 0)
}

function initialSelection(options: ProviderOption[], provider: string, model: string) {
  const selectedProvider = options.find((option) => option.value === provider)
  if (!selectedProvider) return { provider: "", model: "" }

  const selectedModel = selectedProvider.children.find((option) => option.value === model)
  return {
    provider: selectedProvider.value,
    model: selectedModel ? selectedModel.value : "",
  }
}

function initialBackupSelection(options: ProviderOption[], raw: string) {
  const value = parseModelList(raw)[0] || ""
  if (!value) return { provider: "", model: "" }

  for (const option of options) {
    const prefix = `${option.value}/`

    if (value.startsWith(prefix)) {
      return { provider: option.value, model: value.slice(prefix.length) }
    }
  }

  const selectedProvider = options.find((option) =>
    option.children.some((child) => child.value === value)
  )

  return selectedProvider ? { provider: selectedProvider.value, model: value } : { provider: "", model: "" }
}

function modelOptions(options: ProviderOption[], provider: string): ModelOption[] {
  return options.find((option) => option.value === provider)?.children || []
}

function providerModelValue(provider: string, model: string): string {
  return provider && model ? `${provider}/${model}` : ""
}

function AgentModelPicker({
  id,
  options,
  initialProvider,
  initialModel,
  providerInputId,
  modelInputId,
  stateInputId,
}: AgentModelPickerProps) {
  const initial = useMemo(
    () => initialSelection(options, initialProvider, initialModel),
    [initialModel, initialProvider, options]
  )
  const [provider, setProvider] = useState(initial.provider)
  const [model, setModel] = useState(initial.model)
  const models = modelOptions(options, provider)
  const stateValue = JSON.stringify({ provider, model })

  const selectClass =
    "w-full rounded-md border border-outline-variant bg-surface-container-low px-3 py-2 text-sm text-on-surface outline-none transition-colors focus:border-primary focus:ring-2 focus:ring-primary/20 disabled:cursor-not-allowed disabled:opacity-60"

  function changeProvider(nextProvider: string) {
    const nextModels = modelOptions(options, nextProvider)
    const nextModel = nextModels.some((option) => option.value === model)
      ? model
      : nextModels[0]?.value || ""

    setProvider(nextProvider)
    setModel(nextProvider ? nextModel : "")
  }

  return h("div", { class: "grid grid-cols-1 gap-3 sm:grid-cols-2" }, [
    h("input", {
      id: providerInputId,
      key: "provider-hidden",
      type: "hidden",
      name: "agent[provider]",
      value: provider,
    }),
    h("input", {
      id: modelInputId,
      key: "model-hidden",
      type: "hidden",
      name: "agent[model]",
      value: model,
    }),
    h("input", {
      id: stateInputId,
      key: "state-hidden",
      type: "hidden",
      name: "agent[provider_model_state]",
      value: stateValue,
    }),
    h("label", { key: "provider", class: "block" }, [
      h("span", { class: "sr-only" }, "Provider"),
      h(
        "select",
        {
          id: `${id}-provider`,
          class: selectClass,
          value: provider,
          onChange: (event: Event) =>
            changeProvider((event.currentTarget as HTMLSelectElement).value),
        },
        [
          h("option", { value: "" }, "Provider"),
          ...options.map((option) =>
            h("option", { key: option.value, value: option.value }, option.label)
          ),
        ]
      ),
    ]),
    h("label", { key: "model", class: "block" }, [
      h("span", { class: "sr-only" }, "Model"),
      h(
        "select",
        {
          id: `${id}-model`,
          class: selectClass,
          value: model,
          disabled: !provider || models.length === 0,
          onChange: (event: Event) => setModel((event.currentTarget as HTMLSelectElement).value),
        },
        [
          h("option", { value: "" }, "Model"),
          ...models.map((option) =>
            h("option", { key: option.value, value: option.value }, option.label)
          ),
        ]
      ),
    ]),
  ])
}

function AgentBackupModelPicker({
  id,
  options,
  initialValue,
  valueInputId,
  stateInputId,
}: AgentBackupModelPickerProps) {
  const initial = useMemo(
    () => initialBackupSelection(options, initialValue),
    [initialValue, options]
  )
  const [provider, setProvider] = useState(initial.provider)
  const [model, setModel] = useState(initial.model)
  const models = modelOptions(options, provider)
  const stateValue = JSON.stringify({ provider, model })
  const backupValue = providerModelValue(provider, model)

  const selectClass =
    "w-full rounded-md border border-outline-variant bg-surface-container-low px-3 py-2 text-sm text-on-surface outline-none transition-colors focus:border-primary focus:ring-2 focus:ring-primary/20 disabled:cursor-not-allowed disabled:opacity-60"

  function changeProvider(nextProvider: string) {
    const nextModels = modelOptions(options, nextProvider)
    const nextModel = nextModels.some((option) => option.value === model)
      ? model
      : nextModels[0]?.value || ""

    setProvider(nextProvider)
    setModel(nextProvider ? nextModel : "")
  }

  return h("div", { class: "grid grid-cols-1 gap-3 sm:grid-cols-2" }, [
    h("input", {
      id: valueInputId,
      key: "backup-model-hidden",
      type: "hidden",
      name: "agent[fallback_models]",
      value: backupValue,
    }),
    h("input", {
      id: stateInputId,
      key: "backup-state-hidden",
      type: "hidden",
      name: "agent[fallback_model_state]",
      value: stateValue,
    }),
    h("label", { key: "provider", class: "block" }, [
      h("span", { class: "sr-only" }, "Backup provider"),
      h(
        "select",
        {
          id: `${id}-provider`,
          class: selectClass,
          value: provider,
          onChange: (event: Event) =>
            changeProvider((event.currentTarget as HTMLSelectElement).value),
        },
        [
          h("option", { value: "" }, "Provider"),
          ...options.map((option) =>
            h("option", { key: option.value, value: option.value }, option.label)
          ),
        ]
      ),
    ]),
    h("label", { key: "model", class: "block" }, [
      h("span", { class: "sr-only" }, "Backup model"),
      h(
        "select",
        {
          id: `${id}-model`,
          class: selectClass,
          value: model,
          disabled: !provider || models.length === 0,
          onChange: (event: Event) => setModel((event.currentTarget as HTMLSelectElement).value),
        },
        [
          h("option", { value: "" }, "Model"),
          ...models.map((option) =>
            h("option", { key: option.value, value: option.value }, option.label)
          ),
        ]
      ),
    ]),
  ])
}

export const AgentModelPickerHook = {
  mounted(this: any) {
    this.agentModelPickerAgentId = this.el.dataset.agentId || ""
    this.renderPicker()
  },

  updated(this: any) {
    const agentId = this.el.dataset.agentId || ""

    if (agentId !== this.agentModelPickerAgentId) {
      this.agentModelPickerAgentId = agentId
      this.renderPicker()
    }
  },

  destroyed(this: any) {
    render(null, this.el)
  },

  renderPicker(this: any) {
    if (!this.agentModelPickerRendered) {
      this.el.replaceChildren()
      this.agentModelPickerRendered = true
    }

    render(
      h(AgentModelPicker, {
        key: this.agentModelPickerAgentId,
        id: this.el.id,
        options: parseOptions(this.el.dataset.options),
        initialProvider: normalizeText(this.el.dataset.provider),
        initialModel: normalizeText(this.el.dataset.model),
        providerInputId: this.el.dataset.providerInput || "agent-provider-hidden",
        modelInputId: this.el.dataset.modelInput || "agent-model-hidden",
        stateInputId: this.el.dataset.stateInput || "agent-provider-model-state",
      }),
      this.el
    )
  },
} as any

export const AgentBackupModelPickerHook = {
  mounted(this: any) {
    this.agentBackupModelPickerAgentId = this.el.dataset.agentId || ""
    this.renderPicker()
  },

  updated(this: any) {
    const agentId = this.el.dataset.agentId || ""

    if (agentId !== this.agentBackupModelPickerAgentId) {
      this.agentBackupModelPickerAgentId = agentId
      this.renderPicker()
    }
  },

  destroyed(this: any) {
    render(null, this.el)
  },

  renderPicker(this: any) {
    if (!this.agentBackupModelPickerRendered) {
      this.el.replaceChildren()
      this.agentBackupModelPickerRendered = true
    }

    render(
      h(AgentBackupModelPicker, {
        key: this.agentBackupModelPickerAgentId,
        id: this.el.id,
        options: parseOptions(this.el.dataset.options),
        initialValue: normalizeText(this.el.dataset.backupModel),
        valueInputId: this.el.dataset.valueInput || "agent-fallback-models-hidden",
        stateInputId: this.el.dataset.stateInput || "agent-fallback-model-state",
      }),
      this.el
    )
  },
} as any

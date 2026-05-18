type CascaderChangeDetail = {
  value?: unknown
  path?: unknown
}

function pathFromValue(value: unknown): string[] {
  if (Array.isArray(value)) {
    return value.map(String)
  }

  if (typeof value !== "string" || value.trim() === "") {
    return []
  }

  try {
    const parsed = JSON.parse(value)
    return Array.isArray(parsed) ? parsed.map(String) : []
  } catch {
    return []
  }
}

function cascaderValue(element: HTMLElement & { value?: unknown }): unknown {
  return element.value ?? element.getAttribute("value")
}

export const AgentModelCascaderHook = {
  mounted(this: any) {
    this.handleChange = (event: CustomEvent<CascaderChangeDetail>) => {
      const path = pathFromValue(event.detail?.path)
      this.syncInputs(path.length > 0 ? path : pathFromValue(event.detail?.value), true)
    }

    this.syncInputs(pathFromValue(cascaderValue(this.el)), false)
    this.el.addEventListener("dm-change", this.handleChange)
  },

  updated(this: any) {
    this.syncInputs(pathFromValue(cascaderValue(this.el)), false)
  },

  destroyed(this: any) {
    this.el.removeEventListener("dm-change", this.handleChange)
  },

  syncInputs(this: any, path: string[], notify: boolean) {
    const providerInput = document.getElementById(
      this.el.dataset.providerInput || ""
    ) as HTMLInputElement | null
    const modelInput = document.getElementById(
      this.el.dataset.modelInput || ""
    ) as HTMLInputElement | null

    if (!providerInput || !modelInput) {
      return
    }

    providerInput.value = path[0] || ""
    modelInput.value = path[1] || ""

    if (notify) {
      providerInput.dispatchEvent(new Event("change", { bubbles: true }))
    }
  },
} as any

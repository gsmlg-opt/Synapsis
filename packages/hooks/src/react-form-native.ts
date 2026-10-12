// WORKAROUND(upstream): duskmoon-dev/phoenix-duskmoon-ui#192
// Keep native grouped selections in the published mixed React Form API.
export type NativeField = {
  name: string
  type?: string
  value: string
  checked?: boolean
  disabled?: boolean
  multiple?: boolean
  selectedOptions?: ArrayLike<{ value: string }>
  options?: ArrayLike<{ value: string; selected: boolean }>
}

type Values = Record<string, any>

function pathOf(name: string): string[] {
  return name.replace(/\]/g, '').split(/[.[\]]/).filter(Boolean)
}

function getAt(values: Values, path: string[]): any {
  return path.reduce((value, key) => value?.[key], values as any)
}

function setAt(values: Values, path: string[], value: any) {
  if (!path.length || path.some(key => ['__proto__', 'constructor', 'prototype'].includes(key))) return
  let target = values
  for (const key of path.slice(0, -1)) target = target[key] ??= {}
  target[path[path.length - 1]] = value
}

export function snapshotNativeFields(fields: Iterable<NativeField>, base: Values = {}): Values {
  const values = structuredClone(base)
  const groups = new Map<string, string[]>()
  for (const field of fields) {
    if (!field.name || field.disabled || ['submit', 'button', 'reset', 'file'].includes(field.type || '')) continue
    const path = pathOf(field.name)
    if (field.name.endsWith('[]')) {
      const key = JSON.stringify(path)
      if (!groups.has(key)) groups.set(key, [])
      const group = groups.get(key)!
      if ((field.type !== 'checkbox' || field.checked) && field.value && !group.includes(field.value)) group.push(field.value)
      setAt(values, path, group)
    } else if (field.type === 'radio') {
      if (field.checked) setAt(values, path, field.value)
    } else {
      const value = field.type === 'checkbox' ? Boolean(field.checked)
        : field.type === 'number' ? (field.value === '' ? null : Number(field.value))
          : field.multiple ? Array.from(field.selectedOptions || [], option => option.value)
            : field.value
      setAt(values, path, value)
    }
  }
  return values
}

export function restoreNativeFields(fields: Iterable<NativeField>, values: Values): void {
  for (const field of fields) {
    const value = getAt(values, pathOf(field.name))
    if (field.type === 'checkbox') {
      field.checked = field.name.endsWith('[]') ? Array.isArray(value) && value.includes(field.value)
        : value === true || value === 'true' || value === 'on'
    } else if (field.type === 'radio') {
      field.checked = value === field.value
    } else if (field.multiple) {
      Array.from(field.options || []).forEach(option => { option.selected = Array.isArray(value) && value.includes(option.value) })
    } else if (!field.name.endsWith('[]')) {
      field.value = value == null ? '' : String(value)
    }
  }
}

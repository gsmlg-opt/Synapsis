import { restoreNativeFields, snapshotNativeFields, type NativeField } from './react-form-native'

function nativeFields(form: HTMLFormElement): NativeField[] {
  return Array.from(form.querySelectorAll<HTMLInputElement | HTMLSelectElement | HTMLTextAreaElement>('[name]'))
    .filter(field => !field.closest('[data-dm-react-field]'))
}

// The outer LiveView mount can patch validation while the native form retains focus and draft values.
function renderNativeErrors(element: HTMLElement): void {
  const raw = element.dataset.nativeFieldErrors
  if (raw === undefined) return
  const errors: Record<string, string> = JSON.parse(raw)
  for (const message of element.querySelectorAll<HTMLElement>('[data-native-field-error]')) {
    const id = message.dataset.nativeFieldError!
    const error = errors[id]
    message.textContent = error || ''
    message.hidden = !error
    const control = element.querySelector<HTMLElement>(`#${CSS.escape(id)}`)
    if (error) {
      control?.setAttribute('aria-invalid', 'true')
      control?.setAttribute('aria-errormessage', message.id)
    } else {
      control?.removeAttribute('aria-invalid')
      control?.removeAttribute('aria-errormessage')
    }
  }
}

// WORKAROUND(upstream): duskmoon-dev/phoenix-duskmoon-ui#193
// Keep the public upstream hook and only reconcile application native controls.
export function createSynapsisReactFormHook(upstream: any) {
  return {
    ...upstream,
    mounted(this: any) {
      upstream.mounted.call(this)
      this.values = { ...snapshotNativeFields(nativeFields(this.form), this.values), ...JSON.parse(this.el.dataset.initialValues || '{}') }
      restoreNativeFields(nativeFields(this.form), this.values)
      this.initialValues = structuredClone(this.values)
      this.renderAll()
      renderNativeErrors(this.el)
      this.handleEvent('dm:form:reset', (payload: any) => {
        if (payload.form_id === this.el.dataset.formId && payload.id !== this.el.id) {
          this.resetForm(payload.values ?? this.initialValues)
        }
      })
    },
    updated(this: any) {
      upstream.updated.call(this)
      renderNativeErrors(this.el)
    },
    bindNative(this: any) {
      // Delegation also observes controls mounted later by the model-picker hook.
      this.native = []
      this.nativeGeneration = 0
      this.nativeHandler = (event: Event) => {
        const target = event.target as HTMLElement
        if (target.closest('[data-dm-react-field]')) return
        const generation = this.nativeGeneration
        queueMicrotask(() => {
          if (this.destroyedState || generation !== this.nativeGeneration) return
          this.values = snapshotNativeFields(nativeFields(this.form), this.values)
          this.scheduleChange((target as HTMLInputElement).name || [])
        })
      }
      this.form.addEventListener('input', this.nativeHandler)
      this.form.addEventListener('change', this.nativeHandler)
    },
    submit(this: any, submitter?: HTMLElement) {
      this.nativeGeneration++
      this.values = snapshotNativeFields(nativeFields(this.form), this.values)
      upstream.submit.call(this, submitter)
    },
    resetForm(this: any, values = this.initialValues) {
      this.nativeGeneration++
      upstream.resetForm.call(this, values)
      restoreNativeFields(nativeFields(this.form), this.values)
    },
    destroyed(this: any) {
      this.form?.removeEventListener('input', this.nativeHandler)
      this.form?.removeEventListener('change', this.nativeHandler)
      upstream.destroyed.call(this)
    },
  }
}

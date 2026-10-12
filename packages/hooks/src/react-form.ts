import { restoreNativeFields, snapshotNativeFields, type NativeField } from './react-form-native'

function nativeFields(form: HTMLFormElement): NativeField[] {
  return Array.from(form.querySelectorAll<HTMLInputElement | HTMLSelectElement | HTMLTextAreaElement>('[name]'))
    .filter(field => !field.closest('[data-dm-react-field]'))
}

// WORKAROUND(upstream): duskmoon-dev/phoenix-duskmoon-ui#193
// Keep the public upstream hook and only reconcile application native controls.
export function createSynapsisReactFormHook(upstream: any) {
  return {
    ...upstream,
    mounted(this: any) {
      upstream.mounted.call(this)
      this.form.id = `${this.el.id}-native`
      // WORKAROUND(upstream): duskmoon-dev/phoenix-duskmoon-ui#195
      // Layout belongs on the native form, which participates in the parent layout.
      this.form.className = this.el.className
      this.form.classList.remove('synapsis-react-form')
      this.values = { ...snapshotNativeFields(nativeFields(this.form), this.values), ...JSON.parse(this.el.dataset.initialValues || '{}') }
      restoreNativeFields(nativeFields(this.form), this.values)
      this.initialValues = structuredClone(this.values)
      this.renderAll()
      this.handleEvent('dm:form:reset', (payload: any) => {
        if (payload.form_id === this.el.dataset.formId && payload.id !== this.el.id) {
          this.resetForm(payload.values ?? this.initialValues)
        }
      })
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
    submit(this: any) {
      // WORKAROUND(upstream): duskmoon-dev/phoenix-duskmoon-ui#194
      if (!this.form.reportValidity()) return
      this.nativeGeneration++
      this.values = snapshotNativeFields(nativeFields(this.form), this.values)
      upstream.submit.call(this)
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

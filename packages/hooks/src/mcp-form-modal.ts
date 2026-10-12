export const MCPFormModalHook = {
  mounted(this: any) {
    const dialog = this.el as HTMLDialogElement
    let closing = false
    this.closeModal = () => {
      if (closing) return
      closing = true
      dialog.close()
      this.pushEvent(dialog.dataset.closeEvent, {})
    }
    this.cancelModal = (event: Event) => {
      event.preventDefault()
      this.closeModal()
    }
    this.clickModal = (event: MouseEvent) => {
      if (event.target !== dialog) return
      const box = dialog.querySelector('.dialog-box')!.getBoundingClientRect()
      if (event.clientX < box.left || event.clientX > box.right ||
          event.clientY < box.top || event.clientY > box.bottom) this.closeModal()
    }
    dialog.addEventListener('cancel', this.cancelModal)
    dialog.addEventListener('close', this.closeModal)
    dialog.addEventListener('click', this.clickModal)
    dialog.showModal()
  },
  destroyed(this: any) {
    this.el.removeEventListener('cancel', this.cancelModal)
    this.el.removeEventListener('close', this.closeModal)
    this.el.removeEventListener('click', this.clickModal)
  },
}

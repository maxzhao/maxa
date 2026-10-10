export class JsonlProtocol {
  constructor({ stdout = process.stdout, stderr = process.stderr } = {}) {
    this.stdout = stdout
    this.stderr = stderr
    this.ready = false
    this.terminal = false
  }

  emit(event) {
    if (event.event === 'ready') {
      if (this.ready || this.terminal) throw new Error('Invalid duplicate or late ready event')
      this.ready = true
    } else if (['submitted', 'cancelled', 'error'].includes(event.event)) {
      if (this.terminal) throw new Error('Invalid duplicate terminal event')
      this.terminal = true
    }
    this.stdout.write(`${JSON.stringify(event)}\n`)
  }

  log(message) {
    this.stderr.write(`${message}\n`)
  }
}

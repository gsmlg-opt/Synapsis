/** Stateful box-filter resampling to PCM16, 24 kHz, mono. */
export class PCM24Encoder {
  declare private remaining: number
  declare private sum: number
  declare private weight: number
  declare private inputRate: number

  constructor(inputRate: number) {
    this.inputRate = inputRate
    this.sum = 0
    this.weight = 0
    if (!Number.isFinite(inputRate) || inputRate < 24000) throw new Error('unsupported_sample_rate')
    this.remaining = inputRate / 24000
  }

  encode(input: Float32Array): Int16Array {
    const output: number[] = []
    const ratio = this.inputRate / 24000
    for (const value of input) {
      let available = 1
      while (available > 0.000001) {
        const take = Math.min(available, this.remaining)
        this.sum += value * take
        this.weight += take
        this.remaining -= take
        available -= take
        if (this.remaining < 0.000001) {
          const sample = Math.max(-1, Math.min(1, this.sum / this.weight))
          output.push(Math.round(sample * (sample < 0 ? 32768 : 32767)))
          this.sum = 0
          this.weight = 0
          this.remaining = ratio
        }
      }
    }
    return Int16Array.from(output)
  }
}

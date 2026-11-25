type SinkAudioContext = AudioContext & {
  setSinkId?: (id: string) => Promise<void>
}

/** Bounded local device preview. Microphone samples stay in the browser audio graph. */
export async function testBrowserAudio(
  kind: 'microphone' | 'speaker',
  deviceId: string | null,
  volume: number | null,
  signal?: AbortSignal
): Promise<{ peak?: number }> {
  if (kind !== 'microphone' && kind !== 'speaker') throw new Error('invalid_audio_test_kind')
  if (!window.isSecureContext) throw new Error('microphone_requires_https_or_localhost')
  if (typeof AudioContext === 'undefined') throw new Error('browser_audio_unavailable')
  if (volume !== null && (!Number.isFinite(volume) || volume < 0 || volume > 200)) {
    throw new Error('invalid_audio_volume')
  }
  if (signal?.aborted) throw new DOMException('Audio test cancelled', 'AbortError')

  let context: SinkAudioContext | null = null
  let stream: MediaStream | null = null
  let source: MediaStreamAudioSourceNode | null = null
  let gain: GainNode | null = null
  let analyser: AnalyserNode | null = null
  let oscillator: OscillatorNode | null = null
  let oscillatorStarted = false
  let released = false
  let close: Promise<void> = Promise.resolve()
  let duration: ReturnType<typeof setTimeout> | undefined
  let samples: ReturnType<typeof setInterval> | undefined
  let rejectCancellation: (reason: Error) => void = () => {}
  const cancelled = new Promise<never>((_, reject) => {
    rejectCancellation = reject
  })
  const abort = () => cancel(new DOMException('Audio test cancelled', 'AbortError'))
  const deviceEnded = () => cancel(new Error('input_device_disconnected'))
  const setupTimeout = setTimeout(() => cancel(new Error('audio_test_timeout')), 10_000)
  signal?.addEventListener('abort', abort, { once: true })

  function release(): Promise<void> {
    if (released) return close
    released = true
    clearTimeout(setupTimeout)
    clearTimeout(duration)
    clearInterval(samples)
    signal?.removeEventListener('abort', abort)
    stream?.getTracks().forEach((track) => {
      track.removeEventListener('ended', deviceEnded)
      track.stop()
    })
    source?.disconnect()
    gain?.disconnect()
    analyser?.disconnect()
    if (oscillator) {
      if (oscillatorStarted) oscillator.stop()
      oscillator.disconnect()
    }
    if (context && context.state !== 'closed') close = context.close()
    return close
  }

  function cancel(error: Error): void {
    if (released) return
    rejectCancellation(error)
    void release()
  }

  try {
    context = new AudioContext({ latencyHint: 'interactive' }) as SinkAudioContext
    await Promise.race([context.resume(), cancelled])
    const multiplier = (volume ?? 100) / 100

    if (kind === 'microphone') {
      if (!navigator.mediaDevices?.getUserMedia) throw new Error('browser_audio_unavailable')
      const permission = navigator.mediaDevices
        .getUserMedia({
          audio: {
            deviceId: deviceId ? { exact: deviceId } : undefined,
            channelCount: { ideal: 1 },
            echoCancellation: true,
            noiseSuppression: true,
            autoGainControl: false
          }
        })
        .then((opened) => {
          if (released) opened.getTracks().forEach((track) => track.stop())
          else {
            stream = opened
            opened.getAudioTracks().forEach((track) => track.addEventListener('ended', deviceEnded))
          }
          return opened
        })
      const opened = await Promise.race([permission, cancelled])
      source = context.createMediaStreamSource(opened)
      gain = context.createGain()
      gain.gain.value = multiplier
      analyser = context.createAnalyser()
      analyser.fftSize = 2048
      source.connect(gain).connect(analyser)
      // AnalyserNode can sample without connecting its output to the speakers.
      const values = new Float32Array(analyser.fftSize)
      let peak = 0
      const measure = () => {
        analyser!.getFloatTimeDomainData(values)
        for (const value of values) peak = Math.max(peak, Math.abs(value))
      }
      clearTimeout(setupTimeout)
      measure()
      samples = setInterval(measure, 40)
      await Promise.race([
        new Promise<void>((resolve) => {
          duration = setTimeout(resolve, 2_000)
        }),
        cancelled
      ])
      measure()
      return { peak: Math.min(100, Math.round(peak * 100)) }
    }

    if (deviceId && deviceId !== 'default') {
      if (!context.setSinkId) throw new Error('output_selection_unsupported')
      await Promise.race([context.setSinkId(deviceId), cancelled])
    }
    gain = context.createGain()
    oscillator = context.createOscillator()
    oscillator.type = 'sine'
    oscillator.frequency.value = 440
    const now = context.currentTime
    gain.gain.setValueAtTime(0, now)
    gain.gain.linearRampToValueAtTime(0.08 * multiplier, now + 0.025)
    gain.gain.setValueAtTime(0.08 * multiplier, now + 0.425)
    gain.gain.linearRampToValueAtTime(0, now + 0.5)
    oscillator.connect(gain).connect(context.destination)
    oscillator.start()
    oscillatorStarted = true
    oscillator.stop(now + 0.52)
    clearTimeout(setupTimeout)
    await Promise.race([
      new Promise<void>((resolve) => {
        duration = setTimeout(resolve, 550)
      }),
      cancelled
    ])
    return {}
  } finally {
    await release()
  }
}

# Ordinary speech codec fixtures

These files contain a synthesized 440 Hz mono sine tone, with a one-second source.
They contain no speech, recordings, or third-party licensed content. They are
ordinary successful codec fixtures, shared by the server HTTP and LiveView audio
delivery tests. Tests read the committed bytes; they do not require FFmpeg.

Generated with FFmpeg 8.1.2 and its `libmp3lame` / `libopus` encoders, from the
repository root:

```sh
ffmpeg -hide_banner -loglevel error \
  -f lavfi -i 'sine=frequency=440:sample_rate=48000:duration=1' \
  -map_metadata -1 -ac 1 -ar 24000 -c:a libmp3lame -b:a 48k \
  -threads 1 -flags:a +bitexact -fflags +bitexact \
  -write_xing 0 -id3v2_version 0 \
  apps/synapsis_provider/test/fixtures/speech/tone.mp3

ffmpeg -hide_banner -loglevel error \
  -f lavfi -i 'sine=frequency=440:sample_rate=48000:duration=1' \
  -map_metadata -1 -ac 1 -ar 48000 -c:a libopus -b:a 32k \
  -vbr off -application audio -frame_duration 20 \
  -threads 1 -flags:a +bitexact -fflags +bitexact -serial_offset 0 \
  apps/synapsis_provider/test/fixtures/speech/tone.opus
```

No source metadata is copied. MP3 has no ID3 or Xing metadata; Ogg Opus retains
the encoder identification `Lavc libopus`. Fixed encoding options and Ogg serial
offset produced identical bytes on a second generation with this FFmpeg build.
Other encoder versions may produce different bytes.

| File | Container / codec | MIME | Channels | Sample rate | Probed duration | Decoded samples | Bytes |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `tone.mp3` | MP3 / MP3 | `audio/mpeg` | 1 | 24,000 Hz | 1.056 s | 25,344 | 6,336 |
| `tone.opus` | Ogg / Opus | `audio/ogg` | 1 | 48,000 Hz | 1.0065 s | 48,000 | 4,306 |

The MP3 duration includes encoder padding. Ogg Opus pre-skip is trimmed during
decoding, yielding exactly one second of PCM. Independent `ffprobe` inspection
and full FFmpeg decoding to signed 16-bit mono PCM succeeded for both files.

SHA-256:

```text
d5a040f559355708bb5f1e0e1f98708309c54057f842228a71c795956fa8b16a  tone.mp3
3699b4d6248a7ba896ac41e1edbdf31b622ca70d97a1281d79cb4368988cbfde  tone.opus
```

Optional fixture verification (not invoked by tests):

```sh
ffprobe -v error -show_entries stream=codec_name,sample_rate,channels,duration:format=format_name,duration,size \
  -of json apps/synapsis_provider/test/fixtures/speech/tone.mp3
ffmpeg -v error -i apps/synapsis_provider/test/fixtures/speech/tone.mp3 -f null -
ffprobe -v error -show_entries stream=codec_name,sample_rate,channels,duration:format=format_name,duration,size \
  -of json apps/synapsis_provider/test/fixtures/speech/tone.opus
ffmpeg -v error -i apps/synapsis_provider/test/fixtures/speech/tone.opus -f null -
```

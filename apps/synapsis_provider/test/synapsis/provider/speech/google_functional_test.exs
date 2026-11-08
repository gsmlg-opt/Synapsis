defmodule Synapsis.Provider.Speech.GoogleFunctionalTest do
  use ExUnit.Case, async: false
  alias Synapsis.Provider.Speech.Google

  @moduletag timeout: 90_000
  # Frozen source oracle: these are literal inputs/expectations independently
  # authored in scripts/openclaw/google-speech-functional.test.mjs before host
  # implementation. No generated capture output is read by these tests.
  # Its synthetic transcode result is intentionally never an audio oracle here:
  # voice-note rows use an independently generated PCM tone and real FFmpeg.
  @recipes Jason.decode!(~S"""
           {"config":[{"id":"config-defaults","input":{"rawConfig":{"providers":{"google":{"apiKey":"fixture-google-speech"}}}},"response":null,"expected":{"apiKey":"fixture-google-speech","model":"gemini-3.1-flash-tts-preview","voiceName":"Kore"}},{"id":"config-model-gemini-3.8-flash-tts","input":{"rawConfig":{"providers":{"google":{"apiKey":"fixture-google-speech","model":" google/gemini-3.8-flash-tts "}}}},"response":null,"expected":{"apiKey":"fixture-google-speech","model":"gemini-3.8-flash-tts","voiceName":"Kore"}},{"id":"config-model-gemini-3.8-flash-lite-tts","input":{"rawConfig":{"providers":{"google":{"apiKey":"fixture-google-speech","model":" google/gemini-3.8-flash-lite-tts "}}}},"response":null,"expected":{"apiKey":"fixture-google-speech","model":"gemini-3.8-flash-lite-tts","voiceName":"Kore"}},{"id":"config-model-gemini-3.1-flash-tts-preview","input":{"rawConfig":{"providers":{"google":{"apiKey":"fixture-google-speech","model":" google/gemini-3.1-flash-tts-preview "}}}},"response":null,"expected":{"apiKey":"fixture-google-speech","model":"gemini-3.1-flash-tts-preview","voiceName":"Kore"}},{"id":"config-model-gemini-2.5-flash-preview-tts","input":{"rawConfig":{"providers":{"google":{"apiKey":"fixture-google-speech","model":" google/gemini-2.5-flash-preview-tts "}}}},"response":null,"expected":{"apiKey":"fixture-google-speech","model":"gemini-2.5-flash-preview-tts","voiceName":"Kore"}},{"id":"config-model-gemini-2.5-pro-preview-tts","input":{"rawConfig":{"providers":{"google":{"apiKey":"fixture-google-speech","model":" google/gemini-2.5-pro-preview-tts "}}}},"response":null,"expected":{"apiKey":"fixture-google-speech","model":"gemini-2.5-pro-preview-tts","voiceName":"Kore"}},{"id":"config-alias-rich","input":{"rawConfig":{"providers":{"google":{"apiKey":"fixture-google-speech","model":" google/gemini-3.1-flash-tts ","voice":" Puck ","baseUrl":" https://generativelanguage.googleapis.com/v1beta/// ","audioProfile":" Warm ","speakerName":" Guide ","promptTemplate":" audio-profile-v1 ","personaPrompt":" Speak clearly "}}}},"response":null,"expected":{"apiKey":"fixture-google-speech","model":"gemini-3.1-flash-tts-preview","voiceName":"Puck","baseUrl":"https://generativelanguage.googleapis.com/v1beta///","audioProfile":"Warm","speakerName":"Guide","promptTemplate":"audio-profile-v1","personaPrompt":"Speak clearly"}},{"id":"config-dialogue-aliases","input":{"rawConfig":{"providers":{"google":{"apiKey":"fixture-google-speech","model":"gemini-3.8-flash-tts","voiceName":" Zephyr ","voice":"Kore","speakers":[{"speaker":" Puck ","voice":" Puck ","style":" Bright "},{"name":" Kore ","voiceName":" Kore ","style":" Gentle "}]}}}},"response":null,"expected":{"apiKey":"fixture-google-speech","model":"gemini-3.8-flash-tts","voiceName":"Zephyr","speakers":[{"speaker":"Puck","voice":"Puck","style":"Bright"},{"speaker":"Kore","voice":"Kore","style":"Gentle"}]}},{"id":"config-unicode","input":{"rawConfig":{"providers":{"google":{"apiKey":"fixture-google-speech","model":" ﻿google/gemini-3.1-flash-tts﻿ ","voiceName":" ﻿Kore﻿ "}}}},"response":null,"expected":{"apiKey":"fixture-google-speech","model":"gemini-3.1-flash-tts-preview","voiceName":"Kore"}}],"talkConfig":[{"id":"talk-defaults","input":{"baseTtsConfig":{"providers":{"google":{"apiKey":"fixture-google-speech"}}},"talkProviderConfig":{}},"response":null,"expected":{"apiKey":"fixture-google-speech","model":"gemini-3.1-flash-tts-preview","voiceName":"Kore"}},{"id":"talk-overlay","input":{"baseTtsConfig":{"providers":{"google":{"apiKey":"fixture-google-speech","audioProfile":" Warm ","speakerName":" Guide ","promptTemplate":"audio-profile-v1","personaPrompt":" Calm "}}},"talkProviderConfig":{"apiKey":" fixture-google-talk ","baseUrl":" https://generativelanguage.googleapis.com/ ","modelId":" google/gemini-3.8-flash-lite-tts ","voiceId":" Zephyr "}},"response":null,"expected":{"apiKey":"fixture-google-talk","model":"gemini-3.8-flash-lite-tts","voiceName":"Zephyr","baseUrl":"https://generativelanguage.googleapis.com/","audioProfile":"Warm","speakerName":"Guide","promptTemplate":"audio-profile-v1","personaPrompt":"Calm"}},{"id":"talk-inherit","input":{"baseTtsConfig":{"providers":{"google":{"apiKey":"fixture-google-speech","model":"gemini-3.8-flash-tts","voiceName":"Puck","speakers":[{"speaker":" Puck ","voice":" Puck ","style":" Bright "},{"name":" Kore ","voiceName":" Kore ","style":" Gentle "}]}}},"talkProviderConfig":{"modelId":" ","voiceId":" ","baseUrl":" "}},"response":null,"expected":{"apiKey":"fixture-google-speech","model":"gemini-3.8-flash-tts","voiceName":"Puck","speakers":[{"speaker":"Puck","voice":"Puck","style":"Bright"},{"speaker":"Kore","voice":"Kore","style":"Gentle"}]}},{"id":"talk-alias","input":{"baseTtsConfig":{"providers":{"google":{"apiKey":"fixture-google-speech"}}},"talkProviderConfig":{"modelId":"google/gemini-3.1-flash-tts","voiceId":" Aoede "}},"response":null,"expected":{"apiKey":"fixture-google-speech","model":"gemini-3.1-flash-tts-preview","voiceName":"Aoede"}}],"talkOverride":[{"id":"talk-overrides-empty","input":{"params":{}},"response":null,"expected":{}},{"id":"talk-overrides-both","input":{"params":{"voiceId":" Puck ","modelId":" google/gemini-3.8-flash-tts "}},"response":null,"expected":{"voiceName":"Puck","model":"gemini-3.8-flash-tts"}},{"id":"talk-overrides-alias","input":{"params":{"modelId":" google/gemini-3.1-flash-tts "}},"response":null,"expected":{"model":"gemini-3.1-flash-tts-preview"}},{"id":"talk-overrides-voice","input":{"params":{"voiceId":" Kore "}},"response":null,"expected":{"voiceName":"Kore"}}],"prepare":[{"id":"prepare-plain","input":{"rawConfig":{"providers":{"google":{"apiKey":"fixture-google-speech"}}},"text":"Hello plain."},"response":null,"expected":null},{"id":"prepare-profile-label","input":{"rawConfig":{"providers":{"google":{"apiKey":"fixture-google-speech","promptTemplate":"audio-profile-v1","personaPrompt":" Warm\r\nClear\u0001 "}}},"text":" Hello\r\nworld. ","persona":{"label":" Narrator\u0002 ","id":"ignored"}},"response":null,"expected":{"text":"Synthesize speech from the TRANSCRIPT section only. Use the other sections only\nas performance direction. Do not read section titles, notes, labels, or\nconfiguration aloud.\n\n# AUDIO PROFILE: Narrator\n\n### DIRECTOR'S NOTES\nProvider notes:\nWarm\nClear\n\n### TRANSCRIPT\nHello\nworld."}},{"id":"prepare-persona-id","input":{"rawConfig":{"providers":{"google":{"apiKey":"fixture-google-speech","personaPrompt":" Be calm "}}},"text":" A quiet line. ","persona":{"id":" Assistant "}},"response":null,"expected":{"text":"Synthesize speech from the TRANSCRIPT section only. Use the other sections only\nas performance direction. Do not read section titles, notes, labels, or\nconfiguration aloud.\n\n# AUDIO PROFILE: Assistant\n\n### DIRECTOR'S NOTES\nProvider notes:\nBe calm\n\n### TRANSCRIPT\nA quiet line."}},{"id":"prepare-template-only","input":{"rawConfig":{"providers":{"google":{"apiKey":"fixture-google-speech","promptTemplate":"audio-profile-v1"}}},"text":" Hello template. "},"response":null,"expected":{"text":"Synthesize speech from the TRANSCRIPT section only. Use the other sections only\nas performance direction. Do not read section titles, notes, labels, or\nconfiguration aloud.\n\n### TRANSCRIPT\nHello template."}},{"id":"prepare-already-wrapped","input":{"rawConfig":{"providers":{"google":{"apiKey":"fixture-google-speech","promptTemplate":"audio-profile-v1","personaPrompt":"Different"}}},"text":"Synthesize speech from the TRANSCRIPT section only. Use the other sections only\nas performance direction. Do not read section titles, notes, labels, or\nconfiguration aloud.\n\n# AUDIO PROFILE: Narrator\n\n### DIRECTOR'S NOTES\nProvider notes:\nWarm delivery\n\n### TRANSCRIPT\nHello there.\n\n### TRANSCRIPT\nSpoken delimiter."},"response":null,"expected":null},{"id":"prepare-interactions-unwrap","input":{"rawConfig":{"providers":{"google":{"apiKey":"fixture-google-speech","model":"gemini-3.8-flash-tts"}}},"text":"Synthesize speech from the TRANSCRIPT section only. Use the other sections only\nas performance direction. Do not read section titles, notes, labels, or\nconfiguration aloud.\n\n# AUDIO PROFILE: Narrator\n\n### DIRECTOR'S NOTES\nProvider notes:\nWarm delivery\n\n### TRANSCRIPT\nHello there.\n\n### TRANSCRIPT\nSpoken delimiter."},"response":null,"expected":{"text":"Hello there.\n\n### TRANSCRIPT\nSpoken delimiter."}},{"id":"prepare-interactions-plain","input":{"rawConfig":{"providers":{"google":{"apiKey":"fixture-google-speech","model":"gemini-3.8-flash-lite-tts","personaPrompt":"Calm"}}},"text":"Read this verbatim."},"response":null,"expected":null},{"id":"prepare-override-interactions","input":{"rawConfig":{"providers":{"google":{"apiKey":"fixture-google-speech","promptTemplate":"audio-profile-v1"}}},"providerOverrides":{"model":"gemini-3.8-flash-lite-tts"},"text":"Synthesize speech from the TRANSCRIPT section only. Use the other sections only\nas performance direction. Do not read section titles, notes, labels, or\nconfiguration aloud.\n\n# AUDIO PROFILE: Narrator\n\n### DIRECTOR'S NOTES\nProvider notes:\nWarm delivery\n\n### TRANSCRIPT\nHello there.\n\n### TRANSCRIPT\nSpoken delimiter."},"response":null,"expected":{"text":"Hello there.\n\n### TRANSCRIPT\nSpoken delimiter."}}],"synthesis":[{"id":"synthesize-gemini-3.8-flash-tts-file","input":{"rawConfig":{"providers":{"google":{"apiKey":"fixture-google-speech","model":"gemini-3.8-flash-tts"}}},"text":"Hello Google.","target":"file","timeoutMs":12345},"response":{"json":{"output_audio":{"data":"AAD/fwCA//8="}}},"expected":{"url":"https://generativelanguage.googleapis.com/v1beta/interactions","body":{"model":"gemini-3.8-flash-tts","store":false,"input":[{"type":"user_input","content":[{"type":"text","text":"Hello Google."}]}],"response_format":{"type":"audio","mime_type":"audio/l16","sample_rate":24000},"generation_config":{"speech_config":[{"voice":"Kore"}]}},"result":{"audioBase64":"UklGRiwAAABXQVZFZm10IBAAAAABAAEAwF0AAIC7AAACABAAZGF0YQgAAAAAAP9/AID//w==","outputFormat":"wav","fileExtension":".wav","voiceCompatible":false},"transcodes":[]}},{"id":"synthesize-gemini-3.8-flash-tts-voice-note","input":{"rawConfig":{"providers":{"google":{"apiKey":"fixture-google-speech","model":"gemini-3.8-flash-tts"}}},"text":"Hello Google.","target":"voice-note","timeoutMs":12345},"response":{"json":{"output_audio":{"data":"AAD/fwCA//8="}},"transcodeAudioBase64":"T2dnUwBmaXh0dXJlLW9wdXM="},"expected":{"url":"https://generativelanguage.googleapis.com/v1beta/interactions","body":{"model":"gemini-3.8-flash-tts","store":false,"input":[{"type":"user_input","content":[{"type":"text","text":"Hello Google."}]}],"response_format":{"type":"audio","mime_type":"audio/l16","sample_rate":24000},"generation_config":{"speech_config":[{"voice":"Kore"}]}},"result":{"audioBase64":"T2dnUwBmaXh0dXJlLW9wdXM=","outputFormat":"opus","fileExtension":".opus","voiceCompatible":true},"transcodes":[{"audioBase64":"UklGRiwAAABXQVZFZm10IBAAAAABAAEAwF0AAIC7AAACABAAZGF0YQgAAAAAAP9/AID//w==","inputExtension":"wav","tempPrefix":"tts-google-","timeoutMs":12345,"outputAudioBase64":"T2dnUwBmaXh0dXJlLW9wdXM="}]}},{"id":"synthesize-gemini-3.8-flash-lite-tts-file","input":{"rawConfig":{"providers":{"google":{"apiKey":"fixture-google-speech","model":"gemini-3.8-flash-lite-tts"}}},"text":"Hello Google.","target":"file","timeoutMs":12345},"response":{"json":{"output_audio":{"data":"AAD/fwCA//8="}}},"expected":{"url":"https://generativelanguage.googleapis.com/v1beta/interactions","body":{"model":"gemini-3.8-flash-lite-tts","store":false,"input":[{"type":"user_input","content":[{"type":"text","text":"Hello Google."}]}],"response_format":{"type":"audio","mime_type":"audio/l16","sample_rate":24000},"generation_config":{"speech_config":[{"voice":"Kore"}]}},"result":{"audioBase64":"UklGRiwAAABXQVZFZm10IBAAAAABAAEAwF0AAIC7AAACABAAZGF0YQgAAAAAAP9/AID//w==","outputFormat":"wav","fileExtension":".wav","voiceCompatible":false},"transcodes":[]}},{"id":"synthesize-gemini-3.8-flash-lite-tts-voice-note","input":{"rawConfig":{"providers":{"google":{"apiKey":"fixture-google-speech","model":"gemini-3.8-flash-lite-tts"}}},"text":"Hello Google.","target":"voice-note","timeoutMs":12345},"response":{"json":{"output_audio":{"data":"AAD/fwCA//8="}},"transcodeAudioBase64":"T2dnUwBmaXh0dXJlLW9wdXM="},"expected":{"url":"https://generativelanguage.googleapis.com/v1beta/interactions","body":{"model":"gemini-3.8-flash-lite-tts","store":false,"input":[{"type":"user_input","content":[{"type":"text","text":"Hello Google."}]}],"response_format":{"type":"audio","mime_type":"audio/l16","sample_rate":24000},"generation_config":{"speech_config":[{"voice":"Kore"}]}},"result":{"audioBase64":"T2dnUwBmaXh0dXJlLW9wdXM=","outputFormat":"opus","fileExtension":".opus","voiceCompatible":true},"transcodes":[{"audioBase64":"UklGRiwAAABXQVZFZm10IBAAAAABAAEAwF0AAIC7AAACABAAZGF0YQgAAAAAAP9/AID//w==","inputExtension":"wav","tempPrefix":"tts-google-","timeoutMs":12345,"outputAudioBase64":"T2dnUwBmaXh0dXJlLW9wdXM="}]}},{"id":"synthesize-gemini-3.1-flash-tts-preview-file","input":{"rawConfig":{"providers":{"google":{"apiKey":"fixture-google-speech","model":"gemini-3.1-flash-tts-preview"}}},"text":"Hello Google.","target":"file","timeoutMs":12345},"response":{"json":{"candidates":[{"content":{"parts":[{"text":"synthetic metadata"},{"inlineData":{"mimeType":"audio/L16","data":"AAD/fwCA//8="}}]}}]}},"expected":{"url":"https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-tts-preview:generateContent","body":{"contents":[{"role":"user","parts":[{"text":"Hello Google."}]}],"generationConfig":{"responseModalities":["AUDIO"],"speechConfig":{"voiceConfig":{"prebuiltVoiceConfig":{"voiceName":"Kore"}}}}},"result":{"audioBase64":"UklGRiwAAABXQVZFZm10IBAAAAABAAEAwF0AAIC7AAACABAAZGF0YQgAAAAAAP9/AID//w==","outputFormat":"wav","fileExtension":".wav","voiceCompatible":false},"transcodes":[]}},{"id":"synthesize-gemini-3.1-flash-tts-preview-voice-note","input":{"rawConfig":{"providers":{"google":{"apiKey":"fixture-google-speech","model":"gemini-3.1-flash-tts-preview"}}},"text":"Hello Google.","target":"voice-note","timeoutMs":12345},"response":{"json":{"candidates":[{"content":{"parts":[{"text":"synthetic metadata"},{"inlineData":{"mimeType":"audio/L16","data":"AAD/fwCA//8="}}]}}]},"transcodeAudioBase64":"T2dnUwBmaXh0dXJlLW9wdXM="},"expected":{"url":"https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-tts-preview:generateContent","body":{"contents":[{"role":"user","parts":[{"text":"Hello Google."}]}],"generationConfig":{"responseModalities":["AUDIO"],"speechConfig":{"voiceConfig":{"prebuiltVoiceConfig":{"voiceName":"Kore"}}}}},"result":{"audioBase64":"T2dnUwBmaXh0dXJlLW9wdXM=","outputFormat":"opus","fileExtension":".opus","voiceCompatible":true},"transcodes":[{"audioBase64":"UklGRiwAAABXQVZFZm10IBAAAAABAAEAwF0AAIC7AAACABAAZGF0YQgAAAAAAP9/AID//w==","inputExtension":"wav","tempPrefix":"tts-google-","timeoutMs":12345,"outputAudioBase64":"T2dnUwBmaXh0dXJlLW9wdXM="}]}},{"id":"synthesize-gemini-2.5-flash-preview-tts-file","input":{"rawConfig":{"providers":{"google":{"apiKey":"fixture-google-speech","model":"gemini-2.5-flash-preview-tts"}}},"text":"Hello Google.","target":"file","timeoutMs":12345},"response":{"json":{"candidates":[{"content":{"parts":[{"text":"synthetic metadata"},{"inlineData":{"mimeType":"audio/L16","data":"AAD/fwCA//8="}}]}}]}},"expected":{"url":"https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-preview-tts:generateContent","body":{"contents":[{"role":"user","parts":[{"text":"Hello Google."}]}],"generationConfig":{"responseModalities":["AUDIO"],"speechConfig":{"voiceConfig":{"prebuiltVoiceConfig":{"voiceName":"Kore"}}}}},"result":{"audioBase64":"UklGRiwAAABXQVZFZm10IBAAAAABAAEAwF0AAIC7AAACABAAZGF0YQgAAAAAAP9/AID//w==","outputFormat":"wav","fileExtension":".wav","voiceCompatible":false},"transcodes":[]}},{"id":"synthesize-gemini-2.5-flash-preview-tts-voice-note","input":{"rawConfig":{"providers":{"google":{"apiKey":"fixture-google-speech","model":"gemini-2.5-flash-preview-tts"}}},"text":"Hello Google.","target":"voice-note","timeoutMs":12345},"response":{"json":{"candidates":[{"content":{"parts":[{"text":"synthetic metadata"},{"inlineData":{"mimeType":"audio/L16","data":"AAD/fwCA//8="}}]}}]},"transcodeAudioBase64":"T2dnUwBmaXh0dXJlLW9wdXM="},"expected":{"url":"https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-preview-tts:generateContent","body":{"contents":[{"role":"user","parts":[{"text":"Hello Google."}]}],"generationConfig":{"responseModalities":["AUDIO"],"speechConfig":{"voiceConfig":{"prebuiltVoiceConfig":{"voiceName":"Kore"}}}}},"result":{"audioBase64":"T2dnUwBmaXh0dXJlLW9wdXM=","outputFormat":"opus","fileExtension":".opus","voiceCompatible":true},"transcodes":[{"audioBase64":"UklGRiwAAABXQVZFZm10IBAAAAABAAEAwF0AAIC7AAACABAAZGF0YQgAAAAAAP9/AID//w==","inputExtension":"wav","tempPrefix":"tts-google-","timeoutMs":12345,"outputAudioBase64":"T2dnUwBmaXh0dXJlLW9wdXM="}]}},{"id":"synthesize-gemini-2.5-pro-preview-tts-file","input":{"rawConfig":{"providers":{"google":{"apiKey":"fixture-google-speech","model":"gemini-2.5-pro-preview-tts"}}},"text":"Hello Google.","target":"file","timeoutMs":12345},"response":{"json":{"candidates":[{"content":{"parts":[{"text":"synthetic metadata"},{"inlineData":{"mimeType":"audio/L16","data":"AAD/fwCA//8="}}]}}]}},"expected":{"url":"https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-pro-preview-tts:generateContent","body":{"contents":[{"role":"user","parts":[{"text":"Hello Google."}]}],"generationConfig":{"responseModalities":["AUDIO"],"speechConfig":{"voiceConfig":{"prebuiltVoiceConfig":{"voiceName":"Kore"}}}}},"result":{"audioBase64":"UklGRiwAAABXQVZFZm10IBAAAAABAAEAwF0AAIC7AAACABAAZGF0YQgAAAAAAP9/AID//w==","outputFormat":"wav","fileExtension":".wav","voiceCompatible":false},"transcodes":[]}},{"id":"synthesize-gemini-2.5-pro-preview-tts-voice-note","input":{"rawConfig":{"providers":{"google":{"apiKey":"fixture-google-speech","model":"gemini-2.5-pro-preview-tts"}}},"text":"Hello Google.","target":"voice-note","timeoutMs":12345},"response":{"json":{"candidates":[{"content":{"parts":[{"text":"synthetic metadata"},{"inlineData":{"mimeType":"audio/L16","data":"AAD/fwCA//8="}}]}}]},"transcodeAudioBase64":"T2dnUwBmaXh0dXJlLW9wdXM="},"expected":{"url":"https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-pro-preview-tts:generateContent","body":{"contents":[{"role":"user","parts":[{"text":"Hello Google."}]}],"generationConfig":{"responseModalities":["AUDIO"],"speechConfig":{"voiceConfig":{"prebuiltVoiceConfig":{"voiceName":"Kore"}}}}},"result":{"audioBase64":"T2dnUwBmaXh0dXJlLW9wdXM=","outputFormat":"opus","fileExtension":".opus","voiceCompatible":true},"transcodes":[{"audioBase64":"UklGRiwAAABXQVZFZm10IBAAAAABAAEAwF0AAIC7AAACABAAZGF0YQgAAAAAAP9/AID//w==","inputExtension":"wav","tempPrefix":"tts-google-","timeoutMs":12345,"outputAudioBase64":"T2dnUwBmaXh0dXJlLW9wdXM="}]}},{"id":"generate-alias-overrides","input":{"rawConfig":{"providers":{"google":{"apiKey":"fixture-google-speech","model":"google/gemini-3.1-flash-tts","voiceName":"Puck","audioProfile":" Warm ","speakerName":" Guide "}}},"text":"Hello Google.","target":"file","timeoutMs":12345,"providerOverrides":{"voice":" Zephyr ","audioProfile":" Bright ","speakerName":" Narrator "}},"response":{"json":{"candidates":[{"content":{"parts":[{"text":"first candidate"}]}},{"content":{"parts":[{"inline_data":{"data":" -_8AAQ==\n"}}]}}]}},"expected":{"url":"https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-tts-preview:generateContent","body":{"contents":[{"role":"user","parts":[{"text":"Bright\n\nSpeaker name: Narrator\n\nHello Google."}]}],"generationConfig":{"responseModalities":["AUDIO"],"speechConfig":{"voiceConfig":{"prebuiltVoiceConfig":{"voiceName":"Zephyr"}}}}},"result":{"audioBase64":"UklGRigAAABXQVZFZm10IBAAAAABAAEAwF0AAIC7AAACABAAZGF0YQQAAAD7/wAB","outputFormat":"wav","fileExtension":".wav","voiceCompatible":false},"transcodes":[]}},{"id":"generate-custom-model","input":{"rawConfig":{"providers":{"google":{"apiKey":"fixture-google-speech","model":"fixture-custom-tts"}}},"text":"Hello Google.","target":"file","timeoutMs":12345},"response":{"json":{"candidates":[{"content":{"parts":[{"text":"synthetic metadata"},{"inlineData":{"mimeType":"audio/L16","data":"AAD/fwCA//8"}}]}}]}},"expected":{"url":"https://generativelanguage.googleapis.com/v1beta/models/fixture-custom-tts:generateContent","body":{"contents":[{"role":"user","parts":[{"text":"Hello Google."}]}],"generationConfig":{"responseModalities":["AUDIO"],"speechConfig":{"voiceConfig":{"prebuiltVoiceConfig":{"voiceName":"Kore"}}}}},"result":{"audioBase64":"UklGRiwAAABXQVZFZm10IBAAAAABAAEAwF0AAIC7AAACABAAZGF0YQgAAAAAAP9/AID//w==","outputFormat":"wav","fileExtension":".wav","voiceCompatible":false},"transcodes":[]}},{"id":"generate-wav-strip","input":{"rawConfig":{"providers":{"google":{"apiKey":"fixture-google-speech","model":"gemini-2.5-flash-preview-tts"}}},"text":"Hello Google.","target":"file","timeoutMs":12345},"response":{"json":{"candidates":[{"content":{"parts":[{"text":"first candidate"}]}},{"content":{"parts":[{"inline_data":{"data":"UklGRiwAAABXQVZFZm10IBAAAAABAAEAwF0AAIC7AAACABAAZGF0YQgAAAAAAP9/AID//w=="}}]}}]}},"expected":{"url":"https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-preview-tts:generateContent","body":{"contents":[{"role":"user","parts":[{"text":"Hello Google."}]}],"generationConfig":{"responseModalities":["AUDIO"],"speechConfig":{"voiceConfig":{"prebuiltVoiceConfig":{"voiceName":"Kore"}}}}},"result":{"audioBase64":"UklGRiwAAABXQVZFZm10IBAAAAABAAEAwF0AAIC7AAACABAAZGF0YQgAAAAAAP9/AID//w==","outputFormat":"wav","fileExtension":".wav","voiceCompatible":false},"transcodes":[]}},{"id":"generate-odd-chunk-strip","input":{"rawConfig":{"providers":{"google":{"apiKey":"fixture-google-speech","model":"gemini-2.5-pro-preview-tts"}}},"text":"Hello Google.","target":"file","timeoutMs":12345},"response":{"json":{"candidates":[{"content":{"parts":[{"text":"synthetic metadata"},{"inlineData":{"mimeType":"audio/L16","data":"UklGRjgAAABXQVZFSlVOSwMAAABhYmMAZm10IBAAAAABAAEAwF0AAIC7AAACABAAZGF0YQgAAAAAAP9/AID//w=="}}]}}]}},"expected":{"url":"https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-pro-preview-tts:generateContent","body":{"contents":[{"role":"user","parts":[{"text":"Hello Google."}]}],"generationConfig":{"responseModalities":["AUDIO"],"speechConfig":{"voiceConfig":{"prebuiltVoiceConfig":{"voiceName":"Kore"}}}}},"result":{"audioBase64":"UklGRiwAAABXQVZFZm10IBAAAAABAAEAwF0AAIC7AAACABAAZGF0YQgAAAAAAP9/AID//w==","outputFormat":"wav","fileExtension":".wav","voiceCompatible":false},"transcodes":[]}},{"id":"interactions-single-style","input":{"rawConfig":{"providers":{"google":{"apiKey":"fixture-google-speech","model":"gemini-3.8-flash-tts","voice":" Aoede ","audioProfile":" Warm ","speakerName":" Narrator ","personaPrompt":" Calm "}}},"text":"Hello Google.","target":"file","timeoutMs":12345},"response":{"json":{"outputAudio":{"data":"-_8AAQ"}}},"expected":{"url":"https://generativelanguage.googleapis.com/v1beta/interactions","body":{"model":"gemini-3.8-flash-tts","store":false,"input":[{"type":"user_input","content":[{"type":"text","text":"Hello Google.","annotations":[{"type":"speech_metadata","speaker":"Narrator","style":"Warm\n\nCalm"}]}]}],"response_format":{"type":"audio","mime_type":"audio/l16","sample_rate":24000},"generation_config":{"speech_config":[{"voice":"Aoede"}]}},"result":{"audioBase64":"UklGRigAAABXQVZFZm10IBAAAAABAAEAwF0AAIC7AAACABAAZGF0YQQAAAD7/wAB","outputFormat":"wav","fileExtension":".wav","voiceCompatible":false},"transcodes":[]}},{"id":"interactions-dialogue","input":{"rawConfig":{"providers":{"google":{"apiKey":"fixture-google-speech","model":"gemini-3.8-flash-tts","speakers":[{"speaker":" Puck ","voice":" Puck ","style":" Bright "},{"name":" Kore ","voiceName":" Kore ","style":" Gentle "}],"audioProfile":" Warm ","personaPrompt":" Clear "}}},"text":"Intro before label.\r\nKore:Hello.\nKore:Again.\nBudget: 10 dollars\nPuck: Welcome.\nContinuation.\nPuck:\nKore: Bye.","target":"file","timeoutMs":12345},"response":{"json":{"steps":[{"content":[{"type":"text","data":"spoken metadata"},{"type":"audio","data":"UklGRjgAAABXQVZFSlVOSwMAAABhYmMAZm10IBAAAAABAAEAwF0AAIC7AAACABAAZGF0YQgAAAAAAP9/AID//w=="}]}]}},"expected":{"url":"https://generativelanguage.googleapis.com/v1beta/interactions","body":{"model":"gemini-3.8-flash-tts","store":false,"input":[{"type":"user_input","content":[{"type":"text","text":"Intro before label. Hello. Again. Budget: 10 dollars","annotations":[{"type":"speech_metadata","speaker":"Kore","style":"Gentle\n\nWarm\n\nClear"}]},{"type":"text","text":"Welcome. Continuation.","annotations":[{"type":"speech_metadata","speaker":"Puck","style":"Bright\n\nWarm\n\nClear"}]},{"type":"text","text":"Bye.","annotations":[{"type":"speech_metadata","speaker":"Kore","style":"Gentle\n\nWarm\n\nClear"}]}]}],"response_format":{"type":"audio","mime_type":"audio/l16","sample_rate":24000},"generation_config":{"speech_config":{"mode":"conversational","speakers":[{"speaker":"Puck","voice":"Puck"},{"speaker":"Kore","voice":"Kore"}]}}},"result":{"audioBase64":"UklGRiwAAABXQVZFZm10IBAAAAABAAEAwF0AAIC7AAACABAAZGF0YQgAAAAAAP9/AID//w==","outputFormat":"wav","fileExtension":".wav","voiceCompatible":false},"transcodes":[]}},{"id":"interactions-lite-dialogue","input":{"rawConfig":{"providers":{"google":{"apiKey":"fixture-google-speech","model":"gemini-3.8-flash-lite-tts","speakers":[{"speaker":" Puck ","voice":" Puck ","style":" Bright "},{"name":" Kore ","voiceName":" Kore ","style":" Gentle "}]}}},"text":"Puck: First.\nKore: Second.","target":"file","timeoutMs":12345},"response":{"json":{"steps":[{"content":[{"mime_type":"audio/l16","data":"UklGRiwAAABXQVZFZm10IBAAAAABAAEAwF0AAIC7AAACABAAZGF0YQgAAAAAAP9/AID//w=="}]}]}},"expected":{"url":"https://generativelanguage.googleapis.com/v1beta/interactions","body":{"model":"gemini-3.8-flash-lite-tts","store":false,"input":[{"type":"user_input","content":[{"type":"text","text":"First.","annotations":[{"type":"speech_metadata","speaker":"Puck","style":"Bright"}]},{"type":"text","text":"Second.","annotations":[{"type":"speech_metadata","speaker":"Kore","style":"Gentle"}]}]}],"response_format":{"type":"audio","mime_type":"audio/l16","sample_rate":24000},"generation_config":{"speech_config":{"mode":"conversational","speakers":[{"speaker":"Puck","voice":"Puck"},{"speaker":"Kore","voice":"Kore"}]}}},"result":{"audioBase64":"UklGRiwAAABXQVZFZm10IBAAAAABAAEAwF0AAIC7AAACABAAZGF0YQgAAAAAAP9/AID//w==","outputFormat":"wav","fileExtension":".wav","voiceCompatible":false},"transcodes":[]}},{"id":"interactions-speakers-unlabeled","input":{"rawConfig":{"providers":{"google":{"apiKey":"fixture-google-speech","model":"gemini-3.8-flash-lite-tts","speakers":[{"speaker":" Puck ","voice":" Puck ","style":" Bright "},{"name":" Kore ","voiceName":" Kore ","style":" Gentle "}]}}},"text":"An unlabeled single utterance.","target":"file","timeoutMs":12345},"response":{"json":{"steps":[{"content":[{"mimeType":"audio/l16","data":"AAD/fwCA//8="}]}]}},"expected":{"url":"https://generativelanguage.googleapis.com/v1beta/interactions","body":{"model":"gemini-3.8-flash-lite-tts","store":false,"input":[{"type":"user_input","content":[{"type":"text","text":"An unlabeled single utterance."}]}],"response_format":{"type":"audio","mime_type":"audio/l16","sample_rate":24000},"generation_config":{"speech_config":[{"voice":"Kore"}]}},"result":{"audioBase64":"UklGRiwAAABXQVZFZm10IBAAAAABAAEAwF0AAIC7AAACABAAZGF0YQgAAAAAAP9/AID//w==","outputFormat":"wav","fileExtension":".wav","voiceCompatible":false},"transcodes":[]}},{"id":"request-source-normalization","input":{"rawConfig":{"providers":{"google":{"apiKey":"fixture-google-speech","model":"gemini-3.1-flash-tts-preview","baseUrl":" https://generativelanguage.googleapis.com/v1beta/openai/// "}}},"text":"Hello Google.","target":"file","timeoutMs":12345,"cfg":{"models":{"providers":{"google":{"request":{"headers":{"X-Fixture":" trace-google "}}}}}}},"response":{"json":{"candidates":[{"content":{"parts":[{"text":"synthetic metadata"},{"inlineData":{"mimeType":"audio/L16","data":"AAD/fwCA//8="}}]}}]}},"expected":{"url":"https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-tts-preview:generateContent","body":{"contents":[{"role":"user","parts":[{"text":"Hello Google."}]}],"generationConfig":{"responseModalities":["AUDIO"],"speechConfig":{"voiceConfig":{"prebuiltVoiceConfig":{"voiceName":"Kore"}}}}},"result":{"audioBase64":"UklGRiwAAABXQVZFZm10IBAAAAABAAEAwF0AAIC7AAACABAAZGF0YQgAAAAAAP9/AID//w==","outputFormat":"wav","fileExtension":".wav","voiceCompatible":false},"transcodes":[]}}],"telephony":[{"id":"telephony-generate-pcm","input":{"rawConfig":{"providers":{"google":{"apiKey":"fixture-google-speech","model":"gemini-3.1-flash-tts-preview"}}},"text":"Hello Google.","target":"telephony","timeoutMs":12345},"response":{"json":{"candidates":[{"content":{"parts":[{"text":"synthetic metadata"},{"inlineData":{"mimeType":"audio/L16","data":"AAD/fwCA//8="}}]}}]}},"expected":{"url":"https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-tts-preview:generateContent","body":{"contents":[{"role":"user","parts":[{"text":"Hello Google."}]}],"generationConfig":{"responseModalities":["AUDIO"],"speechConfig":{"voiceConfig":{"prebuiltVoiceConfig":{"voiceName":"Kore"}}}}},"result":{"audioBase64":"AAD/fwCA//8=","outputFormat":"pcm","sampleRate":24000},"transcodes":[]}},{"id":"telephony-generate-wav","input":{"rawConfig":{"providers":{"google":{"apiKey":"fixture-google-speech","model":"gemini-2.5-flash-preview-tts"}}},"text":"Hello Google.","target":"telephony","timeoutMs":12345},"response":{"json":{"candidates":[{"content":{"parts":[{"text":"first candidate"}]}},{"content":{"parts":[{"inline_data":{"data":"UklGRjgAAABXQVZFSlVOSwMAAABhYmMAZm10IBAAAAABAAEAwF0AAIC7AAACABAAZGF0YQgAAAAAAP9/AID//w=="}}]}}]}},"expected":{"url":"https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-preview-tts:generateContent","body":{"contents":[{"role":"user","parts":[{"text":"Hello Google."}]}],"generationConfig":{"responseModalities":["AUDIO"],"speechConfig":{"voiceConfig":{"prebuiltVoiceConfig":{"voiceName":"Kore"}}}}},"result":{"audioBase64":"AAD/fwCA//8=","outputFormat":"pcm","sampleRate":24000},"transcodes":[]}},{"id":"telephony-interactions-pcm","input":{"rawConfig":{"providers":{"google":{"apiKey":"fixture-google-speech","model":"gemini-3.8-flash-tts"}}},"text":"Hello Google.","target":"telephony","timeoutMs":12345},"response":{"json":{"outputAudio":{"data":"-_8AAQ=="}}},"expected":{"url":"https://generativelanguage.googleapis.com/v1beta/interactions","body":{"model":"gemini-3.8-flash-tts","store":false,"input":[{"type":"user_input","content":[{"type":"text","text":"Hello Google."}]}],"response_format":{"type":"audio","mime_type":"audio/l16","sample_rate":24000},"generation_config":{"speech_config":[{"voice":"Kore"}]}},"result":{"audioBase64":"+/8AAQ==","outputFormat":"pcm","sampleRate":24000},"transcodes":[]}},{"id":"telephony-interactions-wav","input":{"rawConfig":{"providers":{"google":{"apiKey":"fixture-google-speech","model":"gemini-3.8-flash-lite-tts"}}},"text":"Hello Google.","target":"telephony","timeoutMs":12345},"response":{"json":{"steps":[{"content":[{"type":"text","data":"spoken metadata"},{"type":"audio","data":"UklGRiwAAABXQVZFZm10IBAAAAABAAEAwF0AAIC7AAACABAAZGF0YQgAAAAAAP9/AID//w=="}]}]}},"expected":{"url":"https://generativelanguage.googleapis.com/v1beta/interactions","body":{"model":"gemini-3.8-flash-lite-tts","store":false,"input":[{"type":"user_input","content":[{"type":"text","text":"Hello Google."}]}],"response_format":{"type":"audio","mime_type":"audio/l16","sample_rate":24000},"generation_config":{"speech_config":[{"voice":"Kore"}]}},"result":{"audioBase64":"AAD/fwCA//8=","outputFormat":"pcm","sampleRate":24000},"transcodes":[]}}],"voices":[{"id":"voices-static","input":{},"response":null,"expected":[{"id":"Zephyr","name":"Zephyr"},{"id":"Puck","name":"Puck"},{"id":"Charon","name":"Charon"},{"id":"Kore","name":"Kore"},{"id":"Fenrir","name":"Fenrir"},{"id":"Leda","name":"Leda"},{"id":"Orus","name":"Orus"},{"id":"Aoede","name":"Aoede"},{"id":"Callirrhoe","name":"Callirrhoe"},{"id":"Autonoe","name":"Autonoe"},{"id":"Enceladus","name":"Enceladus"},{"id":"Iapetus","name":"Iapetus"},{"id":"Umbriel","name":"Umbriel"},{"id":"Algieba","name":"Algieba"},{"id":"Despina","name":"Despina"},{"id":"Erinome","name":"Erinome"},{"id":"Algenib","name":"Algenib"},{"id":"Rasalgethi","name":"Rasalgethi"},{"id":"Laomedeia","name":"Laomedeia"},{"id":"Achernar","name":"Achernar"},{"id":"Alnilam","name":"Alnilam"},{"id":"Schedar","name":"Schedar"},{"id":"Gacrux","name":"Gacrux"},{"id":"Pulcherrima","name":"Pulcherrima"},{"id":"Achird","name":"Achird"},{"id":"Zubenelgenubi","name":"Zubenelgenubi"},{"id":"Vindemiatrix","name":"Vindemiatrix"},{"id":"Sadachbia","name":"Sadachbia"},{"id":"Sadaltager","name":"Sadaltager"},{"id":"Sulafat","name":"Sulafat"}]}]}
           """)
  @metadata Jason.decode!(~S"""
            {"id":"google","label":"Google","autoSelectOrder":50,"defaultModel":"gemini-3.1-flash-tts-preview","models":["gemini-3.8-flash-tts","gemini-3.8-flash-lite-tts","gemini-3.1-flash-tts-preview","gemini-2.5-flash-preview-tts","gemini-2.5-pro-preview-tts"],"voices":["Zephyr","Puck","Charon","Kore","Fenrir","Leda","Orus","Aoede","Callirrhoe","Autonoe","Enceladus","Iapetus","Umbriel","Algieba","Despina","Erinome","Algenib","Rasalgethi","Laomedeia","Achernar","Alnilam","Schedar","Gacrux","Pulcherrima","Achird","Zubenelgenubi","Vindemiatrix","Sadachbia","Sadaltager","Sulafat"]}
            """)

  test "literal ordered metadata, all five models and thirty static voices" do
    assert Google.metadata() == canonical(@metadata)
    assert Google.models() == @metadata["models"]
    assert Google.voices() == @metadata["voices"]
    assert {:ok, voices} = Google.list_voices()
    assert voices == Enum.map(@metadata["voices"], &%{id: &1, name: &1})
    assert Enum.sum(Enum.map(@recipes, fn {_, rows} -> length(rows) end)) == 49
  end

  for group <- ~w(config talkConfig talkOverride prepare), row <- @recipes[group] do
    @group group
    @row row
    test "full source callback #{@group}: #{row["id"]}" do
      input = @row["input"]
      expected = canonical(@row["expected"])

      case @group do
        "config" ->
          assert Google.resolve_config(input["rawConfig"]) == expected

        "talkConfig" ->
          assert Google.resolve_talk_config(input["baseTtsConfig"], input["talkProviderConfig"]) ==
                   expected

        "talkOverride" ->
          assert Google.resolve_talk_overrides(input["params"]) == expected

        "prepare" ->
          context = %{
            text: input["text"],
            provider_config: Google.resolve_config(input["rawConfig"]),
            provider_overrides: canonical(input["providerOverrides"] || %{}),
            persona: canonical(input["persona"] || %{})
          }

          assert Google.prepare_synthesis(context) == {:ok, expected}
      end
    end
  end

  for group <- ~w(synthesis telephony), row <- @recipes[group] do
    @group group
    @row row
    test "actual host JSON, complete request and result #{@group}: #{row["id"]}" do
      input = @row["input"]
      expected = @row["expected"]
      config = Google.resolve_config(input["rawConfig"])
      request = request(input)
      assert {:ok, built} = Google.build_request(request, config)
      assert built.url == expected["url"]
      assert built.body == expected["body"]
      assert built.timeout_ms == 12_345
      assert {"content-type", "application/json"} in built.headers
      # Positive header assembly provenance using a dummy key only.
      assert {"x-goog-api-key", "fixture-google-speech"} in built.headers

      fixture = Gaoxy.Test.open()
      on_exit(fn -> Gaoxy.Test.close(fixture) end)
      owner = self()
      note? = request.target == :voice_note
      response = if note?, do: tone_response(built.url), else: @row["response"]["json"]
      path = URI.parse(expected["url"]).path

      Gaoxy.Test.stub(fixture, "POST", path, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body) == expected["body"]
        assert Plug.Conn.get_req_header(conn, "x-goog-api-key") == ["fixture-google-speech"]
        send(owner, {:google_http_completed, self()})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(response))
      end)

      config = Map.put(config, :base_url, Gaoxy.Test.url(fixture, "/v1beta"))
      links_before = elem(Process.info(self(), :links), 1) |> MapSet.new()
      ports_before = owned_ports()
      temp_before = Path.wildcard(Path.join(System.tmp_dir!(), "tts-google-*")) |> MapSet.new()

      output =
        if @group == "telephony",
          do: Google.synthesize_telephony(request, config),
          else: Google.synthesize(request, config)

      assert {:ok, result} = output
      assert owned_ports() == ports_before

      assert Path.wildcard(Path.join(System.tmp_dir!(), "tts-google-*")) |> MapSet.new() ==
               temp_before

      assert_receive {:google_http_completed, _}, 5_000

      if note? do
        assert Map.drop(result, [:audio]) == %{
                 output_format: "opus",
                 file_extension: ".opus",
                 voice_compatible: true
               }

        assert_opus(result.audio, @row["id"])
      else
        assert result == expected_result(expected["result"])
      end

      # Normal service return owns completion of its invocation-local linked task.
      links_after = elem(Process.info(self(), :links), 1) |> MapSet.new()
      assert MapSet.difference(links_after, links_before) == MapSet.new()
      refute_receive {:google_http_completed, _}, 20
    end
  end

  for row <- @recipes["prepare"] do
    @row row
    test "consumer explicitly prepares then synthesizes #{row["id"]}" do
      input = @row["input"]
      config = Google.resolve_config(input["rawConfig"])
      overrides = canonical(input["providerOverrides"] || %{})

      assert {:ok, prepared} =
               Google.prepare_synthesis(%{
                 text: input["text"],
                 provider_config: config,
                 provider_overrides: overrides,
                 persona: canonical(input["persona"] || %{})
               })

      expected_text = if @row["expected"], do: @row["expected"]["text"], else: input["text"]
      text = if prepared, do: prepared.text, else: input["text"]
      assert text == expected_text

      request = %{
        text: text,
        target: :audio_file,
        timeout_ms: 12_345,
        provider_overrides: overrides
      }

      source = input["rawConfig"]["providers"]["google"]

      model =
        Map.get(
          input["providerOverrides"] || %{},
          "model",
          source["model"] || "gemini-3.1-flash-tts-preview"
        )

      oracle_config = %{
        voice_name: source["voiceName"] || source["voice"] || "Kore",
        audio_profile: source["audioProfile"],
        speaker_name: source["speakerName"],
        persona_prompt: if(source["personaPrompt"], do: String.trim(source["personaPrompt"]))
      }

      expected_body =
        if model in ["gemini-3.8-flash-tts", "gemini-3.8-flash-lite-tts"] do
          style =
            [oracle_config[:audio_profile], oracle_config[:persona_prompt]]
            |> Enum.reject(&is_nil/1)
            |> Enum.join("\n\n")

          metadata =
            %{"type" => "speech_metadata"}
            |> maybe_put("speaker", oracle_config[:speaker_name])
            |> maybe_put("style", if(style != "", do: style))

          block = %{"type" => "text", "text" => expected_text}

          block =
            if map_size(metadata) > 1, do: Map.put(block, "annotations", [metadata]), else: block

          interactions(model, [block], [%{"voice" => oracle_config.voice_name}])
        else
          text =
            [
              oracle_config[:audio_profile],
              if(oracle_config[:speaker_name], do: "Speaker name: " <> oracle_config.speaker_name),
              expected_text
            ]
            |> Enum.reject(&is_nil/1)
            |> Enum.join("\n\n")

          generate(text, oracle_config.voice_name)
        end

      synthesize_expected(request, config, expected_body)
    end
  end

  for row <- @recipes["talkConfig"] do
    @row row
    test "Talk inheritance and overrides feed preparation and actual HTTP #{row["id"]}" do
      input = @row["input"]
      config = Google.resolve_talk_config(input["baseTtsConfig"], input["talkProviderConfig"])
      oracle_config = canonical(@row["expected"])
      assert config == oracle_config
      # A real Talk per-call callback output changes the effective API model.
      overrides =
        Google.resolve_talk_overrides(%{
          "modelId" => "google/gemini-3.8-flash-lite-tts",
          "voiceId" => " Aoede "
        })

      assert overrides == %{model: "gemini-3.8-flash-lite-tts", voice_name: "Aoede"}
      text = "A Talk utterance."

      assert {:ok, nil} =
               Google.prepare_synthesis(%{
                 text: text,
                 provider_config: config,
                 provider_overrides: overrides
               })

      style =
        [oracle_config[:audio_profile], oracle_config[:persona_prompt]]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\n\n")

      metadata =
        %{"type" => "speech_metadata"}
        |> maybe_put("speaker", oracle_config[:speaker_name])
        |> maybe_put("style", if(style != "", do: style))

      block = %{"type" => "text", "text" => text}

      block =
        if map_size(metadata) > 1, do: Map.put(block, "annotations", [metadata]), else: block

      expected = interactions("gemini-3.8-flash-lite-tts", [block], [%{"voice" => "Aoede"}])

      synthesize_expected(
        %{text: text, target: :audio_file, timeout_ms: 12_345, provider_overrides: overrides},
        config,
        expected
      )
    end
  end

  test "generic telephony returns WAV while dedicated callback returns PCM24000" do
    for model <- ["gemini-3.1-flash-tts-preview", "gemini-3.8-flash-tts"] do
      fixture = Gaoxy.Test.open()
      on_exit(fn -> Gaoxy.Test.close(fixture) end)

      config =
        Google.resolve_config(%{
          "providers" => %{"google" => %{"apiKey" => "fixture", "model" => model}}
        })
        |> Map.put(:base_url, Gaoxy.Test.url(fixture, "/v1beta"))

      path =
        if model == "gemini-3.8-flash-tts",
          do: "/v1beta/interactions",
          else: "/v1beta/models/#{model}:generateContent"

      response =
        if model == "gemini-3.8-flash-tts",
          do: %{"output_audio" => %{"data" => "AAD/fwCA//8="}},
          else: %{
            "candidates" => [
              %{"content" => %{"parts" => [%{"inlineData" => %{"data" => "AAD/fwCA//8="}}]}}
            ]
          }

      Gaoxy.Test.stub(fixture, "POST", path, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(response))
      end)

      request = %{text: "Phone line.", target: :telephony, timeout_ms: 12_345}

      assert {:ok,
              %{audio: wav, output_format: "wav", file_extension: ".wav", voice_compatible: false}} =
               Google.synthesize(request, config)

      assert wav ==
               Base.decode64!(
                 "UklGRiwAAABXQVZFZm10IBAAAAABAAEAwF0AAIC7AAACABAAZGF0YQgAAAAAAP9/AID//w=="
               )

      assert {:ok,
              %{
                audio: <<0, 0, 255, 127, 0, 128, 255, 255>>,
                output_format: "pcm",
                sample_rate: 24_000
              }} = Google.synthesize_telephony(request, config)
    end
  end

  test "first nonempty audio wins across both API response aliases and candidate order" do
    for {model, response} <- [
          {"gemini-3.1-flash-tts-preview",
           %{
             "candidates" => [
               %{
                 "content" => %{
                   "parts" => [
                     %{"inlineData" => %{"data" => " "}},
                     %{"inline_data" => %{"data" => "-_8AAQ=="}},
                     %{"inlineData" => %{"data" => "AAD/fwCA//8="}}
                   ]
                 }
               }
             ]
           }},
          {"gemini-3.8-flash-tts",
           %{
             "output_audio" => %{"data" => "-_8AAQ=="},
             "steps" => [%{"content" => [%{"type" => "audio", "data" => "AAD/fwCA//8="}]}]
           }},
          {"gemini-3.8-flash-lite-tts",
           %{
             "steps" => [
               %{
                 "content" => [
                   %{"type" => "text", "data" => "ignored"},
                   %{"mimeType" => "audio/l16", "data" => "-_8AAQ=="},
                   %{"type" => "audio", "data" => "AAD/fwCA//8="}
                 ]
               }
             ]
           }}
        ] do
      fixture = Gaoxy.Test.open()
      on_exit(fn -> Gaoxy.Test.close(fixture) end)
      config = %{api_key: "fixture", model: model, base_url: Gaoxy.Test.url(fixture, "/v1beta")}

      path =
        if String.starts_with?(model, "gemini-3.8"),
          do: "/v1beta/interactions",
          else: "/v1beta/models/#{model}:generateContent"

      Gaoxy.Test.stub(fixture, "POST", path, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(response))
      end)

      assert {:ok, %{audio: <<251, 255, 0, 1>>, output_format: "pcm", sample_rate: 24_000}} =
               Google.synthesize_telephony(
                 %{text: "First audio", target: :telephony, timeout_ms: 12_345},
                 config
               )
    end
  end

  test "ordinary ProtoJSON padding, embedded whitespace and URL-safe spellings conserve independently known bytes" do
    for model <- ["gemini-3.1-flash-tts-preview", "gemini-3.8-flash-tts"],
        encoded <- ["+/8AAQ==", "+/8AAQ", " +/8 A A\tQ==\r\n", "-_8AAQ==", "-_8AAQ"] do
      fixture = Gaoxy.Test.open()
      on_exit(fn -> Gaoxy.Test.close(fixture) end)
      config = %{api_key: "fixture", model: model, base_url: Gaoxy.Test.url(fixture, "/v1beta")}

      path =
        if model == "gemini-3.8-flash-tts",
          do: "/v1beta/interactions",
          else: "/v1beta/models/#{model}:generateContent"

      response =
        if model == "gemini-3.8-flash-tts",
          do: %{"output_audio" => %{"data" => encoded}},
          else: %{
            "candidates" => [
              %{"content" => %{"parts" => [%{"inlineData" => %{"data" => encoded}}]}}
            ]
          }

      Gaoxy.Test.stub(fixture, "POST", path, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(response))
      end)

      assert {:ok, %{audio: <<251, 255, 0, 1>>, output_format: "pcm", sample_rate: 24_000}} =
               Google.synthesize_telephony(
                 %{text: "Known samples", target: :telephony, timeout_ms: 12_345},
                 config
               )
    end
  end

  test "nullish alias selection and custom model and voice remain source compatible" do
    assert Google.resolve_config(%{
             "providers" => %{
               "google" => %{"apiKey" => "fixture", "voiceName" => " ", "voice" => "Puck"}
             }
           }) == %{api_key: "fixture", model: "gemini-3.1-flash-tts-preview", voice_name: "Kore"}

    config =
      Google.resolve_config(%{
        "providers" => %{
          "google" => %{
            "apiKey" => "fixture",
            "model" => "fixture-future-tts",
            "voiceName" => "Custom Voice"
          }
        }
      })

    assert config == %{
             api_key: "fixture",
             model: "fixture-future-tts",
             voice_name: "Custom Voice"
           }

    synthesize_expected(
      %{text: "Custom voice.", target: :audio_file, timeout_ms: 12_345},
      config,
      generate("Custom voice.", "Custom Voice")
    )
  end

  test "template without persona profile follows the source recognizer on a second preparation" do
    row = Enum.find(@recipes["prepare"], &(&1["id"] == "prepare-template-only"))
    config = Google.resolve_config(row["input"]["rawConfig"])

    assert {:ok, first} =
             Google.prepare_synthesis(%{text: row["input"]["text"], provider_config: config})

    assert first == canonical(row["expected"])
    assert {:ok, second} = Google.prepare_synthesis(%{text: first.text, provider_config: config})

    prefix =
      "Synthesize speech from the TRANSCRIPT section only. Use the other sections only\nas performance direction. Do not read section titles, notes, labels, or\nconfiguration aloud.\n\n### TRANSCRIPT\n"

    assert second == %{text: prefix <> row["expected"]["text"]}
  end

  test "real Opus conversion uses source FFmpeg recipe and completes owned helper, Port and files" do
    Code.ensure_loaded!(Google.Opus)

    wav =
      <<"RIFF", 4_836::little-32, "WAVEfmt ", 16::little-32, 1::little-16, 1::little-16,
        24_000::little-32, 48_000::little-32, 2::little-16, 16::little-16, "data",
        4_800::little-32, tone()::binary>>

    flags = Process.info(self(), :trap_exit)
    ports_before = owned_ports()

    assert :erlang.trace_pattern({:erlang, :open_port, 2}, [{:_, [], [{:return_trace}]}], [:local]) ==
             1

    on_exit(fn -> :erlang.trace_pattern({:erlang, :open_port, 2}, false, [:local]) end)

    task =
      Task.async(fn ->
        receive do
          :convert ->
            Google.Opus.transcode(wav,
              timeout_ms: 30_000,
              deadline_ms: System.monotonic_time(:millisecond) + 30_000,
              max_bytes: 100_000
            )
        end
      end)

    supervisor = Process.whereis(Synapsis.Provider.TaskSupervisor)
    :erlang.trace(supervisor, true, [:call, :procs, :set_on_spawn, {:tracer, self()}])
    on_exit(fn -> :erlang.trace(supervisor, false, [:call, :procs, :set_on_spawn]) end)

    :erlang.trace(task.pid, true, [:call, :procs, :set_on_spawn, {:tracer, self()}])
    send(task.pid, :convert)
    assert {:ok, opus} = Task.await(task, 35_000)
    barrier = :erlang.trace_delivered(:all)
    assert_receive {:trace_delivered, :all, ^barrier}, 5_000
    traces = codec_traces([])

    assert [{owner, {:spawn_executable, executable}, settings}] =
             for(
               {:trace, pid, :call, {:erlang, :open_port, [name, settings]}} <- traces,
               do: {pid, name, settings}
             )

    assert Path.basename(to_string(executable)) == "ffmpeg"

    assert [
             "-hide_banner",
             "-loglevel",
             "error",
             "-y",
             "-i",
             input,
             "-vn",
             "-sn",
             "-dn",
             "-c:a",
             "libopus",
             "-b:a",
             "64k",
             "-ar",
             "48000",
             "-ac",
             "1",
             "-f",
             "opus",
             output
           ] = Enum.map(Keyword.fetch!(settings, :args), &to_string/1)

    assert Path.basename(input) == "input.wav"
    assert Path.basename(output) == "voice.opus"
    assert Path.dirname(input) == Path.dirname(output)
    refute File.exists?(Path.dirname(input))

    assert [port] =
             for(
               {:trace, ^owner, :return_from, {:erlang, :open_port, 2}, port} <- traces,
               do: port
             )

    assert Port.info(port) == nil
    refute Process.alive?(owner)
    assert Process.info(self(), :trap_exit) == flags
    assert owned_ports() == ports_before
    assert_opus(opus, "direct-owned-conversion")
  end

  defp codec_traces(acc) do
    receive do
      {:trace, _, _, _} = event -> codec_traces([event | acc])
      {:trace, _, _, _, _} = event -> codec_traces([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp synthesize_expected(request, config, body) do
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    model = Map.get(request[:provider_overrides] || %{}, :model, config.model)

    path =
      if model in ["gemini-3.8-flash-tts", "gemini-3.8-flash-lite-tts"],
        do: "/v1beta/interactions",
        else: "/v1beta/models/#{model}:generateContent"

    owner = self()

    Gaoxy.Test.stub(fixture, "POST", path, fn conn ->
      {:ok, bytes, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(bytes) == body
      send(owner, :prepared_synthesis_observed)

      response =
        if String.ends_with?(path, "/interactions"),
          do: %{"output_audio" => %{"data" => "AAD/fwCA//8="}},
          else: %{
            "candidates" => [
              %{"content" => %{"parts" => [%{"inline_data" => %{"data" => "AAD/fwCA//8="}}]}}
            ]
          }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(response))
    end)

    assert {:ok, result} =
             Google.synthesize(
               request,
               Map.put(config, :base_url, Gaoxy.Test.url(fixture, "/v1beta"))
             )

    assert result == %{
             audio:
               Base.decode64!(
                 "UklGRiwAAABXQVZFZm10IBAAAAABAAEAwF0AAIC7AAACABAAZGF0YQgAAAAAAP9/AID//w=="
               ),
             output_format: "wav",
             file_extension: ".wav",
             voice_compatible: false
           }

    assert_receive :prepared_synthesis_observed, 5_000
  end

  defp request(input),
    do: %{
      text: input["text"],
      target:
        %{"file" => :audio_file, "voice-note" => :voice_note, "telephony" => :telephony}[
          input["target"]
        ],
      timeout_ms: input["timeoutMs"],
      provider_overrides: canonical(input["providerOverrides"] || %{})
    }

  defp expected_result(raw),
    do:
      raw
      |> Map.delete("audioBase64")
      |> canonical()
      |> Map.put(:audio, Base.decode64!(raw["audioBase64"]))

  defp canonical(raw) when is_map(raw),
    do: Map.new(raw, fn {key, value} -> {field(key), canonical(value)} end)

  defp canonical(raw) when is_list(raw), do: Enum.map(raw, &canonical/1)
  defp canonical(raw), do: raw

  defp field(key),
    do:
      %{
        "apiKey" => :api_key,
        "baseUrl" => :base_url,
        "voiceName" => :voice_name,
        "audioProfile" => :audio_profile,
        "speakerName" => :speaker_name,
        "promptTemplate" => :prompt_template,
        "personaPrompt" => :persona_prompt,
        "autoSelectOrder" => :auto_select_order,
        "defaultModel" => :default_model,
        "outputFormat" => :output_format,
        "fileExtension" => :file_extension,
        "voiceCompatible" => :voice_compatible,
        "sampleRate" => :sample_rate
      }[key] || String.to_existing_atom(key)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp generate(text, voice),
    do: %{
      "contents" => [%{"role" => "user", "parts" => [%{"text" => text}]}],
      "generationConfig" => %{
        "responseModalities" => ["AUDIO"],
        "speechConfig" => %{"voiceConfig" => %{"prebuiltVoiceConfig" => %{"voiceName" => voice}}}
      }
    }

  defp interactions(model, blocks, speech),
    do: %{
      "model" => model,
      "store" => false,
      "input" => [%{"type" => "user_input", "content" => blocks}],
      "response_format" => %{
        "type" => "audio",
        "mime_type" => "audio/l16",
        "sample_rate" => 24_000
      },
      "generation_config" => %{"speech_config" => speech}
    }

  defp owned_ports do
    :erlang.ports()
    |> Enum.filter(&(Port.info(&1, :connected) == {:connected, self()}))
    |> MapSet.new()
  end

  defp tone do
    for n <- 0..2_399,
        into: <<>>,
        do: <<round(12_000 * :math.sin(2 * :math.pi() * 440 * n / 24_000))::little-signed-16>>
  end

  defp tone_response(url) do
    data = Base.encode64(tone())

    if String.ends_with?(url, "/interactions"),
      do: %{"output_audio" => %{"data" => data}},
      else: %{
        "candidates" => [%{"content" => %{"parts" => [%{"inlineData" => %{"data" => data}}]}}]
      }
  end

  defp assert_opus(bytes, label) do
    assert <<"OggS", _::binary>> = bytes
    assert :binary.match(bytes, "OpusHead") != :nomatch
    root = "/tmp/synapsis-google334-evidence/opus-#{label}-#{System.unique_integer([:positive])}"
    File.mkdir_p!(root)
    path = Path.join(root, "voice.opus")

    try do
      File.write!(path, bytes)

      probe =
        executable!("ffprobe")
        |> port_output([
          "-v",
          "error",
          "-show_entries",
          "stream=codec_name,sample_rate,channels",
          "-of",
          "json",
          path
        ])
        |> Jason.decode!()

      assert [stream] = probe["streams"]

      assert Map.take(stream, ~w(codec_name sample_rate channels)) == %{
               "codec_name" => "opus",
               "sample_rate" => "48000",
               "channels" => 1
             }

      decoded =
        executable!("ffmpeg")
        |> port_output([
          "-v",
          "error",
          "-i",
          path,
          "-f",
          "s16le",
          "-ac",
          "1",
          "-ar",
          "48000",
          "pipe:1"
        ])

      assert byte_size(decoded) in 9_000..10_600
      samples = for <<sample::little-signed-16 <- decoded>>, do: abs(sample)
      assert Enum.max(samples) > 5_000

      File.write!(
        "/tmp/synapsis-google334-evidence/#{label}-codec.json",
        Jason.encode!(
          %{
            probe: probe,
            decoded_bytes: byte_size(decoded),
            sha256: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
          },
          pretty: true
        )
      )
    after
      File.rm_rf!(root)
    end
  end

  defp executable!(name),
    do:
      System.find_executable(name) ||
        flunk("BLOCKED_ENV: #{name} is required for real ordinary Opus evidence")

  defp port_output(executable, args) do
    port =
      Port.open({:spawn_executable, executable}, [:binary, :exit_status, :use_stdio, args: args])

    deadline = System.monotonic_time(:millisecond) + 15_000

    try do
      collect_port(port, deadline, [])
    after
      if Port.info(port), do: Port.close(port)
    end
  end

  defp collect_port(port, deadline, parts) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} -> collect_port(port, deadline, [data | parts])
      {^port, {:exit_status, 0}} -> IO.iodata_to_binary(Enum.reverse(parts))
      {^port, {:exit_status, status}} -> flunk("ordinary codec process exited #{status}")
    after
      remaining -> flunk("ordinary codec process did not finish")
    end
  end
end

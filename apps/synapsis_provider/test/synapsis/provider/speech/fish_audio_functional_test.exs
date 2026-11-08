defmodule Synapsis.Provider.Speech.FishAudioFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Provider.Speech.FishAudio
  alias Synapsis.Provider.Speech.FishAudio.Stream

  @audio <<82, 73, 70, 70, 0, 1, 2, 255>>
  @models ~w(drama-3 drama-3-preview s2.1-pro-free s2.1-pro s2-pro s1)
  # Frozen before implementation. Inputs and expectations are the independently
  # authored source oracle at 488631c18fae7cc541ba8fc8beff6cbb0438787b,
  # not output inferred from a capture fixture or the host implementation.
  # Source auth discovery, directives, byte limits and non-normal paths are unqualified.
  @recipes Jason.decode!(~S"""
           {
             "config": [
               {"input":{"id":"config-defaults","input":{"rawConfig":{"providers":{"fish-audio":{"apiKey":"fixture-fish-speech"}}}}},"expected":{"id":"config-defaults","result":{"apiKey":"fixture-fish-speech","baseUrl":"https://api.fish.audio","model":"s2.1-pro","latency":"balanced"}}},
               {"input":{"id":"config-model-drama-3","input":{"rawConfig":{"providers":{"fish-audio":{"apiKey":"fixture-fish-speech","model":" drama-3 "}}}}},"expected":{"id":"config-model-drama-3","result":{"apiKey":"fixture-fish-speech","baseUrl":"https://api.fish.audio","model":"drama-3","latency":"balanced"}}},
               {"input":{"id":"config-model-drama-3-preview","input":{"rawConfig":{"providers":{"fish-audio":{"apiKey":"fixture-fish-speech","model":" drama-3-preview "}}}}},"expected":{"id":"config-model-drama-3-preview","result":{"apiKey":"fixture-fish-speech","baseUrl":"https://api.fish.audio","model":"drama-3-preview","latency":"balanced"}}},
               {"input":{"id":"config-model-s2.1-pro-free","input":{"rawConfig":{"providers":{"fish-audio":{"apiKey":"fixture-fish-speech","model":" s2.1-pro-free "}}}}},"expected":{"id":"config-model-s2.1-pro-free","result":{"apiKey":"fixture-fish-speech","baseUrl":"https://api.fish.audio","model":"s2.1-pro-free","latency":"balanced"}}},
               {"input":{"id":"config-model-s2.1-pro","input":{"rawConfig":{"providers":{"fish-audio":{"apiKey":"fixture-fish-speech","model":" s2.1-pro "}}}}},"expected":{"id":"config-model-s2.1-pro","result":{"apiKey":"fixture-fish-speech","baseUrl":"https://api.fish.audio","model":"s2.1-pro","latency":"balanced"}}},
               {"input":{"id":"config-model-s2-pro","input":{"rawConfig":{"providers":{"fish-audio":{"apiKey":"fixture-fish-speech","model":" s2-pro "}}}}},"expected":{"id":"config-model-s2-pro","result":{"apiKey":"fixture-fish-speech","baseUrl":"https://api.fish.audio","model":"s2-pro","latency":"balanced"}}},
               {"input":{"id":"config-model-s1","input":{"rawConfig":{"providers":{"fish-audio":{"apiKey":"fixture-fish-speech","model":" s1 "}}}}},"expected":{"id":"config-model-s1","result":{"apiKey":"fixture-fish-speech","baseUrl":"https://api.fish.audio","model":"s1","latency":"balanced"}}},
               {"input":{"id":"config-rich-precedence","input":{"rawConfig":{"providers":{"fish-audio":{"apiKey":"fixture-fish-speech","baseUrl":" https://fish.example/custom/v2/// ","model":" drama-3 ","speakerVoiceId":" primary-voice ","voiceId":"secondary-voice","referenceId":"third-voice","latency":" LOW ","speed":1.2,"temperature":0.7,"topP":0.6,"top_p":0.4,"normalize":false}}}}},"expected":{"id":"config-rich-precedence","result":{"apiKey":"fixture-fish-speech","baseUrl":"https://fish.example/custom/v2","model":"drama-3","latency":"low","referenceId":"primary-voice","speed":1.2,"temperature":0.7,"topP":0.6,"normalize":false}}},
               {"input":{"id":"config-modelid-voiceid","input":{"rawConfig":{"providers":{"fish-audio":{"apiKey":"fixture-fish-speech","modelId":" s2-pro ","voiceId":" voice-id ","top_p":0.3,"normalize":true}}}}},"expected":{"id":"config-modelid-voiceid","result":{"apiKey":"fixture-fish-speech","baseUrl":"https://api.fish.audio","model":"s2-pro","latency":"balanced","referenceId":"voice-id","topP":0.3,"normalize":true}}},
               {"input":{"id":"config-reference-alias","input":{"rawConfig":{"providers":{"fish-audio":{"apiKey":"fixture-fish-speech","referenceId":" reference-only ","latency":" NORMAL "}}}}},"expected":{"id":"config-reference-alias","result":{"apiKey":"fixture-fish-speech","baseUrl":"https://api.fish.audio","model":"s2.1-pro","latency":"normal","referenceId":"reference-only"}}},
               {"input":{"id":"config-model-first","input":{"rawConfig":{"providers":{"fish-audio":{"apiKey":"fixture-fish-speech","model":"s1","modelId":"drama-3-preview"}}}}},"expected":{"id":"config-model-first","result":{"apiKey":"fixture-fish-speech","baseUrl":"https://api.fish.audio","model":"s1","latency":"balanced"}}},
               {"input":{"id":"config-unicode-trim","input":{"rawConfig":{"providers":{"fish-audio":{"apiKey":"fixture-fish-speech","baseUrl":" ﻿https://fish.example/voice///﻿ ","model":" ﻿s2.1-pro-free﻿ ","voiceId":" ﻿Voice-声音﻿ "}}}}},"expected":{"id":"config-unicode-trim","result":{"apiKey":"fixture-fish-speech","baseUrl":"https://fish.example/voice","model":"s2.1-pro-free","latency":"balanced","referenceId":"Voice-声音"}}}
             ],
             "talkConfig": [
               {"input":{"id":"talk-defaults","input":{"baseTtsConfig":{"providers":{"fish-audio":{"apiKey":"fixture-fish-speech"}}},"talkProviderConfig":{}}},"expected":{"id":"talk-defaults","result":{"apiKey":"fixture-fish-speech","baseUrl":"https://api.fish.audio","model":"s2.1-pro","latency":"balanced"}}},
               {"input":{"id":"talk-rich-overlay","input":{"baseTtsConfig":{"providers":{"fish-audio":{"apiKey":"fixture-fish-speech","baseUrl":" https://fish.example/custom/v2/// ","model":" drama-3 ","speakerVoiceId":" primary-voice ","voiceId":"secondary-voice","referenceId":"third-voice","latency":" LOW ","speed":1.2,"temperature":0.7,"topP":0.6,"top_p":0.4,"normalize":false}}},"talkProviderConfig":{"apiKey":" fixture-fish-talk ","baseUrl":" https://talk.example/fish/// ","modelId":" s1 ","model":"drama-3-preview","speakerVoiceId":" talk-speaker ","voiceId":"talk-second","referenceId":"talk-third","latency":" NORMAL ","speed":1.4}}},"expected":{"id":"talk-rich-overlay","result":{"apiKey":"fixture-fish-talk","baseUrl":"https://talk.example/fish","model":"s1","latency":"normal","referenceId":"talk-speaker","speed":1.4,"temperature":0.7,"topP":0.6,"normalize":false}}},
               {"input":{"id":"talk-retains-base-options","input":{"baseTtsConfig":{"providers":{"fish-audio":{"apiKey":"fixture-fish-speech","baseUrl":" https://fish.example/custom/v2/// ","model":" drama-3 ","speakerVoiceId":" primary-voice ","voiceId":"secondary-voice","referenceId":"third-voice","latency":" LOW ","speed":1.2,"temperature":0.7,"topP":0.6,"top_p":0.4,"normalize":false}}},"talkProviderConfig":{"model":"s2-pro","voiceId":" next-voice "}}},"expected":{"id":"talk-retains-base-options","result":{"apiKey":"fixture-fish-speech","baseUrl":"https://fish.example/custom/v2","model":"s2-pro","latency":"low","referenceId":"next-voice","speed":1.2,"temperature":0.7,"topP":0.6,"normalize":false}}},
               {"input":{"id":"talk-reference-model-alias","input":{"baseTtsConfig":{"providers":{"fish-audio":{"apiKey":"fixture-fish-speech"}}},"talkProviderConfig":{"model":"drama-3-preview","referenceId":"talk-ref","speed":1.1}}},"expected":{"id":"talk-reference-model-alias","result":{"apiKey":"fixture-fish-speech","baseUrl":"https://api.fish.audio","model":"drama-3-preview","latency":"balanced","referenceId":"talk-ref","speed":1.1}}},
               {"input":{"id":"talk-explicit-base-key","input":{"baseTtsConfig":{"providers":{"fish-audio":{"apiKey":"fixture-fish-speech","baseUrl":" https://fish.example/custom/v2/// ","model":" drama-3 ","speakerVoiceId":" primary-voice ","voiceId":"secondary-voice","referenceId":"third-voice","latency":" LOW ","speed":1.2,"temperature":0.7,"topP":0.6,"top_p":0.4,"normalize":false}}},"talkProviderConfig":{"apiKey":"fixture-fish-speech","baseUrl":"https://api.fish.audio"}}},"expected":{"id":"talk-explicit-base-key","result":{"apiKey":"fixture-fish-speech","baseUrl":"https://api.fish.audio","model":"drama-3","latency":"low","referenceId":"primary-voice","speed":1.2,"temperature":0.7,"topP":0.6,"normalize":false}}}
             ],
             "talkOverride": [
               {"input":{"id":"override-empty","input":{"params":{}}},"expected":{"id":"override-empty","result":{}}},
               {"input":{"id":"override-modelid-first","input":{"params":{"modelId":" drama-3 ","model":"s1","speakerVoiceId":" primary ","voiceId":"second","referenceId":"third","speed":1.25}}},"expected":{"id":"override-modelid-first","result":{"model":"drama-3","referenceId":"primary","speed":1.25}}},
               {"input":{"id":"override-model-voice","input":{"params":{"model":"s2.1-pro-free","voiceId":" voice "}}},"expected":{"id":"override-model-voice","result":{"model":"s2.1-pro-free","referenceId":"voice"}}},
               {"input":{"id":"override-reference","input":{"params":{"referenceId":" ref ","speed":1.3}}},"expected":{"id":"override-reference","result":{"referenceId":"ref","speed":1.3}}},
               {"input":{"id":"override-talk-keeps-only-surface","input":{"params":{"model":"s2-pro","temperature":0.5,"topP":0.4,"latency":"low","normalize":true}}},"expected":{"id":"override-talk-keeps-only-surface","result":{"model":"s2-pro"}}}
             ],
             "synthesis": [
               {"input":{"id":"drama-3-audio-file","input":{"rawConfig":{"providers":{"fish-audio":{"apiKey":"fixture-fish-speech","model":"drama-3"}}},"cfg":{},"text":"Ordinary Fish speech.","target":"audio-file","timeoutMs":12345,"providerOverrides":{}},"response":{"audioBase64":"UklGRgABAv8="}},"expected":{"id":"drama-3-audio-file","resolvedConfig":{"apiKey":"fixture-fish-speech","baseUrl":"https://api.fish.audio","model":"drama-3","latency":"balanced"},"request":{"url":"https://api.fish.audio/v1/tts","modelHeader":"drama-3","body":{"text":"Ordinary Fish speech.","format":"mp3","sample_rate":44100,"latency":"balanced"},"timeoutMs":12345},"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"mp3","fileExtension":".mp3","voiceCompatible":false}}},
               {"input":{"id":"drama-3-voice-note","input":{"rawConfig":{"providers":{"fish-audio":{"apiKey":"fixture-fish-speech","model":"drama-3"}}},"cfg":{},"text":"Ordinary Fish speech.","target":"voice-note","timeoutMs":12345,"providerOverrides":{}},"response":{"audioBase64":"UklGRgABAv8="}},"expected":{"id":"drama-3-voice-note","resolvedConfig":{"apiKey":"fixture-fish-speech","baseUrl":"https://api.fish.audio","model":"drama-3","latency":"balanced"},"request":{"url":"https://api.fish.audio/v1/tts","modelHeader":"drama-3","body":{"text":"Ordinary Fish speech.","format":"opus","sample_rate":48000,"latency":"balanced"},"timeoutMs":12345},"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"opus","fileExtension":".opus","voiceCompatible":true}}},
               {"input":{"id":"drama-3-preview-audio-file","input":{"rawConfig":{"providers":{"fish-audio":{"apiKey":"fixture-fish-speech","model":"drama-3-preview"}}},"cfg":{},"text":"Ordinary Fish speech.","target":"audio-file","timeoutMs":12345,"providerOverrides":{}},"response":{"audioBase64":"UklGRgABAv8="}},"expected":{"id":"drama-3-preview-audio-file","resolvedConfig":{"apiKey":"fixture-fish-speech","baseUrl":"https://api.fish.audio","model":"drama-3-preview","latency":"balanced"},"request":{"url":"https://api.fish.audio/v1/tts","modelHeader":"drama-3-preview","body":{"text":"Ordinary Fish speech.","format":"mp3","sample_rate":44100,"latency":"balanced"},"timeoutMs":12345},"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"mp3","fileExtension":".mp3","voiceCompatible":false}}},
               {"input":{"id":"drama-3-preview-voice-note","input":{"rawConfig":{"providers":{"fish-audio":{"apiKey":"fixture-fish-speech","model":"drama-3-preview"}}},"cfg":{},"text":"Ordinary Fish speech.","target":"voice-note","timeoutMs":12345,"providerOverrides":{}},"response":{"audioBase64":"UklGRgABAv8="}},"expected":{"id":"drama-3-preview-voice-note","resolvedConfig":{"apiKey":"fixture-fish-speech","baseUrl":"https://api.fish.audio","model":"drama-3-preview","latency":"balanced"},"request":{"url":"https://api.fish.audio/v1/tts","modelHeader":"drama-3-preview","body":{"text":"Ordinary Fish speech.","format":"opus","sample_rate":48000,"latency":"balanced"},"timeoutMs":12345},"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"opus","fileExtension":".opus","voiceCompatible":true}}},
               {"input":{"id":"s2.1-pro-free-audio-file","input":{"rawConfig":{"providers":{"fish-audio":{"apiKey":"fixture-fish-speech","model":"s2.1-pro-free"}}},"cfg":{},"text":"Ordinary Fish speech.","target":"audio-file","timeoutMs":12345,"providerOverrides":{}},"response":{"audioBase64":"UklGRgABAv8="}},"expected":{"id":"s2.1-pro-free-audio-file","resolvedConfig":{"apiKey":"fixture-fish-speech","baseUrl":"https://api.fish.audio","model":"s2.1-pro-free","latency":"balanced"},"request":{"url":"https://api.fish.audio/v1/tts","modelHeader":"s2.1-pro-free","body":{"text":"Ordinary Fish speech.","format":"mp3","sample_rate":44100,"latency":"balanced"},"timeoutMs":12345},"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"mp3","fileExtension":".mp3","voiceCompatible":false}}},
               {"input":{"id":"s2.1-pro-free-voice-note","input":{"rawConfig":{"providers":{"fish-audio":{"apiKey":"fixture-fish-speech","model":"s2.1-pro-free"}}},"cfg":{},"text":"Ordinary Fish speech.","target":"voice-note","timeoutMs":12345,"providerOverrides":{}},"response":{"audioBase64":"UklGRgABAv8="}},"expected":{"id":"s2.1-pro-free-voice-note","resolvedConfig":{"apiKey":"fixture-fish-speech","baseUrl":"https://api.fish.audio","model":"s2.1-pro-free","latency":"balanced"},"request":{"url":"https://api.fish.audio/v1/tts","modelHeader":"s2.1-pro-free","body":{"text":"Ordinary Fish speech.","format":"opus","sample_rate":48000,"latency":"balanced"},"timeoutMs":12345},"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"opus","fileExtension":".opus","voiceCompatible":true}}},
               {"input":{"id":"s2.1-pro-audio-file","input":{"rawConfig":{"providers":{"fish-audio":{"apiKey":"fixture-fish-speech","model":"s2.1-pro"}}},"cfg":{},"text":"Ordinary Fish speech.","target":"audio-file","timeoutMs":12345,"providerOverrides":{}},"response":{"audioBase64":"UklGRgABAv8="}},"expected":{"id":"s2.1-pro-audio-file","resolvedConfig":{"apiKey":"fixture-fish-speech","baseUrl":"https://api.fish.audio","model":"s2.1-pro","latency":"balanced"},"request":{"url":"https://api.fish.audio/v1/tts","modelHeader":"s2.1-pro","body":{"text":"Ordinary Fish speech.","format":"mp3","sample_rate":44100,"latency":"balanced"},"timeoutMs":12345},"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"mp3","fileExtension":".mp3","voiceCompatible":false}}},
               {"input":{"id":"s2.1-pro-voice-note","input":{"rawConfig":{"providers":{"fish-audio":{"apiKey":"fixture-fish-speech","model":"s2.1-pro"}}},"cfg":{},"text":"Ordinary Fish speech.","target":"voice-note","timeoutMs":12345,"providerOverrides":{}},"response":{"audioBase64":"UklGRgABAv8="}},"expected":{"id":"s2.1-pro-voice-note","resolvedConfig":{"apiKey":"fixture-fish-speech","baseUrl":"https://api.fish.audio","model":"s2.1-pro","latency":"balanced"},"request":{"url":"https://api.fish.audio/v1/tts","modelHeader":"s2.1-pro","body":{"text":"Ordinary Fish speech.","format":"opus","sample_rate":48000,"latency":"balanced"},"timeoutMs":12345},"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"opus","fileExtension":".opus","voiceCompatible":true}}},
               {"input":{"id":"s2-pro-audio-file","input":{"rawConfig":{"providers":{"fish-audio":{"apiKey":"fixture-fish-speech","model":"s2-pro"}}},"cfg":{},"text":"Ordinary Fish speech.","target":"audio-file","timeoutMs":12345,"providerOverrides":{}},"response":{"audioBase64":"UklGRgABAv8="}},"expected":{"id":"s2-pro-audio-file","resolvedConfig":{"apiKey":"fixture-fish-speech","baseUrl":"https://api.fish.audio","model":"s2-pro","latency":"balanced"},"request":{"url":"https://api.fish.audio/v1/tts","modelHeader":"s2-pro","body":{"text":"Ordinary Fish speech.","format":"mp3","sample_rate":44100,"latency":"balanced"},"timeoutMs":12345},"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"mp3","fileExtension":".mp3","voiceCompatible":false}}},
               {"input":{"id":"s2-pro-voice-note","input":{"rawConfig":{"providers":{"fish-audio":{"apiKey":"fixture-fish-speech","model":"s2-pro"}}},"cfg":{},"text":"Ordinary Fish speech.","target":"voice-note","timeoutMs":12345,"providerOverrides":{}},"response":{"audioBase64":"UklGRgABAv8="}},"expected":{"id":"s2-pro-voice-note","resolvedConfig":{"apiKey":"fixture-fish-speech","baseUrl":"https://api.fish.audio","model":"s2-pro","latency":"balanced"},"request":{"url":"https://api.fish.audio/v1/tts","modelHeader":"s2-pro","body":{"text":"Ordinary Fish speech.","format":"opus","sample_rate":48000,"latency":"balanced"},"timeoutMs":12345},"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"opus","fileExtension":".opus","voiceCompatible":true}}},
               {"input":{"id":"s1-audio-file","input":{"rawConfig":{"providers":{"fish-audio":{"apiKey":"fixture-fish-speech","model":"s1"}}},"cfg":{},"text":"Ordinary Fish speech.","target":"audio-file","timeoutMs":12345,"providerOverrides":{}},"response":{"audioBase64":"UklGRgABAv8="}},"expected":{"id":"s1-audio-file","resolvedConfig":{"apiKey":"fixture-fish-speech","baseUrl":"https://api.fish.audio","model":"s1","latency":"balanced"},"request":{"url":"https://api.fish.audio/v1/tts","modelHeader":"s1","body":{"text":"Ordinary Fish speech.","format":"mp3","sample_rate":44100,"latency":"balanced"},"timeoutMs":12345},"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"mp3","fileExtension":".mp3","voiceCompatible":false}}},
               {"input":{"id":"s1-voice-note","input":{"rawConfig":{"providers":{"fish-audio":{"apiKey":"fixture-fish-speech","model":"s1"}}},"cfg":{},"text":"Ordinary Fish speech.","target":"voice-note","timeoutMs":12345,"providerOverrides":{}},"response":{"audioBase64":"UklGRgABAv8="}},"expected":{"id":"s1-voice-note","resolvedConfig":{"apiKey":"fixture-fish-speech","baseUrl":"https://api.fish.audio","model":"s1","latency":"balanced"},"request":{"url":"https://api.fish.audio/v1/tts","modelHeader":"s1","body":{"text":"Ordinary Fish speech.","format":"opus","sample_rate":48000,"latency":"balanced"},"timeoutMs":12345},"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"opus","fileExtension":".opus","voiceCompatible":true}}},
               {"input":{"id":"rich-config-file","input":{"rawConfig":{"providers":{"fish-audio":{"apiKey":"fixture-fish-speech","baseUrl":" https://fish.example/custom/v2/// ","model":" drama-3 ","speakerVoiceId":" primary-voice ","voiceId":"secondary-voice","referenceId":"third-voice","latency":" LOW ","speed":1.2,"temperature":0.7,"topP":0.6,"top_p":0.4,"normalize":false}}},"cfg":{},"text":"Ordinary Fish speech.","target":"audio-file","timeoutMs":12345,"providerOverrides":{}},"response":{"audioBase64":"UklGRgABAv8="}},"expected":{"id":"rich-config-file","resolvedConfig":{"apiKey":"fixture-fish-speech","baseUrl":"https://fish.example/custom/v2","model":"drama-3","latency":"low","referenceId":"primary-voice","speed":1.2,"temperature":0.7,"topP":0.6,"normalize":false},"request":{"url":"https://fish.example/custom/v2/v1/tts","modelHeader":"drama-3","body":{"text":"Ordinary Fish speech.","format":"mp3","sample_rate":44100,"latency":"low","reference_id":"primary-voice","prosody":{"speed":1.2},"temperature":0.7,"top_p":0.6,"normalize":false},"timeoutMs":12345},"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"mp3","fileExtension":".mp3","voiceCompatible":false}}},
               {"input":{"id":"rich-config-note","input":{"rawConfig":{"providers":{"fish-audio":{"apiKey":"fixture-fish-speech","baseUrl":" https://fish.example/custom/v2/// ","model":" drama-3 ","speakerVoiceId":" primary-voice ","voiceId":"secondary-voice","referenceId":"third-voice","latency":" LOW ","speed":1.2,"temperature":0.7,"topP":0.6,"top_p":0.4,"normalize":false}}},"cfg":{},"text":"Ordinary Fish speech.","target":"voice-note","timeoutMs":12345,"providerOverrides":{}},"response":{"audioBase64":"UklGRgABAv8="}},"expected":{"id":"rich-config-note","resolvedConfig":{"apiKey":"fixture-fish-speech","baseUrl":"https://fish.example/custom/v2","model":"drama-3","latency":"low","referenceId":"primary-voice","speed":1.2,"temperature":0.7,"topP":0.6,"normalize":false},"request":{"url":"https://fish.example/custom/v2/v1/tts","modelHeader":"drama-3","body":{"text":"Ordinary Fish speech.","format":"opus","sample_rate":48000,"latency":"low","reference_id":"primary-voice","prosody":{"speed":1.2},"temperature":0.7,"top_p":0.6,"normalize":false},"timeoutMs":12345},"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"opus","fileExtension":".opus","voiceCompatible":true}}},
               {"input":{"id":"rich-override-model-first","input":{"rawConfig":{"providers":{"fish-audio":{"apiKey":"fixture-fish-speech","baseUrl":" https://fish.example/custom/v2/// ","model":" drama-3 ","speakerVoiceId":" primary-voice ","voiceId":"secondary-voice","referenceId":"third-voice","latency":" LOW ","speed":1.2,"temperature":0.7,"topP":0.6,"top_p":0.4,"normalize":false}}},"cfg":{},"text":"Ordinary Fish speech.","target":"audio-file","timeoutMs":12345,"providerOverrides":{"model":" s1 ","modelId":"drama-3","speakerVoiceId":" override-primary ","voiceId":"override-second","referenceId":"override-third","latency":" NORMAL ","speed":1.5,"temperature":0.45,"topP":0.35,"top_p":0.65,"normalize":true}},"response":{"audioBase64":"UklGRgABAv8="}},"expected":{"id":"rich-override-model-first","resolvedConfig":{"apiKey":"fixture-fish-speech","baseUrl":"https://fish.example/custom/v2","model":"drama-3","latency":"low","referenceId":"primary-voice","speed":1.2,"temperature":0.7,"topP":0.6,"normalize":false},"request":{"url":"https://fish.example/custom/v2/v1/tts","modelHeader":"s1","body":{"text":"Ordinary Fish speech.","format":"mp3","sample_rate":44100,"latency":"normal","reference_id":"override-primary","prosody":{"speed":1.5},"temperature":0.45,"top_p":0.35,"normalize":true},"timeoutMs":12345},"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"mp3","fileExtension":".mp3","voiceCompatible":false}}},
               {"input":{"id":"override-modelid-voiceid","input":{"rawConfig":{"providers":{"fish-audio":{"apiKey":"fixture-fish-speech"}}},"cfg":{},"text":"Ordinary Fish speech.","target":"audio-file","timeoutMs":12345,"providerOverrides":{"modelId":"drama-3-preview","voiceId":" override-voice ","top_p":0.55}},"response":{"audioBase64":"UklGRgABAv8="}},"expected":{"id":"override-modelid-voiceid","resolvedConfig":{"apiKey":"fixture-fish-speech","baseUrl":"https://api.fish.audio","model":"s2.1-pro","latency":"balanced"},"request":{"url":"https://api.fish.audio/v1/tts","modelHeader":"drama-3-preview","body":{"text":"Ordinary Fish speech.","format":"mp3","sample_rate":44100,"latency":"balanced","reference_id":"override-voice","top_p":0.55},"timeoutMs":12345},"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"mp3","fileExtension":".mp3","voiceCompatible":false}}},
               {"input":{"id":"override-reference-only","input":{"rawConfig":{"providers":{"fish-audio":{"apiKey":"fixture-fish-speech"}}},"cfg":{},"text":"Ordinary Fish speech.","target":"audio-file","timeoutMs":12345,"providerOverrides":{"referenceId":" reference-only "}},"response":{"audioBase64":"UklGRgABAv8="}},"expected":{"id":"override-reference-only","resolvedConfig":{"apiKey":"fixture-fish-speech","baseUrl":"https://api.fish.audio","model":"s2.1-pro","latency":"balanced"},"request":{"url":"https://api.fish.audio/v1/tts","modelHeader":"s2.1-pro","body":{"text":"Ordinary Fish speech.","format":"mp3","sample_rate":44100,"latency":"balanced","reference_id":"reference-only"},"timeoutMs":12345},"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"mp3","fileExtension":".mp3","voiceCompatible":false}}},
               {"input":{"id":"exact-text","input":{"rawConfig":{"providers":{"fish-audio":{"apiKey":"fixture-fish-speech"}}},"cfg":{},"text":"  Fish 🐟\n语音 é\tverbatim  ","target":"audio-file","timeoutMs":12345,"providerOverrides":{}},"response":{"audioBase64":"UklGRgABAv8="}},"expected":{"id":"exact-text","resolvedConfig":{"apiKey":"fixture-fish-speech","baseUrl":"https://api.fish.audio","model":"s2.1-pro","latency":"balanced"},"request":{"url":"https://api.fish.audio/v1/tts","modelHeader":"s2.1-pro","body":{"text":"  Fish 🐟\n语音 é\tverbatim  ","format":"mp3","sample_rate":44100,"latency":"balanced"},"timeoutMs":12345},"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"mp3","fileExtension":".mp3","voiceCompatible":false}}},
               {"input":{"id":"configured-modelid-top-p","input":{"rawConfig":{"providers":{"fish-audio":{"apiKey":"fixture-fish-speech","modelId":"s2-pro","top_p":0.25,"normalize":true}}},"cfg":{},"text":"Ordinary Fish speech.","target":"audio-file","timeoutMs":12345,"providerOverrides":{}},"response":{"audioBase64":"UklGRgABAv8="}},"expected":{"id":"configured-modelid-top-p","resolvedConfig":{"apiKey":"fixture-fish-speech","baseUrl":"https://api.fish.audio","model":"s2-pro","latency":"balanced","topP":0.25,"normalize":true},"request":{"url":"https://api.fish.audio/v1/tts","modelHeader":"s2-pro","body":{"text":"Ordinary Fish speech.","format":"mp3","sample_rate":44100,"latency":"balanced","top_p":0.25,"normalize":true},"timeoutMs":12345},"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"mp3","fileExtension":".mp3","voiceCompatible":false}}},
               {"input":{"id":"explicit-45s","input":{"rawConfig":{"providers":{"fish-audio":{"apiKey":"fixture-fish-speech"}}},"cfg":{},"text":"Ordinary Fish speech.","target":"audio-file","timeoutMs":45000,"providerOverrides":{}},"response":{"audioBase64":"UklGRgABAv8="}},"expected":{"id":"explicit-45s","resolvedConfig":{"apiKey":"fixture-fish-speech","baseUrl":"https://api.fish.audio","model":"s2.1-pro","latency":"balanced"},"request":{"url":"https://api.fish.audio/v1/tts","modelHeader":"s2.1-pro","body":{"text":"Ordinary Fish speech.","format":"mp3","sample_rate":44100,"latency":"balanced"},"timeoutMs":45000},"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"mp3","fileExtension":".mp3","voiceCompatible":false}}},
               {"input":{"id":"explicit-75s","input":{"rawConfig":{"providers":{"fish-audio":{"apiKey":"fixture-fish-speech"}}},"cfg":{},"text":"Ordinary Fish speech.","target":"audio-file","timeoutMs":75000,"providerOverrides":{}},"response":{"audioBase64":"UklGRgABAv8="}},"expected":{"id":"explicit-75s","resolvedConfig":{"apiKey":"fixture-fish-speech","baseUrl":"https://api.fish.audio","model":"s2.1-pro","latency":"balanced"},"request":{"url":"https://api.fish.audio/v1/tts","modelHeader":"s2.1-pro","body":{"text":"Ordinary Fish speech.","format":"mp3","sample_rate":44100,"latency":"balanced"},"timeoutMs":75000},"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"mp3","fileExtension":".mp3","voiceCompatible":false}}},
               {"input":{"id":"buffered-telephony-target","input":{"rawConfig":{"providers":{"fish-audio":{"apiKey":"fixture-fish-speech"}}},"cfg":{},"text":"Ordinary Fish speech.","target":"telephony","timeoutMs":12345,"providerOverrides":{}},"response":{"audioBase64":"UklGRgABAv8="}},"expected":{"id":"buffered-telephony-target","resolvedConfig":{"apiKey":"fixture-fish-speech","baseUrl":"https://api.fish.audio","model":"s2.1-pro","latency":"balanced"},"request":{"url":"https://api.fish.audio/v1/tts","modelHeader":"s2.1-pro","body":{"text":"Ordinary Fish speech.","format":"pcm","sample_rate":8000,"latency":"balanced"},"timeoutMs":12345},"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"pcm","fileExtension":".pcm","voiceCompatible":false}}}
             ],
             "stream": [
               {"input":{"id":"stream-file","input":{"rawConfig":{"providers":{"fish-audio":{"apiKey":"fixture-fish-speech"}}},"cfg":{},"text":"Ordinary Fish speech.","target":"audio-file","timeoutMs":12345,"providerOverrides":{}},"response":{"chunksBase64":["Ukk=","RkYA","AQL/"]}},"expected":{"id":"stream-file","resolvedConfig":{"apiKey":"fixture-fish-speech","baseUrl":"https://api.fish.audio","model":"s2.1-pro","latency":"balanced"},"request":{"url":"https://api.fish.audio/v1/tts","modelHeader":"s2.1-pro","body":{"text":"Ordinary Fish speech.","format":"mp3","sample_rate":44100,"latency":"balanced"},"timeoutMs":12345},"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"mp3","fileExtension":".mp3","voiceCompatible":false,"chunksBase64":["Ukk=","RkYA","AQL/"],"cleanupBeforeRelease":0,"cleanupAfterRelease":1,"sourceLockedAfterEof":false}}},
               {"input":{"id":"stream-rich-file","input":{"rawConfig":{"providers":{"fish-audio":{"apiKey":"fixture-fish-speech","baseUrl":" https://fish.example/custom/v2/// ","model":" drama-3 ","speakerVoiceId":" primary-voice ","voiceId":"secondary-voice","referenceId":"third-voice","latency":" LOW ","speed":1.2,"temperature":0.7,"topP":0.6,"top_p":0.4,"normalize":false}}},"cfg":{},"text":"Ordinary Fish speech.","target":"audio-file","timeoutMs":45000,"providerOverrides":{"model":" s1 ","modelId":"drama-3","speakerVoiceId":" override-primary ","voiceId":"override-second","referenceId":"override-third","latency":" NORMAL ","speed":1.5,"temperature":0.45,"topP":0.35,"top_p":0.65,"normalize":true}},"response":{"chunksBase64":["Ukk=","RkYA","AQL/"]}},"expected":{"id":"stream-rich-file","resolvedConfig":{"apiKey":"fixture-fish-speech","baseUrl":"https://fish.example/custom/v2","model":"drama-3","latency":"low","referenceId":"primary-voice","speed":1.2,"temperature":0.7,"topP":0.6,"normalize":false},"request":{"url":"https://fish.example/custom/v2/v1/tts","modelHeader":"s1","body":{"text":"Ordinary Fish speech.","format":"mp3","sample_rate":44100,"latency":"normal","reference_id":"override-primary","prosody":{"speed":1.5},"temperature":0.45,"top_p":0.35,"normalize":true},"timeoutMs":45000},"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"mp3","fileExtension":".mp3","voiceCompatible":false,"chunksBase64":["Ukk=","RkYA","AQL/"],"cleanupBeforeRelease":0,"cleanupAfterRelease":1,"sourceLockedAfterEof":false}}},
               {"input":{"id":"stream-note","input":{"rawConfig":{"providers":{"fish-audio":{"apiKey":"fixture-fish-speech"}}},"cfg":{},"text":"Ordinary Fish speech.","target":"voice-note","timeoutMs":12345,"providerOverrides":{}},"response":{"chunksBase64":["Ukk=","RkYA","AQL/"]}},"expected":{"id":"stream-note","resolvedConfig":{"apiKey":"fixture-fish-speech","baseUrl":"https://api.fish.audio","model":"s2.1-pro","latency":"balanced"},"request":{"url":"https://api.fish.audio/v1/tts","modelHeader":"s2.1-pro","body":{"text":"Ordinary Fish speech.","format":"opus","sample_rate":48000,"latency":"balanced"},"timeoutMs":12345},"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"opus","fileExtension":".opus","voiceCompatible":true,"chunksBase64":["Ukk=","RkYA","AQL/"],"cleanupBeforeRelease":0,"cleanupAfterRelease":1,"sourceLockedAfterEof":false}}},
               {"input":{"id":"stream-rich-note","input":{"rawConfig":{"providers":{"fish-audio":{"apiKey":"fixture-fish-speech","baseUrl":" https://fish.example/custom/v2/// ","model":" drama-3 ","speakerVoiceId":" primary-voice ","voiceId":"secondary-voice","referenceId":"third-voice","latency":" LOW ","speed":1.2,"temperature":0.7,"topP":0.6,"top_p":0.4,"normalize":false}}},"cfg":{},"text":"Ordinary Fish speech.","target":"voice-note","timeoutMs":45000,"providerOverrides":{"model":" s1 ","modelId":"drama-3","speakerVoiceId":" override-primary ","voiceId":"override-second","referenceId":"override-third","latency":" NORMAL ","speed":1.5,"temperature":0.45,"topP":0.35,"top_p":0.65,"normalize":true}},"response":{"chunksBase64":["Ukk=","RkYA","AQL/"]}},"expected":{"id":"stream-rich-note","resolvedConfig":{"apiKey":"fixture-fish-speech","baseUrl":"https://fish.example/custom/v2","model":"drama-3","latency":"low","referenceId":"primary-voice","speed":1.2,"temperature":0.7,"topP":0.6,"normalize":false},"request":{"url":"https://fish.example/custom/v2/v1/tts","modelHeader":"s1","body":{"text":"Ordinary Fish speech.","format":"opus","sample_rate":48000,"latency":"normal","reference_id":"override-primary","prosody":{"speed":1.5},"temperature":0.45,"top_p":0.35,"normalize":true},"timeoutMs":45000},"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"opus","fileExtension":".opus","voiceCompatible":true,"chunksBase64":["Ukk=","RkYA","AQL/"],"cleanupBeforeRelease":0,"cleanupAfterRelease":1,"sourceLockedAfterEof":false}}},
               {"input":{"id":"stream-phone","input":{"rawConfig":{"providers":{"fish-audio":{"apiKey":"fixture-fish-speech"}}},"cfg":{},"text":"Ordinary Fish speech.","target":"telephony","timeoutMs":12345,"providerOverrides":{}},"response":{"chunksBase64":["Ukk=","RkYA","AQL/"]}},"expected":{"id":"stream-phone","resolvedConfig":{"apiKey":"fixture-fish-speech","baseUrl":"https://api.fish.audio","model":"s2.1-pro","latency":"balanced"},"request":{"url":"https://api.fish.audio/v1/tts","modelHeader":"s2.1-pro","body":{"text":"Ordinary Fish speech.","format":"pcm","sample_rate":8000,"latency":"balanced"},"timeoutMs":12345},"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"pcm","fileExtension":".pcm","voiceCompatible":false,"chunksBase64":["Ukk=","RkYA","AQL/"],"cleanupBeforeRelease":0,"cleanupAfterRelease":1,"sourceLockedAfterEof":false}}},
               {"input":{"id":"stream-rich-phone","input":{"rawConfig":{"providers":{"fish-audio":{"apiKey":"fixture-fish-speech","baseUrl":" https://fish.example/custom/v2/// ","model":" drama-3 ","speakerVoiceId":" primary-voice ","voiceId":"secondary-voice","referenceId":"third-voice","latency":" LOW ","speed":1.2,"temperature":0.7,"topP":0.6,"top_p":0.4,"normalize":false}}},"cfg":{},"text":"Ordinary Fish speech.","target":"telephony","timeoutMs":45000,"providerOverrides":{"model":" s1 ","modelId":"drama-3","speakerVoiceId":" override-primary ","voiceId":"override-second","referenceId":"override-third","latency":" NORMAL ","speed":1.5,"temperature":0.45,"topP":0.35,"top_p":0.65,"normalize":true}},"response":{"chunksBase64":["Ukk=","RkYA","AQL/"]}},"expected":{"id":"stream-rich-phone","resolvedConfig":{"apiKey":"fixture-fish-speech","baseUrl":"https://fish.example/custom/v2","model":"drama-3","latency":"low","referenceId":"primary-voice","speed":1.2,"temperature":0.7,"topP":0.6,"normalize":false},"request":{"url":"https://fish.example/custom/v2/v1/tts","modelHeader":"s1","body":{"text":"Ordinary Fish speech.","format":"pcm","sample_rate":8000,"latency":"normal","reference_id":"override-primary","prosody":{"speed":1.5},"temperature":0.45,"top_p":0.35,"normalize":true},"timeoutMs":45000},"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"pcm","fileExtension":".pcm","voiceCompatible":false,"chunksBase64":["Ukk=","RkYA","AQL/"],"cleanupBeforeRelease":0,"cleanupAfterRelease":1,"sourceLockedAfterEof":false}}}
             ],
             "telephony": [
               {"input":{"id":"phone-forces-file-target","input":{"rawConfig":{"providers":{"fish-audio":{"apiKey":"fixture-fish-speech"}}},"cfg":{},"text":"Ordinary Fish speech.","target":"audio-file","timeoutMs":12345,"providerOverrides":{}},"response":{"audioBase64":"UklGRgABAv8="}},"expected":{"id":"phone-forces-file-target","resolvedConfig":{"apiKey":"fixture-fish-speech","baseUrl":"https://api.fish.audio","model":"s2.1-pro","latency":"balanced"},"request":{"url":"https://api.fish.audio/v1/tts","modelHeader":"s2.1-pro","body":{"text":"Ordinary Fish speech.","format":"pcm","sample_rate":8000,"latency":"balanced"},"timeoutMs":12345},"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"pcm","sampleRate":8000}}},
               {"input":{"id":"phone-forces-note-target","input":{"rawConfig":{"providers":{"fish-audio":{"apiKey":"fixture-fish-speech","baseUrl":" https://fish.example/custom/v2/// ","model":" drama-3 ","speakerVoiceId":" primary-voice ","voiceId":"secondary-voice","referenceId":"third-voice","latency":" LOW ","speed":1.2,"temperature":0.7,"topP":0.6,"top_p":0.4,"normalize":false}}},"cfg":{},"text":"Ordinary Fish speech.","target":"voice-note","timeoutMs":12345,"providerOverrides":{}},"response":{"audioBase64":"UklGRgABAv8="}},"expected":{"id":"phone-forces-note-target","resolvedConfig":{"apiKey":"fixture-fish-speech","baseUrl":"https://fish.example/custom/v2","model":"drama-3","latency":"low","referenceId":"primary-voice","speed":1.2,"temperature":0.7,"topP":0.6,"normalize":false},"request":{"url":"https://fish.example/custom/v2/v1/tts","modelHeader":"drama-3","body":{"text":"Ordinary Fish speech.","format":"pcm","sample_rate":8000,"latency":"low","reference_id":"primary-voice","prosody":{"speed":1.2},"temperature":0.7,"top_p":0.6,"normalize":false},"timeoutMs":12345},"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"pcm","sampleRate":8000}}},
               {"input":{"id":"phone-overrides","input":{"rawConfig":{"providers":{"fish-audio":{"apiKey":"fixture-fish-speech","baseUrl":" https://fish.example/custom/v2/// ","model":" drama-3 ","speakerVoiceId":" primary-voice ","voiceId":"secondary-voice","referenceId":"third-voice","latency":" LOW ","speed":1.2,"temperature":0.7,"topP":0.6,"top_p":0.4,"normalize":false}}},"cfg":{},"text":"Ordinary Fish speech.","target":"audio-file","timeoutMs":75000,"providerOverrides":{"model":" s1 ","modelId":"drama-3","speakerVoiceId":" override-primary ","voiceId":"override-second","referenceId":"override-third","latency":" NORMAL ","speed":1.5,"temperature":0.45,"topP":0.35,"top_p":0.65,"normalize":true}},"response":{"audioBase64":"UklGRgABAv8="}},"expected":{"id":"phone-overrides","resolvedConfig":{"apiKey":"fixture-fish-speech","baseUrl":"https://fish.example/custom/v2","model":"drama-3","latency":"low","referenceId":"primary-voice","speed":1.2,"temperature":0.7,"topP":0.6,"normalize":false},"request":{"url":"https://fish.example/custom/v2/v1/tts","modelHeader":"s1","body":{"text":"Ordinary Fish speech.","format":"pcm","sample_rate":8000,"latency":"normal","reference_id":"override-primary","prosody":{"speed":1.5},"temperature":0.45,"top_p":0.35,"normalize":true},"timeoutMs":75000},"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"pcm","sampleRate":8000}}}
             ],
             "voices": [
               {"input":{"id":"voices-own-public-order-dedup","input":{"providerConfig":{"apiKey":"fixture-fish-speech","baseUrl":"https://api.fish.audio","model":"s2.1-pro","latency":"balanced"}},"response":{"pages":[{"total":2,"items":[{"_id":"owned-a","title":" Owned A ","description":" Voice owned-a ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-b","title":" Owned B ","description":" Voice owned-b ","visibility":" private ","languages":[" zh-CN ","fr-FR"],"tags":[" warm ","clear"]}]},{"total":3,"items":[{"_id":"owned-b","title":" Public duplicate ","description":" Voice owned-b ","visibility":" public ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"public-a","title":" Public A ","description":" Voice public-a ","visibility":" public ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"public-b","title":" Public B ","description":" Voice public-b ","visibility":" public ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]}]}]}},"expected":{"id":"voices-own-public-order-dedup","requests":[{"url":"https://api.fish.audio/model?type=tts&page_size=100&page_number=1&self=true","timeoutMs":240000},{"url":"https://api.fish.audio/model?type=tts&page_size=100&page_number=1&sort_by=score","timeoutMs":240000}],"result":[{"id":"owned-a","name":"Owned A","description":"Voice owned-a","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-b","name":"Owned B","description":"Voice owned-b","category":"private","locale":"zh-CN","personalities":["warm","clear"]},{"id":"public-a","name":"Public A","description":"Voice public-a","category":"public","locale":"en-US","personalities":["warm","clear"]},{"id":"public-b","name":"Public B","description":"Voice public-b","category":"public","locale":"en-US","personalities":["warm","clear"]}]}},
               {"input":{"id":"voices-two-owned-pages","input":{"providerConfig":{"apiKey":"fixture-fish-speech","baseUrl":"https://api.fish.audio","model":"s2.1-pro","latency":"balanced"},"timeoutMs":45000},"response":{"pages":[{"total":102,"items":[{"_id":"owned-000","title":" Own 0 ","description":" Voice owned-000 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-001","title":" Own 1 ","description":" Voice owned-001 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-002","title":" Own 2 ","description":" Voice owned-002 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-003","title":" Own 3 ","description":" Voice owned-003 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-004","title":" Own 4 ","description":" Voice owned-004 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-005","title":" Own 5 ","description":" Voice owned-005 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-006","title":" Own 6 ","description":" Voice owned-006 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-007","title":" Own 7 ","description":" Voice owned-007 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-008","title":" Own 8 ","description":" Voice owned-008 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-009","title":" Own 9 ","description":" Voice owned-009 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-010","title":" Own 10 ","description":" Voice owned-010 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-011","title":" Own 11 ","description":" Voice owned-011 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-012","title":" Own 12 ","description":" Voice owned-012 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-013","title":" Own 13 ","description":" Voice owned-013 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-014","title":" Own 14 ","description":" Voice owned-014 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-015","title":" Own 15 ","description":" Voice owned-015 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-016","title":" Own 16 ","description":" Voice owned-016 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-017","title":" Own 17 ","description":" Voice owned-017 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-018","title":" Own 18 ","description":" Voice owned-018 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-019","title":" Own 19 ","description":" Voice owned-019 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-020","title":" Own 20 ","description":" Voice owned-020 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-021","title":" Own 21 ","description":" Voice owned-021 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-022","title":" Own 22 ","description":" Voice owned-022 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-023","title":" Own 23 ","description":" Voice owned-023 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-024","title":" Own 24 ","description":" Voice owned-024 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-025","title":" Own 25 ","description":" Voice owned-025 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-026","title":" Own 26 ","description":" Voice owned-026 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-027","title":" Own 27 ","description":" Voice owned-027 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-028","title":" Own 28 ","description":" Voice owned-028 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-029","title":" Own 29 ","description":" Voice owned-029 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-030","title":" Own 30 ","description":" Voice owned-030 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-031","title":" Own 31 ","description":" Voice owned-031 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-032","title":" Own 32 ","description":" Voice owned-032 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-033","title":" Own 33 ","description":" Voice owned-033 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-034","title":" Own 34 ","description":" Voice owned-034 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-035","title":" Own 35 ","description":" Voice owned-035 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-036","title":" Own 36 ","description":" Voice owned-036 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-037","title":" Own 37 ","description":" Voice owned-037 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-038","title":" Own 38 ","description":" Voice owned-038 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-039","title":" Own 39 ","description":" Voice owned-039 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-040","title":" Own 40 ","description":" Voice owned-040 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-041","title":" Own 41 ","description":" Voice owned-041 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-042","title":" Own 42 ","description":" Voice owned-042 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-043","title":" Own 43 ","description":" Voice owned-043 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-044","title":" Own 44 ","description":" Voice owned-044 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-045","title":" Own 45 ","description":" Voice owned-045 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-046","title":" Own 46 ","description":" Voice owned-046 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-047","title":" Own 47 ","description":" Voice owned-047 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-048","title":" Own 48 ","description":" Voice owned-048 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-049","title":" Own 49 ","description":" Voice owned-049 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-050","title":" Own 50 ","description":" Voice owned-050 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-051","title":" Own 51 ","description":" Voice owned-051 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-052","title":" Own 52 ","description":" Voice owned-052 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-053","title":" Own 53 ","description":" Voice owned-053 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-054","title":" Own 54 ","description":" Voice owned-054 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-055","title":" Own 55 ","description":" Voice owned-055 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-056","title":" Own 56 ","description":" Voice owned-056 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-057","title":" Own 57 ","description":" Voice owned-057 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-058","title":" Own 58 ","description":" Voice owned-058 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-059","title":" Own 59 ","description":" Voice owned-059 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-060","title":" Own 60 ","description":" Voice owned-060 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-061","title":" Own 61 ","description":" Voice owned-061 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-062","title":" Own 62 ","description":" Voice owned-062 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-063","title":" Own 63 ","description":" Voice owned-063 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-064","title":" Own 64 ","description":" Voice owned-064 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-065","title":" Own 65 ","description":" Voice owned-065 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-066","title":" Own 66 ","description":" Voice owned-066 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-067","title":" Own 67 ","description":" Voice owned-067 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-068","title":" Own 68 ","description":" Voice owned-068 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-069","title":" Own 69 ","description":" Voice owned-069 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-070","title":" Own 70 ","description":" Voice owned-070 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-071","title":" Own 71 ","description":" Voice owned-071 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-072","title":" Own 72 ","description":" Voice owned-072 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-073","title":" Own 73 ","description":" Voice owned-073 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-074","title":" Own 74 ","description":" Voice owned-074 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-075","title":" Own 75 ","description":" Voice owned-075 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-076","title":" Own 76 ","description":" Voice owned-076 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-077","title":" Own 77 ","description":" Voice owned-077 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-078","title":" Own 78 ","description":" Voice owned-078 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-079","title":" Own 79 ","description":" Voice owned-079 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-080","title":" Own 80 ","description":" Voice owned-080 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-081","title":" Own 81 ","description":" Voice owned-081 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-082","title":" Own 82 ","description":" Voice owned-082 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-083","title":" Own 83 ","description":" Voice owned-083 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-084","title":" Own 84 ","description":" Voice owned-084 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-085","title":" Own 85 ","description":" Voice owned-085 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-086","title":" Own 86 ","description":" Voice owned-086 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-087","title":" Own 87 ","description":" Voice owned-087 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-088","title":" Own 88 ","description":" Voice owned-088 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-089","title":" Own 89 ","description":" Voice owned-089 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-090","title":" Own 90 ","description":" Voice owned-090 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-091","title":" Own 91 ","description":" Voice owned-091 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-092","title":" Own 92 ","description":" Voice owned-092 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-093","title":" Own 93 ","description":" Voice owned-093 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-094","title":" Own 94 ","description":" Voice owned-094 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-095","title":" Own 95 ","description":" Voice owned-095 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-096","title":" Own 96 ","description":" Voice owned-096 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-097","title":" Own 97 ","description":" Voice owned-097 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-098","title":" Own 98 ","description":" Voice owned-098 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-099","title":" Own 99 ","description":" Voice owned-099 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]}]},{"total":102,"items":[{"_id":"owned-100","title":" Own 100 ","description":" Voice owned-100 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"owned-101","title":" Own 101 ","description":" Voice owned-101 ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]}]},{"total":2,"items":[{"_id":"owned-000","title":" Duplicate public ","description":" Voice owned-000 ","visibility":" public ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]},{"_id":"public-next","title":" Public next ","description":" Voice public-next ","visibility":" public ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]}]}]}},"expected":{"id":"voices-two-owned-pages","requests":[{"url":"https://api.fish.audio/model?type=tts&page_size=100&page_number=1&self=true","timeoutMs":45000},{"url":"https://api.fish.audio/model?type=tts&page_size=100&page_number=2&self=true","timeoutMs":45000},{"url":"https://api.fish.audio/model?type=tts&page_size=100&page_number=1&sort_by=score","timeoutMs":45000}],"result":[{"id":"owned-000","name":"Own 0","description":"Voice owned-000","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-001","name":"Own 1","description":"Voice owned-001","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-002","name":"Own 2","description":"Voice owned-002","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-003","name":"Own 3","description":"Voice owned-003","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-004","name":"Own 4","description":"Voice owned-004","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-005","name":"Own 5","description":"Voice owned-005","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-006","name":"Own 6","description":"Voice owned-006","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-007","name":"Own 7","description":"Voice owned-007","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-008","name":"Own 8","description":"Voice owned-008","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-009","name":"Own 9","description":"Voice owned-009","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-010","name":"Own 10","description":"Voice owned-010","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-011","name":"Own 11","description":"Voice owned-011","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-012","name":"Own 12","description":"Voice owned-012","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-013","name":"Own 13","description":"Voice owned-013","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-014","name":"Own 14","description":"Voice owned-014","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-015","name":"Own 15","description":"Voice owned-015","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-016","name":"Own 16","description":"Voice owned-016","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-017","name":"Own 17","description":"Voice owned-017","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-018","name":"Own 18","description":"Voice owned-018","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-019","name":"Own 19","description":"Voice owned-019","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-020","name":"Own 20","description":"Voice owned-020","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-021","name":"Own 21","description":"Voice owned-021","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-022","name":"Own 22","description":"Voice owned-022","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-023","name":"Own 23","description":"Voice owned-023","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-024","name":"Own 24","description":"Voice owned-024","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-025","name":"Own 25","description":"Voice owned-025","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-026","name":"Own 26","description":"Voice owned-026","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-027","name":"Own 27","description":"Voice owned-027","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-028","name":"Own 28","description":"Voice owned-028","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-029","name":"Own 29","description":"Voice owned-029","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-030","name":"Own 30","description":"Voice owned-030","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-031","name":"Own 31","description":"Voice owned-031","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-032","name":"Own 32","description":"Voice owned-032","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-033","name":"Own 33","description":"Voice owned-033","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-034","name":"Own 34","description":"Voice owned-034","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-035","name":"Own 35","description":"Voice owned-035","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-036","name":"Own 36","description":"Voice owned-036","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-037","name":"Own 37","description":"Voice owned-037","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-038","name":"Own 38","description":"Voice owned-038","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-039","name":"Own 39","description":"Voice owned-039","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-040","name":"Own 40","description":"Voice owned-040","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-041","name":"Own 41","description":"Voice owned-041","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-042","name":"Own 42","description":"Voice owned-042","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-043","name":"Own 43","description":"Voice owned-043","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-044","name":"Own 44","description":"Voice owned-044","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-045","name":"Own 45","description":"Voice owned-045","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-046","name":"Own 46","description":"Voice owned-046","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-047","name":"Own 47","description":"Voice owned-047","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-048","name":"Own 48","description":"Voice owned-048","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-049","name":"Own 49","description":"Voice owned-049","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-050","name":"Own 50","description":"Voice owned-050","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-051","name":"Own 51","description":"Voice owned-051","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-052","name":"Own 52","description":"Voice owned-052","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-053","name":"Own 53","description":"Voice owned-053","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-054","name":"Own 54","description":"Voice owned-054","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-055","name":"Own 55","description":"Voice owned-055","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-056","name":"Own 56","description":"Voice owned-056","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-057","name":"Own 57","description":"Voice owned-057","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-058","name":"Own 58","description":"Voice owned-058","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-059","name":"Own 59","description":"Voice owned-059","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-060","name":"Own 60","description":"Voice owned-060","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-061","name":"Own 61","description":"Voice owned-061","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-062","name":"Own 62","description":"Voice owned-062","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-063","name":"Own 63","description":"Voice owned-063","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-064","name":"Own 64","description":"Voice owned-064","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-065","name":"Own 65","description":"Voice owned-065","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-066","name":"Own 66","description":"Voice owned-066","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-067","name":"Own 67","description":"Voice owned-067","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-068","name":"Own 68","description":"Voice owned-068","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-069","name":"Own 69","description":"Voice owned-069","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-070","name":"Own 70","description":"Voice owned-070","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-071","name":"Own 71","description":"Voice owned-071","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-072","name":"Own 72","description":"Voice owned-072","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-073","name":"Own 73","description":"Voice owned-073","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-074","name":"Own 74","description":"Voice owned-074","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-075","name":"Own 75","description":"Voice owned-075","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-076","name":"Own 76","description":"Voice owned-076","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-077","name":"Own 77","description":"Voice owned-077","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-078","name":"Own 78","description":"Voice owned-078","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-079","name":"Own 79","description":"Voice owned-079","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-080","name":"Own 80","description":"Voice owned-080","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-081","name":"Own 81","description":"Voice owned-081","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-082","name":"Own 82","description":"Voice owned-082","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-083","name":"Own 83","description":"Voice owned-083","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-084","name":"Own 84","description":"Voice owned-084","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-085","name":"Own 85","description":"Voice owned-085","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-086","name":"Own 86","description":"Voice owned-086","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-087","name":"Own 87","description":"Voice owned-087","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-088","name":"Own 88","description":"Voice owned-088","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-089","name":"Own 89","description":"Voice owned-089","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-090","name":"Own 90","description":"Voice owned-090","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-091","name":"Own 91","description":"Voice owned-091","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-092","name":"Own 92","description":"Voice owned-092","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-093","name":"Own 93","description":"Voice owned-093","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-094","name":"Own 94","description":"Voice owned-094","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-095","name":"Own 95","description":"Voice owned-095","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-096","name":"Own 96","description":"Voice owned-096","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-097","name":"Own 97","description":"Voice owned-097","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-098","name":"Own 98","description":"Voice owned-098","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-099","name":"Own 99","description":"Voice owned-099","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-100","name":"Own 100","description":"Voice owned-100","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"owned-101","name":"Own 101","description":"Voice owned-101","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"public-next","name":"Public next","description":"Voice public-next","category":"public","locale":"en-US","personalities":["warm","clear"]}]}},
               {"input":{"id":"voices-explicit-connection","input":{"providerConfig":{"apiKey":"fixture-fish-speech","baseUrl":"https://saved.example/fish","model":"s2.1-pro","latency":"balanced"},"apiKey":"fixture-fish-speech","baseUrl":" https://voices.example/custom/v3/// ","timeoutMs":75000},"response":{"pages":[{"total":1,"items":[{"_id":"saved-one","title":" Saved One ","description":" Voice saved-one ","visibility":" private ","languages":[" en-US ","fr-FR"],"tags":[" warm ","clear"]}]},{"total":1,"items":[{"_id":"public-one","title":" Public One ","description":" Voice public-one ","visibility":" public ","languages":[" ja-JP ","fr-FR"],"tags":[" gentle "]}]}]}},"expected":{"id":"voices-explicit-connection","requests":[{"url":"https://voices.example/custom/v3/model?type=tts&page_size=100&page_number=1&self=true","timeoutMs":75000},{"url":"https://voices.example/custom/v3/model?type=tts&page_size=100&page_number=1&sort_by=score","timeoutMs":75000}],"result":[{"id":"saved-one","name":"Saved One","description":"Voice saved-one","category":"private","locale":"en-US","personalities":["warm","clear"]},{"id":"public-one","name":"Public One","description":"Voice public-one","category":"public","locale":"ja-JP","personalities":["gentle"]}]}}
             ]
           }
           """)

  test "Fish metadata retains its ordered six models and finite default" do
    assert FishAudio.models() == @models
    assert FishAudio.default_timeout_ms() == 240_000

    assert Map.take(FishAudio.metadata(), [
             :id,
             :label,
             :auto_select_order,
             :default_model,
             :default_timeout_ms,
             :models
           ]) == %{
             id: "fish-audio",
             label: "Fish Audio",
             auto_select_order: 28,
             default_model: "s2.1-pro",
             default_timeout_ms: 240_000,
             models: @models
           }

    assert FishAudio.resolve_config(%{}) == %{
             base_url: "https://api.fish.audio",
             model: "s2.1-pro",
             latency: "balanced"
           }
  end

  for recipe <- @recipes["config"] do
    @recipe recipe
    test "source config: #{recipe["expected"]["id"]}" do
      assert FishAudio.resolve_config(@recipe["input"]["input"]["rawConfig"]) ==
               fields(@recipe["expected"]["result"])
    end
  end

  for recipe <- @recipes["talkConfig"] do
    @recipe recipe
    test "Talk config composes into ordinary synthesis: #{recipe["expected"]["id"]}" do
      input = @recipe["input"]["input"]
      expected = fields(@recipe["expected"]["result"])
      config = FishAudio.resolve_talk_config(input["baseTtsConfig"], input["talkProviderConfig"])
      assert config == expected

      assert_http(
        %{text: "Talk composition", target: :audio_file, timeout_ms: 12_345},
        config,
        expected.model,
        literal_body(expected, "Talk composition"),
        output("mp3")
      )
    end
  end

  for recipe <- @recipes["talkOverride"] do
    @recipe recipe
    test "Talk overrides compose into ordinary synthesis: #{recipe["expected"]["id"]}" do
      expected = fields(@recipe["expected"]["result"])
      overrides = FishAudio.resolve_talk_overrides(@recipe["input"]["input"]["params"])
      assert overrides == expected

      config = %{
        api_key: "fixture-fish-speech",
        base_url: "https://api.fish.audio",
        model: "s2.1-pro",
        latency: "balanced",
        temperature: 0.7,
        top_p: 0.6,
        normalize: false
      }

      resolved = Map.merge(config, expected)

      assert_http(
        %{
          text: "Talk overrides",
          target: :audio_file,
          timeout_ms: 12_345,
          provider_overrides: overrides
        },
        config,
        resolved.model,
        literal_body(resolved, "Talk overrides"),
        output("mp3")
      )
    end
  end

  for section <- ["synthesis", "telephony"], recipe <- @recipes[section] do
    @section section
    @recipe recipe
    test "ordinary #{@section}: #{recipe["expected"]["id"]}" do
      input = @recipe["input"]["input"]
      expected = @recipe["expected"]
      config = FishAudio.resolve_config(input["rawConfig"])
      assert config == fields(expected["resolvedConfig"])
      req = request(input)

      if @section == "synthesis" do
        assert {:ok, built} = FishAudio.build_request(req, config)
        assert built.url == expected["request"]["url"]
        assert built.body == expected["request"]["body"]
        assert built.timeout_ms == expected["request"]["timeoutMs"]
        assert Map.new(built.headers)["model"] == expected["request"]["modelHeader"]
      end

      assert_http(
        req,
        config,
        expected["request"]["modelHeader"],
        expected["request"]["body"],
        result(expected["result"]),
        @section
      )
    end
  end

  for recipe <- @recipes["stream"] do
    @recipe recipe
    test "real incremental HTTP then normal EOF and explicit release: #{recipe["expected"]["id"]}" do
      fixture = Gaoxy.Test.open()
      on_exit(fn -> Gaoxy.Test.close(fixture) end)
      owner = self()
      token = make_ref()
      expected = @recipe["expected"]
      input = @recipe["input"]["input"]
      config = FishAudio.resolve_config(input["rawConfig"])
      assert config == fields(expected["resolvedConfig"])
      config = Map.put(config, :base_url, Gaoxy.Test.url(fixture, "/incremental"))
      first = <<82, 73>>
      rest = <<70, 70, 0, 1, 2, 255>>

      Gaoxy.Test.expect_once(fixture, "POST", "/incremental/v1/tts", fn conn ->
        {:ok, data, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(data) == expected["request"]["body"]
        assert Plug.Conn.get_req_header(conn, "model") == [expected["request"]["modelHeader"]]

        conn =
          conn
          |> Plug.Conn.put_resp_content_type("application/octet-stream")
          |> Plug.Conn.send_chunked(200)

        {:ok, conn} = Plug.Conn.chunk(conn, first)
        send(owner, {:fish_first, token, self()})

        receive do
          {:fish_remainder, ^token} -> :ok
        after
          10_000 -> raise "consumer did not read first bytes before server EOF"
        end

        {:ok, conn} = Plug.Conn.chunk(conn, rest)
        conn
      end)

      before = Task.Supervisor.children(Synapsis.Provider.TaskSupervisor)
      assert {:ok, opened} = FishAudio.stream_synthesize(request(input), config)
      assert Map.delete(opened, :stream) == output(expected["result"]["outputFormat"])
      assert_receive {:fish_first, ^token, server}, 5_000
      assert read_prefix(opened.stream, byte_size(first), <<>>) == first
      # The server is still waiting here: neither opening nor the first read can
      # depend on the complete response. Transport chunk boundaries may vary.
      [task] = Task.Supervisor.children(Synapsis.Provider.TaskSupervisor) -- before
      monitor = Process.monitor(task)
      send(server, {:fish_remainder, token})
      assert read_all(opened.stream, []) == rest
      assert Stream.read(opened.stream) == :eof
      assert Stream.release(opened.stream) == :ok
      assert_receive {:DOWN, ^monitor, :process, ^task, _}, 5_000
      assert Stream.release(opened.stream) == :ok
      assert Task.Supervisor.children(Synapsis.Provider.TaskSupervisor) -- before == []
      Gaoxy.Test.verify!(fixture)
    end
  end

  for recipe <- @recipes["voices"] do
    @recipe recipe
    test "ordered normalized voice catalog: #{recipe["expected"]["id"]}" do
      fixture = Gaoxy.Test.open()
      on_exit(fn -> Gaoxy.Test.close(fixture) end)
      source = @recipe["input"]
      expected = @recipe["expected"]
      owner = self()
      token = make_ref()
      {:ok, counter} = Agent.start_link(fn -> 0 end)
      on_exit(fn -> if Process.alive?(counter), do: Agent.stop(counter) end)
      pages = source["response"]["pages"]

      Gaoxy.Test.stub(fixture, "GET", "/voices/model", fn conn ->
        index = Agent.get_and_update(counter, &{&1, &1 + 1})
        assert index < length(pages)
        conn = Plug.Conn.fetch_query_params(conn)

        expected_query =
          expected["requests"]
          |> Enum.at(index)
          |> Map.fetch!("url")
          |> URI.parse()
          |> Map.fetch!(:query)
          |> URI.decode_query()

        assert conn.query_params == expected_query
        send(owner, {:fish_voice_page, token, index})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(Enum.at(pages, index)))
      end)

      config =
        source["input"]["providerConfig"]
        |> then(&FishAudio.resolve_config(%{"providers" => %{"fish-audio" => &1}}))

      config =
        Map.put(
          config,
          :base_url,
          Gaoxy.Test.url(fixture, if(source["input"]["baseUrl"], do: "/saved", else: "/voices"))
        )

      req =
        if source["input"]["timeoutMs"],
          do: %{timeout_ms: source["input"]["timeoutMs"]},
          else: %{}

      req =
        if source["input"]["baseUrl"],
          do:
            Map.merge(req, %{
              base_url: Gaoxy.Test.url(fixture, "/voices"),
              api_key: "explicit-fish-fixture"
            }),
          else: req

      trace_voice_http()
      assert {:ok, voices} = FishAudio.list_voices(req, config)
      assert voices == Enum.map(expected["result"], &voice_fields/1)

      for index <- 0..(length(pages) - 1),
          do: assert_receive({:fish_voice_page, ^token, ^index}, 5_000)

      assert Agent.get(counter, & &1) == length(pages)
      assert_voice_timeouts(fixture, Enum.map(expected["requests"], & &1["timeoutMs"]))
    end
  end

  defp assert_http(req, config, model, body, expected, callback \\ "synthesis") do
    fixture = Gaoxy.Test.open()

    try do
      prefix = URI.parse(config.base_url).path || ""
      base_url = String.trim_trailing(Gaoxy.Test.url(fixture), "/") <> prefix
      local = Map.put(config, :base_url, base_url)

      Gaoxy.Test.expect_once(fixture, "POST", prefix <> "/v1/tts", fn conn ->
        {:ok, bytes, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(bytes) == body
        assert Plug.Conn.get_req_header(conn, "model") == [model]

        assert Plug.Conn.get_req_header(conn, "content-type")
               |> Enum.any?(&String.starts_with?(&1, "application/json"))

        conn
        |> Plug.Conn.put_resp_content_type("application/octet-stream")
        |> Plug.Conn.resp(200, @audio)
      end)

      actual =
        if callback == "telephony",
          do: FishAudio.synthesize_telephony(req, local),
          else: FishAudio.synthesize(req, local)

      assert actual == {:ok, Map.put(expected, :audio, @audio)}
      Gaoxy.Test.verify!(fixture)
    after
      Gaoxy.Test.close(fixture)
    end
  end

  defp request(input),
    do: %{
      text: input["text"],
      target: target(input["target"]),
      timeout_ms: input["timeoutMs"],
      provider_overrides: fields(input["providerOverrides"] || %{})
    }

  defp target("voice-note"), do: :voice_note
  defp target("telephony"), do: :telephony
  defp target(_), do: :audio_file

  defp fields(map) do
    names = %{
      "apiKey" => :api_key,
      "baseUrl" => :base_url,
      "model" => :model,
      "modelId" => :model_id,
      "referenceId" => :reference_id,
      "speakerVoiceId" => :speaker_voice_id,
      "voiceId" => :voice_id,
      "latency" => :latency,
      "speed" => :speed,
      "temperature" => :temperature,
      "topP" => :top_p,
      "top_p" => :top_p,
      "normalize" => :normalize
    }

    # Source camelCase topP precedes top_p when both are supplied.
    map = if Map.has_key?(map, "topP"), do: Map.delete(map, "top_p"), else: map
    Map.new(map, fn {key, value} -> {Map.fetch!(names, key), value} end)
  end

  defp output(format),
    do: %{
      output_format: format,
      file_extension: "." <> format,
      voice_compatible: format == "opus"
    }

  defp result(%{"sampleRate" => rate}), do: %{output_format: "pcm", sample_rate: rate}
  defp result(map), do: output(map["outputFormat"])

  defp literal_body(config, text) do
    Enum.reduce(
      [
        {:reference_id, "reference_id"},
        {:temperature, "temperature"},
        {:top_p, "top_p"},
        {:normalize, "normalize"}
      ],
      %{"text" => text, "format" => "mp3", "sample_rate" => 44_100, "latency" => config.latency},
      fn {key, wire}, body ->
        if Map.has_key?(config, key), do: Map.put(body, wire, config[key]), else: body
      end
    )
    |> then(fn body ->
      if Map.has_key?(config, :speed),
        do: Map.put(body, "prosody", %{"speed" => config.speed}),
        else: body
    end)
  end

  defp voice_fields(map),
    do:
      Map.new(map, fn {key, value} ->
        {Map.fetch!(
           %{
             "id" => :id,
             "name" => :name,
             "description" => :description,
             "category" => :category,
             "locale" => :locale,
             "personalities" => :personalities
           },
           key
         ), value}
      end)

  defp read_prefix(_stream, size, bytes) when byte_size(bytes) == size, do: bytes

  defp read_prefix(stream, size, bytes) do
    assert {:ok, chunk} = Stream.read(stream)
    assert byte_size(bytes) + byte_size(chunk) <= size
    read_prefix(stream, size, bytes <> chunk)
  end

  defp read_all(stream, chunks) do
    case Stream.read(stream) do
      {:ok, chunk} -> read_all(stream, [chunk | chunks])
      :eof -> chunks |> Enum.reverse() |> IO.iodata_to_binary()
    end
  end

  defp trace_voice_http do
    Code.ensure_loaded!(Req)
    :erlang.trace_pattern({Req, :request, 1}, true, [:local])
    :erlang.trace(:all, true, [:call, {:tracer, self()}])

    on_exit(fn ->
      :erlang.trace(:all, false, [:call])
      :erlang.trace_pattern({Req, :request, 1}, false, [:local])
    end)
  end

  defp assert_voice_timeouts(fixture, expected) do
    barrier = :erlang.trace_delivered(:all)
    assert_receive {:trace_delivered, :all, ^barrier}, 5_000
    requests = voice_requests([], Gaoxy.Test.url(fixture))
    assert length(requests) == length(expected)

    for {req, timeout} <- Enum.zip(requests, expected) do
      for duration <- [
            req.options[:receive_timeout],
            req.options[:request_timeout],
            req.options[:finch][:pool_timeout]
          ] do
        assert duration > timeout - 5_000
        assert duration <= timeout
      end
    end
  end

  defp voice_requests(requests, base) do
    receive do
      {:trace, _, :call, {Req, :request, [%Req.Request{} = req]}} ->
        requests =
          if String.starts_with?(URI.to_string(req.url), base),
            do: [req | requests],
            else: requests

        voice_requests(requests, base)
    after
      0 -> Enum.reverse(requests)
    end
  end
end

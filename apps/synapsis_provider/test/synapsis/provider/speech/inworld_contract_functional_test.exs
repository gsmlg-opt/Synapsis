defmodule Synapsis.Provider.Speech.InworldContractFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Provider.Speech.Inworld

  @moduletag timeout: 90_000

  # Frozen source-authored batch345 inputs and literal expectations, copied before
  # host implementation. These eight opaque audio bytes qualify transport only.
  # The source has no streamSynthesize callback: all service results are buffered.
  @raw Jason.decode!(~S"""
       {
         "config": [
           {"id":"empty-defaults","input":{"rawConfig":{}}},
           {"id":"root-and-legacy-not-selected","input":{"rawConfig":{"apiKey":"fixture-inworld-speech-contract","voiceId":"RootVoice","modelId":"RootModel","inworld":{"voiceId":"LegacyVoice","modelId":"LegacyModel"}}}},
           {"id":"nested-all-fields","input":{"rawConfig":{"providers":{"inworld":{"apiKey":"fixture-inworld-speech-contract","baseUrl":" https://speech.example.test/v2/// ","voiceId":" Ashley ","modelId":" inworld-tts-1.5-mini ","temperature":0.75}}}}},
           {"id":"empty-nested-masks-legacy","input":{"rawConfig":{"voiceId":"RootVoice","inworld":{"voiceId":"LegacyVoice"},"providers":{"inworld":{}}}}},
           {"id":"blank-optionals-use-defaults","input":{"rawConfig":{"providers":{"inworld":{"apiKey":"fixture-inworld-speech-contract","baseUrl":" \t ","voiceId":" ","modelId":"\n "}}}}},
           {"id":"ecmascript-trim","input":{"rawConfig":{"providers":{"inworld":{"apiKey":" fixture-inworld-speech-contract ","baseUrl":"\ufeff\u00a0https://trim.example.test/api///\u00a0\ufeff","voiceId":"\ufeff\u00a0 Olivia \u00a0\ufeff","modelId":"\ufeff\u00a0 inworld-tts-1 \u00a0\ufeff","temperature":1.1}}}}},
           {"id":"custom-values-preserved","input":{"rawConfig":{"providers":{"inworld":{"apiKey":"fixture-inworld-speech-contract","baseUrl":"https://studio.example.test/prefix/","voiceId":" Studio / Voice ","modelId":" custom-studio-model ","temperature":1.25}}}}}
         ],
         "talkConfig": [
           {"id":"defaults-from-empty-base","input":{"baseTtsConfig":{},"talkProviderConfig":{}}},
           {"id":"inherit-normalized-base","input":{"baseTtsConfig":{"providers":{"inworld":{"apiKey":"fixture-inworld-speech-contract","baseUrl":" https://base.example.test/api/// ","voiceId":" Dennis ","modelId":" inworld-tts-1.5-mini ","temperature":0.8}}},"talkProviderConfig":{}}},
           {"id":"explicit-talk-fields","input":{"baseTtsConfig":{"providers":{"inworld":{"apiKey":"fixture-inworld-speech-contract","baseUrl":"https://base.example.test/api","voiceId":"Dennis","modelId":"inworld-tts-1.5-mini","temperature":0.8}}},"talkProviderConfig":{"apiKey":" fixture-inworld-speech-contract ","baseUrl":" https://talk.example.test/v1/// ","voiceId":"\ufeff\u00a0 Wendy \u00a0\ufeff","modelId":" inworld-tts-1 ","temperature":1.1}}},
           {"id":"partial-talk-composition","input":{"baseTtsConfig":{"providers":{"inworld":{"apiKey":"fixture-inworld-speech-contract","baseUrl":"https://base.example.test/api","voiceId":"Dennis","modelId":"inworld-tts-1.5-mini","temperature":0.8}}},"talkProviderConfig":{"voiceId":" Ashley ","temperature":0.9}}},
           {"id":"blank-talk-optionals-inherit","input":{"baseTtsConfig":{"providers":{"inworld":{"apiKey":"fixture-inworld-speech-contract","baseUrl":"https://base.example.test/api","voiceId":"Dennis","modelId":"inworld-tts-1.5-mini","temperature":0.8}}},"talkProviderConfig":{"baseUrl":" \t ","voiceId":"\ufeff\u00a0","modelId":" "}}}
         ],
         "talkOverrides": [
           {"id":"empty-params","input":{"params":{}}},
           {"id":"canonical-fields","input":{"params":{"voiceId":"\ufeff\u00a0 Olivia \u00a0\ufeff","modelId":" inworld-tts-1 ","temperature":1.1}}},
           {"id":"partial-temperature","input":{"params":{"temperature":0.6}}},
           {"id":"aliases-not-projected","input":{"params":{"voice":"AliasVoice","model":"AliasModel","voice_id":"SnakeVoice","model_id":"SnakeModel","outputFormat":"mp3","language":"en-US"}}},
           {"id":"blank-canonical-optionals","input":{"params":{"voiceId":" \t ","modelId":"\ufeff\u00a0","voice":"AliasVoice","model":"AliasModel"}}}
         ],
         "synthesis": [
           {"id":"file-default-from-raw","input":{"request":{"text":"Ordinary Inworld speech.","target":"audio-file","timeoutMs":12345},"rawConfig":{"providers":{"inworld":{"apiKey":"fixture-inworld-speech-contract"}}}}},
           {"id":"file-configured-from-raw","input":{"request":{"text":"  Ordinary speech.\n\u4f60\u597d \ud83c\udf0d \u2014 caf\u00e9.\t ","target":"audio-file","timeoutMs":12345},"rawConfig":{"providers":{"inworld":{"apiKey":"fixture-inworld-speech-contract","baseUrl":" https://speech.example.test/v2/// ","voiceId":" Ashley ","modelId":" inworld-tts-1.5-mini ","temperature":0.75}}}}},
           {"id":"file-pre-resolved-config","input":{"request":{"text":"Ordinary Inworld speech.","target":"audio-file","timeoutMs":12345,"providerConfig":{"apiKey":"fixture-inworld-speech-contract","baseUrl":"https://resolved.example.test/api","voiceId":"Dennis","modelId":"inworld-tts-1-max","temperature":0.9}}}},
           {"id":"file-talk-config-and-overrides","input":{"request":{"text":"Ordinary Inworld speech.","target":"audio-file","timeoutMs":12345},"baseTtsConfig":{"providers":{"inworld":{"apiKey":"fixture-inworld-speech-contract","baseUrl":"https://base.example.test/api","voiceId":"Dennis","modelId":"inworld-tts-1.5-mini","temperature":0.8}}},"talkProviderConfig":{"baseUrl":" https://talk.example.test/v1/// ","voiceId":"Ashley"},"talkParams":{"voiceId":" Olivia ","modelId":" inworld-tts-1 ","temperature":1.1}}},
           {"id":"note-default-from-raw","input":{"request":{"text":"Ordinary Inworld speech.","target":"voice-note","timeoutMs":12345},"rawConfig":{"providers":{"inworld":{"apiKey":"fixture-inworld-speech-contract"}}}}},
           {"id":"note-talk-config-and-overrides","input":{"request":{"text":"Ordinary Inworld speech.","target":"voice-note","timeoutMs":12345},"baseTtsConfig":{"providers":{"inworld":{"apiKey":"fixture-inworld-speech-contract","voiceId":"Dennis","temperature":0.8}}},"talkProviderConfig":{"voiceId":" Ashley ","modelId":" inworld-tts-1-max "},"talkParams":{"temperature":0.7}}},
           {"id":"file-direct-alias-overrides","input":{"request":{"text":"Ordinary Inworld speech.","target":"audio-file","timeoutMs":12345,"providerConfig":{"apiKey":"fixture-inworld-speech-contract","voiceId":"Dennis","modelId":"inworld-tts-1.5-mini","temperature":0.8},"providerOverrides":{"voice":" Olivia ","model":" inworld-tts-1 ","temperature":1.2}}}},
           {"id":"file-primary-overrides","input":{"request":{"text":"Ordinary Inworld speech.","target":"audio-file","timeoutMs":12345,"providerConfig":{"apiKey":"fixture-inworld-speech-contract"},"providerOverrides":{"voiceId":" Ashley ","voice":"Olivia","modelId":" inworld-tts-1-max ","model":"inworld-tts-1","temperature":0.9}}}},
           {"id":"file-blank-primary-uses-config","input":{"request":{"text":"Ordinary Inworld speech.","target":"audio-file","timeoutMs":12345,"providerConfig":{"apiKey":"fixture-inworld-speech-contract","voiceId":"Dennis","modelId":"inworld-tts-1.5-mini","temperature":0.8},"providerOverrides":{"voiceId":" ","voice":"Olivia","modelId":"\t","model":"inworld-tts-1"}}}},
           {"id":"file-multiple-audio-lines","input":{"request":{"text":"Ordinary Inworld speech.","target":"audio-file","timeoutMs":12345,"providerConfig":{"apiKey":"fixture-inworld-speech-contract"}},"response":{"ndjson":"{\"result\":{\"audioContent\":\"UklGRg==\"}}\n{\"result\":{\"audioContent\":\"AAE=\"}}\n{\"result\":{\"audioContent\":\"Av8=\"}}\n"}}},
           {"id":"file-metadata-and-blank-lines","input":{"request":{"text":"Ordinary Inworld speech.","target":"audio-file","timeoutMs":12345,"providerConfig":{"apiKey":"fixture-inworld-speech-contract"}},"response":{"ndjson":"\n \t\n{\"requestId\":\"ordinary-request\"}\n\ufeff\u00a0 {\"result\":{\"audioContent\":\"UklGRg==\"}} \u00a0\ufeff\n{\"result\":{\"requestId\":\"ordinary-progress\"}}\n{\"result\":{\"audioContent\":\"AAE=\"}}\n\n{\"result\":{\"audioContent\":\"Av8=\"}}\n"}}},
           {"id":"file-canonical-base64-variants","input":{"request":{"text":"Ordinary Inworld speech.","target":"audio-file","timeoutMs":12345,"providerConfig":{"apiKey":"fixture-inworld-speech-contract"}},"response":{"ndjson":"{\"result\":{\"audioContent\":\" UklG Rg==\\t\"}}\n{\"result\":{\"audioContent\":\"AAE\"}}\n{\"result\":{\"audioContent\":\"Av8\"}}\n"}}}
         ],
         "telephony": [
           {"id":"phone-from-raw","input":{"request":{"text":"Ordinary Inworld phone speech.","target":"telephony","timeoutMs":12345},"rawConfig":{"providers":{"inworld":{"apiKey":"fixture-inworld-speech-contract","voiceId":"Dennis","modelId":"inworld-tts-1.5-mini","temperature":0.8}}}}},
           {"id":"phone-pre-resolved-and-aliases","input":{"request":{"text":"  Phone speech.\n\u4f60\u597d \ud83d\udcde\t ","target":"telephony","timeoutMs":12345,"providerConfig":{"apiKey":"fixture-inworld-speech-contract","baseUrl":" https://phone.example.test/api/// ","voiceId":"Sarah","modelId":"inworld-tts-1.5-max"},"providerOverrides":{"voice":" Wendy ","model":" inworld-tts-1 ","temperature":1.1}}}},
           {"id":"phone-talk-composition","input":{"request":{"text":"Ordinary Inworld phone speech.","target":"telephony","timeoutMs":12345},"baseTtsConfig":{"providers":{"inworld":{"apiKey":"fixture-inworld-speech-contract","baseUrl":"https://base.example.test/api","voiceId":"Dennis","modelId":"inworld-tts-1.5-mini","temperature":0.8}}},"talkProviderConfig":{"voiceId":" Ashley "},"talkParams":{"modelId":" inworld-tts-1-max ","temperature":0.7}}}
         ],
         "voices": [
           {"id":"explicit-get-projection","input":{"request":{"apiKey":"fixture-inworld-speech-contract","baseUrl":" https://voices.example.test/api/// ","timeoutMs":12345},"response":{"voices":[{"voiceId":" Sarah ","displayName":" Sarah Voice ","description":" A calm narrator. ","langCode":" en-US ","tags":["warm","female","male"],"source":"curated"},{"voiceId":"Dennis","displayName":" Dennis ","langCode":"en-GB","tags":["male","female"]},{"voiceId":"Sarah","displayName":" Second Sarah ","description":"   ","langCode":"fr-CA","tags":["neutral","female"]},{"voiceId":"Minimal","tags":["Male","FEMALE","character"]}]}}},
           {"id":"provider-config-default-timeout","input":{"request":{"providerConfig":{"apiKey":"fixture-inworld-speech-contract","baseUrl":" https://catalog.example.test/v2/// "}},"response":{"voices":[{"voiceId":"Locale","displayName":" Locale Voice ","description":" Description ","langCode":"\tpt-BR ","tags":["other","male"]},{"voiceId":"Optional","displayName":"  ","description":"\t","langCode":"","tags":[]}]}}},
           {"id":"raw-config-voice-list","input":{"request":{"timeoutMs":12345},"rawConfig":{"providers":{"inworld":{"apiKey":"fixture-inworld-speech-contract","baseUrl":" https://rawvoices.example.test/api/// "}}},"response":{"voices":[{"voiceId":" RawVoice "}]}}},
           {"id":"talk-config-explicit-url","input":{"request":{"baseUrl":" https://explicit.example.test/list/// ","timeoutMs":4567},"baseTtsConfig":{"providers":{"inworld":{"apiKey":"fixture-inworld-speech-contract","baseUrl":"https://base.example.test/api","voiceId":"Dennis","temperature":0.8}}},"talkProviderConfig":{"baseUrl":" https://talk.example.test/v1/// ","modelId":" inworld-tts-1 "},"response":{"voices":[{"voiceId":"TalkVoice","displayName":" Talk Voice ","description":" Talk catalog ","langCode":"ja-JP","tags":["female","male"]}]}}}
         ]
       }
       """)

  @literal Jason.decode!(~S"""
           {
             "config": [
               {"id":"empty-defaults","expected":{"result":{"baseUrl":"https://api.inworld.ai","voiceId":"Sarah","modelId":"inworld-tts-1.5-max"},"requests":[],"releaseCount":0}},
               {"id":"root-and-legacy-not-selected","expected":{"result":{"baseUrl":"https://api.inworld.ai","voiceId":"Sarah","modelId":"inworld-tts-1.5-max"},"requests":[],"releaseCount":0}},
               {"id":"nested-all-fields","expected":{"result":{"apiKey":"fixture-inworld-speech-contract","baseUrl":"https://speech.example.test/v2","voiceId":"Ashley","modelId":"inworld-tts-1.5-mini","temperature":0.75},"requests":[],"releaseCount":0}},
               {"id":"empty-nested-masks-legacy","expected":{"result":{"baseUrl":"https://api.inworld.ai","voiceId":"Sarah","modelId":"inworld-tts-1.5-max"},"requests":[],"releaseCount":0}},
               {"id":"blank-optionals-use-defaults","expected":{"result":{"apiKey":"fixture-inworld-speech-contract","baseUrl":"https://api.inworld.ai","voiceId":"Sarah","modelId":"inworld-tts-1.5-max"},"requests":[],"releaseCount":0}},
               {"id":"ecmascript-trim","expected":{"result":{"apiKey":"fixture-inworld-speech-contract","baseUrl":"https://trim.example.test/api","voiceId":"Olivia","modelId":"inworld-tts-1","temperature":1.1},"requests":[],"releaseCount":0}},
               {"id":"custom-values-preserved","expected":{"result":{"apiKey":"fixture-inworld-speech-contract","baseUrl":"https://studio.example.test/prefix","voiceId":"Studio / Voice","modelId":"custom-studio-model","temperature":1.25},"requests":[],"releaseCount":0}}
             ],
             "talkConfig": [
               {"id":"defaults-from-empty-base","expected":{"result":{"baseUrl":"https://api.inworld.ai","voiceId":"Sarah","modelId":"inworld-tts-1.5-max"},"requests":[],"releaseCount":0}},
               {"id":"inherit-normalized-base","expected":{"result":{"apiKey":"fixture-inworld-speech-contract","baseUrl":"https://base.example.test/api","voiceId":"Dennis","modelId":"inworld-tts-1.5-mini","temperature":0.8},"requests":[],"releaseCount":0}},
               {"id":"explicit-talk-fields","expected":{"result":{"apiKey":"fixture-inworld-speech-contract","baseUrl":"https://talk.example.test/v1","voiceId":"Wendy","modelId":"inworld-tts-1","temperature":1.1},"requests":[],"releaseCount":0}},
               {"id":"partial-talk-composition","expected":{"result":{"apiKey":"fixture-inworld-speech-contract","baseUrl":"https://base.example.test/api","voiceId":"Ashley","modelId":"inworld-tts-1.5-mini","temperature":0.9},"requests":[],"releaseCount":0}},
               {"id":"blank-talk-optionals-inherit","expected":{"result":{"apiKey":"fixture-inworld-speech-contract","baseUrl":"https://base.example.test/api","voiceId":"Dennis","modelId":"inworld-tts-1.5-mini","temperature":0.8},"requests":[],"releaseCount":0}}
             ],
             "talkOverrides": [
               {"id":"empty-params","expected":{"result":{},"requests":[],"releaseCount":0}},
               {"id":"canonical-fields","expected":{"result":{"voiceId":"Olivia","modelId":"inworld-tts-1","temperature":1.1},"requests":[],"releaseCount":0}},
               {"id":"partial-temperature","expected":{"result":{"temperature":0.6},"requests":[],"releaseCount":0}},
               {"id":"aliases-not-projected","expected":{"result":{},"requests":[],"releaseCount":0}},
               {"id":"blank-canonical-optionals","expected":{"result":{},"requests":[],"releaseCount":0}}
             ],
             "synthesis": [
               {"id":"file-default-from-raw","expected":{"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"mp3","fileExtension":".mp3","voiceCompatible":false},"resolvedConfig":{"apiKey":"fixture-inworld-speech-contract","baseUrl":"https://api.inworld.ai","voiceId":"Sarah","modelId":"inworld-tts-1.5-max"},"synthesisRequest":{"text":"Ordinary Inworld speech.","target":"audio-file","timeoutMs":12345,"providerConfig":{"apiKey":"fixture-inworld-speech-contract","baseUrl":"https://api.inworld.ai","voiceId":"Sarah","modelId":"inworld-tts-1.5-max"},"cfg":{}},"requests":[{"url":"https://api.inworld.ai/tts/v1/voice:stream","method":"POST","body":{"text":"Ordinary Inworld speech.","voiceId":"Sarah","modelId":"inworld-tts-1.5-max","audioConfig":{"audioEncoding":"MP3"}},"bodyText":"{\"text\":\"Ordinary Inworld speech.\",\"voiceId\":\"Sarah\",\"modelId\":\"inworld-tts-1.5-max\",\"audioConfig\":{\"audioEncoding\":\"MP3\"}}","timeoutMs":12345,"auditContext":"inworld-tts"}],"releaseCount":1}},
               {"id":"file-configured-from-raw","expected":{"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"mp3","fileExtension":".mp3","voiceCompatible":false},"resolvedConfig":{"apiKey":"fixture-inworld-speech-contract","baseUrl":"https://speech.example.test/v2","voiceId":"Ashley","modelId":"inworld-tts-1.5-mini","temperature":0.75},"synthesisRequest":{"text":"  Ordinary speech.\n\u4f60\u597d \ud83c\udf0d \u2014 caf\u00e9.\t ","target":"audio-file","timeoutMs":12345,"providerConfig":{"apiKey":"fixture-inworld-speech-contract","baseUrl":"https://speech.example.test/v2","voiceId":"Ashley","modelId":"inworld-tts-1.5-mini","temperature":0.75},"cfg":{}},"requests":[{"url":"https://speech.example.test/v2/tts/v1/voice:stream","method":"POST","body":{"text":"  Ordinary speech.\n\u4f60\u597d \ud83c\udf0d \u2014 caf\u00e9.\t ","voiceId":"Ashley","modelId":"inworld-tts-1.5-mini","audioConfig":{"audioEncoding":"MP3"},"temperature":0.75},"bodyText":"{\"text\":\"  Ordinary speech.\\n\u4f60\u597d \ud83c\udf0d \u2014 caf\u00e9.\\t \",\"voiceId\":\"Ashley\",\"modelId\":\"inworld-tts-1.5-mini\",\"audioConfig\":{\"audioEncoding\":\"MP3\"},\"temperature\":0.75}","timeoutMs":12345,"auditContext":"inworld-tts"}],"releaseCount":1}},
               {"id":"file-pre-resolved-config","expected":{"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"mp3","fileExtension":".mp3","voiceCompatible":false},"synthesisRequest":{"text":"Ordinary Inworld speech.","target":"audio-file","timeoutMs":12345,"providerConfig":{"apiKey":"fixture-inworld-speech-contract","baseUrl":"https://resolved.example.test/api","voiceId":"Dennis","modelId":"inworld-tts-1-max","temperature":0.9},"cfg":{}},"requests":[{"url":"https://resolved.example.test/api/tts/v1/voice:stream","method":"POST","body":{"text":"Ordinary Inworld speech.","voiceId":"Dennis","modelId":"inworld-tts-1-max","audioConfig":{"audioEncoding":"MP3"},"temperature":0.9},"bodyText":"{\"text\":\"Ordinary Inworld speech.\",\"voiceId\":\"Dennis\",\"modelId\":\"inworld-tts-1-max\",\"audioConfig\":{\"audioEncoding\":\"MP3\"},\"temperature\":0.9}","timeoutMs":12345,"auditContext":"inworld-tts"}],"releaseCount":1}},
               {"id":"file-talk-config-and-overrides","expected":{"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"mp3","fileExtension":".mp3","voiceCompatible":false},"resolvedConfig":{"apiKey":"fixture-inworld-speech-contract","baseUrl":"https://talk.example.test/v1","voiceId":"Ashley","modelId":"inworld-tts-1.5-mini","temperature":0.8},"synthesisRequest":{"text":"Ordinary Inworld speech.","target":"audio-file","timeoutMs":12345,"providerConfig":{"apiKey":"fixture-inworld-speech-contract","baseUrl":"https://talk.example.test/v1","voiceId":"Ashley","modelId":"inworld-tts-1.5-mini","temperature":0.8},"providerOverrides":{"voiceId":"Olivia","modelId":"inworld-tts-1","temperature":1.1},"cfg":{}},"requests":[{"url":"https://talk.example.test/v1/tts/v1/voice:stream","method":"POST","body":{"text":"Ordinary Inworld speech.","voiceId":"Olivia","modelId":"inworld-tts-1","audioConfig":{"audioEncoding":"MP3"},"temperature":1.1},"bodyText":"{\"text\":\"Ordinary Inworld speech.\",\"voiceId\":\"Olivia\",\"modelId\":\"inworld-tts-1\",\"audioConfig\":{\"audioEncoding\":\"MP3\"},\"temperature\":1.1}","timeoutMs":12345,"auditContext":"inworld-tts"}],"releaseCount":1}},
               {"id":"note-default-from-raw","expected":{"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"ogg_opus","fileExtension":".ogg","voiceCompatible":true},"resolvedConfig":{"apiKey":"fixture-inworld-speech-contract","baseUrl":"https://api.inworld.ai","voiceId":"Sarah","modelId":"inworld-tts-1.5-max"},"synthesisRequest":{"text":"Ordinary Inworld speech.","target":"voice-note","timeoutMs":12345,"providerConfig":{"apiKey":"fixture-inworld-speech-contract","baseUrl":"https://api.inworld.ai","voiceId":"Sarah","modelId":"inworld-tts-1.5-max"},"cfg":{}},"requests":[{"url":"https://api.inworld.ai/tts/v1/voice:stream","method":"POST","body":{"text":"Ordinary Inworld speech.","voiceId":"Sarah","modelId":"inworld-tts-1.5-max","audioConfig":{"audioEncoding":"OGG_OPUS"}},"bodyText":"{\"text\":\"Ordinary Inworld speech.\",\"voiceId\":\"Sarah\",\"modelId\":\"inworld-tts-1.5-max\",\"audioConfig\":{\"audioEncoding\":\"OGG_OPUS\"}}","timeoutMs":12345,"auditContext":"inworld-tts"}],"releaseCount":1}},
               {"id":"note-talk-config-and-overrides","expected":{"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"ogg_opus","fileExtension":".ogg","voiceCompatible":true},"resolvedConfig":{"apiKey":"fixture-inworld-speech-contract","baseUrl":"https://api.inworld.ai","voiceId":"Ashley","modelId":"inworld-tts-1-max","temperature":0.8},"synthesisRequest":{"text":"Ordinary Inworld speech.","target":"voice-note","timeoutMs":12345,"providerConfig":{"apiKey":"fixture-inworld-speech-contract","baseUrl":"https://api.inworld.ai","voiceId":"Ashley","modelId":"inworld-tts-1-max","temperature":0.8},"providerOverrides":{"temperature":0.7},"cfg":{}},"requests":[{"url":"https://api.inworld.ai/tts/v1/voice:stream","method":"POST","body":{"text":"Ordinary Inworld speech.","voiceId":"Ashley","modelId":"inworld-tts-1-max","audioConfig":{"audioEncoding":"OGG_OPUS"},"temperature":0.7},"bodyText":"{\"text\":\"Ordinary Inworld speech.\",\"voiceId\":\"Ashley\",\"modelId\":\"inworld-tts-1-max\",\"audioConfig\":{\"audioEncoding\":\"OGG_OPUS\"},\"temperature\":0.7}","timeoutMs":12345,"auditContext":"inworld-tts"}],"releaseCount":1}},
               {"id":"file-direct-alias-overrides","expected":{"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"mp3","fileExtension":".mp3","voiceCompatible":false},"synthesisRequest":{"text":"Ordinary Inworld speech.","target":"audio-file","timeoutMs":12345,"providerConfig":{"apiKey":"fixture-inworld-speech-contract","voiceId":"Dennis","modelId":"inworld-tts-1.5-mini","temperature":0.8},"providerOverrides":{"voice":" Olivia ","model":" inworld-tts-1 ","temperature":1.2},"cfg":{}},"requests":[{"url":"https://api.inworld.ai/tts/v1/voice:stream","method":"POST","body":{"text":"Ordinary Inworld speech.","voiceId":"Olivia","modelId":"inworld-tts-1","audioConfig":{"audioEncoding":"MP3"},"temperature":1.2},"bodyText":"{\"text\":\"Ordinary Inworld speech.\",\"voiceId\":\"Olivia\",\"modelId\":\"inworld-tts-1\",\"audioConfig\":{\"audioEncoding\":\"MP3\"},\"temperature\":1.2}","timeoutMs":12345,"auditContext":"inworld-tts"}],"releaseCount":1}},
               {"id":"file-primary-overrides","expected":{"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"mp3","fileExtension":".mp3","voiceCompatible":false},"synthesisRequest":{"text":"Ordinary Inworld speech.","target":"audio-file","timeoutMs":12345,"providerConfig":{"apiKey":"fixture-inworld-speech-contract"},"providerOverrides":{"voiceId":" Ashley ","voice":"Olivia","modelId":" inworld-tts-1-max ","model":"inworld-tts-1","temperature":0.9},"cfg":{}},"requests":[{"url":"https://api.inworld.ai/tts/v1/voice:stream","method":"POST","body":{"text":"Ordinary Inworld speech.","voiceId":"Ashley","modelId":"inworld-tts-1-max","audioConfig":{"audioEncoding":"MP3"},"temperature":0.9},"bodyText":"{\"text\":\"Ordinary Inworld speech.\",\"voiceId\":\"Ashley\",\"modelId\":\"inworld-tts-1-max\",\"audioConfig\":{\"audioEncoding\":\"MP3\"},\"temperature\":0.9}","timeoutMs":12345,"auditContext":"inworld-tts"}],"releaseCount":1}},
               {"id":"file-blank-primary-uses-config","expected":{"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"mp3","fileExtension":".mp3","voiceCompatible":false},"synthesisRequest":{"text":"Ordinary Inworld speech.","target":"audio-file","timeoutMs":12345,"providerConfig":{"apiKey":"fixture-inworld-speech-contract","voiceId":"Dennis","modelId":"inworld-tts-1.5-mini","temperature":0.8},"providerOverrides":{"voiceId":" ","voice":"Olivia","modelId":"\t","model":"inworld-tts-1"},"cfg":{}},"requests":[{"url":"https://api.inworld.ai/tts/v1/voice:stream","method":"POST","body":{"text":"Ordinary Inworld speech.","voiceId":"Dennis","modelId":"inworld-tts-1.5-mini","audioConfig":{"audioEncoding":"MP3"},"temperature":0.8},"bodyText":"{\"text\":\"Ordinary Inworld speech.\",\"voiceId\":\"Dennis\",\"modelId\":\"inworld-tts-1.5-mini\",\"audioConfig\":{\"audioEncoding\":\"MP3\"},\"temperature\":0.8}","timeoutMs":12345,"auditContext":"inworld-tts"}],"releaseCount":1}},
               {"id":"file-multiple-audio-lines","expected":{"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"mp3","fileExtension":".mp3","voiceCompatible":false},"synthesisRequest":{"text":"Ordinary Inworld speech.","target":"audio-file","timeoutMs":12345,"providerConfig":{"apiKey":"fixture-inworld-speech-contract"},"cfg":{}},"requests":[{"url":"https://api.inworld.ai/tts/v1/voice:stream","method":"POST","body":{"text":"Ordinary Inworld speech.","voiceId":"Sarah","modelId":"inworld-tts-1.5-max","audioConfig":{"audioEncoding":"MP3"}},"bodyText":"{\"text\":\"Ordinary Inworld speech.\",\"voiceId\":\"Sarah\",\"modelId\":\"inworld-tts-1.5-max\",\"audioConfig\":{\"audioEncoding\":\"MP3\"}}","timeoutMs":12345,"auditContext":"inworld-tts"}],"releaseCount":1}},
               {"id":"file-metadata-and-blank-lines","expected":{"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"mp3","fileExtension":".mp3","voiceCompatible":false},"synthesisRequest":{"text":"Ordinary Inworld speech.","target":"audio-file","timeoutMs":12345,"providerConfig":{"apiKey":"fixture-inworld-speech-contract"},"cfg":{}},"requests":[{"url":"https://api.inworld.ai/tts/v1/voice:stream","method":"POST","body":{"text":"Ordinary Inworld speech.","voiceId":"Sarah","modelId":"inworld-tts-1.5-max","audioConfig":{"audioEncoding":"MP3"}},"bodyText":"{\"text\":\"Ordinary Inworld speech.\",\"voiceId\":\"Sarah\",\"modelId\":\"inworld-tts-1.5-max\",\"audioConfig\":{\"audioEncoding\":\"MP3\"}}","timeoutMs":12345,"auditContext":"inworld-tts"}],"releaseCount":1}},
               {"id":"file-canonical-base64-variants","expected":{"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"mp3","fileExtension":".mp3","voiceCompatible":false},"synthesisRequest":{"text":"Ordinary Inworld speech.","target":"audio-file","timeoutMs":12345,"providerConfig":{"apiKey":"fixture-inworld-speech-contract"},"cfg":{}},"requests":[{"url":"https://api.inworld.ai/tts/v1/voice:stream","method":"POST","body":{"text":"Ordinary Inworld speech.","voiceId":"Sarah","modelId":"inworld-tts-1.5-max","audioConfig":{"audioEncoding":"MP3"}},"bodyText":"{\"text\":\"Ordinary Inworld speech.\",\"voiceId\":\"Sarah\",\"modelId\":\"inworld-tts-1.5-max\",\"audioConfig\":{\"audioEncoding\":\"MP3\"}}","timeoutMs":12345,"auditContext":"inworld-tts"}],"releaseCount":1}}
             ],
             "telephony": [
               {"id":"phone-from-raw","expected":{"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"pcm","sampleRate":22050},"resolvedConfig":{"apiKey":"fixture-inworld-speech-contract","baseUrl":"https://api.inworld.ai","voiceId":"Dennis","modelId":"inworld-tts-1.5-mini","temperature":0.8},"synthesisRequest":{"text":"Ordinary Inworld phone speech.","target":"telephony","timeoutMs":12345,"providerConfig":{"apiKey":"fixture-inworld-speech-contract","baseUrl":"https://api.inworld.ai","voiceId":"Dennis","modelId":"inworld-tts-1.5-mini","temperature":0.8},"cfg":{}},"requests":[{"url":"https://api.inworld.ai/tts/v1/voice:stream","method":"POST","body":{"text":"Ordinary Inworld phone speech.","voiceId":"Dennis","modelId":"inworld-tts-1.5-mini","audioConfig":{"audioEncoding":"PCM","sampleRateHertz":22050},"temperature":0.8},"bodyText":"{\"text\":\"Ordinary Inworld phone speech.\",\"voiceId\":\"Dennis\",\"modelId\":\"inworld-tts-1.5-mini\",\"audioConfig\":{\"audioEncoding\":\"PCM\",\"sampleRateHertz\":22050},\"temperature\":0.8}","timeoutMs":12345,"auditContext":"inworld-tts"}],"releaseCount":1}},
               {"id":"phone-pre-resolved-and-aliases","expected":{"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"pcm","sampleRate":22050},"synthesisRequest":{"text":"  Phone speech.\n\u4f60\u597d \ud83d\udcde\t ","target":"telephony","timeoutMs":12345,"providerConfig":{"apiKey":"fixture-inworld-speech-contract","baseUrl":" https://phone.example.test/api/// ","voiceId":"Sarah","modelId":"inworld-tts-1.5-max"},"providerOverrides":{"voice":" Wendy ","model":" inworld-tts-1 ","temperature":1.1},"cfg":{}},"requests":[{"url":"https://phone.example.test/api/tts/v1/voice:stream","method":"POST","body":{"text":"  Phone speech.\n\u4f60\u597d \ud83d\udcde\t ","voiceId":"Wendy","modelId":"inworld-tts-1","audioConfig":{"audioEncoding":"PCM","sampleRateHertz":22050},"temperature":1.1},"bodyText":"{\"text\":\"  Phone speech.\\n\u4f60\u597d \ud83d\udcde\\t \",\"voiceId\":\"Wendy\",\"modelId\":\"inworld-tts-1\",\"audioConfig\":{\"audioEncoding\":\"PCM\",\"sampleRateHertz\":22050},\"temperature\":1.1}","timeoutMs":12345,"auditContext":"inworld-tts"}],"releaseCount":1}},
               {"id":"phone-talk-composition","expected":{"result":{"audioBase64":"UklGRgABAv8=","outputFormat":"pcm","sampleRate":22050},"resolvedConfig":{"apiKey":"fixture-inworld-speech-contract","baseUrl":"https://base.example.test/api","voiceId":"Ashley","modelId":"inworld-tts-1.5-mini","temperature":0.8},"synthesisRequest":{"text":"Ordinary Inworld phone speech.","target":"telephony","timeoutMs":12345,"providerConfig":{"apiKey":"fixture-inworld-speech-contract","baseUrl":"https://base.example.test/api","voiceId":"Ashley","modelId":"inworld-tts-1.5-mini","temperature":0.8},"providerOverrides":{"modelId":"inworld-tts-1-max","temperature":0.7},"cfg":{}},"requests":[{"url":"https://base.example.test/api/tts/v1/voice:stream","method":"POST","body":{"text":"Ordinary Inworld phone speech.","voiceId":"Ashley","modelId":"inworld-tts-1-max","audioConfig":{"audioEncoding":"PCM","sampleRateHertz":22050},"temperature":0.7},"bodyText":"{\"text\":\"Ordinary Inworld phone speech.\",\"voiceId\":\"Ashley\",\"modelId\":\"inworld-tts-1-max\",\"audioConfig\":{\"audioEncoding\":\"PCM\",\"sampleRateHertz\":22050},\"temperature\":0.7}","timeoutMs":12345,"auditContext":"inworld-tts"}],"releaseCount":1}}
             ],
             "voices": [
               {"id":"explicit-get-projection","expected":{"result":[{"id":"Sarah","name":"Sarah Voice","description":"A calm narrator.","locale":" en-US ","gender":"female"},{"id":"Dennis","name":"Dennis","locale":"en-GB","gender":"male"},{"id":"Sarah","name":"Second Sarah","locale":"fr-CA","gender":"female"},{"id":"Minimal"}],"requests":[{"url":"https://voices.example.test/api/voices/v1/voices","method":"GET","timeoutMs":12345,"auditContext":"inworld-voices"}],"releaseCount":1}},
               {"id":"provider-config-default-timeout","expected":{"result":[{"id":"Locale","name":"Locale Voice","description":"Description","locale":"\tpt-BR ","gender":"male"},{"id":"Optional"}],"requests":[{"url":"https://catalog.example.test/v2/voices/v1/voices","method":"GET","timeoutMs":30000,"auditContext":"inworld-voices"}],"releaseCount":1}},
               {"id":"raw-config-voice-list","expected":{"result":[{"id":"RawVoice"}],"resolvedConfig":{"apiKey":"fixture-inworld-speech-contract","baseUrl":"https://rawvoices.example.test/api","voiceId":"Sarah","modelId":"inworld-tts-1.5-max"},"requests":[{"url":"https://rawvoices.example.test/api/voices/v1/voices","method":"GET","timeoutMs":12345,"auditContext":"inworld-voices"}],"releaseCount":1}},
               {"id":"talk-config-explicit-url","expected":{"result":[{"id":"TalkVoice","name":"Talk Voice","description":"Talk catalog","locale":"ja-JP","gender":"female"}],"resolvedConfig":{"apiKey":"fixture-inworld-speech-contract","baseUrl":"https://talk.example.test/v1","voiceId":"Dennis","modelId":"inworld-tts-1","temperature":0.8},"requests":[{"url":"https://explicit.example.test/list/voices/v1/voices","method":"GET","timeoutMs":4567,"auditContext":"inworld-voices"}],"releaseCount":1}}
             ]
           }
           """)

  test "complete ordinary source inventory and metadata preserve advertised order" do
    counts = %{
      "config" => 7,
      "talkConfig" => 5,
      "talkOverrides" => 5,
      "synthesis" => 12,
      "telephony" => 3,
      "voices" => 4
    }

    assert Map.new(@raw, fn {group, rows} -> {group, length(rows)} end) == counts
    assert Map.new(@literal, fn {group, rows} -> {group, length(rows)} end) == counts

    models = [
      "inworld-tts-1.5-max",
      "inworld-tts-1.5-mini",
      "inworld-tts-1-max",
      "inworld-tts-1"
    ]

    assert Inworld.models() == models

    assert Map.take(Inworld.metadata(), [
             :id,
             :label,
             :auto_select_order,
             :default_model,
             :models
           ]) == %{
             id: "inworld",
             label: "Inworld",
             auto_select_order: 30,
             default_model: "inworld-tts-1.5-max",
             models: models
           }
  end

  for group <- ["config", "talkConfig", "talkOverrides"],
      {raw, literal} <- Enum.zip(@raw[group], @literal[group]) do
    @group group
    @row raw
    @expected literal
    test "ordinary pure #{@group}: #{raw["id"]}" do
      assert @row["id"] == @expected["id"]
      input = @row["input"]

      actual =
        case @group do
          "config" ->
            Inworld.resolve_config(input["rawConfig"])

          "talkConfig" ->
            Inworld.resolve_talk_config(input["baseTtsConfig"], input["talkProviderConfig"])

          "talkOverrides" ->
            Inworld.resolve_talk_overrides(input["params"])
        end

      assert actual == fields(@expected["expected"]["result"])
    end
  end

  for group <- ["synthesis", "telephony"],
      {raw, literal} <- Enum.zip(@raw[group], @literal[group]) do
    @group group
    @row raw
    @expected literal
    test "ordinary complete builder and local buffered HTTP #{@group}: #{raw["id"]}" do
      assert @row["id"] == @expected["id"]
      input = @row["input"]
      expected = @expected["expected"]
      [wire] = expected["requests"]
      config = source_config(input)
      request = source_request(input)
      before_build = System.monotonic_time(:millisecond)
      assert {:ok, built} = build(@group, request, config)
      after_build = System.monotonic_time(:millisecond)
      assert built.url == wire["url"]
      assert built.body == wire["body"]
      assert built.timeout_ms === wire["timeoutMs"]
      assert built.timeout_ms === request.timeout_ms
      assert built.deadline_ms === request.deadline_ms
      assert built.transport_deadline_ms >= before_build + request.timeout_ms
      assert built.transport_deadline_ms <= after_build + request.timeout_ms
      assert built.transport_deadline_ms <= request.deadline_ms
      assert built.max_bytes == 16 * 1024 * 1024
      assert built.max_response_bytes == 32 * 1024 * 1024
      assert Map.take(built, output_keys()) == result_fields(expected["result"])

      if expected["resolvedConfig"],
        do: assert(config == fields(expected["resolvedConfig"]))

      fixture = Gaoxy.Test.open()
      on_exit(fn -> Gaoxy.Test.close(fixture) end)
      path = URI.parse(wire["url"]).path
      owner = self()
      token = make_ref()

      Gaoxy.Test.expect_once(fixture, "POST", path, fn conn ->
        {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
        assert conn.method == "POST"
        assert conn.query_string == ""
        assert Jason.decode!(raw_body) == wire["body"]

        assert Plug.Conn.get_req_header(conn, "authorization") == [
                 "Basic fixture-inworld-speech-contract"
               ]

        assert Plug.Conn.get_req_header(conn, "content-type") == ["application/json"]
        send(owner, {:inworld_contract_post, token})

        conn =
          conn
          |> Plug.Conn.put_resp_content_type("application/x-ndjson")
          |> Plug.Conn.send_chunked(200)

        # Deliberately cross a JSON record boundary with ordinary HTTP chunks.
        response = response_ndjson(input)
        <<first::binary-size(17), rest::binary>> = response
        {:ok, conn} = Plug.Conn.chunk(conn, first)
        {:ok, conn} = Plug.Conn.chunk(conn, rest)
        conn
      end)

      [prefix, ""] = String.split(path, "/tts/v1/voice:stream", parts: 2)

      local =
        Map.put(
          config,
          :base_url,
          Gaoxy.Test.url(fixture, if(prefix == "", do: "/", else: prefix))
        )

      assert {:ok, actual} = synthesize(@group, request, local)

      assert actual ==
               Map.put(
                 result_fields(expected["result"]),
                 :audio,
                 <<82, 73, 70, 70, 0, 1, 2, 255>>
               )

      assert_receive {:inworld_contract_post, ^token}, 5_000
      Gaoxy.Test.verify!(fixture)
    end
  end

  for {raw, literal} <- Enum.zip(@raw["voices"], @literal["voices"]) do
    @row raw
    @expected literal
    test "explicit catalog preserves complete ordered source projection: #{raw["id"]}" do
      assert @row["id"] == @expected["id"]
      input = @row["input"]
      expected = @expected["expected"]
      [wire] = expected["requests"]
      fixture = Gaoxy.Test.open()
      on_exit(fn -> Gaoxy.Test.close(fixture) end)
      path = URI.parse(wire["url"]).path
      owner = self()
      token = make_ref()

      Gaoxy.Test.expect_once(fixture, "GET", path, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert body == ""
        assert conn.method == "GET"
        assert conn.query_string == ""

        assert Plug.Conn.get_req_header(conn, "authorization") == [
                 "Basic fixture-inworld-speech-contract"
               ]

        send(owner, {:inworld_contract_catalog, token})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(input["response"]))
      end)

      watcher = spawn(fn -> watch_task(owner, token) end)
      on_exit(fn -> send(watcher, :stop) end)
      route_req_origin(fixture, wire, token, watcher)
      config = source_config(input)
      request = input["request"] |> Map.delete("providerConfig") |> fields()
      if expected["resolvedConfig"], do: assert(config == fields(expected["resolvedConfig"]))
      assert {:ok, actual} = Inworld.list_voices(request, config)
      assert actual == Enum.map(expected["result"], &fields/1)

      assert_receive {:inworld_contract_route, ^token, source_url, :get, options, transport,
                      links},
                     5_000

      assert source_url == wire["url"]
      assert owner in links
      refute Process.alive?(transport)
      assert_receive {:inworld_actual_task_down, ^token, ^transport, :normal}, 5_000
      assert options[:request_timeout] > 0
      assert options[:request_timeout] <= wire["timeoutMs"]
      assert options[:receive_timeout] > 0
      assert options[:receive_timeout] <= min(30_000, wire["timeoutMs"])
      assert_receive {:inworld_contract_catalog, ^token}, 5_000
      Gaoxy.Test.verify!(fixture)
    end
  end

  test "dedicated telephony fixes PCM22050 independently of the ordinary file target" do
    request = %{text: "Dedicated phone speech.", target: :audio_file, timeout_ms: 12_345}

    config = %{
      api_key: "fixture-inworld-speech-contract",
      voice_id: "Dennis",
      model_id: "custom-phone-model"
    }

    assert {:ok, built} = Inworld.build_telephony_request(request, config)

    assert built.body == %{
             "text" => "Dedicated phone speech.",
             "voiceId" => "Dennis",
             "modelId" => "custom-phone-model",
             "audioConfig" => %{"audioEncoding" => "PCM", "sampleRateHertz" => 22_050}
           }

    assert Map.take(built, output_keys()) == %{output_format: "pcm", sample_rate: 22_050}
    assert {:ok, legacy} = Inworld.build_request(%{request | target: :telephony}, config)
    assert legacy.body == built.body
    assert Map.take(legacy, output_keys()) == %{output_format: "pcm", sample_rate: 22_050}

    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)

    expected_body = %{
      "text" => "Dedicated phone speech.",
      "voiceId" => "Dennis",
      "modelId" => "custom-phone-model",
      "audioConfig" => %{"audioEncoding" => "PCM", "sampleRateHertz" => 22_050}
    }

    Gaoxy.Test.expect_once(fixture, "POST", "/tts/v1/voice:stream", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == expected_body
      Plug.Conn.resp(conn, 200, "{\"result\":{\"audioContent\":\"UklGRgABAv8=\"}}\n")
    end)

    local = Map.put(config, :base_url, Gaoxy.Test.url(fixture))
    assert {:ok, result} = Inworld.synthesize_telephony(request, local)

    assert result == %{
             audio: <<82, 73, 70, 70, 0, 1, 2, 255>>,
             output_format: "pcm",
             sample_rate: 22_050
           }

    Gaoxy.Test.verify!(fixture)
  end

  test "one normal HTTP task keeps original operation deadline and exits before buffered return" do
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    owner = self()
    token = make_ref()
    source_url = "https://timing.example.test/tenant/tts/v1/voice:stream"

    request = %{
      text: "Ordinary completed task.",
      target: :audio_file,
      timeout_ms: 12_345,
      deadline_ms: System.monotonic_time(:millisecond) + 10_000
    }

    config = %{
      api_key: "fixture-inworld-speech-contract",
      base_url: "https://timing.example.test/tenant"
    }

    watcher = spawn(fn -> watch_task(owner, token) end)
    on_exit(fn -> send(watcher, :stop) end)

    Gaoxy.Test.expect_once(fixture, "POST", "/tenant/tts/v1/voice:stream", fn conn ->
      send(owner, {:inworld_normal_server_complete, token})
      Plug.Conn.resp(conn, 200, "{\"result\":{\"audioContent\":\"UklGRgABAv8=\"}}\n")
    end)

    route_req_origin(fixture, %{"url" => source_url}, token, watcher)
    assert {:ok, built} = Inworld.build_request(request, config)
    assert built.timeout_ms === 12_345
    assert built.deadline_ms === request.deadline_ms
    assert built.transport_deadline_ms === request.deadline_ms
    assert {:ok, result} = Inworld.synthesize(request, config)

    assert result == %{
             audio: <<82, 73, 70, 70, 0, 1, 2, 255>>,
             output_format: "mp3",
             file_extension: ".mp3",
             voice_compatible: false
           }

    assert_receive {:inworld_contract_route, ^token, ^source_url, :post, options, transport,
                    links},
                   5_000

    assert owner in links
    assert options[:finch] == [pool_timeout: options[:request_timeout]]
    assert options[:request_timeout] > 0
    assert options[:request_timeout] <= request.timeout_ms
    assert options[:request_timeout] <= 10_000
    assert options[:receive_timeout] <= min(30_000, options[:request_timeout])
    refute Process.alive?(transport)
    assert_receive {:inworld_actual_task_down, ^token, ^transport, :normal}, 5_000
    assert_receive {:inworld_normal_server_complete, ^token}, 5_000
    Gaoxy.Test.verify!(fixture)
  end

  defp source_config(%{"rawConfig" => raw}), do: Inworld.resolve_config(raw)

  defp source_config(%{"baseTtsConfig" => raw, "talkProviderConfig" => talk}),
    do: Inworld.resolve_talk_config(raw, talk)

  defp source_config(input), do: fields(get_in(input, ["request", "providerConfig"]) || %{})

  defp source_request(input) do
    raw = input["request"]

    overrides =
      if input["talkParams"],
        do: Inworld.resolve_talk_overrides(input["talkParams"]),
        else: fields(raw["providerOverrides"] || %{})

    %{
      text: raw["text"],
      target: target(raw["target"]),
      timeout_ms: raw["timeoutMs"],
      provider_overrides: overrides,
      deadline_ms: System.monotonic_time(:millisecond) + 60_000
    }
  end

  defp target("voice-note"), do: :voice_note
  defp target("telephony"), do: :telephony
  defp target("audio-file"), do: :audio_file
  defp build("synthesis", request, config), do: Inworld.build_request(request, config)
  defp build("telephony", request, config), do: Inworld.build_telephony_request(request, config)
  defp synthesize("synthesis", request, config), do: Inworld.synthesize(request, config)
  defp synthesize("telephony", request, config), do: Inworld.synthesize_telephony(request, config)

  defp response_ndjson(%{"response" => %{"ndjson" => ndjson}}), do: ndjson
  defp response_ndjson(_input), do: "{\"result\":{\"audioContent\":\"UklGRgABAv8=\"}}\n"
  defp output_keys, do: [:output_format, :file_extension, :voice_compatible, :sample_rate]

  defp result_fields(result),
    do: result |> Map.take(~w(outputFormat fileExtension voiceCompatible sampleRate)) |> fields()

  defp route_req_origin(fixture, wire, token, watcher) do
    original = Application.fetch_env(:req, :default_options)
    defaults = Req.default_options()
    owner = self()
    source_uri = URI.parse(wire["url"])
    local_uri = URI.parse(Gaoxy.Test.url(fixture))

    plugin = fn req ->
      Req.Request.prepend_request_steps(req,
        inworld346_source_origin: fn outgoing ->
          assert outgoing.url == source_uri
          {:links, links} = Process.info(self(), :links)

          send(
            owner,
            {:inworld_contract_route, token, URI.to_string(outgoing.url), outgoing.method,
             outgoing.options, self(), links}
          )

          if watcher do
            send(watcher, {:watch, self()})

            receive do
              {:inworld_watched, ^token} -> :ok
            after
              5_000 -> flunk("ordinary transport monitor was not established")
            end
          end

          routed = %{
            outgoing.url
            | scheme: local_uri.scheme,
              host: local_uri.host,
              port: local_uri.port
          }

          %{outgoing | url: routed}
        end
      )
    end

    Req.default_options(Keyword.update(defaults, :plugins, [plugin], &(&1 ++ [plugin])))

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:req, :default_options, value)
        :error -> Application.delete_env(:req, :default_options)
      end
    end)
  end

  defp watch_task(owner, token) do
    receive do
      {:watch, pid} ->
        monitor = Process.monitor(pid)
        send(pid, {:inworld_watched, token})

        receive do
          {:DOWN, ^monitor, :process, ^pid, reason} ->
            send(owner, {:inworld_actual_task_down, token, pid, reason})

          :stop ->
            Process.demonitor(monitor, [:flush])
        after
          15_000 -> Process.demonitor(monitor, [:flush])
        end

      :stop ->
        :ok
    after
      15_000 -> :ok
    end
  end

  defp fields(map) do
    names = %{
      "apiKey" => :api_key,
      "baseUrl" => :base_url,
      "voiceId" => :voice_id,
      "modelId" => :model_id,
      "voice" => :voice,
      "model" => :model,
      "temperature" => :temperature,
      "timeoutMs" => :timeout_ms,
      "id" => :id,
      "name" => :name,
      "description" => :description,
      "locale" => :locale,
      "gender" => :gender,
      "outputFormat" => :output_format,
      "fileExtension" => :file_extension,
      "voiceCompatible" => :voice_compatible,
      "sampleRate" => :sample_rate
    }

    Map.new(map, fn {key, value} -> {Map.fetch!(names, key), value} end)
  end
end

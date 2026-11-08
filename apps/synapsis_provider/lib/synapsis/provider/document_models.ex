defmodule Synapsis.Provider.DocumentModels do
  @moduledoc """
  Immutable OpenClaw media metadata, pinned to 488631c18fae7cc541ba8fc8beff6cbb0438787b.

  Source: extensions/*/openclaw.plugin.json, declared mediaUnderstandingProviders
  contracts only; selection semantics: src/media-understanding/{defaults,
  provider-registry-metadata}.ts and packages/media-understanding-common/src/provider-id.ts.
  No plugin code, file access or provider discovery runs here.

  Saved config.media_understanding accepts an explicit exact `profile`, then
  source fields `capabilities`, `autoPriority`, `defaultModels`,
  `nativeDocumentInputs`, `documentModels` (snake_case field aliases also accepted).
  Lists replace the source list; maps merge recursively. Nested map keys retain
  the source spelling, including documentModels.pdf.textExtraction. Literal false
  is retained. An explicit unknown profile opts out of preset/name defaults.

  Exact known host presets map to a source profile, followed by exact canonical
  source names and the source's three documented aliases. Transport and URL never
  establish a media identity. Multiple instances keep independent execution IDs.
  """

  # MIT License
  #
  # Copyright (c) 2026 OpenClaw Foundation
  #
  # Permission is hereby granted, free of charge, to any person obtaining a copy
  # of this software and associated documentation files (the "Software"), to deal
  # in the Software without restriction, including without limitation the rights
  # to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
  # copies of the Software, and to permit persons to whom the Software is
  # furnished to do so, subject to the following conditions:
  #
  # The above copyright notice and this permission notice shall be included in all
  # copies or substantial portions of the Software.
  #
  # THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
  # IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
  # FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
  # AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
  # LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
  # OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
  # SOFTWARE.

  @revision "openclaw:488631c18fae7cc541ba8fc8beff6cbb0438787b"
  # SHA-256 extensions/anthropic/openclaw.plugin.json: 70b3e20bbd91214a853a5bb8ee096a0398029573f65e25b752eb86de0d1bdb9c
  # SHA-256 extensions/clawrouter/openclaw.plugin.json: 82f6f01cb4b231b646a379d3feae4d2cdd4af4d5df447dbfde9010feeca3952e
  # SHA-256 extensions/codex/openclaw.plugin.json: b5774ff832d71a0180ac1a81a8dc03fcbc3d95614aac2292dbb0c0df3dce3011
  # SHA-256 extensions/deepgram/openclaw.plugin.json: 220cd73dd454eab96643d8146d555a80fa4056d5705732801583ae81e4d1ced6
  # SHA-256 extensions/deepinfra/openclaw.plugin.json: b798952671fbf02a9746ba7a885456d0e8caebb89380640f55e1474b25080695
  # SHA-256 extensions/elevenlabs/openclaw.plugin.json: 61e8bc572f083f88a856924028694883b3198fe541fc83c0cb91149f600410cb
  # SHA-256 extensions/google/openclaw.plugin.json: 8ed0ba5e5ce3f7bf5cd9e4f9a516faf941e14d124ff08b6aec56bf93eb49feb6
  # SHA-256 extensions/groq/openclaw.plugin.json: 5ebb730ffd06ec9d37043b6938f9463779786b9658f02a6bbcb791f247bbc3e1
  # SHA-256 extensions/minimax/openclaw.plugin.json: dd8e18eeb21c16fbd2f14657596bf19bde71be7f16eb7bb917b76dfd3cb751ec
  # SHA-256 extensions/mistral/openclaw.plugin.json: 96d4cb8e74569d32f13b3db868f02457adbeeedd107f2b6917b7b81865959fc2
  # SHA-256 extensions/moonshot/openclaw.plugin.json: f82131872b07a7a47762d529421ad8b2a1a6a9a2743c25b1188e5b7dd635cde3
  # SHA-256 extensions/openai/openclaw.plugin.json: f28b87cc29867144eeef9d15dc05fa58aaf2db5ed5098e7c01189d9d2ad04048
  # SHA-256 extensions/opencode-go/openclaw.plugin.json: c815dd0230c6f63d08ec70a0fe3496d38943f50f745738b4d9f1dd656b4f83c2
  # SHA-256 extensions/opencode/openclaw.plugin.json: 4df3792a1831a1497a6c1ee900e789c23014b54262605b759d49d4390aedd765
  # SHA-256 extensions/openrouter/openclaw.plugin.json: 27607ddf251e388bf91c8a6facac37b0acad3105a7a195810864785f1de004fd
  # SHA-256 extensions/qwen/openclaw.plugin.json: 5b5be4e07392243079d5e929d84cc43b759e4b58b6d00921abbdb37fcf8233ac
  # SHA-256 extensions/xai/openclaw.plugin.json: dfcc9e3d007e8891fd72d9129ffa52340a894728b7af03a7f308e5bade681790
  # SHA-256 extensions/zai/openclaw.plugin.json: 1b0801cd6bfafc34da431a9409625df53ac48c815941403f793b2e129cf00e34
  @profiles %{
    "anthropic" => %{
      "capabilities" => ["image"],
      "defaultModels" => %{"image" => "claude-opus-5-5"},
      "autoPriority" => %{"image" => 20},
      "nativeDocumentInputs" => ["pdf"]
    },
    "clawrouter" => %{
      "capabilities" => ["audio"],
      "defaultModels" => %{"audio" => "gpt-4o-transcribe"}
    },
    "codex" => %{"capabilities" => ["image"], "defaultModels" => %{"image" => "gpt-6-astra"}},
    "deepgram" => %{
      "capabilities" => ["audio"],
      "defaultModels" => %{"audio" => "nova-3"},
      "autoPriority" => %{"audio" => 30}
    },
    "deepinfra" => %{
      "capabilities" => ["image", "audio"],
      "defaultModels" => %{
        "image" => "moonshotai/Kimi-K2.6",
        "audio" => "openai/whisper-large-v3-turbo"
      },
      "autoPriority" => %{"image" => 45, "audio" => 45}
    },
    "elevenlabs" => %{
      "capabilities" => ["audio"],
      "defaultModels" => %{"audio" => "scribe_v2"},
      "autoPriority" => %{"audio" => 45}
    },
    "google" => %{
      "capabilities" => ["image", "audio", "video"],
      "defaultModels" => %{
        "image" => "gemini-3-flash-preview",
        "audio" => "gemini-3-flash-preview",
        "video" => "gemini-3-flash-preview"
      },
      "autoPriority" => %{"image" => 30, "audio" => 40, "video" => 10},
      "nativeDocumentInputs" => ["pdf"]
    },
    "groq" => %{
      "capabilities" => ["audio"],
      "defaultModels" => %{"audio" => "whisper-large-v3-turbo"},
      "autoPriority" => %{"audio" => 20}
    },
    "minimax" => %{
      "capabilities" => ["image"],
      "defaultModels" => %{"image" => "MiniMax-VL-01"},
      "documentModels" => %{"pdf" => %{"textExtraction" => "MiniMax-M2.7", "image" => false}},
      "autoPriority" => %{"image" => 40}
    },
    "minimax-portal" => %{
      "capabilities" => ["image"],
      "defaultModels" => %{"image" => "MiniMax-VL-01"},
      "documentModels" => %{"pdf" => %{"textExtraction" => "MiniMax-M2.7", "image" => false}},
      "autoPriority" => %{"image" => 50}
    },
    "mistral" => %{
      "capabilities" => ["audio"],
      "defaultModels" => %{"audio" => "voxtral-mini-latest"},
      "autoPriority" => %{"audio" => 50}
    },
    "moonshot" => %{
      "capabilities" => ["image", "video"],
      "defaultModels" => %{"image" => "kimi-k2.6", "video" => "kimi-k2.6"},
      "autoPriority" => %{"video" => 20}
    },
    "openai" => %{
      "capabilities" => ["image", "audio"],
      "defaultModels" => %{"image" => "gpt-6-astra", "audio" => "gpt-4o-transcribe"},
      "autoPriority" => %{"image" => 20, "audio" => 20}
    },
    "opencode-go" => %{
      "capabilities" => ["image"],
      "defaultModels" => %{"image" => "kimi-k2.7-code"}
    },
    "opencode" => %{"capabilities" => ["image"], "defaultModels" => %{"image" => "minimax-m3"}},
    "openrouter" => %{
      "capabilities" => ["image", "audio"],
      "defaultModels" => %{"image" => "auto", "audio" => "openai/whisper-large-v3-turbo"},
      "autoPriority" => %{"audio" => 35}
    },
    "qwen" => %{
      "capabilities" => ["image", "video"],
      "defaultModels" => %{"image" => "qwen3.6-plus", "video" => "qwen3.6-plus"},
      "autoPriority" => %{"video" => 15}
    },
    "xai" => %{"capabilities" => ["audio"], "autoPriority" => %{"audio" => 25}},
    "zai" => %{
      "capabilities" => ["image"],
      "defaultModels" => %{"image" => "glm-4.6v"},
      "autoPriority" => %{"image" => 60}
    }
  }

  @host_profiles %{
    "openai-sub" => "codex",
    "moonshot-ai" => "moonshot",
    "moonshot-cn" => "moonshot",
    "zhipu-ai" => "zai",
    "zhipu-cn" => "zai",
    "zhipu-coding" => "zai",
    "minimax-io" => "minimax",
    "minimax-cn" => "minimax",
    "gemini" => "google",
    "minimax-portal-cn" => "minimax-portal"
  }
  @fields [
    {:capabilities, "capabilities", "capabilities", []},
    {:auto_priority, "autoPriority", "auto_priority", %{}},
    {:default_models, "defaultModels", "default_models", %{}},
    {:native_document_inputs, "nativeDocumentInputs", "native_document_inputs", []},
    {:document_models, "documentModels", "document_models", %{}}
  ]

  def revision, do: @revision

  def metadata(provider) do
    config = value(provider, :config) || %{}
    override = value(config, :media_understanding) || %{}
    override = if is_map(override), do: override, else: %{}

    profile =
      case fetch(override, "profile") do
        {:ok, selected} -> known_profile(selected)
        :error -> known_profile(value(provider, :preset)) || known_profile(value(provider, :name))
      end

    source = Map.get(@profiles, profile, %{})

    Enum.reduce(@fields, %{profile: profile}, fn {key, source_key, alias_key, default}, acc ->
      base = Map.get(source, source_key, default)

      selected =
        case fetch(override, source_key) do
          {:ok, selected} ->
            merge(base, selected)

          :error ->
            case fetch(override, alias_key) do
              {:ok, selected} -> merge(base, selected)
              :error -> base
            end
        end

      Map.put(acc, key, selected)
    end)
  end

  defp known_profile(name) when is_binary(name) do
    profile = Map.get(@host_profiles, name, name)
    if Map.has_key?(@profiles, profile), do: profile
  end

  defp known_profile(_), do: nil

  defp merge(base, override) when is_map(base) and is_map(override),
    do: Map.merge(base, stringify(override), fn _key, left, right -> merge(left, right) end)

  defp merge(_base, override), do: stringify(override)

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify(value), do: value

  defp value(map, key), do: Map.get(map, key, Map.get(map, to_string(key)))

  defp fetch(map, key) do
    case Map.fetch(map, key) do
      :error ->
        Enum.find_value(map, :error, fn {candidate, value} ->
          if to_string(candidate) == key, do: {:ok, value}
        end)

      found ->
        found
    end
  end
end

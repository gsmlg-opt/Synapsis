defmodule Synapsis.Provider.Speech.Google.Opus do
  @moduledoc "Google WAV input contract for the shared provider-owned Opus converter."

  @max_timeout 2_147_483_647

  def transcode(wav, options) when is_binary(wav) and is_list(options) do
    timeout = Keyword.get(options, :timeout_ms)

    if is_integer(timeout) and timeout > 0 and timeout <= @max_timeout do
      Synapsis.Provider.Speech.Opus.transcode(
        wav,
        options
        |> Keyword.put(:input_extension, "wav")
        |> Keyword.put(:temp_prefix, "tts-google-")
        |> Keyword.put(:timeout_ceiling, @max_timeout)
      )
    else
      {:error, :invalid_transcode_options}
    end
  rescue
    _ -> {:error, :transcode}
  end

  def transcode(_, _), do: {:error, :invalid_transcode_options}
end

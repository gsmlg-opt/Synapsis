defmodule Synapsis.Provider.MusicGeneration.Comfy do
  @moduledoc """
  Inactive explicit Comfy music workflow callback (OpenClaw 488631c).

  Requests supply exact UTF-8 `:prompt`, optional `:model` (JS-blank defaults
  to workflow), and a finite positive `:timeout_ms`. The inline workflow owns
  generation settings; lyrics, instrumental, format and duration do not change
  it. One optional `:input_images` entry supplies binary `:data`, optional MIME
  (nil defaults to image/png) and filename. Upload binds the returned name.

  Config explicitly supplies `:mode` (:local or :cloud), `:base_url`,
  string-keyed `:workflow` and `:prompt_node_id`. Cloud requires `:api_key`.
  Optional prompt/image/seed/output node bindings, headers and poll interval
  match the existing Comfy image adapter. Seed binding uses a real uniform
  integer in 0..281474976710654. `:max_audio_bytes` defaults to 16 MiB per
  output, with no image-specific 64 MiB floor; JSON responses have a 16 MiB cap.

  Only audio buckets are read, in JavaScript numeric-node/insertion/array
  order. All selected tracks retain exact bytes, history filename and trimmed
  HTTP MIME (application/octet-stream when absent), without node metadata.
  Result metadata includes prompt_id, ordered unique output_node_ids and
  input_image_count. Opaque bytes do not establish codec or playback quality.

  Call generate/2 from a supervised task. The shared Comfy workflow transport
  uses one linked HTTP owner and a single absolute deadline after preparation,
  covering upload, prompt submission, local history or cloud status/history
  polling and sequential downloads. No retries, parallel polls or request
  signal are introduced. Failure/cancellation/recovery branches are unqualified.
  No saved configuration/files/environment/discovery, public tool, background
  jobs, storage or delivery is activated.
  """

  @spec build_request(map(), map()) :: {:ok, map()} | {:error, term()}
  def build_request(request, config),
    do: Synapsis.Provider.ComfyWorkflow.build_request(request, config, :music)

  @spec generate(map(), map()) :: {:ok, map()} | {:error, term()}
  def generate(request, config),
    do: Synapsis.Provider.ComfyWorkflow.generate(request, config, :music)
end

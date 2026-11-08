defmodule Synapsis.Provider.ImageGeneration.Comfy do
  @moduledoc """
  Inactive, explicit Comfy image workflow callback protocol.

  Requests supply `:prompt`, a nonblank `:model` label and finite positive
  `:timeout_ms`. Prompt bytes survive unchanged. The model labels the result;
  the caller's graph owns all generation settings. Count, geometry, quality,
  format and provider options do not modify the graph or limit its outputs.

  Config supplies `:mode` (`:local` or `:cloud`), `:base_url`, a string-keyed
  `:workflow` map and `:prompt_node_id`. Cloud additionally requires an explicit
  `:api_key`. Optional bindings are `:prompt_input_name` (text),
  `:input_image_node_id` / `:input_image_input_name` (image),
  `:seed_node_id` / `:seed_input_name` (seed), and `:output_node_id`.
  A seed binding generates a uniform integer in 0..281474976710654.
  Optional `:headers` override the JSON/cloud defaults. `:poll_interval_ms`
  defaults to 1500; `:max_image_bytes` has a 64 MiB floor per image.

  One optional `:input_images` entry supplies exact binary `:data`,
  `:mime_type` and optional `:filename`. Upload uses multipart image/type/
  overwrite fields, then binds the uploaded name into a fresh graph. Output
  history determines filenames and image order: JavaScript integer node keys
  first, then original noninteger key order, then each image array's order.
  All selected images retain exact bytes, full trimmed HTTP Content-Type
  (octet-stream when absent), and prompt/node metadata.

  Call `generate/2` from a supervised task. After preparation, one absolute
  monotonic deadline covers one linked HTTP owner using shared Req.Finch for
  sequential upload, submission, polling, waits and downloads. JSON bodies
  have a 16 MiB cap and 30 second idle bound; binary idle bounds use remaining
  time. There are no retries, parallel polls or request-signal feature.

  This module reads no saved configuration, files, environment or credentials,
  and performs no catalog registration, tool activation, jobs, custody, storage
  or delivery.
  """

  @spec build_request(map(), map()) :: {:ok, map()} | {:error, term()}
  def build_request(request, config),
    do: Synapsis.Provider.ComfyWorkflow.build_request(request, config, :image)

  @spec generate(map(), map()) :: {:ok, map()} | {:error, term()}
  def generate(request, config),
    do: Synapsis.Provider.ComfyWorkflow.generate(request, config, :image)
end

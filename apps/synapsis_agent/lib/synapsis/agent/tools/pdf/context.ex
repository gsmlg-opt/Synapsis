defmodule Synapsis.Agent.Tools.PDF.Context do
  @moduledoc "Reference-shaped PDF inputs, domain message parts, and extraction notices."

  alias Backplane.AgentRuntime.Error
  alias Backplane.AiProtocol.ContentBlock
  alias Synapsis.Part.{Image, Text}

  @max_bytes 10 * 1024 * 1024
  @limits %{max_bytes: 32 * 1024 * 1024, max_string_bytes: 32 * 1024 * 1024, max_depth: 64}

  def normalize(arguments, config) when is_map(arguments) and is_map(config) do
    with pdfs when is_list(pdfs) <- Map.get(arguments, "pdfs", []),
         true <- Enum.all?(pdfs, &is_binary/1),
         references =
           [arguments["pdf"] | pdfs]
           |> Enum.filter(&is_binary/1)
           |> Enum.map(&String.trim/1)
           |> Enum.reject(&(&1 == ""))
           |> Enum.uniq(),
         true <-
           length(references) in 1..10 and
             Enum.all?(references, &(String.valid?(&1) and byte_size(&1) <= 4096)),
         pages = config["pdfMaxPages"] || 20,
         true <- is_integer(pages) and pages in 1..1000,
         mb = arguments["maxBytesMb"] || config["pdfMaxMb"] || 10,
         true <- is_number(mb) and mb > 0 and mb <= 10,
         bytes = floor(mb * 1024 * 1024),
         true <- bytes in 1..@max_bytes,
         {:ok, selected, truncated} <- page_range(arguments["pages"], pages),
         prompt = arguments["prompt"],
         true <-
           is_nil(prompt) or
             (is_binary(prompt) and String.valid?(prompt) and byte_size(prompt) <= 16_384),
         password = arguments["password"],
         true <-
           is_nil(password) or
             (is_binary(password) and String.valid?(password) and byte_size(password) <= 4096) do
      {:ok,
       %{
         references: references,
         prompt:
           if(is_nil(prompt) or String.trim(prompt) == "",
             do: "Analyze this PDF document.",
             else: String.trim(prompt)
           ),
         max_bytes: bytes,
         max_pages: pages,
         page_numbers: selected,
         selection_truncated: truncated,
         password: password
       }}
    else
      _ -> invalid()
    end
  end

  def normalize(_, _), do: invalid()

  def native_parts(documents, %{page_numbers: nil, password: password} = input)
      when password in [nil, ""] do
    Enum.reduce_while(documents, {:ok, []}, fn document, {:ok, parts} ->
      attrs = %{
        type: :resource,
        data: %{
          "uri" => source_uri(document.resolved_input),
          "mime_type" => "application/pdf",
          "data" => Base.encode64(document.bytes)
        },
        extensions: %{}
      }

      case ContentBlock.new(attrs, limits: @limits) do
        {:ok, block} -> {:cont, {:ok, parts ++ [block]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, parts} -> {:ok, parts ++ [%Text{content: input.prompt}]}
      error -> error
    end
  end

  def native_parts(_documents, _input),
    do:
      {:error,
       Error.new(:unsupported_capability, "Native PDF models do not support pages or password")}

  defp source_uri(path) do
    if Path.type(path) == :absolute,
      do: "file://" <> URI.encode(path, &(URI.char_unreserved?(&1) or &1 == ?/)),
      else: path
  end

  def parts(extractions, input, supports_images) do
    extractions =
      Enum.map(extractions, fn extraction ->
        if supports_images or extraction["images"] == [] do
          extraction
        else
          extraction |> Map.put("images", []) |> put_in(["metadata", "imagesTruncated"], true)
        end
      end)

    if Enum.any?(extractions, &(String.trim(&1["text"]) != "" or &1["images"] != [])) do
      limit = if input.selection_truncated, do: input.max_pages
      notices = Enum.map(extractions, &notice(&1["metadata"], limit)) |> Enum.reject(&is_nil/1)

      parts =
        Enum.with_index(extractions, 1)
        |> Enum.flat_map(fn {extraction, index} ->
          label = if length(extractions) > 1, do: "[PDF #{index} text]\n", else: "[PDF text]\n"
          note = notice(extraction["metadata"], limit)
          text = if String.trim(extraction["text"]) != "", do: wrapped(extraction["text"])

          prefix =
            if text || note,
              do: [%Text{content: label <> Enum.join(Enum.reject([note, text], &is_nil/1), "\n")}],
              else: []

          prefix ++
            Enum.map(extraction["images"], &%Image{media_type: &1["mimeType"], data: &1["data"]})
        end)

      {:ok, parts ++ [%Text{content: input.prompt}], notices}
    else
      {:error,
       Error.new(
         :unsupported_capability,
         "The configured PDF model cannot analyze the extracted document content"
       )}
    end
  end

  def notice(metadata, explicit_limit \\ nil) do
    pages = metadata["pages"]

    reasons =
      [
        if(explicit_limit, do: "requested page selection limited to #{explicit_limit} pages"),
        if(pages["truncated"],
          do:
            if(pages["selection"] == "automatic",
              do: "#{length(pages["processed"])} of #{pages["total"]} pages processed",
              else: "some requested pages omitted; #{length(pages["processed"])} pages processed"
            )
        ),
        if(metadata["textTruncated"], do: "text truncated"),
        if(metadata["imagesTruncated"], do: "image rendering truncated")
      ]
      |> Enum.reject(&is_nil/1)

    if reasons != [], do: "[Partial document: #{Enum.join(reasons, "; ")}.]"
  end

  defp wrapped(text) do
    id = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    "<<<EXTERNAL_UNTRUSTED_CONTENT id=\"#{id}\">>>\nSource: unknown\n---\n" <>
      text <> "\n<<<END_EXTERNAL_UNTRUSTED_CONTENT id=\"#{id}\">>>"
  end

  defp page_range(nil, _limit), do: {:ok, nil, false}

  defp page_range(value, limit) when is_binary(value) and byte_size(value) <= 4096 do
    if String.trim(value) == "" do
      {:ok, nil, false}
    else
      ranges =
        value
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.map(&interval/1)

      if ranges != [] and Enum.all?(ranges, &match?({:ok, _, _}, &1)) do
        merged =
          ranges
          |> Enum.map(fn {:ok, first, last} -> {first, last} end)
          |> Enum.sort()
          |> Enum.reduce([], fn
            {first, last}, [{previous, finish} | rest] when first <= finish + 1 ->
              [{previous, max(last, finish)} | rest]

            range, acc ->
              [range | acc]
          end)
          |> Enum.reverse()

        total = Enum.reduce(merged, 0, fn {first, last}, sum -> sum + last - first + 1 end)

        selected =
          Enum.reduce_while(merged, [], fn {first, last}, acc ->
            remaining = limit - length(acc)

            if remaining == 0,
              do: {:halt, acc},
              else: {:cont, acc ++ Enum.to_list(first..min(last, first + remaining - 1))}
          end)

        {:ok, selected, total > limit}
      else
        invalid()
      end
    end
  end

  defp page_range(_, _), do: invalid()

  defp interval(value) do
    case Regex.run(~r/\A(\d+)(?:\s*-\s*(\d+))?\z/, value) do
      [_, first] -> number_interval(first, first)
      [_, first, last] -> number_interval(first, last)
      _ -> :invalid
    end
  end

  defp number_interval(first, last) do
    first = String.to_integer(first)
    last = String.to_integer(last)

    if first > 0 and last >= first and last <= 9_007_199_254_740_991,
      do: {:ok, first, last},
      else: :invalid
  end

  defp invalid,
    do: {:error, Error.new(:validation, "PDF inputs or configured host limits are invalid")}
end

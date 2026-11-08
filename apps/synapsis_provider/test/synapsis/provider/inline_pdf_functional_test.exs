defmodule Synapsis.Provider.InlinePDFFunctionalTest do
  use ExUnit.Case, async: false

  alias Backplane.AiProtocol.ContentBlock
  alias Synapsis.Part.Text
  alias Synapsis.Provider.MessageMapper

  @limits %{max_bytes: 32 * 1024 * 1024, max_string_bytes: 32 * 1024 * 1024, max_depth: 64}
  @fixture Path.expand(
             "../../../../synapsis_agent/test/fixtures/openclaw/488631c/pdf-native.json",
             __DIR__
           )

  for protocol <- [:anthropic, :google] do
    @protocol protocol
    test "#{protocol} maps transient official PDF resources to the frozen native helper content in order" do
      assert_fixture(@protocol)
    end
  end

  defp assert_fixture(protocol) do
    fixture = @fixture |> File.read!() |> Jason.decode!()
    id = if protocol == :anthropic, do: "anthropic-two", else: "gemini-two"
    observation = Enum.find(fixture["observations"], &(&1["id"] == id))
    assert is_map(observation)
    input = observation["input"]
    docs = [ordinary_pdf("First report", 0), ordinary_pdf("Second report", 270_000)]
    assert byte_size(List.last(docs)) > 262_144
    encoded = Enum.map(docs, &Base.encode64/1)

    parts =
      Enum.with_index(encoded, 1)
      |> Enum.map(fn {data, index} ->
        attrs = %{
          type: :resource,
          data: %{
            "uri" => "file:///ordinary/report%20#{index}.pdf",
            "mime_type" => "application/pdf",
            "data" => data
          },
          extensions: %{}
        }

        assert {:ok, %ContentBlock{} = block} = ContentBlock.new(attrs, limits: @limits)
        assert Map.keys(block.data) |> Enum.sort() == ["data", "mime_type", "uri"]
        assert block.extensions == %{}
        block
      end)

    assert {:ok, request} =
             MessageMapper.build_request(
               protocol,
               [%{role: "user", parts: parts ++ [%Text{content: input["prompt"]}]}],
               [],
               %{
                 model: input["modelId"],
                 provider_name: "custom-native-fixture",
                 stream: true,
                 max_tokens: input["maxTokens"] || 4096
               }
             )

    expected = replace_pdf_bytes(observation["request"]["body"], encoded)

    if protocol == :anthropic do
      assert request["messages"] == expected["messages"]
      assert request["model"] == expected["model"]
      assert request["max_tokens"] == expected["max_tokens"]
    else
      assert request["contents"] == google_content(expected["contents"])
    end

    # Source URI is retained by the official value and intentionally omitted on the wire.
    assert Enum.map(parts, & &1.data["uri"]) == [
             "file:///ordinary/report%201.pdf",
             "file:///ordinary/report%202.pdf"
           ]

    refute Jason.encode!(request) =~ "file:///ordinary"
  end

  defp replace_pdf_bytes(body, encoded) do
    case body do
      %{"messages" => [message]} ->
        content =
          Enum.zip(encoded, Enum.take(message["content"], 2))
          |> Enum.map(fn {data, block} -> put_in(block, ["source", "data"], data) end)

        put_in(body, ["messages"], [
          Map.put(message, "content", content ++ [List.last(message["content"])])
        ])

      %{"contents" => [message]} ->
        parts =
          Enum.zip(encoded, Enum.take(message["parts"], 2))
          |> Enum.map(fn {data, block} -> put_in(block, ["inline_data", "data"], data) end)

        put_in(body, ["contents"], [
          Map.put(message, "parts", parts ++ [List.last(message["parts"])])
        ])
    end
  end

  defp google_content(messages),
    do:
      Enum.map(messages, fn message ->
        Map.update!(message, "parts", fn parts ->
          Enum.map(parts, fn
            %{"inline_data" => %{"mime_type" => mime, "data" => data}} ->
              %{"inlineData" => %{"mimeType" => mime, "data" => data}}

            part ->
              part
          end)
        end)
      end)

  defp ordinary_pdf(label, padding) do
    stream =
      "BT /F1 12 Tf 40 100 Td (#{label}) Tj ET\n%" <> String.duplicate("x", padding) <> "\n"

    objects = [
      "<< /Type /Catalog /Pages 2 0 R >>",
      "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
      "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
      "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
      "<< /Length #{byte_size(stream)} >>\nstream\n#{stream}endstream"
    ]

    {body, offsets} =
      Enum.with_index(objects, 1)
      |> Enum.reduce({"%PDF-1.4\n", []}, fn {object, index}, {body, offsets} ->
        {body <> "#{index} 0 obj\n#{object}\nendobj\n", offsets ++ [byte_size(body)]}
      end)

    xref =
      Enum.map_join(
        offsets,
        "",
        &(String.pad_leading(Integer.to_string(&1), 10, "0") <> " 00000 n \n")
      )

    body <>
      "xref\n0 6\n0000000000 65535 f \n" <>
      xref <> "trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n#{byte_size(body)}\n%%EOF\n"
  end
end

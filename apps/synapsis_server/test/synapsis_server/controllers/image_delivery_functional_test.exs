defmodule SynapsisServer.ImageDeliveryFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.MediaDelivery
  alias Synapsis.Provider.ImageGeneration.OpenAI
  alias Synapsis.Workspace.Media

  @moduletag :tmp_dir
  @capture Path.expand(
             "../../../../synapsis_agent/test/fixtures/openclaw/488631c/openai-image-generation.json",
             __DIR__
           )
  @images @capture
          |> File.read!()
          |> Jason.decode!()
          |> Map.fetch!("observations")
          |> Enum.find(&(&1["id"] == "ordered-inline"))
          |> get_in(["result", "images"])
          |> Enum.zip([{"png", "image/png"}, {"jpeg", "image/jpeg"}, {"webp", "image/webp"}])
          |> Enum.map(fn {image, {format, mime}} ->
            {format, mime, Base.decode64!(image["bytesBase64"])}
          end)

  setup do
    listener =
      start_supervised!(
        {Gaoxy.HTTP,
         id: __MODULE__,
         plug: {SynapsisServer.Endpoint, []},
         ip: {127, 0, 0, 1},
         port: 0,
         http_limits: %{request_timeout: 5_000}}
      )

    %{local: {:ok, {_address, port}}} = Gaoxy.info(listener, __MODULE__)
    {:ok, port: port}
  end

  test "the actual Endpoint serves exact ordered PNG JPEG WebP bytes from publication roots",
       %{tmp_dir: root, port: port} do
    session_id = Ecto.UUID.generate()

    for {format, mime, bytes} <- @images do
      media_root = Path.join(root, "original-" <> format)
      assert {:ok, descriptor} = Media.put_image(bytes, format, root: media_root)

      assert {:ok, reference} =
               MediaDelivery.publish_image(descriptor, session_id, invocation(),
                 root: media_root,
                 max_bytes: byte_size(bytes)
               )

      assert {:ok, path} = MediaDelivery.image_url(reference)
      assert [file] = Path.wildcard(Path.join(media_root, "**/*." <> format))
      before_read = File.stat!(file, time: :posix)

      for _ <- 1..2 do
        assert {:ok, response} = get_image(port, path, mime)
        assert response.status == 200
        assert response.body == bytes
        assert response.headers["content-type"] == [mime]
        assert response.headers["content-length"] == [Integer.to_string(byte_size(bytes))]
        assert response.headers["content-disposition"] == ["inline; filename=\"image.#{format}\""]
      end

      after_read = File.stat!(file, time: :posix)

      assert {after_read.inode, after_read.mtime, after_read.size} ==
               {before_read.inode, before_read.mtime, before_read.size}
    end
  end

  test "one explicit provider generation yields ordered durable image downloads",
       %{tmp_dir: root, port: port} do
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    tasks = start_supervised!({Task.Supervisor, []})
    calls = start_supervised!({Agent, fn -> 0 end})

    Gaoxy.Test.expect_once(fixture, "POST", "/v1/images/generations", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert Jason.decode!(body) == %{
               "model" => "gpt-image-2",
               "prompt" => "Three ordinary images",
               "n" => 3,
               "size" => "1024x1024"
             }

      Agent.update(calls, &(&1 + 1))

      images =
        Enum.map(@images, fn {_format, mime, bytes} ->
          %{"b64_json" => Base.encode64(bytes), "mime_type" => mime}
        end)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"data" => images}))
    end)

    generated =
      Task.Supervisor.async_nolink(tasks, fn ->
        OpenAI.generate(
          %{prompt: "Three ordinary images", model: "gpt-image-2", count: 3, timeout_ms: 5_000},
          %{base_url: Gaoxy.Test.url(fixture, "/v1"), api_key: "ordinary-image-fixture"}
        )
      end)

    assert {:ok, result} = Task.await(generated, 10_000)
    assert result.model == "gpt-image-2"
    assert Enum.map(result.images, & &1.data) == Enum.map(@images, &elem(&1, 2))
    session_id = Ecto.UUID.generate()
    operation = invocation()

    # Compose the explicit domain APIs without installing a replacement native
    # backend. Native imagegen remains blocked on its upstream contract.
    paths =
      Enum.zip(result.images, @images)
      |> Enum.map(fn {image, {format, mime, bytes}} ->
        assert image.mime_type == mime
        assert {:ok, descriptor} = Media.put_image(image.data, format, root: root)

        assert {:ok, reference} =
                 MediaDelivery.publish_image(descriptor, session_id, operation,
                   root: root,
                   max_bytes: byte_size(bytes)
                 )

        assert {:ok, path} = MediaDelivery.image_url(reference)
        {path, mime, bytes}
      end)

    assert length(Enum.uniq(Enum.map(paths, &elem(&1, 0)))) == 3

    for _ <- 1..2, {path, mime, bytes} <- paths do
      assert {:ok, response} = get_image(port, path, mime)
      assert response.status == 200
      assert response.body == bytes
    end

    assert Agent.get(calls, & &1) == 1
  end

  defp invocation do
    %{
      run_id: Ecto.UUID.generate(),
      invocation_id: Ecto.UUID.generate(),
      tool_call_id: "ordinary-image-http",
      tool_name: "image_gen::imagegen"
    }
  end

  defp get_image(port, path, mime) do
    Req.Request.new()
    |> Req.Steps.attach()
    |> Req.merge(
      method: :get,
      url: "http://127.0.0.1:#{port}" <> path,
      headers: [{"accept", mime}],
      raw: true,
      retry: false,
      redirect: false,
      receive_timeout: 5_000,
      request_timeout: 5_000
    )
    |> Req.request()
  end
end

defmodule Synapsis.Agent.ImageDeliveryFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.MediaDelivery
  alias Synapsis.Runtime.Store
  alias Synapsis.Workspace.Media

  @moduletag :tmp_dir
  @capture Path.expand("../../fixtures/openclaw/488631c/openai-image-generation.json", __DIR__)
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

  test "image references retain exact original publication facts and stored bytes", %{
    tmp_dir: root
  } do
    session_id = Ecto.UUID.generate()

    for {format, mime, bytes} <- @images do
      media_root = Path.join(root, "original-" <> format)
      bound = byte_size(bytes)
      operation = invocation("same-provider-call")

      assert {:ok, descriptor} = Media.put_image(bytes, format, root: media_root)
      assert descriptor["mime_type"] == mime

      assert {:ok, reference} =
               MediaDelivery.publish_image(descriptor, session_id, operation,
                 root: media_root,
                 max_bytes: bound
               )

      assert %{"version" => 1, "session_id" => ^session_id, "id" => id} = reference
      assert map_size(reference) == 3
      assert {:ok, ^id} = Ecto.UUID.cast(id)
      assert Jason.decode!(Jason.encode!(reference)) == reference
      assert {:ok, "/api/media/image/" <> path} = MediaDelivery.image_url(reference)
      assert path == session_id <> "/" <> id
      assert {:ok, fact} = Store.get_fact(session_id, :image_delivery, id)

      assert fact == %{
               version: 1,
               descriptor: descriptor,
               root: Path.expand(media_root),
               max_bytes: bound,
               invocation:
                 Map.take(operation, [:run_id, :invocation_id, :tool_call_id, :tool_name])
             }

      assert {:ok, %{image: ^bytes, descriptor: ^descriptor}} =
               MediaDelivery.read_image(session_id, id)

      assert {:ok, ^fact} = Store.get_fact(session_id, :image_delivery, id)
    end
  end

  test "separate invocation references survive their publishers and repeated readers", %{
    tmp_dir: root
  } do
    session_id = Ecto.UUID.generate()
    {format, _mime, bytes} = hd(@images)
    assert {:ok, descriptor} = Media.put_image(bytes, format, root: root)
    operations = [invocation("reused-call-id"), invocation("reused-call-id")]

    references =
      Enum.map(operations, fn operation ->
        publisher =
          Task.async(fn ->
            MediaDelivery.publish_image(descriptor, session_id, operation,
              root: root,
              max_bytes: byte_size(bytes)
            )
          end)

        assert {:ok, reference} = Task.await(publisher, 5_000)
        reference
      end)

    assert length(Enum.uniq(references)) == 2
    assert [file] = Path.wildcard(Path.join(root, "**/*.png"))
    before_read = File.stat!(file, time: :posix)

    for reference <- references, _ <- 1..2 do
      reader = Task.async(fn -> MediaDelivery.read_image(session_id, reference["id"]) end)

      assert {:ok, %{image: ^bytes, descriptor: ^descriptor}} = Task.await(reader, 5_000)
    end

    after_read = File.stat!(file, time: :posix)
    assert {after_read.inode, after_read.mtime} == {before_read.inode, before_read.mtime}
    assert {:ok, facts} = Store.list_facts(session_id, :image_delivery)
    assert length(facts) == 2

    assert Enum.sort(Enum.map(facts, & &1.invocation.invocation_id)) ==
             Enum.sort(Enum.map(operations, & &1.invocation_id))
  end

  defp invocation(call_id) do
    %{
      run_id: Ecto.UUID.generate(),
      invocation_id: Ecto.UUID.generate(),
      tool_call_id: call_id,
      tool_name: "image_gen::imagegen",
      arguments: %{"prompt" => "Not stored in the delivery fact"}
    }
  end
end

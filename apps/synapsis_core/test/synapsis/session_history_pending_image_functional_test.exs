defmodule Synapsis.SessionHistoryPendingImageFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Part.Image
  alias Synapsis.Session.{PendingInputStore, Store}
  alias Synapsis.SessionHistory

  @moduletag timeout: 120_000

  # A complete, CRC-valid 1x1 RGBA PNG (70 decoded bytes).
  @png "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="

  test "a real queued image prompt survives storage and source-computed pending display" do
    assert :ok = Store.ensure_started()
    id = Ecto.UUID.generate()
    assert :ok = Store.put_meta(id, %{id: id, agent: "archive", title: "Image prompt"})
    on_exit(fn -> Store.delete_session(id) end)

    content = "Describe this ordinary pixel 雪 😀"
    image = %Image{media_type: "image/png", data: @png, path: "/ordinary/history/pixel.png"}
    assert {:ok, queued} = PendingInputStore.append_prompt(id, content, [image])
    assert {:ok, [stored]} = PendingInputStore.list_result(id)
    assert stored == queued
    assert stored.image_parts == [image]
    assert {:ok, pending_id} = Ecto.UUID.cast(queued.id)
    assert pending_id == queued.id
    assert {:ok, _, 0} = DateTime.from_iso8601(queued.inserted_at)

    input = %{"limit" => 1}
    node = System.get_env("SYNAPSIS_FILESYSTEM_NODE") || System.find_executable("node")
    assert is_binary(node)

    assert {:ok, rendered} =
             SessionHistory.read_rendered(input, %{session_id: id, agent_id: "reader"},
               node_executable: node
             )

    # Portable producer facts are authored independently of the product DTO.
    source_message = %{
      "role" => "user",
      "content" => [
        %{"type" => "text", "text" => content},
        %{"type" => "image", "mimeType" => "image/png", "data" => @png, "path" => image.path}
      ]
    }

    expected = source_expected(node, id, queued, source_message)

    display_message = %{
      "role" => "user",
      "content" => [
        %{"type" => "text", "text" => content},
        %{"type" => "image", "mimeType" => "image/png", "omitted" => true, "bytes" => 70}
      ]
    }

    assert expected["projectedMessage"] == display_message
    assert rendered == %{page: expected["page"], text: expected["text"]}
    assert rendered.page["session_id"] == id

    assert rendered.page["pendingInputs"] == %{
             "items" => [
               %{
                 "id" => queued.id,
                 "state" => "queued",
                 "kind" => "prompt",
                 "acceptedAt" => queued.inserted_at,
                 "message" => display_message
               }
             ],
             "total" => 1
           }

    assert {:ok, [^stored]} = PendingInputStore.list_result(id)
  end

  defp source_expected(node, id, queued, message) do
    request = %{
      "hostId" => id,
      "message" => message,
      "item" => %{
        "id" => queued.id,
        "state" => "queued",
        "kind" => "prompt",
        "acceptedAt" => queued.inserted_at
      }
    }

    # Pin 488631c: original projectChatDisplayMessage (core.ts:620-624) delegates
    # to projectChatDisplayMessagesWithState (552-607); the original kernel uses
    # that projector on our independent portable message. Media shape is owned by
    # chat-display-projection.sanitize.ts:41-138, not this DTO/test adapter.
    # The oracle gateway supplies pending facts; it does NOT execute the source
    # pending-storage/projector owner. We explicitly feed the original kernel's
    # projection to that gateway and then run the actual factory pending bound
    # (sessions-history-tool.ts:158-190). The host kind extension and session UUID
    # rename below are the frozen public adaptation, with extended bytes counted.
    script = ~S"""
    import {pathToFileURL} from 'node:url';
    const oraclePath = process.argv[1];
    process.argv.splice(1, 1);
    const {computeSessionHistoryWindow} = await import(pathToFileURL(oraclePath).href);
    let data = '';
    for await (const chunk of process.stdin) { data += chunk; if (data.includes('\n')) break; }
    const input = JSON.parse(data.trim());
    const result = messages => ({messages, totalMessages: messages.length,
      displaySource: 'supplied-history291',
      readWindow: {source: 'supplied-history291', latestResetRawSeq: null}});
    const base = {args: {sessionKey: 'agent:main:history291', limit: 1}, max: 1};
    const projected = await computeSessionHistoryWindow({...base, id: 'pending-image-projection',
      reads: [{operation: 'recent', result: result([input.message])}],
      pendingInputs: {items: [], total: 0}});
    const [projectedMessage] = projected.preparedPage.messages;
    if (projected.preparedPage.messages.length !== 1) throw Error('ordinary image projection');
    const observation = await computeSessionHistoryWindow({...base, id: 'pending-image-page',
      reads: [{operation: 'recent', result: result([])}],
      pendingInputs: {items: [{...input.item, message: projectedMessage}], total: 1}});
    const original = JSON.parse(observation.result.content[0].text);
    const page = Object.fromEntries(Object.entries(original).map(([key, value]) =>
      [key === 'sessionKey' ? 'session_id' : key, key === 'sessionKey' ? input.hostId : value]));
    const before = Buffer.byteLength(JSON.stringify(page.pendingInputs), 'utf8');
    page.pendingInputs.items = page.pendingInputs.items.map(item => ({...item, kind: input.item.kind}));
    page.bytes += Buffer.byteLength(JSON.stringify(page.pendingInputs), 'utf8') - before;
    await new Promise((resolve, reject) => {
      process.stdout.write(JSON.stringify({page, text: JSON.stringify(page, null, 2), projectedMessage}),
        error => error ? reject(error) : resolve());
    });
    process.exit(0);
    """

    oracle =
      Path.expand("../../../../scripts/openclaw/capture-session-history-window.mjs", __DIR__)

    port =
      Port.open({:spawn_executable, node}, [
        :binary,
        :exit_status,
        :use_stdio,
        args: ["--experimental-vm-modules", "--input-type=module", "-e", script, oracle]
      ])

    assert Port.command(port, Jason.encode!(request) <> "\n")
    collect(port, "")
  end

  defp collect(port, output) do
    receive do
      {^port, {:data, chunk}} -> collect(port, output <> chunk)
      {^port, {:exit_status, 0}} -> Jason.decode!(output)
      {^port, {:exit_status, status}} -> flunk("pinned image oracle exit #{status}: #{output}")
    after
      90_000 ->
        if Port.info(port), do: Port.close(port)
        flunk("pinned image oracle did not finish")
    end
  end
end

defmodule Synapsis.SessionDirectoryProjectionFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.{Message, SessionDirectory}
  alias Synapsis.Part.Text
  alias Synapsis.Session.Store

  setup do
    assert :ok = Store.ensure_started()
    id = Ecto.UUID.generate()
    title = "projection-#{id} 雪 \"path\\file\"\t\u2028"

    assert :ok =
             Message.persist_list(
               id,
               [
                 %Message{role: "user", parts: [%Text{content: "Build the session report."}]},
                 %Message{role: "assistant", parts: [%Text{content: "# **Report** ready. 😀"}]}
               ],
               %{id: id, title: title, agent: "archive"}
             )

    on_exit(fn -> Store.delete_session(id) end)

    %{
      id: id,
      title: title,
      input: %{"search" => id},
      context: %{session_id: Ecto.UUID.generate(), agent_id: "main"},
      node: node_executable()
    }
  end

  test "each optional flag independently adds its requested source field", ctx do
    assert {:ok, %{sessions: [title_row]}} =
             SessionDirectory.list(
               Map.put(ctx.input, "include_derived_titles", true),
               ctx.context,
               node_executable: ctx.node
             )

    assert title_row.title == ctx.title
    assert title_row.derived_title == "Build the session report."
    refute Map.has_key?(title_row, :last_message_preview)

    assert {:ok, %{sessions: [preview_row]}} =
             SessionDirectory.list(
               Map.put(ctx.input, "include_last_message", true),
               ctx.context,
               node_executable: ctx.node
             )

    assert preview_row.title == ctx.title
    assert preview_row.last_message_preview == "Report ready. 😀"
    refute Map.has_key?(preview_row, :derived_title)
  end

  test "pretty JSON byte accounting equals JSON.stringify for the actual public enriched tree",
       ctx do
    assert {:ok, page} =
             SessionDirectory.list(
               Map.merge(ctx.input, %{
                 "include_derived_titles" => true,
                 "include_last_message" => true
               }),
               ctx.context,
               node_executable: ctx.node
             )

    compact = Jason.encode!(page)
    expected = javascript_pretty(ctx.node, compact)
    encoded = Jason.encode!(page, pretty: true)
    assert byte_size(encoded) == byte_size(expected)
    assert Jason.decode!(encoded) == Jason.decode!(expected)
    assert byte_size(encoded) <= 65_536
    assert String.contains?(encoded, "\n  \"")
    assert page.source == "durable"
    assert page.has_more == false
    assert hd(page.sessions).provider == nil
  end

  defp javascript_pretty(node, json) do
    script = ~S"""
    let buffer = Buffer.alloc(0);
    function read(chunk) {
      buffer = Buffer.concat([buffer, chunk]);
      const end = buffer.indexOf(10);
      if (end < 0) return;
      process.stdin.removeListener('data', read);
      const value = JSON.parse(buffer.subarray(0, end).toString('utf8'));
      process.stdout.write(JSON.stringify(value, null, 2));
      process.stdin.destroy();
    }
    process.stdin.on('data', read);
    """

    port =
      Port.open({:spawn_executable, node}, [
        :binary,
        :exit_status,
        :use_stdio,
        args: ["-e", script]
      ])

    assert Port.command(port, json <> "\n")
    collect(port, "")
  end

  defp collect(port, output) do
    receive do
      {^port, {:data, data}} -> collect(port, output <> data)
      {^port, {:exit_status, 0}} -> output
    after
      5_000 ->
        if Port.info(port), do: Port.close(port)
        flunk("ordinary JSON.stringify child did not complete")
    end
  end

  defp node_executable,
    do:
      System.get_env("SYNAPSIS_FILESYSTEM_NODE") || System.find_executable("node") ||
        System.fetch_env!("SYNAPSIS_FILESYSTEM_NODE")
end

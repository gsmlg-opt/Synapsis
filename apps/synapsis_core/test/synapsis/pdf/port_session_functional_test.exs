defmodule Synapsis.PDF.PortSessionFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.PDF.PortSession

  @moduletag timeout: 30_000

  test "starts dormant and returns actual PDF text and PNG only after clean helper exit" do
    broker = broker()
    assert %{phase: :dormant, outcome: nil, os_pid: nil} = PortSession.status(broker)
    extraction = Task.async(fn -> PortSession.extract(broker, pdf(), %{}, 15_000) end)
    pid = launched_pid(broker)
    state = :sys.get_state(broker)
    assert state.phase == :running
    assert File.exists?("/proc/#{pid}")
    port = state.port
    assert is_port(port)
    assert {:ok, result} = Task.await(extraction, 20_000)
    assert String.trim(result["text"]) == "Ordinary first page"

    assert result["metadata"] == %{
             "pages" => %{
               "processed" => [1, 2],
               "total" => 2,
               "selection" => "automatic",
               "truncated" => false
             },
             "textTruncated" => false,
             "imagesTruncated" => false
           }

    assert [_, image] = result["images"]
    assert_png(image)

    assert %{
             phase: :settled,
             outcome: :completed,
             cleanup_confirmed: true,
             exit_status: 0,
             os_pid: ^pid
           } = PortSession.status(broker)

    assert_exited(pid)
    assert Port.info(port) == nil
    assert {:ok, %{outcome: :completed}} = PortSession.cancel(broker)
    assert {:ok, %{outcome: :completed}} = PortSession.close(broker)
    assert %{outcome: :completed, exit_status: 0} = PortSession.status(broker)
  end

  test "explicit page selection retains actual PNG and total-document metadata" do
    broker = broker()
    assert {:ok, result} = PortSession.extract(broker, pdf(), %{pageNumbers: [2, 2]}, 15_000)
    assert result["text"] == ""

    assert result["metadata"]["pages"] == %{
             "processed" => [2],
             "total" => 2,
             "selection" => "explicit",
             "truncated" => false
           }

    assert [image] = result["images"]
    assert_png(image)
    assert %{cleanup_confirmed: true, exit_status: 0} = PortSession.status(broker)
  end

  test "cancels a pending small valid PDF and preserves an already completed outcome" do
    broker = broker()
    extraction = Task.async(fn -> PortSession.extract(broker, pdf(), %{}, 15_000) end)
    pid = launched_pid(broker)
    assert {:ok, status} = PortSession.cancel(broker)

    case Task.await(extraction, 5_000) do
      {:ok, result} ->
        assert status.outcome == :completed
        assert String.trim(result["text"]) == "Ordinary first page"

      {:error, :cancelled} ->
        assert status.outcome == :cancelled
    end

    assert status.cleanup_confirmed
    assert_exited(pid)
  end

  test "queued cancellation preserves a real PDF completion after the helper has exited" do
    broker = broker()
    extraction = Task.async(fn -> PortSession.extract(broker, pdf(), %{}, 15_000) end)
    pid = launched_pid(broker)

    try do
      assert :ok = :sys.suspend(broker)
      state = :sys.get_state(broker)
      assert state.phase == :running
      assert state.os_pid == pid
      assert File.exists?("/proc/#{pid}")

      cancellation = Task.async(fn -> PortSession.cancel(broker) end)

      await(fn ->
        {:messages, messages} = Process.info(broker, :messages)
        Enum.any?(messages, &match?({:"$gen_call", _, :cancel}, &1))
      end)

      assert File.exists?("/proc/#{pid}"), "helper completed before cancellation was queued"
      await(fn -> not File.exists?("/proc/#{pid}") end)
      assert_exited(pid)

      await(fn ->
        {:messages, messages} = Process.info(broker, :messages)
        Enum.any?(messages, &match?({port, {:exit_status, 0}} when port == state.port, &1))
      end)

      assert :ok = :sys.resume(broker)

      assert {:ok, %{outcome: :completed, cleanup_confirmed: true, exit_status: 0}} =
               Task.await(cancellation, 5_000)

      assert {:ok, result} = Task.await(extraction, 5_000)
      assert String.trim(result["text"]) == "Ordinary first page"
      assert [_, image] = result["images"]
      assert_png(image)

      assert %{outcome: :completed, cleanup_confirmed: true, exit_status: 0} =
               PortSession.status(broker)

      assert Port.info(state.port) == nil
    after
      if Process.alive?(broker), do: :sys.resume(broker)
    end
  end

  test "owner departure cleans up the owned helper and stops the broker" do
    owner =
      spawn(fn ->
        receive do
          :finish -> :ok
        end
      end)

    broker = broker(owner)
    monitor = Process.monitor(broker)

    spawn(fn ->
      try do
        PortSession.extract(broker, pdf(), %{}, 15_000)
      catch
        :exit, _ -> :ok
      end
    end)

    pid = launched_pid(broker)
    send(owner, :finish)
    assert_receive {:DOWN, ^monitor, :process, ^broker, :normal}, 5_000
    assert_exited(pid)
  end

  test "broker termination closes Port stdin and the actual owned helper disappears" do
    broker = broker()

    spawn(fn ->
      try do
        PortSession.extract(broker, pdf(), %{}, 15_000)
      catch
        :exit, _ -> :ok
      end
    end)

    pid = launched_pid(broker)
    Process.exit(broker, :kill)
    await(fn -> not File.exists?("/proc/#{pid}") end)
    assert_exited(pid)
  end

  defp broker(owner \\ self()) do
    root = Path.expand("../../../../..", __DIR__)

    start_supervised!(
      {PortSession,
       owner_pid: owner,
       node_executable: System.find_executable("node"),
       helper_path: Path.join(root, "packages/tool-host/src/pdf/stdio.mjs")}
    )
  end

  defp launched_pid(broker) do
    await(fn -> is_integer(PortSession.status(broker).os_pid) end)
    PortSession.status(broker).os_pid
  end

  defp await(predicate, remaining \\ 400) do
    cond do
      predicate.() ->
        :ok

      remaining == 0 ->
        flunk("owned helper lifecycle did not settle")

      true ->
        Process.sleep(10)
        await(predicate, remaining - 1)
    end
  end

  defp assert_exited(pid),
    do: refute(File.exists?("/proc/#{pid}"), "owned helper #{pid} still exists")

  defp assert_png(image) do
    assert %{"type" => "image", "mimeType" => "image/png", "data" => data} = image

    assert <<137, 80, 78, 71, 13, 10, 26, 10, _::binary-size(8), 192::32, 96::32, _::binary>> =
             Base.decode64!(data)
  end

  # Independent plain PDF objects and byte-exact xref; no extractor generates it.
  defp pdf do
    first = "BT /F1 6 Tf 4 60 Td (Ordinary first page) Tj ET"
    second = "0 0 1 rg 0 0 144 72 re f"

    objects = [
      "<< /Type /Catalog /Pages 2 0 R >>",
      "<< /Type /Pages /Count 2 /Kids [4 0 R 6 0 R] >>",
      "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
      "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 144 72] /Resources << /Font << /F1 3 0 R >> >> /Contents 5 0 R >>",
      "<< /Length #{byte_size(first)} >>\nstream\n#{first}\nendstream",
      "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 144 72] /Resources << /Font << /F1 3 0 R >> >> /Contents 7 0 R >>",
      "<< /Length #{byte_size(second)} >>\nstream\n#{second}\nendstream"
    ]

    {document, offsets} =
      Enum.with_index(objects, 1)
      |> Enum.reduce({"%PDF-1.4\n", []}, fn {object, index}, {document, offsets} ->
        {document <> "#{index} 0 obj\n#{object}\nendobj\n", offsets ++ [byte_size(document)]}
      end)

    entries =
      Enum.map_join(offsets, "", fn offset ->
        String.pad_leading(Integer.to_string(offset), 10, "0") <> " 00000 n \n"
      end)

    document <>
      "xref\n0 8\n0000000000 65535 f \n" <>
      entries <> "trailer\n<< /Size 8 /Root 1 0 R >>\nstartxref\n#{byte_size(document)}\n%%EOF\n"
  end
end

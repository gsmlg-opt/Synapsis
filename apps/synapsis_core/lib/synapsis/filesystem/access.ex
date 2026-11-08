defmodule Synapsis.Filesystem.Access do
  @moduledoc """
  Node-local admission of complete physical path sets.

  The calling worker reserves before resolving paths. Only the monitored guardian's
  actual exit releases its admission; worker results and deadlines are not releases.
  This process performs bookkeeping only, never filesystem I/O or callbacks.
  """

  use GenServer

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :temporary}
  end

  def start_link(opts \\ []) do
    opts = opts |> Keyword.take([:name]) |> Keyword.put_new(:name, __MODULE__)
    GenServer.start_link(__MODULE__, nil, opts)
  end

  def reserve(owner_pid, deadline), do: reserve(owner_pid, deadline, Process.whereis(__MODULE__))

  def reserve(owner_pid, deadline, server)
      when is_pid(owner_pid) and is_integer(deadline) and is_pid(server) do
    call(server, {:reserve, owner_pid, deadline}, deadline)
  end

  def reserve(_, _, _), do: {:error, :unavailable}

  def acquire({__MODULE__, server, ref, deadline}, keys)
      when is_pid(server) and is_reference(ref) and is_integer(deadline) do
    with {:ok, keys} <- absolute_keys(keys),
         do: call(server, {:acquire, ref, keys}, deadline)
  end

  def acquire(_, _), do: {:error, :invalid_lease}

  def check({__MODULE__, server, ref, deadline}, keys)
      when is_pid(server) and is_reference(ref) and is_integer(deadline) do
    with {:ok, keys} <- absolute_keys(keys),
         do: call(server, {:check, ref, keys}, deadline)
  end

  def check(_, _), do: {:error, :invalid_lease}

  defp call(server, request, deadline) do
    case deadline - System.monotonic_time(:millisecond) do
      timeout when timeout > 0 ->
        try do
          result = GenServer.call(server, request, timeout)
          if deadline > System.monotonic_time(:millisecond), do: result, else: {:error, :timeout}
        catch
          :exit, {:timeout, _} -> {:error, :timeout}
          :exit, _ -> {:error, :unavailable}
        end

      _ ->
        {:error, :timeout}
    end
  end

  defp absolute_keys(keys) when is_list(keys) do
    if Enum.all?(keys, fn key ->
         is_binary(key) and String.valid?(key) and not String.contains?(key, "\0") and
           Path.type(key) == :absolute and Path.expand(key) == key
       end),
       do: {:ok, keys |> Enum.uniq() |> Enum.sort()},
       else: {:error, :invalid_input}
  end

  defp absolute_keys(_), do: {:error, :invalid_input}

  @impl true
  def init(nil), do: {:ok, []}

  @impl true
  def handle_call({:reserve, owner, deadline}, {worker, _}, admissions) do
    if deadline > System.monotonic_time(:millisecond) and Process.alive?(owner) do
      ref = make_ref()
      monitor = Process.monitor(owner)
      remaining = max(0, deadline - System.monotonic_time(:millisecond))
      timer = Process.send_after(self(), {:expire, ref}, remaining)

      entry = %{
        ref: ref,
        monitor: monitor,
        timer: timer,
        owner_pid: owner,
        worker_pid: worker,
        deadline: deadline,
        keys: nil,
        waiter: nil,
        granted: false,
        expired: false
      }

      {:reply, {:ok, {__MODULE__, self(), ref, deadline}}, admissions ++ [entry]}
    else
      {:reply, {:error, :timeout}, admissions}
    end
  end

  def handle_call({:acquire, ref, keys}, {worker, _} = from, admissions) do
    case Enum.find(admissions, &(&1.ref == ref)) do
      %{worker_pid: ^worker, keys: nil} = entry ->
        if current?(entry) do
          admissions = replace(admissions, %{entry | keys: keys, waiter: from})
          {admissions, replies} = schedule(admissions)
          Enum.each(replies, fn {waiter, reply} -> GenServer.reply(waiter, reply) end)
          {:noreply, admissions}
        else
          {:reply, {:error, :timeout}, admissions}
        end

      _ ->
        {:reply, {:error, :invalid_lease}, admissions}
    end
  end

  def handle_call({:check, ref, keys}, {worker, _}, admissions) do
    result =
      case Enum.find(admissions, &(&1.ref == ref)) do
        %{worker_pid: ^worker, granted: true} = entry ->
          cond do
            not current?(entry) ->
              {:error, :timeout}

            Enum.all?(keys, &(&1 in entry.keys)) ->
              {:ok, Map.take(entry, [:owner_pid, :worker_pid, :deadline])}

            true ->
              {:error, :invalid_lease}
          end

        _ ->
          {:error, :invalid_lease}
      end

    {:reply, result, admissions}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _owner, _reason}, admissions) do
    {retired, live} = Enum.split_with(admissions, &(&1.monitor == monitor))

    Enum.each(retired, fn entry ->
      Process.cancel_timer(entry.timer)
      if entry.waiter, do: GenServer.reply(entry.waiter, {:error, :unavailable})
    end)

    {live, replies} = schedule(live)
    Enum.each(replies, fn {waiter, reply} -> GenServer.reply(waiter, reply) end)
    {:noreply, live}
  end

  def handle_info({:expire, ref}, admissions) do
    admissions =
      Enum.map(admissions, fn
        %{ref: ^ref} = entry ->
          if entry.waiter, do: GenServer.reply(entry.waiter, {:error, :timeout})
          # Keep even unresolved/expired admissions until actual owner DOWN.
          %{entry | expired: true, waiter: nil}

        entry ->
          entry
      end)

    {:noreply, admissions}
  end

  defp replace(admissions, entry),
    do: Enum.map(admissions, &if(&1.ref == entry.ref, do: entry, else: &1))

  defp current?(entry),
    do:
      not entry.expired and entry.deadline > System.monotonic_time(:millisecond) and
        Process.alive?(entry.owner_pid)

  defp schedule(admissions) do
    live_owners =
      admissions |> Enum.filter(&Process.alive?(&1.owner_pid)) |> MapSet.new(& &1.owner_pid)

    grant(admissions, System.monotonic_time(:millisecond), live_owners)
  end

  # A known waiting set is a barrier too, preventing overlapping later arrivals
  # from overtaking it. Unresolved earlier identities conservatively block all.
  defp grant(admissions, now, live_owners) do
    {entries, replies} =
      Enum.reduce(admissions, {[], []}, fn entry, {earlier, replies} ->
        blocked = Enum.any?(earlier, &intersect?(&1.keys, entry.keys))

        current =
          not entry.expired and entry.deadline > now and
            MapSet.member?(live_owners, entry.owner_pid)

        if entry.waiter != nil and current and not blocked do
          {[%{entry | granted: true, waiter: nil} | earlier], [{entry.waiter, :ok} | replies]}
        else
          {[entry | earlier], replies}
        end
      end)

    {Enum.reverse(entries), Enum.reverse(replies)}
  end

  defp intersect?(nil, _), do: true
  defp intersect?(_, nil), do: true

  defp intersect?(left, right) do
    Enum.any?(left, fn a ->
      a = Path.split(a)

      Enum.any?(right, fn b ->
        b = Path.split(b)
        List.starts_with?(a, b) or List.starts_with?(b, a)
      end)
    end)
  end
end

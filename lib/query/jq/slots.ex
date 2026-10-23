defmodule Query.Jq.Slots do
  @moduledoc """
  Limits how many jq workers run at once on this machine (`:jq_max_workers`, default
  2). The default matched the vCPU count of the machines production ran when it was
  set; production now runs one vCPU and keeps 2, so two workers share it. Each worker
  may use up to its memory limit, so this also bounds jq's total memory (2 x 256 MiB
  on Linux). A slot is held by the process that acquired it until it releases the
  slot or exits. A caller waits up to the jq time limit for a slot; its worker then
  gets the full limit.
  """

  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Waits up to `timeout_ms` for a slot. Returns `{:ok, slot}` or `{:error, :busy}`.
  On a node without this server (test peers run only Storage) returns `{:ok, nil}`.
  """
  def acquire(timeout_ms) do
    case GenServer.whereis(__MODULE__) do
      nil -> {:ok, nil}
      server -> GenServer.call(server, {:acquire, self(), timeout_ms}, :infinity)
    end
  end

  def release(nil), do: :ok

  def release(slot) do
    GenServer.cast(__MODULE__, {:release, slot})
  end

  @doc false
  def held do
    GenServer.call(__MODULE__, :held)
  end

  @impl true
  def init(_opts) do
    {:ok, %{holders: %{}, waiting: :queue.new()}}
  end

  @impl true
  def handle_call({:acquire, pid, timeout_ms}, from, state) do
    if map_size(state.holders) < max_workers() do
      monitor = Process.monitor(pid)
      {:reply, {:ok, monitor}, %{state | holders: Map.put(state.holders, monitor, pid)}}
    else
      wait_ref = make_ref()
      timer = Process.send_after(self(), {:expire, wait_ref}, max(timeout_ms, 0))
      waiting = :queue.in({wait_ref, from, pid, timer}, state.waiting)
      {:noreply, %{state | waiting: waiting}}
    end
  end

  def handle_call(:held, _from, state) do
    {:reply, map_size(state.holders), state}
  end

  @impl true
  def handle_cast({:release, monitor}, state) do
    Process.demonitor(monitor, [:flush])
    {:noreply, state |> remove_holder(monitor) |> grant_waiting()}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    {:noreply, state |> remove_holder(monitor) |> grant_waiting()}
  end

  def handle_info({:expire, wait_ref}, state) do
    {expired, waiting} =
      Enum.split_with(:queue.to_list(state.waiting), fn {ref, _, _, _} -> ref == wait_ref end)

    Enum.each(expired, fn {_, from, _, _} -> GenServer.reply(from, {:error, :busy}) end)
    {:noreply, %{state | waiting: :queue.from_list(waiting)}}
  end

  # A slot is the monitor reference on its holder. A waiter that died is granted a
  # slot anyway; its monitor fires at once and frees it again.
  defp remove_holder(state, monitor), do: %{state | holders: Map.delete(state.holders, monitor)}

  defp grant_waiting(state) do
    if map_size(state.holders) < max_workers() do
      case :queue.out(state.waiting) do
        {{:value, {_ref, from, pid, timer}}, waiting} ->
          Process.cancel_timer(timer)
          monitor = Process.monitor(pid)
          GenServer.reply(from, {:ok, monitor})

          grant_waiting(%{
            state
            | waiting: waiting,
              holders: Map.put(state.holders, monitor, pid),
          })

        {:empty, _} ->
          state
      end
    else
      state
    end
  end

  defp max_workers do
    Application.get_env(:guardian, :jq_max_workers, 2)
  end
end

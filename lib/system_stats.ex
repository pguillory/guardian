defmodule SystemStats do
  use GenServer
  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, opts)
  end

  # State: `failing`, whether the last write failed (see `record_tick/1`).
  def init(_opts) do
    timestamp_ms = System.monotonic_time(:millisecond)
    timestamp_ms = timestamp_ms - rem(timestamp_ms, 1000)
    :ok = send_next_tick(timestamp_ms)
    {:ok, %{failing: false}}
  end

  def handle_info({:tick, timestamp_ms}, state) do
    state = record_tick(state)
    :ok = send_next_tick(timestamp_ms)
    {:noreply, state}
  end

  def send_next_tick(timestamp_ms) do
    next_timestamp_ms = timestamp_ms + 1000
    interval_ms = next_timestamp_ms - System.monotonic_time(:millisecond)

    if interval_ms >= 0 do
      Process.send_after(self(), {:tick, next_timestamp_ms}, interval_ms)
      :ok
    else
      send_next_tick(next_timestamp_ms)
    end
  end

  @doc "Writes one system_stats event now. Raises if the write fails."
  def record_metrics do
    Engine.log_event("system_stats", metrics())
    :ok
  end

  # A write that fails (Storage restarting, say) is skipped rather than crashing this
  # process every second, which would use up Main's restart budget while Storage
  # recovers. The failure is logged once, and so is the recovery.
  defp record_tick(state) do
    case Engine.try_log_event("system_stats", metrics()) do
      {:ok, _event} ->
        if state.failing, do: Logger.info("SystemStats: recording system_stats again")
        %{state | failing: false}

      {:error, kind} ->
        unless state.failing do
          Logger.warning(
            "SystemStats: could not record system_stats (#{kind}); " <>
              "skipping until a write succeeds"
          )
        end

        %{state | failing: true}
    end
  end

  def metrics do
    memory_stats = :erlang.memory() |> Enum.map(fn {key, value} -> {:"memory_#{key}", value} end)

    {context_switches, 0} = :erlang.statistics(:context_switches)

    {total_exact_reductions, exact_reductions_since_last_call} =
      :erlang.statistics(:exact_reductions)

    {number_of_gcs, words_reclaimed, 0} = :erlang.statistics(:garbage_collection)
    {{:input, io_input}, {:output, io_output}} = :erlang.statistics(:io)
    {total_reductions, reductions_since_last_call} = :erlang.statistics(:reductions)
    run_queue = :erlang.statistics(:run_queue)
    {total_run_time, time_since_last_call} = :erlang.statistics(:runtime)
    total_active_tasks = :erlang.statistics(:total_active_tasks)
    total_active_tasks_all = :erlang.statistics(:total_active_tasks_all)
    total_run_queue_lengths = :erlang.statistics(:total_run_queue_lengths)
    total_run_queue_lengths_all = :erlang.statistics(:total_run_queue_lengths_all)
    {total_wallclock_time, wallclock_time_since_last_call} = :erlang.statistics(:wall_clock)

    erlang_stats = [
      timestamp: Timestamp.now(),
      host: Utils.hostname(),
      context_switches: context_switches,
      total_exact_reductions: total_exact_reductions,
      exact_reductions_since_last_call: exact_reductions_since_last_call,
      number_of_gcs: number_of_gcs,
      words_reclaimed: words_reclaimed,
      io_input: io_input,
      io_output: io_output,
      total_reductions: total_reductions,
      reductions_since_last_call: reductions_since_last_call,
      run_queue: run_queue,
      total_run_time: total_run_time,
      time_since_last_call: time_since_last_call,
      total_active_tasks: total_active_tasks,
      total_active_tasks_all: total_active_tasks_all,
      total_run_queue_lengths: total_run_queue_lengths,
      total_run_queue_lengths_all: total_run_queue_lengths_all,
      total_wallclock_time: total_wallclock_time,
      wallclock_time_since_last_call: wallclock_time_since_last_call,
      atom_count: :erlang.system_info(:atom_count),
      atom_limit: :erlang.system_info(:atom_limit),
      ets_count: :erlang.system_info(:ets_count),
      ets_limit: :erlang.system_info(:ets_limit),
      port_count: :erlang.system_info(:port_count),
      port_limit: :erlang.system_info(:port_limit),
      process_count: :erlang.system_info(:process_count),
      process_limit: :erlang.system_info(:process_limit),
    ]

    memory_stats ++ erlang_stats
  end
end

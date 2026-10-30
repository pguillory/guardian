defmodule Guardian.Counters.Restarter do
  @moduledoc """
  Owns the disposable counter subtree without propagating its failures to Guardian.Application.
  Recovery starts after 15 seconds, doubles up to four minutes, and resets after
  one healthy minute. This process handles no counter requests or event data.
  """
  use GenServer, shutdown: :infinity
  require Logger

  @initial_delay_ms 15_000
  @max_delay_ms 240_000
  @healthy_interval_ms 60_000

  @doc """
  Starts the restarter, named `:name` (default `Guardian.Counters.Restarter`), and
  with it the counter supervisor, started with the `:counters` options. Invalid
  counter options stop it with `:invalid_options`; any other startup failure is
  retried with backoff. `:initial_delay_ms`, `:max_delay_ms` and
  `:healthy_interval_ms` override the timings in the moduledoc, for tests.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    initial_delay = Keyword.get(opts, :initial_delay_ms, @initial_delay_ms)

    state = %{
      counters: Keyword.get(opts, :counters, []),
      initial_delay: initial_delay,
      next_delay: initial_delay,
      max_delay: Keyword.get(opts, :max_delay_ms, @max_delay_ms),
      healthy_interval: Keyword.get(opts, :healthy_interval_ms, @healthy_interval_ms),
      subtree: nil,
      retry_timer: nil,
      healthy_timer: nil,
    }

    case start_counters(state) do
      {:ok, pid} ->
        {:ok, watch(state, pid)}

      {:error, reason} ->
        # Invalid explicit configuration must still refuse application startup.
        # Other failures (including names held by a dying prior generation) retry;
        # never adopt a subtree whose OTP parent is the previous Restarter.
        if invalid_options?(reason),
          do: {:stop, :invalid_options},
          else: {:ok, retry(state, reason)}
    end
  end

  @impl true
  def handle_info({:EXIT, pid, reason}, %{subtree: pid} = state) when is_pid(pid) do
    if state.healthy_timer, do: Process.cancel_timer(state.healthy_timer)
    {:noreply, retry(%{state | subtree: nil, healthy_timer: nil}, reason)}
  end

  def handle_info({:timeout, ref, :retry}, %{retry_timer: ref} = state) when is_reference(ref) do
    state = %{state | retry_timer: nil}

    case start_counters(state) do
      {:ok, pid} ->
        Logger.info("Counters: subtree recovered")
        {:noreply, watch(state, pid)}

      {:error, reason} ->
        {:noreply, retry(state, reason)}
    end
  end

  def handle_info({:timeout, ref, :healthy}, %{healthy_timer: ref} = state)
      when is_reference(ref) do
    {:noreply, %{state | next_delay: state.initial_delay, healthy_timer: nil}}
  end

  def handle_info(_message, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    # Orderly termination stops the owned subtree before this owner exits.
    # Its orderly EXIT cannot reach a later logging/retry callback.
    if state.subtree, do: Supervisor.stop(state.subtree, :shutdown, :infinity)
    :ok
  catch
    # The subtree was already gone.
    :exit, _ -> :ok
  end

  @impl true
  def format_status(status) do
    status
    |> Map.put(:state, :redacted)
    |> Map.put(:message, :redacted)
    |> Map.put(:log, [])
    |> Map.put(:reason, :redacted)
  end

  defp watch(state, pid) do
    %{
      state
      | subtree: pid,
        healthy_timer: :erlang.start_timer(state.healthy_interval, self(), :healthy),
    }
  end

  defp retry(state, reason) do
    Logger.error(
      "Counters: subtree unavailable (#{reason_kind(reason)}); retry in #{state.next_delay} ms"
    )

    %{
      state
      | retry_timer: :erlang.start_timer(state.next_delay, self(), :retry),
        next_delay: min(state.max_delay, state.next_delay * 2),
    }
  end

  defp start_counters(state) do
    Guardian.Counters.Supervisor.start_link(state.counters)
  catch
    # This process's whole job: counters are advisory, and a crash loop in them must not
    # reach Guardian.Application's restart limit.
    _, _ -> {:error, :start_failed}
  end

  defp invalid_options?(:invalid_options) do
    true
  end

  defp invalid_options?({:shutdown, {:failed_to_start_child, _id, reason}}) do
    invalid_options?(reason)
  end

  defp invalid_options?(_) do
    false
  end

  # Arbitrary exit/startup reasons can contain event values or configuration.
  defp reason_kind(reason) when reason in [:normal, :shutdown, :killed, :noproc] do
    reason
  end

  defp reason_kind({:shutdown, {:failed_to_start_child, _, _}}) do
    :start_or_process_failure
  end

  defp reason_kind({:shutdown, _}) do
    :shutdown
  end

  defp reason_kind(_) do
    :start_or_process_failure
  end
end

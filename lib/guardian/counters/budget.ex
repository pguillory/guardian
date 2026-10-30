defmodule Guardian.Counters.Budget do
  @moduledoc """
  Internal failed-wait reservations, deadline enforcement and owner cooldowns for Counters.Client.

  The GenServer owns only cooldown lifecycle and housekeeping. Admission and
  settlement use atomics and ETS directly, never its mailbox.
  """
  use GenServer
  alias Guardian.Counters.Clock
  alias Guardian.Counters.Context

  # Microsecond durations in Clock's coordinate, like Context's timeout_us.
  @batch_allowance_us 250_000
  @minimum_us 10_000
  @suspect_timeout_us 25_000
  @cooldown_us 1_000_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def new_batch do
    batch = :atomics.new(1, [])
    :atomics.put(batch, 1, @batch_allowance_us)
    batch
  end

  @doc false
  @spec reserve(Context.t(), node()) :: {:ok, integer(), integer()} | :exhausted | :cooldown
  def reserve(%Context{} = event, owner) do
    if available?(event.cooldown_table, owner) do
      started = Clock.now()

      case reserve_allowance(event.batch, min(event.timeout_us, event.deadline - started)) do
        :exhausted -> :exhausted
        reserved -> {:ok, started, reserved}
      end
    else
      :cooldown
    end
  end

  @doc false
  @spec refund(Context.t(), integer()) :: :ok
  def refund(%Context{} = event, reserved) do
    :atomics.add(event.batch, 1, reserved)
  end

  @doc false
  @spec settle(term(), node(), Context.t(), integer(), integer(), integer()) :: term()
  def settle(result, owner, %Context{} = event, started, reserved, completed) do
    # Unwrap the pipeline once. A successful value can itself contain error tuples.
    responses =
      case result do
        {:ok, responses} -> responses
        error -> [error]
      end

    failed = Enum.any?(responses, &failed?/1)
    charged = if failed, do: min(reserved, max(0, completed - started)), else: 0
    refund(event, reserved - charged)
    if Enum.any?(responses, &suspect?(&1, reserved)), do: suspect(event.cooldown_table, owner)
  end

  defp reserve_allowance(_batch, allowance) when allowance < @minimum_us do
    :exhausted
  end

  defp reserve_allowance(batch, allowance) do
    remaining = :atomics.get(batch, 1)
    take = min(remaining, allowance)

    cond do
      take < @minimum_us -> :exhausted
      :atomics.compare_exchange(batch, 1, remaining, remaining - take) == :ok -> take
      true -> reserve_allowance(batch, allowance)
    end
  end

  defp failed?({:error, :conflict}) do
    false
  end

  defp failed?({:error, _}) do
    true
  end

  defp failed?(_) do
    false
  end

  defp suspect?({:error, :timeout}, allowance) do
    allowance >= @suspect_timeout_us
  end

  defp suspect?({:error, :unavailable}, _) do
    true
  end

  defp suspect?(_, _) do
    false
  end

  defp available?(table, owner) do
    case :ets.lookup(table, owner) do
      [{^owner, until}] -> until <= Clock.now()
      [] -> true
    end
  catch
    :error, :badarg -> false
  end

  defp suspect(table, owner) do
    if owner in [node() | Node.list()],
      do: :ets.insert(table, {owner, Clock.now() + @cooldown_us})
  catch
    :error, :badarg -> :ok
  end

  @impl true
  def init(opts) do
    table = Keyword.get(opts, :name, __MODULE__)

    :ets.new(table, [:named_table, :public, :set, read_concurrency: true, write_concurrency: true])

    :net_kernel.monitor_nodes(true)
    Process.send_after(self(), :cleanup, 1_000)
    {:ok, table}
  end

  @impl true
  def handle_info(:cleanup, table) do
    cleanup(table)
    Process.send_after(self(), :cleanup, 1_000)
    {:noreply, table}
  end

  def handle_info({kind, _node}, table) when kind in [:nodeup, :nodedown] do
    cleanup(table)
    {:noreply, table}
  end

  def handle_info(_, table) do
    {:noreply, table}
  end

  defp cleanup(table) do
    members = [node() | Node.list()]

    for {member, until} <- :ets.tab2list(table),
        member not in members or until <= Clock.now(),
        do: :ets.delete_object(table, {member, until})
  end

  @impl true
  def format_status(status) do
    status
    |> Map.put(:state, :redacted)
    |> Map.put(:message, :redacted)
    |> Map.put(:log, [])
    |> Map.put(:reason, :redacted)
  end
end

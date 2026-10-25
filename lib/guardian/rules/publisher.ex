defmodule Guardian.Rules.Publisher do
  @moduledoc """
  Internal synchronous owner of activation, publication and the generated-module
  pool. Call only from Server's scrubbed callbacks; Server forwards reclamation
  messages and timers target that calling process. There is no separate process.
  State contains only module atoms and retirement statuses, never sources, plans
  or diagnostics (Server's generic struct redaction passes this value through).

  Compiled modules are never reloaded in place: each change compiles into a free
  name of Compiler's pool. A module the published map stops using is retired,
  and 30 s later (rows run under a 1 s limit, so no caller can still hold it)
  deleted and soft-purged; its name returns to the pool only once the purge
  succeeds. On a restart, names in the published map are in use and any other
  loaded name is retired. Prior plans live only in published modules and are
  recovered through plan/0, without a separate history/cache of plans.
  """

  require Logger

  alias Guardian.Rules

  @reclaim_after_ms 30_000
  @reclaim_retry_ms 5_000

  defstruct free: [], retired: %{}

  # Rebuild on boot or Server restart. Published names remain reserved even while
  # the store is unreachable; unpublished current or old code must retire first.
  def new(published) do
    in_use = published |> Map.values() |> Enum.filter(&is_atom/1) |> MapSet.new()
    reserve_pool(%__MODULE__{}, in_use)
  end

  # Rebuilds the pool from what is loaded: names in use stay in use, any other loaded
  # name (left by an earlier instance of this process) is retired, never reused while
  # loaded; the rest are free.
  defp reserve_pool(state, in_use) do
    {loaded, free} =
      Guardian.Rules.Compiler.names()
      |> Enum.reject(&(&1 in in_use))
      |> Enum.split_with(&(:code.is_loaded(&1) != false or :erlang.check_old_code(&1)))

    Enum.each(loaded, &schedule_reclaim(&1, @reclaim_after_ms))
    %{state | free: free, retired: Map.new(loaded, &{&1, :pending})}
  end

  ## Activation

  def activate(state, preparation) do
    published = Rules.published() || %{}
    previous = published_plans(published)
    selected = Guardian.Rules.Activation.select(preparation, previous)
    errors = activation_errors(preparation, selected)
    log_errors(errors)

    {targets, to_compile} =
      Enum.reduce(selected.tables, {%{}, []}, fn {table, result}, {targets, to_compile} ->
        current = Map.get(published, table)

        case result do
          {:ok, plan} ->
            if is_atom(current) and current != nil and current.hash() == plan.hash do
              {Map.put(targets, table, current), to_compile}
            else
              {targets, [plan | to_compile]}
            end

          {:error, errors} ->
            {Map.put(targets, table, {:invalid, invalid_message(errors)}), to_compile}
        end
      end)

    case compile_all(state, Enum.reverse(to_compile), []) do
      {:ok, compiled, free} ->
        tables =
          Enum.reduce(compiled, targets, fn {plan, module}, acc ->
            Map.put(acc, plan.table, module)
          end)

        Rules.publish(tables)

        in_use = tables |> Map.values() |> Enum.filter(&is_atom/1) |> MapSet.new()

        retiring =
          published
          |> Map.values()
          |> Enum.filter(&(is_atom(&1) and &1 not in in_use))
          |> Enum.uniq()

        Enum.each(retiring, &schedule_reclaim(&1, @reclaim_after_ms))
        retired = Enum.reduce(retiring, state.retired, &Map.put(&2, &1, :pending))

        {:ok, %{state | free: free, retired: retired}, errors}

      {:error, message} ->
        {:error, message, errors}
    end
  end

  # Published modules are the sole source of truth, also after a Server restart.
  # The fixed pool bounds metadata lifetime; no per-reload registry accumulates.
  defp published_plans(published) do
    for {table, module} <- published, is_atom(module), into: %{}, do: {table, module.plan()}
  end

  defp activation_errors(preparation, selected) do
    selected_errors =
      Enum.flat_map(selected.tables, fn
        {_table, {:error, errors}} -> errors
        _ -> []
      end)

    (preparation.errors ++ selected_errors)
    |> Enum.uniq()
    |> Enum.sort_by(&{&1.file, &1.line || 0, &1.kind})
  end

  defp compile_all(state, [], compiled) do
    {:ok, compiled, state.free}
  end

  defp compile_all(%{free: []}, [_ | _], compiled) do
    discard(compiled)
    {:error, "no free rule module names; retrying on the next poll"}
  end

  defp compile_all(%{free: [module | free]} = state, [plan | plans], compiled) do
    case Guardian.Rules.Compiler.compile(module, plan) do
      :ok ->
        compile_all(%{state | free: free}, plans, [{plan, module} | compiled])

      {:error, kind} ->
        discard([{plan, module} | compiled])
        {:error, "compiling the rules for #{plan.table} failed (#{kind})"}
    end
  end

  # Unloads modules that were compiled but never published (nothing has called them),
  # so their names, still in the caller's free list, can be used again.
  defp discard(compiled) do
    Enum.each(compiled, fn {_plan, module} ->
      :code.delete(module)
      :code.purge(module)
    end)
  end

  defp invalid_message([first | rest]) do
    case rest do
      [] -> first.message
      _ -> "#{first.message} (and #{length(rest)} more)"
    end
  end

  ## Reclaiming retired modules

  defp schedule_reclaim(module, @reclaim_after_ms) do
    after_ms = Application.get_env(:guardian, :rules_reclaim_after_ms, @reclaim_after_ms)
    Process.send_after(self(), {:reclaim, module}, after_ms)
  end

  defp schedule_reclaim(module, after_ms) do
    Process.send_after(self(), {:reclaim, module}, after_ms)
  end

  def reclaim(state, module) do
    case Map.get(state.retired, module) do
      nil ->
        state

      status ->
        # Delete once (making the code old), then soft-purge until no process runs it.
        if status == :pending, do: :code.delete(module)

        if :code.soft_purge(module) do
          %{state | retired: Map.delete(state.retired, module), free: state.free ++ [module]}
        else
          schedule_reclaim(module, @reclaim_retry_ms)
          %{state | retired: Map.put(state.retired, module, :deleted)}
        end
    end
  end

  defp log_errors([]) do
    :ok
  end

  # By file, line and kind only: a message can quote rule text (the token a parse
  # error got, say), and rules can hold secrets. The rule tools return the messages.
  defp log_errors(errors) do
    Logger.warning(
      "Rules: #{length(errors)} invalid: " <>
        Enum.map_join(Enum.take(errors, 5), "; ", &error_location/1)
    )
  end

  defp error_location(%{file: file, line: nil, kind: kind}) do
    "#{file} (#{kind})"
  end

  defp error_location(%{file: file, line: line, kind: kind}) do
    "#{file} line #{line} (#{kind})"
  end
end

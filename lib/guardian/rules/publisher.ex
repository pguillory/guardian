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
  loaded name is retired. No prior plans are kept: each activation publishes what
  the store holds now.
  """

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
  # loaded; the rest are free. A name with only old code was already deleted, so it
  # is retired as :deleted and reclamation only soft-purges it.
  defp reserve_pool(state, in_use) do
    retired =
      for module <- Guardian.Rules.Compiler.names(),
          module not in in_use,
          status = retirement_status(module),
          into: %{},
          do: {module, status}

    free =
      Enum.reject(Guardian.Rules.Compiler.names(), &(&1 in in_use or Map.has_key?(retired, &1)))

    Enum.each(Map.keys(retired), &schedule_reclaim(&1, @reclaim_after_ms))
    %{state | free: free, retired: retired}
  end

  defp retirement_status(module) do
    cond do
      :code.is_loaded(module) != false -> :pending
      :erlang.check_old_code(module) -> :deleted
      true -> nil
    end
  end

  ## Activation

  # Publishes each table's result from whole-set preparation, at boot and on every
  # reload alike: a valid table runs its plan, an invalid one fails its events.
  def activate(state, preparation) do
    published = Rules.published() || %{}
    errors = Enum.sort_by(preparation.errors, &{&1.file, &1.line || 0, &1.kind})

    {targets, to_compile} =
      Enum.reduce(preparation.tables, {%{}, []}, fn {table, result}, {targets, to_compile} ->
        current = Map.get(published, table)

        case result do
          {:ok, plan} ->
            if is_atom(current) and current != nil and current.hash() == plan.hash do
              {Map.put(targets, table, current), to_compile}
            else
              {targets, [plan | to_compile]}
            end

          {:error, table_errors} ->
            {Map.put(targets, table, {:invalid, invalid_message(table_errors)}), to_compile}
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
end

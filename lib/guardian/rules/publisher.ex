defmodule Guardian.Rules.Publisher do
  @moduledoc """
  Internal synchronous activation and publication, called only from Server's
  callbacks (so only one process loads rule modules on a node). It holds no state.

  Each table has one module (`Guardian.Rules.Compiler.module_name/1`), replaced in
  place by the VM's hot code swap. Loading a new version over a module that still has
  old code would kill any process running that old code, so every module is first
  soft-purged; if a process still runs its old code, nothing loads and the activation
  fails as `{:error, too_recent_message()}`. A generated module is on a stack only
  while a row reads its levels (`apply/2` tail-calls `Guardian.Rules.Runtime.run/3`),
  so that takes two changes to a table milliseconds apart. A process holding only a
  literal from old code does not block the purge.

  A table whose rules are deleted or become invalid leaves the published map; its
  module stays loaded, uncalled, so an event that read the map just before cannot find
  it gone. Writing the table's rules again replaces it like any change. No prior plans
  are kept: each activation publishes what the store holds now.
  """

  require Logger

  alias Guardian.Rules
  alias Guardian.Rules.Compiler

  @too_recent "rules changed too recently; try again"

  def too_recent_message do
    @too_recent
  end

  @doc """
  `preparation`'s valid tables and their plan hashes: what `purge_for/1` needs, small
  enough to send to every node.
  """
  def hashes(preparation) do
    for {table, {:ok, plan}} <- preparation.tables, into: %{}, do: {table, plan.hash}
  end

  @doc """
  Soft-purges the old code of every module that activating a set with these table
  hashes would load on this node (its published module is missing or has another
  hash), never killing a process. Returns whether all of them are free of old code.
  Writers call it on every node before saving, so each node checks what it would
  load, even one that missed an earlier reload.
  """
  def purge_for(hashes) do
    hashes
    |> Enum.reject(fn {table, hash} -> unchanged?(lookup(table), hash) end)
    |> Enum.map(fn {table, _hash} -> Compiler.module_name(table) end)
    |> purge()
  end

  defp purge(modules) do
    Enum.all?(modules, &:code.soft_purge/1)
  end

  ## Activation

  # Publishes each table's result from whole-set preparation, at boot and on every
  # reload alike: a valid table runs its plan, an invalid one fails its events.
  # Nothing loads unless every changed table compiles and every purge succeeds.
  def activate(preparation) do
    errors = Enum.sort_by(preparation.errors, &{&1.file, &1.line || 0, &1.kind})
    to_load = plans_to_load(preparation)

    with {:ok, binaries} <- compile_all(to_load, []),
         :ok <- purge_all(binaries) do
      load_all(binaries)

      tables =
        Map.new(preparation.tables, fn
          {table, {:ok, _plan}} ->
            {table, Compiler.module_name(table)}

          {table, {:error, table_errors}} ->
            {table, {:invalid, invalid_message(table_errors)}}
        end)

      Rules.publish(tables)
      {:ok, errors}
    else
      {:error, message} -> {:error, message, errors}
    end
  end

  defp plans_to_load(preparation) do
    for {table, {:ok, plan}} <- preparation.tables,
        not unchanged?(lookup(table), plan.hash) do
      plan
    end
  end

  defp lookup(table) do
    Map.get(Rules.published() || %{}, table)
  end

  defp unchanged?(current, hash) do
    is_atom(current) and current != nil and current.hash() == hash
  end

  defp compile_all([], compiled) do
    {:ok, Enum.reverse(compiled)}
  end

  defp compile_all([plan | plans], compiled) do
    module = Compiler.module_name(plan.table)

    case Compiler.compile(module, plan) do
      {:ok, binary} ->
        compile_all(plans, [{module, ~c"rules/#{plan.table}", binary} | compiled])

      {:error, kind} ->
        message = "compiling the rules for #{plan.table} failed (#{kind})"
        # Only a bug gets here, and a write's reply names the node, not this message.
        Logger.error("Rules: #{message}")
        {:error, message}
    end
  end

  defp purge_all(binaries) do
    if purge(Enum.map(binaries, fn {module, _filename, _binary} -> module end)),
      do: :ok,
      else: {:error, @too_recent}
  end

  # Switches every changed module at once. `atomic_load/1` refuses, rather than
  # kills, a module with old code; nothing else loads rule modules and every one was
  # just purged, so a refusal is a bug.
  defp load_all(binaries) do
    :ok = :code.atomic_load(binaries)
  end

  defp invalid_message([first | rest]) do
    case rest do
      [] -> first.message
      _ -> "#{first.message} (and #{length(rest)} more)"
    end
  end
end

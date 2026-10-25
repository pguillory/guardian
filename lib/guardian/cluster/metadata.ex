defmodule Guardian.Cluster.Metadata do
  @moduledoc """
  Cluster-wide table metadata.

  Each lookup asks every node in `Guardian.Cluster.connected_nodes/0` for its local Storage
  schemas and merges them. A schema holds per-column, per-type value counts
  (`Guardian.Storage.Column.Metadata`), so merging adds the counts with
  `Guardian.Storage.merge_schemas/2`. A column that holds ints on one node and strings on
  another is the same as a mixed column on one node; there is nothing to reconcile.

  If any connected node fails or times out, the lookup raises `Guardian.Cluster.NodeError`
  instead of returning partial metadata.

  Only connected nodes are asked. A node that is disconnected when the lookup runs is
  not detected, so its tables and counts are missing from the answer, just as its
  rows are missing from SELECT results.
  """

  @timeout 60_000

  @doc "Returns the schema of `table`, merged across the cluster."
  def schema(table) when is_binary(table) do
    call_all(:local_schema, [table])
    |> Enum.reduce(%{}, &Guardian.Storage.merge_schemas(&2, &1))
  end

  @doc "Returns `%{table => schema}` for every table on any connected node."
  def schemas do
    call_all(:local_schemas, [])
    |> Enum.reduce(%{}, fn tables, acc ->
      Map.merge(acc, tables, fn _table, schema1, schema2 ->
        Guardian.Storage.merge_schemas(schema1, schema2)
      end)
    end)
  end

  @doc false
  def local_schema(table) do
    Guardian.Storage.schema(table)
  end

  @doc false
  def local_schemas do
    Map.new(Guardian.Storage.table_names(), &{&1, Guardian.Storage.schema(&1)})
  end

  defp call_all(function, args) do
    nodes = Guardian.Cluster.connected_nodes()
    results = :erpc.multicall(nodes, __MODULE__, function, args, @timeout)

    failures =
      Enum.zip(nodes, results)
      |> Enum.reject(&match?({_node, {:ok, _value}}, &1))

    if failures != [] do
      raise Guardian.Cluster.NodeError, operation: function, failures: failures
    end

    Enum.map(results, fn {:ok, value} -> value end)
  end
end

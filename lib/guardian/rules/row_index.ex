defmodule Guardian.Rules.RowIndex do
  @moduledoc """
  One event's flattened row while its rules run, indexed so each statement costs what
  it touches rather than a pass over every column.

  - The trie holds each key under its top-level object path (the object keys before
    the first list boundary, each lowercased): `user.Name..x` sits at `user` →
    `name`. Removing a field or a path takes one subtree, so SET and UNSET touch only
    the keys they remove.
  - The read index maps each key's lowercase spelling to the set of present keys with
    that spelling (`:gb_sets`, kept in step with every insertion and removal). A read
    takes the exact key if present, else the least matching key in byte order.

  The read index is built at the first statement (`ensure/1`). The trie is built at
  the first SET or UNSET that applies, since building it decodes every key: an event
  whose statements all skip decodes none, as before the index. Every key is inserted
  once and removed at most once, so an event's rules cost about (columns × depth +
  statements × (path length + reads)) × log columns.
  """

  alias Guardian.Storage.Flattening

  defstruct [:row, :trie, :reads]

  @empty {[], %{}}

  @doc "An index of `row`, built when first needed."
  def new(row) do
    %__MODULE__{row: row}
  end

  @doc "The index with its read index built."
  def ensure(%__MODULE__{reads: nil, row: row} = index) do
    %__MODULE__{index | reads: row |> Map.keys() |> Enum.reduce(%{}, &add_read(&2, &1))}
  end

  def ensure(index) do
    index
  end

  defp ensure_trie(%__MODULE__{trie: nil, row: row} = index) do
    %__MODULE__{} = index = ensure(index)
    %__MODULE__{index | trie: row |> Map.keys() |> Enum.reduce(@empty, &insert(&2, path(&1), &1))}
  end

  defp ensure_trie(index) do
    index
  end

  @doc """
  The value read as `name` (lowercase, as identifiers are): the exact key's value,
  else the value of the least key in byte order whose lowercase spelling is `name`.
  `:error` when there is none.
  """
  def fetch(%__MODULE__{row: row, reads: reads}, name) do
    case Map.fetch(row, name) do
      {:ok, value} ->
        {:ok, value}

      :error ->
        case Map.fetch(reads, name) do
          {:ok, keys} -> {:ok, Map.fetch!(row, :gb_sets.smallest(keys))}
          :error -> :error
        end
    end
  end

  @doc """
  Removes every key under the top-level field `field` in any case, then stores `value`
  under `field`. `field` is a lowercase identifier with no dot or quote, as validation
  guarantees for SET: a dotted or quoted one would be removed under one path and
  inserted under another.
  """
  def put_field(index, field, value) do
    %__MODULE__{} = index = remove(index, [field])
    trie = insert(index.trie, path(field), field)

    %__MODULE__{
      index
      | row: Map.put(index.row, field, value),
        trie: trie,
        reads: add_read(index.reads, field),
    }
  end

  @doc """
  Removes every key whose object path starts with `segments` (lowercase), and every
  key beneath them.
  """
  def remove(%__MODULE__{} = index, segments) do
    %__MODULE__{} = index = ensure_trie(index)

    case detach(index.trie, segments) do
      {nil, _trie} ->
        index

      {subtree, trie} ->
        keys = subtree_keys(subtree, [])

        %__MODULE__{
          index
          | row: Map.drop(index.row, keys),
            trie: trie,
            reads: Enum.reduce(keys, index.reads, &remove_read(&2, &1)),
        }
    end
  end

  # The object keys before the key's first list boundary, lowercased: ["user", "name"]
  # for `User.name` and for `user.Name..x`. A quoted key holding dots is one segment.
  defp path(key) do
    keys =
      if String.contains?(key, ["\"", "."]) do
        [keys | _] = Flattening.decode_path(key)
        keys
      else
        [key]
      end

    Enum.map(keys, &String.downcase/1)
  end

  # A node is {keys ending here, children by lowercase segment}.
  defp insert({keys, children}, [], key) do
    {[key | keys], children}
  end

  defp insert({keys, children}, [segment | rest], key) do
    child = Map.get(children, segment, @empty)
    {keys, Map.put(children, segment, insert(child, rest, key))}
  end

  # {the subtree at `segments` or nil, the trie without it}.
  defp detach({keys, children} = node, [segment | rest]) do
    case Map.fetch(children, segment) do
      :error ->
        {nil, node}

      {:ok, child} when rest == [] ->
        {child, {keys, Map.delete(children, segment)}}

      {:ok, child} ->
        case detach(child, rest) do
          {nil, _child} -> {nil, node}
          {subtree, child} -> {subtree, {keys, Map.put(children, segment, child)}}
        end
    end
  end

  defp subtree_keys({keys, children}, acc) do
    Enum.reduce(Map.values(children), keys ++ acc, &subtree_keys/2)
  end

  defp add_read(reads, key) do
    lower = String.downcase(key)
    Map.update(reads, lower, :gb_sets.singleton(key), &:gb_sets.add(key, &1))
  end

  # An emptied set is removed, so a read never takes the least of an empty set.
  defp remove_read(reads, key) do
    lower = String.downcase(key)
    keys = :gb_sets.delete_any(key, Map.fetch!(reads, lower))
    if :gb_sets.is_empty(keys), do: Map.delete(reads, lower), else: Map.put(reads, lower, keys)
  end
end

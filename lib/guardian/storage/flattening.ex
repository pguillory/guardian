defmodule Guardian.Storage.Flattening do
  @moduledoc """
  Flattens events into dot-notation columns and encodes their column names.
  Nothing turns a flat row back into nested JSON: stored rows, query results and
  ingest results are all flat.
  """

  # Flattens an event map to string-keyed {path, value} pairs
  def flatten_event(event) do
    event
    |> flatten()
    |> Map.new(fn {path, value} -> {encode_path(path), value} end)
  end

  # Flattens a map by flattening each value and prefixing with the key
  def flatten(map) when is_map(map) do
    Enum.flat_map(map, fn {key, value} ->
      flatten(value)
      |> Enum.map(fn {[init | rest], val} ->
        {[[key | init] | rest], val}
      end)
    end)
  end

  # Flattens a list by flattening each item, combining by path, then prepending [].
  # Each path's values hold one entry per item up to the last item that has the path,
  # with nil for items that lack it. Values are collected in reverse, so flattening
  # takes time linear in the size of its result.
  def flatten(list) when is_list(list) do
    list
    |> Enum.reduce({%{}, 0}, fn item, {map, index} ->
      map =
        Enum.reduce(flatten(item), map, fn {path, value}, map ->
          {reversed, length} = Map.get(map, path, {[], 0})
          reversed = [value | prepend_nils(reversed, index - length)]
          Map.put(map, path, {reversed, index + 1})
        end)

      {map, index + 1}
    end)
    |> then(fn {combined, _count} -> combined end)
    |> Enum.map(fn
      {[[]], {reversed, _length}} -> {[[]], Enum.reverse(reversed)}
      {path, {reversed, _length}} -> {[[] | path], Enum.reverse(reversed)}
    end)
  end

  # Flattens a scalar to a single empty segment
  def flatten(scalar) do
    [{[[]], scalar}]
  end

  defp prepend_nils(list, 0) do
    list
  end

  defp prepend_nils(list, n) when n > 0 do
    prepend_nils([nil | list], n - 1)
  end

  # Pads or truncates a list to target length
  def pad(_, 0, _value) do
    []
  end

  def pad([], n, value) do
    List.duplicate(value, n)
  end

  def pad([head | rest], n, value) do
    [head | pad(rest, n - 1, value)]
  end

  # Encodes a path like [["a", "b"], ["c"]] to dot notation "a.b..c"
  # Keys containing dots or quotes, and empty keys, are quoted:
  # [["a", "b.c"]] -> "a.\"b.c\"". Inside quotes a backslash or quote is escaped
  # with a backslash, so a key ending in a backslash can't swallow the closing quote.
  def encode_path([[key]]) do
    encode_key(key)
  end

  def encode_path([[key | keys] | rest]) do
    encode_key(key) <> "." <> encode_path([keys | rest])
  end

  def encode_path([[] | rest]) do
    "." <> encode_path(rest)
  end

  defp encode_key("") do
    "\"\""
  end

  defp encode_key(key) when is_atom(key) do
    encode_key(Atom.to_string(key))
  end

  defp encode_key(key) do
    if String.contains?(key, ".") or String.contains?(key, "\"") do
      escaped = key |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")
      "\"#{escaped}\""
    else
      key
    end
  end
end

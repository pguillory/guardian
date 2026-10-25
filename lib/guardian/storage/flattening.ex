defmodule Guardian.Storage.Flattening do
  @moduledoc """
  Converts between row-oriented events and columnar representation.
  """

  defstruct columns: %{}, count: 0

  def new, do: %__MODULE__{}

  def from_events(events) do
    Enum.reduce(events, new(), fn event, segment ->
      append_event(segment, event)
    end)
  end

  # Flattens an event map to string-keyed {path, value} pairs
  def flatten_event(event) do
    event
    |> flatten()
    |> Map.new(fn {path, value} -> {encode_path(path), value} end)
  end

  # Unflattens string-keyed map back to nested event structure
  def unflatten_event(flat_row) do
    columns =
      Map.new(flat_row, fn {key, value} ->
        {decode_path(key), [value]}
      end)

    [event] = to_events(%__MODULE__{columns: columns, count: 1})
    event
  end

  # Appends a single event to the virtual segment
  defp append_event(%__MODULE__{columns: columns, count: count}, event) do
    # Flatten the event into {path, value} pairs
    pairs = flatten(event)

    # For each pair, append the value to that column
    new_columns =
      Enum.reduce(pairs, columns, fn {path, value}, cols ->
        Map.update(cols, path, [value], fn existing -> existing ++ [value] end)
      end)

    %__MODULE__{columns: new_columns, count: count + 1}
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

  defp prepend_nils(list, 0), do: list
  defp prepend_nils(list, n) when n > 0, do: prepend_nils([nil | list], n - 1)

  # Pads or truncates a list to target length
  def pad(_, 0, _value), do: []
  def pad([], n, value), do: List.duplicate(value, n)
  def pad([head | rest], n, value), do: [head | pad(rest, n - 1, value)]

  # Zips two lists and maps over pairs, padding shorter list with nils
  def zip_map([], [], _fun), do: []
  def zip_map([a | as], [], fun), do: [fun.(a, nil) | zip_map(as, [], fun)]
  def zip_map([], [b | bs], fun), do: [fun.(nil, b) | zip_map([], bs, fun)]
  def zip_map([a | as], [b | bs], fun), do: [fun.(a, b) | zip_map(as, bs, fun)]

  def map_update(map, key, default, func) when is_function(func, 1) do
    value = Map.get(map, key, default)
    value = func.(value)
    Map.put(map, key, value)
  end

  # Encodes a path like [["a", "b"], ["c"]] to dot notation "a.b..c"
  # Keys containing dots or quotes, and empty keys, are quoted:
  # [["a", "b.c"]] -> "a.\"b.c\"". Inside quotes a backslash or quote is escaped
  # with a backslash, so a key ending in a backslash can't swallow the closing quote.
  def encode_path([[key]]), do: encode_key(key)
  def encode_path([[key | keys] | rest]), do: encode_key(key) <> "." <> encode_path([keys | rest])
  def encode_path([[] | rest]), do: "." <> encode_path(rest)

  defp encode_key(""), do: "\"\""
  defp encode_key(key) when is_atom(key), do: encode_key(Atom.to_string(key))

  defp encode_key(key) do
    if String.contains?(key, ".") or String.contains?(key, "\"") do
      escaped = key |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")
      "\"#{escaped}\""
    else
      key
    end
  end

  # Decodes dot notation "a.b..c" back to path [["a", "b"], ["c"]]
  def decode_path(encoded) do
    parse_path(encoded, [], [])
  end

  # Parse path string into segments, handling quoted keys
  # acc = current segment keys (reversed), segments = completed segments (reversed)
  defp parse_path("", acc, segments) do
    Enum.reverse([Enum.reverse(acc) | segments])
  end

  # Double dot (or more) = segment boundary
  defp parse_path(".." <> rest, acc, segments) do
    parse_path("." <> rest, [], [Enum.reverse(acc) | segments])
  end

  # Single dot followed by non-dot = key separator within segment
  defp parse_path("." <> rest, acc, segments) do
    parse_path(rest, acc, segments)
  end

  defp parse_path("\"" <> rest, acc, segments) do
    {key, rest} = parse_quoted_key(rest, "")
    parse_path(rest, [key | acc], segments)
  end

  defp parse_path(str, acc, segments) do
    # Parse unquoted key until . or end
    case String.split(str, ".", parts: 2) do
      [key] -> parse_path("", [key | acc], segments)
      [key, rest] -> parse_path("." <> rest, [key | acc], segments)
    end
  end

  # Parse a quoted key until closing quote. A backslash escapes a backslash or a
  # quote; before any other character it is itself (names stored before backslashes
  # were escaped).
  defp parse_quoted_key("\\\\" <> rest, acc), do: parse_quoted_key(rest, acc <> "\\")
  defp parse_quoted_key("\\\"" <> rest, acc), do: parse_quoted_key(rest, acc <> "\"")
  defp parse_quoted_key("\"" <> rest, acc), do: {acc, rest}

  defp parse_quoted_key(<<char::utf8, rest::binary>>, acc) do
    parse_quoted_key(rest, acc <> <<char::utf8>>)
  end

  def to_events(%__MODULE__{columns: columns, count: count}) do
    events = List.duplicate(%{}, count)

    Enum.reduce(columns, events, fn {path, values}, events ->
      zip_map(events, values, fn event, value ->
        unflatten(event, path, value)
      end)
    end)
  end

  # Unflattens a path and value back into a nested structure
  defp unflatten(event, [[key]], value) when is_map(event) do
    Map.put(event, key, value)
  end

  defp unflatten(event, [[key] | rest_path], value) when is_map(event) do
    map_update(event, key, [], fn list ->
      merge_into_list(list, rest_path, value)
    end)
  end

  defp unflatten(event, [[key | rest_keys] | rest_path], value) when is_map(event) do
    map_update(event, key, %{}, fn nested ->
      unflatten(nested, [rest_keys | rest_path], value)
    end)
  end

  # Merges values into a list of objects
  defp merge_into_list(list, [[] | rest_path], values) when is_list(list) do
    zip_map(list, values, fn inner_list, val ->
      merge_into_list(inner_list || [], rest_path, val)
    end)
  end

  defp merge_into_list(list, [[field | rest_field]], values) when is_list(list) do
    zip_map(list, values, fn obj, val ->
      unflatten(obj || %{}, [[field | rest_field]], val)
    end)
  end

  defp merge_into_list(list, [[field] | rest_path], values) when is_list(list) do
    zip_map(list, values, fn obj, val ->
      map_update(obj || %{}, field, [], fn inner_list ->
        merge_into_list(inner_list, rest_path, val)
      end)
    end)
  end
end

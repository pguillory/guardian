defmodule Rules.RowIndexTest do
  use ExUnit.Case, async: true

  alias Rules.RowIndex
  alias Storage.Flattening

  describe "against the scan-every-key implementation it replaced" do
    # The reference: what Rules.Runtime did before the index, one pass over the row
    # per statement and per read.
    defp ref_fetch(row, name) do
      case Map.fetch(row, name) do
        {:ok, value} ->
          {:ok, value}

        :error ->
          case row |> Map.keys() |> Enum.filter(&(String.downcase(&1) == name)) do
            [] -> :error
            keys -> {:ok, Map.fetch!(row, Enum.min(keys))}
          end
      end
    end

    defp ref_set(row, field, value) do
      row
      |> Map.reject(fn {key, _} -> key |> ref_keys() |> hd() |> String.downcase() == field end)
      |> Map.put(field, value)
    end

    defp ref_unset(row, path) do
      segments = String.split(path, ".")

      Map.reject(row, fn {key, _} ->
        keys = ref_keys(key)

        length(keys) >= length(segments) and
          Enum.zip_with(segments, keys, &(String.downcase(&2) == &1)) |> Enum.all?()
      end)
    end

    defp ref_keys(key) do
      if String.contains?(key, ["\"", "."]) do
        [keys | _] = Flattening.decode_path(key)
        keys
      else
        [key]
      end
    end

    @names ["a", "A", "b", "B", "x.y", "X.y", "q\"", ""]

    defp random_event(depth) do
      for _ <- 1..Enum.random(1..4), into: %{} do
        {Enum.random(@names), random_value(depth)}
      end
    end

    defp random_value(0), do: Enum.random([1, "s", nil, [1, 2]])

    defp random_value(depth) do
      case Enum.random(1..4) do
        1 -> random_event(depth - 1)
        2 -> [random_event(depth - 1), random_event(depth - 1)]
        _ -> random_value(0)
      end
    end

    @fields ["a", "b", "x", "q"]
    @paths ["a", "b", "a.a", "a.b", "a.b.a", "b.a", "a..b", "x", "x.y", "\"x.y\""]
    @reads ["a", "b", "a.a", "a.b", "a..a", "a.a..b", "x.y", "\"x.y\"", "q\"", "\"q\\\"\""]

    test "every operation and read agrees on random rows" do
      for _ <- 1..500 do
        row = Flattening.flatten_event(random_event(3))

        Enum.reduce(1..12, {row, RowIndex.ensure(RowIndex.new(row))}, fn _, {ref, index} ->
          for name <- @reads do
            assert RowIndex.fetch(index, name) == ref_fetch(ref, name), inspect({ref, name})
          end

          {ref, index} =
            case Enum.random([:set, :unset]) do
              :set ->
                field = Enum.random(@fields)
                {ref_set(ref, field, 7), RowIndex.put_field(index, field, 7)}

              :unset ->
                path = Enum.random(@paths)
                {ref_unset(ref, path), RowIndex.remove(index, String.split(path, "."))}
            end

          assert index.row == ref
          {ref, index}
        end)
      end
    end
  end

  describe "cost" do
    # Runs `source` as the table's rules on `row` the way a compiled module does, and
    # times every statement after the first. The first applies and builds the index,
    # which costs about the row's size; the rest should cost what they touch. The
    # scan this replaced took about 205 s for them in the first test and 1.8 s after
    # the UNSET in the second; the index takes a few milliseconds.
    defp run(source, row) do
      %{tables: %{"t" => {:ok, plan}}} = Rules.RuleSet.validate(%{"t/r.gsql" => source})
      [first | rest] = plan.steps
      state = step(Rules.Runtime.start(row), first)
      {micros, state} = :timer.tc(fn -> Enum.reduce(rest, state, &step(&2, &1)) end)
      {micros / 1_000_000, Rules.Runtime.finish(state)}
    end

    defp step(state, step), do: apply(Rules.Runtime, step.kind, [state, step])

    test "1,000 statements on an event with 100,000 columns" do
      row = Map.new(1..100_000, &{"c#{&1}", &1})
      source = Enum.map_join(1..1_000, ";\n", &"SET f#{&1} = c#{&1} + 1 WHERE c1 = 1")

      {seconds, result} = run(source, row)
      assert result["f1000"] == 1_001
      assert map_size(result) == 101_000
      assert seconds < 0.5
    end

    test "many reads of a field with 100,000 case variants, live and after an UNSET" do
      # 2^17 spellings of one 17-letter name, each with its own case pattern.
      name = String.duplicate("a", 17)

      row =
        Map.new(0..99_999, fn n ->
          spelling =
            for i <- 0..16, into: "" do
              if Bitwise.band(n, Bitwise.bsl(1, i)) == 0, do: "a", else: "A"
            end

          {spelling, n}
        end)

      # Without the exact spelling, a read takes the least spelling in byte order.
      live = Map.delete(row, name)
      least = live |> Map.keys() |> Enum.min()
      expected = Map.fetch!(live, least)
      reads = Enum.map_join(1..999, ";\n", &"SET f#{&1} = 1 WHERE #{name} = #{expected}")
      {seconds, result} = run("SET v = #{name};\n" <> reads, live)
      assert result["v"] == expected
      assert result["f999"] == 1
      assert seconds < 0.5

      stale =
        "UNSET #{name};\n" <> Enum.map_join(1..999, ";\n", &"UNSET c#{&1} WHERE #{name} = 0")

      {seconds, result} = run(stale, Map.put(row, "c1", 1))
      assert result == %{"c1" => 1}
      assert seconds < 0.5
    end
  end
end

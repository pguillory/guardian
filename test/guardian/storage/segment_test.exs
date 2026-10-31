defmodule Guardian.Storage.SegmentTest do
  alias Guardian.Storage.Segment
  # Segment.append/2 takes flat rows; these tests append nested ones.
  import Segment, except: [append: 2]
  import Guardian.Test.Segments, only: [segment_append: 2, segment_row: 2]
  use ExUnit.Case, async: true

  @dir "/tmp/SegmentTest"

  @filename "/tmp/SegmentTest/file.dat"

  setup do
    File.rm_rf(@dir)
    File.mkdir_p!(@dir)

    on_exit(fn ->
      File.rm_rf(@dir)
    end)
  end

  test "store + load" do
    {:ok, segment} = start_link()
    :ok = segment_append(segment, %{"a" => 1})
    assert File.exists?(@filename) == false
    :ok = pack(segment)
    :ok = store(segment, @filename)
    assert File.exists?(@filename)
    :ok = retire(segment)

    {:ok, segment2} = start_link(load: @filename)
    assert keys(segment2) == {:ok, ["a"]}
  end

  test "a nested object is stored as dotted columns" do
    {:ok, segment} = start_link()

    # Simple nested object
    :ok = segment_append(segment, %{"user" => %{"name" => "Alice", "age" => 30}})

    {:ok, row} = segment_row(segment, 0)
    assert row == %{"user.name" => "Alice", "user.age" => 30}
  end

  test "nested object with array of objects" do
    {:ok, segment} = start_link()

    event = %{
      "user" => %{
        "name" => "Bob",
        "tags" => [%{"key" => "role", "value" => "admin"}, %{"key" => "dept", "value" => "eng"}],
      },
    }

    :ok = segment_append(segment, event)

    {:ok, row} = segment_row(segment, 0)

    assert row == %{
             "user.name" => "Bob",
             "user.tags..key" => ["role", "dept"],
             "user.tags..value" => ["admin", "eng"],
           }
  end

  test "deeply nested objects" do
    {:ok, segment} = start_link()

    event = %{
      "a" => %{
        "b" => %{
          "c" => %{
            "d" => 42,
          },
        },
      },
    }

    :ok = segment_append(segment, event)

    {:ok, row} = segment_row(segment, 0)
    assert row == %{"a.b.c.d" => 42}
  end

  test "multiple events with nested objects" do
    {:ok, segment} = start_link()

    event1 = %{"user" => %{"name" => "Alice"}}
    event2 = %{"user" => %{"name" => "Bob"}}

    :ok = segment_append(segment, event1)
    :ok = segment_append(segment, event2)

    {:ok, row1} = segment_row(segment, 0)
    {:ok, row2} = segment_row(segment, 1)

    assert row1 == %{"user.name" => "Alice"}
    assert row2 == %{"user.name" => "Bob"}
  end

  test "nested objects with atom keys" do
    {:ok, segment} = start_link()

    # Atom keys should be converted to strings
    :ok = segment_append(segment, %{user: %{name: "Alice"}})

    {:ok, row} = segment_row(segment, 0)
    assert row == %{"user.name" => "Alice"}
  end

  test "nested objects store and load" do
    {:ok, segment} = start_link()

    event = %{
      "user" => %{
        "name" => "Alice",
        "items" => [%{"id" => 1, "name" => "item1"}, %{"id" => 2, "name" => "item2"}],
      },
    }

    :ok = segment_append(segment, event)
    :ok = pack(segment)
    :ok = store(segment, @filename)
    :ok = retire(segment)

    {:ok, segment2} = start_link(load: @filename)
    {:ok, row} = segment_row(segment2, 0)

    assert row == %{
             "user.name" => "Alice",
             "user.items..id" => [1, 2],
             "user.items..name" => ["item1", "item2"],
           }
  end

  test "filtering list columns in mutable, packed, and loaded segments" do
    # Ingest flattening drops empty lists, so build the column directly to keep them.
    values = [nil, ["x", "y"], [], [["n", 1], [], [true]], "scalar", [nil, 2.5], [[]]]
    keep = [false, true, false, true, false, true, true]
    expected = [["x", "y"], [["n", 1], [], [true]], [nil, 2.5], [[]]]
    mask = Guardian.Storage.Column.from_list(keep)

    column = Guardian.Storage.Column.new(length(values))
    Enum.each(values, &(:ok = Guardian.Storage.Column.append(column, &1)))

    {:ok, segment} = start_link()
    :ok = put_column(segment, "tags", Guardian.Storage.Column.pack(column))
    :ok = update_count(segment, length(values))

    assert_filtered = fn segment ->
      {:ok, column} = get_column(segment, "tags")
      assert column |> Guardian.Storage.Column.to_list() === values

      assert column |> Guardian.Storage.Column.filter(mask) |> Guardian.Storage.Column.to_list() ===
               expected
    end

    assert_filtered.(segment)
    :ok = pack(segment)
    {:ok, packed_column} = get_column(segment, "tags")
    assert is_binary(packed_column)
    assert_filtered.(segment)
    :ok = store(segment, @filename)
    :ok = retire(segment)

    {:ok, loaded} = start_link(load: @filename)
    assert_filtered.(loaded)
  end

  describe "capacity" do
    test "lists totaling more than 65535 elements in one column" do
      {:ok, segment} = start_link()

      for i <- 1..20 do
        :ok = segment_append(segment, %{"n" => i, "tags" => List.duplicate(i, 5_000)})
      end

      assert full(segment) == {:ok, false}
      :ok = segment_append(segment, %{"n" => 21, "tags" => [21]})

      :ok = pack(segment)
      :ok = store(segment, @filename)
      {:ok, loaded} = start_link(load: @filename)
      assert count(loaded) == {:ok, 21}
      {:ok, tags} = get_column(loaded, "tags")
      assert [_, {100_001, _, _, _, _, _, _, _}] = Guardian.Storage.Column.metadata(tags)
      assert segment_row(loaded, 19) == {:ok, %{"n" => 20, "tags" => List.duplicate(20, 5_000)}}
    end

    test "strings longer than 65535 bytes" do
      {:ok, segment} = start_link()
      string = String.duplicate("s", 100_000)

      for i <- 1..50 do
        :ok = segment_append(segment, %{"i" => i, "s" => string, "l" => [string]})
      end

      :ok = pack(segment)
      :ok = store(segment, @filename)
      {:ok, loaded} = start_link(load: @filename)
      assert segment_row(loaded, 49) == {:ok, %{"i" => 50, "s" => string, "l" => [string]}}
    end

    # About 1 GB peak. Run by hand with `mix test --only large`.
    @tag :large
    @tag timeout: :infinity
    test "strings totaling more than 2^28 bytes in one column" do
      {:ok, segment} = start_link(max_bytes: :infinity)
      string = String.duplicate("s", 1024 * 1024)

      for i <- 1..270 do
        :ok = segment_append(segment, %{"i" => i, "s" => string})
      end

      :ok = pack(segment)
      {:ok, s} = get_column(segment, "s")
      assert byte_size(s) > 2 ** 28
      assert segment_row(segment, 269) == {:ok, %{"i" => 270, "s" => string}}
    end

    test "a capacity over 65535 rows" do
      {:ok, segment} = start_link(capacity: 70_000)

      for i <- 1..69_999 do
        :ok = segment_append(segment, %{"i" => i})
      end

      assert segment_append(segment, %{"i" => 70_000}) == {:ok, :full}
      {:ok, i} = get_column(segment, "i")
      assert Guardian.Storage.Column.to_list(i) == Enum.to_list(1..70_000)
    end

    test "the row that reaches capacity fills the segment" do
      {:ok, segment} = start_link(capacity: 2)
      assert segment_append(segment, %{"a" => 1}) == :ok
      assert segment_append(segment, %{"a" => 2}) == {:ok, :full}
      assert full(segment) == {:ok, true}
      assert segment_append(segment, %{"a" => 3}) == {:error, :full}
    end

    test "values no column can hold raise without harming the segment" do
      {:ok, segment} = start_link()
      :ok = segment_append(segment, %{"a" => 1})

      assert_raise MatchError, fn -> segment_append(segment, %{"a" => [[[1]]]}) end

      assert_raise ArgumentError, fn ->
        segment_append(segment, %{String.duplicate("k", 251) => 1})
      end

      assert GenServer.call(segment, {:append, %{"a" => [[[1]]]}}) == {:error, :invalid_value}
      # Guardian.Storage.Value accepts a map value; the segment refuses it.
      assert Segment.append(segment, %{"a" => %{}}) == {:error, :invalid_value}

      assert Process.alive?(segment)
      :ok = segment_append(segment, %{"a" => 2})
      assert count(segment) == {:ok, 2}
    end

    test "appending to a dead segment reports it" do
      {:ok, segment} = start_link()
      GenServer.stop(segment)
      assert segment_append(segment, %{"a" => 1}) == {:error, :dead}
    end
  end

  describe "maximum age" do
    test "empty and refused rows start no timer; the first stored row expires" do
      {:ok, segment} = start_link(max_age_ms: 50, max_age_owner: self())

      assert GenServer.call(segment, {:append, %{"a" => [[[1]]]}}) ==
               {:error, :invalid_value}

      refute_receive {:segment_max_age, ^segment}, 100
      assert full(segment) == {:ok, false}

      :ok = segment_append(segment, %{})
      assert_receive {:segment_max_age, ^segment}, 1000
      assert full(segment) == {:ok, true}
      assert count(segment) == {:ok, 1}
      assert segment_append(segment, %{"a" => 1}) == {:error, :full}
    end

    test "a segment loaded from a file does not expire" do
      {:ok, segment} = start_link()
      :ok = segment_append(segment, %{"a" => 1})
      :ok = pack(segment)
      :ok = store(segment, @filename)

      {:ok, loaded} = start_link(load: @filename, max_age_ms: 1, max_age_owner: self())
      refute_receive {:segment_max_age, ^loaded}, 150
      assert segment_row(loaded, 0) == {:ok, %{"a" => 1}}
    end
  end

  describe "byte budget" do
    test "the row that crosses the budget is stored and fills the segment" do
      {:ok, segment} = start_link(max_bytes: 100_000)
      string = String.duplicate("s", 10_000)

      results = for i <- 1..10, do: segment_append(segment, %{"i" => i, "s" => string})
      assert Enum.take(results, 9) == List.duplicate(:ok, 9)
      assert List.last(results) == {:ok, :full}
      assert full(segment) == {:ok, true}
      assert segment_append(segment, %{"i" => 11}) == {:error, :full}
      assert count(segment) == {:ok, 10}

      :ok = pack(segment)
      :ok = store(segment, @filename)
      {:ok, loaded} = start_link(load: @filename)
      assert count(loaded) == {:ok, 10}

      for i <- 0..9 do
        assert segment_row(loaded, i) == {:ok, %{"i" => i + 1, "s" => string}}
      end
    end

    test "a row larger than the budget gets a segment to itself" do
      {:ok, segment} = start_link(max_bytes: 1000)
      assert segment_append(segment, %{"s" => String.duplicate("s", 5000)}) == {:ok, :full}
      assert count(segment) == {:ok, 1}
      assert segment_append(segment, %{"a" => 1}) == {:error, :full}
    end

    test "many sparse columns cross the budget" do
      # Every row has keys of its own. Each column costs its bitmaps once padded to
      # the row count, so the budget is reached long before the row capacity.
      {:ok, segment} = start_link(max_bytes: 4 * 1024 * 1024)

      rows =
        Stream.iterate(0, &(&1 + 1))
        |> Enum.reduce_while(0, fn i, _ ->
          row = Map.new(1..3, fn j -> {"k#{i}_#{j}", i} end)

          case segment_append(segment, row) do
            :ok -> {:cont, i + 1}
            {:ok, :full} -> {:halt, i + 1}
          end
        end)

      assert rows < 16_384
      assert full(segment) == {:ok, true}
    end

    test "many small columns in one row count toward the budget" do
      {:ok, segment} = start_link(max_bytes: 50_000)
      row = Map.new(1..1000, fn i -> {"k#{i}", i} end)
      assert segment_append(segment, row) == {:ok, :full}
    end
  end

  describe "column confinement" do
    @race_script Path.expand("../../fixtures/segment_column_race.exs", __DIR__)

    @tag timeout: 120_000
    test "querying a segment while it appends and packs does not corrupt its columns" do
      {output, status} = run_child(@race_script, 60_000)
      assert status == 0, "race child exited with #{inspect(status)}:\n#{output}"

      match = Regex.run(~r/^ok rows=(\d+) column_reads=\[(.*)\]$/m, output)
      assert [_, rows, column_reads] = match, "no result line in:\n#{output}"

      assert String.to_integer(rows) >= 2_000

      for reads <- String.split(column_reads, ", ") do
        assert String.to_integer(reads) > 1
      end
    end

    # Runs an Elixir script with this build's code path in a child OS process, killing it
    # if it outlives `timeout_ms`.
    defp run_child(script, timeout_ms) do
      paths =
        :code.get_path()
        |> Enum.map(&to_string/1)
        |> Enum.filter(&String.contains?(&1, "_build"))
        |> Enum.flat_map(&["-pa", &1])

      port =
        Port.open({:spawn_executable, System.find_executable("elixir")}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: paths ++ [script],
        ])

      {:os_pid, os_pid} = Port.info(port, :os_pid)
      deadline = System.monotonic_time(:millisecond) + timeout_ms
      collect_child(port, os_pid, deadline, [])
    end

    defp collect_child(port, os_pid, deadline, output) do
      remaining = max(deadline - System.monotonic_time(:millisecond), 0)

      receive do
        {^port, {:data, data}} ->
          collect_child(port, os_pid, deadline, [output, data])

        {^port, {:exit_status, status}} ->
          {IO.iodata_to_binary(output), status}
      after
        remaining ->
          System.cmd("kill", ["-9", to_string(os_pid)])
          {IO.iodata_to_binary(output), :timeout}
      end
    end

    test "get_column returns a snapshot that later appends don't change" do
      {:ok, segment} = start_link()
      :ok = segment_append(segment, %{"a" => 1})
      {:ok, a1} = get_column(segment, "a")
      assert is_binary(a1)
      assert Guardian.Storage.Column.to_list(a1) == [1]

      :ok = segment_append(segment, %{"a" => 2})
      assert Guardian.Storage.Column.to_list(a1) == [1]
      {:ok, a2} = get_column(segment, "a")
      assert Guardian.Storage.Column.to_list(a2) == [1, 2]
    end

    test "a snapshot follows appends of rows without its key" do
      {:ok, segment} = start_link()
      :ok = segment_append(segment, %{"a" => 1})
      {:ok, _} = get_column(segment, "a")

      :ok = segment_append(segment, %{})
      {:ok, a} = get_column(segment, "a")
      assert Guardian.Storage.Column.to_list(a) == [1, nil]

      :ok = segment_append(segment, %{"b" => true})
      {:ok, a} = get_column(segment, "a")
      assert Guardian.Storage.Column.to_list(a) == [1, nil, nil]
      {:ok, b} = get_column(segment, "b")
      assert Guardian.Storage.Column.to_list(b) == [nil, nil, true]
    end

    test "a snapshot follows update_count and put_column" do
      {:ok, segment} = start_link(capacity: 10)
      :ok = segment_append(segment, %{"a" => 1})
      {:ok, _} = get_column(segment, "a")

      :ok = update_count(segment, 3)
      {:ok, a} = get_column(segment, "a")
      assert Guardian.Storage.Column.to_list(a) == [1, nil, nil]

      replacement = Guardian.Storage.Column.from_list([7, 8, 9])
      :ok = put_column(segment, "a", replacement)
      assert get_column(segment, "a") == {:ok, replacement}
    end

    test "a mutable list column reads as a packed snapshot, before and after pack" do
      values = [["x", "y"], nil, [["n", 1], [true]], "scalar", [nil, 2.5]]
      mask = Guardian.Storage.Column.from_list([true, true, true, false, true])
      expected = [["x", "y"], nil, [["n", 1], [true]], [nil, 2.5]]
      {:ok, segment} = start_link()

      for value <- values do
        :ok = segment_append(segment, if(value == nil, do: %{}, else: %{"tags" => value}))
      end

      {:ok, snapshot} = get_column(segment, "tags")
      assert is_binary(snapshot)
      assert Guardian.Storage.Column.to_list(snapshot) === values

      assert snapshot |> Guardian.Storage.Column.filter(mask) |> Guardian.Storage.Column.to_list() ===
               expected

      :ok = pack(segment)
      {:ok, packed} = get_column(segment, "tags")
      assert packed == snapshot

      assert packed |> Guardian.Storage.Column.filter(mask) |> Guardian.Storage.Column.to_list() ===
               expected
    end

    test "pack stores the snapshot taken after freezing" do
      {:ok, segment} = start_link()
      :ok = segment_append(segment, %{"a" => 1, "b" => "x"})
      :ok = segment_append(segment, %{"a" => 2})
      :ok = freeze(segment)
      {:ok, a} = get_column(segment, "a")

      :ok = pack(segment)
      assert get_column(segment, "a") == {:ok, a}
      {:ok, b} = get_column(segment, "b")
      assert Guardian.Storage.Column.to_list(b) == ["x", nil]
      :ok = store(segment, @filename)

      {:ok, loaded} = start_link(load: @filename)
      assert get_column(loaded, "a") == {:ok, a}
    end

    test "only a frozen segment packs a column" do
      {:ok, segment} = start_link()
      :ok = segment_append(segment, %{"a" => 1})
      assert GenServer.call(segment, {:pack_column, "a"}) == {:error, :not_frozen}
      :ok = freeze(segment)
      assert GenServer.call(segment, {:pack_column, "missing"}) == {:error, :not_found}
      assert GenServer.call(segment, {:pack_column, "a"}) == :ok
      assert GenServer.call(segment, {:pack_column, "a"}) == :ok
    end

    test "put_column refuses a mutable column" do
      {:ok, segment} = start_link()
      :ok = segment_append(segment, %{"a" => 1})
      column = Guardian.Storage.Column.new(1)
      :ok = Guardian.Storage.Column.append(column, 5)

      assert_raise FunctionClauseError, fn -> put_column(segment, "a", column) end

      assert GenServer.call(segment, {:put_column, "a", column}) == {:error, :not_binary}
      {:ok, a} = get_column(segment, "a")
      assert Guardian.Storage.Column.to_list(a) == [1]
    end

    test "store refuses a segment that is not packed" do
      {:ok, segment} = start_link()
      :ok = segment_append(segment, %{"a" => 1})
      :ok = freeze(segment)
      assert_raise RuntimeError, "Column not packed", fn -> store(segment, @filename) end
      refute File.exists?(@filename)
    end
  end
end

# Run by SegmentTest in a child OS process, because the bug it guards against aborts the
# whole VM. One process appends to a mutable segment while readers query its columns the
# way a query does, then the segment is packed for persistence while they keep reading.
# Before columns were confined to their segment, this aborted the VM within a second or
# two with a failed assertion in column.c.
#
# Exits 0 and prints "ok ..." if every read saw the right values.

alias Storage.Column
alias Storage.Segment

# A watchdog, so a hang can't outlive the test.
spawn(fn ->
  Process.sleep(20_000)
  IO.puts("watchdog: no result after 20 s")
  System.halt(3)
end)

min_reader_ms = 3_000
min_rows = 2_000
string = String.duplicate("y", 200)

# Row j holds "i" => j, and "s" => string when rem(j, 7) == 0.
row = fn j -> if rem(j, 7) == 0, do: %{"i" => j, "s" => string}, else: %{"i" => j} end

{:ok, segment} = Segment.start_link(capacity: 10_000_000, max_bytes: :infinity)

# A seed row, so readers find both columns from the start.
:ok = Segment.append(segment, row.(0))

appender =
  Task.async(fn ->
    Stream.iterate(1, &(&1 + 1))
    |> Enum.reduce_while(nil, fn j, nil ->
      :ok = Segment.append(segment, row.(j))

      receive do
        :stop -> {:halt, j + 1}
      after
        0 -> {:cont, nil}
      end
    end)
  end)

stop = :atomics.new(1, [])
stopped? = fn -> :atomics.get(stop, 1) == 1 end

check_i = fn values, count ->
  unless values == Enum.to_list(0..(count - 1)) do
    raise "column i is wrong at count #{count}"
  end
end

check_s = fn values, count ->
  unless length(values) == count do
    raise "column s has #{length(values)} values at count #{count}"
  end

  values
  |> Enum.with_index()
  |> Enum.each(fn {value, j} ->
    expected = if rem(j, 7) == 0, do: string, else: nil

    unless value == expected do
      raise "column s is wrong at row #{j} of #{count}"
    end
  end)
end

# Reads a column as a query does: the packed column, cut or padded to the row count
# read just before it.
read_column = fn segment, key, count ->
  case Segment.get_column(segment, key) do
    {:ok, column} -> column |> Column.resize(count) |> Column.to_list()
    {:error, :not_found} -> List.duplicate(nil, count)
  end
end

loop = fn read ->
  Stream.repeatedly(read)
  |> Enum.reduce_while(0, fn _, n -> if stopped?.(), do: {:halt, n + 1}, else: {:cont, n + 1} end)
end

column_readers =
  for _ <- 1..4 do
    Task.async(fn ->
      loop.(fn ->
        {:ok, count} = Segment.count(segment)
        check_i.(read_column.(segment, "i", count), count)
        check_s.(read_column.(segment, "s", count), count)
      end)
    end)
  end

row_reader =
  Task.async(fn ->
    loop.(fn ->
      {:ok, count} = Segment.count(segment)
      j = :rand.uniform(count) - 1
      expected = row.(j)
      {:ok, ^expected} = Segment.get_row(segment, j)
    end)
  end)

# Phase 1: appends and reads overlap for at least `min_reader_ms`, and until the
# segment holds `min_rows` rows however slow the machine is.
Process.sleep(min_reader_ms)

Stream.repeatedly(fn ->
  {:ok, count} = Segment.count(segment)
  if count < min_rows, do: Process.sleep(50)
  count
end)
|> Enum.find(&(&1 >= min_rows))

send(appender.pid, :stop)
rows = Task.await(appender, :infinity)

# Phase 2: pack the segment for persistence while the readers keep reading, then let
# them read the packed segment for a while.
:ok = Segment.pack(segment)
{:ok, ^rows} = Segment.count(segment)
Process.sleep(500)

:atomics.put(stop, 1, 1)
column_reads = Enum.map(column_readers, &Task.await(&1, :infinity))
row_reads = Task.await(row_reader, :infinity)

# Joined rather than inspected: inspect/1 prints a list of small counts as a charlist.
IO.puts("ok rows=#{rows} column_reads=[#{Enum.join(column_reads, ", ")}] row_reads=#{row_reads}")

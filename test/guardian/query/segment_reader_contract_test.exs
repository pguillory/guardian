defmodule Guardian.Query.SegmentReaderContractTest do
  # Segment reads wait for slow segments and name the segment when one disappears; the
  # query time limit stops whatever is left. Suspends segments and changes the time
  # limit, so it runs alone.
  use ExUnit.Case, async: false
  import Guardian.Test.Query
  import Guardian.Test.Polling
  import Guardian.Test.Processes
  import Guardian.Test.Segments

  alias Guardian.Storage.Segment

  defp table do
    "reader_contract_#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}"
  end

  # Three full segments plus a partial one.
  defp fill(table, rows \\ 3 * 16_384 + 100) do
    1..rows
    |> Enum.map(&%{"v" => &1})
    |> Enum.chunk_every(5_000)
    |> Enum.each(&Guardian.Engine.ingest_events(table, &1))

    rows
  end

  # Full segments only (index 0 to 2), loaded; see Guardian.Test.Segments.loaded_segment/2.
  defp segment(table, index) do
    loaded_segment(table, index)
  end

  # Waits until some query worker is blocked reading a segment.
  defp await_blocked_reader do
    eventually(fn ->
      processes_running_all([Guardian.Storage.Segment, Guardian.Query.Executor]) != []
    end)
  end

  describe "segment reads" do
    test "a segment that is gone, or dies mid-call, returns segment_unavailable" do
      {:ok, segment} = Segment.start_link()
      :ok = Segment.append(segment, %{"a" => 1})
      assert Segment.count(segment) == {:ok, 1}
      assert Segment.get_column(segment, "missing") == {:error, :not_found}

      # Dies while a read waits on it.
      :sys.suspend(segment)
      task = Task.async(fn -> Segment.get_column(segment, "a") end)
      await_queued_call(segment)
      Process.unlink(segment)
      Process.exit(segment, :kill)
      assert Task.await(task) == {:error, {:segment_unavailable, :killed}}

      # Already gone.
      for read <- [
            &Segment.count/1,
            &Segment.full/1,
            &Segment.keys/1,
            &Segment.schema/1,
            &Segment.get_column(&1, "a"),
          ] do
        assert read.(segment) == {:error, {:segment_unavailable, :noproc}}
      end
    end

    test "a slow segment is waited for, unless the caller gives a timeout" do
      {:ok, segment} = Segment.start_link()
      :ok = Segment.append(segment, %{"a" => 1})
      :sys.suspend(segment)
      task = Task.async(fn -> Segment.count(segment) end)
      assert Segment.count(segment, 50) == {:error, {:segment_unavailable, :timeout}}
      Process.sleep(5_500)
      :sys.resume(segment)
      assert Task.await(task) == {:ok, 1}
      # The timed-out reply is dropped, not left in the mailbox.
      assert Process.info(self(), :messages) == {:messages, []}
    end

    test "pack still exits (for the persister) when the segment dies after freezing" do
      # A stand-in that answers the freeze and then dies, before pack reads its keys.
      fake =
        spawn(fn ->
          receive do
            {:"$gen_call", from, :freeze} -> GenServer.reply(from, :ok)
          end
        end)

      # The keys call finds the stand-in gone (`:noproc`) or sees it exit (`:normal`).
      assert {reason, {GenServer, :call, _}} = catch_exit(Segment.pack(fake))
      assert reason in [:noproc, :normal]
    end
  end

  describe "queries" do
    test "a segment suspended past 5 seconds still answers in full" do
      table = table()
      rows = fill(table)
      {_id, segment} = segment(table, 1)
      :sys.suspend(segment)
      spawn(fn -> Process.sleep(6_000) && :sys.resume(segment) end)

      assert run_sql("SELECT count() FROM #{table}") == [[rows]]
    end

    test "a segment deleted mid-query fails the query, naming it" do
      table = table()
      fill(table)
      {id, segment} = segment(table, 2)
      statement = resolve_sql("SELECT v FROM #{table} WHERE v > 0 ORDER BY v LIMIT 3")
      :sys.suspend(segment)
      task = Task.async(fn -> catch_error(Guardian.Query.run(statement)) end)
      await_blocked_reader()
      :ok = Guardian.Storage.delete_segment(id)

      assert %Guardian.Query.Error{message: message} = Task.await(task)
      assert message =~ "segment #{id} became unavailable during the query"
    end

    test "Storage's own reads give up on a hung segment after 5 seconds" do
      table = table()
      Guardian.Engine.ingest_events(table, [%{"v" => 1}])
      [id] = table |> Guardian.Storage.segment_ids() |> Enum.to_list()
      {:ok, segment} = Guardian.Storage.get_segment(id)
      :sys.suspend(segment)

      try do
        {micros, result} =
          :timer.tc(fn ->
            Task.async(fn -> catch_exit(Guardian.Storage.table_row_count(table)) end)
            |> Task.await(10_000)
          end)

        # Only the reason's kind: a crash report must not carry the segment's rows.
        assert result == {:segment_unavailable, ":timeout"}
        assert div(micros, 1000) in 4_900..8_000
      after
        :sys.resume(segment)
      end
    end

    test "a segment that is gone before its columns are read fails the query, naming it" do
      table = table()
      fill(table, 100)
      [id] = table |> Guardian.Storage.segment_ids() |> Enum.to_list()
      :ok = Guardian.Storage.delete_segment(id)

      snapshot = %Guardian.Query.Evaluation.SegmentSnapshot{segment: id, count: 100}

      assert_raise Guardian.Query.Error,
                   "segment #{id} became unavailable during the query (it was deleted, expired, or moved to its file)",
                   fn ->
                     Guardian.Query.Evaluation.eval(snapshot, %Guardian.AST.Node.Identifier{
                       name: "v",
                     })
                   end
    end
  end

  describe "the query time limit" do
    test "stops a query that runs past it on this node and leaves the caller clean" do
      table = table()
      fill(table)
      {_id, segment} = segment(table, 1)
      statement = resolve_sql("SELECT count() FROM #{table}")
      :sys.suspend(segment)

      with_time_limit(300, fn ->
        for _ <- 1..3 do
          assert_raise Guardian.Query.Error,
                       "query exceeded its time limit of 300 ms; narrow it with WHERE or LIMIT",
                       fn -> Guardian.Query.run(statement) end
        end
      end)

      assert Process.info(self(), :messages) == {:messages, []}
      assert Process.info(self(), :monitors) == {:monitors, []}
      :sys.resume(segment)
    end

    test "a result racing the limit never stays in the caller's mailbox" do
      table = table()
      fill(table, 20_000)
      statement = resolve_sql("SELECT count() FROM #{table}")

      # Limits around the query's own duration, so some runs finish just before the
      # limit and some just after.
      {micros, [[20_000]]} = :timer.tc(fn -> Guardian.Query.run(statement) end)
      duration_ms = max(div(micros, 1000), 2)

      outcomes =
        for limit_ms <- Enum.flat_map(1..(2 * duration_ms), &[&1, &1]) do
          with_time_limit(limit_ms, fn ->
            try do
              [[20_000]] = Guardian.Query.run(statement)
              :ok
            rescue
              Guardian.Query.Error -> :timeout
            end
          end)
        end

      assert :timeout in outcomes

      assert Process.info(self(), :messages) == {:messages, []}
    end

    test "the message names the configured limit" do
      assert Guardian.Query.Limits.time_limit_message(30_000) =~ "time limit of 30 seconds"
      assert Guardian.Query.Limits.time_limit_message(1_000) =~ "time limit of 1 second"
      assert Guardian.Query.Limits.time_limit_message(1_500) =~ "time limit of 1500 ms"
    end
  end
end

defmodule Query.HeapLimitTest do
  # Changes the global heap limit and counts live query processes, and starts a peer
  # node, so it must not run beside other tests.
  use ExUnit.Case, async: false
  import TestHelpers

  # The VM logs a report for each process its heap limit kills.
  @moduletag :capture_log

  alias Query.DistributedStream

  setup do
    previous = Application.fetch_env(:guardian, :query_max_heap_mb)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:guardian, :query_max_heap_mb, value)
        :error -> Application.delete_env(:guardian, :query_max_heap_mb)
      end
    end)
  end

  defp set_limit(mb), do: Application.put_env(:guardian, :query_max_heap_mb, mb)

  # Runs a pipeline as a trapping consumer, like the query process, in a fresh process.
  defp consume(fun) do
    task =
      Task.async(fn ->
        Process.flag(:trap_exit, true)

        try do
          {:ok, fun.()}
        catch
          :exit, reason -> {:exit, reason}
        end
      end)

    Task.await(task, 30_000)
  end

  defp assert_no_query_processes_left do
    await_no_processes_running([DistributedStream, Query, Query.Executor], except: [self()])
  end

  test "limit_heap/0 sets the configured limit, and nothing when it is off" do
    task = fn ->
      Task.async(fn ->
        Query.Limits.limit_heap()
        Process.info(self(), :max_heap_size)
      end)
      |> Task.await()
    end

    set_limit(0)
    assert {:max_heap_size, %{size: 0}} = task.()

    set_limit(64)
    words = div(64 * 1024 * 1024, :erlang.system_info(:wordsize))

    assert {:max_heap_size,
            %{size: ^words, kill: true, error_logger: true, include_shared_binaries: false}} =
             task.()
  end

  test "a worker over the limit fails the pipeline; under it, or with it off, it finishes" do
    run = fn ->
      consume(fn ->
        [1, 2]
        |> DistributedStream.fan_out(fn value -> {node(), value} end)
        |> DistributedStream.map(&DistributedStreamTestStages.grow_heap/1)
        |> DistributedStream.fan_in()
        |> Enum.to_list()
      end)
    end

    set_limit(1)
    assert run.() == {:exit, :killed}
    assert_no_query_processes_left()

    set_limit(64)
    assert run.() == {:ok, [200_000, 200_000]}

    set_limit(0)
    assert run.() == {:ok, [200_000, 200_000]}
  end

  test "the initial worker, which reads the input, is limited too" do
    set_limit(1)

    result =
      consume(fn ->
        Stream.map([1], &DistributedStreamTestStages.grow_heap/1)
        |> DistributedStream.fan_out(fn _ -> {node(), 1} end)
        |> DistributedStream.fan_in()
        |> Enum.to_list()
      end)

    assert result == {:exit, :killed}
    assert_no_query_processes_left()
  end

  test "a query over the limit (here sorting in its query process) fails with the heap message" do
    table = "heap_limit_#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}"

    marker = "HEAP_LIMIT_ROW_MARKER"

    1..40_000
    |> Enum.map(&%{"v" => &1, "w" => "#{marker}_#{&1}"})
    |> Enum.chunk_every(5_000)
    |> Enum.each(&Engine.ingest_events(table, &1))

    set_limit(1)

    log =
      ExUnit.CaptureLog.capture_log([level: :error], fn ->
        error = catch_error(run_sql("SELECT v, w FROM #{table} ORDER BY v DESC"))
        assert %Query.Error{message: message} = error
        assert message == Query.Limits.heap_kill_message()
        # The VM sends its report as the process dies; give the logger time to print it.
        Process.sleep(500)
      end)

    # The VM's report names the process and sizes, never the rows on its heap.
    assert log =~ "maximum heap size reached"
    refute log =~ marker
    assert_no_query_processes_left()

    set_limit(0)
    assert length(run_sql("SELECT v, w FROM #{table} ORDER BY v DESC")) == 40_000
  end

  test "a killed process is reported with the heap message, from the pipeline or the query" do
    assert Query.Failure.from_exit(:killed).message == Query.Limits.heap_kill_message()
    assert Query.Failure.query_process_down(:killed).message == Query.Limits.heap_kill_message()
  end

  describe "on a peer node" do
    setup do
      started_distribution = TestCluster.ensure_distributed()
      {peer, peer_node} = TestCluster.start_peer(nil)

      on_exit(fn ->
        :peer.stop(peer)
        if started_distribution, do: Node.stop()
      end)

      %{peer_node: peer_node}
    end

    test "a remote worker follows its own node's limit", %{peer_node: peer_node} do
      run = fn ->
        consume(fn ->
          [1]
          |> DistributedStream.fan_out(fn _ -> {peer_node, 1} end)
          |> DistributedStream.map(&DistributedStreamTestStages.grow_heap/1)
          |> DistributedStream.fan_in()
          |> Enum.to_list()
        end)
      end

      # Off here, on there: the remote worker is killed.
      set_limit(0)
      :ok = :erpc.call(peer_node, Application, :put_env, [:guardian, :query_max_heap_mb, 1])
      assert run.() == {:exit, :killed}

      # On here, off there: it finishes.
      set_limit(1)
      :ok = :erpc.call(peer_node, Application, :put_env, [:guardian, :query_max_heap_mb, 0])
      assert run.() == {:ok, [200_000]}
    end
  end
end

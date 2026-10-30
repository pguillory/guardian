defmodule Guardian.DetachedTest do
  use ExUnit.Case, async: true

  alias Guardian.Detached

  defmodule Raiser do
    def raise_it do
      raise ArgumentError, "boom"
    end
  end

  test "returns the function's result" do
    assert Detached.run(fn -> {:ok, 42} end) == {:ok, 42}
  end

  test "runs the function in another process" do
    caller = self()
    refute Detached.run(fn -> self() end) == caller
  end

  test "re-raises a raise with the worker's stacktrace" do
    error =
      try do
        Detached.run(&Raiser.raise_it/0)
      rescue
        error in ArgumentError -> {error, __STACKTRACE__}
      end

    assert {%ArgumentError{message: "boom"}, [{Raiser, :raise_it, 0, _} | _]} = error
  end

  test "re-raises throws and exits" do
    assert catch_throw(Detached.run(fn -> throw(:thrown) end)) == :thrown
    assert catch_exit(Detached.run(fn -> exit(:gone) end)) == :gone
  end

  test "exits with the worker's reason when the worker is killed" do
    test = self()

    fun = fn ->
      send(test, {:worker, self()})
      Process.sleep(:infinity)
    end

    caller = Task.async(fn -> catch_exit(Detached.run(fun)) end)
    assert_receive {:worker, worker}
    Process.exit(worker, :kill)
    assert Task.await(caller) == :killed
  end

  test "the function finishes when the caller is killed" do
    test = self()

    fun = fn ->
      receive do
        :go -> send(test, :finished)
      end
    end

    caller =
      spawn(fn ->
        Detached.run(fn ->
          send(test, {:worker, self()})
          fun.()
        end)
      end)

    assert_receive {:worker, worker}
    ref = Process.monitor(caller)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^ref, :process, ^caller, :killed}

    send(worker, :go)
    assert_receive :finished
  end
end

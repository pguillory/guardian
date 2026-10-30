defmodule Guardian.Counters.MachineTest do
  use ExUnit.Case, async: true
  alias Guardian.Counters.KeyMachines
  alias Guardian.Counters.Machine

  @sum Guardian.Aggregation.fetch!("sum")

  test "a new machine requires a non-nil operation" do
    # Exercise invalid input at runtime without a compile-time type warning.
    assert_raise FunctionClauseError, fn ->
      apply(Machine, :new, [nil, nil, fn _, _, _ -> {:done, :ok} end])
    end
  end

  test "a nil next operation raises instead of silently finishing" do
    broken = Machine.new({:get, :k}, :state, fn _, _, state -> {:next, nil, state} end)

    assert_raise ArgumentError, "next operation must not be nil", fn ->
      Machine.advance(broken, :ok)
    end
  end

  test "advance holds the next operation or finishes with a result" do
    expiry = System.monotonic_time(:millisecond) + 5_000
    machine = KeyMachines.merge(@sum, :k, 2, expiry)
    refute Machine.done?(machine)

    machine = Machine.advance(machine, {:ok, 5, :token})
    refute Machine.done?(machine)
    assert {:cas, :k, :token, 7, {:expires, ^expiry}} = machine.op

    machine = Machine.advance(machine, :ok)
    assert Machine.done?(machine)
    assert machine.result == {:ok, 7}
  end

  test "a raising callback finishes with a fixed error" do
    broken = Machine.new({:get, :k}, nil, fn _, _, _ -> raise "private" end)
    assert %Machine{op: nil, result: {:error, :invalid_state}} = Machine.advance(broken, :ok)
  end
end

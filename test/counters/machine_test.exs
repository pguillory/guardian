defmodule Counters.MachineTest do
  use ExUnit.Case, async: true
  alias Counters.{KeyMachines, Machine}

  test "nested rounds batch independent machines and preserve empty groups and result order" do
    parent = self()
    expiry = System.monotonic_time(:millisecond) + 5_000

    execute = fn requests, _ ->
      send(parent, {:round, requests})

      Map.new(requests, fn {id, op} ->
        response =
          case op do
            {:get, :a} -> {:ok, nil}
            {:get, :b} -> :not_found
            {:incr, :c, 1, _} -> {:ok, 4}
            {:gets, :d} -> {:ok, 5, :token}
            {:cas, :d, :token, 7, _} -> :ok
          end

        {id, response}
      end)
    end

    machines = [
      [],
      [KeyMachines.read(:a), KeyMachines.read(:b)],
      [],
      [KeyMachines.incr(:c, 1, expiry), KeyMachines.merge({"sum", 1}, :d, 2, expiry)],
      [],
    ]

    assert Machine.run_nested(machines, nil, execute) ==
             [[], [{:ok, nil}, :not_found], [], [{:ok, 4}, {:ok, 7}], []]

    assert_receive {:round, first}
    assert map_size(first) == 4
    assert_receive {:round, second}
    assert map_size(second) == 1
    assert {:cas, :d, :token, 7, _} = second[3]
    refute_receive {:round, _}
    assert Machine.run_nested([[], []], nil, execute) == [[], []]
    refute_receive {:round, _}
  end

  test "only definite conflicts retry, with three attempts, and callback exceptions are isolated" do
    parent = self()
    expiry = System.monotonic_time(:millisecond) + 5_000

    for failure <- [:conflict, :timeout] do
      execute = fn requests, _ ->
        Map.new(requests, fn {id, op} ->
          send(parent, elem(op, 0))

          {id,
           case op do
             {:gets, _} -> :not_found
             {:cas, _, _, _, _} -> {:error, failure}
           end}
        end)
      end

      assert Machine.run_nested([[KeyMachines.merge({"sum", 1}, :k, 1, expiry)]], nil, execute) ==
               [[{:error, failure}]]

      for _ <- 1..if(failure == :conflict, do: 3, else: 1) do
        assert_receive :gets
        assert_receive :cas
      end

      refute_receive :gets
    end

    broken = Machine.new({:get, :bad}, nil, fn _, _, _ -> raise "private" end)

    assert Machine.run_nested([[broken, KeyMachines.read(:good)]], nil, fn requests, _ ->
             Map.new(requests, fn {id, _} -> {id, {:ok, 8}} end)
           end) ==
             [[{:error, :invalid_state}, {:ok, 8}]]
  end

  test "strict equality preserves numeric type changes and unchanged states skip CAS" do
    expiry = System.monotonic_time(:millisecond) + 5_000
    parent = self()

    execute = fn requests, _ ->
      Map.new(requests, fn {id, op} ->
        case op do
          {:gets, _} ->
            {id, {:ok, 1, :token}}

          {:cas, _, _, value, _} ->
            send(parent, {:write, value})
            {id, :ok}
        end
      end)
    end

    assert Machine.run_nested(
             [
               [
                 KeyMachines.merge({"min", 1}, :k, 1.0, expiry),
                 KeyMachines.merge({"max", 1}, :k, 0, expiry),
               ],
             ],
             nil,
             execute
           ) == [[{:ok, 1.0}, {:ok, 1}]]

    assert_receive {:write, value}
    assert value === 1.0
    refute_receive {:write, _}
  end
end

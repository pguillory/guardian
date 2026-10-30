defmodule Guardian.FailureTest do
  use ExUnit.Case, async: true
  import Guardian.Failure

  test "caught failures retain their existing value-free labels" do
    stack = [{__MODULE__, :example, ["PRIVATE"], []}]

    for {reason, expected} <- [
          {%RuntimeError{message: "PRIVATE"}, "RuntimeError"},
          {:badarg, "ArgumentError"},
          {{:badmatch, "PRIVATE"}, "MatchError"},
        ] do
      assert kind(:error, reason, stack) == expected
    end

    assert kind(:exit, {:timeout, {GenServer, :call, ["PRIVATE"]}}, stack) ==
             "exit :timeout"

    assert kind(:throw, {"PRIVATE", self()}, stack) == "throw"
  end

  test "exit labels unwrap GenServer calls without inspecting carried values" do
    for {reason, expected} <- [
          {:normal, ":normal"},
          {:killed, ":killed"},
          {:timeout, ":timeout"},
          {{:shutdown, "PRIVATE"}, ":shutdown"},
          {{%ArgumentError{message: "PRIVATE"}, []}, "ArgumentError"},
          {{{:badmatch, "PRIVATE"}, []}, "an abnormal exit"},
          {%{"PRIVATE" => self()}, "an abnormal exit"},
        ] do
      assert exit_kind(reason) == expected

      wrapped = {reason, {GenServer, :call, ["PRIVATE"]}}
      assert exit_kind(wrapped) == expected
      assert exit_kind({wrapped, {GenServer, :call, ["PRIVATE"]}}) == expected
    end

    crash = {%ArgumentError{message: "PRIVATE"}, [{__MODULE__, :fun, ["PRIVATE"], []}]}
    assert exit_kind({crash, {GenServer, :call, ["PRIVATE"]}}) == "ArgumentError"
  end
end

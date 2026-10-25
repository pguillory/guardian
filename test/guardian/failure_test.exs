defmodule Guardian.FailureTest do
  use ExUnit.Case, async: true

  alias Guardian.Failure

  test "caught failures retain their existing value-free labels" do
    stack = [{__MODULE__, :example, ["PRIVATE"], []}]

    for {reason, expected} <- [
          {%RuntimeError{message: "PRIVATE"}, "RuntimeError"},
          {:badarg, "ArgumentError"},
          {{:badmatch, "PRIVATE"}, "MatchError"},
        ] do
      assert Failure.kind(:error, reason, stack) == expected
      assert Guardian.Engine.failure_kind(:error, reason, stack) == expected
    end

    assert Failure.kind(:exit, {:timeout, {GenServer, :call, ["PRIVATE"]}}, stack) ==
             "exit :timeout"

    assert Failure.kind(:throw, {"PRIVATE", self()}, stack) == "throw"
  end

  test "exit labels unwrap GenServer calls without inspecting carried values" do
    for {reason, expected} <- [
          {:normal, ":normal"},
          {:killed, ":killed"},
          {{:shutdown, "PRIVATE"}, ":shutdown"},
          {{%ArgumentError{message: "PRIVATE"}, []}, "ArgumentError"},
          {{{:badmatch, "PRIVATE"}, []}, "an abnormal exit"},
          {%{"PRIVATE" => self()}, "an abnormal exit"},
        ] do
      assert Failure.exit_kind(reason) == expected
      assert Guardian.Storage.exit_kind(reason) == expected

      wrapped = {reason, {GenServer, :call, ["PRIVATE"]}}
      assert Failure.exit_kind(wrapped) == expected
      assert Failure.exit_kind({wrapped, {GenServer, :call, ["PRIVATE"]}}) == expected
    end
  end

  test "raw callback reason labels stay distinct from normalized caught errors" do
    assert Failure.reason_kind(%ArgumentError{message: "PRIVATE"}) == "ArgumentError"
    assert Failure.reason_kind(:badarg) == ":badarg"
    assert Failure.reason_kind({:badmatch, "PRIVATE", self()}) == ":badmatch"
    assert Failure.reason_kind({}) == "term"
    assert Failure.reason_kind({"PRIVATE", self()}) == "term"
    assert Failure.reason_kind(%{"PRIVATE" => self()}) == "term"
  end

  test "MFA frames keep arity and only typed file and line locations" do
    location = [
      file: ~c"example.ex",
      line: 7,
      error_info: %{cause: "PRIVATE"},
      file: ["PRIVATE"],
      line: "PRIVATE",
      line: -1,
    ]

    assert Failure.stacktrace([
             {__MODULE__, :example, ["PRIVATE", %{value: "PRIVATE"}], location},
             {__MODULE__, :example, 2, location},
           ]) == [
             {__MODULE__, :example, 2, [file: ~c"example.ex", line: 7]},
             {__MODULE__, :example, 2, [file: ~c"example.ex", line: 7]},
           ]
  end

  test "fun and unsupported frames become a fixed frame without closures or values" do
    marker = "PRIVATE"
    frame = {fn -> marker end, [marker], [file: ~c"example.ex", line: 7]}

    for frame <- [
          frame,
          {marker, :example, 1, []},
          {__MODULE__, marker, 1, []},
          {__MODULE__, :example, -1, []},
          {__MODULE__, :example, marker, []},
          {__MODULE__, :example, 1, marker},
          {:unknown, marker},
        ] do
      assert Failure.stacktrace([frame]) == [{Failure, :redacted, 0, []}]
    end

    assert Failure.stacktrace([]) == []
  end
end

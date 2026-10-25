defmodule Guardian.Query.FailureTest do
  use ExUnit.Case, async: true

  alias Guardian.Query.Failure

  describe "truncate/1" do
    test "keeps short valid messages as they are" do
      assert Failure.truncate("division by zero") == "division by zero"
    end

    test "cuts long messages on a codepoint boundary within the byte limit" do
      message = Failure.truncate("a" <> String.duplicate("é", 1000))
      assert String.valid?(message)
      assert String.ends_with?(message, "...")
      assert byte_size(message) <= 1024 + 3
      assert {:ok, _} = Jason.encode(message)
    end

    test "replaces invalid UTF-8 so the message can be JSON-encoded" do
      message = Failure.truncate("bad " <> <<0xC3>>)
      assert String.valid?(message)
      assert {:ok, _} = Jason.encode(message)
    end
  end

  test "from_exit/1 turns pipeline exit reasons into bounded messages" do
    message = &Failure.from_exit(&1).message

    assert message.({%Guardian.Query.Error{message: String.duplicate("e", 5_000)}, []}) ==
             String.duplicate("e", 1_024) <> "..."

    assert message.({%RuntimeError{message: "boom"}, []}) == "query evaluation failed: boom"

    for reason <- [
          :noconnection,
          {:nodedown, :peer@host},
          {:distributed_stream, {:sender_down, :noconnection}},
          {:distributed_stream, {:receiver_down, :noconnection}},
          {:distributed_stream, {:router_down, :noconnection}},
        ] do
      assert message.(reason) == "query failed: a machine disconnected during the query"
    end

    assert message.({:distributed_stream, {:lost_input, 3}}) ==
             "query failed: 3 chunk(s) of rows were lost between machines"

    assert message.({:distributed_stream, {:sender_down, :noproc}}) ==
             "query failed: a query worker stopped before all its rows were passed on (:noproc)"

    assert message.({:distributed_stream, :worker_exited}) ==
             "query failed: a query worker exited before finishing"

    assert message.({:distributed_stream, :worker_finished_early}) ==
             "query failed: a query worker finished before reading all its input"

    assert message.({:distributed_stream, :input_exited}) ==
             "query failed: the query's input ended without finishing"

    assert message.({:distributed_stream, :unexpected_sender}) ==
             "query failed: a query worker received rows from an unknown sender"

    # An Erlang-level crash keeps its message and drops its stack and arguments.
    stack = [{Guardian.Storage, :get_segment, [String.duplicate("a", 10_000)], []}]
    badmatch = message.({{:badmatch, {:error, :not_found}}, stack})

    assert badmatch =~
             ~r/^query evaluation failed: no match of right hand side value:\s+\{:error, :not_found\}\s*$/

    # Anything else is inspected with limits, and cut to 1 KiB.
    long = message.({:weird, String.duplicate("v", 100_000), Enum.to_list(1..1_000)})
    assert byte_size(long) <= 1_024 + 3
    assert long =~ "query failed: a query process exited ({:weird"
  end
end

defmodule Guardian.Web.IngestRetryTest do
  use ExUnit.Case, async: false

  @api_key Application.compile_env!(:guardian, :api_key)

  defp table, do: "ingest_retry_#{System.unique_integer([:positive])}"

  defp post(params) do
    conn =
      Plug.Test.conn(:post, "/api/json/send_events", params)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("x-api-key", @api_key)
      |> Guardian.Web.MainRouter.call(nil)

    {conn.status, Jason.decode!(conn.resp_body)}
  end

  test "HTTP retries acknowledge a completed batch without storing it again" do
    table = table()

    params = %{
      "table" => table,
      "events" => [%{"value" => 1, "other" => "kept"}],
      "return_keys" => ["value"],
      "idempotency_key" => "lost-response",
    }

    assert post(params) ==
             {200,
              %{"status" => 200, "results" => [%{"success" => true, "event" => %{"value" => 1}}]}}

    assert post(params) == {200, %{"status" => 200, "duplicate" => true, "failed_events" => 0}}
    assert Guardian.Storage.dump_table(table) == params["events"]

    for changed <- [
          Map.put(params, "events", [%{"value" => 2}]),
          Map.put(params, "return_keys", []),
        ] do
      assert {409, %{"status" => 409, "info" => info}} = post(changed)
      assert info =~ "different events or return_keys"
    end

    assert Guardian.Storage.dump_table(table) == params["events"]
  end

  test "per-table scope and absent/null keys retain ordinary ingest behavior" do
    first = table()
    second = table()
    event = %{"value" => 1}
    params = %{"table" => first, "events" => [event], "idempotency_key" => "same-key"}
    assert {200, %{"results" => [_]}} = post(params)
    assert {200, %{"results" => [_]}} = post(Map.put(params, "table", second))
    assert Guardian.Storage.dump_table(first) == [event]
    assert Guardian.Storage.dump_table(second) == [event]

    for params <- [Map.delete(params, "idempotency_key"), Map.put(params, "idempotency_key", nil)] do
      assert {200, %{"results" => [_]}} = post(params)
      assert {200, %{"results" => [_]}} = post(params)
    end

    assert length(Guardian.Storage.dump_table(first)) == 5
  end

  test "keys are validated before claims and corrected invalid requests can reuse the key" do
    table = table()
    valid = %{"table" => table, "events" => [%{"value" => 1}], "idempotency_key" => "valid"}

    for key <- ["", true, 1, [], %{}, String.duplicate("x", 129), String.duplicate("雪", 43)] do
      assert {400, %{"info" => info}} = post(Map.put(valid, "idempotency_key", key))
      assert info =~ "idempotency_key"
      assert Guardian.Storage.dump_table(table) == []
    end

    assert {:error, message} =
             Guardian.Web.Ingest.send_events(Map.put(valid, "idempotency_key", <<255>>))

    assert message =~ "UTF-8"

    for invalid <- [Map.delete(valid, "events"), Map.put(valid, "return_keys", false)] do
      assert {400, _} = post(invalid)
    end

    assert {200, %{"results" => [_]}} = post(valid)
    max_key = String.duplicate("x", 128)
    assert {200, %{"results" => [_]}} = post(Map.put(valid, "idempotency_key", max_key))
  end

  test "receipts count partial and total failures without retrying their batches" do
    for {events, failed} <- [{[%{"value" => 1}, nil], 1}, {[false, nil], 2}, {[], 0}] do
      table = table()
      params = %{"table" => table, "events" => events, "idempotency_key" => "partial"}
      assert {200, %{"results" => results}} = post(params)
      assert length(results) == length(events)

      assert post(params) ==
               {200, %{"status" => 200, "duplicate" => true, "failed_events" => failed}}

      assert length(Guardian.Storage.dump_table(table)) == length(events) - failed
    end
  end

  test "digest ignores object key order and treats omitted/null return_keys alike" do
    table = table()
    fields = for n <- 1..40, into: %{}, do: {"key_#{n}", n}
    event = Map.merge(fields, %{"a" => 1, "b" => %{"c" => 2}})

    first = %{
      "table" => table,
      "events" => [event],
      "idempotency_key" => "objects",
    }

    assert {200, %{"results" => [_]}} = post(first)

    reordered =
      for(n <- 40..1//-1, into: %{}, do: {"key_#{n}", n})
      |> Map.merge(Jason.decode!(~s({"b":{"c":2},"a":1})))

    retry = first |> Map.put("events", [reordered]) |> Map.put("return_keys", nil)
    assert {200, %{"duplicate" => true}} = post(retry)

    assert {409, _} = post(Map.put(first, "events", [Map.put(event, "a", 1.0)]))
  end

  test "HTTP pending and uncertain outcomes return conflicts and never write" do
    table = table()
    events = [%{"value" => 1}]
    key = "pending"
    token = make_ref()
    digest = :crypto.hash(:sha256, :erlang.term_to_binary({events, nil}, [:deterministic]))
    server = Guardian.Web.IngestIdempotency
    assert GenServer.call(server, {:claim, {table, key}, digest, token}) == :claimed
    params = %{"table" => table, "events" => events, "idempotency_key" => key}
    assert {409, %{"info" => message}} = post(params)
    assert message =~ "in flight"
    assert GenServer.call(server, {:finish, token, :uncertain}) == :ok
    assert {409, %{"info" => message}} = post(params)
    assert message =~ "may have been stored"
    assert Guardian.Storage.dump_table(table) == []
  end

  test "a stopped coordinator preserves valid HTTP ingestion" do
    server = Guardian.Web.IngestIdempotency
    :ok = Supervisor.terminate_child(Guardian.Main, server)

    try do
      table = table()
      event = %{"value" => 1}
      params = %{"table" => table, "events" => [event], "idempotency_key" => "unavailable"}
      assert {200, %{"results" => [_]}} = post(params)
      assert {200, %{"results" => [_]}} = post(params)
      assert Guardian.Storage.dump_table(table) == [event, event]
    after
      {:ok, _pid} = Supervisor.restart_child(Guardian.Main, server)
    end
  end
end

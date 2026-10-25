defmodule Guardian.Rules.StoreTest do
  use ExUnit.Case, async: false
  import Guardian.RulesTestHelper

  alias Guardian.Rules.Store

  setup do
    s3 = Guardian.FakeS3.start(page_size: 2)
    on_exit(fn -> Guardian.FakeS3.stop(s3) end)
    dir = Path.join(System.tmp_dir!(), "rules_store_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, local} = Guardian.Rules.Store.Local.new(dir)
    %{s3: s3, stores: [local: local, s3: Guardian.FakeS3.store(s3, "guardian/")]}
  end

  test "list, get, conditional put and delete behave the same on both stores", %{stores: stores} do
    for {_kind, store} <- stores do
      assert Store.list(store) == {:ok, []}
      assert {:ok, etag1} = Store.put(store, "t/a.gsql", "SET a = 1", :absent)
      assert Store.put(store, "t/a.gsql", "SET a = 2", :absent) == {:error, :precondition_failed}

      assert Store.put(store, "t/a.gsql", "SET a = 2", {:etag, "nope"}) ==
               {:error, :precondition_failed}

      assert {:ok, etag2} = Store.put(store, "t/a.gsql", "SET a = 2", {:etag, etag1})
      assert {:ok, _} = Store.put(store, "u/b.gsql", "SET b = 1", :none)
      assert {:ok, _} = Store.put(store, "v/c.gsql", "SET c = 1", :none)

      assert {:ok, objects} = Store.list(store)
      assert Enum.map(objects, & &1.key) == ["t/a.gsql", "u/b.gsql", "v/c.gsql"]
      assert %{etag: ^etag2, size: 9} = hd(objects)

      assert {:ok, "SET a = 2", %{etag: ^etag2, age_ms: age}} =
               Store.get(store, "t/a.gsql", etag2)

      assert age >= 0 and age < 5_000
      assert Store.get(store, "t/a.gsql", etag1) == {:error, :precondition_failed}
      assert Store.get(store, "t/missing.gsql") == {:error, :not_found}

      assert Store.delete(store, "u/b.gsql") == :ok
      assert Store.delete(store, "u/b.gsql") == :ok
      assert {:ok, [_, _]} = Store.list(store)
    end
  end

  test "S3 requests are signed, paginated and prefix-scoped", %{s3: s3, stores: stores} do
    store = stores[:s3]
    Guardian.FakeS3.put_object(s3, "other/x.gsql", "not ours")
    for n <- 1..5, do: {:ok, _} = Store.put(store, "t/f#{n}.gsql", "SET a = #{n}", :absent)

    assert {:ok, objects} = Store.list(store)
    assert length(objects) == 5

    lists =
      s3
      |> Guardian.FakeS3.requests()
      |> Enum.filter(&(&1.method == "GET" and &1.path == "/rules-bucket"))

    assert length(lists) == 3
    assert Enum.any?(lists, &(&1.query =~ "continuation-token="))
    assert Map.has_key?(Guardian.FakeS3.objects(s3), "guardian/t/f1.gsql")
  end

  test "S3 with the wrong secret is misconfigured, and no secret reaches a log or inspect", %{
    s3: s3,
  } do
    wrong = %{s3 | secret_access_key: "WRONG-SECRET-VALUE"}
    store = Guardian.FakeS3.store(wrong)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert Store.list(store) == {:error, {:misconfigured, "HTTP 403"}}
        assert Store.put(store, "t/a.gsql", "x", :none) == {:error, {:misconfigured, "HTTP 403"}}
      end)

    refute log =~ "WRONG-SECRET-VALUE"
    refute inspect(store) =~ "WRONG-SECRET-VALUE"
    refute inspect(Guardian.FakeS3.store(s3)) =~ s3.secret_access_key
  end

  test "S3 failures are classified by kind", %{s3: s3, stores: stores} do
    store = stores[:s3]
    put_env(:rules_s3_receive_timeout_ms, 200)
    put_env(:rules_s3_write_deadline_ms, 300)

    Guardian.FakeS3.fault(s3, {:status, 503})
    assert Store.list(store) == {:error, {:unreachable, "HTTP 503"}}
    Guardian.FakeS3.fault(s3, {:status, 500})
    assert Store.put(store, "t/a.gsql", "x", :none) == {:error, {:unknown, "HTTP 500"}}

    # Rate limited: a read can be retried, and a write is known not to have happened.
    Guardian.FakeS3.put_object(s3, "guardian/t/b.gsql", "SET x = 1")
    assert {:ok, _, _} = Store.get(store, "t/b.gsql")
    Guardian.FakeS3.fault(s3, {:status, 429})
    assert Store.list(store) == {:error, {:unreachable, "HTTP 429"}}
    Guardian.FakeS3.fault(s3, {:status, 429})
    assert Store.get(store, "t/b.gsql") == {:error, {:unreachable, "HTTP 429"}}
    Guardian.FakeS3.fault(s3, {:status, 429})
    assert Store.put(store, "t/a.gsql", "x", :none) == {:error, {:failed, "HTTP 429"}}
    Guardian.FakeS3.fault(s3, {:status, 429})
    assert Store.delete(store, "t/b.gsql") == {:error, {:failed, "HTTP 429"}}
    assert Map.keys(Guardian.FakeS3.objects(s3)) == ["guardian/t/b.gsql"]
    Guardian.FakeS3.fault(s3, {:delay, 1_000})
    assert {:error, {:unreachable, "timeout"}} = Store.list(store)
    Guardian.FakeS3.fault(s3, {:delay, 1_000})
    assert {:error, {:unknown, _}} = Store.put(store, "t/a.gsql", "x", :none)

    closed = Guardian.FakeS3.store(%{s3 | endpoint: "http://localhost:1"})
    assert {:error, {:unreachable, "econnrefused"}} = Store.list(closed)
    assert {:error, {:unreachable, "econnrefused"}} = Store.put(closed, "t/a.gsql", "x", :none)
  end

  test "the S3 HTTP date parser" do
    assert Guardian.Rules.Store.S3.parse_http_date("Wed, 21 Oct 2015 07:28:00 GMT") ==
             {:ok, ~U[2015-10-21 07:28:00Z]}

    assert Guardian.Rules.Store.S3.parse_http_date("garbage") == :error
  end

  test "the local store skips folders named like rule files and fails on unreadable ones", %{
    stores: stores,
  } do
    {Store.Local, %{dir: dir}} = local = stores[:local]
    File.mkdir_p!(Path.join(dir, "t/folder.gsql"))
    {:ok, _} = Store.put(local, "t/a.gsql", "SET x = 1", :absent)
    assert {:ok, [%{key: "t/a.gsql"}]} = Store.list(local)

    path = Path.join(dir, "t/a.gsql")
    File.chmod!(path, 0o000)
    on_exit(fn -> File.chmod(path, 0o644) end)
    assert {:error, {:failed, "t/a.gsql: eacces"}} = Store.list(local)
  end

  test "S3 list responses with entities are refused" do
    body =
      ~s(<?xml version="1.0"?><!DOCTYPE a [<!ENTITY e "x">]><ListBucketResult>&e;</ListBucketResult>)

    assert catch_exit(Guardian.Rules.Store.S3.parse_list(body, ""))
  end
end

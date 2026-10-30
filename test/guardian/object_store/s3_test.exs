defmodule Guardian.ObjectStore.S3Test do
  # Not async: tests set the S3 timeouts in the application env, which is node-wide.
  use ExUnit.Case, async: false
  import Guardian.ObjectStore.S3

  alias Guardian.ObjectStore
  alias Guardian.ObjectStore.S3

  setup do
    s3 = Guardian.Test.FakeS3.start(page_size: 2)
    on_exit(fn -> Guardian.Test.FakeS3.stop(s3) end)
    %{s3: s3, store: Guardian.Test.FakeS3.store(s3, "guardian/")}
  end

  test "S3 requests are signed, paginated and prefix-scoped", %{s3: s3, store: store} do
    Guardian.Test.FakeS3.put_object(s3, "other/x.gsql", "not ours")
    for n <- 1..5, do: {:ok, _} = ObjectStore.put(store, "t/f#{n}.gsql", "SET a = #{n}", :absent)

    assert {:ok, objects} = ObjectStore.list(store)
    assert length(objects) == 5

    lists =
      s3
      |> Guardian.Test.FakeS3.requests()
      |> Enum.filter(&(&1.method == "GET" and &1.path == "/rules-bucket"))

    assert length(lists) == 3
    assert Enum.any?(lists, &(&1.query =~ "continuation-token="))
    assert Map.has_key?(Guardian.Test.FakeS3.objects(s3), "guardian/t/f1.gsql")
  end

  test "S3 with the wrong secret is misconfigured, and inspect never shows a secret", %{
    s3: s3,
  } do
    wrong = %{s3 | secret_access_key: "WRONG-SECRET-VALUE"}
    store = Guardian.Test.FakeS3.store(wrong)

    assert ObjectStore.list(store) == {:error, {:misconfigured, "HTTP 403"}}

    assert ObjectStore.put(store, "t/a.gsql", "x", :none) ==
             {:error, {:misconfigured, "HTTP 403"}}

    refute inspect(store) =~ "WRONG-SECRET-VALUE"
    refute inspect(Guardian.Test.FakeS3.store(s3)) =~ s3.secret_access_key
  end

  test "S3 failures are classified by kind", %{s3: s3, store: store} do
    Guardian.Test.Env.put(
      object_store_s3_receive_timeout_ms: 200,
      object_store_s3_write_deadline_ms: 300
    )

    assert write_deadline_ms() == 300

    Guardian.Test.FakeS3.fault(s3, {:status, 503})
    assert ObjectStore.list(store) == {:error, {:unreachable, "HTTP 503"}}
    Guardian.Test.FakeS3.fault(s3, {:status, 500})
    assert ObjectStore.put(store, "t/a.gsql", "x", :none) == {:error, {:unknown, "HTTP 500"}}

    # Rate limited: a read can be retried, and a write is known not to have happened.
    Guardian.Test.FakeS3.put_object(s3, "guardian/t/b.gsql", "SET x = 1")
    assert {:ok, _, _} = ObjectStore.get(store, "t/b.gsql")
    Guardian.Test.FakeS3.fault(s3, {:status, 429})
    assert ObjectStore.list(store) == {:error, {:unreachable, "HTTP 429"}}
    Guardian.Test.FakeS3.fault(s3, {:status, 429})
    assert ObjectStore.get(store, "t/b.gsql") == {:error, {:unreachable, "HTTP 429"}}
    Guardian.Test.FakeS3.fault(s3, {:status, 429})
    assert ObjectStore.put(store, "t/a.gsql", "x", :none) == {:error, {:failed, "HTTP 429"}}
    Guardian.Test.FakeS3.fault(s3, {:status, 429})
    assert ObjectStore.delete(store, "t/b.gsql") == {:error, {:failed, "HTTP 429"}}
    assert Map.keys(Guardian.Test.FakeS3.objects(s3)) == ["guardian/t/b.gsql"]
    Guardian.Test.FakeS3.fault(s3, {:delay, 1_000})
    assert {:error, {:unreachable, "timeout"}} = ObjectStore.list(store)
    Guardian.Test.FakeS3.fault(s3, {:delay, 1_000})
    assert {:error, {:unknown, _}} = ObjectStore.put(store, "t/a.gsql", "x", :none)

    closed = Guardian.Test.FakeS3.store(%{s3 | endpoint: "http://localhost:1"})
    assert {:error, {:unreachable, "econnrefused"}} = ObjectStore.list(closed)

    assert {:error, {:unreachable, "econnrefused"}} =
             ObjectStore.put(closed, "t/a.gsql", "x", :none)
  end

  test "the S3 HTTP date parser" do
    assert parse_http_date("Wed, 21 Oct 2015 07:28:00 GMT") ==
             {:ok, ~U[2015-10-21 07:28:00Z]}

    assert parse_http_date("garbage") == :error
  end

  test "an object's age is nil without a Last-Modified it can parse" do
    date = "Wed, 21 Oct 2015 07:28:00 GMT"
    modified = "Wed, 21 Oct 2015 07:27:00 GMT"
    response = fn headers -> Req.Response.new(headers: headers) end

    assert age_ms(response.([{"date", date}, {"last-modified", modified}])) == 60_000
    assert age_ms(response.([{"date", date}])) == nil
    assert age_ms(response.([{"date", date}, {"last-modified", "yesterday"}])) == nil
  end

  test "S3 list responses with entities are refused" do
    body =
      ~s(<?xml version="1.0"?><!DOCTYPE a [<!ENTITY e "x">]><ListBucketResult>&e;</ListBucketResult>)

    assert parse_list(body, "") == {:error, {:unreachable, "malformed listing"}}
  end

  test "a garbage S3 listing is a reason, never a crash" do
    malformed = {:error, {:unreachable, "malformed listing"}}
    assert parse_list("not xml", "") == malformed
    assert parse_list(<<0xFF, 0xFE>>, "") == malformed

    bad_size =
      "<ListBucketResult><Contents><Key>k</Key><Size>big</Size></Contents></ListBucketResult>"

    assert parse_list(bad_size, "") == malformed
  end

  test "a listing stops after max_list_pages pages", %{s3: s3} do
    {S3, config} = Guardian.Test.FakeS3.store(s3)
    store = {S3, %{config | max_list_pages: 2}}
    for n <- 1..4, do: {:ok, _} = ObjectStore.put(store, "f#{n}", "x", :absent)
    assert {:ok, [_, _, _, _]} = ObjectStore.list(store)
    {:ok, _} = ObjectStore.put(store, "f5", "x", :absent)
    assert ObjectStore.list(store) == {:error, {:failed, "too many objects"}}
  end

  test "endpoint and prefix checks" do
    assert check_endpoint("https://example.com") == :ok
    assert check_endpoint("http://localhost:9000") == :ok
    assert check_endpoint("http://127.0.0.5") == :ok
    assert check_endpoint("http://[::1]:9000") == :ok
    assert check_endpoint("http://example.com") == {:error, :insecure}
    assert check_endpoint("https://example.com/path") == {:error, :not_url}
    assert check_endpoint("ftp://example.com") == {:error, :not_url}
    assert check_prefix("") == :ok
    assert check_prefix("a/b/") == :ok
    assert check_prefix("a") == {:error, :no_trailing_slash}
    assert check_prefix("a b/") == {:error, :invalid_characters}
  end
end

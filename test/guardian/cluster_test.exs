defmodule Guardian.ClusterTest do
  import Guardian.Cluster
  # Not async: tests set the application env, which is node-wide.
  use ExUnit.Case, async: false

  test "discovery is off without a DNS query" do
    assert Application.get_env(:guardian, :dns_cluster_query) == nil
    {DNSCluster, opts} = discovery_child_spec()
    assert opts[:query] == :ignore
    assert DNSCluster.start_link(Keyword.put(opts, :name, :cluster_test_dns)) == :ignore
  end

  describe "with a DNS query" do
    setup do
      Guardian.Test.Env.put(dns_cluster_query: "my-app.internal")
      :ok
    end

    test "an IPv6-named node, as on Fly, looks up AAAA records" do
      assert {DNSCluster, opts} =
               discovery_child_spec(:"guardian@fdaa:0:1a2b:a7b:16b:0:42:2")

      assert opts[:query] == "my-app.internal"
      assert opts[:resource_types] == [:aaaa]

      assert {DNSCluster, opts} = discovery_child_spec(:"guardian@fdaa:0:1::2")
      assert opts[:resource_types] == [:aaaa]
    end

    test "an IPv4-named node looks up A records" do
      assert {DNSCluster, opts} = discovery_child_spec(:"guardian@10.0.0.5")
      assert opts[:resource_types] == [:a]
    end

    test "a node whose name DNS discovery cannot reach refuses to start" do
      for {name, problem} <- [
            {:"guardian@2001:0db8:0000:0000:0000:0000:0000:0001",
             "write its address as 2001:db8::1"},
            {:"guardian@FDAA:0:1::2", "write its address as fdaa:0:1::2"},
            {:"guardian@010.0.0.5", "not an IP address"},
            {:"guardian@127.0.0.1", "loopback"},
            {:"guardian@::1", "loopback"},
            {:guardian@localhost, "not an IP address"},
            {:"guardian@db.example.com", "not an IP address"},
            {:nonode@nohost, "not an IP address"},
          ] do
        error = assert_raise ArgumentError, fn -> discovery_child_spec(name) end
        assert error.message =~ "DNS_CLUSTER_QUERY is set"
        assert error.message =~ problem, inspect(name)
      end
    end
  end
end

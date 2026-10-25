defmodule Guardian.RegistrationTest do
  alias Guardian.Storage.Segment
  import Guardian.Storage.Segment.Registration
  use ExUnit.Case, async: true

  test "tuple" do
    {:ok, segment} = Segment.start_link()
    tuple = tuple(segment_id: "A", segment: segment, table: "foo")
    assert tuple == {"A", segment, "foo"}
    assert tuple |> segment_id() == "A"
    assert tuple |> segment() == segment
    assert tuple |> table() == "foo"
  end

  test "match_spec" do
    {:ok, segment1} = Segment.start_link()
    {:ok, segment2} = Segment.start_link()
    {:ok, segment3} = Segment.start_link()

    tab = :ets.new(nil, [])

    true =
      :ets.insert(tab, tuple(segment_id: "A", segment: segment1, table: "foo"))

    true =
      :ets.insert(tab, tuple(segment_id: "B", segment: segment2, table: "bar"))

    true =
      :ets.insert(tab, tuple(segment_id: "C", segment: segment3, table: "bar"))

    assert :ets.select(tab, match_spec(table: "foo")) == [{"A", segment1, "foo"}]

    assert :ets.select(tab, match_spec(segment: segment1, select: :segment_id)) == ["A"]
    assert :ets.select(tab, match_spec(segment_id: "A", select: :segment)) == [segment1]
    assert :ets.select(tab, match_spec(segment_id: "A", select: :table)) == ["foo"]
  end

  describe "registry helpers" do
    setup do
      registry = :ets.new(nil, [:ordered_set])
      {:ok, a} = Segment.start_link()
      {:ok, b} = Segment.start_link()
      {:ok, c} = Segment.start_link()
      true = :ets.insert(registry, tuple(segment_id: "A", segment: a, table: "foo"))
      true = :ets.insert(registry, tuple(segment_id: "B", segment: b, table: "bar"))
      true = :ets.insert(registry, tuple(segment_id: "C", segment: c, table: "bar"))
      %{registry: registry, a: a, b: b, c: c}
    end

    test "segment_ids/2 and all_segment_ids/1", %{registry: registry} do
      assert segment_ids(registry, "bar") == ["B", "C"]
      assert segment_ids(registry, "missing") == []
      assert all_segment_ids(registry) == ["A", "B", "C"]
    end

    test "lookup/2", %{registry: registry, a: a} do
      assert lookup(registry, "A") == {:ok, a}
      assert lookup(registry, "Z") == {:error, :not_found}
    end

    test "retire_segment_id/2 retires only that ID's registration",
         %{registry: registry, a: a, b: b} do
      Process.flag(:trap_exit, true)
      assert retire_segment_id(registry, "A") == :ok
      refute Process.alive?(a)
      assert Process.alive?(b)
      assert all_segment_ids(registry) == ["B", "C"]
      assert retire_segment_id(registry, "Z") == :ok
    end

    test "retire_all/1 retires every registration", %{registry: registry, a: a, b: b, c: c} do
      Process.flag(:trap_exit, true)
      assert retire_all(registry) == :ok
      for segment <- [a, b, c], do: refute(Process.alive?(segment))
      assert :ets.tab2list(registry) == []
    end
  end
end

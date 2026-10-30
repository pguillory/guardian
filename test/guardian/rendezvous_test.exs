defmodule Guardian.RendezvousTest do
  use ExUnit.Case, async: true
  import Guardian.Rendezvous

  @candidates [{:a@host, 1}, {:a@host, 2}, {:b@host, 1}, {:b@host, 2}, {:c@host, 1}]

  test "the owner does not depend on candidate order" do
    for key <- 1..300 do
      owner = owner(key, @candidates)
      assert owner in @candidates
      assert owner(key, Enum.reverse(@candidates)) == owner
      assert owner(key, Enum.shuffle(@candidates)) == owner
    end
  end

  test "adding or removing a candidate moves only the keys it wins or owned" do
    for key <- 1..300 do
      owner = owner(key, @candidates)
      assert owner(key, [{:d@host, 1} | @candidates]) in [owner, {:d@host, 1}]

      for removed <- List.delete(@candidates, owner) do
        assert owner(key, List.delete(@candidates, removed)) == owner
      end
    end
  end

  test "the highest 32-bit phash2 score of {key, id} wins" do
    for key <- 1..50 do
      expected = Enum.max_by(@candidates, &:erlang.phash2({key, &1}, 4_294_967_296))
      assert owner(key, @candidates) == expected
    end
  end

  test "the larger id breaks a hash tie" do
    # A real 32-bit phash2 collision, found by search.
    assert :erlang.phash2({:k, 106_154}, 4_294_967_296) ==
             :erlang.phash2({:k, 106_807}, 4_294_967_296)

    assert owner(:k, [106_154, 106_807]) == 106_807
    assert owner(:k, [106_807, 106_154]) == 106_807
  end

  test "id_fun chooses what is scored and the candidate is returned" do
    members = [:a@host, :b@host, :c@host]

    for key <- 1..50 do
      owner = owner(key, members, &Atom.to_string/1)
      assert is_atom(owner)
      assert owner(key, Enum.map(members, &Atom.to_string/1)) == Atom.to_string(owner)
    end

    assert owner(:k, [{:x, 106_154}, {:y, 106_807}], &elem(&1, 1)) == {:y, 106_807}
  end

  test "no candidates is an error" do
    assert_raise FunctionClauseError, fn -> owner(:k, []) end
  end
end

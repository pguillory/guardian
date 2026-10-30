defmodule Guardian.Test.EnvTest do
  # Not async: it exercises the node-wide application env.
  use ExUnit.Case, async: false
  import Guardian.Test.Env

  @set :test_env_test_set
  @unset :test_env_test_unset

  setup do
    Application.put_env(:guardian, @set, :original)
    Application.put_env(:guardian, :test_env_test_nil, nil)

    on_exit(fn ->
      for key <- [@set, @unset, :test_env_test_nil], do: Application.delete_env(:guardian, key)
    end)
  end

  test "put restores set values, nil values and absent keys through its restore function" do
    restore = put([{@set, 1}, {@unset, 2}, {:test_env_test_nil, 3}])
    assert Application.fetch_env(:guardian, @set) == {:ok, 1}
    assert Application.fetch_env(:guardian, @unset) == {:ok, 2}
    assert Application.fetch_env(:guardian, :test_env_test_nil) == {:ok, 3}

    restore.()
    assert Application.fetch_env(:guardian, @set) == {:ok, :original}
    assert Application.fetch_env(:guardian, @unset) == :error
    assert Application.fetch_env(:guardian, :test_env_test_nil) == {:ok, nil}

    Application.put_env(:guardian, @set, :changed_after_restore)
    restore.()
    assert Application.fetch_env(:guardian, @set) == {:ok, :original}
    assert Application.fetch_env(:guardian, @unset) == :error
    assert Application.fetch_env(:guardian, :test_env_test_nil) == {:ok, nil}
  end

  test "put restores when the test exits" do
    # Exit callbacks run last registered first, so this one runs after put's restore.
    on_exit(fn ->
      assert Application.fetch_env(:guardian, @set) == {:ok, :original}
      assert Application.fetch_env(:guardian, @unset) == :error
    end)

    put([{@set, 1}, {@unset, 2}])
    assert Application.fetch_env(:guardian, @set) == {:ok, 1}
  end

  test "a key put twice in one call ends at its original value" do
    restore = put([{@set, 1}, {@set, 2}])
    assert Application.fetch_env(:guardian, @set) == {:ok, 2}
    restore.()
    assert Application.fetch_env(:guardian, @set) == {:ok, :original}
  end

  test "with_env restores after the block, also when it raises, and nests" do
    result =
      with_env([{@set, :outer}], fn ->
        with_env([{@set, :inner}, {@unset, :inner}], fn ->
          assert Application.fetch_env(:guardian, @set) == {:ok, :inner}
        end)

        assert Application.fetch_env(:guardian, @set) == {:ok, :outer}
        assert Application.fetch_env(:guardian, @unset) == :error
        :result
      end)

    assert result == :result
    assert Application.fetch_env(:guardian, @set) == {:ok, :original}

    assert_raise RuntimeError, fn ->
      with_env([{@set, :raised}], fn -> raise "boom" end)
    end

    assert Application.fetch_env(:guardian, @set) == {:ok, :original}
  end
end

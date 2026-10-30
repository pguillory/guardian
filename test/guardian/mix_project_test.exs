defmodule Guardian.MixProjectTest do
  use ExUnit.Case, async: false

  import Guardian.MixProject

  # config/runtime.exs generates an admin key in dev; a release must never carry that
  # path, so only MIX_ENV=prod builds one. Not async: the test sets Mix.env, which is
  # global.
  test "refuses to build a release outside MIX_ENV=prod" do
    assert Mix.env() == :test

    assert_raise Mix.Error, "Guardian releases must be built with MIX_ENV=prod, not test", fn ->
      require_prod_release(%Mix.Release{name: :guardian})
    end

    Mix.env(:prod)

    try do
      release = %Mix.Release{name: :guardian}
      assert require_prod_release(release) == release
    after
      Mix.env(:test)
    end

    # First, before anything is assembled.
    steps = Mix.Project.config()[:releases][:guardian][:steps]
    assert Enum.take(steps, 2) == [&Guardian.MixProject.require_prod_release/1, :assemble]
  end
end

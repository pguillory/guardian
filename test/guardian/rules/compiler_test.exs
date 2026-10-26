defmodule Guardian.Rules.CompilerTest do
  use ExUnit.Case, async: true
  import Guardian.Test.Rules, only: [compile_module: 2]

  alias Guardian.Rules.{DependencyGraph, Event, RuleSet, Runtime}

  defp compile(module, files) do
    preparation = RuleSet.prepare(files)
    assert preparation.errors == []
    {:ok, plan} = preparation.tables["t"]

    compile_module(module, plan)
    plan
  end

  defp assert_recovered(module, plan) do
    recovered = module.plan()
    assert recovered === plan

    assert :erlang.term_to_binary(recovered, [:deterministic]) ==
             :erlang.term_to_binary(plan, [:deterministic])

    assert module.table() == plan.table
    assert module.hash() == plan.hash
  end

  test "plan recovery preserves flat counter metadata order independently of execution levels" do
    module = __MODULE__.CounterOrderProbe

    plan =
      compile(module, %{
        "t/a.gsql" => "TRACK a = count() BY z LAST '1h'",
        "t/b.gsql" => "TRACK b = count() BY y LAST '1h'",
        "t/q.gsql" =>
          "LOOKUP prior = a BY group_key; SET group_key = normalized; SET normalized = raw_group",
        "t/y.gsql" => "SET y = raw_y",
        "t/z.gsql" => "SET z = raw_z; UNSET secret",
      })

    assert Enum.map(plan.steps, & &1.field) ==
             ["normalized", "group_key", "prior", "y", "b", "z", "a", "secret"]

    levels = DependencyGraph.levels(plan.steps)

    assert Enum.map(levels, fn level -> Enum.map(level, & &1.field) end) ==
             [["normalized"], ["group_key"], ["prior"], ["y", "z"], ["a", "b"], ["secret"]]

    refute List.flatten(levels) == plan.steps
    assert_recovered(module, plan)
    refute Map.has_key?(module.plan(), :levels)
  end

  test "both generated entry points execute prepared levels with scalar literals and final UNSETs" do
    module = __MODULE__.ScalarProbe

    plan =
      compile(module, %{
        "t/a.gsql" => "SET a = z",
        "t/b.gsql" => "SET b = CASE WHEN y THEN 'yes' ELSE 'no' END",
        "t/y.gsql" => "SET y = message RLIKE '^secret$'",
        "t/z.gsql" => "SET z = upper(raw_z); UNSET password; UNSET raw_z WHERE y",
      })

    levels = DependencyGraph.levels(plan.steps)
    refute List.flatten(levels) == plan.steps
    assert_recovered(module, plan)
    row = %{"message" => "secret", "raw_z" => "hello", "password" => "hide"}
    event = Event.new()

    expected = %{
      "message" => "secret",
      "a" => "HELLO",
      "b" => "yes",
      "y" => true,
      "z" => "HELLO",
    }

    assert Runtime.run(row, levels, event) == expected
    assert apply(module, :apply, [row, event]) == expected
    assert apply(module, :apply, [row]) == expected
  end

  test "empty resolved plans recover exactly and leave rows unchanged" do
    module = __MODULE__.EmptyProbe
    plan = compile(module, %{"t/a.gsql" => "-- no statements"})
    assert plan.steps == []
    assert DependencyGraph.levels(plan.steps) == []
    assert_recovered(module, plan)
    row = %{"untouched" => 1}
    assert apply(module, :apply, [row]) == row
    assert apply(module, :apply, [row, Event.new()]) == row
  end
end

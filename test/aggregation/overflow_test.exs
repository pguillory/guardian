defmodule Guardian.Aggregation.OverflowTest do
  # A float overflow while merging is sticky (lib/aggregation/CLAUDE.md): merged with
  # anything, in either order, and however many times, it finishes as null.
  use ExUnit.Case, async: true

  # Each aggregate with two values whose merge overflows.
  @cases [
    {"sum", 1.0e308, 1.0e308},
    {"avg", 1.0e308, 1.0e308},
    {"var_pop", 1.0e308, -1.0e308},
    {"var_samp", 1.0e308, -1.0e308},
    {"stddev_pop", 1.0e308, -1.0e308},
    {"stddev_samp", 1.0e308, -1.0e308},
  ]

  test "an overflowed state absorbs every merge and finishes as null" do
    for {name, a, b} <- @cases do
      aggregation = Guardian.Aggregation.fetch!(name)
      start = fn value -> hd(Guardian.Aggregation.start_row([aggregation], [1], [value])) end
      overflowed = Guardian.Aggregation.merge(aggregation, start.(a), start.(b))
      assert Guardian.Aggregation.finish(aggregation, overflowed) == nil, name

      others = [
        overflowed,
        start.(1),
        start.(2.5),
        start.(nil),
        start.("a"),
        Guardian.Aggregation.default(aggregation),
        Guardian.Aggregation.merge(aggregation, start.(1), start.(2)),
      ]

      for other <- others do
        for merged <- [
              Guardian.Aggregation.merge(aggregation, overflowed, other),
              Guardian.Aggregation.merge(aggregation, other, overflowed),
            ] do
          assert Guardian.Aggregation.finish(aggregation, merged) == nil,
                 "#{name}: #{inspect(overflowed)} merged with #{inspect(other)}"

          # Still absorbing after another merge.
          again = Guardian.Aggregation.merge(aggregation, merged, start.(3))
          assert Guardian.Aggregation.finish(aggregation, again) == nil, name
        end
      end
    end
  end
end

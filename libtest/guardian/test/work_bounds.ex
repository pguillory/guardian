defmodule Guardian.Test.WorkBounds do
  @moduledoc """
  Measures synchronous work in the calling test process without scheduler delays.
  Safe for async tests when the measured workload is async-safe.

  Reductions are a runtime-specific proxy, not exact CPU accounting: native calls
  may charge them approximately, and work in other processes is not included.
  Calibrate a bound against both the workload and a representative regression.
  See `docs/changes/unit-test-work-bounds.md` for calibration results; recalibrate
  native work when the supported OTP runtime changes.
  """

  @doc "Returns `{reductions, result}` for one call to `fun`."
  def reductions(fun) do
    {:reductions, before_work} = Process.info(self(), :reductions)
    result = fun.()
    {:reductions, after_work} = Process.info(self(), :reductions)
    {after_work - before_work, result}
  end
end

defmodule Guardian.Storage.PersistedSegmentsSettingsTest do
  # Not async: puts `persisted_segment_cache_ms`, an application env setting
  # PersistedSegments reads instead of taking it as an argument.
  use ExUnit.Case, async: false

  alias Guardian.Storage.PersistedSegments

  test "an invalid cache window stops the persister from starting" do
    for invalid <- [0, -1, 1.5, "600000", nil] do
      Guardian.Test.Env.put(persisted_segment_cache_ms: invalid)

      assert_raise ArgumentError, "persisted_segment_cache_ms must be a positive integer", fn ->
        PersistedSegments.init([])
      end
    end
  end
end

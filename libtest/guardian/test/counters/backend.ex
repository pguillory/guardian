defmodule Guardian.Test.Counters.Backend do
  @moduledoc false

  # Only test builds interpret backend tuples; ordinary servers pass through to ETS,
  # after any `Guardian.Test.Counters.StorePause` gate.
  def batch(operations, now, opts) do
    case Keyword.fetch!(opts, :server) do
      {backend, server} when is_atom(backend) ->
        backend.batch(operations, now, Keyword.put(opts, :server, server))

      server ->
        :ok = Guardian.Test.Counters.StorePause.await_gate(server)
        Guardian.Counters.Store.batch(operations, now, opts)
    end
  end
end

defmodule Guardian.CounterTestBackend do
  @moduledoc false

  # Only test builds interpret backend tuples; ordinary servers pass through to ETS.
  def batch(operations, opts) do
    case Keyword.fetch!(opts, :server) do
      {backend, server} when is_atom(backend) ->
        backend.batch(operations, Keyword.put(opts, :server, server))

      _ ->
        Guardian.Counters.Store.batch(operations, opts)
    end
  end
end

defmodule Guardian.Rendezvous do
  @moduledoc """
  Rendezvous (highest random weight) hashing: picks the owner of a key among
  candidates, so that every node choosing from the same candidates agrees, and adding
  or removing one candidate moves only the keys that candidate wins or owned.
  """

  @range 4_294_967_296

  @doc """
  The candidate with the highest score `{:erlang.phash2({key, id}, 2^32), id}`, where
  `id = id_fun.(candidate)` (the candidate itself by default). The id breaks hash ties
  in Erlang term order, so the owner does not depend on candidate order as long as
  `id_fun` is deterministic and no two candidates' ids compare equal (as `1` and `1.0`
  do). Returns the candidate, not its id.
  """
  def owner(key, [_ | _] = candidates, id_fun \\ &Function.identity/1)
      when is_function(id_fun, 1) do
    Enum.max_by(candidates, fn candidate ->
      id = id_fun.(candidate)
      {:erlang.phash2({key, id}, @range), id}
    end)
  end
end

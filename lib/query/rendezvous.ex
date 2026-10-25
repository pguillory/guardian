defmodule Guardian.Query.Rendezvous do
  def sort([_ | _] = nodes, key) do
    Enum.sort_by(nodes, &:erlang.phash2({key, &1}))
  end

  def top(nodes, key) do
    sort(nodes, key) |> List.first()
  end
end

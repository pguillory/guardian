defmodule Guardian.Query.Function.Date do
  def eval do
    Guardian.Timestamp.now()
    |> eval()
  end

  def eval(timestamp) do
    case Guardian.Timestamp.read(timestamp) do
      {:ok, {date, _time}} -> date
      :error -> nil
    end
  end
end

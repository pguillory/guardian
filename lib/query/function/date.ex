defmodule Query.Function.Date do
  def eval do
    Timestamp.now()
    |> eval()
  end

  def eval(<<date::binary-size(10), " ", _time::binary-size(8)>>) do
    date
  end

  def eval(_) do
    nil
  end
end

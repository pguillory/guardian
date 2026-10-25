defmodule Guardian.Query.Function.Type do
  def eval(nil) do
    "null"
  end

  def eval(false) do
    "boolean"
  end

  def eval(true) do
    "boolean"
  end

  def eval(integer) when is_integer(integer) do
    "integer"
  end

  def eval(float) when is_float(float) do
    "float"
  end

  def eval(string) when is_binary(string) do
    "string"
  end

  def eval(list) when is_list(list) do
    list
    |> Enum.map(&eval/1)
    |> Enum.sort()
    |> Enum.uniq()
  end
end

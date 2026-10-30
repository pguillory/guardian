defmodule Guardian.Failure do
  @moduledoc """
  Short failure labels, for the few failures that are caught and logged, or logged as a
  process's exit.

  `kind/3` names a caught error, exit or throw: errors normalize to their exception
  module, exits use `exit_kind/1`, and throws have no reason text. `exit_kind/1` keeps
  Storage's exit labels and unwraps GenServer call exits.
  """

  @spec kind(:error | :exit | :throw, term(), Exception.stacktrace()) :: String.t()
  def kind(:error, reason, stacktrace) do
    %module{} = Exception.normalize(:error, reason, stacktrace)
    inspect(module)
  end

  def kind(:exit, reason, _stacktrace) do
    "exit " <> exit_kind(reason)
  end

  def kind(:throw, _value, _stacktrace) do
    "throw"
  end

  @doc "Names an exit without its arguments, exception message or other values."
  @spec exit_kind(term()) :: String.t()
  def exit_kind({reason, {GenServer, :call, _}}) do
    exit_kind(reason)
  end

  def exit_kind(reason) when is_atom(reason) do
    inspect(reason)
  end

  def exit_kind({%module{}, stack}) when is_list(stack) do
    inspect(module)
  end

  def exit_kind({kind, _}) when is_atom(kind) do
    inspect(kind)
  end

  def exit_kind(_reason) do
    "an abnormal exit"
  end
end

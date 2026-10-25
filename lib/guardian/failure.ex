defmodule Guardian.Failure do
  @moduledoc """
  Value-free failure labels and argument-free diagnostic stack traces.

  `kind/3` names a caught error, exit or throw: errors normalize to their exception
  module, exits use `exit_kind/1`, and throws have no reason text. Use it for caught
  failure log lines. `exit_kind/1` preserves Storage's exit labels and unwraps
  GenServer call exits.

  `reason_kind/1` preserves Rules.Server's different crash-report vocabulary: an
  exception module, atom or tuple's leading atom, otherwise "term". It describes
  the raw reason, so `:badarg` stays ":badarg" rather than becoming "ArgumentError".
  Callers own their log messages and catch/reraise policy.
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

  @doc "Names a raw callback failure reason using Rules.Server's existing labels."
  @spec reason_kind(term()) :: String.t()
  def reason_kind(%{__exception__: true, __struct__: module}) do
    inspect(module)
  end

  def reason_kind(atom) when is_atom(atom) do
    inspect(atom)
  end

  def reason_kind(tuple)
      when is_tuple(tuple) and tuple_size(tuple) > 0 and is_atom(elem(tuple, 0)) do
    inspect(elem(tuple, 0))
  end

  def reason_kind(_reason) do
    "term"
  end

  @doc "Keeps MFA arities and typed file/line locations; replaces all other frames."
  @spec stacktrace(list()) :: Exception.stacktrace()
  def stacktrace(stack) do
    Enum.map(stack, &redact_frame/1)
  end

  defp redact_frame({module, function, args, location})
       when is_atom(module) and is_atom(function) and
              (is_list(args) or (is_integer(args) and args >= 0)) and is_list(location) do
    arity = if is_list(args), do: length(args), else: args

    location =
      Enum.filter(location, fn
        {:file, file} when is_list(file) -> Enum.all?(file, &is_integer/1)
        {:line, line} when is_integer(line) and line >= 0 -> true
        _ -> false
      end)

    {module, function, arity, location}
  end

  defp redact_frame(_frame) do
    {__MODULE__, :redacted, 0, []}
  end
end

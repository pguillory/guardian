defmodule Guardian.Counters.Machine do
  @moduledoc """
  One key's state machine: a pending store operation, or a finished result.

  Its callback receives the pending operation, that operation's response and the
  machine's state, and returns `{:next, op, state}` or `{:done, result}`. Nil is reserved
  for a finished machine's operation: initial operations must be non-nil, and
  malformed callback returns, including `{:next, nil, state}`, raise.
  """
  defstruct [:op, :state, :callback, :result]

  @doc "A machine whose first pending operation is `op` (not nil), with `state` for the callback."
  def new(op, state, callback) when not is_nil(op) do
    %__MODULE__{op: op, state: state, callback: callback}
  end

  @doc "Whether the machine has finished (it has a result and no pending operation)."
  def done?(%__MODULE__{op: op}) do
    op == nil
  end

  @doc "Feeds the pending operation's response to the machine."
  def advance(%__MODULE__{} = machine, response) do
    case machine.callback.(machine.op, response, machine.state) do
      {:next, nil, _state} -> raise ArgumentError, "next operation must not be nil"
      {:next, op, state} -> %{machine | op: op, state: state}
      {:done, result} -> %{machine | op: nil, result: result}
    end
  end
end

defmodule Guardian.Query.Failure do
  @moduledoc """
  Turns a failed query into a `Guardian.Query.Error` with a bounded message.

  Failures reach a query as exceptions, exits or throws caught in a worker or the query
  process (`caught/3`), as the exit reason of a failed DistributedStream pipeline
  (`from_exit/1`), or as the down reason of the query process itself
  (`query_process_down/1`). A `:killed` reason from either becomes
  `Guardian.Query.Limits.heap_kill_message/0`. Their reasons can carry row values, so messages are built
  only from bounded inspections and cut by `truncate/1`, which also keeps them valid
  UTF-8 for JSON.
  """

  alias Guardian.Query.Error
  alias Guardian.Query.Limits

  @max_message_bytes 1024

  @doc """
  The error for an exception, exit or throw caught while evaluating a query.
  """
  @spec caught(:error | :exit | :throw, term(), Exception.stacktrace()) :: %Error{}
  def caught(:error, %Error{message: message}, _stacktrace) do
    %Error{message: truncate(message)}
  end

  def caught(:error, reason, stacktrace) do
    exception = Exception.normalize(:error, reason, stacktrace)

    %Error{
      message: truncate("query evaluation failed: " <> Exception.message(exception)),
    }
  end

  def caught(kind, reason, _stacktrace) do
    %Error{
      message: truncate("query evaluation failed (#{kind}): #{describe(reason)}"),
    }
  end

  @doc """
  The error for the reason a `Guardian.Query.DistributedStream` pipeline (or a process linked to
  the query process) failed with: a `t:Guardian.Query.DistributedStream.failure_reason/0`.
  """
  @spec from_exit(term()) :: %Error{}
  def from_exit({exception, stacktrace})
      when is_exception(exception) and is_list(stacktrace) do
    caught(:error, exception, stacktrace)
  end

  # A process killed outright: most likely by its heap limit (Guardian.Query.Limits), though
  # the reason cannot tell that apart from any other kill.
  def from_exit(:killed) do
    %Error{message: Limits.heap_kill_message()}
  end

  def from_exit(:noconnection) do
    disconnected()
  end

  def from_exit({:nodedown, _node}) do
    disconnected()
  end

  def from_exit({:distributed_stream, {_edge, :noconnection}}) do
    disconnected()
  end

  def from_exit({:distributed_stream, detail}) do
    %Error{message: "query failed: " <> distributed_stream_message(detail)}
  end

  # An Erlang-level crash outside the guard, such as a badmatch: its message, not its
  # stack frames and arguments.
  def from_exit({reason, stacktrace}) when is_list(stacktrace) do
    caught(:error, Exception.normalize(:error, reason, stacktrace), stacktrace)
  end

  def from_exit(reason) do
    %Error{
      message: truncate("query failed: a query process exited (#{describe(reason)})"),
    }
  end

  @doc """
  The error for a query process that went down without sending its result.
  """
  @spec query_process_down(term()) :: %Error{}
  def query_process_down(:killed) do
    %Error{message: Limits.heap_kill_message()}
  end

  def query_process_down(reason) do
    %Error{message: "query failed: " <> truncate(describe(reason))}
  end

  @doc """
  Returns valid UTF-8 of at most #{@max_message_bytes} bytes plus "...", so the
  message can always be JSON-encoded: messages may quote user data.
  """
  @spec truncate(String.t()) :: String.t()
  def truncate(message) do
    message = String.replace_invalid(message)

    if byte_size(message) <= @max_message_bytes do
      message
    else
      cut_to_codepoint(binary_part(message, 0, @max_message_bytes)) <> "..."
    end
  end

  defp cut_to_codepoint(prefix) do
    if String.valid?(prefix),
      do: prefix,
      else: cut_to_codepoint(binary_part(prefix, 0, byte_size(prefix) - 1))
  end

  defp disconnected do
    %Error{message: "query failed: a machine disconnected during the query"}
  end

  defp distributed_stream_message({:lost_input, missing}) do
    "#{missing} chunk(s) of rows were lost between machines"
  end

  defp distributed_stream_message({edge, reason})
       when edge in [:sender_down, :receiver_down, :router_down] do
    "a query worker stopped before all its rows were passed on (#{Guardian.Storage.exit_kind(reason)})"
  end

  defp distributed_stream_message(:worker_finished_early) do
    "a query worker finished before reading all its input"
  end

  defp distributed_stream_message(:worker_exited) do
    "a query worker exited before finishing"
  end

  defp distributed_stream_message(:input_exited) do
    "the query's input ended without finishing"
  end

  defp distributed_stream_message(:unexpected_sender) do
    "a query worker received rows from an unknown sender"
  end

  defp distributed_stream_message(other) do
    truncate(describe(other))
  end

  # A bounded inspection: reasons can carry row values.
  defp describe(term) do
    inspect(term, limit: 10, printable_limit: 200)
  end
end

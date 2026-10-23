defmodule Query.Jq do
  @moduledoc """
  Runs jq programs for the `jq()` query function in a sandboxed worker process
  (`src/jq_worker.c`, built into `priv/jq_worker`).

  Each evaluation (one `jq()` call over one segment, or one scalar call) starts its own
  worker with an empty environment, compiles each distinct program once, sends inputs
  in batches, and closes the worker. The worker cannot read the environment or files
  (see the C file for the sandbox), and it ends itself when its time limit runs out.

  Limits (application env, defaults in parentheses):

  - `:jq_time_limit_ms` (2000): wall-clock life of one worker, compile included. This
    does not bound a whole query: a stage runs one evaluation per segment.
  - `:jq_max_row_output_bytes` (1 MiB): JSON output for one input row.
  - `:jq_max_output_bytes` (16 MiB): JSON output for the whole evaluation.
  - `:jq_memory_limit_bytes` (256 MiB): the worker's address space (Linux only).
  - `:jq_max_workers` (2): concurrent workers per machine (`Query.Jq.Slots`).

  Exceeding a limit, a compile error, or a failed worker raises `Query.Error`.
  Results per row: a list of the program's outputs, or nil when the program or input is
  not a string or the input is not valid JSON. An output that a column cannot hold (an
  object, or lists nested too deeply) is returned as its JSON text.
  """

  alias Storage.Column

  # Matches MAX_REQUEST_BYTES in src/jq_worker.c.
  @max_frame_payload_bytes 8 * 1024 * 1024
  @batch_rows 1024
  @batch_bytes 1024 * 1024
  # Outputs are capped by the worker; the frame cap adds headroom for framing.
  @frame_overhead 1024 * 1024
  # Exactly representable integers; integral floats outside it stay floats.
  @max_exact_integer 9_007_199_254_740_992
  @int64_range -9_223_372_036_854_775_808..9_223_372_036_854_775_807

  @doc """
  Evaluates `{program, input}` pairs and returns one result per pair, in order.
  """
  def eval_rows(pairs) when is_list(pairs) do
    if Enum.any?(pairs, fn {program, input} -> is_binary(program) and is_binary(input) end) do
      with_worker(fn worker ->
        pairs
        |> Enum.chunk_by(fn {program, _input} -> program end)
        |> Enum.flat_map(fn [{program, _} | _] = run ->
          inputs = Enum.map(run, fn {_program, input} -> input end)

          if is_binary(program) and Enum.any?(inputs, &is_binary/1) do
            compile!(worker, program)
            run_inputs!(worker, inputs)
          else
            List.duplicate(nil, length(run))
          end
        end)
      end)
    else
      List.duplicate(nil, length(pairs))
    end
  end

  # ---------------------------------------------------------------------------------
  # Worker lifecycle

  defp with_worker(fun) do
    limits = limits()

    slot =
      case Query.Jq.Slots.acquire(limits.time_ms) do
        {:ok, slot} ->
          slot

        {:error, :busy} ->
          raise Query.Error,
            message: "jq is busy: too many concurrent jq() evaluations on this machine; try again"
      end

    try do
      # The worker's own timer starts when it does, so the deadline must too; taken
      # before a slot wait, it could close the port (and free the slot) while the OS
      # process still runs.
      port = open_port(limits)
      deadline = System.monotonic_time(:millisecond) + limits.time_ms + 1_000
      worker = %{port: port, limits: limits, deadline: deadline}

      try do
        fun.(worker)
      after
        close_port(port)
      end
    after
      Query.Jq.Slots.release(slot)
    end
  end

  defp open_port(limits) do
    args = [
      "-i",
      worker_path(),
      to_string(limits.time_ms),
      to_string(limits.row_bytes),
      to_string(limits.total_bytes),
      to_string(limits.memory_bytes),
    ]

    Port.open({:spawn_executable, "/usr/bin/env"}, [
      :binary,
      :stream,
      :exit_status,
      :use_stdio,
      args: args,
    ])
  end

  defp close_port(port) do
    try do
      Port.close(port)
    catch
      :error, :badarg -> :ok
    end

    flush_port(port)
  end

  defp flush_port(port) do
    receive do
      {^port, _} -> flush_port(port)
    after
      0 -> :ok
    end
  end

  defp worker_path do
    Path.join(:code.priv_dir(:guardian), "jq_worker")
  end

  defp limits do
    %{
      time_ms: Application.get_env(:guardian, :jq_time_limit_ms, 2_000),
      row_bytes: Application.get_env(:guardian, :jq_max_row_output_bytes, 1024 * 1024),
      total_bytes: Application.get_env(:guardian, :jq_max_output_bytes, 16 * 1024 * 1024),
      memory_bytes: Application.get_env(:guardian, :jq_memory_limit_bytes, 256 * 1024 * 1024),
    }
  end

  # ---------------------------------------------------------------------------------
  # Requests

  defp compile!(worker, program) do
    if byte_size(program) > @max_frame_payload_bytes - 1 do
      raise Query.Error,
        message:
          "jq program is #{byte_size(program)} bytes; the limit is " <>
            "#{@max_frame_payload_bytes - 1} bytes (8 MiB)"
    end

    case request(worker, ["C", program]) do
      "K" -> :ok
      "E" <> message -> raise Query.Error, message: clean_error(message)
      _ -> protocol_error!()
    end
  end

  defp run_inputs!(worker, inputs) do
    indexed = Enum.with_index(inputs)
    {strings, others} = Enum.split_with(indexed, fn {input, _} -> is_binary(input) end)
    Enum.each(strings, fn {input, _} -> check_input_size!(input) end)

    results =
      strings
      |> chunk_batches()
      |> Enum.flat_map(fn batch ->
        payload = Enum.map(batch, fn {input, _} -> [<<byte_size(input)::32>>, input] end)

        case request(worker, ["R" | payload]) do
          "B" <> data ->
            values = decode_batch(data, [])
            length(values) == length(batch) || protocol_error!()
            Enum.zip_with(batch, values, fn {_, index}, value -> {index, value} end)

          "E" <> message ->
            raise Query.Error, message: clean_error(message)

          _ ->
            protocol_error!()
        end
      end)

    nils = Enum.map(others, fn {_, index} -> {index, nil} end)

    (results ++ nils)
    |> List.keysort(0)
    |> Enum.map(fn {_, value} -> value end)
  end

  # The worker refuses a request frame over 8 MiB; one input travels alone in a frame
  # with a 1-byte tag and a 4-byte length.
  @max_input_bytes @max_frame_payload_bytes - 5

  defp check_input_size!(input) when byte_size(input) <= @max_input_bytes, do: :ok

  defp check_input_size!(input) do
    raise Query.Error,
      message:
        "jq input is #{byte_size(input)} bytes; the limit is #{@max_input_bytes} bytes " <>
          "(8 MiB)"
  end

  defp chunk_batches(inputs) do
    Enum.chunk_while(
      inputs,
      {[], 0, 0},
      fn {input, _} = item, {acc, rows, bytes} ->
        size = byte_size(input) + 4

        if acc != [] and (rows >= @batch_rows or bytes + size > @batch_bytes) do
          {:cont, Enum.reverse(acc), {[item], 1, size}}
        else
          {:cont, {[item | acc], rows + 1, bytes + size}}
        end
      end,
      fn
        {[], _, _} -> {:cont, {[], 0, 0}}
        {acc, _, _} -> {:cont, Enum.reverse(acc), {[], 0, 0}}
      end
    )
  end

  defp decode_batch(<<>>, acc), do: Enum.reverse(acc)

  defp decode_batch(<<"N", 0::32, rest::binary>>, acc) do
    decode_batch(rest, [nil | acc])
  end

  defp decode_batch(<<"J", size::32, json::binary-size(size), rest::binary>>, acc) do
    outputs = json |> Jason.decode!() |> Enum.map(&output/1)
    decode_batch(rest, [outputs | acc])
  end

  defp decode_batch(_data, _acc), do: protocol_error!()

  # Mirrors the libjq NIF this replaces: jq numbers are doubles, and integral ones came
  # back as integers.
  defp output(value) do
    value = normalize(value)

    if Column.valid_value?([value]) do
      value
    else
      Jason.encode!(value)
    end
  end

  defp normalize(value) when is_float(value) do
    if value == Float.round(value) and abs(value) <= @max_exact_integer do
      trunc(value)
    else
      value
    end
  end

  defp normalize(value) when is_integer(value) do
    if value in @int64_range, do: value, else: value * 1.0
  end

  defp normalize(value) when is_list(value), do: Enum.map(value, &normalize/1)

  defp normalize(value) when is_map(value) do
    Map.new(value, fn {k, v} -> {k, normalize(v)} end)
  end

  defp normalize(value), do: value

  # ---------------------------------------------------------------------------------
  # Framing: 4-byte big-endian length, then the payload. The port is read in stream
  # mode so a frame length is checked before the frame is buffered.

  defp request(%{port: port} = worker, payload) do
    size = IO.iodata_length(payload)
    Port.command(port, [<<size::32>> | payload])
    receive_frame(worker, <<>>)
  rescue
    # The worker already exited; its exit status says why.
    ArgumentError ->
      receive do
        {^port, {:exit_status, status}} -> worker_failed!(worker, status)
      after
        1_000 -> worker_failed!(worker, nil)
      end
  end

  defp receive_frame(%{port: port, limits: limits} = worker, buffer) do
    case buffer do
      <<size::32, frame::binary-size(size), _rest::binary>> ->
        frame

      <<size::32, _::binary>> when size > limits.total_bytes + @frame_overhead ->
        protocol_error!()

      _ ->
        timeout = max(worker.deadline - System.monotonic_time(:millisecond), 0)

        receive do
          {^port, {:data, data}} ->
            receive_frame(worker, buffer <> data)

          {^port, {:exit_status, status}} ->
            worker_failed!(worker, status)
        after
          timeout -> time_limit!(worker)
        end
    end
  end

  # Signals: SIGALRM (14) is the worker's own deadline, SIGXCPU (24) and SIGKILL (9)
  # its CPU limit.
  defp worker_failed!(worker, status) when status in [128 + 14, 128 + 24, 128 + 9] do
    time_limit!(worker)
  end

  defp worker_failed!(worker, 3) do
    raise Query.Error,
      message:
        "jq program exceeded its memory limit (#{div(worker.limits.memory_bytes, 1024 * 1024)} MiB)"
  end

  defp worker_failed!(_worker, status) do
    raise Query.Error, message: "jq worker failed (exit status #{inspect(status)})"
  end

  defp time_limit!(worker) do
    raise Query.Error,
      message: "jq program exceeded its time limit (#{worker.limits.time_ms} ms)"
  end

  defp protocol_error! do
    raise Query.Error, message: "jq worker sent an invalid reply"
  end

  defp clean_error(message) do
    message
    |> String.replace("jq: error: ", "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> Query.Failure.truncate()
  end
end

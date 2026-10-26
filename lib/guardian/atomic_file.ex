defmodule Guardian.AtomicFile do
  @moduledoc """
  Atomic file replacement: a reader sees the old file or the whole new one, never a
  partial write, after a VM crash or a host crash.
  """

  @doc """
  Writes `data` to a unique temp file beside `filename`, fsyncs it, then renames it
  over `filename`, creating the parent folder first. Returns `:ok` or
  `{:error, reason}`, where `reason` is a posix atom (`:badarg` for data that is not
  iodata).

  The fsync before the rename means a host crash cannot leave `filename` present
  but empty or truncated (the rename reaching disk before the data). The directory
  entry itself is not fsynced, so a crash can still lose a recent rename, leaving
  the previous file (or none) rather than a corrupt one. A failed write removes its
  temp file; a crash mid-write leaves it behind, named `{filename}.{n}.tmp`.
  """
  def write(filename, data) do
    # Unique temp filename to avoid conflicts if multiple processes write to the same file
    temp_filename = filename <> ".#{:erlang.unique_integer([:positive])}.tmp"

    with :ok <- File.mkdir_p(Path.dirname(filename)),
         {:ok, file} <- :file.open(temp_filename, [:write, :exclusive, :raw, :binary]) do
      # Only a temp file this call created is removed on failure.
      with :ok <- write_synced(file, data),
           :ok <- File.rename(temp_filename, filename) do
        :ok
      else
        error ->
          File.rm(temp_filename)
          error
      end
    end
  end

  @doc """
  Whether a file name (one path segment) is a temp file `write/2` would create, so a
  folder listing can skip one left by a crash mid-write.
  """
  def temp_file?(name) do
    String.match?(name, ~r/\.[1-9][0-9]*\.tmp\z/)
  end

  # Writes, fsyncs, and closes `file`; every step must succeed before the rename.
  # Raw-mode `:file` calls return errors (`{:error, :badarg}` for bad iodata) rather
  # than raising, so the descriptor is always closed.
  defp write_synced(file, data) do
    result =
      with :ok <- :file.write(file, data) do
        :file.sync(file)
      end

    case {result, :file.close(file)} do
      {:ok, close_result} -> close_result
      {error, _close_result} -> error
    end
  end
end

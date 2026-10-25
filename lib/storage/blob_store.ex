defmodule Guardian.Storage.BlobStore do
  # Internal to Storage; see lib/storage/CLAUDE.md, "Public boundary".
  @moduledoc false

  # Writes `data` to a unique temp file, fsyncs it, then renames it over `filename`.
  # The fsync before the rename means a host crash cannot leave `filename` present
  # but empty or truncated (the rename reaching disk before the data). The directory
  # entry itself is not fsynced, so a crash can still lose a recent rename, leaving
  # the file absent rather than corrupt.
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

  def list(dirname) do
    case File.ls(dirname) do
      {:ok, filenames} ->
        filenames = filenames |> Enum.map(&Path.join(dirname, &1)) |> Enum.sort()
        {:ok, filenames}

      {:error, :enoent} ->
        {:ok, []}
    end
  end

  def delete(filename) do
    File.rm(filename)
  end

  def exists(filename) do
    File.exists?(filename)
  end
end

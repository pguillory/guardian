defmodule Guardian.Storage.BlobStore do
  # Internal to Storage; see lib/guardian/storage/CLAUDE.md, "Public boundary".
  @moduledoc false

  # Atomic replacement, fsynced before the rename (`Guardian.AtomicFile.write/2`).
  def write(filename, data) do
    Guardian.AtomicFile.write(filename, data)
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

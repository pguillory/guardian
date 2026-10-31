defmodule Guardian.ObjectStore.Local do
  @moduledoc """
  A local folder as a `Guardian.ObjectStore`: each regular file under the folder, at
  any depth, is an object keyed by its path relative to the folder, with `/`
  separators. ETags are content hashes, and `age_ms` comes from the file's mtime.

  Listing walks the whole folder, hashing each file as it streams it, and skips names
  that start with `.` (files or folders), names that are not valid UTF-8, and
  `Guardian.AtomicFile` temporary files. Symlinks are followed: a symlinked file or
  folder counts as what it points to, in listings and in reads and writes through it,
  so a symlink can lead outside the folder (the folder's owner is trusted with them).
  A folder already being walked above itself is skipped, as are dangling and looping
  links. A file or folder that disappears during the walk is skipped; any other
  file error fails the listing. The walk visits at most `max_entries` names (default
  20,000), and past that fails with `"too many objects"`.

  Keys are checked before they reach the disk: a key is valid UTF-8 made of
  `/`-separated segments, each one a name `list/1` could return (non-empty, not
  starting with `.`, no NUL byte, not a temporary file's name). That excludes
  absolute paths, empty segments and `..`, so a key cannot climb out of the folder
  lexically (symlinks inside it are followed, as above).
  Any other key is `{:error, "invalid key"}`.

  Writes go through `Guardian.AtomicFile.write/2` (a temporary file, fsynced, then
  renamed into place), so a crash never leaves a torn file. The directory entry is not
  fsynced, so a power loss can roll a recent write back to the previous version, or to
  no file for a new key. Writes to the folder are serialized across this node and every
  node connected to it, so conditional puts are atomic among them; a hung connected
  node stalls them, and nothing coordinates writers on machines not connected.

  The lock is keyed by the folder's identity (device and inode, through symlinks), taken once
  in `new/2`, so stores naming one folder differently (a trailing slash, a relative
  path, a symlink) share it. A live store needs that folder, and any symlink to it, to
  stay in place: a folder deleted and recreated gets a new identity, and stores made
  before and after no longer share a lock. Locking is per root folder, not per file:
  overlapping stores (one on a folder, one on a folder inside it) or a symlink from one
  store's folder into another's reach the same file under different locks.

  Contended writes use `:global`'s randomized exponential backoff, with each retry
  delay capped at 8 s, no fairness and no total wait limit. A hung write holds up later
  writes to its folder. `Guardian.ObjectStore.Lock.acquire/4` makes one attempt, but
  its put still waits for this local lock.
  """

  @behaviour Guardian.ObjectStore

  @enforce_keys [:dir, :lock]
  defstruct [:dir, :lock, max_entries: 20_000]

  @chunk_bytes 65_536

  @doc "The store for `dir`, creating the folder. `{:error, reason}` if it cannot."
  def new(dir, opts \\ []) do
    with :ok <- File.mkdir_p(dir),
         {:ok, %File.Stat{type: :directory} = stat} <- File.stat(dir) do
      config = %__MODULE__{dir: dir, lock: identity(stat)}
      {:ok, {__MODULE__, struct!(config, Keyword.take(opts, [:max_entries]))}}
    else
      {:ok, %File.Stat{}} -> {:error, "#{dir} is not a folder"}
      {:error, posix} -> {:error, "#{dir}: #{:file.format_error(posix)}"}
    end
  end

  @impl true
  def describe(%__MODULE__{dir: dir}) do
    "local folder #{dir}"
  end

  @impl true
  def list(%__MODULE__{dir: dir, max_entries: max_entries}) do
    case File.stat(dir) do
      {:ok, %File.Stat{type: :directory} = stat} ->
        with {:ok, objects, _left} <- walk(dir, nil, [identity(stat)], max_entries, []) do
          {:ok, Enum.sort_by(objects, & &1.key)}
        end

      {:error, posix} when posix != :enoent ->
        {:error, "#{dir}: #{posix_text(posix)}"}

      _ ->
        {:error, "#{dir} is not a folder"}
    end
  end

  # Walks the folder at `prefix` (nil for the root), accumulating objects, with `left`
  # names still allowed. `ancestors` are the identities of the folders above, so a
  # symlink back up the tree is not walked again.
  defp walk(dir, prefix, ancestors, left, objects) do
    case File.ls(full_path(dir, prefix)) do
      {:ok, names} ->
        Enum.reduce_while(names, {:ok, objects, left}, fn name, {:ok, objects, left} ->
          cond do
            left <= 0 ->
              {:halt, {:error, "too many objects"}}

            not valid_name?(name) ->
              {:cont, {:ok, objects, left - 1}}

            true ->
              key = if prefix, do: prefix <> "/" <> name, else: name

              case entry(dir, key, ancestors, left - 1, objects) do
                {:ok, objects, left} -> {:cont, {:ok, objects, left}}
                {:error, reason} -> {:halt, {:error, reason}}
              end
          end
        end)

      {:error, vanished} when vanished in [:enoent, :enotdir] ->
        {:ok, objects, left}

      {:error, posix} ->
        {:error, "#{prefix || "."}: #{posix_text(posix)}"}
    end
  end

  defp entry(dir, key, ancestors, left, objects) do
    path = full_path(dir, key)

    case File.stat(path) do
      {:ok, %File.Stat{type: :directory} = stat} ->
        if identity(stat) in ancestors do
          {:ok, objects, left}
        else
          walk(dir, key, [identity(stat) | ancestors], left, objects)
        end

      {:ok, %File.Stat{type: :regular}} ->
        case hash_file(path) do
          {:ok, etag, size} -> {:ok, [%{key: key, etag: etag, size: size} | objects], left}
          {:error, :enoent} -> {:ok, objects, left}
          {:error, posix} -> {:error, "#{key}: #{posix_text(posix)}"}
        end

      # Devices and sockets hold no object.
      {:ok, _stat} ->
        {:ok, objects, left}

      # Vanished entries, and dangling or looping symlinks, hold none either.
      {:error, gone} when gone in [:enoent, :eloop] ->
        {:ok, objects, left}

      {:error, posix} ->
        {:error, "#{key}: #{posix_text(posix)}"}
    end
  end

  # File errors are posix atoms, or a tuple such as {:no_translation, name} under
  # strict file name translation; only the atom is shown.
  defp posix_text(posix) when is_atom(posix) do
    Atom.to_string(posix)
  end

  defp posix_text(_error) do
    "unreadable name"
  end

  defp identity(%File.Stat{major_device: device, inode: inode}) do
    {device, inode}
  end

  # The ETag and size of the bytes read, streamed so a large file is not held whole.
  defp hash_file(path) do
    case :file.open(path, [:read, :raw, :binary]) do
      {:ok, file} ->
        try do
          hash_chunks(file, :crypto.hash_init(:sha256), 0)
        after
          :file.close(file)
        end

      {:error, posix} ->
        {:error, posix}
    end
  end

  defp hash_chunks(file, hash, size) do
    case :file.read(file, @chunk_bytes) do
      {:ok, chunk} -> hash_chunks(file, :crypto.hash_update(hash, chunk), size + byte_size(chunk))
      :eof -> {:ok, etag_of_hash(:crypto.hash_final(hash)), size}
      {:error, posix} -> {:error, posix}
    end
  end

  @impl true
  def get(%__MODULE__{} = config, key, etag) do
    with {:ok, path} <- path(config, key),
         {:ok, body} <- read(path),
         {:ok, %File.Stat{mtime: mtime}} <- stat(path) do
      if etag != nil and etag(body) != etag do
        {:error, :precondition_failed}
      else
        age_ms = (System.os_time(:second) - mtime) * 1000
        {:ok, body, %{etag: etag(body), age_ms: age_ms}}
      end
    end
  end

  @impl true
  def put(%__MODULE__{} = config, key, body, condition) do
    with {:ok, path} <- path(config, key) do
      serialized(config, fn ->
        current =
          case File.read(path) do
            {:ok, current} -> etag(current)
            {:error, _} -> nil
          end

        case {condition, current} do
          {:absent, current} when current != nil -> {:error, :precondition_failed}
          {{:etag, etag}, current} when current != etag -> {:error, :precondition_failed}
          _ -> write(path, body)
        end
      end)
    end
  end

  @impl true
  def delete(%__MODULE__{} = config, key) do
    with {:ok, path} <- path(config, key) do
      serialized(config, fn ->
        case File.rm(path) do
          :ok -> :ok
          {:error, :enoent} -> :ok
          {:error, posix} -> {:error, Atom.to_string(posix)}
        end
      end)
    end
  end

  defp write(path, body) do
    case Guardian.AtomicFile.write(path, body) do
      :ok -> {:ok, etag(body)}
      {:error, posix} -> {:error, Atom.to_string(posix)}
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, body} -> {:ok, body}
      {:error, :enoent} -> {:error, :not_found}
      {:error, posix} -> {:error, Atom.to_string(posix)}
    end
  end

  defp stat(path) do
    case File.stat(path, time: :posix) do
      {:ok, stat} -> {:ok, stat}
      {:error, :enoent} -> {:error, :not_found}
      {:error, posix} -> {:error, Atom.to_string(posix)}
    end
  end

  # A `:global` lock id is `{resource, requester}`, and the lock is granted again to its
  # own requester, so the folder is the resource and the calling process the requester.
  # The folder is named by its identity, so every spelling of it shares the lock.
  # Taken on every connected node, so nodes sharing the folder exclude each other.
  # Do not nest: an inner call would be granted the lock and release it on return.
  # See the moduledoc for the contention and unbounded-wait limits.
  defp serialized(%__MODULE__{lock: lock}, fun) do
    :global.trans({{__MODULE__, lock}, self()}, fun, [node() | Node.list()])
  end

  defp path(%__MODULE__{dir: dir}, key) do
    if valid_key?(key) do
      {:ok, Path.join(dir, key)}
    else
      {:error, "invalid key"}
    end
  end

  defp full_path(dir, nil) do
    dir
  end

  defp full_path(dir, key) do
    Path.join(dir, key)
  end

  # A key is a path of names `list/1` could return; none is empty, `.`, `..` or
  # absolute, so the key stays inside the folder.
  defp valid_key?(key) when is_binary(key) do
    String.valid?(key) and Enum.all?(String.split(key, "/"), &valid_name?/1)
  end

  defp valid_key?(_key) do
    false
  end

  defp valid_name?(name) do
    name != "" and String.valid?(name) and not String.starts_with?(name, ".") and
      not String.contains?(name, <<0>>) and not Guardian.AtomicFile.temp_file?(name)
  end

  defp etag(body) do
    etag_of_hash(:crypto.hash(:sha256, body))
  end

  defp etag_of_hash(hash) do
    hash |> Base.encode16(case: :lower) |> binary_part(0, 32)
  end
end

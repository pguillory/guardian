defmodule Guardian.Build do
  def timestamp do
    unquote(Guardian.Timestamp.now())
  end

  @commit_file :code.priv_dir(:guardian) |> Path.join("commit")
  @external_resource @commit_file
  @commit (case(File.read(@commit_file)) do
             {:ok, commit} -> String.trim(commit)
             _ -> "unknown"
           end)

  def commit do
    unquote(Macro.escape(@commit))
  end
end

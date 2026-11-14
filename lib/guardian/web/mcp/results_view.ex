defmodule Guardian.Web.MCP.ResultsView do
  @moduledoc """
  The `query` tool's MCP App view (the MCP Apps extension, `io.modelcontextprotocol/ui`).

  Two parts:

  - `shell/0`: the static `ui://guardian/query-results` document that App hosts render
    in a sandboxed frame. Its one inline script waits for the host to pass it a tool
    result and swaps in that result's server-rendered HTML. Its own Content Security
    Policy allows only that script, by hash, so markup in a result can't run code.
  - `fragment/3` and `error_fragment/2`: the HTML for one call's result, a table in
    column-label order, which `Guardian.Web.MCP.Server` puts in the result's `_meta`
    under `html_key/0`. Every value and label is escaped. The table shows at most 300
    rows and 100 KiB of row markup, and each value's first 1,000 characters, saying
    how many rows it left out; the tool's content (what the model reads) is never cut.

  The fragment is well-formed XML (every element closed, only XML entities), which
  tests rely on to parse it.
  """

  @uri "ui://guardian/query-results"
  @mime_type "text/html;profile=mcp-app"
  @html_key "guardian/html"

  @max_rows 300
  @max_row_bytes 100 * 1024
  @max_cell_chars 1_000
  @max_sql_chars 2_000

  @shell_path Path.join(__DIR__, "results_view.html")
  @script_path Path.join(__DIR__, "results_view.js")
  @external_resource @shell_path
  @external_resource @script_path
  @script File.read!(@script_path)
  @script_hash "sha256-" <> Base.encode64(:crypto.hash(:sha256, @script))
  @shell @shell_path
         |> File.read!()
         |> String.replace("@SCRIPT_HASH@", @script_hash)
         |> String.replace("@SCRIPT@", @script)

  @doc "The view's resource URI, which the `query` tool names in `_meta.ui.resourceUri`."
  def uri do
    @uri
  end

  @doc "The MCP Apps HTML MIME type, for the resource and for detecting App hosts."
  def mime_type do
    @mime_type
  end

  @doc "The tool result `_meta` key holding the rendered HTML."
  def html_key do
    @html_key
  end

  @doc "The static view document."
  def shell do
    @shell
  end

  @doc """
  Renders a successful result: the SQL, a row count, and the table. `columns` are the
  result's labels and `rows` lists of values in the same order.
  """
  @spec fragment(String.t(), [String.t()], [list()]) :: String.t()
  def fragment(sql, columns, rows) do
    header = [
      "<thead><tr>",
      Enum.map(columns, &["<th>", text(&1, @max_cell_chars), "</th>"]),
      "</tr></thead>",
    ]

    {shown, body} = take_rows(rows, 0, @max_row_bytes, [])

    IO.iodata_to_binary([
      sql_block(sql),
      ~s(<p class="summary">),
      summary(shown, length(rows)),
      "</p>",
      ~s(<div class="scroll"><table>),
      header,
      "<tbody>",
      body,
      "</tbody></table></div>",
    ])
  end

  @doc "Renders a failed query: the SQL and the error message."
  @spec error_fragment(String.t(), String.t()) :: String.t()
  def error_fragment(sql, message) do
    IO.iodata_to_binary([
      sql_block(sql),
      ~s(<p class="error">),
      text(message, @max_cell_chars),
      "</p>",
    ])
  end

  # Rows are rendered in order until the row cap or the byte budget would be passed.
  defp take_rows([], shown, _budget, acc) do
    {shown, Enum.reverse(acc)}
  end

  defp take_rows(_rows, @max_rows, _budget, acc) do
    {@max_rows, Enum.reverse(acc)}
  end

  defp take_rows([row | rows], shown, budget, acc) do
    html = IO.iodata_to_binary(["<tr>", Enum.map(row, &cell/1), "</tr>"])

    if byte_size(html) > budget do
      {shown, Enum.reverse(acc)}
    else
      take_rows(rows, shown + 1, budget - byte_size(html), [html | acc])
    end
  end

  defp cell(nil) do
    ~s(<td class="null">null</td>)
  end

  defp cell(true) do
    ~s(<td class="true">true</td>)
  end

  defp cell(false) do
    ~s(<td class="false">false</td>)
  end

  defp cell(value) when is_binary(value) do
    ["<td>", text(value, @max_cell_chars), "</td>"]
  end

  defp cell(value) when is_number(value) do
    [~s(<td class="number">), JSON.encode!(value), "</td>"]
  end

  defp cell(value) do
    [~s(<td class="list">), text(JSON.encode!(value), @max_cell_chars), "</td>"]
  end

  defp sql_block(sql) do
    [~s(<pre class="sql">), text(sql, @max_sql_chars), "</pre>"]
  end

  defp summary(0, 0) do
    "No rows"
  end

  defp summary(1, 1) do
    "1 row"
  end

  defp summary(total, total) do
    "#{count(total)} rows"
  end

  defp summary(0, total) do
    "The first row is too wide to show here; the full result of #{count(total)} rows went to the model"
  end

  defp summary(shown, total) do
    "Showing #{count(shown)} of #{count(total)} rows; the full result went to the model"
  end

  # Escaped text, cut to `max` characters with an ellipsis. Invalid UTF-8 and control
  # characters other than tab and newlines are replaced, so the page stays valid HTML
  # and well-formed XML.
  defp text(value, max) do
    value =
      value
      |> String.replace_invalid()
      |> String.replace(~r/[\x00-\x08\x0B\x0C\x0E-\x1F]/u, "\uFFFD")

    value =
      if String.length(value) > max do
        String.slice(value, 0, max) <> "…"
      else
        value
      end

    Plug.HTML.html_escape_to_iodata(value)
  end

  defp count(n) when n < 1_000 do
    Integer.to_string(n)
  end

  defp count(n) do
    thousands = n |> rem(1_000) |> Integer.to_string() |> String.pad_leading(3, "0")
    count(div(n, 1_000)) <> "," <> thousands
  end
end

defmodule Guardian.Web.MCP.ResultsViewTest do
  use ExUnit.Case, async: true

  alias Guardian.Web.MCP.ResultsView

  require Record

  Record.defrecordp(
    :xml_element,
    :xmlElement,
    Record.extract(:xmlElement, from_lib: "xmerl/include/xmerl.hrl")
  )

  Record.defrecordp(
    :xml_text,
    :xmlText,
    Record.extract(:xmlText, from_lib: "xmerl/include/xmerl.hrl")
  )

  Record.defrecordp(
    :xml_attribute,
    :xmlAttribute,
    Record.extract(:xmlAttribute, from_lib: "xmerl/include/xmerl.hrl")
  )

  # The fragment is well-formed XML, so OTP's xmerl parses it. Returns the root.
  defp parse(fragment) do
    {root, []} =
      ("<root>" <> fragment <> "</root>")
      |> :binary.bin_to_list()
      |> :xmerl_scan.string(quiet: true)

    root
  end

  defp all(root, path) do
    :xmerl_xpath.string(String.to_charlist(path), root)
  end

  defp text(node) do
    node
    |> xml_element(:content)
    |> Enum.map_join(fn
      xml_text(value: value) -> List.to_string(value)
      element -> text(element)
    end)
  end

  defp class(node) do
    Enum.find_value(xml_element(node, :attributes), fn
      xml_attribute(name: :class, value: value) -> List.to_string(value)
      _ -> nil
    end)
  end

  defp texts(root, path) do
    Enum.map(all(root, path), &text/1)
  end

  test "renders the SQL, a row count and a table in column order" do
    root =
      ResultsView.fragment("SELECT b, a FROM t", ["b", "a"], [["x", 1], ["y", 2.5]])
      |> parse()

    assert texts(root, "//pre") == ["SELECT b, a FROM t"]
    assert texts(root, "//p") == ["2 rows"]
    assert texts(root, "//th") == ["b", "a"]
    assert texts(root, "//tbody/tr/td") == ["x", "1", "y", "2.5"]
  end

  test "marks each value's type and writes null, booleans and lists" do
    root =
      ResultsView.fragment("q", ~w(a b c d e f), [[nil, true, false, 7, "s", ["l", 1, nil]]])
      |> parse()

    cells = all(root, "//td")

    assert Enum.map(cells, &text/1) == ["null", "true", "false", "7", "s", ~s(["l",1,null])]
    assert Enum.map(cells, &class/1) == ["null", "true", "false", "number", nil, "list"]
  end

  test "values, labels, SQL and errors are text, never markup" do
    hostile = ~s|<img src=x onerror="alert(1)">&amp;<script>alert('x')</script>|
    root = ResultsView.fragment(hostile, [hostile], [[hostile]]) |> parse()

    assert all(root, "//img") == []
    assert all(root, "//script") == []
    assert texts(root, "//td") == [hostile]
    assert texts(root, "//th") == [hostile]
    assert texts(root, "//pre") == [hostile]

    error = ResultsView.error_fragment(hostile, hostile) |> parse()
    assert all(error, "//img") == []
    assert texts(error, "//p[@class='error']") == [hostile]
  end

  test "an empty result has its header and says so" do
    root = ResultsView.fragment("q", ["a"], []) |> parse()
    assert texts(root, "//p") == ["No rows"]
    assert texts(root, "//th") == ["a"]
    assert all(root, "//td") == []
    assert texts(ResultsView.fragment("q", ["a"], [[1]]) |> parse(), "//p") == ["1 row"]
  end

  test "shows all of 300 rows" do
    root = ResultsView.fragment("q", ["n"], for(n <- 1..300, do: [n])) |> parse()
    assert length(all(root, "//tbody/tr")) == 300
    assert texts(root, "//p") == ["300 rows"]
  end

  test "shows at most 300 rows and says how many there were" do
    rows = for n <- 1..10_000, do: [n]
    root = ResultsView.fragment("q", ["n"], rows) |> parse()

    assert length(all(root, "//tbody/tr")) == 300
    assert List.last(texts(root, "//td")) == "300"
    assert texts(root, "//p") == ["Showing 300 of 10,000 rows; the full result went to the model"]
  end

  test "stops before the rows' markup passes 100 KiB" do
    value = String.duplicate("v", 1_000)
    rows = for _ <- 1..200, do: [value, value]
    fragment = ResultsView.fragment("q", ["a", "b"], rows)
    shown = length(all(parse(fragment), "//tbody/tr"))

    # Each row is about 2 KB, so about 50 fit.
    assert shown in 45..55
    assert byte_size(fragment) < 110 * 1024

    assert texts(parse(fragment), "//p") == [
             "Showing #{shown} of 200 rows; the full result went to the model",
           ]
  end

  test "says so when even the first row is too wide to show" do
    value = String.duplicate("<", 1_000)
    root = ResultsView.fragment("q", ["a"], [List.duplicate(value, 30), [1]]) |> parse()

    assert all(root, "//tbody/tr") == []

    assert texts(root, "//p") == [
             "The first row is too wide to show here; the full result of 2 rows went to the model",
           ]
  end

  test "writes maps, large integers and floats as JSON" do
    root = ResultsView.fragment("q", ~w(a b c), [[%{"k" => 1}, 2 ** 70, 0.1]]) |> parse()
    assert texts(root, "//td") == [~s({"k":1}), "1180591620717411303424", "0.1"]
  end

  test "cuts each value at 1,000 characters and the SQL at 2,000" do
    long = String.duplicate("é", 5_000)
    root = ResultsView.fragment(long, [long], [[long, [long]]]) |> parse()

    assert [label] = texts(root, "//th")
    assert label == String.duplicate("é", 1_000) <> "…"
    assert [cell, list] = texts(root, "//td")
    assert cell == label
    assert String.length(list) == 1_001
    assert texts(root, "//pre") == [String.duplicate("é", 2_000) <> "…"]

    exact = String.duplicate("x", 1_000)
    assert texts(ResultsView.fragment("q", ["a"], [[exact]]) |> parse(), "//td") == [exact]
  end

  test "control characters are replaced, keeping the fragment well-formed" do
    root = ResultsView.fragment("q", ["a"], [["a\u0001b\tc\nd"]]) |> parse()
    assert texts(root, "//td") == ["a\uFFFDb\tc\nd"]
  end

  test "invalid UTF-8 in a string value is replaced, keeping the page valid" do
    root = ResultsView.fragment("q", ["a"], [[<<"ok", 255>>]]) |> parse()
    assert texts(root, "//td") == ["ok�"]
  end

  test "the shell allows only its own script, by hash" do
    shell = ResultsView.shell()
    [_, script] = Regex.run(~r{<script>(.*)</script>}s, shell)

    hash = "sha256-" <> Base.encode64(:crypto.hash(:sha256, script))
    assert shell =~ "script-src '#{hash}';"
    assert shell =~ "default-src 'none'"
    refute shell =~ "@SCRIPT"
    assert [_] = Regex.scan(~r{<script}, shell)
  end
end

defmodule Guardian.Query.Function.UrlPathTest do
  use Guardian.Query.EvaluationTestCase, async: true

  test "url_path function" do
    assert eval("url_path('http://domain.com/path#fragment')") === "/path"
  end

  test "url_path reads a URL whose port is too long to convert" do
    value = "http://domain.com:" <> String.duplicate("9", 1_300_000) <> "/p#f"
    assert eval("url_path(value)", value: value) === "/p"
  end
end

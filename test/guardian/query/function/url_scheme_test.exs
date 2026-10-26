defmodule Guardian.Query.Function.UrlSchemeTest do
  use Guardian.Query.EvaluationTestCase, async: true

  test "url_scheme function" do
    assert eval("url_scheme('http://domain.com/path#fragment')") === "http"
  end

  test "url_scheme reads a URL whose port is too long to convert" do
    value = "http://domain.com:" <> String.duplicate("9", 1_300_000) <> "/p#f"
    assert eval("url_scheme(value)", value: value) === "http"
  end
end

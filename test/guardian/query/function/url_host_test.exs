defmodule Guardian.Query.Function.UrlHostTest do
  use Guardian.Query.EvaluationTestCase, async: true

  test "url_host function" do
    assert eval("url_host('http://domain.com/path#fragment')") === "domain.com"
  end

  test "url_host reads a URL whose port is too long to convert" do
    value = "http://domain.com:" <> String.duplicate("9", 1_300_000) <> "/p#f"
    assert eval("url_host(value)", value: value) === "domain.com"
  end
end

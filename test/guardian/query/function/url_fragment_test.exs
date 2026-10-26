defmodule Guardian.Query.Function.UrlFragmentTest do
  use Guardian.Query.EvaluationTestCase, async: true

  test "url_fragment function" do
    assert eval("url_fragment('http://domain.com/path#fragment')") === "fragment"
  end

  test "url_fragment reads a URL whose port is too long to convert" do
    value = "http://domain.com:" <> String.duplicate("9", 1_300_000) <> "/p#f"
    assert eval("url_fragment(value)", value: value) === "f"
  end
end

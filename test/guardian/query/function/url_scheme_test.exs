defmodule Guardian.Query.Function.UrlSchemeTest do
  use Guardian.Query.EvaluationTestCase, async: true

  test "url_scheme function" do
    assert eval("url_scheme('http://domain.com/path#fragment')") === "http"
  end
end

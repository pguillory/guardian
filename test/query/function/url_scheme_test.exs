defmodule Query.Function.UrlSchemeTest do
  use Query.EvaluationTestCase, async: true

  test "url_scheme function" do
    assert eval("url_scheme('http://domain.com/path#fragment')") === "http"
  end
end

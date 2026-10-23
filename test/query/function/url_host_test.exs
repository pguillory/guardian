defmodule Query.Function.UrlHostTest do
  use Query.EvaluationTestCase, async: true

  test "url_host function" do
    assert eval("url_host('http://domain.com/path#fragment')") === "domain.com"
  end
end

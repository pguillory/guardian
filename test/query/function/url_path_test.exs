defmodule Query.Function.UrlPathTest do
  use Query.EvaluationTestCase, async: true

  test "url_path function" do
    assert eval("url_path('http://domain.com/path#fragment')") === "/path"
  end
end

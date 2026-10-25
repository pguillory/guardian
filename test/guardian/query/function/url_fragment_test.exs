defmodule Guardian.Query.Function.UrlFragmentTest do
  use Guardian.Query.EvaluationTestCase, async: true

  test "url_fragment function" do
    assert eval("url_fragment('http://domain.com/path#fragment')") === "fragment"
  end
end

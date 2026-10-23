defmodule Query.Function.UrlFragmentTest do
  use Query.EvaluationTestCase, async: true

  test "url_fragment function" do
    assert eval("url_fragment('http://domain.com/path#fragment')") === "fragment"
  end
end

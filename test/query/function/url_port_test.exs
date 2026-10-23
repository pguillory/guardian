defmodule Query.Function.UrlPortTest do
  use Query.EvaluationTestCase, async: true

  test "url_port function" do
    assert eval("url_port('http://domain.com/path#fragment')") === 80
    assert eval("url_port('asdf://domain.com/path#fragment')") === nil
    assert eval("url_port('http://domain.com:123/path#fragment')") === 123
  end
end

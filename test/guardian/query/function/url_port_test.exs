defmodule Guardian.Query.Function.UrlPortTest do
  use Guardian.Query.EvaluationTestCase, async: true

  test "url_port function" do
    assert eval("url_port('http://domain.com/path#fragment')") === 80
    assert eval("url_port('asdf://domain.com/path#fragment')") === nil
    assert eval("url_port('http://domain.com:123/path#fragment')") === 123
  end

  test "url_port gives null for a port it can't read or that is out of range" do
    for value <- [
          "",
          "http://domain.com:65536/",
          "http://domain.com:99999999999999999999999/",
          "http://domain.com:" <> String.duplicate("9", 1_300_000),
          <<0xFF, 0xFE>>,
          <<"\xFF://domain.com:1/">>,
          123,
          nil,
        ] do
      assert eval("url_port(value)", value: value) === nil, inspect(value, limit: 5)
    end

    assert eval("url_port('http://domain.com:65535/')") === 65_535
  end
end

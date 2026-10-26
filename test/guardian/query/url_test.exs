defmodule Guardian.Query.URLTest do
  use ExUnit.Case, async: true

  alias Guardian.Query.URL

  @max_port_digits 20

  # URI.parse/1's authority split (Elixir 1.19), the oracle for which digits are the port.
  @split_authority ~r/(^(.*)@)?(\[[a-zA-Z0-9:.]*\]|[^:]*)(:(\d*))?/

  @d20 String.duplicate("9", 20)
  @d21 String.duplicate("9", 21)

  @prefixes ["", "http:", "HTTP:", "//", "http://"]

  # Pieces of a URL's authority and what follows it. Digit runs of 21 or more are long
  # ports when they land in the port, and URI.parse/1 still converts them cheaply, so it
  # can be the oracle.
  @pieces [
    "h",
    ":",
    "@",
    "/",
    "?",
    "#",
    "[",
    "]",
    ".",
    "\n",
    "\r",
    "1",
    "١",
    <<0xFF>>,
    @d20,
    @d21,
    "0" <> @d20,
  ]

  test "agrees with URI.parse on every short combination of URL pieces" do
    for prefix <- @prefixes, n <- 0..3, rest <- combinations(n) do
      check(prefix <> rest)
    end
  end

  test "agrees with URI.parse on a fixed sample of longer combinations" do
    :rand.seed(:exsss, {13_211, 1, 1})

    for _ <- 1..50_000 do
      n = 3 + :rand.uniform(5)
      check(Enum.random(@prefixes) <> Enum.map_join(1..n, fn _ -> Enum.random(@pieces) end))
    end
  end

  test "agrees with URI.parse on long ports in each part of the authority" do
    for value <- [
          "http://[::1]:#{@d21}/p",
          "http://[1]x:#{@d21}/",
          "http://u:#{@d21}@h:#{@d21}/",
          "http://h:#{@d21}x/",
          "http://u\n@h:#{@d21}/",
          "//h:#{@d21}?q#f",
        ] do
      check(value)
    end
  end

  test "a port of up to 20 digits is converted, leading zeros included" do
    assert URL.parse("http://h:" <> @d20 <> "/").port == String.to_integer(@d20)
    assert URL.parse("http://h:" <> String.duplicate("0", 18) <> "80/").port == 80
    assert URL.parse("http://h:" <> String.duplicate("0", 19) <> "80/").port == nil
    assert URL.parse("http://h:" <> @d21 <> "/").port == nil
  end

  test "a port URI.parse can't convert gives the other fields and no port" do
    value = "http://u@h:" <> String.duplicate("9", 1_300_000) <> "/p?q#f"
    assert_raise SystemLimitError, fn -> URI.parse(value) end

    assert %URI{
             scheme: "http",
             userinfo: "u",
             host: "h",
             port: nil,
             path: "/p",
             query: "q",
             fragment: "f",
           } = URL.parse(value)
  end

  test "userinfo stops at a line feed, as URI.parse's does" do
    value = "http://h:" <> String.duplicate("9", 1_300_000) <> "\n@x:1/p#f"
    assert %URI{host: "h", port: nil, path: "/p", fragment: "f"} = URL.parse(value)

    value = "http://u@x:1\n@h:" <> String.duplicate("9", 1_300_000) <> "/p"
    assert %URI{userinfo: "u", host: "x", port: 1, path: "/p"} = URL.parse(value)
  end

  defp combinations(0) do
    [""]
  end

  defp combinations(n) do
    for piece <- @pieces, rest <- combinations(n - 1), do: piece <> rest
  end

  defp check(value) do
    expected = URI.parse(value)

    if long_port?(expected) do
      assert is_integer(expected.port) and expected.port >= 10 ** 19, inspect(value)

      assert Map.delete(URL.parse(value), :authority) ==
               Map.delete(%{expected | port: nil}, :authority),
             inspect(value)
    else
      assert URL.parse(value) == expected, inspect(value)
    end
  end

  defp long_port?(%URI{authority: nil}) do
    false
  end

  defp long_port?(%URI{authority: authority}) do
    case Regex.run(@split_authority, authority) do
      [_, _, _, _, _, port] -> byte_size(port) > @max_port_digits
      _ -> false
    end
  end
end

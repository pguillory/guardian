defmodule Guardian.Query.URL do
  @moduledoc """
  URL parsing for the `url_*` functions: `URI.parse/1`, made total.

  `URI.parse/1` doesn't validate, but it turns the port's digits into an integer. Over
  about 1.26 million digits that raises `system_limit`, and just under it the
  conversion takes up to about three quarters of a second per value. `parse/1` never
  converts a port of more than 20 digits (leading zeros count): it parses the value with
  those digits cut out and gives `port: nil`, not the scheme's default. Every other
  field is what `URI.parse/1` gives on the whole value, except `authority`, which
  lacks the cut digits. In that case every string field, `authority` included, is a
  fresh copy, so a short result (a host, say) does not keep the up to 8 MB cut value
  alive.

  The port is found with `URI.parse/1`'s own regular expressions, copied verbatim from
  Elixir 1.19 (the prefix of its main pattern, which captures exactly what the whole
  pattern does, and its authority split), so the digits cut are the ones it would
  convert. They are fixed internal patterns, not user patterns, so
  `Guardian.Query.Regex`'s policy (match limits, group cap) doesn't apply. As a
  backstop, a `system_limit` from `URI.parse/1` gives an empty `%URI{}`; with the cap
  it can't happen.
  """

  @max_port_digits 20

  @authority ~r{^(([a-z][a-z0-9\+\-\.]*):)?(//([^/?#]*))?}i
  @split_authority ~r/(^(.*)@)?(\[[a-zA-Z0-9:.]*\]|[^:]*)(:(\d*))?/

  @doc "Parses `value` like `URI.parse/1`, without converting a long port. Never raises."
  def parse(value) when is_binary(value) do
    case long_port(value) do
      nil ->
        URI.parse(value)

      {at, length} ->
        rest = byte_size(value) - at - length
        cut = binary_part(value, 0, at) <> binary_part(value, at + length, rest)
        uri = URI.parse(cut)

        %URI{
          uri
          | scheme: copy(uri.scheme),
            userinfo: copy(uri.userinfo),
            host: copy(uri.host),
            port: nil,
            path: copy(uri.path),
            query: copy(uri.query),
            fragment: copy(uri.fragment),
            authority: copy(uri.authority),
        }
    end
  catch
    :error, :system_limit -> %URI{}
  end

  defp copy(nil) do
    nil
  end

  defp copy(field) do
    :binary.copy(field)
  end

  # The byte offset and length of the port's digits when there are more than
  # @max_port_digits of them, or nil. Regex.run leaves out unmatched trailing groups,
  # so a value with no authority, or an authority with no port, matches neither list.
  defp long_port(value) do
    with [_, _, _, _, {authority_at, authority_length}]
         when authority_length > @max_port_digits <-
           Regex.run(@authority, value, return: :index),
         authority = binary_part(value, authority_at, authority_length),
         [_, _, _, _, _, {port_at, port_length}] when port_length > @max_port_digits <-
           Regex.run(@split_authority, authority, return: :index) do
      {authority_at + port_at, port_length}
    else
      _ -> nil
    end
  end
end

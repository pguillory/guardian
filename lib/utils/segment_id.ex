defmodule Guardian.SegmentID do
  defmacro match(opts \\ []) do
    underscore =
      quote do
        _
      end

    {segment_id, opts} = Keyword.pop_first(opts, :segment_id, underscore)
    [] = opts

    quote do
      <<unquote(segment_id)::binary-size(32)>>
    end
  end

  def generate do
    timestamp = System.os_time(:nanosecond)
    random = :crypto.strong_rand_bytes(8)
    Base.encode16(<<timestamp::size(64), random::binary-size(8)>>)
  end

  def get_timestamp_nanoseconds(segment_id) do
    <<timestamp::size(64), _::binary-size(8)>> = Base.decode16!(segment_id)
    timestamp
  end

  def timestamp(segment_id) do
    get_timestamp_nanoseconds(segment_id)
    |> System.convert_time_unit(:nanosecond, :second)
    |> Guardian.Timestamp.from_seconds()
  end
end

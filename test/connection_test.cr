require "./test_helper"
require "../src/http2"

class HTTP2::ConnectionTest < Minitest::Test
  def test_headers_frame_with_end_stream_closes_the_stream
    headers_frame = {
      Frame::Type::HEADERS,
      Frame::Flags::END_HEADERS | Frame::Flags::END_STREAM,
      1,
      HPACK::Encoder.new(huffman: false).encode(HTTP::Headers{":status" => "204"}),
    }
    connection = new_connection(:client, headers_frame)
    stream = connection.streams.create(Stream::State::HALF_CLOSED_LOCAL)
    connection.receive
    assert_equal Stream::State::CLOSED, stream.state
    assert_empty stream.data.gets_to_end
  end

  # A unary gRPC response: HEADERS, DATA, then trailing HEADERS with END_STREAM.
  # The trailers close the stream before the client reads the body, so the
  # data must survive the transition to CLOSED.
  def test_data_stays_readable_after_trailers_close_the_stream
    encoder = HPACK::Encoder.new(huffman: false)
    body = Bytes.new(64) { |i| i.to_u8 }

    headers_frame = {
      Frame::Type::HEADERS,
      Frame::Flags::END_HEADERS,
      1,
      encoder.encode(HTTP::Headers{":status" => "200"}),
    }
    data_frame = {Frame::Type::DATA, Frame::Flags::None, 1, body}
    trailers_frame = {
      Frame::Type::HEADERS,
      Frame::Flags::END_HEADERS | Frame::Flags::END_STREAM,
      1,
      encoder.encode(HTTP::Headers{"grpc-status" => "0"}),
    }

    connection = new_connection(:client, headers_frame, data_frame, trailers_frame)
    # the client already sent its request with END_STREAM
    stream = connection.streams.create(Stream::State::HALF_CLOSED_LOCAL)
    assert_equal 1, stream.id

    3.times { connection.receive }

    assert_equal Stream::State::CLOSED, stream.state
    assert_equal "200", stream.headers[":status"]
    assert_equal "0", stream.trailers?.try(&.["grpc-status"]?)
    # checked first: reading a fresh, never-closed buffer blocks forever
    assert_equal body.size, stream.data.size
    assert_equal body, stream.data.gets_to_end.to_slice
  end
end

require "./test_helper"
require "../src/http2"

class HTTP2::StreamTest < Minitest::Test
  def test_peer_reset_wakes_writer_waiting_on_flow_control
    reset = {Frame::Type::RST_STREAM, Frame::Flags::None, 1, Bytes[0, 0, 0, 8]}
    connection, _, _ = new_blocked_writer(reset)

    connection.receive
    assert_stream_closed { wait }
  end

  def test_local_reset_wakes_writer_waiting_on_flow_control
    _, stream, _ = new_blocked_writer

    stream.send_rst_stream(Error::Code::CANCEL)
    assert_stream_closed { wait }
  end

  def test_connection_close_wakes_writer_waiting_on_flow_control
    connection, _, _ = new_blocked_writer

    connection.close
    assert_stream_closed { wait }
  end

  def test_send_data_on_closed_stream_raises_without_writing
    output = IO::Memory.new
    connection = Connection.new(IO::Stapled.new(IO::Memory.new, output), :client)
    stream = connection.streams.create(state: Stream::State::OPEN)
    stream.send_rst_stream(Error::Code::CANCEL)
    written = output.size

    assert_stream_closed { stream.send_data("hello") }
    assert_stream_closed { stream.send_data("") }
    assert_equal written, output.size
  end

  def test_window_update_resumes_writer
    update = {Frame::Type::WINDOW_UPDATE, Frame::Flags::None, 0, Bytes[0, 1, 0, 0]}
    stream_update = {Frame::Type::WINDOW_UPDATE, Frame::Flags::None, 1, Bytes[0, 1, 0, 0]}
    connection, _, output = new_blocked_writer(update, stream_update)

    connection.receive
    connection.receive
    wait

    assert_equal DEFAULT_INITIAL_WINDOW_SIZE * 2, data_bytes_written(output)
  end

  private def new_blocked_writer(*frames)
    input = IO::Memory.new
    frames.each { |frame| write_frame(input, *frame) }
    input.rewind
    output = IO::Memory.new
    connection = Connection.new(IO::Stapled.new(input, output), :client)
    stream = connection.streams.create(state: Stream::State::OPEN)

    async { stream.send_data(Bytes.new(DEFAULT_INITIAL_WINDOW_SIZE * 2)) }
    until stream.@outbound_window_size == 0
      Fiber.yield
    end

    {connection, stream, output}
  end

  private def assert_stream_closed(&)
    error = assert_raises(Error) { yield }
    assert_equal Error::Code::STREAM_CLOSED, error.code
  end

  private def data_bytes_written(output)
    output.rewind
    total = 0
    while output.pos < output.size
      header = output.read_bytes(UInt32, IO::ByteFormat::BigEndian)
      output.skip(5)
      size = (header >> 8).to_i
      total += size if header & 0xff == Frame::Type::DATA.to_u8
      output.skip(size)
    end
    total
  end
end

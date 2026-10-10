require_relative "test_helper"

class GeminiStreamingTest < Minitest::Test
  class Response
    attr_reader :code, :read_count
    def initialize(chunks, code)
      @chunks, @code, @read_count = chunks, code, 0
    end
    def read_body
      @chunks.each do |chunk|
        raise chunk if chunk.is_a?(Exception)
        @read_count += 1
        yield chunk
      end
    end
  end
  class Http
    attr_accessor :open_timeout, :read_timeout
    attr_reader :request_received
    def initialize(response)
      @response = response
    end
    def request(request)
      @request_received = request
      yield @response
    end
  end
  def setup
    AiLite::Gemini.reset_configuration!
    @client = AiLite::Gemini.new(api_key: "test-key", timeout: 8)
  end
  def event(type, fields = {})
    "data: #{JSON.generate(fields.merge('event_type' => type))}\n\n"
  end
  def start
    event("interaction.created", "interaction" => { "id" => "stream-id", "status" => "in_progress" }) +
      event("step.start", "index" => 0, "step" => { "type" => "model_output" })
  end
  def delta(text, index = 0)
    event("step.delta", "index" => index, "delta" => { "type" => "text", "text" => text })
  end
  def finish(status = "completed")
    event("interaction.completed", "interaction" => { "id" => "stream-id", "status" => status, "usage" => { "total_tokens" => 4 } })
  end
  def with_http(chunks, code = "200")
    response = Response.new(chunks, code)
    http = Http.new(response)
    original = Net::HTTP.method(:start)
    Net::HTTP.define_singleton_method(:start) do |host, port, use_ssl:, &block|
      raise "Wrong provider" unless host == "generativelanguage.googleapis.com" && port == 443 && use_ssl
      block.call(http)
    end
    yield http, response
  ensure
    Net::HTTP.define_singleton_method(:start, original)
  end
  def test_incremental_delivery_request_options_and_partial_terminal_resource
    options = { "stream" => false, generation_config: { temperature: 0.2 } }
    original = Marshal.dump(options)
    with_http([start, delta("Hi"), delta(" there"), finish]) do |http, response|
      pieces = []
      result = @client.chat_stream([{ type: "text", text: "Hello" }], model: "custom-model",
        instructions: "Brief", previous_response_id: "previous", max_output_tokens: 50,
        options: options, debug: true) do |text|
        pieces << text
        assert_equal pieces.size + 1, response.read_count
      end
      assert_equal ["Hi", " there"], pieces
      assert_equal "Hi there", result["content"]
      assert_equal "stream-id", result["response_id"]
      assert_nil result["error"]
      assert_equal 4, result.dig("raw", "interaction", "usage", "total_tokens")
      assert_equal 5, result["raw"]["events"].size
      request = http.request_received
      assert_equal "/v1beta/interactions", request.path
      assert_equal "test-key", request["x-goog-api-key"]
      assert_nil request["Authorization"]
      assert_equal "text/event-stream", request["Accept"]
      payload = JSON.parse(request.body)
      assert_equal true, payload["stream"]
      assert_equal "previous", payload["previous_interaction_id"]
      assert_equal "Brief", payload["system_instruction"]
      assert_equal "custom-model", payload["model"]
      assert_equal 50, payload.dig("generation_config", "max_output_tokens")
      assert_equal 0.2, payload.dig("generation_config", "temperature")
      assert_equal 8, http.read_timeout
      assert_equal 8, http.open_timeout
      assert_equal original, Marshal.dump(options)
    end
  end
  def test_fragmented_utf8_multiline_sse_and_reasoning_filter
    stream = ": heartbeat\r\n\r\n" + start +
      event("step.start", "index" => 1, "step" => { "type" => "thought" }) + delta("Secret", 1) +
      "data: {\"event_type\":\"step.delta\",\r\ndata: \"index\":0,\"delta\":{\"type\":\"text\",\"text\":\"🌍\"}}\r\n\r\n" +
      event("step.stop", "index" => 0) + finish
    with_http(stream.bytes.map(&:chr)) do
      parts = []
      result = @client.chat_stream("Hello") { |text| parts << text }
      assert_equal ["🌍"], parts
      assert_equal "🌍", result["content"]
      assert_nil result["raw"]
      assert_nil result["error"]
    end
  end
  def test_json_and_class_delegation
    AiLite::Gemini.configure { |c| c.api_key = "key" }
    with_http([start + delta('{"ok":true}') + finish]) do
      result = AiLite::Gemini.chat_stream("JSON") { |_| }
      assert_equal({ "ok" => true }, result["content"])
    end
  end
  def test_failure_events_and_interrupted_streams
    tails = [finish("incomplete"), finish("failed"), finish("requires_action"),
      event("interaction.status_update", "status" => "cancelled"),
      event("error", "error" => { "message" => "Overloaded" }),
      "data: [DONE]\n\n", "data: {broken}\n\n", "data: {", IOError.new("Disconnected")]
    tails.each do |tail|
      with_http([start, delta("Partial"), tail]) do
        result = @client.chat_stream("Hi", debug: true) { |_| }
        assert_equal "Partial", result["content"]
        assert_equal "stream-id", result["response_id"]
        refute_nil result["error"]
        refute_nil result["raw"]
      end
    end
    with_http([start]) do
      assert_match(/terminal/, @client.chat_stream("Hi") { |_| }["error"])
    end
  end
  def test_http_errors_and_block_exceptions
    with_http(['{"error":{"message":"Denied"}}'], "403") do
      result = @client.chat_stream("Hi") { flunk "Unexpected callback" }
      assert_equal 403, result["status"]
      assert_equal "Denied", result["error"]
    end
    with_http(["Bad gateway"], "502") do
      result = @client.chat_stream("Hi", debug: true) { flunk "Unexpected callback" }
      assert_equal 502, result["status"]
      assert_equal "Bad gateway", result["raw"]
      refute_nil result["error"]
    end
    assert_raises(ArgumentError) { @client.chat_stream("Hi") }
    with_http([start, delta("Hello")]) do
      failure = RuntimeError.new("UI error")
      assert_same failure, assert_raises(RuntimeError) { @client.chat_stream("Hi") { raise failure } }
    end
  end
  def test_mixed_sse_newlines_and_lone_cr_at_eof
    stream = start.gsub("\n\n", "\r\n\n") + delta("Hello") + finish.gsub("\n", "\r")
    with_http(stream.bytes.map(&:chr)) do
      parts = []
      result = @client.chat_stream("Hi") { |text| parts << text }
      assert_equal ["Hello"], parts
      assert_equal "Hello", result["content"]
      assert_nil result["error"]
    end
  end

  def test_invalid_request_does_not_use_http
    with_http([]) do |http, _|
      refute_nil @client.chat_stream("Hi", options: { background: true }) { |_| }["error"]
      refute_nil @client.chat_stream(nil) { |_| }["error"]
      assert_nil http.request_received
    end
  end
end

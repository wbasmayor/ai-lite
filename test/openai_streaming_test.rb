require_relative "test_helper"

class OpenAIStreamingTest < Minitest::Test
  class Response
    attr_reader :code, :read_count
    def initialize(chunks, code = "200")
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
    AiLite::OpenAI.reset_configuration!
    @client = AiLite::OpenAI.new(api_key: "test-key", timeout: 17)
  end

  def event(type, fields = {})
    "event: #{type}\ndata: #{JSON.generate(fields.merge('type' => type))}\n\n"
  end

  def completed(text = "Hello")
    event("response.completed", "response" => {
      "id" => "resp_test", "status" => "completed", "usage" => { "output_tokens" => 2 },
      "output" => [{ "type" => "message", "content" => [{ "type" => "output_text", "text" => text }] }]
    })
  end

  def with_http(chunks, code = "200")
    response = Response.new(chunks, code)
    http = Http.new(response)
    original = Net::HTTP.method(:start)
    Net::HTTP.define_singleton_method(:start) do |host, port, use_ssl:, &block|
      raise "Wrong endpoint" unless host == "api.openai.com" && port == 443 && use_ssl
      block.call(http)
    end
    yield http, response
  ensure
    Net::HTTP.define_singleton_method(:start, original)
  end

  def test_yields_before_reading_next_chunk_and_preserves_chat_options
    chunks = [event("response.output_text.delta", "delta" => "Hel"),
              event("response.output_text.delta", "delta" => "lo"), completed]
    with_http(chunks) do |http, response|
      yielded = []
      result = @client.chat_stream([{ role: "user", content: "Hi" }], model: "test-model",
        instructions: "Be brief", previous_response_id: "resp_before", max_output_tokens: 9,
        options: { "stream" => false, stream: false, temperature: 0.5 }, debug: true) do |delta|
        yielded << delta
        assert_equal yielded.length, response.read_count
      end
      assert_equal ["Hel", "lo"], yielded
      assert_equal "Hello", result["content"]
      assert_equal "resp_test", result["response_id"]
      assert_equal 200, result["status"]
      assert_nil result["error"]
      assert_equal 2, result.dig("raw", "usage", "output_tokens")
      request = http.request_received
      payload = JSON.parse(request.body)
      assert_equal "/v1/responses", request.path
      assert_equal "Bearer test-key", request["Authorization"]
      assert_equal "text/event-stream", request["Accept"]
      assert_equal true, payload["stream"]
      assert_equal "test-model", payload["model"]
      assert_equal "Be brief", payload["instructions"]
      assert_equal "resp_before", payload["previous_response_id"]
      assert_equal 9, payload["max_output_tokens"]
      assert_equal 0.5, payload["temperature"]
      assert_equal [{ "role" => "user", "content" => "Hi" }], payload["input"]
      assert_equal 17, http.open_timeout
      assert_equal 17, http.read_timeout
    end
  end

  def test_byte_splits_crlf_comments_multiline_data_and_ignored_events
    stream = ": heartbeat\r\n\r\n" +
      "data: {\"type\":\"response.output_text.delta\",\r\ndata: \"delta\":\"Hi 🌍\"}\r\n\r\n" +
      event("response.output_text.done", "text" => "Hi 🌍") + completed("Hi 🌍")
    with_http(stream.bytes.map { |byte| byte.chr }) do
      parts = []
      result = @client.chat_stream("Hi") { |delta| parts << delta }
      assert_equal ["Hi 🌍"], parts
      assert_equal "Hi 🌍", result["content"]
      assert_nil result["raw"]
      assert_nil result["error"]
    end
  end

  def test_json_final_content_and_multiple_events_in_one_chunk
    with_http([event("response.output_text.delta", "delta" => '{"ok":true}') + completed('{"ok":true}')]) do
      parts = []
      result = @client.chat_stream("Hi") { |delta| parts << delta }
      assert_equal ['{"ok":true}'], parts
      assert_equal({ "ok" => true }, result["content"])
    end
  end

  def test_failed_incomplete_and_error_events_preserve_partial_text
    terminals = [
      [event("response.failed", "response" => { "id" => "resp_test", "error" => { "message" => "Failed" } }), "Failed"],
      [event("response.incomplete", "response" => { "id" => "resp_test", "incomplete_details" => { "reason" => "max_output_tokens" } }), "Response incomplete: max_output_tokens"],
      [event("error", "message" => "Rate limited"), "Rate limited"]
    ]
    terminals.each do |terminal, message|
      with_http([event("response.created", "response" => { "id" => "resp_test" }),
                 event("response.output_text.delta", "delta" => "Partial"), terminal]) do
        result = @client.chat_stream("Hi", debug: true) { |_| }
        assert_equal "Partial", result["content"]
        assert_equal message, result["error"]
        assert_equal "resp_test", result["response_id"]
        refute_nil result["raw"]
      end
    end
  end

  def test_truncation_done_marker_malformed_json_and_disconnect_are_errors
    [[], ["data: [DONE]\n\n"], ["data: {bad}\n\n"], ["data: {"], [IOError.new("Connection lost")]].each do |tail|
      with_http([event("response.output_text.delta", "delta" => "Partial")] + tail) do
        result = @client.chat_stream("Hi") { |_| }
        assert_equal "Partial", result["content"]
        refute_nil result["error"]
      end
    end
  end

  def test_http_errors_do_not_yield
    ['{"error":{"message":"Invalid API key"}}', "Bad gateway"].each do |body|
      with_http([body], "401") do
        result = @client.chat_stream("Hi", debug: true) { flunk "Should not yield" }
        assert_equal 401, result["status"]
        refute_nil result["error"]
        refute_nil result["raw"]
      end
    end
  end

  def test_missing_block_and_callback_errors_raise
    assert_raises(ArgumentError) { @client.chat_stream("Hi") }
    with_http([event("response.output_text.delta", "delta" => "Hello")]) do
      error = RuntimeError.new("UI failed")
      raised = assert_raises(RuntimeError) { @client.chat_stream("Hi") { raise error } }
      assert_same error, raised
    end
  end

  def test_mixed_sse_newlines_and_lone_cr_at_eof
    stream = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Hello\"}\r\n\n" + completed.gsub("\n", "\r")
    with_http(stream.bytes.map(&:chr)) do
      parts = []
      result = @client.chat_stream("Hi") { |delta| parts << delta }
      assert_equal ["Hello"], parts
      assert_equal "Hello", result["content"]
      assert_nil result["error"]
    end
  end

  def test_provider_and_legacy_class_methods_forward_blocks
    AiLite::OpenAI.configure { |config| config.api_key = "test-key" }
    [AiLite::OpenAI, AiLite].each do |provider|
      with_http([event("response.output_text.delta", "delta" => "Hello"), completed]) do
        parts = []
        capture_io do
          result = provider.chat_stream("Hi") { |delta| parts << delta }
          assert_equal "Hello", result["content"]
        end
        assert_equal ["Hello"], parts
      end
    end
  end
end

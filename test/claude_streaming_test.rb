require_relative "test_helper"

class ClaudeStreamingTest < Minitest::Test
  class Response
    attr_reader :code
    def initialize(chunks, code)
      @chunks, @code = chunks, code
    end
    def read_body
      @chunks.each do |chunk|
        raise chunk if chunk.is_a?(Exception)
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
    @client = AiLite::Claude.new(api_key: "test", timeout: 9)
  end

  def events(reason = "end_turn")
    [
      { type: "message_start", message: { id: "msg_test", type: "message", role: "assistant", content: [], usage: { input_tokens: 8, output_tokens: 1 } } },
      { type: "ping" },
      { type: "content_block_start", index: 0, content_block: { type: "thinking", thinking: "", signature: "" } },
      { type: "content_block_delta", index: 0, delta: { type: "thinking_delta", thinking: "Reasoning" } },
      { type: "content_block_delta", index: 0, delta: { type: "signature_delta", signature: "signed" } },
      { type: "content_block_stop", index: 0 },
      { type: "content_block_start", index: 1, content_block: { type: "text", text: "" } },
      { type: "content_block_delta", index: 1, delta: { type: "text_delta", text: "Hé" } },
      { type: "content_block_delta", index: 1, delta: { type: "text_delta", text: "llo" } },
      { type: "content_block_stop", index: 1 },
      { type: "message_delta", delta: { stop_reason: reason, stop_sequence: nil }, usage: { output_tokens: 5 } },
      { type: "message_stop" }
    ]
  end

  def wire(items = events, separator = "\r\n")
    items.map { |event| "event: #{event[:type]}#{separator}data: #{JSON.generate(event)}#{separator}#{separator}" }.join
  end

  def with_http(chunks, code = "200")
    http = Http.new(Response.new(chunks, code))
    original = Net::HTTP.method(:start)
    Net::HTTP.define_singleton_method(:start) do |host, port, use_ssl:, &block|
      raise "Wrong endpoint" unless host == "api.anthropic.com" && port == 443 && use_ssl
      block.call(http)
    end
    yield http
  ensure
    Net::HTTP.define_singleton_method(:start, original)
  end

  def test_fragmented_utf8_replay_usage_and_transport
    options = { stream: false, thinking: { type: "disabled" } }
    before = Marshal.dump(options)
    chunks = []
    # Split every byte, including UTF-8 and CRLF pairs.
    with_http(wire.bytes.map { |byte| byte.chr }) do |http|
      result = @client.chat_stream("Hi", model: "chosen", instructions: "Be brief", max_output_tokens: 40, options: options, debug: true) { |text| chunks << text }
      assert_nil result["error"]
      assert_equal ["Hé", "llo"], chunks
      assert_equal "Héllo", result["content"]
      assert_equal "msg_test", result["response_id"]
      assert_equal "signed", result.dig("assistant_message", "content", 0, "signature")
      assert_equal "Reasoning", result.dig("assistant_message", "content", 0, "thinking")
      assert_equal({ "input_tokens" => 8, "output_tokens" => 5 }, result["raw"]["usage"])
      request = http.request_received
      assert_equal "/v1/messages", request.path
      assert_equal "Bearer test", request["Authorization"]
      assert_equal @client.api_version, request["anthropic-version"]
      assert_equal "text/event-stream", request["Accept"]
      payload = JSON.parse(request.body)
      assert_equal true, payload["stream"]
      assert_equal "chosen", payload["model"]
      assert_equal "Be brief", payload["system"]
      assert_equal 40, payload["max_tokens"]
      assert_equal 9, http.open_timeout
      assert_equal 9, http.read_timeout
    end
    assert_equal before, Marshal.dump(options)
  end

  def test_json_and_class_delegation_without_debug
    items = events
    items[7][:delta][:text] = '{"ok":'
    items[8][:delta][:text] = 'true}'
    AiLite::Claude.configure { |config| config.api_key = "test" }
    with_http([wire(items)]) do
      result = AiLite::Claude.chat_stream([{ role: "user", content: "JSON please" }]) { |_| }
      assert_equal({ "ok" => true }, result["content"])
      assert_nil result["raw"]
      assert_equal '{"ok":true}', result.dig("assistant_message", "content", 1, "text")
    end
  ensure
    AiLite::Claude.reset_configuration!
  end

  def test_incomplete_and_transport_failure_preserve_partial_text
    [[wire(events[0...9])], [wire(events[0...9]), IOError.new("connection lost")]].each do |chunks|
      with_http(chunks) do
        result = @client.chat_stream("Hi") { |_| }
        assert_equal "Héllo", result["content"]
        assert_equal "msg_test", result["response_id"]
        refute_nil result["error"]
        refute result.key?("assistant_message")
      end
    end
  end

  def test_http_and_stream_errors
    with_http(['{"error":{"message":"Unauthorized"}}'], "401") do
      result = @client.chat_stream("Hi") { flunk "Unexpected text" }
      assert_equal 401, result["status"]
      assert_equal "Unauthorized", result["error"]
    end
    with_http([wire(events[0...9] + [{ type: "error", error: { message: "Overloaded" } }])]) do
      result = @client.chat_stream("Hi") { |_| }
      assert_equal "Overloaded", result["error"]
      assert_equal "Héllo", result["content"]
    end
  end

  def test_non_success_stop_reasons_and_terminal_closes_connection
    %w[max_tokens refusal pause_turn tool_use].each do |reason|
      with_http([wire(events(reason)), IOError.new("Should not read after terminal")]) do
        result = @client.chat_stream("Hi") { |_| }
        assert_includes result["error"], reason
        assert_equal "Héllo", result["content"]
        refute_nil result["assistant_message"]
      end
    end
  end

  def test_native_tool_fragments_citations_and_redacted_thinking_are_preserved
    items = events("tool_use")
    items.insert(9, { type: "content_block_delta", index: 1,
      delta: { type: "citations_delta", citation: { type: "char_location", cited_text: "source" } } })
    items.insert(-3,
      { type: "content_block_start", index: 2, content_block: { type: "redacted_thinking", data: "opaque" } },
      { type: "content_block_stop", index: 2 },
      { type: "content_block_start", index: 3, content_block: { type: "tool_use", id: "tool_1", name: "lookup", input: {} } },
      { type: "content_block_delta", index: 3, delta: { type: "input_json_delta", partial_json: '{"city":' } },
      { type: "content_block_delta", index: 3, delta: { type: "input_json_delta", partial_json: '"Manila"}' } },
      { type: "content_block_stop", index: 3 })
    with_http([wire(items)]) do
      yielded = []
      result = @client.chat_stream("Hi") { |delta| yielded << delta }
      assert_equal ["Hé", "llo"], yielded
      assert_nil result["error"]
      assert_equal "Manila", result["tool_calls"][0]["arguments"]["city"]
      blocks = result.fetch("assistant_message").fetch("content")
      assert_equal "source", blocks[1]["citations"][0]["cited_text"]
      assert_equal "opaque", blocks[2]["data"]
      assert_equal({ "city" => "Manila" }, blocks[3]["input"])
    end
  end

  def test_stream_tool_payload_and_incomplete_arguments
    history = [{ role: "assistant", content: [
      { type: "tool_use", id: "a", name: "lookup", input: {} }
    ] }]
    tools = [{ name: "lookup", input_schema: { type: "object" } }]
    with_http([wire]) do |http|
      result = @client.chat_stream(history, tools: tools,
        tool_results: [{ id: "a", name: "lookup", output: 42 }]) { |_| }
      assert_nil result["error"]
      payload = JSON.parse(http.request_received.body)
      assert_equal "lookup", payload["tools"][0]["name"]
      assert_equal "42", payload["messages"].last["content"][0]["content"]
    end
    prefix = [events.first,
      { type: "content_block_start", index: 0, content_block: { type: "tool_use", id: "a", name: "lookup", input: {} } },
      { type: "content_block_delta", index: 0, delta: { type: "input_json_delta", partial_json: '{"x":' } }]
    [prefix, prefix + [{ type: "content_block_stop", index: 0 }],
      prefix + [{ type: "message_delta", delta: { stop_reason: "tool_use" } }, { type: "message_stop" }]].each do |items|
      with_http([wire(items)]) do
        result = @client.chat_stream("Hi", tools: tools) { flunk "Tool arguments must not be yielded" }
        refute_nil result["error"]
        refute result.key?("tool_calls")
      end
    end
  end

  def test_callback_errors_propagate_and_block_is_required
    assert_raises(ArgumentError) { @client.chat_stream("Hi") }
    failure = RuntimeError.new("caller failed")
    with_http([wire]) do
      assert_same failure, assert_raises(RuntimeError) { @client.chat_stream("Hi") { raise failure } }
    end
    assert_match(/explicit message history/, @client.chat_stream("Hi", previous_response_id: "id") { |_| }["error"])
    assert_match(/options must be a hash/, @client.chat_stream("Hi", options: nil) { |_| }["error"])
  end

  def test_unknown_events_multiline_data_and_malformed_streams
    with_http([": comment\ndata: {\ndata: \"type\": \"future_event\"}\n\n", wire(events, "\r")]) do
      assert_nil @client.chat_stream("Hi") { |_| }["error"]
    end
    ["data: nope\n\n", "data: []\n\n", wire([{ type: "message_stop" }]), wire(events[0...9] + [{ type: "message_stop" }])].each do |data|
      with_http([data]) { refute_nil @client.chat_stream("Hi") { |_| }["error"] }
    end
  end
  def test_media_helper_blocks_pass_through_streaming
    history = [{ role: "user", content: [
      @client.image_input(url: "https://example.com/image"),
      @client.pdf_input(url: "https://example.com/report"),
      { type: "text", text: "Describe these." }
    ] }]
    with_http([wire]) do |http|
      assert_nil @client.chat_stream(history) { |_| }["error"]
      assert_equal JSON.parse(JSON.generate(history)), JSON.parse(http.request_received.body)["messages"]
    end
  end

end

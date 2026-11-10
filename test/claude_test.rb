require_relative "test_helper"

class ClaudeTest < Minitest::Test
  Response = Struct.new(:code, :body)
  class Http
    attr_accessor :open_timeout, :read_timeout
    attr_reader :request_received
    def initialize(response)
      @response = response
    end
    def request(request)
      @request_received = request
      raise @response if @response.is_a?(Exception)
      @response
    end
  end

  def setup
    AiLite::Claude.reset_configuration!
    @old_key = ENV.delete("ANTHROPIC_API_KEY")
    @client = AiLite::Claude.new(api_key: "claude-test", timeout: 7)
  end

  def teardown
    ENV["ANTHROPIC_API_KEY"] = @old_key
    AiLite::Claude.reset_configuration!
  end

  def body(text = "Hello", reason = "end_turn")
    { "id" => "msg_123", "type" => "message", "role" => "assistant", "stop_reason" => reason,
      "content" => [{ "type" => "thinking", "thinking" => "private", "signature" => "sig" },
                      { "type" => "text", "text" => text }], "usage" => { "input_tokens" => 3 } }
  end

  def with_http(raw = body, status = "200")
    http = Http.new(raw.is_a?(Exception) ? raw : Response.new(status, raw.is_a?(String) ? raw : JSON.generate(raw)))
    original = Net::HTTP.method(:start)
    Net::HTTP.define_singleton_method(:start) do |host, port, use_ssl:, &block|
      raise "Wrong Claude endpoint" unless host == "api.anthropic.com" && port == 443 && use_ssl
      block.call(http)
    end
    yield http
  ensure
    Net::HTTP.define_singleton_method(:start, original)
  end

  def test_configuration_key_precedence_and_provider_isolation
    assert_raises(ArgumentError) { AiLite::Claude.new }
    ENV["ANTHROPIC_API_KEY"] = "env-key"
    assert_equal "env-key", AiLite::Claude.new.api_key
    previous = AiLite::OpenAI.configuration.model
    AiLite::Claude.configure { |c| c.api_key = "configured"; c.model = "custom"; c.workspace_id = "wrkspc_test"; c.api_version = "custom-version" }
    assert_equal "configured", AiLite::Claude.new.api_key
    assert_equal "explicit", AiLite::Claude.new(api_key: "explicit").api_key
    assert_equal "custom", AiLite::Claude.client.model
    assert_equal "wrkspc_test", AiLite::Claude.client.headers["anthropic-workspace-id"]
    assert_equal "custom-version", AiLite::Claude.client.headers["anthropic-version"]
    old_client = AiLite::Claude.client
    AiLite::Claude.configure { |c| c.model = "other" }
    refute_same old_client, AiLite::Claude.client
    assert_equal previous, AiLite::OpenAI.configuration.model
    AiLite::Claude.reset_configuration!
    assert_equal "claude-haiku-5-5", AiLite::Claude.new.model
    %i[chat_stream embed speak transcribe image moderate count_tokens available_models].each { |method| refute_respond_to @client, method }
  end

  def test_chat_transport_and_replay_message
    with_http do |http|
      result = @client.chat("Hi")
      assert_equal "Hello", result["content"]
      assert_equal "msg_123", result["response_id"]
      assert_equal 200, result["status"]
      assert_nil result["error"]
      assert_nil result["raw"]
      assert_equal({ "role" => "assistant", "content" => body["content"] }, result["assistant_message"])
      request = http.request_received
      assert_equal "/v1/messages", request.path
      assert_equal "Bearer claude-test", request["Authorization"]
      assert_equal "2026-10-21", request["anthropic-version"]
      assert_nil request["x-goog-api-key"]
      assert_equal 7, http.open_timeout
      assert_equal 7, http.read_timeout
      assert_equal({ "model" => "claude-haiku-5-5", "messages" => [{ "role" => "user", "content" => "Hi" }], "max_tokens" => 2000 }, JSON.parse(request.body))
      history = [{ role: "user", content: "Hi" }, result["assistant_message"], { role: "user", content: "Continue" }]
      @client.chat(history)
      assert_equal JSON.parse(JSON.generate(history)), JSON.parse(http.request_received.body)["messages"]
    end
  end

  def test_options_native_media_precedence_and_no_mutation
    history = [{ role: "user", content: [{ type: "image", source: { type: "base64", media_type: "image/png", data: "AAAA" } }] }]
    options = { "model" => "ignored", messages: [], max_tokens: 10, system: "ignored", thinking: { type: "disabled" } }
    original = Marshal.dump([history, options])
    with_http(body('{"ok":true}')) do |http|
      result = @client.chat(history, model: "selected", instructions: "Brief", max_output_tokens: 20, options: options, debug: true)
      assert_equal({ "ok" => true }, result["content"])
      assert_equal body('{"ok":true}'), result["raw"]
      payload = JSON.parse(http.request_received.body)
      assert_equal "selected", payload["model"]
      assert_equal "Brief", payload["system"]
      assert_equal 20, payload["max_tokens"]
      assert_equal({ "type" => "disabled" }, payload["thinking"])
      assert_equal JSON.parse(JSON.generate(history)), payload["messages"]
    end
    assert_equal original, Marshal.dump([history, options])
    with_http do |http|
      @client.chat("Hi", options: { max_tokens: 12, system: [{ type: "text", text: "Native" }] })
      assert_equal 12, JSON.parse(http.request_received.body)["max_tokens"]
      assert_equal [{ "type" => "text", "text" => "Native" }], JSON.parse(http.request_received.body)["system"]
    end
  end

  def test_class_delegation_and_text_only_output
    AiLite::Claude.configure { |c| c.api_key = "configured" }
    with_http(body("Hello", "stop_sequence")) { assert_equal "Hello", AiLite::Claude.chat("Hi")["content"] }
    with_http(body.merge("content" => [])) { assert_nil @client.chat("Hi")["content"] }
  end

  def test_stop_reasons_and_malformed_responses
    %w[max_tokens refusal model_context_window_exceeded pause_turn tool_use unknown].each do |reason|
      with_http(body("Partial", reason)) do
        result = @client.chat("Hi")
        assert_equal "Partial", result["content"]
        assert_includes result["error"], reason
      end
    end
    [[], {}, body.merge("content" => nil), body.merge("role" => "user"), body.merge("content" => [{ "type" => "text", "text" => 1 }]), "not json"].each do |raw|
      with_http(raw) do
        result = @client.chat("Hi", debug: true)
        refute_nil result["error"]
        assert_equal 200, result["status"]
        assert_equal raw, result["raw"]
      end
    end
    ["200", "401", "429", "529"].each do |status|
      with_http({ "error" => { "type" => "overloaded_error", "message" => "Unavailable" } }, status) do
        result = @client.chat("Hi")
        assert_equal "Unavailable", result["error"]
        assert_equal status.to_i, result["status"]
        assert_nil result["raw"]
      end
    end
    with_http(IOError.new("Disconnected")) { assert_equal "unknown", @client.chat("Hi")["status"] }
  end

  def test_invalid_inputs_never_send_requests
    with_http do |http|
      [nil, 1, {}, [], [1], [{ role: "invalid", content: "Hi" }]].each { |message| refute_nil @client.chat(message)["error"] }
      [{ options: nil }, { previous_response_id: "msg_123" }, { options: { previous_response_id: "msg_123" } },
       { options: { stream: true } }, { instructions: 1 }, { max_output_tokens: -1 }].each do |kwargs|
        refute_nil @client.chat("Hi", **kwargs)["error"]
      end
      assert_nil http.request_received
    end
  end
end

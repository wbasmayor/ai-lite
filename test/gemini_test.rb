require_relative "test_helper"
require "open3"
require "rbconfig"

class GeminiTest < Minitest::Test
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
    AiLite::Gemini.reset_configuration!
    AiLite::OpenAI.reset_configuration!
    @client = AiLite::Gemini.new(api_key: "gemini-key", timeout: 9)
  end

  def body(text = "Hello")
    { "id" => "interaction_123", "status" => "completed", "steps" => [
      { "type" => "thought", "content" => [{ "type" => "text", "text" => "Hidden" }] },
      { "type" => "model_output", "content" => [{ "type" => "text", "text" => text }] }
    ], "usage" => { "total_tokens" => 10 } }
  end

  def with_http(raw = body, status = "200")
    response = raw.is_a?(Exception) ? raw : Response.new(status, raw.is_a?(String) ? raw : JSON.generate(raw))
    http = Http.new(response)
    original = Net::HTTP.method(:start)
    Net::HTTP.define_singleton_method(:start) do |host, port, use_ssl:, &block|
      raise "Wrong provider host" unless host == "generativelanguage.googleapis.com" && port == 443 && use_ssl
      block.call(http)
    end
    yield http
  ensure
    Net::HTTP.define_singleton_method(:start, original)
  end

  def test_string_chat_transport_and_envelope
    with_http do |http|
      result = @client.chat("Tell me a joke")
      assert_equal({ "content" => "Hello", "response_id" => "interaction_123", "status" => 200,
                     "error" => nil, "raw" => nil }, result)
      request = http.request_received
      assert_equal "/v1beta/interactions", request.path
      assert_equal "gemini-key", request["x-goog-api-key"]
      assert_nil request["Authorization"]
      assert_nil URI(request.path).query
      payload = JSON.parse(request.body)
      assert_equal "Tell me a joke", payload["input"]
      assert_equal AiLite::Gemini::DEFAULT_MODEL, payload["model"]
      assert_equal 2000, payload.dig("generation_config", "max_output_tokens")
      assert_equal 9, http.open_timeout
      assert_equal 9, http.read_timeout
    end
  end

  def test_structured_inputs_and_history_pass_through_without_mutation
    inputs = [
      { type: "video", uri: "https://www.youtube.com/watch?v=example" },
      [{ type: "video", uri: "https://www.youtube.com/watch?v=example" }, { type: "text", text: "Summarize" }],
      [{ type: "user_input", content: [{ type: "text", text: "Hello" }] },
       { type: "model_output", content: [{ type: "text", text: "Hi" }] }]
    ]
    inputs.each do |input|
      original = Marshal.dump(input)
      with_http do |http|
        assert_nil @client.chat(input)["error"]
        assert_equal JSON.parse(JSON.generate(input)), JSON.parse(http.request_received.body)["input"]
        assert_equal original, Marshal.dump(input)
      end
    end
  end

  def test_keywords_and_provider_options
    options = { "generation_config" => { "temperature" => 0.4, "max_output_tokens" => 50 },
                "previous_interaction_id" => "old", store: false, response_format: { type: "object" } }
    original = Marshal.dump(options)
    with_http(body('{"ok":true}')) do |http|
      result = @client.chat("Hello", model: "custom-model", instructions: "Be brief",
                            previous_response_id: "previous", max_output_tokens: 25, debug: true, options: options)
      payload = JSON.parse(http.request_received.body)
      assert_equal "custom-model", payload["model"]
      assert_equal "Be brief", payload["system_instruction"]
      assert_equal "previous", payload["previous_interaction_id"]
      refute payload.key?("previous_response_id")
      assert_equal({ "temperature" => 0.4, "max_output_tokens" => 25 }, payload["generation_config"])
      assert_equal false, payload["store"]
      assert_equal({ "ok" => true }, result["content"])
      assert_equal 10, result.dig("raw", "usage", "total_tokens")
      assert_equal original, Marshal.dump(options)
    end
  end

  def test_options_continuation_and_token_limit_without_keywords
    with_http do |http|
      @client.chat("Hi", options: { previous_interaction_id: "before", generation_config: { max_output_tokens: 33 } })
      payload = JSON.parse(http.request_received.body)
      assert_equal "before", payload["previous_interaction_id"]
      assert_equal 33, payload.dig("generation_config", "max_output_tokens")
    end
  end

  def test_config_and_cached_clients_are_isolated
    AiLite::OpenAI.configure { |config| config.api_key = "openai-key"; config.model = "openai-model" }
    openai = AiLite::OpenAI.client
    AiLite::Gemini.configure do |config|
      config.api_key = "configured-gemini"
      config.model = "configured-model"
      config.timeout = 14
      config.max_output_tokens = 88
    end
    gemini = AiLite::Gemini.client
    assert_same gemini, AiLite::Gemini.client
    assert_equal "configured-gemini", gemini.api_key
    assert_equal "configured-model", gemini.model
    assert_equal 14, gemini.timeout
    assert_equal 88, gemini.max_output_tokens
    overridden = AiLite::Gemini.new(api_key: "explicit", model: "override", timeout: 3, max_output_tokens: 4)
    assert_equal ["explicit", "override", 3, 4], [overridden.api_key, overridden.model, overridden.timeout, overridden.max_output_tokens]
    AiLite::Gemini.configure { |config| config.api_key = "new-key" }
    refute_same gemini, AiLite::Gemini.client
    assert_same openai, AiLite::OpenAI.client
    assert_equal "openai-key", openai.api_key
    refute AiLite::Gemini < AiLite::OpenAI
    %i[moderate transcribe image speak embed].each { |method| refute_respond_to gemini, method }
    with_http do
      assert_equal "Hello", AiLite::Gemini.chat("Hello")["content"]
    end
  end

  def test_gemini_key_fallback_does_not_use_openai_key
    previous = ENV.to_h.slice("GEMINI_API_KEY", "OPENAI_API_KEY", "OPEN_AI_TOKEN")
    ENV.delete("GEMINI_API_KEY")
    ENV["OPENAI_API_KEY"] = "openai-only"
    ENV["OPEN_AI_TOKEN"] = "legacy-only"
    assert_raises(ArgumentError) { AiLite::Gemini.new }
    ENV["GEMINI_API_KEY"] = "env-key"
    assert_equal "env-key", AiLite::Gemini.new.api_key
    AiLite::Gemini.configure { |config| config.api_key = "config-key" }
    assert_equal "config-key", AiLite::Gemini.new.api_key
    assert_equal "explicit-key", AiLite::Gemini.new(api_key: "explicit-key").api_key
  ensure
    %w[GEMINI_API_KEY OPENAI_API_KEY OPEN_AI_TOKEN].each do |key|
      previous.key?(key) ? ENV[key] = previous[key] : ENV.delete(key)
    end
  end

  def test_errors_and_noncompleted_interactions
    with_http({ "error" => { "code" => 403, "message" => "Permission denied" } }, "403") do
      result = @client.chat("Hi", debug: true)
      assert_equal 403, result["status"]
      assert_equal "Permission denied", result["error"]
      refute_nil result["raw"]
    end
    ["bad json", [], {}, IOError.new("Disconnected")].each do |raw|
      with_http(raw) { refute_nil @client.chat("Hi")["error"] }
    end
    %w[failed incomplete cancelled requires_action queued in_progress].each do |state|
      with_http(body.merge("status" => state)) do
        result = @client.chat("Hi", debug: true)
        assert_includes result["error"], state
        assert_equal "interaction_123", result["response_id"]
      end
    end
    with_http(body.merge("status" => "failed", "error" => { "message" => "Generation failed" })) do
      assert_equal "Generation failed", @client.chat("Hi")["error"]
    end
  end

  def test_unsupported_execution_modes_and_invalid_inputs_do_not_call_http
    with_http do |http|
      [{ stream: true }, { "background" => true }, { generation_config: nil }].each do |options|
        refute_nil @client.chat("Hi", options: options)["error"]
      end
      refute_nil @client.chat(nil)["error"]
      assert_nil http.request_received
    end
  end

  def test_direct_require
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-I#{File.expand_path('../lib', __dir__)}", "-e", <<~'CODE')
      require "ai_lite/gemini"
      abort unless AiLite::Gemini.new(api_key: "key").respond_to?(:chat)
      abort if AiLite.const_defined?(:OpenAI, false)
      require "ai_lite"
      abort unless AiLite::OpenAI.new(api_key: "key").respond_to?(:chat)
    CODE
    assert status.success?, stderr
    assert_empty stdout
    assert_empty stderr
  end
end

# frozen_string_literal: true

require_relative "test_helper"

class AiLiteTest < Minitest::Test
  FakeResponse = Struct.new(:code, :body)

  class FakeHttp
    attr_accessor :open_timeout, :read_timeout
    attr_reader :last_request

    def initialize(response)
      @response = response
    end

    def request(request)
      @last_request = request
      @response
    end
  end

  def setup
    AiLite.reset_configuration!
  end

  def test_has_a_version_number
    refute_nil AiLite::VERSION
  end

  def test_stores_initializer_config_and_headers
    with_env("OPENAI_API_KEY" => nil, "OPEN_AI_TOKEN" => nil) do
      client = AiLite.new(
        api_key: "explicit-key",
        model: "gpt-test",
        timeout: 10
      )

      assert_equal "explicit-key", client.api_key
      assert_equal "gpt-test", client.model
      assert_equal 10, client.timeout
      assert_equal 2000, client.max_output_tokens
      assert_equal "Bearer explicit-key", client.headers["Authorization"]
      assert_equal "application/json", client.headers["Content-Type"]
    end
  end

  def test_configure_sets_defaults_for_client
    with_env("OPENAI_API_KEY" => nil, "OPEN_AI_TOKEN" => nil) do
      AiLite.configure do |config|
        config.api_key = "configured-key"
        config.model = "gpt-config"
        config.timeout = 15
        config.max_output_tokens = 750
      end

      client = AiLite.client

      assert_equal "configured-key", client.api_key
      assert_equal "gpt-config", client.model
      assert_equal 15, client.timeout
      assert_equal 750, client.max_output_tokens
      assert_same client, AiLite.client
    end
  end

  def test_configure_resets_cached_client
    AiLite.configure { |config| config.api_key = "first-key" }
    first_client = AiLite.client

    AiLite.configure { |config| config.api_key = "second-key" }
    second_client = AiLite.client

    refute_same first_client, second_client
    assert_equal "second-key", second_client.api_key
  end

  def test_instance_arguments_override_configuration
    AiLite.configure do |config|
      config.api_key = "configured-key"
      config.model = "gpt-config"
      config.timeout = 15
      config.max_output_tokens = 750
    end

    client = AiLite.new(
      api_key: "explicit-key",
      model: "gpt-explicit",
      timeout: 5,
      max_output_tokens: 300
    )

    assert_equal "explicit-key", client.api_key
    assert_equal "gpt-explicit", client.model
    assert_equal 5, client.timeout
    assert_equal 300, client.max_output_tokens
  end

  def test_api_key_fallback_order
    with_env("OPENAI_API_KEY" => "openai-key", "OPEN_AI_TOKEN" => "legacy-key") do
      assert_equal "openai-key", AiLite.new.api_key
      assert_equal "explicit-key", AiLite.new(api_key: "explicit-key").api_key
    end

    with_env("OPENAI_API_KEY" => nil, "OPEN_AI_TOKEN" => "legacy-key") do
      assert_equal "legacy-key", AiLite.new.api_key
    end
  end

  def test_configured_api_key_takes_precedence_over_env
    AiLite.configure { |config| config.api_key = "configured-key" }

    with_env("OPENAI_API_KEY" => "openai-key", "OPEN_AI_TOKEN" => "legacy-key") do
      assert_equal "configured-key", AiLite.new.api_key
      assert_equal "explicit-key", AiLite.new(api_key: "explicit-key").api_key
    end
  end

  def test_missing_api_key_raises
    with_env("OPENAI_API_KEY" => nil, "OPEN_AI_TOKEN" => nil) do
      assert_raises(ArgumentError) { AiLite.new }
    end
  end

  def test_chat_sends_post_to_responses_with_default_payload
    client = AiLite.new(api_key: "token-abc")

    with_stubbed_http(success_response("Hello!")) do |captured, _response|
      result = client.chat("Say hello")
      request = captured[:http].last_request
      payload = JSON.parse(request.body)

      assert_equal "Hello!", result["content"]
      assert_equal 200, result["status"]
      assert_nil result["error"]
      assert_nil result["raw"]
      assert_equal "api.openai.com", captured[:host]
      assert_equal 443, captured[:port]
      assert_equal true, captured[:use_ssl]
      assert_instance_of Net::HTTP::Post, request
      assert_equal "/v1/responses", request.path
      assert_equal "Bearer token-abc", request["Authorization"]
      assert_equal "application/json", request["Content-Type"]
      assert_equal "gpt-5.5", payload["model"]
      assert_equal "Say hello", payload["input"]
      assert_equal 2000, payload["max_output_tokens"]
    end
  end

  def test_chat_allows_overriding_max_output_tokens
    client = AiLite.new(api_key: "token-abc")

    with_stubbed_http(success_response("Short")) do |captured, _response|
      client.chat("Summarize", max_output_tokens: 500)
      payload = JSON.parse(captured[:http].last_request.body)

      assert_equal 500, payload["max_output_tokens"]
    end
  end

  def test_chat_uses_configured_max_output_tokens
    AiLite.configure do |config|
      config.api_key = "configured-key"
      config.max_output_tokens = 750
    end

    with_stubbed_http(success_response("Configured")) do |captured, _response|
      AiLite.chat("Use configured defaults")
      payload = JSON.parse(captured[:http].last_request.body)

      assert_equal 750, payload["max_output_tokens"]
      assert_equal "Bearer configured-key", captured[:http].last_request["Authorization"]
    end
  end

  def test_chat_includes_instructions_model_and_options
    client = AiLite.new(api_key: "token-abc")

    with_stubbed_http(success_response("Aye")) do |captured, _response|
      client.chat(
        "Are semicolons optional in JavaScript?",
        model: "gpt-5.4-mini",
        instructions: "Be concise.",
        options: {
          reasoning: { effort: "none" },
          text: { verbosity: "low" },
          store: false
        }
      )
      payload = JSON.parse(captured[:http].last_request.body)

      assert_equal "gpt-5.4-mini", payload["model"]
      assert_equal "Be concise.", payload["instructions"]
      assert_equal({ "effort" => "none" }, payload["reasoning"])
      assert_equal({ "verbosity" => "low" }, payload["text"])
      assert_equal false, payload["store"]
    end
  end

  def test_extracts_text_from_nested_output_text_items
    client = AiLite.new(api_key: "token-abc")
    body = JSON.generate(
      "output" => [
        { "type" => "reasoning", "content" => [] },
        {
          "type" => "message",
          "content" => [
            { "type" => "output_text", "text" => "Hello" },
            { "type" => "output_text", "text" => " world" }
          ]
        }
      ]
    )

    with_stubbed_http(FakeResponse.new("200", body)) do |_captured, _response|
      result = client.chat("Say hello")

      assert_equal "Hello world", result["content"]
      assert_equal 200, result["status"]
      assert_nil result["error"]
    end
  end

  def test_parses_json_looking_output_with_string_keys
    client = AiLite.new(api_key: "token-abc")

    with_stubbed_http(success_response(JSON.generate("valid" => true))) do |_captured, _response|
      result = client.chat("Validate")

      assert_equal({ "valid" => true }, result["content"])
      assert_equal 200, result["status"]
      assert_nil result["error"]
      assert_nil result["raw"]
    end
  end

  def test_debug_true_returns_raw_success_response
    client = AiLite.new(api_key: "token-abc")

    with_stubbed_http(success_response("Hello!")) do |_captured, _response|
      result = client.chat("Say hello", debug: true)

      assert_equal "Hello!", result["content"]
      assert_equal 200, result["status"]
      assert_nil result["error"]
      assert_equal(
        [
          {
            "type" => "message",
            "content" => [
              { "type" => "output_text", "text" => "Hello!" }
            ]
          }
        ],
        result["raw"]["output"]
      )
    end
  end

  def test_http_errors_return_standard_envelope
    client = AiLite.new(api_key: "token-abc")
    body = JSON.generate("error" => { "message" => "Invalid API key" })

    with_stubbed_http(FakeResponse.new("401", body)) do |_captured, _response|
      result = client.chat("Say hello")

      assert_nil result["content"]
      assert_equal 401, result["status"]
      assert_equal "Invalid API key", result["error"]
      assert_nil result["raw"]
    end
  end

  def test_debug_true_returns_raw_http_error_response
    client = AiLite.new(api_key: "token-abc")
    body = JSON.generate("error" => { "message" => "Invalid API key" })

    with_stubbed_http(FakeResponse.new("401", body)) do |_captured, _response|
      result = client.chat("Say hello", debug: true)

      assert_nil result["content"]
      assert_equal 401, result["status"]
      assert_equal "Invalid API key", result["error"]
      assert_equal({ "error" => { "message" => "Invalid API key" } }, result["raw"])
    end
  end

  def test_response_parse_errors_return_standard_envelope
    client = AiLite.new(api_key: "token-abc")

    with_stubbed_http(FakeResponse.new("200", "not-json")) do |_captured, _response|
      result = client.chat("Say hello")

      assert_nil result["content"]
      assert_equal 200, result["status"]
      assert_match(/unexpected token|unexpected character|parse/i, result["error"])
      assert_nil result["raw"]
    end
  end

  def test_debug_true_returns_raw_response_parse_error_body
    client = AiLite.new(api_key: "token-abc")

    with_stubbed_http(FakeResponse.new("200", "not-json")) do |_captured, _response|
      result = client.chat("Say hello", debug: true)

      assert_nil result["content"]
      assert_equal 200, result["status"]
      assert_match(/unexpected token|unexpected character|parse/i, result["error"])
      assert_equal "not-json", result["raw"]
    end
  end

  def test_network_errors_return_standard_envelope
    client = AiLite.new(api_key: "token-abc")
    original_start = Net::HTTP.method(:start)

    Net::HTTP.singleton_class.send(:define_method, :start) do |_host, _port, use_ssl:, &_block|
      raise IOError, "connection failed"
    end

    result = client.chat("Say hello")

    assert_nil result["content"]
    assert_equal "unknown", result["status"]
    assert_equal "connection failed", result["error"]
    assert_nil result["raw"]
  ensure
    Net::HTTP.singleton_class.send(:define_method, :start, original_start)
  end

  private

  def success_response(content)
    body = JSON.generate(
      "output" => [
        {
          "type" => "message",
          "content" => [
            { "type" => "output_text", "text" => content }
          ]
        }
      ]
    )
    FakeResponse.new("200", body)
  end

  def with_env(values)
    originals = {}

    values.each do |key, value|
      originals[key] = ENV.key?(key) ? ENV[key] : :missing
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end

    yield
  ensure
    originals.each do |key, value|
      value == :missing ? ENV.delete(key) : ENV[key] = value
    end
  end

  def with_stubbed_http(response)
    captured = {}
    original_start = Net::HTTP.method(:start)

    Net::HTTP.singleton_class.send(:define_method, :start) do |host, port, use_ssl:, &block|
      http = FakeHttp.new(response)
      captured[:host] = host
      captured[:port] = port
      captured[:use_ssl] = use_ssl
      captured[:http] = http
      block.call(http)
    end

    yield captured, response
  ensure
    Net::HTTP.singleton_class.send(:define_method, :start, original_start)
  end
end

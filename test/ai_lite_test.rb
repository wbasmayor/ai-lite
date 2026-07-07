# frozen_string_literal: true

require_relative "test_helper"
require "tempfile"

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
      assert_equal "omni-moderation-latest", client.moderation_model
      assert_equal "text-embedding-3-small", client.embedding_model
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
        config.moderation_model = "omni-moderation-test"
        config.embedding_model = "text-embedding-test"
        config.timeout = 15
        config.max_output_tokens = 750
      end

      client = AiLite.client

      assert_equal "configured-key", client.api_key
      assert_equal "gpt-config", client.model
      assert_equal "omni-moderation-test", client.moderation_model
      assert_equal "text-embedding-test", client.embedding_model
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
      config.moderation_model = "omni-moderation-config"
      config.embedding_model = "text-embedding-config"
      config.timeout = 15
      config.max_output_tokens = 750
    end

    client = AiLite.new(
      api_key: "explicit-key",
      model: "gpt-explicit",
      moderation_model: "omni-moderation-explicit",
      embedding_model: "text-embedding-explicit",
      timeout: 5,
      max_output_tokens: 300
    )

    assert_equal "explicit-key", client.api_key
    assert_equal "gpt-explicit", client.model
    assert_equal "omni-moderation-explicit", client.moderation_model
    assert_equal "text-embedding-explicit", client.embedding_model
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
      assert_equal "resp_test_123", result["response_id"]
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

  def test_chat_supports_previous_response_id_through_options
    client = AiLite.new(api_key: "token-abc")

    with_stubbed_http(success_response("Follow-up")) do |captured, _response|
      result = client.chat(
        "Explain why that is funny",
        options: {
          previous_response_id: "resp_previous_123"
        }
      )
      payload = JSON.parse(captured[:http].last_request.body)

      assert_equal "resp_previous_123", payload["previous_response_id"]
      assert_equal "Follow-up", result["content"]
      assert_equal "resp_test_123", result["response_id"]
    end
  end

  def test_extracts_text_from_nested_output_text_items
    client = AiLite.new(api_key: "token-abc")
    body = JSON.generate(
      "id" => "resp_nested_123",
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
      assert_equal "resp_nested_123", result["response_id"]
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

  def test_moderate_sends_post_to_moderations_with_default_payload
    client = AiLite.new(api_key: "token-abc")

    with_stubbed_http(moderation_response) do |captured, _response|
      result = client.moderate("Some user submitted text")
      request = captured[:http].last_request
      payload = JSON.parse(request.body)

      assert_equal false, result["content"]["flagged"]
      assert_equal "modr_test_123", result["response_id"]
      assert_equal 200, result["status"]
      assert_nil result["error"]
      assert_nil result["raw"]
      assert_equal "api.openai.com", captured[:host]
      assert_equal 443, captured[:port]
      assert_equal true, captured[:use_ssl]
      assert_instance_of Net::HTTP::Post, request
      assert_equal "/v1/moderations", request.path
      assert_equal "Bearer token-abc", request["Authorization"]
      assert_equal "application/json", request["Content-Type"]
      assert_equal "omni-moderation-latest", payload["model"]
      assert_equal "Some user submitted text", payload["input"]
    end
  end

  def test_moderate_uses_class_level_configured_client
    AiLite.configure do |config|
      config.api_key = "configured-key"
      config.moderation_model = "omni-moderation-config"
    end

    with_stubbed_http(moderation_response) do |captured, _response|
      AiLite.moderate("Use configured defaults")
      payload = JSON.parse(captured[:http].last_request.body)

      assert_equal "omni-moderation-config", payload["model"]
      assert_equal "Bearer configured-key", captured[:http].last_request["Authorization"]
    end
  end

  def test_moderate_accepts_text_and_image_url_keywords
    client = AiLite.new(api_key: "token-abc")

    with_stubbed_http(moderation_response) do |captured, _response|
      client.moderate(
        text: "Profile caption",
        image_url: "https://example.com/image.png"
      )
      payload = JSON.parse(captured[:http].last_request.body)

      assert_equal(
        [
          { "type" => "text", "text" => "Profile caption" },
          {
            "type" => "image_url",
            "image_url" => { "url" => "https://example.com/image.png" }
          }
        ],
        payload["input"]
      )
    end
  end

  def test_moderate_accepts_raw_openai_input_shape
    client = AiLite.new(api_key: "token-abc")
    input = [
      { type: "text", text: "Caption" },
      {
        type: "image_url",
        image_url: {
          url: "https://example.com/image.png"
        }
      }
    ]

    with_stubbed_http(moderation_response) do |captured, _response|
      client.moderate(input)
      payload = JSON.parse(captured[:http].last_request.body)

      assert_equal(
        [
          { "type" => "text", "text" => "Caption" },
          {
            "type" => "image_url",
            "image_url" => { "url" => "https://example.com/image.png" }
          }
        ],
        payload["input"]
      )
    end
  end

  def test_moderate_reads_image_path_as_data_url
    client = AiLite.new(api_key: "token-abc")

    Tempfile.create(["moderation", ".png"]) do |file|
      file.binmode
      file.write("fake image")
      file.flush

      with_stubbed_http(moderation_response) do |captured, _response|
        client.moderate(image_path: file.path)
        payload = JSON.parse(captured[:http].last_request.body)

        assert_equal(
          [
            {
              "type" => "image_url",
              "image_url" => { "url" => "data:image/png;base64,ZmFrZSBpbWFnZQ==" }
            }
          ],
          payload["input"]
        )
      end
    end
  end

  def test_moderate_returns_all_results_for_multiple_inputs
    client = AiLite.new(api_key: "token-abc")
    safe_result = moderation_result(flagged: false)
    flagged_result = moderation_result(flagged: true)

    with_stubbed_http(moderation_response(results: [safe_result, flagged_result])) do |_captured, _response|
      result = client.moderate(["Safe text", "Risky text"])

      assert_equal [safe_result, flagged_result], result["content"]
      assert_equal 200, result["status"]
      assert_nil result["error"]
    end
  end

  def test_moderate_local_input_errors_return_standard_envelope
    client = AiLite.new(api_key: "token-abc")

    result = client.moderate

    assert_nil result["content"]
    assert_nil result["response_id"]
    assert_equal "unknown", result["status"]
    assert_equal "Missing moderation input", result["error"]
    assert_nil result["raw"]
  end

  def test_embed_sends_post_to_embeddings_with_default_payload
    client = AiLite.new(api_key: "token-abc")

    with_stubbed_http(embedding_response([[0.12, -0.34, 0.56]])) do |captured, _response|
      result = client.embed("Text to vectorize")
      request = captured[:http].last_request
      payload = JSON.parse(request.body)

      assert_equal [0.12, -0.34, 0.56], result["content"]
      assert_nil result["response_id"]
      assert_equal 200, result["status"]
      assert_nil result["error"]
      assert_nil result["raw"]
      assert_equal "api.openai.com", captured[:host]
      assert_equal 443, captured[:port]
      assert_equal true, captured[:use_ssl]
      assert_instance_of Net::HTTP::Post, request
      assert_equal "/v1/embeddings", request.path
      assert_equal "Bearer token-abc", request["Authorization"]
      assert_equal "application/json", request["Content-Type"]
      assert_equal "text-embedding-3-small", payload["model"]
      assert_equal "Text to vectorize", payload["input"]
    end
  end

  def test_embed_returns_vector_list_for_multiple_inputs
    client = AiLite.new(api_key: "token-abc")
    embeddings = [
      [0.11, 0.22, 0.33],
      [0.44, 0.55, 0.66]
    ]

    with_stubbed_http(embedding_response(embeddings)) do |captured, _response|
      result = client.embed(["First text", "Second text"])
      payload = JSON.parse(captured[:http].last_request.body)

      assert_equal ["First text", "Second text"], payload["input"]
      assert_equal embeddings, result["content"]
      assert_equal 200, result["status"]
      assert_nil result["error"]
    end
  end

  def test_embed_includes_options_dimensions_encoding_format_and_model
    client = AiLite.new(api_key: "token-abc")

    with_stubbed_http(embedding_response([[0.12, -0.34]])) do |captured, _response|
      client.embed(
        "Short text",
        model: "text-embedding-3-large",
        dimensions: 2,
        encoding_format: "float",
        options: {
          user: "user-123"
        }
      )
      payload = JSON.parse(captured[:http].last_request.body)

      assert_equal "text-embedding-3-large", payload["model"]
      assert_equal "Short text", payload["input"]
      assert_equal 2, payload["dimensions"]
      assert_equal "float", payload["encoding_format"]
      assert_equal "user-123", payload["user"]
    end
  end

  def test_embed_uses_class_level_configured_client
    AiLite.configure do |config|
      config.api_key = "configured-key"
      config.embedding_model = "text-embedding-config"
    end

    with_stubbed_http(embedding_response([[0.12, -0.34, 0.56]])) do |captured, _response|
      AiLite.embed("Use configured defaults")
      payload = JSON.parse(captured[:http].last_request.body)

      assert_equal "text-embedding-config", payload["model"]
      assert_equal "Bearer configured-key", captured[:http].last_request["Authorization"]
    end
  end

  def test_embed_debug_true_returns_raw_usage
    client = AiLite.new(api_key: "token-abc")

    with_stubbed_http(embedding_response([[0.12, -0.34, 0.56]])) do |_captured, _response|
      result = client.embed("Text to vectorize", debug: true)

      assert_equal [0.12, -0.34, 0.56], result["content"]
      assert_equal({ "prompt_tokens" => 4, "total_tokens" => 4 }, result["raw"]["usage"])
    end
  end

  def test_http_errors_return_standard_envelope
    client = AiLite.new(api_key: "token-abc")
    body = JSON.generate("error" => { "message" => "Invalid API key" })

    with_stubbed_http(FakeResponse.new("401", body)) do |_captured, _response|
      result = client.chat("Say hello")

      assert_nil result["content"]
      assert_nil result["response_id"]
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
      assert_nil result["response_id"]
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
    assert_nil result["response_id"]
    assert_equal "unknown", result["status"]
    assert_equal "connection failed", result["error"]
    assert_nil result["raw"]
  ensure
    Net::HTTP.singleton_class.send(:define_method, :start, original_start)
  end

  private

  def success_response(content)
    body = JSON.generate(
      "id" => "resp_test_123",
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

  def moderation_response(results: [moderation_result])
    body = JSON.generate(
      "id" => "modr_test_123",
      "model" => "omni-moderation-latest",
      "results" => results
    )
    FakeResponse.new("200", body)
  end

  def moderation_result(flagged: false)
    {
      "flagged" => flagged,
      "categories" => {
        "hate" => false,
        "violence" => flagged
      },
      "category_scores" => {
        "hate" => 0.01,
        "violence" => flagged ? 0.95 : 0.02
      }
    }
  end

  def embedding_response(embeddings)
    body = JSON.generate(
      "object" => "list",
      "data" => embeddings.each_with_index.map do |embedding, index|
        {
          "object" => "embedding",
          "index" => index,
          "embedding" => embedding
        }
      end,
      "model" => "text-embedding-3-small",
      "usage" => {
        "prompt_tokens" => 4,
        "total_tokens" => 4
      }
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

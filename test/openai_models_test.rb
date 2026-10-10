require_relative "test_helper"

class OpenAIModelsTest < Minitest::Test
  Response = Struct.new(:code, :body)
  class Http
    attr_accessor :open_timeout, :read_timeout
    attr_reader :requests
    def initialize(response)
      @response, @requests = response, []
    end
    def request(request)
      @requests << request
      raise @response if @response.is_a?(Exception)
      @response
    end
  end

  def setup
    AiLite::OpenAI.reset_configuration!
    @client = AiLite::OpenAI.new(api_key: "test-key", model: "chat-test", timeout: 7)
  end

  def with_http(body, status = "200")
    response = body.is_a?(Exception) ? body : Response.new(status, body.is_a?(String) ? body : JSON.generate(body))
    http = Http.new(response)
    original = Net::HTTP.method(:start)
    Net::HTTP.define_singleton_method(:start) do |host, port, use_ssl:, &block|
      raise "Unexpected host" unless host == "api.openai.com" && port == 443 && use_ssl
      block.call(http)
    end
    yield http
  ensure
    Net::HTTP.define_singleton_method(:start, original)
  end

  def test_get_model_ids_and_debug_metadata
    body = { "data" => [{ "id" => "chat-test", "owned_by" => "openai" }, { "id" => "other" }] }
    with_http(body) do |http|
      result = @client.available_models(debug: true)
      assert_equal ["chat-test", "other"], result["content"]
      assert_equal body, result["raw"]
      assert_equal 200, result["status"]
      assert_nil result["error"]
      assert_nil result["response_id"]
      request = http.requests.fetch(0)
      assert_instance_of Net::HTTP::Get, request
      assert_equal "/v1/models", request.path
      assert_equal "Bearer test-key", request["Authorization"]
      assert_nil request.body
      assert_equal 7, http.open_timeout
      assert_equal 7, http.read_timeout
      assert_nil @client.available_models["raw"]
    end
  end

  def test_exact_predicate_and_empty_list
    with_http("data" => [{ "id" => "chat-test" }]) do
      assert_equal true, @client.model_available?("chat-test")
      assert_equal false, @client.model_available?("chat")
      assert_equal false, @client.model_available?("CHAT-TEST")
    end
    with_http("data" => []) do
      assert_equal [], @client.available_models["content"]
      assert_equal false, @client.model_available?("chat-test")
    end
    [nil, "", " ", :model].each do |input|
      assert_raises(ArgumentError) { @client.model_available?(input) }
    end
  end

  def test_local_configuration_never_uses_network_or_needs_key
    with_http(RuntimeError.new("Must not call network")) do |http|
      AiLite::OpenAI.configure { |config| config.model = "global-model" }
      assert_equal "global-model", AiLite::OpenAI.configured_models["chat"]
      snapshot = @client.configured_models
      assert_equal "chat-test", snapshot["chat"]
      assert_equal %w[chat moderation embedding image speech transcription], snapshot.keys
      snapshot["chat"].replace("changed")
      assert_equal "chat-test", @client.model
      assert_empty http.requests
    end
  end

  def test_check_uses_one_get_for_all_usages_including_duplicate_models
    client = AiLite::OpenAI.new(api_key: "test-key", model: "same", embedding_model: "same")
    with_http("data" => [{ "id" => "same" }]) do |http|
      result = client.check_configured_models(debug: true)
      assert_equal 1, http.requests.length
      assert_equal 6, result["content"].length
      assert_equal true, result.dig("content", "chat", "available")
      assert_equal true, result.dig("content", "embedding", "available")
      assert_equal false, result.dig("content", "image", "available")
      assert_equal "chat", result.dig("content", "chat", "usage")
      assert_nil result["error"]
      refute_nil result["raw"]
    end
  end

  def test_http_parse_shape_and_network_errors_are_not_missing_models
    cases = [
      [{ "error" => { "message" => "Unauthorized" } }, "401"],
      [{ "error" => { "message" => "Rate limited" } }, "429"],
      ["Bad gateway", "502"], ["not json", "200"], [[], "200"],
      [{ "data" => [{}] }, "200"], [{}, "200"],
      [IOError.new("Connection lost"), "200"]
    ]
    cases.each do |body, status|
      with_http(body, status) do |http|
        result = @client.available_models(debug: true)
        refute_nil result["error"]
        assert_nil result["content"]
        assert_nil @client.model_available?("chat-test")
        before = http.requests.length
        report = @client.check_configured_models
        assert_equal before + 1, http.requests.length
        refute_nil report["error"]
        report["content"].each_value do |entry|
          assert_nil entry["available"]
          assert_equal report["error"], entry["error"]
        end
      end
    end
  end

  def test_class_and_legacy_delegation
    AiLite::OpenAI.configure { |config| config.api_key = "test-key"; config.model = "chat-test" }
    [AiLite::OpenAI, AiLite].each do |provider|
      with_http("data" => [{ "id" => "chat-test" }]) do
        capture_io do
          assert_equal ["chat-test"], provider.available_models["content"]
          assert_equal true, provider.model_available?("chat-test")
          assert_equal "chat-test", provider.configured_models["chat"]
          assert_equal true, provider.check_configured_models.dig("content", "chat", "available")
        end
      end
    end
  end
end

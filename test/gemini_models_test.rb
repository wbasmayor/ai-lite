require_relative "test_helper"

class GeminiModelsTest < Minitest::Test
  Response = Struct.new(:code, :body)
  class Http
    attr_accessor :open_timeout, :read_timeout
    attr_reader :requests
    def initialize(pages)
      @pages, @requests = pages, []
    end
    def request(request)
      @requests << request
      page = @pages.shift
      raise page if page.is_a?(Exception)
      raise "Unexpected request" unless page
      Response.new(page[0], page[1].is_a?(String) ? page[1] : JSON.generate(page[1]))
    end
  end
  def setup
    AiLite::Gemini.reset_configuration!
    @client = AiLite::Gemini.new(api_key: "key", model: "models/test-model", timeout: 7)
  end
  def with_pages(*pages)
    http = Http.new(pages)
    original = Net::HTTP.method(:start)
    Net::HTTP.define_singleton_method(:start) do |host, port, use_ssl:, &block|
      raise "Wrong host" unless host == "generativelanguage.googleapis.com" && port == 443 && use_ssl
      block.call(http)
    end
    yield http
  ensure
    Net::HTTP.define_singleton_method(:start, original)
  end
  def page(names, token = nil)
    result = { "models" => names.map { |id| { "name" => "models/#{id}", "supportedGenerationMethods" => ["generateContent"] } } }
    result["nextPageToken"] = token if token
    ["200", result]
  end
  def test_pagination_normalization_metadata_and_http
    with_pages(page(["first"], "a+b/&="), page(["test-model", "first"])) do |http|
      result = @client.available_models(debug: true)
      assert_equal ["first", "test-model"], result["content"]
      assert_nil result["error"]
      assert_equal 2, result.dig("raw", "pages").size
      assert_equal ["generateContent"], result.dig("raw", "pages", 0, "models", 0, "supportedGenerationMethods")
      assert_equal 2, http.requests.size
      assert_equal "/v1beta/models", http.requests[0].path
      request = http.requests[1]
      assert_instance_of Net::HTTP::Get, request
      assert_equal [["pageToken", "a+b/&="]], URI.decode_www_form(URI(request.path).query)
      assert_equal "key", request["x-goog-api-key"]
      assert_nil request["Authorization"]
      assert_nil request.body
      assert_equal 7, http.read_timeout
      assert_equal 7, http.open_timeout
    end
  end
  def test_predicate_matches_exact_ids_with_optional_resource_prefix
    { "test-model" => true, "models/test-model" => true, "test" => false, "TEST-MODEL" => false }.each do |name, expected|
      with_pages(page(["test-model"])) { assert_equal expected, @client.model_available?(name) }
    end
    [nil, "", " ", :test].each { |name| assert_raises(ArgumentError) { @client.model_available?(name) } }
    with_pages(["200", {}]) { assert_equal [], @client.available_models["content"] }
    with_pages(page([])) { assert_equal false, @client.model_available?("missing") }
  end
  def test_local_configuration_and_single_paginated_check
    with_pages do |http|
      assert_equal({ "chat" => AiLite::Gemini::DEFAULT_MODEL }, AiLite::Gemini.configured_models)
      snapshot = @client.configured_models
      snapshot["chat"].replace("changed")
      assert_equal "models/test-model", @client.model
      assert_empty http.requests
    end
    with_pages(page(["other"], "next"), page(["test-model"])) do |http|
      result = @client.check_configured_models
      assert_equal 2, http.requests.size
      assert_equal({ "chat" => { "model" => "models/test-model", "usage" => "chat", "available" => true, "error" => nil } }, result["content"])
      assert_nil result["raw"]
    end
  end
  def test_failed_later_pages_do_not_return_partial_success
    [["200", { "error" => { "message" => "Unexpected error" } }], ["403", { "error" => { "message" => "Denied" } }], ["200", "invalid"],
     ["200", { "models" => [{}] }], ["200", []], ["200", { "nextPageToken" => 3 }],
     IOError.new("Disconnected")].each do |failure|
      with_pages(page(["test-model"], "next"), failure) do
        result = @client.available_models(debug: true)
        assert_nil result["content"]
        refute_nil result["error"]
        refute_empty result.dig("raw", "pages")
      end
      with_pages(failure) { assert_nil @client.model_available?("test-model") }
      with_pages(failure) do
        result = @client.check_configured_models
        assert_nil result.dig("content", "chat", "available")
        refute_nil result["error"]
        assert_equal result["error"], result.dig("content", "chat", "error")
      end
    end
    with_pages(page([], "same"), page([], "same")) do |http|
      assert_match(/Repeated/, @client.available_models["error"])
      assert_equal 2, http.requests.size
    end
  end
  def test_class_delegation_and_provider_isolation
    AiLite::Gemini.configure { |c| c.api_key = "key"; c.model = "test-model" }
    original = AiLite::OpenAI.configured_models
    with_pages(page(["test-model"])) { assert_equal ["test-model"], AiLite::Gemini.available_models["content"] }
    with_pages(page(["test-model"])) { assert_equal true, AiLite::Gemini.model_available?("test-model") }
    with_pages(page([])) { assert_equal false, AiLite::Gemini.check_configured_models.dig("content", "chat", "available") }
    assert_equal original, AiLite::OpenAI.configured_models
  end
end

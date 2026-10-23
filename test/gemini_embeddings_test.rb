require_relative "test_helper"

class GeminiEmbeddingsTest < Minitest::Test
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

  def with_http(raw = {}, status = "200")
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

  def test_single_embedding_transport_and_envelope
    with_http({ "embedding" => { "values" => [0.1, -0.2] } }) do |http|
      result = @client.embed("Hello")
      assert_equal({ "content" => [0.1, -0.2], "status" => 200, "error" => nil,
                     "raw" => nil, "response_id" => nil }, result)
      assert_equal "/v1beta/models/gemini-embedding-001:embedContent", http.request_received.path
      assert_equal "gemini-key", http.request_received["x-goog-api-key"]
      assert_equal "application/json", http.request_received["Content-Type"]
      assert_equal 9, http.read_timeout
      assert_equal 9, http.open_timeout
      assert_equal({ "model" => "models/gemini-embedding-001", "content" => { "parts" => [{ "text" => "Hello" }] } }, JSON.parse(http.request_received.body))
    end
  end

  def test_batch_order_options_dimensions_and_debug
    options = { taskType: "RETRIEVAL_DOCUMENT", title: "Guide", "outputDimensionality" => 8 }
    original = Marshal.dump(options)
    raw = { "embeddings" => [{ "values" => [1, 2] }, { "values" => [3, 4] }], "usageMetadata" => { "totalTokenCount" => 4 } }
    with_http(raw) do |http|
      result = @client.embed(["First", "Second"], model: "models/custom", dimensions: 2, encoding_format: "float", options: options, debug: true)
      assert_equal [[1, 2], [3, 4]], result["content"]
      assert_equal raw, result["raw"]
      assert_equal "/v1beta/models/custom:batchEmbedContents", http.request_received.path
      requests = JSON.parse(http.request_received.body)["requests"]
      assert_equal ["First", "Second"], requests.map { |r| r.dig("content", "parts", 0, "text") }
      requests.each do |request|
        assert_equal "models/custom", request["model"]
        assert_equal 2, request["outputDimensionality"]
        assert_equal "RETRIEVAL_DOCUMENT", request["taskType"]
        assert_equal "Guide", request["title"]
        refute request.key?("encoding_format")
      end
      assert_equal original, Marshal.dump(options)
    end
    with_http({ "embeddings" => [{ "values" => [1] }] }) do
      assert_equal [[1]], @client.embed(["Only one"])["content"]
    end
  end

  def test_configuration_delegation_and_model_checks
    AiLite::Gemini.configure { |c| c.api_key = "key"; c.embedding_model = "configured" }
    assert_equal "configured", AiLite::Gemini.client.embedding_model
    assert_equal "gemini-embedding-001", @client.embedding_model
    assert_equal "override", AiLite::Gemini.new(embedding_model: "override").embedding_model
    snapshot = AiLite::Gemini.configured_models
    snapshot["embedding"].replace("changed")
    assert_equal "configured", AiLite::Gemini.configuration.embedding_model
    with_http({ "embedding" => { "values" => [1] } }) do |http|
      assert_equal [1], AiLite::Gemini.embed("Hello")["content"]
      assert_equal "/v1beta/models/configured:embedContent", http.request_received.path
    end
    with_http({ "models" => [{ "name" => "models/configured" }] }) do
      assert_equal true, AiLite::Gemini.check_configured_models.dig("content", "embedding", "available")
    end
  end

  def test_invalid_inputs_do_not_make_requests
    with_http do |http|
      [nil, [], "", ["ok", nil], { text: "hi" }].each { |input| refute_nil @client.embed(input)["error"] }
      [{ dimensions: 0 }, { dimensions: "2" }, { encoding_format: "base64" }, { model: "bad/path" }].each do |kwargs|
        refute_nil @client.embed("Hello", **kwargs)["error"]
      end
      assert_nil http.request_received
    end
  end

  def test_api_transport_and_malformed_response_errors
    with_http({ "error" => { "message" => "Denied" } }, "403") do
      result = @client.embed("Hello", debug: true)
      assert_equal 403, result["status"]
      assert_equal "Denied", result["error"]
      refute_nil result["raw"]
    end
    ["invalid json", [], {}, { "embedding" => { "values" => ["bad"] } }, IOError.new("Disconnected")].each do |raw|
      with_http(raw) do
        result = @client.embed("Hello")
        refute_nil result["error"]
        assert_nil result["content"]
        assert_nil result["raw"]
      end
    end
    with_http({ "embeddings" => [{ "values" => [1] }] }) do
      assert_match(/count/, @client.embed(["one", "two"])["error"])
    end
  end
end

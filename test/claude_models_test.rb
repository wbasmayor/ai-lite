require_relative "test_helper"

class ClaudeModelsTest < Minitest::Test
  Response = Struct.new(:code, :body)
  class Http
    attr_accessor :open_timeout, :read_timeout
    attr_reader :requests
    def initialize(responses)
      @responses, @requests = responses, []
    end
    def request(request)
      @requests << request
      response = @responses.shift
      raise "Unexpected request" unless response
      raise response if response.is_a?(Exception)
      response
    end
  end

  def setup
    AiLite::Claude.reset_configuration!
    @client = AiLite::Claude.new(api_key: "key", model: "chosen", timeout: 7, workspace_id: "workspace")
  end

  def teardown
    AiLite::Claude.reset_configuration!
  end

  def page(ids, more = false, cursor = ids.last)
    { "data" => ids.map { |id| { "id" => id, "display_name" => "Model" } }, "has_more" => more, "last_id" => cursor }
  end

  def with_http(pages, code = "200")
    http = Http.new(pages.map { |p| p.is_a?(Exception) ? p : Response.new(code, p.is_a?(String) ? p : JSON.generate(p)) })
    original = Net::HTTP.method(:start)
    Net::HTTP.define_singleton_method(:start) do |host, port, use_ssl:, &block|
      raise "Wrong endpoint" unless host == "api.anthropic.com" && port == 443 && use_ssl
      block.call(http)
    end
    yield http
  ensure
    Net::HTTP.define_singleton_method(:start, original)
  end

  def test_paginated_transport_and_debug
    pages = [page(["other"], true, "cursor &?"), page(["chosen", "other"])]
    with_http(pages) do |http|
      result = @client.available_models(debug: true)
      assert_equal ["other", "chosen"], result["content"]
      assert_nil result["error"]
      assert_nil result["response_id"]
      assert_equal 200, result["status"]
      assert_equal({ "pages" => pages }, result["raw"])
      assert_equal 2, http.requests.length
      request = http.requests.first
      assert_instance_of Net::HTTP::Get, request
      assert_equal "/v1/models", request.path
      assert_nil request.body
      assert_equal "Bearer key", request["Authorization"]
      assert_equal @client.api_version, request["anthropic-version"]
      assert_equal "workspace", request["anthropic-workspace-id"]
      assert_nil request["x-goog-api-key"]
      assert_equal [["after_id", "cursor &?"]], URI.decode_www_form(http.requests.last.uri.query)
      assert_equal 7, http.open_timeout
      assert_equal 7, http.read_timeout
    end
  end

  def test_exact_membership_empty_list_and_class_delegation
    AiLite::Claude.configure { |config| config.api_key = "key"; config.model = "chosen" }
    with_http([page(["chosen"])] * 5 + [page([])]) do
      assert_equal ["chosen"], AiLite::Claude.available_models["content"]
      assert_equal true, AiLite::Claude.model_available?("chosen")
      assert_equal false, @client.model_available?("CHOSEN")
      assert_equal false, @client.model_available?("cho")
      assert_equal true, AiLite::Claude.check_configured_models.dig("content", "chat", "available")
      assert_equal [], @client.available_models["content"]
    end
    [nil, "", " ", :chosen].each do |id|
      assert_raises(ArgumentError) { @client.model_available?(id) }
    end
  end

  def test_configuration_snapshot_without_key_or_network
    old_key = ENV.delete("ANTHROPIC_API_KEY")
    with_http([]) do |http|
      AiLite::Claude.configure { |config| config.model = "configured" }
      snapshot = AiLite::Claude.configured_models
      assert_equal({ "chat" => "configured" }, snapshot)
      snapshot["chat"].replace("changed")
      assert_equal "configured", AiLite::Claude.configuration.model
      snapshot = @client.configured_models
      assert_equal({ "chat" => "chosen" }, snapshot)
      snapshot["chat"].replace("changed")
      assert_equal "chosen", @client.model
      assert_empty http.requests
    end
  ensure
    ENV["ANTHROPIC_API_KEY"] = old_key
  end

  def test_check_fetches_each_page_once_and_reports_missing
    with_http([page(["other"], true), page(["chosen"])]) do |http|
      result = @client.check_configured_models
      assert_equal({ "chat" => { "model" => "chosen", "usage" => "chat", "available" => true, "error" => nil } }, result["content"])
      assert_nil result["raw"]
      assert_equal 2, http.requests.length
    end
    with_http([page([])]) do
      assert_equal false, @client.check_configured_models.dig("content", "chat", "available")
    end
  end

  def test_errors_are_not_reported_as_missing_models
    cases = [ [{ "error" => { "message" => "Denied" } }, "401"],
      [{ "error" => "Failed" }, "200"], ["not json", "200"], [[], "200"],
      [{}, "200"], [page([nil]), "200"], [page([" "]), "200"],
      [page([]).merge("has_more" => "false"), "200"],
      [IOError.new("Disconnected"), "200"] ]
    cases.each do |raw, code|
      with_http([raw, raw, raw], code) do
        result = @client.available_models(debug: true)
        refute_nil result["error"]
        assert_nil result["content"]
        assert_equal(raw.is_a?(Exception) ? "unknown" : code.to_i, result["status"])
        assert_equal raw, result["raw"]["pages"].first unless raw.is_a?(Exception)
        assert_nil @client.model_available?("chosen")
        report = @client.check_configured_models
        assert_nil report.dig("content", "chat", "available")
        assert_equal report["error"], report.dig("content", "chat", "error")
        refute_nil report["error"]
      end
    end
  end

  def test_invalid_pagination_and_later_page_failure
    cases = [[page(["chosen"], true, nil)], [page([], true, "cursor")],
      [page(["chosen"], true), page(["chosen"], true)],
      [page(["chosen"], true), "bad json"],
      [page(["chosen"], true), IOError.new("Disconnected")]]
    cases.each do |pages|
      with_http(pages) do |http|
        result = @client.available_models(debug: true)
        assert_nil result["content"]
        refute_nil result["error"]
        assert_equal pages.length, http.requests.length
      end
    end
  end
end

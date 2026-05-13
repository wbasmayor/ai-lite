require "json"
require "net/http"
require "uri"
require_relative "ai_lite/version"

class AiLite
  API_BASE_URL = "https://api.openai.com/v1".freeze
  DEFAULT_MODEL = "gpt-5.5".freeze
  DEFAULT_TIMEOUT = 120
  DEFAULT_MAX_OUTPUT_TOKENS = 2000

  class Configuration
    attr_accessor :api_key, :model, :timeout, :max_output_tokens

    def initialize
      @api_key = nil
      @model = DEFAULT_MODEL
      @timeout = DEFAULT_TIMEOUT
      @max_output_tokens = DEFAULT_MAX_OUTPUT_TOKENS
    end
  end

  class << self
    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield(configuration)
      reset_client!
      configuration
    end

    def reset_configuration!
      @configuration = Configuration.new
      reset_client!
      configuration
    end

    def client
      @client ||= new
    end

    def chat(message, **kwargs)
      client.chat(message, **kwargs)
    end

    def reset_client!
      @client = nil
    end
  end

  attr_reader :api_key, :model, :timeout, :max_output_tokens, :headers

  def initialize(api_key: nil, model: nil, timeout: nil, max_output_tokens: nil)
    @api_key = api_key || self.class.configuration.api_key || ENV["OPENAI_API_KEY"] || ENV["OPEN_AI_TOKEN"]
    raise ArgumentError, "Missing OpenAI API key" if @api_key.to_s.strip.empty?

    @model = model || self.class.configuration.model
    @timeout = timeout || self.class.configuration.timeout
    @max_output_tokens = max_output_tokens || self.class.configuration.max_output_tokens
    @headers = {
      "Authorization" => "Bearer #{@api_key}",
      "Content-Type" => "application/json"
    }
  end

  def chat(message, model: nil, instructions: nil, max_output_tokens: nil, debug: false, options: {})
    payload = options.merge(
      model: model || self.model,
      input: message,
      max_output_tokens: max_output_tokens || self.max_output_tokens
    )
    payload[:instructions] = instructions if instructions

    extract_content(post(payload), debug: debug)
  rescue => e
    prettify_data(status: "unknown", error: e.message, raw: nil, debug: debug)
  end

  private

  def post(payload)
    uri = URI.parse(response_endpoint)
    request = Net::HTTP::Post.new(uri)

    headers.each do |key, value|
      request[key] = value
    end

    request.body = JSON.generate(payload)

    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
      http.open_timeout = timeout if http.respond_to?(:open_timeout=)
      http.read_timeout = timeout if http.respond_to?(:read_timeout=)
      http.request(request)
    end
  end

  def response_endpoint
    "#{API_BASE_URL}/responses"
  end

  def extract_content(response, debug: false)
    status = response.code.to_i
    parsed_response = JSON.parse(response.body)

    unless success_status?(status)
      return prettify_data(status: status, error: error_message(parsed_response), raw: parsed_response, debug: debug)
    end

    raw_content = extract_output_text(parsed_response)
    content = parse_content(raw_content)
    prettify_data(status: status, content: content, raw: parsed_response, debug: debug)
  rescue JSON::ParserError => e
    prettify_data(status: response_status(response), error: e.message, raw: response&.body, debug: debug)
  rescue => e
    prettify_data(status: response_status(response), error: e.message, raw: nil, debug: debug)
  end

  def extract_output_text(raw)
    Array(raw["output"]).flat_map do |item|
      next [] unless item.is_a?(Hash) && item["type"] == "message"

      Array(item["content"]).map do |content|
        next unless content.is_a?(Hash) && content["type"] == "output_text"

        content["text"]
      end.compact
    end.join.strip
  end

  def parse_content(raw_text)
    return nil if raw_text.nil? || raw_text.empty?

    JSON.parse(raw_text)
  rescue JSON::ParserError
    raw_text
  end

  def success_status?(status)
    status >= 200 && status < 300
  end

  def error_message(raw)
    if raw.is_a?(Hash)
      raw.dig("error", "message") || raw["error"] || raw["message"] || raw.to_s
    else
      raw.to_s
    end
  end

  def response_status(response)
    response&.code&.to_i || "unknown"
  end

  def prettify_data(status:, content: nil, error: nil, raw:, debug: false)
    {
      "content" => content,
      "status" => status,
      "error" => error,
      "raw" => debug ? raw : nil
    }
  end
end

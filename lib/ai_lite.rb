require "base64"
require "json"
require "net/http"
require "uri"
require_relative "ai_lite/version"

class AiLite
  API_BASE_URL = "https://api.openai.com/v1".freeze
  DEFAULT_MODEL = "gpt-5.5".freeze
  DEFAULT_MODERATION_MODEL = "omni-moderation-latest".freeze
  DEFAULT_EMBEDDING_MODEL = "text-embedding-3-small".freeze
  DEFAULT_TIMEOUT = 120
  DEFAULT_MAX_OUTPUT_TOKENS = 2000
  IMAGE_MIME_TYPES = {
    ".gif" => "image/gif",
    ".jpeg" => "image/jpeg",
    ".jpg" => "image/jpeg",
    ".png" => "image/png",
    ".webp" => "image/webp"
  }.freeze

  class Configuration
    attr_accessor :api_key, :model, :moderation_model, :embedding_model, :timeout, :max_output_tokens

    def initialize
      @api_key = nil
      @model = DEFAULT_MODEL
      @moderation_model = DEFAULT_MODERATION_MODEL
      @embedding_model = DEFAULT_EMBEDDING_MODEL
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

    def moderate(input = nil, **kwargs)
      client.moderate(input, **kwargs)
    end

    def embed(input, **kwargs)
      client.embed(input, **kwargs)
    end

    def reset_client!
      @client = nil
    end
  end

  attr_reader :api_key, :model, :moderation_model, :embedding_model, :timeout, :max_output_tokens, :headers

  def initialize(api_key: nil, model: nil, moderation_model: nil, embedding_model: nil, timeout: nil, max_output_tokens: nil)
    @api_key = api_key || self.class.configuration.api_key || ENV["OPENAI_API_KEY"] || ENV["OPEN_AI_TOKEN"]
    raise ArgumentError, "Missing OpenAI API key" if @api_key.to_s.strip.empty?

    @model = model || self.class.configuration.model
    @moderation_model = moderation_model || self.class.configuration.moderation_model
    @embedding_model = embedding_model || self.class.configuration.embedding_model
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

  def moderate(input = nil, model: nil, text: nil, image_url: nil, image_path: nil, debug: false, options: {})
    payload = options.merge(
      model: model || moderation_model,
      input: moderation_input(input, text: text, image_url: image_url, image_path: image_path)
    )

    extract_moderation(post(payload, endpoint: moderation_endpoint), debug: debug)
  rescue => e
    prettify_data(status: "unknown", error: e.message, raw: nil, debug: debug)
  end

  def embed(input, model: nil, dimensions: nil, encoding_format: nil, debug: false, options: {})
    payload = options.merge(
      model: model || embedding_model,
      input: input
    )
    payload[:dimensions] = dimensions if dimensions
    payload[:encoding_format] = encoding_format if encoding_format

    extract_embedding(post(payload, endpoint: embedding_endpoint), multiple: input.is_a?(Array), debug: debug)
  rescue => e
    prettify_data(status: "unknown", error: e.message, raw: nil, debug: debug)
  end

  private

  def post(payload, endpoint: response_endpoint)
    uri = URI.parse(endpoint)
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

  def moderation_endpoint
    "#{API_BASE_URL}/moderations"
  end

  def embedding_endpoint
    "#{API_BASE_URL}/embeddings"
  end

  def extract_content(response, debug: false)
    status = response.code.to_i
    parsed_response = JSON.parse(response.body)

    unless success_status?(status)
      return prettify_data(
        status: status,
        error: error_message(parsed_response),
        response_id: parsed_response["id"],
        raw: parsed_response,
        debug: debug
      )
    end

    raw_content = extract_output_text(parsed_response)
    content = parse_content(raw_content)
    prettify_data(
      status: status,
      content: content,
      response_id: parsed_response["id"],
      raw: parsed_response,
      debug: debug
    )
  rescue JSON::ParserError => e
    prettify_data(status: response_status(response), error: e.message, raw: response&.body, debug: debug)
  rescue => e
    prettify_data(status: response_status(response), error: e.message, raw: nil, debug: debug)
  end

  def extract_moderation(response, debug: false)
    status = response.code.to_i
    parsed_response = JSON.parse(response.body)

    unless success_status?(status)
      return prettify_data(
        status: status,
        error: error_message(parsed_response),
        response_id: parsed_response["id"],
        raw: parsed_response,
        debug: debug
      )
    end

    prettify_data(
      status: status,
      content: moderation_content(parsed_response),
      response_id: parsed_response["id"],
      raw: parsed_response,
      debug: debug
    )
  rescue JSON::ParserError => e
    prettify_data(status: response_status(response), error: e.message, raw: response&.body, debug: debug)
  rescue => e
    prettify_data(status: response_status(response), error: e.message, raw: nil, debug: debug)
  end

  def extract_embedding(response, multiple:, debug: false)
    status = response.code.to_i
    parsed_response = JSON.parse(response.body)

    unless success_status?(status)
      return prettify_data(
        status: status,
        error: error_message(parsed_response),
        response_id: parsed_response["id"],
        raw: parsed_response,
        debug: debug
      )
    end

    prettify_data(
      status: status,
      content: embedding_content(parsed_response, multiple: multiple),
      response_id: parsed_response["id"],
      raw: parsed_response,
      debug: debug
    )
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

  def moderation_input(input, text:, image_url:, image_path:)
    unless text || image_url || image_path
      raise ArgumentError, "Missing moderation input" if input.nil?

      return input
    end

    items = []
    items.concat(Array(input).map { |value| moderation_input_item(value) }) unless input.nil?
    items << { type: "text", text: text } if text
    items << { type: "image_url", image_url: { url: image_url } } if image_url
    items << { type: "image_url", image_url: { url: image_data_url(image_path) } } if image_path
    raise ArgumentError, "Missing moderation input" if items.empty?

    items
  end

  def moderation_input_item(value)
    case value
    when String
      { type: "text", text: value }
    when Hash
      value
    else
      raise ArgumentError, "Unsupported moderation input item: #{value.class}"
    end
  end

  def image_data_url(path)
    mime_type = image_mime_type(path)
    "data:#{mime_type};base64,#{Base64.strict_encode64(File.binread(path))}"
  end

  def image_mime_type(path)
    IMAGE_MIME_TYPES.fetch(File.extname(path).downcase) do
      raise ArgumentError, "Unsupported image type for moderation: #{File.extname(path)}"
    end
  end

  def moderation_content(raw)
    results = raw["results"]
    return nil unless results.is_a?(Array)

    results.length == 1 ? results.first : results
  end

  def embedding_content(raw, multiple:)
    embeddings = Array(raw["data"]).map do |item|
      item["embedding"] if item.is_a?(Hash)
    end.compact

    multiple ? embeddings : embeddings.first
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

  def prettify_data(status:, content: nil, error: nil, response_id: nil, raw:, debug: false)
    {
      "content" => content,
      "response_id" => response_id,
      "status" => status,
      "error" => error,
      "raw" => debug ? raw : nil
    }
  end
end

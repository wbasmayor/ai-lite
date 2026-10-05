require "base64"
require "json"
require "net/http"
require "securerandom"
require "uri"
require_relative "ai_lite/version"

class AiLite
  API_BASE_URL = "https://api.openai.com/v1".freeze
  DEFAULT_MODEL = "gpt-5.5".freeze
  DEFAULT_MODERATION_MODEL = "omni-moderation-latest".freeze
  DEFAULT_EMBEDDING_MODEL = "text-embedding-3-small".freeze
  DEFAULT_IMAGE_MODEL = "gpt-image-2".freeze
  DEFAULT_SPEECH_MODEL = "gpt-4o-mini-tts".freeze
  DEFAULT_SPEECH_VOICE = "alloy".freeze
  DEFAULT_SPEECH_FORMAT = "mp3".freeze
  DEFAULT_TRANSCRIPTION_MODEL = "gpt-transcribe".freeze
  DEFAULT_TIMEOUT = 120
  DEFAULT_MAX_OUTPUT_TOKENS = 2000
  IMAGE_MIME_TYPES = {
    ".gif" => "image/gif",
    ".jpeg" => "image/jpeg",
    ".jpg" => "image/jpeg",
    ".png" => "image/png",
    ".webp" => "image/webp"
  }.freeze
  AUDIO_MIME_TYPES = {
    ".flac" => "audio/flac",
    ".m4a" => "audio/mp4",
    ".mp3" => "audio/mpeg",
    ".mp4" => "audio/mp4",
    ".mpeg" => "audio/mpeg",
    ".mpga" => "audio/mpeg",
    ".ogg" => "audio/ogg",
    ".wav" => "audio/wav",
    ".webm" => "audio/webm"
  }.freeze

  class Configuration
    attr_accessor :api_key, :model, :moderation_model, :embedding_model, :image_model, :speech_model, :speech_voice, :transcription_model, :timeout, :max_output_tokens

    def initialize
      @api_key = nil
      @model = DEFAULT_MODEL
      @moderation_model = DEFAULT_MODERATION_MODEL
      @embedding_model = DEFAULT_EMBEDDING_MODEL
      @image_model = DEFAULT_IMAGE_MODEL
      @speech_model = DEFAULT_SPEECH_MODEL
      @speech_voice = DEFAULT_SPEECH_VOICE
      @transcription_model = DEFAULT_TRANSCRIPTION_MODEL
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

    def image(prompt, **kwargs)
      client.image(prompt, **kwargs)
    end

    def speak(text, **kwargs)
      client.speak(text, **kwargs)
    end

    def transcribe(file_path, **kwargs)
      client.transcribe(file_path, **kwargs)
    end

    def reset_client!
      @client = nil
    end
  end

  attr_reader :api_key, :model, :moderation_model, :embedding_model, :image_model, :speech_model, :speech_voice, :transcription_model, :timeout, :max_output_tokens, :headers

  def initialize(api_key: nil, model: nil, moderation_model: nil, embedding_model: nil, image_model: nil, speech_model: nil, speech_voice: nil, transcription_model: nil, timeout: nil, max_output_tokens: nil)
    @api_key = api_key || self.class.configuration.api_key || ENV["OPENAI_API_KEY"] || ENV["OPEN_AI_TOKEN"]
    raise ArgumentError, "Missing OpenAI API key" if @api_key.to_s.strip.empty?

    @model = model || self.class.configuration.model
    @moderation_model = moderation_model || self.class.configuration.moderation_model
    @embedding_model = embedding_model || self.class.configuration.embedding_model
    @image_model = image_model || self.class.configuration.image_model
    @speech_model = speech_model || self.class.configuration.speech_model
    @speech_voice = speech_voice || self.class.configuration.speech_voice
    @transcription_model = transcription_model || self.class.configuration.transcription_model
    @timeout = timeout || self.class.configuration.timeout
    @max_output_tokens = max_output_tokens || self.class.configuration.max_output_tokens
    @headers = {
      "Authorization" => "Bearer #{@api_key}",
      "Content-Type" => "application/json"
    }
  end

  def chat(message, model: nil, instructions: nil, previous_response_id: nil, max_output_tokens: nil, debug: false, options: {})
    payload = options.merge(
      model: model || self.model,
      input: message,
      max_output_tokens: max_output_tokens || self.max_output_tokens
    )
    payload[:instructions] = instructions if instructions
    payload[:previous_response_id] = previous_response_id if previous_response_id

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

  def image(prompt, model: nil, size: nil, quality: nil, background: nil, output_format: nil, output_path: nil, debug: false, options: {})
    payload = options.merge(
      model: model || image_model,
      prompt: prompt
    )
    payload[:size] = size if size
    payload[:quality] = quality if quality
    payload[:background] = background if background
    payload[:output_format] = output_format if output_format

    extract_image(post(payload, endpoint: image_endpoint), output_path: output_path, debug: debug)
  rescue => e
    prettify_data(status: "unknown", error: e.message, raw: nil, debug: debug)
  end

  def speak(text, model: nil, voice: nil, response_format: nil, speed: nil, instructions: nil, output_path: nil, base64: false, debug: false, options: {})
    payload = options.merge(
      model: model || speech_model,
      input: text,
      voice: voice || speech_voice
    )
    payload[:response_format] = response_format if response_format
    payload[:speed] = speed if speed
    payload[:instructions] = instructions if instructions

    extract_speech(
      post(payload, endpoint: speech_endpoint),
      output_path: output_path,
      base64: base64,
      response_format: payload[:response_format] || payload["response_format"] || DEFAULT_SPEECH_FORMAT,
      debug: debug
    )
  rescue => e
    prettify_data(status: "unknown", error: e.message, raw: nil, debug: debug)
  end

  def transcribe(file_path, model: nil, language: nil, prompt: nil, response_format: nil, temperature: nil, timestamp_granularities: nil, debug: false, options: {})
    fields = options.merge(
      model: model || transcription_model
    )
    fields[:language] = language if language
    fields[:prompt] = prompt if prompt
    fields[:response_format] = response_format if response_format
    fields[:temperature] = temperature unless temperature.nil?
    fields[:timestamp_granularities] = timestamp_granularities if timestamp_granularities

    extract_transcription(
      post_multipart(fields, file_field: audio_file_field(file_path), endpoint: transcription_endpoint),
      debug: debug
    )
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

  def post_multipart(fields, file_field:, endpoint:)
    uri = URI.parse(endpoint)
    boundary = "----AiLiteBoundary#{SecureRandom.hex(16)}"
    request = Net::HTTP::Post.new(uri)
    request["Authorization"] = headers["Authorization"]
    request["Content-Type"] = "multipart/form-data; boundary=#{boundary}"
    request.body = multipart_body(fields, file_field: file_field, boundary: boundary)

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

  def image_endpoint
    "#{API_BASE_URL}/images/generations"
  end

  def speech_endpoint
    "#{API_BASE_URL}/audio/speech"
  end

  def transcription_endpoint
    "#{API_BASE_URL}/audio/transcriptions"
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

  def extract_image(response, output_path:, debug: false)
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

    content = image_content(parsed_response)
    write_image_output(output_path, content) if output_path

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

  def extract_speech(response, output_path:, base64:, response_format:, debug: false)
    status = response.code.to_i

    unless success_status?(status)
      parsed_response = parse_error_response(response.body)

      return prettify_data(
        status: status,
        error: error_message(parsed_response),
        response_id: parsed_response.is_a?(Hash) ? parsed_response["id"] : nil,
        raw: parsed_response,
        debug: debug
      )
    end

    audio = response.body
    File.binwrite(output_path, audio) if output_path

    prettify_data(
      status: status,
      content: speech_content(audio, output_path: output_path, base64: base64, response_format: response_format),
      response_id: nil,
      raw: audio,
      debug: debug
    )
  rescue => e
    prettify_data(status: response_status(response), error: e.message, raw: nil, debug: debug)
  end

  def extract_transcription(response, debug: false)
    status = response.code.to_i
    parsed_response = parse_error_response(response.body)

    unless success_status?(status)
      return prettify_data(
        status: status,
        error: error_message(parsed_response),
        response_id: parsed_response.is_a?(Hash) ? parsed_response["id"] : nil,
        raw: parsed_response,
        debug: debug
      )
    end

    prettify_data(
      status: status,
      content: transcription_content(parsed_response),
      response_id: parsed_response.is_a?(Hash) ? parsed_response["id"] : nil,
      raw: parsed_response,
      debug: debug
    )
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

  def audio_file_field(path)
    raise ArgumentError, "Audio file not found: #{path}" unless File.file?(path)

    {
      name: "file",
      path: path,
      filename: File.basename(path),
      content_type: audio_mime_type(path)
    }
  end

  def audio_mime_type(path)
    extension = File.extname(path).downcase
    AUDIO_MIME_TYPES.fetch(extension) do
      raise ArgumentError, "Unsupported audio type for transcription: #{extension}"
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

  def image_content(raw)
    image = Array(raw["data"]).find { |item| item.is_a?(Hash) && item["b64_json"] }
    image && image["b64_json"]
  end

  def write_image_output(path, content)
    raise "No image data returned" if content.to_s.empty?

    File.binwrite(path, Base64.decode64(content))
  end

  def speech_content(audio, output_path:, base64:, response_format:)
    return Base64.strict_encode64(audio) if base64
    return audio unless output_path

    {
      "path" => output_path,
      "bytes" => audio.bytesize,
      "format" => response_format
    }
  end

  def transcription_content(raw)
    return raw["text"] if raw.is_a?(Hash) && raw.key?("text")

    raw
  end

  def multipart_body(fields, file_field:, boundary:)
    body = String.new(encoding: Encoding::BINARY)

    fields.each do |name, value|
      multipart_field_parts(name, value).each do |field_name, field_value|
        body << "--#{boundary}\r\n".b
        body << "Content-Disposition: form-data; name=\"#{multipart_quote(field_name)}\"\r\n\r\n".b
        body << field_value.to_s.b
        body << "\r\n".b
      end
    end

    body << "--#{boundary}\r\n".b
    body << "Content-Disposition: form-data; name=\"#{multipart_quote(file_field[:name])}\"; filename=\"#{multipart_quote(file_field[:filename])}\"\r\n".b
    body << "Content-Type: #{file_field[:content_type]}\r\n\r\n".b
    body << File.binread(file_field[:path])
    body << "\r\n--#{boundary}--\r\n".b
    body
  end

  def multipart_field_parts(name, value)
    return [] if value.nil?

    if value.is_a?(Array)
      value.map { |item| ["#{name}[]", multipart_value(item)] }
    else
      [[name.to_s, multipart_value(value)]]
    end
  end

  def multipart_value(value)
    case value
    when Hash
      JSON.generate(value)
    else
      value
    end
  end

  def multipart_quote(value)
    value.to_s.gsub("\\", "\\\\").gsub("\"", "\\\"").delete("\r\n")
  end

  def parse_error_response(body)
    JSON.parse(body)
  rescue JSON::ParserError
    body
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

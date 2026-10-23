class AiLite
  class Gemini
    module Embeddings
      def embed(input, model: nil, dimensions: nil, encoding_format: nil, debug: false, options: {})
        response = nil
        raw = nil
        multiple = input.is_a?(Array)
        texts = multiple ? input : [input]
        unless !texts.empty? && texts.all? { |text| text.is_a?(String) && !text.strip.empty? }
          raise ArgumentError, "input must be a nonempty string or array of nonempty strings"
        end
        unless dimensions.nil? || (dimensions.is_a?(Integer) && dimensions > 0)
          raise ArgumentError, "dimensions must be a positive integer"
        end
        unless encoding_format.nil? || encoding_format == "float"
          raise ArgumentError, "Gemini embeddings only support encoding_format: float"
        end
        model_id = model || embedding_model
        unless model_id.is_a?(String) && model_id.match?(%r{\A(?:models/)?[A-Za-z0-9._-]+\z})
          raise ArgumentError, "model must be a Gemini model ID"
        end
        resource = "models/#{model_id.delete_prefix('models/')}"
        settings = options.each_with_object({}) { |(key, value), result| result[key.to_s] = value }
        settings["outputDimensionality"] = dimensions if dimensions
        requests = texts.map do |text|
          settings.merge("model" => resource, "content" => { "parts" => [{ "text" => text }] })
        end
        action = multiple ? "batchEmbedContents" : "embedContent"
        payload = multiple ? { "requests" => requests } : requests.first
        response = post_json(payload, endpoint: "#{API_BASE_URL}/#{resource}:#{action}")
        raw = response.body
        raw = JSON.parse(raw)
        raise "Invalid Gemini embedding response: expected an object" unless raw.is_a?(Hash)
        if !response.code.to_i.between?(200, 299) || raw["error"]
          return result_envelope(status: response.code.to_i, error: error_message(raw), raw: raw, debug: debug)
        end
        embeddings = multiple ? raw["embeddings"] : [raw["embedding"]]
        unless embeddings.is_a?(Array) && embeddings.length == texts.length
          raise "Invalid Gemini embedding response: unexpected embedding count"
        end
        vectors = embeddings.map do |entry|
          values = entry["values"] if entry.is_a?(Hash)
          unless values.is_a?(Array) && !values.empty? && values.all? { |value| value.is_a?(Numeric) }
            raise "Invalid Gemini embedding response: expected numeric values"
          end
          values
        end
        result_envelope(status: response.code.to_i, content: multiple ? vectors : vectors.first,
                        raw: raw, debug: debug)
      rescue StandardError => e
        result_envelope(status: response ? response.code.to_i : "unknown", error: e.message, raw: raw, debug: debug)
      end
    end

    include Embeddings
    private_constant :Embeddings
  end
end

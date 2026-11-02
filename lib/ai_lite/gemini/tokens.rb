class AiLite
  class Gemini
    module Tokens
      def count_tokens(input, model: nil, instructions: nil, debug: false, options: {})
        response = raw = nil
        model_id = model || self.model
        unless model_id.is_a?(String) && model_id.match?(%r{\A(?:models/)?[A-Za-z0-9._-]+\z})
          raise ArgumentError, "model must be a Gemini model ID"
        end
        raise ArgumentError, "instructions must be a string" unless instructions.nil? || instructions.is_a?(String)
        raise ArgumentError, "options must be a hash" unless options.is_a?(Hash)

        contents = input.is_a?(String) ? [{ "parts" => [{ "text" => input }] }] : (input.is_a?(Hash) ? [input] : input)
        unless contents.is_a?(Array) && contents.all? { |item| item.is_a?(Hash) && (item["parts"] || item[:parts]).is_a?(Array) }
          raise ArgumentError, "input must be a string, a Gemini Content hash with parts, or an array of Content hashes"
        end
        resource = "models/#{model_id.delete_prefix('models/')}"
        payload = options.each_with_object({}) { |(key, value), result| result[key.to_s] = value }
        if payload.key?("previous_interaction_id") || payload.key?("previous_response_id")
          raise ArgumentError, "Gemini token counting requires explicit conversation contents, not a previous interaction ID"
        end
        if payload.key?("generateContentRequest") || !instructions.nil?
          request = payload.fetch("generateContentRequest", {})
          raise ArgumentError, "generateContentRequest must be a hash" unless request.is_a?(Hash)

          request = request.each_with_object({}) { |(key, value), result| result[key.to_s] = value }
          request.merge!("model" => resource, "contents" => contents)
          request["systemInstruction"] = { "parts" => [{ "text" => instructions }] } unless instructions.nil?
          payload.delete("contents")
          payload["generateContentRequest"] = request
        else
          payload["contents"] = contents
        end
        response = post_json(payload, endpoint: "#{API_BASE_URL}/#{resource}:countTokens")
        raw = response.body
        raw = JSON.parse(raw)
        raise "Invalid Gemini token count response: expected an object" unless raw.is_a?(Hash)
        unless response.code.to_i.between?(200, 299) && !raw["error"]
          return result_envelope(status: response.code.to_i, error: error_message(raw), raw: raw, debug: debug)
        end
        count = raw["totalTokens"]
        raise "Invalid Gemini token count: expected a nonnegative integer" unless count.is_a?(Integer) && count >= 0

        result_envelope(status: response.code.to_i, content: count, raw: raw, debug: debug)
      rescue StandardError => e
        result_envelope(status: response ? response.code.to_i : "unknown", error: e.message, raw: raw, debug: debug)
      end
    end

    include Tokens
    private_constant :Tokens
  end
end

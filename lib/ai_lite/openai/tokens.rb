class AiLite
  class OpenAI
    module Tokens
      def count_tokens(input, model: nil, instructions: nil, previous_response_id: nil, debug: false, options: {})
        response = raw = nil
        unless input.is_a?(String) || (input.is_a?(Array) && input.all? { |item| item.is_a?(Hash) })
          raise ArgumentError, "input must be a string or an array of OpenAI Responses input items"
        end
        raise ArgumentError, "options must be a hash" unless options.is_a?(Hash)
        raise ArgumentError, "instructions must be a string" unless instructions.nil? || instructions.is_a?(String)

        payload = options.each_with_object({}) { |(key, value), result| result[key.to_s] = value }
        payload.merge!("model" => model || self.model, "input" => input)
        payload["instructions"] = instructions unless instructions.nil?
        payload["previous_response_id"] = previous_response_id unless previous_response_id.nil?
        response = post(payload, endpoint: "#{API_BASE_URL}/responses/input_tokens")
        raw = response.body
        raw = JSON.parse(raw)
        raise "Invalid OpenAI token count response: expected an object" unless raw.is_a?(Hash)

        unless response.code.to_i.between?(200, 299) && !raw["error"]
          error = raw["error"]
          message = error.is_a?(Hash) ? (error["message"] || error.to_s) : (error || raw["message"] || raw.to_s)
          return prettify_data(status: response.code.to_i, error: message, raw: raw, debug: debug)
        end
        count = raw["input_tokens"]
        raise "Invalid OpenAI token count: expected a nonnegative integer" unless count.is_a?(Integer) && count >= 0

        prettify_data(status: response.code.to_i, content: count, raw: raw, debug: debug)
      rescue StandardError => e
        prettify_data(status: response ? response.code.to_i : "unknown", error: e.message, raw: raw, debug: debug)
      end
    end

    include Tokens
    private_constant :Tokens
  end
end

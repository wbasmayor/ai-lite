class AiLite
  class Claude
    module Tokens
      def count_tokens(input, model: nil, instructions: nil, debug: false, options: {})
        response = raw = nil
        raise ArgumentError, "options must be a hash" unless options.is_a?(Hash)
        unless instructions.nil? || instructions.is_a?(String)
          raise ArgumentError, "instructions must be a string; use options[:system] for native blocks"
        end
        payload = options.each_with_object({}) { |(key, value), result| result[key.to_s] = value }
        if payload.key?("previous_response_id") || payload.key?("previous_interaction_id")
          raise ArgumentError, "Claude token counting requires explicit message history, not a previous response ID"
        end
        payload.merge!("model" => model || self.model, "messages" => claude_messages(input))
        payload["system"] = instructions unless instructions.nil?
        response = post_json(payload, endpoint: "#{API_BASE_URL}/messages/count_tokens")
        raw = response.body
        raw = JSON.parse(raw)
        raise "Invalid Claude token count response: expected an object" unless raw.is_a?(Hash)
        unless response.code.to_i.between?(200, 299) && !raw["error"]
          return result_envelope(status: response.code.to_i, error: error_message(raw), raw: raw, debug: debug)
        end
        count = raw["input_tokens"]
        raise "Invalid Claude token count: expected a nonnegative integer" unless count.is_a?(Integer) && count >= 0

        result_envelope(status: response.code.to_i, content: count, raw: raw, debug: debug)
      rescue StandardError => e
        result_envelope(status: response ? response.code.to_i : "unknown", error: e.message, raw: raw, debug: debug)
      end
    end

    include Tokens
    private_constant :Tokens
  end
end

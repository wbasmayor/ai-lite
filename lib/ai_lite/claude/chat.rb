class AiLite
  class Claude
    module Chat
      def chat(message, model: nil, instructions: nil, max_output_tokens: nil, previous_response_id: nil, debug: false, options: {})
        response = raw = response_id = nil
        raise ArgumentError, "Claude requires explicit message history, not previous_response_id" unless previous_response_id.nil?
        raise ArgumentError, "options must be a hash" unless options.is_a?(Hash)
        payload = options.each_with_object({}) { |(key, value), result| result[key.to_s] = value }
        if payload.key?("previous_response_id") || payload.key?("previous_interaction_id")
          raise ArgumentError, "Claude requires explicit message history, not a previous response ID"
        end
        raise ArgumentError, "Claude streaming is not implemented yet" if payload["stream"]
        unless instructions.nil? || instructions.is_a?(String)
          raise ArgumentError, "instructions must be a string; use options[:system] for native blocks"
        end
        messages = message.is_a?(String) ? [{ "role" => "user", "content" => message }] : message
        unless messages.is_a?(Array) && !messages.empty? && messages.all? { |item| item.is_a?(Hash) }
          raise ArgumentError, "message must be a string or a nonempty array of Claude messages"
        end
        messages.each do |item|
          role = item["role"] || item[:role]
          content = item.key?("content") ? item["content"] : item[:content]
          unless %w[user assistant system].include?(role) && (content.is_a?(String) || content.is_a?(Array))
            raise ArgumentError, "Each Claude message requires a native role and string or array content"
          end
        end
        limit = max_output_tokens || payload["max_tokens"] || self.max_output_tokens
        raise ArgumentError, "max_output_tokens must be a nonnegative integer" unless limit.is_a?(Integer) && limit >= 0
        payload.merge!("model" => model || self.model, "messages" => messages, "max_tokens" => limit)
        payload["system"] = instructions unless instructions.nil?
        response = post_json(payload, endpoint: "#{API_BASE_URL}/messages")
        raw = response.body
        raw = JSON.parse(raw)
        raise "Invalid Claude response: expected an object" unless raw.is_a?(Hash)
        response_id = raw["id"]
        unless response.code.to_i.between?(200, 299) && !raw["error"]
          return result_envelope(status: response.code.to_i, error: error_message(raw), response_id: response_id, raw: raw, debug: debug)
        end
        blocks = raw["content"]
        unless raw["type"] == "message" && raw["role"] == "assistant" && blocks.is_a?(Array) && blocks.all? { |part| part.is_a?(Hash) }
          raise "Invalid Claude response: expected an assistant message with content blocks"
        end
        text = blocks.select { |part| part["type"] == "text" }.map do |part|
          raise "Invalid Claude text block" unless part["text"].is_a?(String)
          part["text"]
        end.join.strip
        content = text.empty? ? nil : text
        if content
          begin
            content = JSON.parse(text)
          rescue JSON::ParserError
            # Preserve ordinary text, matching the other providers.
          end
        end
        reason = raw["stop_reason"]
        error = unless %w[end_turn stop_sequence].include?(reason)
                  "Claude stopped with #{reason || 'no stop reason'}; inspect raw with debug: true"
                end
        result = result_envelope(status: response.code.to_i, content: content, error: error,
                                 response_id: response_id, raw: raw, debug: debug)
        # Preserve every content block for stateless replay, including thinking signatures.
        result["assistant_message"] = { "role" => "assistant", "content" => blocks }
        result
      rescue StandardError => e
        result_envelope(status: response ? response.code.to_i : "unknown", error: e.message,
                        response_id: response_id, raw: raw, debug: debug)
      end
    end

    include Chat
    private_constant :Chat
  end
end

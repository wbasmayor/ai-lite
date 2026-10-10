class AiLite
  class Gemini
    module Chat
      def chat(message, model: nil, instructions: nil, previous_response_id: nil, max_output_tokens: nil, debug: false, options: {})
        response = nil
        raw = nil
        response_id = nil
        payload = chat_payload(message, model: model, instructions: instructions,
                               previous_response_id: previous_response_id,
                               max_output_tokens: max_output_tokens, options: options)
        response = post_interaction(payload)
        raw = response.body
        raw = JSON.parse(raw)
        raise "Invalid Gemini response: expected an object" unless raw.is_a?(Hash)

        response_id = raw["id"]
        unless response.code.to_i.between?(200, 299)
          return result_envelope(status: response.code.to_i, error: error_message(raw),
                                 response_id: response_id, raw: raw, debug: debug)
        end

        error = if raw["error"]
                  error_message(raw)
                elsif raw["status"] != "completed"
                  "Gemini interaction #{raw['status'] || 'has no status'}; inspect raw with debug: true"
                end
        steps = raw["steps"]
        raise "Invalid Gemini response: expected steps" unless steps.is_a?(Array) || error

        text = Array(steps).flat_map do |step|
          next [] unless step.is_a?(Hash) && step["type"] == "model_output"

          Array(step["content"]).map do |part|
            part["text"] if part.is_a?(Hash) && part["type"] == "text" && part["text"].is_a?(String)
          end.compact
        end.join.strip
        content = if text.empty?
                    nil
                  else
                    begin
                      JSON.parse(text)
                    rescue JSON::ParserError
                      text
                    end
                  end
        result_envelope(status: response.code.to_i, content: content, error: error,
                        response_id: response_id, raw: raw, debug: debug)
      rescue StandardError => e
        result_envelope(status: response ? response.code.to_i : "unknown", error: e.message,
                        response_id: response_id, raw: raw, debug: debug)
      end
      private

      def chat_payload(message, model:, instructions:, previous_response_id:, max_output_tokens:, options:, stream: false)
        payload = options.each_with_object({}) { |(key, value), result| result[key.to_s] = value }
        if (!stream && payload["stream"]) || payload["background"]
          raise ArgumentError, "Use chat_stream for streaming; background execution is not supported"
        end
        unless message.is_a?(String) || message.is_a?(Hash) || message.is_a?(Array)
          raise ArgumentError, "message must be a string, a Gemini content hash, or an array of Gemini content/steps"
        end
        generation = payload.fetch("generation_config", {})
        raise ArgumentError, "generation_config must be a hash" unless generation.is_a?(Hash)

        generation = generation.each_with_object({}) { |(key, value), result| result[key.to_s] = value }
        generation["max_output_tokens"] = max_output_tokens || generation["max_output_tokens"] || self.max_output_tokens
        payload.merge!("model" => model || self.model, "input" => message, "generation_config" => generation)
        payload["system_instruction"] = instructions if instructions
        payload["previous_interaction_id"] = previous_response_id if previous_response_id
        payload["stream"] = true if stream
        payload
      end
    end

    include Chat
    private_constant :Chat
  end
end

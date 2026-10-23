class AiLite
  class Gemini
    module Images
      def image(prompt, model: nil, output_path: nil, debug: false, options: {})
        response = nil
        raw = nil
        response_id = nil
        unless prompt.is_a?(String) && !prompt.strip.empty?
          raise ArgumentError, "prompt must be a nonempty string"
        end
        payload = options.each_with_object({}) { |(key, value), result| result[key.to_s] = value }
        if payload["stream"] || payload["background"]
          raise ArgumentError, "image does not support streaming or background execution"
        end
        payload.merge!("model" => model || image_model, "input" => prompt)
        response = post_interaction(payload)
        raw = response.body
        raw = JSON.parse(raw)
        raise "Invalid Gemini image response: expected an object" unless raw.is_a?(Hash)

        response_id = raw["id"]
        if !response.code.to_i.between?(200, 299) || raw["error"]
          return result_envelope(status: response.code.to_i, error: error_message(raw),
                                 response_id: response_id, raw: raw, debug: debug)
        end
        unless raw["status"] == "completed"
          raise "Gemini interaction #{raw['status'] || 'has no status'}; inspect raw with debug: true"
        end
        steps = raw["steps"]
        raise "Invalid Gemini image response: expected steps" unless steps.is_a?(Array)

        image = steps.flat_map do |step|
          next [] unless step.is_a?(Hash) && step["type"] == "model_output"

          step["content"].is_a?(Array) ? step["content"] : []
        end.find { |part| part.is_a?(Hash) && part["type"] == "image" }
        content = image && image["data"]
        unless content.is_a?(String) && !content.empty?
          raise "No inline image data returned; inspect raw with debug: true"
        end
        bytes = Base64.strict_decode64(content)
        raise "Empty image data returned" if bytes.empty?

        File.binwrite(output_path, bytes) if output_path
        result_envelope(status: response.code.to_i, content: content, response_id: response_id,
                        raw: raw, debug: debug)
      rescue StandardError => e
        result_envelope(status: response ? response.code.to_i : "unknown", error: e.message,
                        response_id: response_id, raw: raw, debug: debug)
      end
    end

    include Images
    private_constant :Images
  end
end

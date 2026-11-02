class AiLite
  class OpenAI
    module ToolCalling
      private

      def apply_chat_tools(payload, tools)
        payload["tools"] = tools unless tools.nil?
        if payload.key?("tools") && !(payload["tools"].is_a?(Array) && payload["tools"].all? { |tool| tool.is_a?(Hash) })
          raise ArgumentError, "tools must be an array of provider tool definitions"
        end
        payload
      end

      def tool_result_input(message, results, previous_id)
        return message if results.nil?
        raise ArgumentError, "Use tool_results without a message" unless message.nil?
        unless previous_id.is_a?(String) && !previous_id.strip.empty?
          raise ArgumentError, "tool_results requires previous_response_id; use native input for stateless history"
        end
        unless results.is_a?(Array) && !results.empty?
          raise ArgumentError, "tool_results must be a nonempty array"
        end
        ids = []
        results.map do |item|
          raise ArgumentError, "Each tool result must be a hash" unless item.is_a?(Hash)
          entry = item.each_with_object({}) { |(key, value), hash| hash[key.to_s] = value }
          unless %w[id name].all? { |key| entry[key].is_a?(String) && !entry[key].strip.empty? } && entry.key?("output")
            raise ArgumentError, "Each tool result requires id, name, and output"
          end
          raise ArgumentError, "Duplicate tool result ID" if ids.include?(entry["id"])
          ids << entry["id"]
          output = entry["output"].is_a?(String) ? entry["output"] : JSON.generate(entry["output"])
          { "type" => "function_call_output", "call_id" => entry["id"], "output" => output }
        end
      end

      def extract_tool_calls(raw)
        calls = Array(raw["output"]).select { |item| item.is_a?(Hash) && item["type"] == "function_call" }
        if !calls.empty? && raw["status"] && raw["status"] != "completed"
          raise "Response #{raw['status']}: function calls are not complete"
        end
        ids = []
        calls.map do |call|
          if call["status"] && call["status"] != "completed"
            raise "Function call #{call['status']}: arguments are not complete"
          end
          id = call["call_id"]
          name = call["name"]
          arguments = call["arguments"]
          arguments = JSON.parse(arguments) if arguments.is_a?(String)
          unless id.is_a?(String) && !id.empty? && name.is_a?(String) && !name.empty? && arguments.is_a?(Hash)
            raise "Invalid function call: expected ID, name, and object arguments"
          end
          raise "Invalid function call: duplicate ID" if ids.include?(id)
          ids << id
          { "id" => id, "name" => name, "arguments" => arguments }
        end
      end

      def attach_tool_calls(result, raw)
        return result if result["error"]
        calls = extract_tool_calls(raw)
        result["tool_calls"] = calls unless calls.empty?
        result
      end
    end

    include ToolCalling
    private_constant :ToolCalling
  end
end

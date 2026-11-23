class AiLite
  class Claude
    module ToolCalling
      private

      def apply_chat_tools(payload, tools)
        payload["tools"] = tools unless tools.nil?
        if payload.key?("tools") && !(payload["tools"].is_a?(Array) && payload["tools"].all? { |tool| tool.is_a?(Hash) })
          raise ArgumentError, "tools must be an array of native Claude tool definitions"
        end
      end

      def extract_tool_calls(blocks)
        ids = []
        blocks.select { |part| part["type"] == "tool_use" }.map do |part|
          id, name, arguments = part.values_at("id", "name", "input")
          unless [id, name].all? { |value| value.is_a?(String) && !value.strip.empty? } && arguments.is_a?(Hash)
            raise ArgumentError, "Invalid Claude tool call: expected ID, name, and object input"
          end
          raise ArgumentError, "Invalid Claude tool call: duplicate ID" if ids.include?(id)
          ids << id
          { "id" => id, "name" => name, "arguments" => arguments }
        end
      end

      def tool_result_messages(messages, results)
        return messages if results.nil?
        unless results.is_a?(Array) && !results.empty?
          raise ArgumentError, "tool_results must be a nonempty array"
        end
        last = messages.last
        role = last["role"] || last[:role]
        blocks = last["content"] || last[:content]
        unless role == "assistant" && blocks.is_a?(Array) && blocks.all? { |part| part.is_a?(Hash) }
          raise ArgumentError, "tool_results requires explicit history ending with the assistant tool-use message"
        end
        native = blocks.map { |part| part.each_with_object({}) { |(key, value), hash| hash[key.to_s] = value } }
        calls = extract_tool_calls(native)
        raise ArgumentError, "Assistant history has no tool calls" if calls.empty?
        ids = []
        content = results.map do |item|
          raise ArgumentError, "Each tool result must be a hash" unless item.is_a?(Hash)
          entry = item.each_with_object({}) { |(key, value), hash| hash[key.to_s] = value }
          call = calls.find { |candidate| candidate["id"] == entry["id"] }
          unless call && entry["name"] == call["name"] && entry.key?("output")
            raise ArgumentError, "Each tool result requires a matching id, name, and output"
          end
          raise ArgumentError, "Duplicate tool result ID" if ids.include?(entry["id"])
          ids << entry["id"]
          output = entry["output"].is_a?(String) ? entry["output"] : JSON.generate(entry["output"])
          result = { "type" => "tool_result", "tool_use_id" => entry["id"], "content" => output }
          if entry.key?("is_error")
            unless entry["is_error"] == true || entry["is_error"] == false
              raise ArgumentError, "is_error must be true or false"
            end
            result["is_error"] = entry["is_error"]
          end
          result
        end
        raise ArgumentError, "Return a result for every requested tool call" unless ids.sort == calls.map { |call| call["id"] }.sort
        messages + [{ "role" => "user", "content" => content }]
      end
    end

    include ToolCalling
    private_constant :ToolCalling
  end
end

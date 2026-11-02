class AiLite
  class Gemini
    module Streaming
      def chat_stream(message, model: nil, instructions: nil, previous_response_id: nil, max_output_tokens: nil, tools: nil, tool_results: nil, debug: false, options: {}, &block)
        raise ArgumentError, "chat_stream requires a block" unless block

        status = "unknown"
        text = +""
        response_id = nil
        events = debug ? [] : nil
        interaction = nil
        raw = nil
        callback_error = nil
        begin
          payload = chat_payload(message, model: model, instructions: instructions,
                                 previous_response_id: previous_response_id,
                                 max_output_tokens: max_output_tokens, options: options, stream: true, tools: tools, tool_results: tool_results)
          uri = URI.parse("#{API_BASE_URL}/interactions")
          request = Net::HTTP::Post.new(uri)
          headers.each { |key, value| request[key] = value }
          request["Accept"] = "text/event-stream"
          request.body = JSON.generate(payload)
          result = nil
          step_types = {}
          function_steps = {}
          argument_fragments = {}
          finished_functions = {}
          Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
            http.open_timeout = timeout
            http.read_timeout = timeout
            catch(:ai_lite_gemini_finished) do
              http.request(request) do |response|
                status = response.code.to_i
                unless status.between?(200, 299)
                  raw = +""
                  response.read_body { |chunk| raw << chunk }
                  raw = JSON.parse(raw)
                  result = result_envelope(status: status, error: error_message(raw), raw: raw, debug: debug)
                  throw :ai_lite_gemini_finished
                end
                each_gemini_stream_event(response) do |event|
                  events << event if events
                  raw = { "interaction" => interaction, "events" => events } if debug
                  case event["event_type"]
                  when "interaction.created"
                    interaction = event.fetch("interaction")
                    response_id = interaction["id"] || response_id
                  when "step.start"
                    index = event.fetch("index")
                    step = event.fetch("step")
                    step_types[index] = step.fetch("type")
                    function_steps[index] = step.dup if step["type"] == "function_call"
                  when "step.delta"
                    delta = event.fetch("delta")
                    if step_types[event["index"]] == "function_call" && delta["type"] == "arguments_delta"
                      index = event["index"]
                      argument_fragments[index] ||= +""
                      argument_fragments[index] << delta.fetch("arguments")
                    end
                    if step_types[event["index"]] == "model_output" && delta["type"] == "text"
                      chunk = delta.fetch("text")
                      text << chunk
                      begin
                        block.call(chunk)
                      rescue StandardError => e
                        callback_error = e
                        raise
                      end
                    end
                  when "step.stop"
                    index = event["index"]
                    if function_steps.key?(index)
                      function_steps[index]["arguments"] = argument_fragments[index] if argument_fragments.key?(index)
                      finished_functions[index] = function_steps[index]
                    end
                  when "interaction.status_update"
                    response_id = event["interaction_id"] || response_id
                    if event["status"] == "requires_action"
                      raise "Gemini interaction requires_action before function calls completed" unless function_steps.size == finished_functions.size && !finished_functions.empty?
                      result = result_envelope(status: status, content: text.empty? ? nil : text,
                        response_id: response_id, raw: raw, debug: debug)
                      attach_tool_calls(result, { "steps" => finished_functions.values })
                      throw :ai_lite_gemini_finished
                    end
                    if %w[failed cancelled incomplete].include?(event["status"])
                      result = result_envelope(status: status, content: text.empty? ? nil : text,
                        response_id: response_id, error: "Gemini interaction #{event['status']}", raw: raw, debug: debug)
                      throw :ai_lite_gemini_finished
                    end
                  when "interaction.completed"
                    interaction = event.fetch("interaction")
                    response_id = interaction["id"] || response_id
                    raw = { "interaction" => interaction, "events" => events } if debug
                    tool_source = interaction.key?("steps") ? interaction : { "steps" => finished_functions.values }
                    error = if interaction["error"]
                              error_message(interaction)
                            elsif interaction["status"] != "completed" && !(interaction["status"] == "requires_action" && !extract_tool_calls(tool_source).empty?)
                              "Gemini interaction #{interaction['status'] || 'has no status'}"
                            end
                    content = text.empty? ? nil : text
                    unless error || content.nil?
                      begin
                        content = JSON.parse(text.strip)
                      rescue JSON::ParserError
                        content = text.strip
                      end
                    end
                    result = result_envelope(status: status, content: content, response_id: response_id,
                                             error: error, raw: raw, debug: debug)
                    unless error
                      raise "Gemini function call stream ended before step.stop" if !interaction.key?("steps") && function_steps.size != finished_functions.size
                      attach_tool_calls(result, tool_source)
                    end
                    throw :ai_lite_gemini_finished
                  when "error"
                    result = result_envelope(status: status, content: text.empty? ? nil : text,
                      response_id: response_id, error: error_message(event), raw: raw, debug: debug)
                    throw :ai_lite_gemini_finished
                  end
                end
              end
            end
          end
          result || result_envelope(status: status, content: text.empty? ? nil : text, response_id: response_id,
            error: "Stream ended before a terminal interaction event", raw: raw, debug: debug)
        rescue StandardError => e
          raise if callback_error.equal?(e)

          result_envelope(status: status, content: text.empty? ? nil : text, response_id: response_id,
                          error: e.message, raw: raw, debug: debug)
        end
      end

      private

      def each_gemini_stream_event(response)
        buffer = +"".b
        data = []
        consume = lambda do
          while (boundary = buffer.index(/[\r\n]/))
            # A trailing CR might be the first byte of a CRLF split across reads.
            break if buffer.getbyte(boundary) == 13 && boundary == buffer.bytesize - 1

            width = buffer.byteslice(boundary, 2) == "\r\n" ? 2 : 1
            line = buffer.slice!(0, boundary + width).byteslice(0, boundary)
            if line.empty?
              unless data.empty?
                payload = data.join("\n").force_encoding(Encoding::UTF_8)
                data.clear
                unless payload == "[DONE]"
                  event = JSON.parse(payload)
                  raise "Invalid streaming event: expected an object" unless event.is_a?(Hash)
                  yield event
                end
              end
            elsif line.start_with?("data:")
              data << line.sub(/\Adata: ?/, "")
            end
          end
        end
        response.read_body do |chunk|
          buffer << chunk.b
          consume.call
        end
        # A final lone CR is a complete line delimiter at EOF.
        if buffer.end_with?("\r")
          buffer << "\n"
          consume.call
        end
      end

    end

    include Streaming
    private_constant :Streaming
  end
end

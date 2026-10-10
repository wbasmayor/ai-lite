require_relative "ai_lite/version"
require_relative "ai_lite/openai"
require_relative "ai_lite/gemini"

class AiLite
  # Preserve previously public constants while ownership stays with OpenAI.
  OpenAI.constants(false).each do |name|
    const_set(name, OpenAI.const_get(name))
  end

  @deprecation_mutex = Mutex.new
  @deprecated_entry_points = {}

  class << self
    def new(**kwargs)
      warn_legacy_entry_point(:new)
      OpenAI.new(**kwargs)
    end

    %i[configuration configure reset_configuration! client reset_client!
       chat chat_stream moderate embed image speak transcribe
       available_models model_available? configured_models check_configured_models].each do |method_name|
      define_method(method_name) do |*args, **kwargs, &block|
        warn_legacy_entry_point(method_name)
        if kwargs.empty?
          OpenAI.public_send(method_name, *args, &block)
        else
          OpenAI.public_send(method_name, *args, **kwargs, &block)
        end
      end
    end

    private

    def warn_legacy_entry_point(method_name)
      @deprecation_mutex.synchronize do
        return if @deprecated_entry_points[method_name]

        warn "[ai-lite] AiLite.#{method_name} is deprecated. " \
             "Use AiLite::OpenAI.#{method_name} instead. " \
             "The legacy entry point will be removed in v2.0."
        @deprecated_entry_points[method_name] = true
      end
    end
  end
end

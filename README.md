# AI Lite

AI Lite is a lightweight, pure Ruby client for OpenAI, Gemini, and Claude, built
entirely on the Ruby standard library with no runtime gem dependencies.

OpenAI and Gemini support chat, streaming, function calling, embeddings, image
generation, speech, transcription, token counting, and model availability checks.
Claude currently supports synchronous chat and explicit message history through
the same consistent result format. Claude support is available starting in v1.3.0.

Built for Rails apps and plain Ruby projects that want straightforward AI
integration without a larger SDK or framework. AI Lite handles the API calls
while you control your application's architecture.

Supports Ruby 2.6 through 4.0, with no Rails dependency or runtime gem dependencies.

This gem is intentionally small:

- No Rails dependency
- No provider SDK dependency
- No Faraday, HTTParty, ActiveSupport, or connection pool dependency
- Uses only Ruby stdlib: `Net::HTTP`, `URI`, `JSON`, and `SecureRandom`

Choose a provider and call the methods your app needs:

```ruby
require "ai_lite"

openai = AiLite::OpenAI.new # Reads OPENAI_API_KEY
gemini = AiLite::Gemini.new # Reads GEMINI_API_KEY
claude = AiLite::Claude.new # Reads ANTHROPIC_API_KEY

openai.chat("Say hello")
gemini.chat("Say hello")
claude.chat("Say hello")

openai.embed("Text to vectorize")
gemini.embed("Text to vectorize")

openai.image("A simple app icon")
gemini.image("A simple app icon")
```

Each provider has independent configuration and native API options. OpenAI also
supports moderation; Gemini supports structured
media input and a YouTube helper. The table below lists the available methods.

## Provider support

| Method | OpenAI | Gemini | Claude |
| --- | --- | --- | --- |
| `chat` | Yes | Yes | Yes; tool helpers pending |
| `chat_stream`, `count_tokens` | Yes | Yes | Not implemented |
| Four model helpers | Yes | Yes | Not implemented |
| `youtube` | No | Yes | Not implemented |
| `embed`, `image`, `speak`, `transcribe` | Yes | Yes | Not implemented |
| `moderate` | Yes | Not implemented | Not implemented |

Unsupported provider methods are absent and raise Ruby's `NoMethodError` if called.
Configure providers during application startup; do not mutate shared configuration
or client headers while requests are running. The gem does not provide automatic
retries, worker threads, or a background-job queue.

## Claude

`AiLite::Claude` supports synchronous chat and explicit message history starting
in v1.3.0. Claude streaming, normalized tool calls/results, token
counting, and model helpers are still pending.

```ruby
require "ai_lite/claude" # Also loaded by require "ai_lite"

claude = AiLite::Claude.new # Reads ANTHROPIC_API_KEY; does not load .env
result = claude.chat("Hello", max_output_tokens: 32,
                     options: { thinking: { type: "disabled" }, output_config: { effort: "low" } })
raise result["error"] if result["error"]
puts result["content"]
```

Defaults: `claude-haiku-5-5`, API version `2026-10-21`, 120-second timeout, and
2,000 maximum output tokens. Thinking settings are provider defaults unless
supplied through `options:`. The short example disables thinking and limits output
for inexpensive development checks; those options depend on the selected model.

The example above uses the default Haiku model. For `claude-sonnet-5-5`, use
`thinking: { type: "between_tools" }` instead of `disabled`:

```ruby
result = claude.chat("Reply only OK.", model: "claude-sonnet-5-5",
                     max_output_tokens: 32,
                     options: { thinking: { type: "between_tools" }, output_config: { effort: "low" } })
raise result["error"] if result["error"]
puts result["content"]
```

AI Lite passes these native options through to Claude; it does not translate
thinking settings between models. The API returns an error for unsupported settings.

```ruby
AiLite::Claude.configure do |config|
  config.api_key = ENV["ANTHROPIC_API_KEY"]
  config.model = "claude-haiku-5-5"
  config.max_output_tokens = 256
  # config.workspace_id = "wrkspc_..." # For keys that require workspace selection
end
AiLite::Claude.chat("Hello")
```

Constructor keywords override configuration, and `api_key:` falls back to
`ANTHROPIC_API_KEY`. Other providers' keys are never used. `api_version` and
`workspace_id` are configurable in both places. Missing credentials raise
`ArgumentError`; request, transport, and response failures use the normal error
envelope. `instructions:` maps to `system`, and `max_output_tokens:` maps to
`max_tokens`. Native options pass through without mutating the caller's hashes.

Claude's standard Messages API requires history on each turn:

```ruby
history = [{ role: "user", content: "My favorite color is blue." }]
first = claude.chat(history)
raise first["error"] if first["error"]
history << first["assistant_message"]
history << { role: "user", content: "What is my favorite color?" }
second = claude.chat(history)
```

The usual envelope is preserved, with `assistant_message` added for replay.
It contains the original assistant content blocks, including any thinking blocks
and signatures, even when `raw` is nil. Treat it as provider conversation data;
`content` remains the displayable text (or parsed JSON). `response_id` identifies
the message but cannot continue the conversation: `previous_response_id:` returns
an error. No conversation is stored inside the client.

Use `debug: true` for the full native response and usage. Truncation, refusals,
paused turns, and tool requests currently return a descriptive error while
preserving available text and assistant content. Only `end_turn` and
`stop_sequence` are handled as completed answers in this initial implementation.
Do not treat HTTP 200 alone as success. Native content blocks can be supplied in
message arrays; the gem does not upload or convert media.

Reference: [Claude Messages API](https://platform.claude.com/docs/en/api/messages/create).

## Function calling (OpenAI and Gemini)

Pass native tool definitions through `tools:` on `chat` or `chat_stream`.
Both providers accept the basic function definition below. Provider-specific
fields and built-in tools retain their native formats; `options:` remains the
escape hatch for settings such as tool choice.

```ruby
ai = AiLite::Gemini.new # Or AiLite::OpenAI.new

tools = [{
  type: "function",
  name: "lookup_order",
  description: "Look up an order's shipping status",
  parameters: {
    type: "object",
    properties: { order_id: { type: "integer" } },
    required: ["order_id"],
    additionalProperties: false
  }
}]

result = ai.chat("Where is order 123?", tools: tools)
raise result["error"] if result["error"]

# When a function is requested:
# result["tool_calls"] => [
#   { "id" => "call_123", "name" => "lookup_order",
#     "arguments" => { "order_id" => 123 } }
# ]
```

A tool request is a successful chat result. `content` may be nil or contain text
alongside tool calls. The `tool_calls` key appears only when complete function
calls are present; existing text-only envelopes are unchanged. OpenAI call IDs
come from `call_id`, not the output item's `id`. Gemini IDs come from the
function-call step's `id`. Arguments are decoded into hashes without requiring
`debug: true`. Failed/incomplete responses do not expose executable tool calls.

Your application validates arguments, authorizes access, and executes only
functions it explicitly allows. For example, in a Rails controller:

```ruby
calls = result.fetch("tool_calls", [])
unless calls.empty?
  outputs = calls.map do |call|
    raise "Unsupported tool" unless call["name"] == "lookup_order"
    order_id = call["arguments"].fetch("order_id")
    raise "Invalid order ID" unless order_id.is_a?(Integer)

    order = current_user.orders.find(order_id)
    { id: call["id"], name: call["name"], output: { status: order.status } }
  end

  result = ai.chat(
    nil,
    previous_response_id: result["response_id"],
    tools: tools,
    tool_results: outputs
  )
  raise result["error"] if result["error"]
end

puts result["content"]
# The model may request more tools; your app decides whether to continue.
```

`tool_results:` takes a nonempty array of `{ id:, name:, output: }` hashes,
requires `previous_response_id:`, and uses `nil` as the positional message.
Strings are sent as text; other JSON-compatible outputs are JSON-encoded.
The helper translates results into OpenAI `function_call_output` items or
Gemini `function_result` steps. Return a result for every requested call and
reuse the same provider/model and tool definitions. IDs refer to stored provider
state; when using stateless requests, pass native history/results as the
positional input instead. Preserve all provider-required history, including
reasoning/thought items and signatures; normalized `tool_calls` alone are not
full conversation history. Use non-streaming `chat` with `debug: true` for the full native response;
streaming debug output may contain partial metadata plus events.

`chat_stream` accepts the same tool keywords. Its block still receives text
only; complete tool calls are returned in the final envelope after streaming.
Do not execute streamed argument fragments. Class-level calls work too:
`AiLite::OpenAI.chat(...)` and `AiLite::Gemini.chat(...)`.

Explicit `tools:` overrides `options[:tools]`, including `tools: []` to clear
it. AI Lite does not execute functions, dispatch method names, retry tool calls,
or run an automatic agent loop. Built-in provider tools are passed through;
only custom `function_call` outputs are normalized into `tool_calls`.

See the [OpenAI function-calling guide](https://developers.openai.com/api/docs/guides/function-calling)
and [Gemini function-calling guide](https://ai.google.dev/gemini-api/docs/function-calling)
for native schemas and continuation requirements.

## Token counting (both providers)

```ruby
openai = AiLite::OpenAI.new
gemini = AiLite::Gemini.new

result = openai.count_tokens("Hello from AI Lite.")
result["content"] # Integer input-token count when error is nil
result["error"]   # nil on success

gemini.count_tokens("Hello from AI Lite.", instructions: "Be concise.")

# Class-level methods use each provider's independent configuration:
AiLite::OpenAI.count_tokens("Hello")
AiLite::Gemini.count_tokens("Hello")
```

These are authenticated HTTP calls, not offline tokenizers. They count input
only, without generating an answer or predicting output tokens or a final bill.
Counts depend on the model and the supplied context. Both use the configured
chat `model` by default; pass `model:` to override it. No tokenizer gem is needed.
The standard envelope contains an integer `content`, a nil `response_id`, and
`raw` only with `debug: true`. Check `error` before using the count; zero is a
valid count, and failures return nil content. Chat output-token defaults are
not added to counting requests.

OpenAI uses `POST /v1/responses/input_tokens`. Pass a string or an array of native
Responses input items, including supported media and conversation history:

```ruby
openai.count_tokens(
  [
    { role: "user", content: "Hello" },
    { role: "assistant", content: "Hi!" },
    { role: "user", content: "Tell me more." }
  ],
  instructions: "Be concise."
)
# Count a continuation using a response ID from an earlier chat:
openai.count_tokens("Tell me more.", previous_response_id: previous_result["response_id"])
```

Gemini uses `POST /v1beta/models/{model}:countTokens`. Its structured inputs use
**Content objects with `parts`, not the Interactions objects accepted by `chat`**:

```ruby
gemini.count_tokens(
  [
    { role: "user", parts: [{ text: "Hello" }] },
    { role: "model", parts: [{ text: "Hi!" }] },
    { role: "user", parts: [{ text: "Tell me more." }] }
  ],
  instructions: "Be concise."
)
```

A single Gemini Content hash is also accepted. Media uses native `inlineData`
or `fileData` parts; the helper does not read or upload local files. Supply
conversation history explicitly: Gemini counting does not resolve
`previous_response_id` or `previous_interaction_id`. Preflight counts can differ
from a later generation's reported usage.

`options:` passes native counting API fields. OpenAI tool definitions go in
`options: { tools: [...] }`; Gemini tool definitions go in
`options: { generateContentRequest: { tools: [...] } }`. Gemini `instructions:`
builds `generateContentRequest.systemInstruction`. The helper owns the model
and input/contents fields; explicit keywords take precedence over matching
options without mutating the caller's hashes. Native fields keep each API's
spelling. Use the counting endpoint's options rather than copying every chat
option. New methods are exposed on the provider classes; there is no legacy
`AiLite.count_tokens` class shortcut.

See [OpenAI's counting guide](https://developers.openai.com/api/docs/guides/token-counting)
and [Gemini's counting API reference](https://ai.google.dev/api/tokens) for supported
inputs and native parameters.

## Gemini

```ruby
require "ai_lite"

gemini = AiLite::Gemini.new # Reads GEMINI_API_KEY
result = gemini.chat("Tell me a joke")
puts result["content"]
warn result["error"] if result["error"]
```

The lookup order is an explicit `api_key:`, Gemini configuration, then
`ENV["GEMINI_API_KEY"]`. OpenAI credentials are never used for Gemini. The gem
does not load `.env` automatically.

```ruby
AiLite::Gemini.configure do |config|
  config.api_key = ENV["GEMINI_API_KEY"]
  config.model = "gemini-3.8-flash"
  config.embedding_model = "gemini-embedding-001"
  config.image_model = "gemini-nano-banana-2.1"
  config.speech_model = "gemini-3.8-flash-tts"
  config.speech_voice = "Kore"
  config.transcription_model = "gemini-3.5-transcribe"
  config.timeout = 120
  config.max_output_tokens = 2000
end

AiLite::Gemini.chat("Tell me a joke")
```

Each provider has independent configuration and a cached client. Constructor
keywords override configured defaults. Configuration changes reset that provider's
class-level client; existing instances keep their settings. Gemini uses the
Interactions API at `https://generativelanguage.googleapis.com/v1beta/interactions`
with `x-goog-api-key` authentication. Its API version and defaults belong to Gemini.

`chat` accepts a string, a native Gemini content hash, or an array of native
content blocks or interaction steps. Structured inputs pass through unchanged:

```ruby
result = gemini.chat([
  { type: "video", uri: "https://www.youtube.com/watch?v=YOUR_VIDEO_ID" },
  { type: "text", text: "Summarize the key points." }
])
```

Google validates media access and model support. This does not download videos,
upload local files, or make arbitrary video webpages accessible. Message history
uses Gemini's native `user_input` / `model_output` steps with `content` arrays;
OpenAI-style role/message arrays are not automatically translated.

Multi-turn continuation uses the familiar keyword:

```ruby
first = gemini.chat("My favorite color is blue.")
second = gemini.chat("What is my favorite color?", previous_response_id: first["response_id"])
```

`instructions:` maps to `system_instruction`; `previous_response_id:` maps to
`previous_interaction_id`; `max_output_tokens:` maps into `generation_config`.
Gemini-specific settings remain available through `options:`:

```ruby
gemini.chat("Say hello", instructions: "Be concise.", options: {
  store: false,
  generation_config: { temperature: 0.4 }
})
```

Interactions are stored by default by the provider; `store: false` opts out and
prevents later server-side continuation from that interaction. See Google's
[Interactions guide](https://ai.google.dev/gemini-api/docs/interactions-overview)
and [API reference](https://ai.google.dev/api/interactions-api).

Results use the standard `content`, `response_id`, `status`, `error`, and `raw`
keys. Text is extracted only from `model_output` steps; JSON-looking text is
parsed. `debug: true` retains the complete response, including non-text output,
tool calls, and usage. `requires_action` with valid function calls returns
`tool_calls` without an error. Other non-completed interactions return an error; no tools are
executed automatically. Input/API/transport errors return an error envelope;
constructing a client without a key raises `ArgumentError`.

Use `chat_stream` for streaming; `chat` rejects
`stream: true`. Both methods reject `background: true` before sending a request.
Legacy `AiLite` entry points still use OpenAI.

### Gemini embeddings

`embed` mirrors OpenAI's text input and return shape: a string returns one numeric
vector in `content`; an array returns a list of vectors in input order, including
an array containing just one string.

```ruby
gemini = AiLite::Gemini.new
result = gemini.embed("Text to vectorize")
result["content"] # [0.12, -0.34, ...]

gemini.embed(["First text", "Second text"], dimensions: 768)
AiLite::Gemini.embed("Search query", options: { taskType: "RETRIEVAL_QUERY" })
```

The default is `gemini-embedding-001`. Override it with `embedding_model:` in the
constructor, `config.embedding_model`, or `model:` per call. Both bare model IDs
and `models/` prefixes are accepted. Model checks include the embedding model.

Single strings use `embedContent`; arrays use one synchronous `batchEmbedContents`
request. `dimensions:` maps to `outputDimensionality`. Native request fields in
`options:` apply to each input; explicit model, input, and dimensions take precedence.
See Google's [embedding API reference](https://ai.google.dev/api/embeddings).

Gemini returns numeric vectors; `encoding_format:` may be omitted or set to
`"float"`. Other formats return an error envelope. Empty inputs and invalid dimensions
also return errors before making a request. `debug: true` retains the provider
response and any usage metadata in `raw`; `response_id` is `nil` for embeddings.

### Gemini image generation

```ruby
gemini = AiLite::Gemini.new
result = gemini.image("A cat astronaut on the moon", output_path: "tmp/cat.jpg")
result["content"] # Base64 image data, also returned when saving to a file

AiLite::Gemini.image("A mountain landscape", options: {
  response_format: { type: "image", aspect_ratio: "16:9", image_size: "2K" }
})
```

The default image model is `gemini-nano-banana-2.1`. Set `config.image_model`,
pass `image_model:` to the constructor, or override `model:` per call.
Model checks include this setting. Requests use the Interactions API, with native
settings passed through `options:`. Explicit prompt and model take precedence.
Image requests do not inherit the chat output-token limit.

Like OpenAI's `image`, `content` contains the first generated image as base64.
Only image blocks from `model_output` steps are selected. `output_path:` saves
its decoded bytes; the parent directory must already exist. Files retain the
provider's encoding: the filename does not convert the image. Use `debug: true`
to inspect MIME type, additional images, text, and usage in `raw`. Gemini can return
JPEG data even when the output filename ends in `.png`; choose the extension to
match the returned image MIME type. AI Lite does not transcode images.

The initial interface accepts a text prompt, `model:`, `output_path:`, `debug:`,
and `options:`. OpenAI-specific size, quality, background, and output format
keywords are not shared; use Gemini's native `response_format` options as above.
Streaming and background execution are rejected. Failed/incomplete interactions,
missing or invalid image data, and file-write errors return error envelopes.
See Google's [image generation guide](https://ai.google.dev/gemini-api/docs/image-generation).

### Gemini speech

```ruby
gemini = AiLite::Gemini.new
result = gemini.speak("Hello from AI Lite.", output_path: "tmp/hello.wav")
result["content"] # { "path" => "tmp/hello.wav", "bytes" => ..., "format" => "wav" }

AiLite::Gemini.speak("Have a wonderful day!", voice: "Puck",
                    instructions: "Speak warmly and calmly", base64: true)
```

`speak` returns binary audio by default. With `output_path:`, it saves the audio
and returns path, byte count, and format. With `base64: true`, `content` is base64
instead; a supplied output path is still written. Parent directories must exist.

The defaults are `gemini-3.8-flash-tts`, voice `Kore`, and WAV output.
Configure `speech_model` and `speech_voice` globally or in the constructor;
`model:` and `voice:` override them per call. Model checks include the speech model.
`instructions:` supplies speaking style through speech metadata.

`response_format:` accepts `"wav"`, `"pcm"`, `"mulaw"`, or `"alaw"`.
This helper saves decoded provider bytes without transcoding; a filename extension
does not change the encoding. It does not support OpenAI's `speed:` or MP3 output.
See Google's [speech guide](https://ai.google.dev/gemini-api/docs/speech-generation)
for model-specific voices and formats.

Native options remain available, for example:

```ruby
gemini.speak("Hello", response_format: "pcm", options: {
  response_format: { sample_rate: 16000 },
  store: false
})
```

Explicit input, model, voice, and format take precedence. This single-speaker
helper owns `generation_config.speech_config`; any supplied speech configuration
is replaced with the selected voice. Other native generation settings pass through;
the chat output-token limit is not added. Streaming/background requests are rejected.

Only one inline audio block from completed model output is accepted. Missing,
invalid, unsupported, or multiple audio blocks return errors before writing a file.
`debug: true` includes the full provider response in `raw`, including audio and usage.
The standard envelope includes the interaction's `response_id` when available.

### Gemini transcription

```ruby
result = gemini.transcribe("tmp/gemini-speech-test.wav")
result["content"] # Transcript as a string
result["error"]   # nil on success

# Class-level calls work too:
AiLite::Gemini.transcribe("tmp/meeting.mp3")
```

The default model is `gemini-3.5-transcribe`. Set `transcription_model` in
configuration or the constructor, or override it with `model:` per call.
The helper reads a local audio file and sends base64 audio to the Interactions
API. The complete JSON request must be under 20 MB, including base64 overhead
(roughly 15 MB of audio, less any options). Larger requests return an error;
this helper does not upload files through the Files API.

The filename extension selects the MIME type for WAV, MP3, AIFF, AAC, OGG,
FLAC, MPEG, M4A, L16/PCM, Opus, ALAW, MULAW, and WebM. Use `mime_type:` when
needed, including parameters for raw PCM such as `audio/l16;rate=24000`.
Audio is sent as supplied; the gem does not convert formats.

Language detection is automatic. Pass provider-specific settings through `options:`:

```ruby
result = gemini.transcribe(
  "tmp/meeting.wav",
  options: {
    generation_config: {
      transcription_config: { language_codes: ["en-US"] }
    }
  },
  debug: true
)
result["content"] # Plain transcript, even when the spoken text looks like JSON
result["raw"]     # Full provider response, including available annotations
```

See Google's [transcription guide](https://ai.google.dev/gemini-api/docs/transcribe)
for vocabulary hints, speaker labels, timestamps, and their compatibility rules.
Unlike OpenAI's transcription helper, this method does not accept `language:` or
`prompt:`; use native transcription settings instead. Streaming and background
transcription are not supported. Failed or incomplete responses return an error
in the standard envelope.

### Gemini model checks

```ruby
gemini = AiLite::Gemini.new
result = gemini.available_models
puts result["content"] unless result["error"]

gemini.model_available?("gemini-3.8-flash") # true / false / nil on lookup failure
gemini.configured_models                  # Includes chat, embedding, image, speech, and transcription models
gemini.check_configured_models            # Standard envelope containing a report

# All four also work at class level:
AiLite::Gemini.available_models(debug: true)
AiLite::Gemini.model_available?("gemini-3.8-flash")
AiLite::Gemini.configured_models          # No key or network required
AiLite::Gemini.check_configured_models
```

`available_models` follows every page of Gemini's `/v1beta/models` endpoint and
returns unique model IDs in `content`, with the `models/` resource prefix removed.
`model_available?` accepts IDs with or without that prefix, uses exact matching
(no alias resolution), and fetches a fresh complete list. Invalid empty/non-string
IDs raise `ArgumentError`. Lookup errors return `nil`; inspect `available_models`
or `check_configured_models` for error details.

`configured_models` returns a local snapshot of the instance's settings; its
class method reports current Gemini configuration. Currently only `chat` is
configured: `chat_stream` and `youtube` use that same model.

`check_configured_models` fetches the list once across its pages, then returns:

```ruby
result["content"]["chat"]
# { "model" => "gemini-3.8-flash", "usage" => "chat",
#   "available" => true, "error" => nil } # if listed
```

Any failed page makes the entire lookup fail; partial lists are not treated as
complete. Reports use `available: nil` on failure, with both entry-level and
outer errors. `debug: true` includes original page responses in
`raw["pages"]`, preserving model metadata and any received error response.
These methods make only model-list GET requests, never generation requests.
They do not verify free-tier eligibility, quota, endpoint compatibility, or
whether a model is temporarily overloaded. See Google's
[Models API documentation](https://ai.google.dev/api/models).

### YouTube helper

```ruby
result = gemini.youtube(
  "https://www.youtube.com/watch?v=DV69qh0BzoA",
  prompt: "Summarize this video in five bullet points.",
  model: "gemini-3.5-flash-lite"
)
puts result["content"]
warn result["error"] if result["error"]
```

`AiLite::Gemini.youtube(url, prompt: ..., **kwargs)` also works. The helper
validates one HTTPS YouTube video URL and a nonempty prompt, builds native video
and text input, and delegates to `chat`. It accepts the same chat keywords,
including `model:`, `instructions:`, `previous_response_id:`, `max_output_tokens:`,
`debug:`, and `options:`, and returns the same envelope.

Supported URL forms are `youtube.com/watch?v=...` (including `www` and `m`),
`youtu.be/...`, and YouTube `/shorts/`, `/embed/`, and `/live/` video paths.
URLs, including timestamp parameters, pass through unchanged. Validation checks
URL shape and video ID, not whether the video is public or accessible to Gemini.
The helper builds the same request as this explicit input:

```ruby
gemini.chat([
  { type: "video", uri: url },
  { type: "text", text: "Summarize this video." }
])
# Equivalent convenience call:
gemini.youtube(url, prompt: "Summarize this video.")
```

Invalid URLs/prompts return an error envelope without a network request. No video
is downloaded locally. Gemini controls video support, limits, and processing.

For streaming, pass the video and text blocks directly to `chat_stream`; the
`youtube` helper itself uses non-streaming `chat`.

### Gemini streaming

```ruby
result = gemini.chat_stream("Tell me a short story", debug: true) do |text|
  print text
  $stdout.flush
end
puts
warn result["error"] if result["error"]

# Class-level calls also work:
AiLite::Gemini.chat_stream("Hello") { |text| print text }
```

`chat_stream` accepts the same input and keywords as `chat` and requires a block.
It yields model-output text fragments as they arrive, excluding reasoning and
other non-text events, and returns the standard envelope with the accumulated
answer and interaction ID. JSON-looking final text is parsed just like `chat`.
It runs in the calling thread without creating background threads.

Gemini's final streaming event may contain only partial interaction metadata.
With `debug: true`, `raw` therefore contains `{ "interaction" => ..., "events" => [...] }`:
the latest lifecycle interaction object and every received event, including tool,
reasoning, and usage events when provided. This differs from non-streaming `chat`,
whose `raw` is the complete HTTP response. No extra retrieval request is made;
retaining all events uses additional memory. Without debugging, `raw` is `nil`.

HTTP errors, malformed/disconnected streams, and incomplete or failed interactions
return an error envelope, retaining partial text when available. Always check
`error`, even with HTTP status `200`. Missing blocks raise `ArgumentError`, and
exceptions from your block propagate. The configured timeout applies to each
network read, not the total stream duration. See Google's
[streaming event reference](https://ai.google.dev/api/interactions-api#InteractionSseStreamEvent).

The remaining usage sections below describe the OpenAI provider.

## Usage

```ruby
require "ai_lite"

ai = AiLite::OpenAI.new
result = ai.chat("Say hello")

puts result["content"]
```

By default, the client looks for an API key in `OPENAI_API_KEY`, then falls back to `OPEN_AI_TOKEN`.

You can also pass the key directly:

```ruby
ai = AiLite::OpenAI.new(api_key: "sk-...")
```

## Configuration

In Rails, configure the default client from an initializer:

```ruby
# config/initializers/ai_lite.rb
AiLite::OpenAI.configure do |config|
  config.api_key = ENV["OPENAI_API_KEY"]
  config.model = "gpt-5.5"
  config.moderation_model = "omni-moderation-latest"
  config.embedding_model = "text-embedding-3-small"
  config.image_model = "gpt-image-2"
  config.speech_model = "gpt-4o-mini-tts"
  config.speech_voice = "alloy"
  config.transcription_model = "gpt-transcribe"
  config.timeout = 120
  config.max_output_tokens = 2000
end
```

Any value left unset falls back to AI Lite's default:

- `model`: `gpt-5.5`
- `moderation_model`: `omni-moderation-latest`
- `embedding_model`: `text-embedding-3-small`
- `image_model`: `gpt-image-2`
- `speech_model`: `gpt-4o-mini-tts`
- `speech_voice`: `alloy`
- `transcription_model`: `gpt-transcribe`
- `timeout`: `120`
- `max_output_tokens`: `2000`

`timeout` is applied to both the HTTP connection timeout and the HTTP read timeout.

Then use the configured singleton-style client:

```ruby
result = AiLite::OpenAI.chat("Say hello")
```

You can still instantiate a separate client for another token:

```ruby
client = AiLite::OpenAI.new(api_key: "sk-other-token")
result = client.chat("Say hello")
```

## Migrating to provider namespaces

Use `AiLite::OpenAI` for OpenAI configuration, class methods, and instances.
OpenAI owns its API URLs, defaults, configuration, HTTP requests, and response handling.
Gemini has its own configuration, requests, and response handling; provider capabilities are implemented separately.

Existing `AiLite.new`, `AiLite.chat`, and the other top-level methods continue to
forward to OpenAI, sharing the same configuration and cached client. They emit a
deprecation warning to stderr once per legacy entry point per process. They will
remain available throughout v1.x and will be removed in v2.0.

```ruby
# Before
AiLite.configure { |config| config.api_key = ENV["OPENAI_API_KEY"] }
ai = AiLite.new

# After
AiLite::OpenAI.configure { |config| config.api_key = ENV["OPENAI_API_KEY"] }
ai = AiLite::OpenAI.new
# Class methods work too: AiLite::OpenAI.chat("Hello")
```

`AiLite.new` returns an `AiLite::OpenAI` instance. Compatibility covers documented
construction, configuration, utility methods, and constants; subclassing the legacy
`AiLite` class or relying on its exact instance class is not supported. Migrate such
code to `AiLite::OpenAI`.

Existing utility calls keep their methods and result envelopes. Legacy
constants such as `AiLite::DEFAULT_MODEL` and `AiLite::Configuration` remain
aliases for their OpenAI counterparts. The gem version stays at `AiLite::VERSION`.

## Chat

```ruby
result = ai.chat(
  "Return JSON confirming whether this is valid.",
  instructions: "Return only minified JSON.",
  max_output_tokens: 500,
  options: {
    text: { verbosity: "low" }
  }
)
```

`chat` sends a `POST` request to `/v1/responses` with:

- `model`
- `input`
- `max_output_tokens`
- optional `instructions`
- optional `previous_response_id`
- optional `debug`
- optional extra `options`

The default model is `gpt-5.5`.

The OpenAI API URL is fixed to `https://api.openai.com/v1/responses`.

### Message-Array Input

For a conversation with multiple input messages, pass an array using the OpenAI Responses API message shape:

```ruby
result = ai.chat([
  { role: "developer", content: "Be concise." },
  { role: "user", content: "Explain dependency injection." }
])
```

AI Lite sends the array unchanged as `input`, so you can also use richer Responses API content items when needed.

### Multi-Turn Chat

Responses include a `response_id`. Pass it to the next call as `previous_response_id` to continue the conversation:

```ruby
first = ai.chat("Tell me a short joke.")

follow_up = ai.chat(
  "Explain why that is funny.",
  previous_response_id: first["response_id"]
)

puts follow_up["content"]
```

Passing `previous_response_id` through `options` remains supported for backward compatibility.

### Streaming Chat

Use `chat_stream` to receive text as it arrives. It accepts the same keywords as
`chat`, requires a block, and returns the usual result envelope when the stream
finishes.

```ruby
ai = AiLite::OpenAI.new

result = ai.chat_stream("Explain Ruby blocks in three sentences.") do |text|
  print text
  $stdout.flush
end
puts

warn result["error"] if result["error"]
# result["content"] contains the final answer.
# result["response_id"] can be passed as previous_response_id on the next call.
```

Class-level usage is also supported:

```ruby
AiLite::OpenAI.chat_stream("Say hello") { |text| print text }
```

The block receives text strings, which are not necessarily whole words or tokens.
JSON-looking final output is parsed in the returned `content`, just like `chat`;
the block still receives the original text fragments. With `debug: true`, `raw`
contains the terminal response object (or the available error/last event on failure),
not a history of every streaming event. Tool arguments, reasoning, and refusal
events are not yielded as text; the terminal response retains these outputs in
`raw` when debugging. See the [OpenAI streaming event reference](https://developers.openai.com/api/reference/resources/responses/streaming-events).

Always check `result["error"]`: failed, incomplete, malformed, or disconnected
streams return an error, retaining text already received when available. An HTTP
status of `200` alone does not mean generation completed successfully. Exceptions
raised by your block propagate to the caller; calling without a block raises
`ArgumentError` before making a request.

Streaming runs in the calling thread and creates no worker threads. In Rails,
forwarding chunks to a browser still requires an appropriate streaming response
or messaging mechanism in the application. The configured read timeout applies
to individual network reads, not to the total generation duration.

## Moderation

Use `moderate` to classify user-submitted text or images for potentially harmful content before saving, publishing, or sending it into another AI call.

A common use case is checking a comment before it is shown publicly:

```ruby
comment = "User submitted comment"
result = ai.moderate(comment)

if result["content"]["flagged"]
  # hide, block, or route the comment to review
else
  # publish the comment
end
```

Moderation responses include an overall `flagged` value plus category booleans and scores:

```ruby
{
  "content" => {
    "flagged" => false,
    "categories" => {
      "hate" => false,
      "violence" => false
    },
    "category_scores" => {
      "hate" => 0.01,
      "violence" => 0.02
    }
  },
  "response_id" => "modr_...",
  "status" => 200,
  "error" => nil,
  "raw" => nil
}
```

`moderate` sends a `POST` request to `/v1/moderations` with:

- `model`
- `input`
- optional extra `options`

The default moderation model is `omni-moderation-latest`.

You can pass an image URL:

```ruby
result = ai.moderate(
  text: "Profile caption",
  image_url: "https://example.com/image.png"
)
```

Or a local image path:

```ruby
result = ai.moderate(image_path: "tmp/upload.png")
```

Local images are read, base64 encoded, and sent as JSON data URLs. They do not use multipart uploads. Supported local image extensions are `.gif`, `.jpeg`, `.jpg`, `.png`, and `.webp`.

You can also pass OpenAI's raw moderation input shape directly:

```ruby
result = ai.moderate([
  { type: "text", text: "Caption" },
  {
    type: "image_url",
    image_url: {
      url: "https://example.com/image.png"
    }
  }
])
```

## Embeddings

Use `embed` to turn text into vectors that can be stored and compared for semantic search, recommendations, duplicate detection, or retrieval-augmented generation.

```ruby
result = ai.embed("How do I reset my password?")
vector = result["content"]
```

For one string input, `content` is the embedding vector:

```ruby
{
  "content" => [0.012, -0.44, 0.203],
  "response_id" => nil,
  "status" => 200,
  "error" => nil,
  "raw" => nil
}
```

For multiple inputs, `content` is an array of vectors in the same order:

```ruby
result = ai.embed([
  "How do I reset my password?",
  "How do I update my billing card?"
])

vectors = result["content"]
first_vector = vectors[0]
```

```ruby
{
  "content" => [
    [0.012, -0.44, 0.203],
    [0.332, 0.021, -0.118]
  ],
  "response_id" => nil,
  "status" => 200,
  "error" => nil,
  "raw" => nil
}
```

`embed` sends a `POST` request to `/v1/embeddings` with:

- `model`
- `input`
- optional `dimensions`
- optional `encoding_format`
- optional `debug`
- optional extra `options`

The default embedding model is `text-embedding-3-small`.

Pass `debug: true` to include the raw OpenAI response, including token usage:

```ruby
result = ai.embed("Hello", debug: true)

result["content"]       # embedding vector
result["raw"]["usage"]  # token usage
```

## Images

Use `image` to generate an image from a prompt.

```ruby
result = ai.image("A clean Ruby gem logo on a white background")
image_data = result["content"]
```

By default, `content` is the base64-encoded generated image:

```ruby
{
  "content" => "iVBORw0KGgo...",
  "response_id" => nil,
  "status" => 200,
  "error" => nil,
  "raw" => nil
}
```

Write the generated image bytes directly to a file with `output_path`:

```ruby
result = ai.image(
  "A clean Ruby gem logo on a white background",
  output_path: "tmp/logo.png"
)
```

`image` sends a `POST` request to `/v1/images/generations` with:

- `model`
- `prompt`
- optional `size`
- optional `quality`
- optional `background`
- optional `output_format`
- optional `debug`
- optional extra `options`

The default image model is `gpt-image-2`.

Use `output_format` to request `png`, `webp`, or `jpeg` output:

```ruby
result = ai.image(
  "A transparent app icon",
  background: "transparent",
  output_format: "webp",
  output_path: "tmp/icon.webp"
)
```

Pass `debug: true` to include the raw OpenAI response, including usage when returned:

```ruby
result = ai.image("A tiny robot sticker", debug: true)

result["content"]       # base64 image data
result["raw"]["usage"]  # token usage, when returned
```

## Speech

Use `speak` to generate audio from text.

```ruby
result = ai.speak("Hello from AI Lite")
audio_bytes = result["content"]
```

By default, `content` is the raw audio bytes returned by OpenAI:

```ruby
{
  "content" => "...binary audio bytes...",
  "response_id" => nil,
  "status" => 200,
  "error" => nil,
  "raw" => nil
}
```

Write the generated audio directly to a file with `output_path`:

```ruby
result = ai.speak(
  "Hello from AI Lite",
  output_path: "tmp/hello.mp3"
)
```

When `output_path` is used, `content` is file metadata:

```ruby
{
  "content" => {
    "path" => "tmp/hello.mp3",
    "bytes" => 12345,
    "format" => "mp3"
  },
  "response_id" => nil,
  "status" => 200,
  "error" => nil,
  "raw" => nil
}
```

Use `base64: true` when you want text-safe audio data that can be transported in JSON and decoded later:

```ruby
result = ai.speak("Hello from AI Lite", base64: true)

File.binwrite("tmp/hello.mp3", result["content"].unpack1("m0"))
```

`speak` sends a `POST` request to `/v1/audio/speech` with:

- `model`
- `input`
- `voice`
- optional `response_format`
- optional `speed`
- optional `instructions`
- optional `debug`
- optional extra `options`

The default speech model is `gpt-4o-mini-tts`.
The default speech voice is `alloy`.
The default response format is `mp3`.

For the current list of built-in voices and model-specific voice support, see
[OpenAI's text-to-speech guide](https://developers.openai.com/api/docs/guides/text-to-speech).
AI Lite does not expose an OpenAI `available_voices` method.

Set `voice` per call when you want a different built-in voice:

```ruby
result = ai.speak(
  "Hello from AI Lite",
  voice: "sage",
  output_path: "tmp/hello.mp3"
)
```

Use `response_format` to request `mp3`, `opus`, `aac`, `flac`, `wav`, or `pcm` output:

```ruby
result = ai.speak(
  "Export this as a WAV file",
  response_format: "wav",
  output_path: "tmp/hello.wav"
)
```

## Transcription

Use `transcribe` to turn an audio file into text.

```ruby
result = ai.transcribe("tmp/meeting.mp3")

puts result["content"]
```

By default, `content` is the transcript text:

```ruby
{
  "content" => "Welcome everyone, let's get started.",
  "response_id" => nil,
  "status" => 200,
  "error" => nil,
  "raw" => nil
}
```

`transcribe` sends a multipart `POST` request to `/v1/audio/transcriptions` with:

- `file`
- `model`
- optional `language`
- optional `prompt`
- optional `response_format`
- optional `temperature`
- optional `timestamp_granularities`
- optional `debug`
- optional extra `options`

The default transcription model is `gpt-transcribe`.

Supported local audio extensions are `.flac`, `.m4a`, `.mp3`, `.mp4`, `.mpeg`, `.mpga`, `.ogg`, `.wav`, and `.webm`.

Pass `language` in ISO-639-1 format when you know the input language:

```ruby
result = ai.transcribe(
  "tmp/meeting.mp3",
  language: "en"
)
```

Use `prompt` to provide words, names, or style context that may help the transcription:

```ruby
result = ai.transcribe(
  "tmp/support-call.mp3",
  prompt: "The speakers may mention AI Lite, RubyGems, and Net::HTTP."
)
```

Pass `debug: true` to include the raw OpenAI response:

```ruby
result = ai.transcribe("tmp/meeting.mp3", debug: true)

result["content"]  # transcript text
result["raw"]      # full response body when available
```

## Model Availability

These helpers are implemented inside the OpenAI provider. Instance and class-level
calls are supported; class-level network calls use the configured OpenAI client.

```ruby
ai = AiLite::OpenAI.new

result = ai.available_models
if result["error"]
  warn result["error"]
else
  puts result["content"] # Array of exact model IDs
end

ai.model_available?("gpt-5.5") # true, false, or nil if the lookup failed
AiLite::OpenAI.available_models(debug: true) # raw includes the full model list
```

`available_models` makes one authenticated `GET /v1/models` request and returns
the standard envelope. Empty model lists are valid. `model_available?` makes a
fresh list request and compares the exact ID, without prefix or alias matching.
It returns `nil` on a lookup error; use `available_models` or
`check_configured_models` when you need the error details. Empty or non-string
IDs raise `ArgumentError`. As with other network methods, constructing a client
without an API key raises `ArgumentError`.

Inspect configured models locally:

```ruby
ai.configured_models
# => { "chat" => "gpt-5.5", "moderation" => "omni-moderation-latest",
#      "embedding" => "text-embedding-3-small", "image" => "gpt-image-2",
#      "speech" => "gpt-4o-mini-tts", "transcription" => "gpt-transcribe" }

AiLite::OpenAI.configured_models # No API key or network request required
```

`configured_models` returns a plain hash of usage names to model IDs. An instance
reports its own settings, including constructor overrides; the class method
reports the current provider configuration. Neither includes credentials.

Check all configured models with a single list request:

```ruby
result = ai.check_configured_models
result["content"]["chat"]
# => { "model" => "gpt-5.5", "usage" => "chat",
#      "available" => true, "error" => nil } # if listed for this key

warn result["error"] if result["error"]
```

Each usage has a report entry. A successful lookup returns `available: true` or
`false`; lookup failures return `available: nil`, an entry-level error, and the
same error in the outer envelope. `debug: true` includes the original list or
error response in `raw`. Network checks use the client's configured timeout and
do not cache results or run automatically during initialization.

**These are model-list availability checks only.** They do not run chat, image,
speech, embedding, moderation, or transcription generation requests and create
no generated output. A listed model does not guarantee endpoint compatibility,
sufficient quota, or permission for every operation. See the
[OpenAI List models reference](https://developers.openai.com/api/reference/resources/models/methods/list).

## Return Shape

Generation methods, `available_models`, and `check_configured_models` return a hash envelope.
`configured_models` returns a plain hash; `model_available?` returns `true`, `false`, or `nil`.

Text output:

```ruby
{
  "content" => "Hello!",
  "response_id" => "resp_...",
  "status" => 200,
  "error" => nil,
  "raw" => nil
}
```

JSON-looking model output:

```ruby
{
  "content" => { "valid" => true },
  "response_id" => "resp_...",
  "status" => 200,
  "error" => nil,
  "raw" => nil
}
```

Failure:

```ruby
{
  "content" => nil,
  "response_id" => nil,
  "status" => 401,
  "error" => "Invalid API key",
  "raw" => nil
}
```

Pass `debug: true` to include the raw OpenAI response:

```ruby
result = ai.chat("Say hello", debug: true)

{
  "content" => "Hello!",
  "response_id" => "resp_...",
  "status" => 200,
  "error" => nil,
  "raw" => { ... }
}
```

## Development

Compatibility CI runs the full suite on Ruby 2.6, 2.7, 3.0, 3.1, 3.2, 3.3,
3.4, and 4.0. Tests include building and installing the gem in isolation and
loading both providers without third-party runtime gems. These are Ruby tests;
they do not constitute a Rails integration matrix.

Install the test dependency (not a runtime dependency):

```sh
# Ruby 2.6–3.4
gem install minitest --version 5.15.0 --no-document
# Ruby 4.0
gem install minitest --version 5.27.0 --no-document
```

Run the test suite from the repository root:

```sh
ruby -Ilib:test test/run.rb
```

# AI Lite

AI Lite is a pure Ruby, dependency-light client for simple OpenAI API calls.

It is built for Rails apps and plain Ruby projects where installing a full OpenAI SDK is too heavy, incompatible, or unnecessary. It is especially useful in legacy Rails apps where Rails, ActiveSupport, Ruby, or HTTP-client dependency constraints make larger client libraries difficult to add.

Use AI Lite when you want a small OpenAI client that works without tying your app to a specific Rails version or a larger dependency stack.

This gem is intentionally small:

- No Rails dependency
- No official OpenAI gem dependency
- No Faraday, HTTParty, ActiveSupport, or connection pool dependency
- Uses only Ruby stdlib: `Net::HTTP`, `URI`, `JSON`, `Base64`, and `SecureRandom`

It is not meant to replace the official OpenAI SDK. It is a small wrapper for projects that only need a few clean interfaces:

```ruby
ai.chat("Say hello")
ai.moderate("User submitted text")
ai.embed("Text to vectorize")
ai.image("A simple app icon")
ai.speak("Read this aloud")
ai.transcribe("tmp/meeting.mp3")
```

## Usage

```ruby
require "ai_lite"

ai = AiLite.new
result = ai.chat("Say hello")

puts result["content"]
```

By default, the client looks for an API key in `OPENAI_API_KEY`, then falls back to `OPEN_AI_TOKEN`.

You can also pass the key directly:

```ruby
ai = AiLite.new(api_key: "sk-...")
```

## Configuration

In Rails, configure the default client from an initializer:

```ruby
# config/initializers/ai_lite.rb
AiLite.configure do |config|
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
result = AiLite.chat("Say hello")
```

You can still instantiate a separate client for another token:

```ruby
client = AiLite.new(api_key: "sk-other-token")
result = client.chat("Say hello")
```

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
- optional `debug`
- optional extra `options`

The default model is `gpt-5.5`.

The OpenAI API URL is fixed to `https://api.openai.com/v1/responses`.

### Multi-Turn Chat

Responses include a `response_id` that can be passed back through `options` as `previous_response_id`:

```ruby
first = ai.chat("Tell me a short joke.")

follow_up = ai.chat(
  "Explain why that is funny.",
  options: {
    previous_response_id: first["response_id"]
  }
)

puts follow_up["content"]
```

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

File.binwrite("tmp/hello.mp3", Base64.decode64(result["content"]))
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

## Return Shape

Methods return a hash envelope.

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

Run the test suite:

```sh
ruby -Ilib:test test/ai_lite_test.rb
```

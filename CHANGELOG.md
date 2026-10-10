# Changelog

## 1.0.0 (unreleased)

- Introduce independent `AiLite::OpenAI` and `AiLite::Gemini` providers.
- Preserve documented legacy OpenAI entry points through `AiLite`, with deprecation
  warnings once per entry point per process. Removal is planned for v2.0.
- Add OpenAI and Gemini text streaming through `chat_stream`.
- Add `available_models`, `model_available?`, `configured_models`, and
  `check_configured_models` to both providers; Gemini discovery follows all pages.
- Add Gemini chat with native structured media input and interaction continuation,
  plus a YouTube URL helper. Existing OpenAI utility methods remain available.
- Document model-list limitations, provider-specific debug output, and migration.
- Treat failed/incomplete OpenAI generations as errors even when HTTP status is 200.
- Handle fragmented UTF-8 and mixed SSE line endings in both stream parsers.

Gemini embeddings, image generation, speech, file transcription, additional
providers, and async convenience methods are deferred beyond v1.

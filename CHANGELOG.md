# Changelog

## 1.2.0 (2026-11-02)

- Add `tools:` and `tool_results:` to OpenAI and Gemini chat and streaming,
  normalized function calls, and manual tool-result continuation. Gemini
  interactions awaiting valid function results are no longer reported as errors.

- Add `count_tokens` for OpenAI and Gemini using provider counting APIs, with
  integer results, instructions, native inputs/options, and no tokenizer dependency.
- Add Gemini `transcribe` for local audio files using `gemini-3.5-transcribe`,
  with inline size validation, native options, configuration, and model checks.
- Add Gemini single-speaker speech with voice/style controls, WAV and raw audio
  formats, binary/base64/file output, speech configuration, and model checks.
- Preserve dependency-free loading on newer Ruby versions by using built-in
  base64 packing/unpacking instead of requiring the separately packaged library.
- Expand Ruby compatibility CI to Ruby 2.6, 2.7, 3.0, 3.1, 3.2, 3.3, 3.4, and
  4.0, and test isolated gem installation/loading.

## 1.1.0

- Add Gemini image generation with base64 results, optional file output, native
  options, image model configuration, and model checks.
- Add Gemini text embeddings for single and multiple inputs, with dimensions,
  embedding model configuration, model checks, and the standard result envelope.

## 1.0.0

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

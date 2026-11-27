# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Workload Identity Federation: `WorkloadIdentityConfig` is accepted in the `auth` parameter of `ModelProvider` and `EmbeddingProvider`. An identity token from an external identity provider is exchanged for a short-lived access token at the Google Cloud Security Token Service, optionally followed by service account impersonation, and the access token is cached until it is about to expire.
- `ModelProvider` client class implementing `ai:ModelProvider` interface for LLM chat and structured content generation via Google Vertex AI, supporting Google Gemini models and partner models (Anthropic Claude, Mistral, Meta Llama, DeepSeek, Qwen, Kimi, MiniMax) through Vertex AI Model Garden.
- `EmbeddingProvider` client class implementing `ai:EmbeddingProvider` interface for vector embedding generation via Vertex AI embedding models.

### Fixed
- `generate()` returns the error when a service account access token cannot be obtained, instead of sending the request without a token.

[Unreleased]: https://github.com/ballerina-platform/module-ballerinax-ai.googleapis.vertex/compare/v1.0.0...HEAD

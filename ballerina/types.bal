// Copyright (c) 2026 WSO2 LLC (http://www.wso2.com).
//
// WSO2 LLC. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

import ballerina/ai;
import ballerina/http;

# Configurations for controlling the behaviours when communicating with a remote HTTP endpoint.
@display {label: "Connection Configuration"}
public type ConnectionConfig record {|

    # The HTTP version understood by the client
    @display {label: "HTTP Version"}
    http:HttpVersion httpVersion = http:HTTP_2_0;

    # Configurations related to HTTP/1.x protocol
    @display {label: "HTTP1 Settings"}
    http:ClientHttp1Settings http1Settings?;

    # Configurations related to HTTP/2 protocol
    @display {label: "HTTP2 Settings"}
    http:ClientHttp2Settings http2Settings?;

    # The maximum time to wait (in seconds) for a response before closing the connection
    @display {label: "Timeout"}
    decimal timeout = 60;

    # The choice of setting `forwarded`/`x-forwarded` header
    @display {label: "Forwarded"}
    string forwarded = "disable";

    # Configurations associated with request pooling
    @display {label: "Pool Configuration"}
    http:PoolConfiguration poolConfig?;

    # HTTP caching related configurations
    @display {label: "Cache Configuration"}
    http:CacheConfig cache?;

    # Specifies the way of handling compression (`accept-encoding`) header
    @display {label: "Compression"}
    http:Compression compression = http:COMPRESSION_AUTO;

    # Configurations associated with the behaviour of the Circuit Breaker
    @display {label: "Circuit Breaker Configuration"}
    http:CircuitBreakerConfig circuitBreaker?;

    # Configurations associated with retrying
    @display {label: "Retry Configuration"}
    http:RetryConfig retryConfig?;

    # Configurations associated with inbound response size limits
    @display {label: "Response Limit Configuration"}
    http:ResponseLimitConfigs responseLimits?;

    # SSL/TLS-related options
    @display {label: "Secure Socket Configuration"}
    http:ClientSecureSocket secureSocket?;

    # Proxy server related options
    @display {label: "Proxy Configuration"}
    http:ProxyConfig proxy?;

    # Enables the inbound payload validation functionality which provided by the constraint package. Enabled by default
    @display {label: "Payload Validation"}
    boolean validation = true;
|};

# Publishers supported on Vertex AI Model Garden.
public enum VERTEX_AI_PUBLISHER {
    GOOGLE = "google",
    ANTHROPIC = "anthropic",
    MISTRAL = "mistralai",
    META = "meta",
    DEEPSEEK_AI = "deepseek-ai",
    QWEN = "qwen",
    KIMI = "kimi",
    MINIMAX = "minimax",
    OPENAI = "openai"
}

# Vertex AI Gemini model names supported by the provider.
public enum VERTEX_AI_MODEL_NAMES {
    GEMINI_2_0_FLASH = "gemini-2.0-flash",
    GEMINI_2_0_FLASH_LITE = "gemini-2.0-flash-lite",
    GEMINI_2_5_PRO = "gemini-2.5-pro-preview-03-25",
    GEMINI_2_5_FLASH = "gemini-2.5-flash-preview-04-17",
    GEMINI_1_5_PRO = "gemini-1.5-pro",
    GEMINI_1_5_FLASH = "gemini-1.5-flash",
    GEMINI_1_5_FLASH_8B = "gemini-1.5-flash-8b"
}

# Anthropic Claude model names available on Vertex AI Model Garden.
# Uses the rawPredict endpoint with the Anthropic Messages API wire format.
public enum ANTHROPIC_ON_VERTEX_MODEL_NAMES {
    CLAUDE_OPUS_4_6 = "claude-opus-4-6",
    CLAUDE_SONNET_4_6 = "claude-sonnet-4-6",
    CLAUDE_SONNET_4 = "claude-sonnet-4@20250514",
    CLAUDE_HAIKU_4_5 = "claude-haiku-4-5@20251001",
    CLAUDE_3_7_SONNET = "claude-3-7-sonnet@20250219",
    CLAUDE_3_5_SONNET_V2 = "claude-3-5-sonnet-v2"
}

# Mistral model names available on Vertex AI Model Garden.
# Uses the rawPredict endpoint with the OpenAI-compatible wire format.
public enum MISTRAL_ON_VERTEX_MODEL_NAMES {
    MISTRAL_MEDIUM_3 = "mistral-medium-3",
    MISTRAL_SMALL_2503 = "mistral-small-2503",
    CODESTRAL_2 = "codestral-2"
}

# Meta Llama model names available on Vertex AI Model Garden.
# Uses the OpenAI-compatible `/endpoints/openapi/chat/completions` endpoint.
public enum META_ON_VERTEX_MODEL_NAMES {
    LLAMA_4_MAVERICK = "llama-4-maverick-17b-128e-instruct-maas",
    LLAMA_4_SCOUT = "llama-4-scout-17b-16e-instruct-maas",
    LLAMA_3_3_70B = "llama-3.3-70b-instruct-maas"
}

# DeepSeek model names available on Vertex AI Model Garden.
# Uses the OpenAI-compatible `/endpoints/openapi/chat/completions` endpoint.
public enum DEEPSEEK_ON_VERTEX_MODEL_NAMES {
    DEEPSEEK_V3 = "deepseek-v3-0324",
    DEEPSEEK_R1 = "deepseek-r1"
}

# Qwen (Alibaba) model names available on Vertex AI Model Garden.
# Uses the OpenAI-compatible `/endpoints/openapi/chat/completions` endpoint.
public enum QWEN_ON_VERTEX_MODEL_NAMES {
    QWEN_3_235B = "qwen3-235b-a22b",
    QWEN_3_32B = "qwen3-32b"
}

# Kimi model names available on Vertex AI Model Garden.
# Uses the OpenAI-compatible `/endpoints/openapi/chat/completions` endpoint.
public enum KIMI_ON_VERTEX_MODEL_NAMES {
    KIMI_K2 = "kimi-k2"
}

# MiniMax model names available on Vertex AI Model Garden.
# Uses the OpenAI-compatible `/endpoints/openapi/chat/completions` endpoint.
public enum MINIMAX_ON_VERTEX_MODEL_NAMES {
    MINIMAX_M2 = "minimax-m2"
}

# OpenAI model names available on Vertex AI Model Garden.
# Uses the OpenAI-compatible `/endpoints/openapi/chat/completions` endpoint.
public enum OPENAI_ON_VERTEX_MODEL_NAMES {
    GPT_OSS_120B = "gpt-oss-120b-maas",
    GPT_OSS_20B = "gpt-oss-20b-maas"
}

# Embedding model names supported by the Vertex AI embedding provider.
public enum VERTEX_AI_EMBEDDING_MODEL_NAMES {
    TEXT_EMBEDDING_005 = "text-embedding-005",
    TEXT_MULTILINGUAL_EMBEDDING_002 = "text-multilingual-embedding-002",
    TEXT_EMBEDDING_004 = "text-embedding-004"
}

// ── Internal Vertex AI API types ──────────────────────────────────────────────

# Represents a single part of a Vertex AI content block.
type VertexAiPart record {
    string text?;
    VertexAiBlob inlineData?;
    VertexAiFunctionCall functionCall?;
    VertexAiFunctionResponse functionResponse?;
};

# Represents inline binary data (e.g., an image encoded in base64).
type VertexAiBlob record {
    string mimeType;
    string data; // base64-encoded
};

# Represents a function call returned by the model.
type VertexAiFunctionCall record {
    string name;
    map<json> args?;
};

# Represents a function response provided to the model.
type VertexAiFunctionResponse record {
    string name;
    map<json> response;
};

# Represents a content object containing a role and one or more parts.
type VertexAiContent record {
    string role;
    VertexAiPart[] parts;
};

# Represents the systemInstruction field in a Vertex AI request.
# The role field is intentionally absent as Vertex AI ignores it for system instructions.
type VertexAiSystemInstruction record {
    VertexAiPart[] parts;
};

# Represents a single function declaration for tool use.
type VertexAiFunctionDeclaration record {
    string name;
    string description;
    map<json> parameters?;
};

# Represents a tool with one or more function declarations.
type VertexAiTool record {
    VertexAiFunctionDeclaration[] functionDeclarations;
};

# Configures the function calling behaviour.
type VertexAiFunctionCallingConfig record {
    string mode; // AUTO, ANY, NONE
    string[] allowedFunctionNames?;
};

# Top-level tool configuration.
type VertexAiToolConfig record {
    VertexAiFunctionCallingConfig functionCallingConfig;
};

# Vertex AI generation configuration parameters.
type VertexAiGenerationConfig record {
    decimal temperature?;
    int maxOutputTokens?;
    string[] stopSequences?;
};

# The full Vertex AI generateContent request body.
type VertexAiRequest record {
    VertexAiContent[] contents;
    VertexAiSystemInstruction systemInstruction?;
    VertexAiTool[] tools?;
    VertexAiToolConfig toolConfig?;
    VertexAiGenerationConfig generationConfig?;
};

# A single candidate in the Vertex AI response.
type VertexAiCandidate record {
    VertexAiContent content?;
    string finishReason?;
    int index?;
};

# Token usage metadata returned in the Vertex AI response.
type VertexAiUsageMetadata record {
    int promptTokenCount?;
    int candidatesTokenCount?;
    int totalTokenCount?;
};

# The full Vertex AI generateContent response body.
type VertexAiResponse record {
    VertexAiCandidate[] candidates?;
    VertexAiUsageMetadata usageMetadata?;
    string responseId?;
    string modelVersion?;
};

# Vertex AI embedContent response.
type VertexAiEmbedResponse record {
    VertexAiEmbedding embedding;
};

# The embedding values returned by Vertex AI.
type VertexAiEmbedding record {
    float[] values;
};

// ── Anthropic on Vertex internal types ────────────────────────────────────────
// Anthropic models on Vertex AI use the rawPredict endpoint with the Anthropic
// Messages API wire format. The version is sent as a request body field instead
// of a header (unlike the direct Anthropic API).

# A single message in the Anthropic Messages API format.
type AnthropicMessage record {
    string role;
    string|AnthropicContentBlock[] content;
};

# A content block in an Anthropic message (text, tool_use, or tool_result).
type AnthropicContentBlock record {
    string 'type;
    string text?;
    string id?;
    string name?;
    json input?;
    string tool_use_id?;
    string content?;
};

# An Anthropic tool definition (uses input_schema instead of parameters).
type AnthropicTool record {
    string name;
    string description;
    map<json> input_schema;
};

# Forces the model to call a specific Anthropic tool.
type AnthropicToolChoice record {
    string 'type;
    string name?;
};

# Token usage information from the Anthropic response.
type AnthropicUsage record {
    int input_tokens?;
    int output_tokens?;
};

# The Anthropic rawPredict response body.
type AnthropicResponse record {
    string id?;
    AnthropicContentBlock[] content;
    string stop_reason?;
    AnthropicUsage usage?;
};

// ── Mistral on Vertex internal types ──────────────────────────────────────────
// Mistral models on Vertex AI use the rawPredict endpoint with an
// OpenAI-compatible wire format. The model name is sent in the request body.

# A single message in the Mistral/OpenAI-compatible format.
type MistralMessage record {
    string role;
    string? content?;
    string? tool_call_id?;
    MistralToolCall[]? tool_calls?;
};

# A tool call entry in a Mistral assistant message.
type MistralToolCall record {
    string id?;
    string 'type?;
    MistralFunction 'function;
};

# The function name and JSON-encoded arguments from a Mistral tool call.
type MistralFunction record {
    string name;
    string arguments;
};

# A Mistral tool definition (OpenAI-compatible function format).
type MistralTool record {
    string 'type = "function";
    MistralFunctionDeclaration 'function;
};

# The function declaration inside a Mistral tool.
type MistralFunctionDeclaration record {
    string name;
    string description;
    map<json> parameters?;
};

# A single candidate choice in the Mistral response.
type MistralChoice record {
    int index?;
    MistralMessage message;
    string? finish_reason?;
};

# Token usage information from the Mistral response.
type MistralUsage record {
    int prompt_tokens?;
    int completion_tokens?;
};

# The Mistral rawPredict response body.
type MistralResponse record {
    string id?;
    MistralChoice[] choices;
    MistralUsage usage?;
};

// ── Internal result type ───────────────────────────────────────────────────────

# Carries the chat assistant message alongside the token-usage metadata from
# the raw provider response, so that chat() can update the observability span
# after dispatch without requiring each publisher path to hold a span reference.
type ChatResult record {|
    ai:ChatAssistantMessage message;
    string responseId;
    int? inputTokens;
    int? outputTokens;
|};

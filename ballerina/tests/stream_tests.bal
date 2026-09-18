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
import ballerina/test;

// ── Streaming test suite ────────────────────────────────────────────────────
// Exercises chatAsStream() and generateAsStream() against the mock SSE services in
// stream_test_services.bal, covering all four publisher wire formats this
// module supports: Gemini (native), Anthropic (Messages API events), Mistral
// (OpenAI-compatible chunks via rawPredict), and the shared open-models
// endpoint (OpenAI-compatible chunks, DeepSeek used as the representative
// publisher). Each publisher is checked for: incremental text streaming,
// `role` present on every chunk, finish-reason mapping, tool-call
// id/name/argument-fragment streaming (accumulated by index, matching how a
// real agent loop would consume it), reasoning/thinking streaming where the
// wire format supports it, and the generateAsStream text projection.

const GEMINI_STREAM_TEXT_URL = "http://localhost:8090/llm/vertexai";
const GEMINI_STREAM_TOOL_URL = "http://localhost:8094/llm/vertexai";
const ANTHROPIC_STREAM_TEXT_URL = "http://localhost:8091/llm/vertexai";
const ANTHROPIC_STREAM_TOOL_URL = "http://localhost:8095/llm/vertexai";
const MISTRAL_STREAM_TEXT_URL = "http://localhost:8092/llm/vertexai";
const MISTRAL_STREAM_TOOL_URL = "http://localhost:8096/llm/vertexai";
const OPEN_MODEL_STREAM_TEXT_URL = "http://localhost:8093/llm/vertexai";
const ANTHROPIC_STREAM_REASONING_URL = "http://localhost:8103/llm/vertexai";
const OPEN_MODEL_STREAM_REASONING_URL = "http://localhost:8104/llm/vertexai";

ModelProvider? geminiStreamTextProvider = ();
ModelProvider? geminiStreamToolProvider = ();
ModelProvider? anthropicStreamTextProvider = ();
ModelProvider? anthropicStreamToolProvider = ();
ModelProvider? anthropicStreamReasoningProvider = ();
ModelProvider? mistralStreamTextProvider = ();
ModelProvider? mistralStreamToolProvider = ();
ModelProvider? openModelStreamTextProvider = ();
ModelProvider? openModelStreamReasoningProvider = ();

@test:BeforeSuite
function initStreamProviders() returns error? {
    geminiStreamTextProvider = check new (TEST_AUTH, PROJECT_ID, GEMINI_2_0_FLASH, LOCATION, GEMINI_STREAM_TEXT_URL);
    geminiStreamToolProvider = check new (TEST_AUTH, PROJECT_ID, GEMINI_2_0_FLASH, LOCATION, GEMINI_STREAM_TOOL_URL);
    anthropicStreamTextProvider =
        check new (TEST_AUTH, PROJECT_ID, "anthropic/claude-test-model", LOCATION, ANTHROPIC_STREAM_TEXT_URL);
    anthropicStreamToolProvider =
        check new (TEST_AUTH, PROJECT_ID, "anthropic/claude-test-model", LOCATION, ANTHROPIC_STREAM_TOOL_URL);
    anthropicStreamReasoningProvider =
        check new (TEST_AUTH, PROJECT_ID, "anthropic/claude-test-model", LOCATION, ANTHROPIC_STREAM_REASONING_URL);
    mistralStreamTextProvider =
        check new (TEST_AUTH, PROJECT_ID, "mistralai/mistral-test-model", LOCATION, MISTRAL_STREAM_TEXT_URL);
    mistralStreamToolProvider =
        check new (TEST_AUTH, PROJECT_ID, "mistralai/mistral-test-model", LOCATION, MISTRAL_STREAM_TOOL_URL);
    openModelStreamTextProvider =
        check new (TEST_AUTH, PROJECT_ID, "deepseek-ai/deepseek-test-model", LOCATION, OPEN_MODEL_STREAM_TEXT_URL);
    openModelStreamReasoningProvider = check new (TEST_AUTH, PROJECT_ID, "deepseek-ai/deepseek-test-model", LOCATION,
        OPEN_MODEL_STREAM_REASONING_URL);
}

// ── Shared stream-collection helpers ────────────────────────────────────────

type AccumulatedToolCall record {|
    string id = "";
    string name = "";
    string args = "";
|};

type StreamResult record {|
    string text = "";
    string reasoning = "";
    int chunkCount = 0;
    boolean everyChunkHasAssistantRole = true;
    ai:FinishReason? finishReason = ();
    map<AccumulatedToolCall> toolCalls = {};
|};

final ai:ChatCompletionFunctions WEATHER_TOOL = {
    name: "get_weather",
    description: "Get the current weather for a given city.",
    parameters: {
        "type": "object",
        "properties": {"city": {"type": "string", "description": "The city name, e.g. Colombo"}},
        "required": ["city"]
    }
};

// Drains the stream with explicit `next()` calls rather than a query expression: a
// `check from ... in chunks` pipeline surfaces the *cause* of a stream error instead of
// the error itself, so the `ai:` error type the connector reports would be lost here and
// the failure-path assertions below could not tell one failure from another.
isolated function collectStream(stream<ai:ChatMessageChunk, ai:Error?> chunks) returns StreamResult|ai:Error {
    StreamResult result = {};
    while true {
        record {|ai:ChatMessageChunk value;|}|ai:Error? next = chunks.next();
        if next is () {
            break;
        }
        if next is ai:Error {
            return next;
        }
        ai:ChatMessageChunk chunk = next.value;
        result.chunkCount += 1;
        if chunk.role != ai:ASSISTANT {
            result.everyChunkHasAssistantRole = false;
        }
        string? contentFragment = chunk.content;
        if contentFragment is string {
            result.text += contentFragment;
        }
        string? reasoningFragment = chunk.reasoning;
        if reasoningFragment is string {
            result.reasoning += reasoningFragment;
        }
        ai:FinishReason? reason = chunk.finishReason;
        if reason is ai:FinishReason {
            result.finishReason = reason;
        }
        ai:ToolCallChunk[]? toolCallChunks = chunk.toolCalls;
        if toolCallChunks is ai:ToolCallChunk[] {
            foreach ai:ToolCallChunk tc in toolCallChunks {
                string key = tc.index.toString();
                AccumulatedToolCall acc = result.toolCalls[key] ?: {};
                string? id = tc?.id;
                if id is string {
                    acc.id = id;
                }
                string? name = tc?.name;
                if name is string {
                    acc.name = name;
                }
                string? args = tc?.arguments;
                if args is string {
                    acc.args += args;
                }
                result.toolCalls[key] = acc;
            }
        }
    }
    return result;
}

// Drains the text stream with explicit `next()` calls, for the same reason as
// `collectStream` above: a query expression would replace the reported error with its cause.
isolated function collectText(stream<string, ai:Error?> fragments) returns string|ai:Error {
    string text = "";
    while true {
        record {|string value;|}|ai:Error? next = fragments.next();
        if next is () {
            break;
        }
        if next is ai:Error {
            return next;
        }
        text += next.value;
    }
    return text;
}

// ── Gemini ───────────────────────────────────────────────────────────────────

@test:Config
function testGeminiChatStreamText() returns error? {
    ModelProvider p = <ModelProvider>geminiStreamTextProvider;
    stream<ai:ChatMessageChunk, ai:Error?> chunks = check p->chatAsStream([{role: ai:USER, content: "Say hello"}]);
    StreamResult result = check collectStream(chunks);

    test:assertEquals(result.text, "Hello, world!");
    test:assertEquals(result.finishReason, ai:STOP);
    test:assertTrue(result.everyChunkHasAssistantRole, "role must be ASSISTANT on every chunk");
    test:assertTrue(result.chunkCount >= 3, "expected multiple incremental chunks");
}

@test:Config
function testGeminiChatStreamToolCall() returns error? {
    ModelProvider p = <ModelProvider>geminiStreamToolProvider;
    stream<ai:ChatMessageChunk, ai:Error?> chunks = check p->chatAsStream(
        [{role: ai:USER, content: "What is the weather in Colombo?"}], [WEATHER_TOOL]);
    StreamResult result = check collectStream(chunks);

    test:assertEquals(result.finishReason, ai:TOOL_CALLS);
    test:assertTrue(result.everyChunkHasAssistantRole, "role must be ASSISTANT on every chunk");
    AccumulatedToolCall acc = check getToolCall(result, "0");
    test:assertEquals(acc.name, "get_weather");
    test:assertEquals(check parseArgs(acc.args), {"city": "Colombo"});
}

@test:Config
function testGeminiGenerateStream() returns error? {
    ModelProvider p = <ModelProvider>geminiStreamTextProvider;
    stream<string, ai:Error?> fragments = check p->generateAsStream(`Say hello`);
    test:assertEquals(check collectText(fragments), "Hello, world!");
}

// ── Anthropic ────────────────────────────────────────────────────────────────

@test:Config
function testAnthropicChatStreamText() returns error? {
    ModelProvider p = <ModelProvider>anthropicStreamTextProvider;
    stream<ai:ChatMessageChunk, ai:Error?> chunks = check p->chatAsStream([{role: ai:USER, content: "Say hello"}]);
    StreamResult result = check collectStream(chunks);

    test:assertEquals(result.text, "Hello, world!");
    test:assertEquals(result.finishReason, ai:STOP);
    test:assertTrue(result.everyChunkHasAssistantRole, "role must be ASSISTANT on every chunk");
}

@test:Config
function testAnthropicChatStreamToolCall() returns error? {
    ModelProvider p = <ModelProvider>anthropicStreamToolProvider;
    stream<ai:ChatMessageChunk, ai:Error?> chunks = check p->chatAsStream(
        [{role: ai:USER, content: "What is the weather in Colombo?"}], [WEATHER_TOOL]);
    StreamResult result = check collectStream(chunks);

    test:assertEquals(result.finishReason, ai:TOOL_CALLS);
    test:assertTrue(result.everyChunkHasAssistantRole, "role must be ASSISTANT on every chunk");
    AccumulatedToolCall acc = check getToolCall(result, "0");
    test:assertEquals(acc.id, "toolu_1");
    test:assertEquals(acc.name, "get_weather");
    test:assertEquals(check parseArgs(acc.args), {"city": "Colombo"});
}

@test:Config
function testAnthropicChatStreamReasoning() returns error? {
    ModelProvider p = <ModelProvider>anthropicStreamReasoningProvider;
    stream<ai:ChatMessageChunk, ai:Error?> chunks = check p->chatAsStream([{role: ai:USER, content: "Say hello"}]);
    StreamResult result = check collectStream(chunks);

    test:assertEquals(result.reasoning, "The user wants a greeting.");
    test:assertEquals(result.text, "Hello!");
    test:assertEquals(result.finishReason, ai:STOP);
    test:assertTrue(result.everyChunkHasAssistantRole, "role must be ASSISTANT on every chunk");
}

@test:Config
function testAnthropicGenerateStream() returns error? {
    ModelProvider p = <ModelProvider>anthropicStreamTextProvider;
    stream<string, ai:Error?> fragments = check p->generateAsStream(`Say hello`);
    test:assertEquals(check collectText(fragments), "Hello, world!");
}

// ── Mistral ──────────────────────────────────────────────────────────────────

@test:Config
function testMistralChatStreamText() returns error? {
    ModelProvider p = <ModelProvider>mistralStreamTextProvider;
    stream<ai:ChatMessageChunk, ai:Error?> chunks = check p->chatAsStream([{role: ai:USER, content: "Say hello"}]);
    StreamResult result = check collectStream(chunks);

    test:assertEquals(result.text, "Hello, world!");
    test:assertEquals(result.finishReason, ai:STOP);
    test:assertTrue(result.everyChunkHasAssistantRole, "role must be ASSISTANT on every chunk");
}

@test:Config
function testMistralChatStreamToolCall() returns error? {
    ModelProvider p = <ModelProvider>mistralStreamToolProvider;
    stream<ai:ChatMessageChunk, ai:Error?> chunks = check p->chatAsStream(
        [{role: ai:USER, content: "What is the weather in Colombo?"}], [WEATHER_TOOL]);
    StreamResult result = check collectStream(chunks);

    test:assertEquals(result.finishReason, ai:TOOL_CALLS);
    test:assertTrue(result.everyChunkHasAssistantRole, "role must be ASSISTANT on every chunk");
    AccumulatedToolCall acc = check getToolCall(result, "0");
    test:assertEquals(acc.id, "call_1");
    test:assertEquals(acc.name, "get_weather");
    test:assertEquals(check parseArgs(acc.args), {"city": "Colombo"});
}

@test:Config
function testMistralGenerateStream() returns error? {
    ModelProvider p = <ModelProvider>mistralStreamTextProvider;
    stream<string, ai:Error?> fragments = check p->generateAsStream(`Say hello`);
    test:assertEquals(check collectText(fragments), "Hello, world!");
}

// ── Open-model publishers (Meta/DeepSeek/Qwen/Kimi/MiniMax) ────────────────
// These share both the request path and toAiChunkOpenAiCompat mapping with
// Mistral (see stream_test_services.bal), so only the text and reasoning scenarios
// are covered separately here; tool-call argument streaming through that shared
// mapping is already verified by testMistralChatStreamToolCall above.

@test:Config
function testOpenModelChatStreamText() returns error? {
    ModelProvider p = <ModelProvider>openModelStreamTextProvider;
    stream<ai:ChatMessageChunk, ai:Error?> chunks = check p->chatAsStream([{role: ai:USER, content: "Say hi"}]);
    StreamResult result = check collectStream(chunks);

    test:assertEquals(result.text, "Hi there!");
    test:assertEquals(result.finishReason, ai:STOP);
    test:assertTrue(result.everyChunkHasAssistantRole, "role must be ASSISTANT on every chunk");
}

@test:Config
function testOpenModelChatStreamReasoning() returns error? {
    ModelProvider p = <ModelProvider>openModelStreamReasoningProvider;
    stream<ai:ChatMessageChunk, ai:Error?> chunks = check p->chatAsStream([{role: ai:USER, content: "Say hi"}]);
    StreamResult result = check collectStream(chunks);

    test:assertEquals(result.reasoning, "Thinking it over.");
    test:assertEquals(result.text, "Hi there!");
    test:assertEquals(result.finishReason, ai:STOP);
    test:assertTrue(result.everyChunkHasAssistantRole, "role must be ASSISTANT on every chunk");
}

@test:Config
function testOpenModelGenerateStream() returns error? {
    ModelProvider p = <ModelProvider>openModelStreamTextProvider;
    stream<string, ai:Error?> fragments = check p->generateAsStream(`Say hi`);
    test:assertEquals(check collectText(fragments), "Hi there!");
}

// ── Assertion helpers ────────────────────────────────────────────────────────

isolated function getToolCall(StreamResult result, string index) returns AccumulatedToolCall|error {
    AccumulatedToolCall? acc = result.toolCalls[index];
    if acc is () {
        test:assertFail(string `expected a streamed tool call at index ${index}`);
    }
    return acc;
}

isolated function parseArgs(string args) returns map<json>|error {
    return args.fromJsonStringWithType();
}

// ── Failure paths and edge cases ────────────────────────────────────────────
// The scenarios above all describe a well-behaved endpoint. These cover what the
// happy-path suite cannot see: a rejected request, a generation cut short mid-stream,
// a garbled frame, tool-call indexing across events, and stream closing.

const GEMINI_STREAM_HTTP_ERROR_URL = "http://localhost:8097/llm/vertexai";
const GEMINI_STREAM_MIDSTREAM_ERROR_URL = "http://localhost:8098/llm/vertexai";
const GEMINI_STREAM_MALFORMED_URL = "http://localhost:8099/llm/vertexai";
const GEMINI_STREAM_PARALLEL_TOOL_URL = "http://localhost:8100/llm/vertexai";
const ANTHROPIC_STREAM_ERROR_EVENT_URL = "http://localhost:8101/llm/vertexai";
const OPEN_MODEL_STREAM_USAGE_URL = "http://localhost:8102/llm/vertexai";

// A non-2xx must surface as an error carrying the status and the API's own message.
// The streaming POST binds to `http:Response`, which turns off the client's status-code
// error mapping, so without an explicit check a 429 reads as an empty successful stream.
@test:Config
function testChatStreamSurfacesHttpErrorStatus() returns error? {
    ModelProvider p = check new (TEST_AUTH, PROJECT_ID, GEMINI_2_0_FLASH, LOCATION, GEMINI_STREAM_HTTP_ERROR_URL);
    stream<ai:ChatMessageChunk, ai:Error?>|ai:Error result = p->chatAsStream([{role: ai:USER, content: "Say hello"}]);

    test:assertTrue(result is ai:Error, "a 429 from the model must fail chatAsStream, not open an empty stream");
    if result is ai:Error {
        string message = result.message();
        test:assertTrue(message.includes("429"), "the status code must reach the caller: " + message);
        test:assertTrue(message.includes("Quota exceeded"),
                "the model's own message must reach the caller: " + message);
        test:assertTrue(result is ai:LlmConnectionError, "a rejected streaming request is a connection error");
    }
}

// The same check must guard generateAsStream, which opens the stream through chatAsStream.
@test:Config
function testGenerateStreamSurfacesHttpErrorStatus() returns error? {
    ModelProvider p = check new (TEST_AUTH, PROJECT_ID, GEMINI_2_0_FLASH, LOCATION, GEMINI_STREAM_HTTP_ERROR_URL);
    stream<string, ai:Error?>|ai:Error result = p->generateAsStream(`Say hello`);
    test:assertTrue(result is ai:Error, "a 429 from the model must fail generateAsStream");
}

// An `{"error": ...}` frame arriving mid-generation must fail the stream. Skipping it
// would end iteration normally and hand back "Hello" as if it were the whole answer.
@test:Config
function testGeminiChatStreamFailsOnMidStreamErrorFrame() returns error? {
    ModelProvider p = check new (TEST_AUTH, PROJECT_ID, GEMINI_2_0_FLASH, LOCATION,
        GEMINI_STREAM_MIDSTREAM_ERROR_URL);
    stream<ai:ChatMessageChunk, ai:Error?> chunks = check p->chatAsStream([{role: ai:USER, content: "Say hello"}]);
    StreamResult|ai:Error result = collectStream(chunks);

    test:assertTrue(result is ai:Error, "a mid-stream error frame must not end the stream cleanly");
    if result is ai:Error {
        test:assertTrue(result.message().includes("Resource exhausted mid-generation"),
                "the mid-stream failure detail must reach the caller: " + result.message());
    }
}

// A frame that is not JSON at all is a broken stream, not something to skip past.
@test:Config
function testGeminiChatStreamFailsOnMalformedFrame() returns error? {
    ModelProvider p = check new (TEST_AUTH, PROJECT_ID, GEMINI_2_0_FLASH, LOCATION, GEMINI_STREAM_MALFORMED_URL);
    stream<ai:ChatMessageChunk, ai:Error?> chunks = check p->chatAsStream([{role: ai:USER, content: "Say hello"}]);
    StreamResult|ai:Error result = collectStream(chunks);

    test:assertTrue(result is ai:Error, "a malformed frame must fail the stream");
    if result is ai:Error {
        test:assertTrue(result is ai:LlmInvalidResponseError,
                "a malformed frame is an invalid response: " + result.message());
    }
}

// Anthropic reports mid-stream failures as an `error` event; its `type` is what tells a
// retryable overload apart from a terminal bad request, so both parts must survive.
@test:Config
function testAnthropicChatStreamSurfacesErrorEvent() returns error? {
    ModelProvider p = check new (TEST_AUTH, PROJECT_ID, "anthropic/claude-test-model", LOCATION,
        ANTHROPIC_STREAM_ERROR_EVENT_URL);
    stream<ai:ChatMessageChunk, ai:Error?> chunks = check p->chatAsStream([{role: ai:USER, content: "Say hello"}]);
    StreamResult|ai:Error result = collectStream(chunks);

    test:assertTrue(result is ai:Error, "an Anthropic error event must fail the stream");
    if result is ai:Error {
        string message = result.message();
        test:assertTrue(message.includes("overloaded_error"), "the error type must reach the caller: " + message);
        test:assertTrue(message.includes("Overloaded"), "the error message must reach the caller: " + message);
    }
}

// Two function calls arriving in separate events must get distinct tool-call indices:
// a consumer accumulating by index would otherwise splice their arguments together.
@test:Config
function testGeminiChatStreamIndexesToolCallsAcrossChunks() returns error? {
    ModelProvider p = check new (TEST_AUTH, PROJECT_ID, GEMINI_2_0_FLASH, LOCATION,
        GEMINI_STREAM_PARALLEL_TOOL_URL);
    stream<ai:ChatMessageChunk, ai:Error?> chunks = check p->chatAsStream(
        [{role: ai:USER, content: "Weather in Colombo and Kandy?"}], [WEATHER_TOOL]);
    StreamResult result = check collectStream(chunks);

    test:assertEquals(result.toolCalls.length(), 2, "each function call needs its own index");
    AccumulatedToolCall first = check getToolCall(result, "0");
    AccumulatedToolCall second = check getToolCall(result, "1");
    test:assertEquals(check parseArgs(first.args), {"city": "Colombo"});
    test:assertEquals(check parseArgs(second.args), {"city": "Kandy"});
}

// A usage-only final chunk carries no choices; it must be skipped (not mapped to an empty
// chunk), while the text that arrived before it still comes through untouched.
@test:Config
function testOpenModelChatStreamSkipsUsageOnlyChunk() returns error? {
    ModelProvider p = check new (TEST_AUTH, PROJECT_ID, "deepseek-ai/deepseek-test-model", LOCATION,
        OPEN_MODEL_STREAM_USAGE_URL);
    stream<ai:ChatMessageChunk, ai:Error?> chunks = check p->chatAsStream([{role: ai:USER, content: "Say hi"}]);
    StreamResult result = check collectStream(chunks);

    test:assertEquals(result.text, "Hi there!");
    test:assertEquals(result.finishReason, ai:STOP);
    test:assertTrue(result.everyChunkHasAssistantRole, "role must be ASSISTANT on every chunk");
}

// Closing the chunk stream must close the underlying SSE stream and release its
// connection, and must stay safe to call after the stream has already ended.
@test:Config
function testChatStreamCloseReleasesTheStream() returns error? {
    ModelProvider p = <ModelProvider>geminiStreamTextProvider;
    stream<ai:ChatMessageChunk, ai:Error?> chunks = check p->chatAsStream([{role: ai:USER, content: "Say hello"}]);
    record {|ai:ChatMessageChunk value;|}|ai:Error? first = chunks.next();
    test:assertTrue(first is record {|ai:ChatMessageChunk value;|}, "expected a first chunk");

    check chunks.close();
    check chunks.close();
}

// generateAsStream's text projection wraps the chunk stream, so closing it has to reach
// through to the chat stream underneath rather than stopping at the wrapper.
@test:Config
function testGenerateStreamCloseReleasesTheStream() returns error? {
    ModelProvider p = <ModelProvider>geminiStreamTextProvider;
    stream<string, ai:Error?> fragments = check p->generateAsStream(`Say hello`);
    record {|string value;|}|ai:Error? first = fragments.next();
    test:assertTrue(first is record {|string value;|}, "expected a first text fragment");

    check fragments.close();
}

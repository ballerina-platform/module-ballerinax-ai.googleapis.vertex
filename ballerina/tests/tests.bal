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

// Service URLs used for the mock services defined in test_services.bal
const GENERATE_SERVICE_URL = "http://localhost:8080/llm/vertexai";
const CHAT_SERVICE_URL = "http://localhost:8081/llm/vertexai";
const EMBED_SERVICE_URL = "http://localhost:8082/llm/vertexai";

const ACCESS_TOKEN = "not-a-real-access-token";
const PROJECT_ID = "test-project";
const LOCATION = "us-central1";

// ── Shared providers ──────────────────────────────────────────────────────────

final ModelProvider provider = check new (ACCESS_TOKEN, PROJECT_ID, GEMINI_2_0_FLASH, LOCATION, GENERATE_SERVICE_URL);

// ── generate() tests ──────────────────────────────────────────────────────────

@test:Config
function testGenerateMethodWithBasicReturnType() returns ai:Error? {
    int|error rating = provider->generate(`Rate this blog out of 10.
        Title: ${blog1.title}
        Content: ${blog1.content}`);
    test:assertEquals(rating, 4);
}

@test:Config
function testGenerateMethodWithBasicArrayReturnType() returns ai:Error? {
    int[]|error rating = provider->generate(`Evaluate this blogs out of 10.
        Title: ${blog1.title}
        Content: ${blog1.content}

        Title: ${blog1.title}
        Content: ${blog1.content}`);
    test:assertEquals(rating, [9, 1]);
}

@test:Config
function testGenerateMethodWithRecordReturnType() returns error? {
    Review|error result = provider->generate(`Please rate this blog out of ${"10"}.
        Title: ${blog2.title}
        Content: ${blog2.content}`);
    test:assertEquals(result, check review.fromJsonStringWithType(Review));
}

@test:Config
function testGenerateMethodWithTextDocument() returns ai:Error? {
    ai:TextDocument blog = {
        content: string `Title: ${blog1.title} Content: ${blog1.content}`
    };
    int maxScore = 10;

    int|error rating = provider->generate(`How would you rate this ${"blog"} content out of ${maxScore}. ${blog}.`);
    test:assertEquals(rating, 4);
}

@test:Config
function testGenerateMethodWithStringUnionNull() returns error? {
    string? result = check provider->generate(`Give me a random joke`);
    test:assertTrue(result is string);
}

// ── chat() tests ──────────────────────────────────────────────────────────────

final ai:ChatCompletionFunctions getWeatherTool = {
    name: "get_weather",
    description: "Get the current weather for a city",
    parameters: {
        "type": "object",
        "properties": {
            "city": {"type": "string", "description": "The city name"}
        },
        "required": ["city"]
    }
};

final ai:ChatCompletionFunctions bookFlightTool = {
    name: "book_flight",
    description: "Book a flight to a destination",
    parameters: {
        "type": "object",
        "properties": {
            "destination": {"type": "string", "description": "The destination city"}
        },
        "required": ["destination"]
    }
};

@test:Config
function testChatWithFunctionCallResponse() returns error? {
    ModelProvider chatProvider = check new (ACCESS_TOKEN, PROJECT_ID, GEMINI_2_0_FLASH, LOCATION, CHAT_SERVICE_URL);
    ai:ChatMessage[] messages = [{role: ai:USER, content: "What is the weather in Colombo?"}];

    ai:ChatAssistantMessage|ai:Error response = chatProvider->chat(messages, [getWeatherTool]);
    test:assertTrue(response is ai:ChatAssistantMessage,
            string `Expected ChatAssistantMessage but got: ${response is ai:Error ? (<ai:Error>response).message() : ""}`);

    ai:ChatAssistantMessage msg = check response;
    ai:FunctionCall[]? toolCalls = msg.toolCalls;
    test:assertNotEquals(toolCalls, (), "toolCalls must be populated from functionCall response");

    ai:FunctionCall call = (<ai:FunctionCall[]>toolCalls)[0];
    test:assertEquals(call.name, "get_weather");
    test:assertEquals(call.arguments["city"], "Colombo");
}

@test:Config
function testChatWithBookFlightFunctionCall() returns error? {
    ModelProvider chatProvider = check new (ACCESS_TOKEN, PROJECT_ID, GEMINI_2_0_FLASH, LOCATION, CHAT_SERVICE_URL);
    ai:ChatMessage[] messages = [{role: ai:USER, content: "Book a flight to London"}];

    ai:ChatAssistantMessage|ai:Error response = chatProvider->chat(messages, [bookFlightTool]);
    test:assertTrue(response is ai:ChatAssistantMessage,
            string `Expected ChatAssistantMessage but got: ${response is ai:Error ? (<ai:Error>response).message() : ""}`);

    ai:ChatAssistantMessage msg = check response;
    ai:FunctionCall[]? toolCalls = msg.toolCalls;
    test:assertNotEquals(toolCalls, (), "toolCalls must be populated");

    ai:FunctionCall call = (<ai:FunctionCall[]>toolCalls)[0];
    test:assertEquals(call.name, "book_flight");
    test:assertEquals(call.arguments["destination"], "London");
}

@test:Config
function testChatWithTextOnlyResponse() returns error? {
    ModelProvider chatProvider = check new (ACCESS_TOKEN, PROJECT_ID, GEMINI_2_0_FLASH, LOCATION, CHAT_SERVICE_URL);
    ai:ChatMessage[] messages = [{role: ai:USER, content: "Hello"}];

    ai:ChatAssistantMessage|ai:Error response = chatProvider->chat(messages, []);
    test:assertTrue(response is ai:ChatAssistantMessage,
            string `Expected ChatAssistantMessage but got: ${response is ai:Error ? (<ai:Error>response).message() : ""}`);

    ai:ChatAssistantMessage msg = check response;
    test:assertEquals(msg.content, "Hello! How can I help you today?");
    test:assertEquals(msg.toolCalls, ());
}

@test:Config
function testChatMethodConnectionError() returns ai:Error? {
    ModelProvider chatProvider = check new (ACCESS_TOKEN, PROJECT_ID, GEMINI_2_0_FLASH, LOCATION,
            "http://localhost:9999/llm/vertexai");
    ai:ChatMessage[] messages = [
        {role: ai:USER, content: "Hello, how are you?"}
    ];
    ai:ChatAssistantMessage|ai:Error response = chatProvider->chat(messages, []);
    test:assertTrue(response is ai:Error, "Expected an error when connecting to a non-existent endpoint");
}

// ── EmbeddingProvider tests ───────────────────────────────────────────────────

final EmbeddingProvider embeddingProvider = check new (ACCESS_TOKEN, PROJECT_ID, LOCATION, TEXT_EMBEDDING_005,
        EMBED_SERVICE_URL);

@test:Config
function testEmbedWithTextChunk() returns error? {
    ai:TextChunk chunk = {'type: "text-chunk", content: "Hello, world!"};
    ai:Embedding result = check embeddingProvider->embed(chunk);
    test:assertTrue(result is float[]);
    test:assertEquals((<float[]>result).length(), 3);
}

@test:Config
function testEmbedWithTextDocument() returns error? {
    ai:TextDocument doc = {'type: "text", content: "This is a text document."};
    ai:Embedding result = check embeddingProvider->embed(doc);
    test:assertTrue(result is float[]);
    test:assertEquals((<float[]>result).length(), 3);
}

@test:Config
function testBatchEmbedWithTextChunks() returns error? {
    ai:TextChunk[] chunks = [
        {'type: "text-chunk", content: "First chunk."},
        {'type: "text-chunk", content: "Second chunk."}
    ];
    ai:Embedding[] results = check embeddingProvider->batchEmbed(chunks);
    test:assertEquals(results.length(), 2);
    test:assertTrue(results[0] is float[]);
    test:assertTrue(results[1] is float[]);
}

@test:Config
function testBatchEmbedWithTextDocuments() returns error? {
    ai:TextDocument[] docs = [
        {'type: "text", content: "Document one."},
        {'type: "text", content: "Document two."},
        {'type: "text", content: "Document three."}
    ];
    ai:Embedding[] results = check embeddingProvider->batchEmbed(docs);
    test:assertEquals(results.length(), 3);
}

@test:Config
function testEmbedWithUnsupportedChunkType() {
    ai:Chunk unsupportedChunk = {'type: "custom", content: "some data"};
    ai:Embedding|ai:Error result = embeddingProvider->embed(unsupportedChunk);
    test:assertTrue(result is ai:Error);
    test:assertTrue((<ai:Error>result).message().includes("Unsupported chunk type"));
}

@test:Config
function testBatchEmbedWithUnsupportedChunkType() {
    ai:TextChunk validChunk = {'type: "text-chunk", content: "valid"};
    ai:Chunk invalidChunk = {'type: "custom", content: "invalid"};
    ai:Embedding[]|ai:Error result = embeddingProvider->batchEmbed([validChunk, invalidChunk]);
    test:assertTrue(result is ai:Error);
    test:assertTrue((<ai:Error>result).message().includes("Unsupported chunk type"));
}

@test:Config
function testBatchEmbedEmptyList() returns error? {
    ai:Embedding[] results = check embeddingProvider->batchEmbed([]);
    test:assertEquals(results.length(), 0);
}

@test:Config
function testEmbedConnectionError() {
    EmbeddingProvider|error badProvider = new (ACCESS_TOKEN, PROJECT_ID, LOCATION, TEXT_EMBEDDING_005,
            "http://localhost:9999/llm/vertexai");
    if badProvider is error {
        test:assertFail("Provider initialization should succeed");
    }
    ai:Embedding|ai:Error result = badProvider->embed({'type: "text-chunk", content: "test"});
    test:assertTrue(result is ai:Error);
}

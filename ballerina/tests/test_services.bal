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

import ballerina/http;
import ballerina/test;

// ── Local types for mock service request deserialization ──────────────────────

type FunctionDeclaration record {
    string name;
    string description?;
    map<json> parameters?;
};

type VertexToolDecl record {
    FunctionDeclaration[] functionDeclarations;
};

type FunctionCallingConfig record {
    string mode;
    string[] allowedFunctionNames?;
};

type ToolConfigDecl record {
    FunctionCallingConfig functionCallingConfig;
};

// ── Generate mock service (port 8080) ────────────────────────────────────────
// Used by generate() tests via the generateLlmResponse utility.
// Validates that the request contains the expected getResults tool with the
// correct schema, then returns a functionCall response.
service /llm/vertexai on new http:Listener(8080) {
    resource function post v1/projects/[string projectId]/locations/[string location]/publishers/google/models/[string modelId](
            @http:Header {name: "Authorization"} string authHeader,
            @http:Payload json payload) returns json|error {

        // Validate auth header
        test:assertTrue(authHeader.startsWith("Bearer "), "Authorization header must start with 'Bearer '");

        // Extract the first user content part text
        json[] contents = check (check payload.contents).cloneWithType();
        map<json> firstContent = check contents[0].cloneWithType();
        map<json>[] parts = check firstContent["parts"].cloneWithType();
        string firstText = check parts[0]["text"].ensureType();

        // Validate tools and toolConfig
        VertexToolDecl[]? tools = check (check payload.tools).cloneWithType();
        if tools is () || tools.length() == 0 {
            return error("No tools in payload");
        }

        FunctionDeclaration? getResultsTool = ();
        foreach FunctionDeclaration fd in tools[0].functionDeclarations {
            if fd.name == GET_RESULTS_TOOL_NAME {
                getResultsTool = fd;
                break;
            }
        }
        if getResultsTool is () {
            return error("getResults tool not found in payload");
        }

        map<json>? parameters = getResultsTool.parameters;
        if parameters is () {
            return error("No parameters in getResults tool");
        }

        test:assertEquals(parameters, getExpectedParameterSchema(firstText),
                string `Schema mismatch for prompt: ${firstText}`);

        // Check toolConfig forces ANY mode on getResults
        ToolConfigDecl? toolConfig = check (check payload.toolConfig).cloneWithType();
        if toolConfig is () {
            return error("toolConfig missing from payload");
        }
        test:assertEquals(toolConfig.functionCallingConfig.mode, "ANY");

        return buildGetResultsToolCallResponse(firstText);
    }
}

// ── Chat mock service (port 8081) ─────────────────────────────────────────────
// Used by chat() tests.
// Routes responses by the first user message text.
service /llm/vertexai on new http:Listener(8081) {
    resource function post v1/projects/[string projectId]/locations/[string location]/publishers/google/models/[string modelId](
            @http:Header {name: "Authorization"} string authHeader,
            @http:Payload json payload) returns json|error {

        test:assertTrue(authHeader.startsWith("Bearer "), "Authorization header must start with 'Bearer '");

        json[] contents = check (check payload.contents).cloneWithType();
        map<json> firstContent = check contents[0].cloneWithType();
        map<json>[] parts = check firstContent["parts"].cloneWithType();
        string firstText = check parts[0]["text"].ensureType();

        if firstText == "What is the weather in Colombo?" {
            // Response with a functionCall part
            return {
                "candidates": [
                    {
                        "content": {
                            "role": "model",
                            "parts": [
                                {
                                    "functionCall": {
                                        "name": "get_weather",
                                        "args": {"city": "Colombo"}
                                    }
                                }
                            ]
                        },
                        "finishReason": "STOP",
                        "index": 0
                    }
                ],
                "usageMetadata": {"promptTokenCount": 20, "candidatesTokenCount": 10, "totalTokenCount": 30},
                "responseId": "chat-fc-id"
            };
        }

        if firstText == "Book a flight to London" {
            return {
                "candidates": [
                    {
                        "content": {
                            "role": "model",
                            "parts": [
                                {
                                    "functionCall": {
                                        "name": "book_flight",
                                        "args": {"destination": "London"}
                                    }
                                }
                            ]
                        },
                        "finishReason": "STOP",
                        "index": 0
                    }
                ],
                "usageMetadata": {"promptTokenCount": 20, "candidatesTokenCount": 10, "totalTokenCount": 30},
                "responseId": "chat-tc-id"
            };
        }

        if firstText == "Hello" {
            // Plain text response, no function call
            return {
                "candidates": [
                    {
                        "content": {
                            "role": "model",
                            "parts": [{"text": "Hello! How can I help you today?"}]
                        },
                        "finishReason": "STOP",
                        "index": 0
                    }
                ],
                "usageMetadata": {"promptTokenCount": 5, "candidatesTokenCount": 10, "totalTokenCount": 15},
                "responseId": "chat-text-id"
            };
        }

        return error(string `Unexpected message in chat mock: ${firstText}`);
    }
}

// ── Mock OAuth2 token endpoint (port 8083) ────────────────────────────────────
// Ballerina's oauth2 module creates an http:Client with the refreshUrl as base
// and always POSTs to "/", so the resource path must be "." (service base path).
service / on new http:Listener(8083) {
    resource function post .(@http:Payload string _payload) returns json {
        return {
            "access_token": "mock-test-access-token",
            "token_type": "Bearer",
            "expires_in": 3600
        };
    }
}

// ── Embedding mock service (port 8082) ────────────────────────────────────────
service /llm/vertexai on new http:Listener(8082) {
    resource function post v1/projects/[string projectId]/locations/[string location]/publishers/google/models/[string modelId](
            @http:Header {name: "Authorization"} string authHeader,
            @http:Payload json payload) returns json|error {

        test:assertTrue(authHeader.startsWith("Bearer "), "Authorization header must start with 'Bearer '");

        return {
            "predictions": [
                {
                    "embeddings": {
                        "values": [0.1, 0.2, 0.3]
                    }
                }
            ]
        };
    }
}

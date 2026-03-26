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

// ── Message conversion ────────────────────────────────────────────────────────

# Converts ai:ChatMessage types to the Mistral/OpenAI-compatible message format.
# System messages are kept inline in the messages array (Mistral supports the
# standard system role unlike Anthropic on Vertex which uses a separate field).
isolated function convertMessagesToMistralMessages(ai:ChatMessage[]|ai:ChatUserMessage messages)
        returns MistralMessage[]|ai:Error {
    MistralMessage[] mistralMessages = [];

    if messages is ai:ChatUserMessage {
        string text = check getChatMessageStringContent(messages.content);
        mistralMessages.push({role: "user", content: text});
        return mistralMessages;
    }

    foreach ai:ChatMessage message in <ai:ChatMessage[]>messages {
        if message is ai:ChatSystemMessage {
            string text = check getChatMessageStringContent(message.content);
            mistralMessages.push({role: "system", content: text});
        } else if message is ai:ChatUserMessage {
            string text = check getChatMessageStringContent(message.content);
            mistralMessages.push({role: "user", content: text});
        } else if message is ai:ChatAssistantMessage {
            mistralMessages.push(check buildMistralAssistantMessage(message));
        } else if message is ai:ChatFunctionMessage {
            // Function results use role "tool" with a tool_call_id field.
            // ai:ChatFunctionMessage.id maps to tool_call_id; fall back to the function name.
            mistralMessages.push({
                role: "tool",
                tool_call_id: message.id ?: message.name,
                content: message.content ?: ""
            });
        }
    }
    return mistralMessages;
}

isolated function buildMistralAssistantMessage(ai:ChatAssistantMessage message)
        returns MistralMessage|ai:Error {
    ai:FunctionCall[]? toolCalls = message.toolCalls;
    if toolCalls is ai:FunctionCall[] && toolCalls.length() > 0 {
        MistralToolCall[] mistralToolCalls = [];
        foreach ai:FunctionCall tc in toolCalls {
            mistralToolCalls.push({
                id: tc.id ?: tc.name,
                'type: "function",
                'function: {
                    name: tc.name,
                    arguments: (tc.arguments ?: {}).toJsonString()
                }
            });
        }
        return {role: "assistant", content: (), tool_calls: mistralToolCalls};
    }
    return {role: "assistant", content: message.content};
}

// ── Tool mapping ──────────────────────────────────────────────────────────────

# Maps ai:ChatCompletionFunctions to the Mistral OpenAI-compatible tool format.
isolated function mapToMistralTools(ai:ChatCompletionFunctions[] tools) returns MistralTool[] {
    MistralTool[] result = [];
    foreach ai:ChatCompletionFunctions t in tools {
        result.push({
            'function: {
                name: t.name,
                description: t.description,
                parameters: t.parameters
            }
        });
    }
    return result;
}

# Builds the forced-call "getResults" tool in Mistral/OpenAI format.
isolated function getMistralGetResultsTool(map<json> schema) returns MistralTool {
    return {
        'function: {
            name: GET_RESULTS_TOOL,
            description: "Tool to call with the response from a large language model (LLM) for a user prompt.",
            parameters: schema
        }
    };
}

// ── Request building ──────────────────────────────────────────────────────────

# Builds the Mistral/OpenAI-compatible request payload.
# `toolChoice` controls the `tool_choice` field: pass `"any"` for Mistral rawPredict,
# `"required"` for the OpenAI-compatible openapi endpoint, or `()` to omit it (regular chat).
isolated function buildMistralPayload(string modelType, MistralMessage[] messages,
        MistralTool[] tools, string? toolChoice,
        int maxTokens, decimal? temperature, string? stop) returns map<json> {
    map<json> payload = {
        "model": modelType,
        "messages": messages.toJson(),
        "max_tokens": maxTokens
    };
    if temperature is decimal {
        payload["temperature"] = temperature;
    }
    if tools.length() > 0 {
        payload["tools"] = tools.toJson();
        if toolChoice is string {
            payload["tool_choice"] = toolChoice;
        }
    }
    if stop is string {
        payload["stop"] = [stop];
    }
    return payload;
}

// ── Response parsing ──────────────────────────────────────────────────────────

# Parses a Mistral rawPredict response into an ai:ChatAssistantMessage.
isolated function buildChatAssistantMessageFromMistralResponse(MistralResponse response)
        returns ai:ChatAssistantMessage|ai:Error {
    if response.choices.length() == 0 {
        return error ai:LlmInvalidResponseError("Empty response from Mistral model on Vertex AI");
    }

    MistralMessage message = response.choices[0].message;
    ai:FunctionCall[] functionCalls = [];

    MistralToolCall[]? toolCalls = message["tool_calls"];
    if toolCalls is MistralToolCall[] {
        foreach MistralToolCall tc in toolCalls {
            map<json>|error arguments = tc.'function.arguments.fromJsonStringWithType();
            if arguments is error {
                return error ai:LlmInvalidResponseError(
                    "Invalid tool call arguments in Mistral response", arguments);
            }
            functionCalls.push({name: tc.'function.name, arguments, id: tc.id});
        }
    }

    return {
        role: ai:ASSISTANT,
        content: message["content"],
        toolCalls: functionCalls.length() > 0 ? functionCalls : ()
    };
}

# Extracts the `getResults` tool call arguments from a Mistral rawPredict response.
# Used by generateLlmResponse to obtain the structured output for generate().
isolated function extractMistralGetResultsArgs(MistralResponse response)
        returns map<json>|ai:Error {
    if response.choices.length() == 0 {
        return error ai:LlmInvalidResponseError(NO_RELEVANT_RESPONSE_FROM_THE_LLM);
    }

    MistralToolCall[]? toolCalls = response.choices[0].message["tool_calls"];
    if toolCalls is MistralToolCall[] {
        foreach MistralToolCall tc in toolCalls {
            if tc.'function.name == GET_RESULTS_TOOL {
                map<json>|error arguments = tc.'function.arguments.fromJsonStringWithType();
                if arguments is error {
                    return error ai:LlmInvalidResponseError(
                        "Invalid getResults arguments in Mistral response", arguments);
                }
                return arguments;
            }
        }
    }
    return error ai:LlmInvalidResponseError(NO_RELEVANT_RESPONSE_FROM_THE_LLM);
}

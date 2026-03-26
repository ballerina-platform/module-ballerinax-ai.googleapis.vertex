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

// Anthropic on Vertex sends the API version as a request body field instead of a header.
const ANTHROPIC_VERSION_VERTEX = "vertex-2023-10-16";

// ── Message conversion ────────────────────────────────────────────────────────

# Converts ai:ChatMessage types to the Anthropic Messages API format.
# System messages are accumulated and returned separately as a plain string because
# the Anthropic API on Vertex expects a single top-level `system` string field.
# Multiple system messages are joined with a double newline.
#
# Returns a tuple of [anthropicMessages, systemPrompt?].
isolated function convertMessagesToAnthropicMessages(ai:ChatMessage[]|ai:ChatUserMessage messages)
        returns [AnthropicMessage[], string?]|ai:Error {
    AnthropicMessage[] anthropicMessages = [];
    string[] systemParts = [];

    if messages is ai:ChatUserMessage {
        string text = check getChatMessageStringContent(messages.content);
        anthropicMessages.push({role: "user", content: text});
        return [anthropicMessages, ()];
    }

    foreach ai:ChatMessage message in messages {
        if message is ai:ChatSystemMessage {
            string text = check getChatMessageStringContent(message.content);
            systemParts.push(text);
        } else if message is ai:ChatUserMessage {
            string text = check getChatMessageStringContent(message.content);
            anthropicMessages.push({role: "user", content: text});
        } else if message is ai:ChatAssistantMessage {
            anthropicMessages.push(check buildAnthropicAssistantMessage(message));
        } else if message is ai:ChatFunctionMessage {
            // Function results become a user-role message with a tool_result content block.
            // ai:ChatFunctionMessage.id maps to tool_use_id; fall back to the function name
            // when the caller did not set an id (id is optional in the ai interface).
            AnthropicContentBlock toolResult = {
                'type: "tool_result",
                tool_use_id: message.id ?: message.name,
                content: message.content ?: ""
            };
            anthropicMessages.push({role: "user", content: [toolResult]});
        }
    }

    string? systemPrompt = ();
    if systemParts.length() > 0 {
        systemPrompt = string:'join("\n\n", ...systemParts);
    }
    return [anthropicMessages, systemPrompt];
}

isolated function buildAnthropicAssistantMessage(ai:ChatAssistantMessage message)
        returns AnthropicMessage|ai:Error {
    ai:FunctionCall[]? toolCalls = message.toolCalls;
    if toolCalls is ai:FunctionCall[] && toolCalls.length() > 0 {
        AnthropicContentBlock[] blocks = [];
        foreach ai:FunctionCall tc in toolCalls {
            blocks.push({
                'type: "tool_use",
                id: tc.id ?: tc.name,
                name: tc.name,
                input: tc.arguments ?: {}
            });
        }
        return {role: "assistant", content: blocks};
    }
    return {role: "assistant", content: message.content ?: ""};
}

// ── Tool mapping ──────────────────────────────────────────────────────────────

# Maps ai:ChatCompletionFunctions to the Anthropic tool format.
# Anthropic uses `input_schema` where OpenAI/Gemini use `parameters`.
isolated function mapToAnthropicTools(ai:ChatCompletionFunctions[] tools) returns AnthropicTool[] {
    AnthropicTool[] result = [];
    foreach ai:ChatCompletionFunctions t in tools {
        result.push({
            name: t.name,
            description: t.description,
            input_schema: t.parameters ?: {'type: "object", properties: {}}
        });
    }
    return result;
}

# Builds the forced-call "getResults" tool in Anthropic format.
isolated function getAnthropicGetResultsTool(map<json> schema) returns AnthropicTool {
    return {
        name: GET_RESULTS_TOOL,
        description: "Tool to call with the response from a large language model (LLM) for a user prompt.",
        input_schema: schema
    };
}

# Returns a tool_choice that forces Anthropic to call "getResults".
isolated function getAnthropicGetResultsToolChoice() returns AnthropicToolChoice {
    return {'type: "tool", name: GET_RESULTS_TOOL};
}

// ── Request building ──────────────────────────────────────────────────────────

# Builds the Anthropic rawPredict request payload.
isolated function buildAnthropicPayload(AnthropicMessage[] messages, string? systemPrompt,
        AnthropicTool[] tools, AnthropicToolChoice? toolChoice,
        int maxTokens, decimal? temperature, string? stop) returns map<json> {
    map<json> payload = {
        "anthropic_version": ANTHROPIC_VERSION_VERTEX,
        "messages": messages.toJson(),
        "max_tokens": maxTokens
    };
    if temperature is decimal {
        payload["temperature"] = temperature;
    }
    if systemPrompt is string {
        payload["system"] = systemPrompt;
    }
    if tools.length() > 0 {
        payload["tools"] = tools.toJson();
    }
    if toolChoice is AnthropicToolChoice {
        payload["tool_choice"] = toolChoice.toJson();
    }
    if stop is string {
        payload["stop_sequences"] = [stop];
    }
    return payload;
}

// ── Response parsing ──────────────────────────────────────────────────────────

# Parses an Anthropic rawPredict response into an ai:ChatAssistantMessage.
isolated function buildChatAssistantMessageFromAnthropicResponse(AnthropicResponse response)
        returns ai:ChatAssistantMessage|ai:Error {
    if response.content.length() == 0 {
        return error ai:LlmInvalidResponseError("Empty response from Anthropic model on Vertex AI");
    }

    ai:FunctionCall[] functionCalls = [];
    string textAccumulator = "";

    foreach AnthropicContentBlock block in response.content {
        if block.'type == "text" {
            textAccumulator += block.text ?: "";
        } else if block.'type == "tool_use" {
            string? blockName = block.name;
            if blockName is () {
                return error ai:LlmInvalidResponseError(
                    "Tool use block is missing the name field in Anthropic response");
            }
            json inputJson = block?.input ?: {};
            map<json>|error arguments = inputJson.cloneWithType();
            if arguments is error {
                return error ai:LlmInvalidResponseError(
                    "Invalid tool call arguments in Anthropic response", arguments);
            }
            functionCalls.push({name: blockName, arguments, id: block.id});
        }
    }
    string? textContent = textAccumulator.length() > 0 ? textAccumulator : ();

    return {
        role: ai:ASSISTANT,
        content: textContent,
        toolCalls: functionCalls.length() > 0 ? functionCalls : ()
    };
}

# Extracts the `getResults` tool call arguments from an Anthropic rawPredict response.
# Used by generateLlmResponse to obtain the structured output for generate().
isolated function extractAnthropicGetResultsArgs(AnthropicResponse response)
        returns map<json>|ai:Error {
    foreach AnthropicContentBlock block in response.content {
        if block.'type == "tool_use" && block.name == GET_RESULTS_TOOL {
            json inputJson = block?.input ?: {};
            map<json>|error args = inputJson.cloneWithType();
            if args is error {
                return error ai:LlmInvalidResponseError(
                    "Invalid getResults arguments in Anthropic response", args);
            }
            return args;
        }
    }
    return error ai:LlmInvalidResponseError(NO_RELEVANT_RESPONSE_FROM_THE_LLM);
}

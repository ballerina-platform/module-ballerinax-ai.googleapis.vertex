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
import ballerina/ai.observe;
import ballerina/http;
import ballerina/io;
import ballerina/jballerina.java;
import ballerina/time;

const DEFAULT_MAX_TOKEN_COUNT = 512;

# ModelProvider is a client class that provides an interface for interacting with
# models hosted on Google Vertex AI, including Google Gemini models and partner
# models (Anthropic Claude, Mistral) available through Vertex AI Model Garden.
#
# The `model` parameter uses `"publisher/model-name"` format, which determines both
# the endpoint path and the wire format used for requests:
# - `"google/gemini-2.0-flash"` — Vertex AI `generateContent` API
# - `"anthropic/claude-sonnet-4-6"` — Anthropic Messages API via `rawPredict`
# - `"mistralai/mistral-medium-3"` — OpenAI-compatible format via `rawPredict`
# - `"meta/llama-4-maverick-17b-128e-instruct-maas"` — OpenAI-compatible open-models endpoint
# - `"deepseek-ai/deepseek-v3-0324"` — OpenAI-compatible open-models endpoint
# - `"qwen/qwen3-235b-a22b"` — OpenAI-compatible open-models endpoint
# - `"kimi/kimi-k2"` — OpenAI-compatible open-models endpoint
# - `"minimax/minimax-m2"` — OpenAI-compatible open-models endpoint
@display {label: "Google Vertex Model Provider"}
public isolated distinct client class ModelProvider {
    *ai:ModelProvider;
    private final http:Client vertexAiClient;
    private final VertexAiAuth auth;
    private string accessToken = "";
    private int tokenExpiryTime = 0;
    private final string modelType;
    private final string projectId;
    private final string location;
    private final string publisher;
    private final int maxTokens;
    private final decimal? temperature;

    # Initializes the Vertex AI model provider with the given configuration.
    #
    # + auth - Authentication config: `OAuth2RefreshConfig` for OAuth2 refresh token flow,
    #          or `ServiceAccountConfig` for automatic token refresh via service account
    # + projectId - The Google Cloud project ID
    # + location - The Google Cloud region (e.g., `"global","us-central1"`)
    # + model - The model in `"publisher/model-name"` format, e.g.:
    #           `"google/gemini-2.0-flash"`.
    # + serviceUrl - The base URL of the Vertex AI API endpoint. Defaults to the
    #                regional URL `https://{location}-aiplatform.googleapis.com`
    # + maxTokens - The upper limit for the number of tokens in the model's response
    # + temperature - Controls randomness in the model's output. Pass `()` to omit
    #                 the field entirely (required for models that do not accept it)
    # + connectionConfig - Additional HTTP connection configuration
    # + return - `()` on successful initialization; otherwise, returns an `ai:Error`
    public isolated function init(
            @display {label: "Auth"} VertexAiAuth auth,
            @display {label: "Project ID"} string projectId,
            @display {label: "Model"} string model,
            @display {label: "Location"} string location = "global",
            @display {label: "Service URL"} string serviceUrl = "",
            @display {label: "Maximum Tokens"} int maxTokens = DEFAULT_MAX_TOKEN_COUNT,
            @display {label: "Temperature"} decimal? temperature = (),
            @display {label: "Connection Configuration"} *ConnectionConfig connectionConfig)
            returns ai:Error? {

        // Parse "publisher/model-name" — bare model name defaults to google
        int? slashIdx = model.indexOf("/");
        string publisher;
        string modelType;
        if slashIdx is () {
            publisher = GOOGLE;
            modelType = model;
        } else {
            publisher = model.substring(0, slashIdx);
            modelType = model.substring(slashIdx + 1);
        }

        if modelType.length() == 0 {
            return error ai:Error("Model name must not be empty in 'publisher/model-name' format");
        }

        if publisher != GOOGLE && publisher != ANTHROPIC && publisher != MISTRAL
                && !isOpenModelPublisher(publisher) {
            return error ai:Error(string `Unsupported publisher '${publisher}'. ` +
                "Supported values: google, anthropic, mistralai, meta, deepseek-ai, qwen, kimi, minimax, openai");
        }

        string resolvedServiceUrl = serviceUrl == "" ?
            (location == "global"
                ? "https://aiplatform.googleapis.com"
                : string `https://${location}-aiplatform.googleapis.com`)
            : serviceUrl;

        http:ClientConfiguration clientConfig = {
            httpVersion: connectionConfig.httpVersion,
            http1Settings: connectionConfig.http1Settings ?: {},
            http2Settings: connectionConfig.http2Settings ?: {},
            timeout: connectionConfig.timeout,
            forwarded: connectionConfig.forwarded,
            poolConfig: connectionConfig.poolConfig,
            cache: connectionConfig.cache ?: {},
            compression: connectionConfig.compression,
            circuitBreaker: connectionConfig.circuitBreaker,
            retryConfig: connectionConfig.retryConfig,
            responseLimits: connectionConfig.responseLimits ?: {},
            secureSocket: connectionConfig.secureSocket,
            proxy: connectionConfig.proxy,
            validation: connectionConfig.validation
        };

        if auth is OAuth2RefreshConfig {
            clientConfig.auth = {
                refreshUrl: auth.refreshUrl,
                refreshToken: auth.refreshToken,
                clientId: auth.clientId,
                clientSecret: auth.clientSecret
            };
        }

        http:Client|error httpClient = new http:Client(resolvedServiceUrl, clientConfig);
        if httpClient is error {
            return error ai:Error("Failed to initialize Vertex AI Model", httpClient);
        }

        self.vertexAiClient = httpClient;
        if auth is ServiceAccountJsonFilePath {
            json|error fileContent = io:fileReadJson(auth);
            if fileContent is error {
                return error ai:Error("Failed to read service account key file", fileContent);
            }
            record {string client_email; string private_key;}|error saRecord = fileContent.fromJsonWithType();
            if saRecord is error {
                return error ai:Error("Invalid service account key file: missing or invalid client_email/private_key", saRecord);
            }
            self.auth = {clientEmail: saRecord.client_email, privateKey: saRecord.private_key};
        } else {
            self.auth = auth;
        }
        self.modelType = modelType;
        self.projectId = projectId;
        self.location = location;
        self.publisher = publisher;
        self.maxTokens = maxTokens;
        self.temperature = temperature;
    }

    # Sends a chat request to the model. The request is routed to the correct
    # publisher-specific endpoint and serialised using the appropriate wire format.
    #
    # + messages - List of chat messages or a single user message
    # + tools - Tool definitions to be used for tool calling
    # + stop - Stop sequence to stop the completion
    # + return - The assistant's response, or an error if the request fails
    isolated remote function chat(ai:ChatMessage[]|ai:ChatUserMessage messages,
            ai:ChatCompletionFunctions[] tools = [], string? stop = ())
            returns ai:ChatAssistantMessage|ai:Error {
        observe:ChatSpan span = observe:createChatSpan(self.modelType);
        span.addProvider(self.publisher);
        decimal? temp = self.temperature;
        if temp is decimal {
            span.addTemperature(temp);
        }

        json|ai:Error inputMessage = convertMessageToJson(messages);
        if inputMessage is json {
            span.addInputMessages(inputMessage);
        }
        if stop is string {
            span.addStopSequence(stop);
        }
        if tools.length() > 0 {
            span.addTools(tools);
        }

        map<string> headers = {"Content-Type": "application/json"};
        if self.auth is ServiceAccountConfig {
            string|ai:Error accessToken = self.getAccessToken();
            if accessToken is ai:Error {
                span.close(accessToken);
                return accessToken;
            }
            headers["Authorization"] = string `Bearer ${accessToken}`;
        }

        ChatResult|ai:Error result;
        if self.publisher == ANTHROPIC {
            string path = buildGenerateContentPath(self.projectId, self.location,
                self.modelType, self.publisher);
            result = self.executeAnthropicChat(messages, tools, stop, path, headers);
        } else if self.publisher == MISTRAL {
            string path = buildGenerateContentPath(self.projectId, self.location,
                self.modelType, self.publisher);
            result = self.executeMistralChat(messages, tools, stop, path, headers);
        } else if isOpenModelPublisher(self.publisher) {
            string path = buildOpenModelsPath(self.projectId, self.location);
            result = self.executeMistralChat(messages, tools, stop, path, headers);
        } else {
            string path = buildGenerateContentPath(self.projectId, self.location,
                self.modelType, self.publisher);
            result = self.executeGeminiChat(messages, tools, stop, path, headers);
        }

        if result is ai:Error {
            span.close(result);
            return result;
        }

        span.addResponseId(result.responseId);
        span.addInputTokenCount(result.inputTokens ?: 0);
        span.addOutputTokenCount(result.outputTokens ?: 0);
        span.addOutputMessages(result.message);
        span.addOutputType(observe:TEXT);
        span.close();
        return result.message;
    }

    # Sends a prompt to the model and generates a value of the type specified by
    # the `td` type descriptor. Supports all publishers (Gemini, Anthropic, Mistral).
    #
    # + prompt - The prompt to use
    # + td - Type descriptor specifying the expected return type format
    # + return - Generates a value that belongs to the type, or an error if generation fails
    isolated remote function generate(ai:Prompt prompt,
            @display {label: "Expected type"} typedesc<anydata> td = <>) returns td|ai:Error = @java:Method {
        'class: "io.ballerina.lib.ai.googleapis.vertex.Generator"
    } external;

    // ── Private publisher-specific chat implementations ───────────────────────

    private isolated function executeGeminiChat(ai:ChatMessage[]|ai:ChatUserMessage messages,
            ai:ChatCompletionFunctions[] tools, string? stop,
            string path, map<string> headers) returns ChatResult|ai:Error {
        var [contents, systemInstruction] = check convertMessagesToVertexAiContents(messages);

        VertexAiGenerationConfig generationConfig = {maxOutputTokens: self.maxTokens};
        decimal? temp = self.temperature;
        if temp is decimal {
            generationConfig.temperature = temp;
        }
        if stop is string {
            generationConfig.stopSequences = [stop];
        }

        map<json> requestPayload = {
            "contents": contents.toJson(),
            "generationConfig": generationConfig.toJson()
        };
        if systemInstruction is VertexAiSystemInstruction {
            requestPayload["systemInstruction"] = systemInstruction.toJson();
        }
        if tools.length() > 0 {
            requestPayload["tools"] = mapToVertexAiTools(tools).toJson();
        }

        VertexAiResponse|error response = self.vertexAiClient->post(path, requestPayload, headers);
        if response is error {
            return buildHttpError(response);
        }

        ai:ChatAssistantMessage|ai:Error assistantMessage = buildChatAssistantMessage(response);
        if assistantMessage is ai:Error {
            return assistantMessage;
        }
        return {
            message: assistantMessage,
            responseId: response.responseId ?: "",
            inputTokens: response.usageMetadata?.promptTokenCount,
            outputTokens: response.usageMetadata?.candidatesTokenCount
        };
    }

    private isolated function executeAnthropicChat(ai:ChatMessage[]|ai:ChatUserMessage messages,
            ai:ChatCompletionFunctions[] tools, string? stop,
            string path, map<string> headers) returns ChatResult|ai:Error {
        var [anthropicMessages, systemPrompt] = check convertMessagesToAnthropicMessages(messages);

        AnthropicTool[] anthropicTools = mapToAnthropicTools(tools);
        map<json> requestPayload = buildAnthropicPayload(
            anthropicMessages, systemPrompt, anthropicTools, (),
            self.maxTokens, self.temperature, stop);

        AnthropicResponse|error response =
            self.vertexAiClient->post(path, requestPayload, headers);
        if response is error {
            return buildHttpError(response);
        }

        ai:ChatAssistantMessage|ai:Error assistantMessage =
            buildChatAssistantMessageFromAnthropicResponse(response);
        if assistantMessage is ai:Error {
            return assistantMessage;
        }
        return {
            message: assistantMessage,
            responseId: response.id ?: "",
            inputTokens: response.usage?.input_tokens,
            outputTokens: response.usage?.output_tokens
        };
    }

    isolated function getAccessToken() returns string|ai:Error {
        lock {
            int currentTime = time:utcNow()[0];
            if self.accessToken.length() > 0 && currentTime < self.tokenExpiryTime - 300 {
                return self.accessToken;
            }
            string|error token = getServiceAccountToken(<ServiceAccountConfig>self.auth);
            if token is error {
                return error ai:Error("Failed to obtain service account access token", token);
            }
            self.accessToken = token;
            self.tokenExpiryTime = currentTime + 3600;
            return self.accessToken;
        }
    }

    private isolated function executeMistralChat(ai:ChatMessage[]|ai:ChatUserMessage messages,
            ai:ChatCompletionFunctions[] tools, string? stop,
            string path, map<string> headers) returns ChatResult|ai:Error {
        MistralMessage[]|ai:Error mistralMessages = convertMessagesToMistralMessages(messages);
        if mistralMessages is ai:Error {
            return mistralMessages;
        }

        MistralTool[] mistralTools = mapToMistralTools(tools);
        string modelId = string `${self.publisher}/${self.modelType}`;
        map<json> requestPayload = buildMistralPayload(
            modelId, mistralMessages, mistralTools, (),
            self.maxTokens, self.temperature, stop);

        MistralResponse|error response =
            self.vertexAiClient->post(path, requestPayload, headers);
        if response is error {
            return buildHttpError(response);
        }

        ai:ChatAssistantMessage|ai:Error assistantMessage =
            buildChatAssistantMessageFromMistralResponse(response);
        if assistantMessage is ai:Error {
            return assistantMessage;
        }
        return {
            message: assistantMessage,
            responseId: response.id ?: "",
            inputTokens: response.usage?.prompt_tokens,
            outputTokens: response.usage?.completion_tokens
        };
    }
}

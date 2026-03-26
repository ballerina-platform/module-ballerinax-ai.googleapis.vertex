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
import ballerina/time;

# EmbeddingProvider is a client class that provides an interface for generating
# vector embeddings using Google Vertex AI text embedding models.
public isolated distinct client class EmbeddingProvider {
    *ai:EmbeddingProvider;
    private final http:Client vertexAiClient;
    private final VertexAiAuth auth;
    private string accessToken = "";
    private int tokenExpiryTime = 0;
    private final string modelType;
    private final string projectId;
    private final string location;

    # Initializes the Vertex AI embedding provider with the given configuration.
    #
    # + auth - Authentication config: `OAuth2RefreshConfig` for OAuth2 refresh token flow,
    #          or `ServiceAccountConfig` for automatic token refresh via service account
    # + projectId - The Google Cloud project ID
    # + location - The Google Cloud region (e.g., `"global"`)
    # + modelType - The embedding model to use
    # + serviceUrl - The base URL of the Vertex AI API endpoint (defaults to the regional URL)
    # + connectionConfig - Additional HTTP connection configuration
    # + return - `()` on successful initialization; otherwise, returns an `ai:Error`
    public isolated function init(
            @display {label: "Auth"} VertexAiAuth auth,
            @display {label: "Project ID"} string projectId,
            @display {label: "Location"} string location = "global",
            @display {label: "Model Type"} VertexAiEmbeddingModelNames modelType = TEXT_EMBEDDING_005,
            @display {label: "Service URL"} string serviceUrl = "",
            @display {label: "Connection Configuration"} *ConnectionConfig connectionConfig) returns ai:Error? {

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
            return error ai:Error("Failed to initialize Vertex AI Embedding Model", httpClient);
        }

        self.vertexAiClient = httpClient;
        self.auth = auth;
        self.modelType = modelType;
        self.projectId = projectId;
        self.location = location;
    }

    # Converts the given chunk into a vector embedding.
    #
    # + chunk - The chunk to convert into an embedding (only `ai:TextChunk` and `ai:TextDocument` are supported)
    # + return - The embedding vector representation on success; `ai:LlmConnectionError` if the HTTP call
    #            fails; `ai:LlmInvalidResponseError` if the model returns no embeddings;
    #            `ai:Error` if the chunk type is not supported
    isolated remote function embed(ai:Chunk chunk) returns ai:Embedding|ai:Error {
        observe:EmbeddingSpan span = observe:createEmbeddingSpan(self.modelType);
        span.addProvider("vertexai");

        if chunk !is ai:TextChunk|ai:TextDocument {
            ai:Error err = error ai:Error(
                "Unsupported chunk type. Only 'ai:TextChunk|ai:TextDocument' is supported.");
            span.close(err);
            return err;
        }

        string content = <string>chunk.content;
        span.addInputContent(content);

        ai:Embedding|ai:Error result = self.embedText(content);
        if result is ai:Error {
            span.close(result);
            return result;
        }

        span.close();
        return result;
    }

    # Converts a batch of chunks into vector embeddings by calling the embed endpoint for each chunk.
    # Chunks are processed sequentially. On the first failure, processing halts and no partial
    # results are returned. Vertex AI does not expose a native batch embedding endpoint for
    # Gemini models, so each chunk requires its own HTTP round trip.
    #
    # + chunks - The chunks to convert into embeddings (only `ai:TextChunk` and `ai:TextDocument` are supported)
    # + return - An array of embedding vectors on success; or an error if ANY single chunk fails
    isolated remote function batchEmbed(ai:Chunk[] chunks) returns ai:Embedding[]|ai:Error {
        if chunks.length() == 0 {
            return [];
        }

        observe:EmbeddingSpan span = observe:createEmbeddingSpan(self.modelType);
        span.addProvider("vertexai");

        if !isAllSupportedChunks(chunks) {
            ai:Error err = error ai:Error(
                "Unsupported chunk type. Expected elements of type 'ai:TextChunk|ai:TextDocument'.");
            span.close(err);
            return err;
        }

        ai:Embedding[] embeddings = [];
        foreach ai:Chunk chunk in chunks {
            string content = <string>chunk.content;
            ai:Embedding|ai:Error result = self.embedText(content);
            if result is ai:Error {
                span.close(result);
                return result;
            }
            embeddings.push(result);
        }

        span.close();
        return embeddings;
    }

    private isolated function embedText(string content) returns ai:Embedding|ai:Error {
        string path = buildEmbedContentPath(self.projectId, self.location, self.modelType);
        map<string> headers = {"Content-Type": "application/json"};
        if self.auth is ServiceAccountConfig {
            string|ai:Error accessToken = self.getAccessToken();
            if accessToken is ai:Error {
                return accessToken;
            }
            headers["Authorization"] = string `Bearer ${accessToken}`;
        }

        map<json> requestPayload = {
            "content": {
                "parts": [{"text": content}]
            }
        };

        VertexAiEmbedResponse|error response = self.vertexAiClient->post(path, requestPayload, headers);
        if response is error {
            return error ai:LlmConnectionError("Error while connecting to the embedding model", response);
        }

        float[] values = response.embedding.values;
        if values.length() == 0 {
            return error ai:LlmInvalidResponseError("Vertex AI returned an empty embedding vector");
        }
        return values;
    }

    private isolated function getAccessToken() returns string|ai:Error {
        lock {
            int currentTime = time:utcNow()[0];
            if self.accessToken.length() > 0 && currentTime < self.tokenExpiryTime - 300 {
                return self.accessToken;
            }
            ServiceAccountConfig saConfig = <ServiceAccountConfig>self.auth;
            string|error token = getServiceAccountToken(saConfig);
            if token is error {
                return error ai:Error("Failed to obtain service account access token", token);
            }
            self.accessToken = token;
            self.tokenExpiryTime = currentTime + 3600;
            return self.accessToken;
        }
    }
}

// Returns true only when every element is either ai:TextChunk or ai:TextDocument.
isolated function isAllSupportedChunks(ai:Chunk[] chunks) returns boolean {
    return chunks.every(chunk => chunk is ai:TextChunk|ai:TextDocument);
}

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
import ballerina/lang.runtime;
import ballerina/test;
import ballerina/time;

const AUTH_MOCK_URL = "http://localhost:8096/auth";
const WIF_AUDIENCE = "//iam.googleapis.com/projects/123456789/locations/global/workloadIdentityPools/pool/providers/provider";
const WIF_IDENTITY_TOKEN = "header.payload.signature";
const WIF_SERVICE_ACCOUNT = "vertex-caller@test-project.iam.gserviceaccount.com";

// Requests received by the mock endpoints, per test.
isolated map<map<string>[]> stsRequests = {};
isolated map<json[]> iamRequests = {};
isolated map<string[]> iamAuthHeaders = {};
// The `Authorization` header of each Vertex AI request, per test and call type (chat, generate, embed).
isolated map<string[]> vertexAuthHeaders = {};

service /auth on new http:Listener(8096) {
    // Mock Security Token Service. Issues access tokens that expire in `expiresIn` seconds, or without
    // `expires_in` when it is 0. With `failAfter` > 0, exchanges after the first `failAfter` fail; with -1, every
    // exchange fails. With `failDelay`, a failing exchange responds after that many seconds. A failing exchange
    // returns a 400, or a 503 with `unavailable`.
    resource function post sts/[string testId]/[int expiresIn]/[int failAfter]/token(http:Request req,
            decimal? failDelay, boolean unavailable = false)
            returns json|http:BadRequest|http:ServiceUnavailable|error {
        string contentType = req.getContentType();
        map<string> form = check req.getFormParams();
        form["content-type"] = contentType;
        int count;
        lock {
            map<string>[] requests = stsRequests[testId] ?: [];
            requests.push(form.clone());
            stsRequests[testId] = requests;
            count = requests.length();
        }
        if failAfter == -1 || (failAfter > 0 && count > failAfter) {
            if failDelay is decimal {
                runtime:sleep(failDelay);
            }
            if unavailable {
                return <http:ServiceUnavailable>{body: {'error: "temporarily_unavailable"}};
            }
            return <http:BadRequest>{body: {'error: "invalid_grant", error_description: "The token has expired"}};
        }
        map<json> response = {
            access_token: string `sts-access-token-${testId}-${count}`,
            issued_token_type: "urn:ietf:params:oauth:token-type:access_token",
            token_type: "Bearer"
        };
        if expiresIn > 0 {
            response["expires_in"] = expiresIn;
        }
        return response;
    }

    // Mock IAM Service Account Credentials API. `mode` is `ok`, or `deny` to return a 403.
    resource function post iam/[string testId]/[string mode]/v1/projects/[string project]/serviceAccounts/[string method](
            http:Request req, @http:Payload json payload) returns json|http:Forbidden|error {
        string authHeader = check req.getHeader(AUTHORIZATION_HEADER);
        int count;
        lock {
            json[] requests = iamRequests[testId] ?: [];
            requests.push(payload.clone());
            iamRequests[testId] = requests;
            count = requests.length();
        }
        lock {
            string[] headers = iamAuthHeaders[testId] ?: [];
            headers.push(authHeader);
            iamAuthHeaders[testId] = headers;
        }
        test:assertEquals(project, "-");
        test:assertEquals(method, string `${WIF_SERVICE_ACCOUNT}:generateAccessToken`);
        // `deny` refuses every request; `deny-once` refuses only the first, like an IAM binding that is granted later.
        if mode == "deny" || (mode == "deny-once" && count == 1) {
            return <http:Forbidden>{body: {'error: {code: 403, message: "Permission 'iam.serviceAccounts.getAccessToken' denied", status: "PERMISSION_DENIED"}}};
        }
        return {
            accessToken: string `sa-access-token-${testId}-${count}`,
            expireTime: time:utcToString(time:utcAddSeconds(time:utcNow(), 3600))
        };
    }

    // Mock Vertex AI. Records the `Authorization` header and returns a chat, generate, or embedding response.
    resource function post vertex/[string testId]/v1/projects/[string project]/locations/[string location]/publishers/[string publisher]/models/[string method](
            http:Request req, @http:Payload map<json> payload) returns json|error {
        string callType = method.endsWith(":predict") ? "embed" : payload.hasKey("toolConfig") ? "generate" : "chat";
        string authHeader = check req.getHeader(AUTHORIZATION_HEADER);
        lock {
            string[] headers = vertexAuthHeaders[string `${testId}/${callType}`] ?: [];
            headers.push(authHeader);
            vertexAuthHeaders[string `${testId}/${callType}`] = headers;
        }
        if callType == "embed" {
            return {predictions: [{embeddings: {values: [0.1, 0.2, 0.3]}}]};
        }
        if callType == "generate" {
            return buildGetResultsToolCallResponse("What is 1 + 1?");
        }
        return {
            candidates: [{content: {role: "model", parts: [{text: "Hi"}]}, finishReason: "STOP", index: 0}],
            usageMetadata: {promptTokenCount: 1, candidatesTokenCount: 1, totalTokenCount: 2},
            responseId: "auth-test"
        };
    }
}

function stsUrl(string testId, int expiresIn = 3600, int failAfter = 0, decimal? failDelay = (),
        boolean unavailable = false) returns string {
    string url = string `${AUTH_MOCK_URL}/sts/${testId}/${expiresIn}/${failAfter}/token?unavailable=${unavailable}`;
    return failDelay is decimal ? string `${url}&failDelay=${failDelay}` : url;
}

function vertexUrl(string testId) returns string => string `${AUTH_MOCK_URL}/vertex/${testId}`;

function wifConfig(string testId, int expiresIn = 3600, int failAfter = 0, decimal? failDelay = (),
        boolean unavailable = false, string? serviceAccountEmail = (), string iamMode = "ok")
        returns WorkloadIdentityConfig {
    string tokenUrl = stsUrl(testId, expiresIn, failAfter, failDelay, unavailable);
    if serviceAccountEmail is string {
        return {
            audience: WIF_AUDIENCE,
            identityToken: WIF_IDENTITY_TOKEN,
            serviceAccountEmail,
            tokenUrl,
            iamCredentialsUrl: string `${AUTH_MOCK_URL}/iam/${testId}/${iamMode}`
        };
    }
    return {audience: WIF_AUDIENCE, identityToken: WIF_IDENTITY_TOKEN, tokenUrl};
}

function wifProvider(string testId, WorkloadIdentityConfig config, *ConnectionConfig connectionConfig)
        returns ModelProvider|ai:Error =>
    new (config, PROJECT_ID, GEMINI_2_0_FLASH, LOCATION, vertexUrl(testId), connectionConfig = connectionConfig);

function getStsRequests(string testId) returns map<string>[] {
    lock {
        return (stsRequests[testId] ?: []).clone();
    }
}

function getVertexAuthHeaders(string testId, string callType) returns string[] {
    lock {
        return (vertexAuthHeaders[string `${testId}/${callType}`] ?: []).clone();
    }
}

function assertVertexAuth(string testId, string callType, string expected) {
    string[] headers = getVertexAuthHeaders(testId, callType);
    test:assertTrue(headers.length() > 0, string `No ${callType} request received`);
    test:assertEquals(headers[headers.length() - 1], expected);
}

function chatConcurrently(ModelProvider provider, int count) returns (ai:ChatAssistantMessage|ai:Error)[] {
    future<ai:ChatAssistantMessage|ai:Error>[] calls = [];
    foreach int i in 0 ..< count {
        future<ai:ChatAssistantMessage|ai:Error> call = start provider->chat([{role: ai:USER, content: "Hi"}]);
        calls.push(call);
    }
    (ai:ChatAssistantMessage|ai:Error)[] results = [];
    foreach future<ai:ChatAssistantMessage|ai:Error> call in calls {
        ai:ChatAssistantMessage|ai:Error result = wait call;
        results.push(result);
    }
    return results;
}

@test:Config
function testWorkloadIdentityChat() returns error? {
    string testId = "wif-chat";
    ModelProvider provider = check wifProvider(testId, wifConfig(testId));
    _ = check provider->chat([{role: ai:USER, content: "Hi"}]);
    assertVertexAuth(testId, "chat", string `Bearer sts-access-token-${testId}-1`);

    map<string>[] requests = getStsRequests(testId);
    test:assertEquals(requests.length(), 1);
    test:assertEquals(requests[0], {
        "content-type": "application/x-www-form-urlencoded",
        grant_type: "urn:ietf:params:oauth:grant-type:token-exchange",
        audience: WIF_AUDIENCE,
        scope: "https://www.googleapis.com/auth/cloud-platform",
        requested_token_type: "urn:ietf:params:oauth:token-type:access_token",
        subject_token: WIF_IDENTITY_TOKEN,
        subject_token_type: "urn:ietf:params:oauth:token-type:jwt"
    });
}

@test:Config
function testWorkloadIdentityGenerateAndEmbed() returns error? {
    string testId = "wif-generate-embed";
    // generate() goes through the native Generator, which passes the auth provider to generateLlmResponse.
    ModelProvider provider = check wifProvider(testId, wifConfig(testId));
    int result = check provider->generate(`What is 1 + 1?`);
    test:assertEquals(result, 2);
    assertVertexAuth(testId, "generate", string `Bearer sts-access-token-${testId}-1`);

    EmbeddingProvider embeddingProvider = check new (wifConfig(testId), PROJECT_ID, LOCATION, TEXT_EMBEDDING_005,
        vertexUrl(testId));
    _ = check embeddingProvider->embed(<ai:TextChunk>{content: "Hello"});
    _ = check embeddingProvider->batchEmbed([<ai:TextChunk>{content: "Hello"}, <ai:TextChunk>{content: "World"}]);
    // The embedding provider exchanges once for its own token cache.
    assertVertexAuth(testId, "embed", string `Bearer sts-access-token-${testId}-2`);
    test:assertEquals(getVertexAuthHeaders(testId, "embed").length(), 3);
    test:assertEquals(getStsRequests(testId).length(), 2);
}

@test:Config
function testWorkloadIdentityIdTokenAndScopes() returns error? {
    string testId = "wif-id-token";
    WorkloadIdentityConfig config = {
        audience: WIF_AUDIENCE,
        identityToken: string ` ${WIF_IDENTITY_TOKEN}${"\n"}`,
        identityTokenType: ID_TOKEN,
        scopes: ["https://www.googleapis.com/auth/cloud-platform", "https://www.googleapis.com/auth/userinfo.email"],
        tokenUrl: stsUrl(testId)
    };
    ModelProvider provider = check wifProvider(testId, config);
    _ = check provider->chat([{role: ai:USER, content: "Hi"}]);
    map<string> request = getStsRequests(testId)[0];
    test:assertEquals(request["subject_token_type"], "urn:ietf:params:oauth:token-type:id_token");
    test:assertEquals(request["scope"],
        "https://www.googleapis.com/auth/cloud-platform https://www.googleapis.com/auth/userinfo.email");
    // A token read from a file or an environment variable may end with a newline.
    test:assertEquals(request["subject_token"], WIF_IDENTITY_TOKEN);
}

@test:Config
function testWorkloadIdentityServiceAccountImpersonation() returns error? {
    string testId = "wif-impersonation";
    ModelProvider provider = check wifProvider(testId, wifConfig(testId, serviceAccountEmail = WIF_SERVICE_ACCOUNT));
    _ = check provider->chat([{role: ai:USER, content: "Hi"}]);
    int _ = check provider->generate(`What is 1 + 1?`);

    // The federated access token is exchanged for a service account access token, which is used for Vertex AI.
    assertVertexAuth(testId, "chat", string `Bearer sa-access-token-${testId}-1`);
    assertVertexAuth(testId, "generate", string `Bearer sa-access-token-${testId}-1`);
    test:assertEquals(getStsRequests(testId).length(), 1);
    string[]? headers;
    lock {
        headers = iamAuthHeaders[testId].clone();
    }
    json[]? requests;
    lock {
        requests = iamRequests[testId].clone();
    }
    test:assertEquals(headers, [string `Bearer sts-access-token-${testId}-1`]);
    test:assertEquals(requests, [{scope: ["https://www.googleapis.com/auth/cloud-platform"], lifetime: "3600s"}]);
}

@test:Config
function testWorkloadIdentityImpersonationScopes() returns error? {
    string testId = "wif-impersonation-scopes";
    // With impersonation, the requested scopes apply to the service account access token. The federated access
    // token is requested with `cloud-platform`, which the IAM Service Account Credentials API needs.
    WorkloadIdentityConfig config = {
        audience: WIF_AUDIENCE,
        identityToken: WIF_IDENTITY_TOKEN,
        serviceAccountEmail: WIF_SERVICE_ACCOUNT,
        scopes: ["https://www.googleapis.com/auth/userinfo.email"],
        tokenUrl: stsUrl(testId),
        iamCredentialsUrl: string `${AUTH_MOCK_URL}/iam/${testId}/ok`
    };
    ModelProvider provider = check wifProvider(testId, config);
    _ = check provider->chat([{role: ai:USER, content: "Hi"}]);
    test:assertEquals(getStsRequests(testId)[0]["scope"], "https://www.googleapis.com/auth/cloud-platform");
    json[]? requests;
    lock {
        requests = iamRequests[testId].clone();
    }
    test:assertEquals(requests, [{scope: ["https://www.googleapis.com/auth/userinfo.email"], lifetime: "3600s"}]);
}

@test:Config
function testWorkloadIdentityImpersonationDenied() returns error? {
    string testId = "wif-impersonation-denied";
    ModelProvider provider = check wifProvider(testId,
        wifConfig(testId, serviceAccountEmail = WIF_SERVICE_ACCOUNT, iamMode = "deny"));
    foreach int i in 0 ..< 2 {
        ai:ChatAssistantMessage|ai:Error result = provider->chat([{role: ai:USER, content: "Hi"}]);
        if result !is ai:LlmError {
            test:assertFail("Expected an ai:LlmError");
        }
        test:assertTrue(result.message().startsWith("Service account impersonation failed with status 403"),
            result.message());
        // The identity token is fine, so the error points to the IAM binding, not to a new identity token.
        test:assertTrue(result.message().includes("roles/iam.workloadIdentityUser"), result.message());
        test:assertFalse(result.message().includes("Create a new provider"), result.message());
    }
    // The second request is inside the backoff period, so it returns the recorded error.
    test:assertEquals(getStsRequests(testId).length(), 1);
}

@test:Config
function testWorkloadIdentityImpersonationRecoversAfterBackoff() returns error? {
    string testId = "wif-impersonation-recovers";
    // The first impersonation is refused, like an IAM binding that is still being applied. After the backoff
    // period, the exchange is tried again and succeeds.
    ModelProvider provider = check wifProvider(testId,
        wifConfig(testId, serviceAccountEmail = WIF_SERVICE_ACCOUNT, iamMode = "deny-once"));
    ai:ChatAssistantMessage|ai:Error first = provider->chat([{role: ai:USER, content: "Hi"}]);
    if first !is ai:LlmError {
        test:assertFail("Expected an ai:LlmError");
    }
    runtime:sleep(5.5);
    _ = check provider->chat([{role: ai:USER, content: "Hi"}]);
    assertVertexAuth(testId, "chat", string `Bearer sa-access-token-${testId}-2`);
    test:assertEquals(getStsRequests(testId).length(), 2);
}

@test:Config
function testWorkloadIdentityConcurrentRequestsExchangeOnce() returns error? {
    string testId = "wif-concurrent";
    ModelProvider provider = check wifProvider(testId, wifConfig(testId));
    foreach ai:ChatAssistantMessage|ai:Error result in chatConcurrently(provider, 10) {
        _ = check result;
    }
    test:assertEquals(getStsRequests(testId).length(), 1);
}

@test:Config
function testWorkloadIdentityReusesShortLivedAccessToken() returns error? {
    string testId = "wif-short-lived";
    // A 100-second access token is inside the 120-second refresh buffer from the start. It is refreshed halfway
    // through its lifetime instead, so back-to-back requests share one exchange.
    ModelProvider provider = check wifProvider(testId, wifConfig(testId, expiresIn = 100));
    _ = check provider->chat([{role: ai:USER, content: "Hi"}]);
    int _ = check provider->generate(`What is 1 + 1?`);
    test:assertEquals(getStsRequests(testId).length(), 1);
}

@test:Config
function testWorkloadIdentityDefaultLifetime() returns error? {
    string testId = "wif-no-expires-in";
    // Without `expires_in`, the access token is assumed to last one hour.
    ModelProvider provider = check wifProvider(testId, wifConfig(testId, expiresIn = 0));
    _ = check provider->chat([{role: ai:USER, content: "Hi"}]);
    _ = check provider->chat([{role: ai:USER, content: "Hi"}]);
    test:assertEquals(getStsRequests(testId).length(), 1);
}

@test:Config
function testWorkloadIdentityRefreshesAccessTokenBeforeExpiry() returns error? {
    string testId = "wif-refresh";
    // A 20-second access token is refreshed after 10 seconds, halfway through its lifetime.
    ModelProvider provider = check wifProvider(testId, wifConfig(testId, expiresIn = 20));
    _ = check provider->chat([{role: ai:USER, content: "Hi"}]);
    runtime:sleep(11);
    int _ = check provider->generate(`What is 1 + 1?`);
    test:assertEquals(getStsRequests(testId).length(), 2);
    assertVertexAuth(testId, "chat", string `Bearer sts-access-token-${testId}-1`);
    assertVertexAuth(testId, "generate", string `Bearer sts-access-token-${testId}-2`);
}

@test:Config
function testWorkloadIdentityUsesCachedTokenWhenRefreshFails() returns error? {
    string testId = "wif-refresh-fails";
    // A 20-second access token is refreshed after 10 seconds, and used until 15 seconds if the refresh fails.
    ModelProvider provider = check wifProvider(testId, wifConfig(testId, expiresIn = 20, failAfter = 1));
    _ = check provider->chat([{role: ai:USER, content: "Hi"}]);
    runtime:sleep(11);
    int _ = check provider->generate(`What is 1 + 1?`);
    test:assertEquals(getStsRequests(testId).length(), 2);
    assertVertexAuth(testId, "generate", string `Bearer sts-access-token-${testId}-1`);
}

@test:Config
function testWorkloadIdentityStopsExchangingAfterRejection() returns error? {
    string testId = "wif-rejected";
    // A rejected identity token cannot succeed later, so concurrent and later requests return the same error
    // without calling the token endpoint again.
    ModelProvider provider = check wifProvider(testId, wifConfig(testId, failAfter = -1, failDelay = 0.5));
    foreach ai:ChatAssistantMessage|ai:Error result in chatConcurrently(provider, 10) {
        if result !is ai:LlmError {
            test:assertFail("Expected an ai:LlmError");
        }
        test:assertTrue(result.message().startsWith(
            "Workload Identity Federation token exchange failed with status 400"), result.message());
        test:assertTrue(result.message().includes("Create a new provider with a new identity token"),
            result.message());
    }
    runtime:sleep(5.5);
    int|ai:Error later = provider->generate(`What is 1 + 1?`);
    if later !is ai:LlmError {
        test:assertFail("Expected an ai:LlmError after the backoff period");
    }
    test:assertEquals(getStsRequests(testId).length(), 1);
}

@test:Config
function testWorkloadIdentityBacksOffAfterTemporaryFailure() returns error? {
    string testId = "wif-backoff";
    // A temporary failure is recorded, so a request inside the backoff period returns the same error without
    // calling the token endpoint.
    ModelProvider provider = check wifProvider(testId, wifConfig(testId, failAfter = -1, unavailable = true));
    foreach int i in 0 ..< 2 {
        ai:ChatAssistantMessage|ai:Error result = provider->chat([{role: ai:USER, content: "Hi"}]);
        if result !is ai:LlmError {
            test:assertFail("Expected an ai:LlmError");
        }
        test:assertTrue(result.message().includes("status 503"), result.message());
        test:assertFalse(result.message().includes("Create a new provider"), result.message());
    }
    test:assertEquals(getStsRequests(testId).length(), 1);
}

@test:Config
function testWorkloadIdentityDoesNotRetryTokenExchange() returns error? {
    string testId = "wif-no-retry";
    // The retry configuration applies only to requests to Vertex AI, not to the token exchange.
    ModelProvider provider = check wifProvider(testId, wifConfig(testId, failAfter = -1),
        retryConfig = {count: 3, interval: 0.1, statusCodes: [400]});
    ai:ChatAssistantMessage|ai:Error result = provider->chat([{role: ai:USER, content: "Hi"}]);
    if result !is ai:LlmError {
        test:assertFail("Expected an ai:LlmError");
    }
    test:assertEquals(getStsRequests(testId).length(), 1);
}

@test:Config
function testWorkloadIdentityUnreachableTokenEndpoint() returns error? {
    WorkloadIdentityConfig config = {
        audience: WIF_AUDIENCE,
        identityToken: WIF_IDENTITY_TOKEN,
        tokenUrl: "http://localhost:8099/token"
    };
    ModelProvider provider = check wifProvider("wif-unreachable", config);
    ai:ChatAssistantMessage|ai:Error result = provider->chat([{role: ai:USER, content: "Hi"}]);
    if result !is ai:LlmConnectionError {
        test:assertFail("Expected an ai:LlmConnectionError");
    }
    test:assertEquals(result.message(), "Error while connecting to the Google Cloud Security Token Service");
}

@test:Config
function testWorkloadIdentityConfigDefaults() {
    WorkloadIdentityConfig config = {audience: WIF_AUDIENCE, identityToken: WIF_IDENTITY_TOKEN};
    test:assertEquals(config.identityTokenType, JWT);
    test:assertEquals(config.scopes, ["https://www.googleapis.com/auth/cloud-platform"]);
    test:assertEquals(config.tokenUrl, "https://sts.googleapis.com/v1/token");
    test:assertEquals(config.iamCredentialsUrl, "https://iamcredentials.googleapis.com");
    test:assertTrue(config.serviceAccountEmail is ());
    VertexAiAuth auth = config;
    test:assertTrue(auth is WorkloadIdentityConfig);
}

@test:Config
function testGenerateReturnsServiceAccountTokenError() returns error? {
    string testId = "service-account-error";
    // generate() used to ignore a failed service account token request and send the request without a token.
    // It now returns the error, like chat().
    ServiceAccountConfig config = {clientEmail: "sa@test-project.iam.gserviceaccount.com", privateKey: "not a key"};
    ModelProvider provider = check new (config, PROJECT_ID, GEMINI_2_0_FLASH, LOCATION, vertexUrl(testId));
    int|ai:Error result = provider->generate(`What is 1 + 1?`);
    if result !is ai:Error {
        test:assertFail("Expected an ai:Error");
    }
    test:assertEquals(result.message(), "Failed to obtain service account access token");
    ai:ChatAssistantMessage|ai:Error chatResult = provider->chat([{role: ai:USER, content: "Hi"}]);
    if chatResult !is ai:Error {
        test:assertFail("Expected an ai:Error");
    }
    test:assertEquals(chatResult.message(), "Failed to obtain service account access token");
    test:assertEquals(getVertexAuthHeaders(testId, "generate").length(), 0);
}

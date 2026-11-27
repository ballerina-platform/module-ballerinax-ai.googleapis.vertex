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
import ballerina/io;
import ballerina/time;

const AUTHORIZATION_HEADER = "Authorization";
const CLOUD_PLATFORM_SCOPE = "https://www.googleapis.com/auth/cloud-platform";
const DEFAULT_STS_TOKEN_URL = "https://sts.googleapis.com/v1/token";
const DEFAULT_IAM_CREDENTIALS_URL = "https://iamcredentials.googleapis.com";
const TOKEN_EXCHANGE_GRANT_TYPE = "urn:ietf:params:oauth:grant-type:token-exchange";
const ACCESS_TOKEN_TYPE = "urn:ietf:params:oauth:token-type:access_token";
const FORM_URLENCODED = "application/x-www-form-urlencoded";
// The lifetime requested for a service account access token. One hour is the default and, unless an organization
// policy allows more, the maximum.
const IMPERSONATED_TOKEN_LIFETIME = "3600s";
// Used when the token endpoint does not return `expires_in`. Google access tokens last one hour.
const decimal DEFAULT_TOKEN_LIFETIME_SECONDS = 3600;

// A cached access token is refreshed this many seconds before it expires, or halfway through its lifetime if
// that is sooner, so a short-lived access token is not exchanged again on every request.
const decimal TOKEN_REFRESH_BUFFER_SECONDS = 120;
// If a refresh fails, the cached access token is still used until this many seconds before it expires, or until
// three quarters of its lifetime if that is sooner.
const decimal TOKEN_EXPIRY_BUFFER_SECONDS = 30;
// After a token exchange fails with an error that may be temporary, the token endpoint is not called again for
// this many seconds, so concurrent requests and an outage do not call it at request rate.
const decimal TOKEN_EXCHANGE_BACKOFF_SECONDS = 5;

# The type of the identity token exchanged with Workload Identity Federation.
public enum SubjectTokenType {
    # A JWT, such as a Kubernetes service account token or a token from a self-hosted OIDC issuer
    JWT = "urn:ietf:params:oauth:token-type:jwt",
    # An OpenID Connect ID token, such as a GitHub Actions or Microsoft Entra ID token
    ID_TOKEN = "urn:ietf:params:oauth:token-type:id_token"
}

# Google Cloud Workload Identity Federation credentials. The connector exchanges an identity token (a JWT or an OIDC
# ID token) issued by your identity provider, for example Kubernetes (including Amazon EKS and Azure AKS), GitHub
# Actions, Microsoft Entra ID, or any OIDC provider, for a short-lived Google Cloud access token at the Security Token
# Service, so no service account key is needed. The access token is reused until it is about to expire, then the
# identity token is exchanged again. Google's native AWS federation, which exchanges a signed AWS request
# (`aws4_request`) instead of a token, is not supported. On AWS, use an OIDC or JWT identity provider.
# See https://cloud.google.com/iam/docs/workload-identity-federation
public type WorkloadIdentityConfig readonly & record {|
    # The full resource name of the workload identity pool provider, in the format
    # `//iam.googleapis.com/projects/PROJECT_NUMBER/locations/global/workloadIdentityPools/POOL_ID/providers/PROVIDER_ID`
    string audience;
    # The identity token (JWT) issued by your identity provider. The same identity token is used for every
    # exchange, so once it expires, create a new provider with a new identity token
    string identityToken;
    # The type of the identity token
    SubjectTokenType identityTokenType = JWT;
    # The email of a service account to impersonate. When set, the federated access token is exchanged for an
    # access token of this service account, so Vertex AI is called as the service account. When not set, Vertex AI
    # is called as the federated identity itself, which must be granted access directly
    string serviceAccountEmail?;
    # OAuth2 scopes to request. With `serviceAccountEmail`, they apply to the service account access token
    string[] scopes = [CLOUD_PLATFORM_SCOPE];
    # The URL of the Google Cloud Security Token Service token endpoint
    string tokenUrl = DEFAULT_STS_TOKEN_URL;
    # The base URL of the IAM Service Account Credentials API, used for service account impersonation
    string iamCredentialsUrl = DEFAULT_IAM_CREDENTIALS_URL;
|};

# Provides the authentication headers for each request to Vertex AI.
type AuthProvider isolated object {
    # Returns the authentication headers to send with a request.
    #
    # + return - The authentication headers, or an `ai:Error` if they could not be obtained
    isolated function getHeaders() returns map<string> & readonly|ai:Error;
};

# Adds no headers. Used for `OAuth2RefreshConfig`, where the HTTP client adds and refreshes the access token.
isolated class HttpClientAuthProvider {
    *AuthProvider;

    isolated function getHeaders() returns map<string> & readonly|ai:Error => {};
}

# Provides the headers for service account authentication. Signs a JWT with the service account key, exchanges it
# for an access token, and caches the access token until five minutes before it expires.
isolated class ServiceAccountAuthProvider {
    *AuthProvider;
    private final ServiceAccountConfig config;
    private string accessToken = "";
    private int tokenExpiryTime = 0;

    isolated function init(ServiceAccountConfig config) {
        self.config = config;
    }

    isolated function getHeaders() returns map<string> & readonly|ai:Error {
        lock {
            int currentTime = time:utcNow()[0];
            if self.accessToken.length() == 0 || currentTime >= self.tokenExpiryTime - 300 {
                string|error token = getServiceAccountToken(self.config);
                if token is error {
                    return error ai:Error("Failed to obtain service account access token", token);
                }
                self.accessToken = token;
                self.tokenExpiryTime = currentTime + 3600;
            }
            return {[AUTHORIZATION_HEADER]: string `Bearer ${self.accessToken}`};
        }
    }
}

# An access token and its lifetime.
type AccessToken record {|
    # The access token
    string token;
    # The number of seconds until the access token expires
    decimal expiresIn;
|};

# The response of the Security Token Service token endpoint.
type StsTokenResponse record {
    # The federated access token
    string access_token;
    # The number of seconds until the access token expires
    int expires_in?;
};

# The response of the IAM Service Account Credentials `generateAccessToken` method.
type GenerateAccessTokenResponse record {
    # The service account access token
    string accessToken;
    # The time the access token expires, in RFC 3339 format
    string expireTime;
};

# Provides the headers for Workload Identity Federation. Exchanges the identity token for an access token,
# caches the access token, and exchanges again before it expires.
isolated class WorkloadIdentityAuthProvider {
    *AuthProvider;
    private final http:Client stsClient;
    private final http:Client? iamClient;
    private final WorkloadIdentityConfig config;
    private string? accessToken = ();
    // The monotonic time, in seconds, after which the cached access token is refreshed.
    private decimal refreshAt = 0;
    // The monotonic time, in seconds, until which the cached access token is used if a refresh fails.
    private decimal usableUntil = 0;
    // The last failed exchange, returned without calling the token endpoint until `retryAfter`.
    private ai:Error? lastError = ();
    // The monotonic time, in seconds, before which a failed exchange is not tried again.
    private decimal retryAfter = 0;
    // Set when the identity token is rejected. The identity token does not change, so no later exchange can
    // succeed, and the token endpoints are not called again.
    private ai:Error? rejectedError = ();

    isolated function init(http:Client stsClient, http:Client? iamClient, WorkloadIdentityConfig config) {
        self.stsClient = stsClient;
        self.iamClient = iamClient;
        self.config = config;
    }

    isolated function getHeaders() returns map<string> & readonly|ai:Error {
        string accessToken = check self.getAccessToken();
        return {[AUTHORIZATION_HEADER]: string `Bearer ${accessToken}`};
    }

    # Returns the cached access token, exchanging the identity token for a new one when the cached access token
    # is about to expire. The exchange runs inside the lock so that concurrent requests trigger only one exchange.
    #
    # A failed exchange is recorded, so requests queued behind it do not call the token endpoint again. They use
    # the cached access token while it is still valid, or return the recorded error. After an error that may be
    # temporary, the exchange is tried again after `TOKEN_EXCHANGE_BACKOFF_SECONDS`. After the identity token is
    # rejected, it is never tried again.
    #
    # + return - The access token, or an `ai:Error` if the exchange fails
    isolated function getAccessToken() returns string|ai:Error {
        lock {
            decimal now = time:monotonicNow();
            string? cachedToken = self.accessToken;
            if cachedToken is string && now < self.refreshAt {
                return cachedToken;
            }
            ai:Error? recordedError = self.rejectedError ?: (now < self.retryAfter ? self.lastError : ());
            if recordedError is ai:Error {
                return cachedToken is string && now < self.usableUntil ? cachedToken : recordedError;
            }
            AccessToken|ai:Error response = exchangeIdentityToken(self.stsClient, self.iamClient, self.config);
            if response is ai:Error {
                // The exchange may have taken a while to fail, so use the current time from here on.
                decimal failedAt = time:monotonicNow();
                ai:Error exchangeError = response;
                if isIdentityTokenRejected(response) {
                    exchangeError = error ai:LlmError(string `${response.message()}. The identity token is not `
                        + "exchanged again. Create a new provider with a new identity token.", response);
                    self.rejectedError = exchangeError;
                } else {
                    self.lastError = exchangeError;
                    self.retryAfter = failedAt + TOKEN_EXCHANGE_BACKOFF_SECONDS;
                }
                // Keep using the cached access token while it is still valid.
                return cachedToken is string && failedAt < self.usableUntil ? cachedToken : exchangeError;
            }
            decimal expiresIn = response.expiresIn;
            self.accessToken = response.token;
            self.refreshAt = now + expiresIn - decimal:min(TOKEN_REFRESH_BUFFER_SECONDS, expiresIn / 2);
            self.usableUntil = now + expiresIn - decimal:min(TOKEN_EXPIRY_BUFFER_SECONDS, expiresIn / 4);
            self.lastError = ();
            self.retryAfter = 0;
            return response.token;
        }
    }
}

# Builds the headers of a JSON request to Vertex AI.
#
# + authHeaders - The authentication headers from the `AuthProvider`
# + return - The request headers
isolated function buildRequestHeaders(map<string> & readonly authHeaders) returns map<string> {
    map<string> headers = {"Content-Type": "application/json"};
    foreach [string, string] [name, value] in authHeaders.entries() {
        headers[name] = value;
    }
    return headers;
}

# Creates the authentication provider for the given authentication configuration.
#
# + auth - The authentication configuration
# + clientConfig - The HTTP client configuration, used for the Workload Identity Federation token endpoints without
# its retry configuration
# + return - The authentication provider, or an `ai:Error` if it could not be created
isolated function createAuthProvider(VertexAiAuth auth, http:ClientConfiguration clientConfig)
        returns AuthProvider|ai:Error {
    if auth is OAuth2RefreshConfig {
        return new HttpClientAuthProvider();
    }
    if auth is ServiceAccountConfig {
        return new ServiceAccountAuthProvider(auth);
    }
    if auth is ServiceAccountJsonFilePath {
        json|error fileContent = io:fileReadJson(auth);
        if fileContent is error {
            return error ai:Error("Failed to read service account key file", fileContent);
        }
        record {string client_email; string private_key;}|error saRecord = fileContent.fromJsonWithType();
        if saRecord is error {
            return error ai:Error("Invalid service account key file: missing or invalid client_email/private_key",
                saRecord);
        }
        return new ServiceAccountAuthProvider({clientEmail: saRecord.client_email, privateKey: saRecord.private_key});
    }

    // The token exchange is not retried, so that a failing identity token is not sent again and again.
    var {retryConfig: _, auth: _, ...tokenClientConfig} = clientConfig;
    http:Client|error stsClient = new (auth.tokenUrl, {...tokenClientConfig});
    if stsClient is error {
        return error ai:Error("Failed to initialize the Workload Identity Federation token client", stsClient);
    }
    http:Client? iamClient = ();
    if auth.serviceAccountEmail is string {
        http:Client|error iamCredentialsClient = new (auth.iamCredentialsUrl, {...tokenClientConfig});
        if iamCredentialsClient is error {
            return error ai:Error("Failed to initialize the service account impersonation client",
                iamCredentialsClient);
        }
        iamClient = iamCredentialsClient;
    }
    return new WorkloadIdentityAuthProvider(stsClient, iamClient, auth);
}

# Exchanges the identity token for a federated access token at the Security Token Service, then, when a service
# account is set, exchanges the federated access token for an access token of that service account.
#
# + stsClient - The HTTP client for the Security Token Service token endpoint
# + iamClient - The HTTP client for the IAM Service Account Credentials API, when a service account is set
# + config - The Workload Identity Federation configuration
# + return - The access token, or an `ai:Error` if an exchange fails
isolated function exchangeIdentityToken(http:Client stsClient, http:Client? iamClient,
        WorkloadIdentityConfig config) returns AccessToken|ai:Error {
    map<string> stsRequest = {
        grant_type: TOKEN_EXCHANGE_GRANT_TYPE,
        audience: config.audience,
        // When a service account is impersonated, the requested scopes are sent only to the IAM Service Account
        // Credentials API, as Google's auth libraries do.
        scope: config.serviceAccountEmail is string ? CLOUD_PLATFORM_SCOPE : string:'join(" ", ...config.scopes),
        requested_token_type: ACCESS_TOKEN_TYPE,
        subject_token: config.identityToken.trim(),
        subject_token_type: config.identityTokenType
    };
    StsTokenResponse|error stsResponse = stsClient->post("", stsRequest, mediaType = FORM_URLENCODED);
    if stsResponse is error {
        return toExchangeError(stsResponse, "Workload Identity Federation token exchange",
            "the Google Cloud Security Token Service");
    }
    decimal stsExpiresIn = <decimal>(stsResponse.expires_in ?: <int>DEFAULT_TOKEN_LIFETIME_SECONDS);
    string? serviceAccountEmail = config.serviceAccountEmail;
    if iamClient is () || serviceAccountEmail is () {
        return {token: stsResponse.access_token, expiresIn: stsExpiresIn};
    }

    // The requested scopes apply to the service account access token. The federated access token only needs to
    // call the IAM Service Account Credentials API, so it is always requested with `cloud-platform`.
    string path = string `/v1/projects/-/serviceAccounts/${serviceAccountEmail}:generateAccessToken`;
    map<json> iamRequest = {scope: config.scopes, lifetime: IMPERSONATED_TOKEN_LIFETIME};
    GenerateAccessTokenResponse|error iamResponse = iamClient->post(path, iamRequest,
        {[AUTHORIZATION_HEADER]: string `Bearer ${stsResponse.access_token}`});
    if iamResponse is http:ApplicationResponseError {
        // The identity token was accepted, so a 4xx here usually means the federated identity is not allowed to
        // impersonate the service account yet, or the service account email is wrong. Both can be fixed without a
        // new identity token, so the error is not a rejection of the identity token.
        http:Detail detail = iamResponse.detail();
        return error ServiceAccountImpersonationError(string `Service account impersonation failed with status ${
            detail.statusCode}: ${detail.body.toString()}. Check that the federated identity has the Workload `
            + string `Identity User role (roles/iam.workloadIdentityUser) on ${serviceAccountEmail}, and that the `
            + "service account email is correct.", iamResponse);
    }
    if iamResponse is error {
        return toExchangeError(iamResponse, "Service account impersonation",
            "the IAM Service Account Credentials API");
    }
    time:Utc|error expireTime = time:utcFromString(iamResponse.expireTime);
    decimal expiresIn = expireTime is time:Utc
        ? time:utcDiffSeconds(expireTime, time:utcNow()) : DEFAULT_TOKEN_LIFETIME_SECONDS;
    return {token: iamResponse.accessToken, expiresIn};
}

# A service account impersonation that the IAM Service Account Credentials API refused, for example because the
# federated identity does not have the Workload Identity User role on the service account yet.
type ServiceAccountImpersonationError distinct ai:LlmError;

# Converts an error from a token endpoint to an `ai:Error`.
#
# + err - The error returned by the HTTP client
# + operation - The name of the failed operation, used in the error message
# + endpoint - The name of the endpoint, used in the error message
# + return - The `ai:Error`
isolated function toExchangeError(error err, string operation, string endpoint) returns ai:Error {
    if err is http:ApplicationResponseError {
        http:Detail detail = err.detail();
        return error ai:LlmError(string `${operation} failed with status ${detail.statusCode}: ${
            detail.body.toString()}`, err);
    }
    if err is http:ClientConnectorError|http:ResiliencyError|http:SslError {
        return error ai:LlmConnectionError(string `Error while connecting to ${endpoint}`, err);
    }
    return error ai:LlmError(string `Unexpected response from ${endpoint}`, err);
}

# Returns whether the Security Token Service rejected the identity token, for example because it has expired or does
# not match the workload identity pool provider. A 4xx response other than 408 and 429 means the same identity token
# cannot succeed later. A failed service account impersonation is not a rejection of the identity token, so it is
# tried again after the backoff period.
#
# + err - The error returned by the token exchange
# + return - `true` if the identity token was rejected
isolated function isIdentityTokenRejected(ai:Error err) returns boolean {
    if err is ServiceAccountImpersonationError {
        return false;
    }
    error? cause = err.cause();
    if cause !is http:ApplicationResponseError {
        return false;
    }
    int statusCode = cause.detail().statusCode;
    return statusCode >= 400 && statusCode < 500 && statusCode != 408 && statusCode != 429;
}

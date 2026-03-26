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

import ballerina/crypto;
import ballerina/jwt;
import ballerina/oauth2;

const string GOOGLE_TOKEN_URL = "https://oauth2.googleapis.com/token";

# Builds a signed JWT assertion and exchanges it for a Google OAuth2 access token.
# A fresh JWT is built on every call so it is always within its 1-hour validity window.
isolated function getServiceAccountToken(ServiceAccountConfig config) returns string|error {
    // Step 1 — crypto + jwt: build and sign the JWT assertion
    string scope = string:'join(" ", ...config.scopes);
    crypto:PrivateKey privateKey = check crypto:decodeRsaPrivateKeyFromContent(config.privateKey.toBytes());
    jwt:IssuerConfig issuerConfig = {
        issuer: config.clientEmail,
        username: config.clientEmail,
        audience: GOOGLE_TOKEN_URL,
        expTime: 3600,
        customClaims: {"scope": scope},
        signatureConfig: {config: privateKey}
    };
    string assertion = check jwt:issue(issuerConfig);

    // Step 2 — oauth2 module: POST the assertion to the token endpoint and return access_token
    oauth2:ClientOAuth2Provider provider = new ({
        tokenUrl: GOOGLE_TOKEN_URL,
        assertion: assertion
    });
    return provider.generateToken();
}

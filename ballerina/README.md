## Overview

This module offers APIs for connecting with models hosted on
[Google Vertex AI](https://cloud.google.com/vertex-ai), including Google Gemini models and partner
models from Anthropic, Mistral, Meta, DeepSeek, Qwen, Kimi, and MiniMax available through the
Vertex AI Model Garden.

## Prerequisites

Before using this module in your Ballerina application, you must have a Google Cloud project with
Vertex AI enabled.

- Create a [Google Cloud account](https://cloud.google.com) and set up a project.
- Enable the [Vertex AI API](https://console.cloud.google.com/apis/library/aiplatform.googleapis.com) for your project.
- Set up authentication using one of the supported methods below.

## Quickstart

To use the `ai.googleapis.vertex` module in your Ballerina application, update the `.bal` file as follows:

### Step 1: Import the module

Import the `ai.googleapis.vertex` module.

```ballerina
import ballerinax/ai.googleapis.vertex;
```

### Step 2: Initialize the Model Provider

Four authentication options are supported:

**Option 1 — OAuth2 refresh token** (recommended for development; credentials from `~/.config/gcloud/application_default_credentials.json`):

```ballerina
import ballerina/ai;
import ballerinax/ai.googleapis.vertex;

final ai:ModelProvider vertexModel = check new vertex:ModelProvider(
    auth = {
        clientId: "your-client-id",
        clientSecret: "your-client-secret",
        refreshToken: "your-refresh-token"
    },
    projectId = "your-gcp-project-id",
    location = "us-central1",
    model = "google/gemini-2.0-flash"
);
```

**Option 2 — Service account JSON key file** (recommended for production):

```ballerina
final ai:ModelProvider vertexModel = check new vertex:ModelProvider(
    auth = "/path/to/service-account-key.json",
    projectId = "your-gcp-project-id",
    location = "us-central1",
    model = "google/gemini-2.0-flash"
);
```

**Option 3 — Service account inline credentials** (use when you need to override scopes):

```ballerina
final ai:ModelProvider vertexModel = check new vertex:ModelProvider(
    auth = {
        clientEmail: "your-sa@your-project.iam.gserviceaccount.com",
        privateKey: "-----BEGIN RSA PRIVATE KEY-----\n..."
    },
    projectId = "your-gcp-project-id",
    location = "us-central1",
    model = "google/gemini-2.0-flash"
);
```

**Option 4 — Workload Identity Federation** (for workloads outside Google Cloud whose identity provider issues OIDC tokens or JWTs, such as Kubernetes including Amazon EKS and Azure AKS, GitHub Actions, or Microsoft Entra ID, with no service account key):

```ballerina
final ai:ModelProvider vertexModel = check new vertex:ModelProvider(
    auth = {
        audience: "//iam.googleapis.com/projects/PROJECT_NUMBER/locations/global/workloadIdentityPools/POOL_ID/providers/PROVIDER_ID",
        identityToken: "<identity token (JWT) from your identity provider>",
        // Optional. Call Vertex AI as this service account instead of as the federated identity.
        serviceAccountEmail: "your-sa@your-project.iam.gserviceaccount.com"
    },
    projectId = "your-gcp-project-id",
    location = "us-central1",
    model = "google/gemini-2.0-flash"
);
```

The connector exchanges the identity token for a short-lived access token at the Google Cloud Security Token Service, and, when `serviceAccountEmail` is set, for an access token of that service account. It reuses the access token until it is about to expire, then exchanges the identity token again. Once the identity token expires or is rejected, create a new model provider with a new identity token. Grant the federated identity (or, with `serviceAccountEmail`, the service account) the Vertex AI User role (`roles/aiplatform.user`). See [Workload Identity Federation](https://cloud.google.com/iam/docs/workload-identity-federation) to set up the workload identity pool and provider. Google's native AWS federation, which exchanges a signed AWS request (`aws4_request`) instead of a token, is not supported. On AWS, use an OIDC or JWT identity provider, such as Amazon EKS service account tokens.

A module-level `final` provider, as above, cannot be replaced. Use one only when the identity token outlives the application. Many identity tokens expire within an hour, for example Kubernetes projected service account tokens and GitHub Actions OIDC tokens. For those, create the provider where you can replace it, and create a new one with a new identity token before the old identity token expires.

### Step 3: Invoke chat completion

```ballerina
ai:ChatMessage[] chatMessages = [{role: "user", content: "hi"}];
ai:ChatAssistantMessage response = check vertexModel->chat(chatMessages, tools = []);

chatMessages.push(response);
```

### Step 4: Generate typed output

```ballerina
type Sentiment record {|
    string label;
    decimal score;
|};

@ai:JsonSchema {
    "type": "object",
    "required": ["label", "score"],
    "properties": {
        "label": {"type": "string", "enum": ["positive", "neutral", "negative"]},
        "score": {"type": "number"}
    }
}
type SentimentType Sentiment;

Sentiment|error result = vertexModel->generate(
    `Analyze the sentiment of: "I love this product!"`
);
```

### Step 5: Use an embedding provider

```ballerina
import ballerina/ai;
import ballerinax/ai.googleapis.vertex;

final ai:EmbeddingProvider vertexEmbedding = check new vertex:EmbeddingProvider(
    auth = "/path/to/service-account-key.json",
    projectId = "your-gcp-project-id",
    location = "us-central1"
);

ai:Embedding embedding = check vertexEmbedding->embed(<ai:TextChunk>{content: "Hello, world!"});
```

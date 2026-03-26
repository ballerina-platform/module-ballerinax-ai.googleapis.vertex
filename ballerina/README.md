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
- Obtain a valid OAuth2 access token (e.g., via `gcloud auth print-access-token`).

## Quickstart

To use the `ai.googleapis.vertex` module in your Ballerina application, update the `.bal` file as follows:

### Step 1: Import the module

Import the `ai.googleapis.vertex` module.

```ballerina
import ballerinax/ai.googleapis.vertex;
```

### Step 2: Initialize the Model Provider

Here's how to initialize the Model Provider:

```ballerina
import ballerina/ai;
import ballerinax/ai.googleapis.vertex;

final ai:ModelProvider vertexModel = check new vertex:ModelProvider(
    accessToken = "your-gcp-access-token",
    projectId = "your-gcp-project-id",
    location = "us-central1",
    model = "google/gemini-2.0-flash"
);
```

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
    accessToken = "your-gcp-access-token",
    projectId = "your-gcp-project-id",
    location = "us-central1",
    model = "text-embedding-005"
);

ai:Embedding embedding = check vertexEmbedding->embed(<ai:TextChunk>{content: "Hello, world!"});
```

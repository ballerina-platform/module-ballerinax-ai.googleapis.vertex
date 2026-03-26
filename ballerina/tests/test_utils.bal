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

const GET_RESULTS_TOOL_NAME = "getResults";

isolated function getExpectedParameterSchema(string message) returns map<json> {
    if message.startsWith("Evaluate this") {
        return expectedParameterSchemaStringForRateBlog6;
    }
    if message.startsWith("Rate this blog") {
        return expectedParameterSchemaStringForRateBlog;
    }
    if message.startsWith("Please rate this blog") {
        return expectedParameterSchemaStringForRateBlog2;
    }
    if message.startsWith("What is") {
        return expectedParameterSchemaStringForRateBlog3;
    }
    if message.startsWith("Tell me") {
        return expectedParameterSchemaStringForRateBlog4;
    }
    if message.startsWith("How would you rate this") {
        return expectedParameterSchemaStringForRateBlog;
    }
    if message.startsWith("Which country") {
        return expectedParamterSchemaStringForCountry;
    }
    if message.startsWith("Describe the following image") {
        return expectedParameterSchemaStringForRateBlog8;
    }
    if message.startsWith("Describe the image") {
        return expectedParameterSchemaStringForRateBlog8;
    }
    if message.startsWith("Give me a random joke") {
        return {"type": "object", "properties": {"result": {"anyOf": [{"type": "string"}, {"type": "null"}]}}};
    }
    return {};
}

isolated function getTheMockLLMResult(string message) returns string {
    if message.startsWith("Evaluate this") {
        return string `{"result": [9, 1]}`;
    }
    if message.startsWith("Rate this blog") {
        return "{\"result\": 4}";
    }
    if message.startsWith("Please rate this blog") {
        return review;
    }
    if message.startsWith("What is") {
        return "{\"result\": 2}";
    }
    if message.startsWith("Tell me") {
        return "{\"result\": [{\"name\": \"Virat Kohli\", \"age\": 33}, {\"name\": \"Kane Williamson\", \"age\": 30}]}";
    }
    if message.startsWith("Which country") {
        return "{\"result\": \"Sri Lanka\"}";
    }
    if message.startsWith("How would you rate this") {
        return "{\"result\": 4}";
    }
    if message.startsWith("Describe the following image") {
        return "{\"result\": \"This is a sample image description.\"}";
    }
    if message.startsWith("Describe the image") {
        return "{\"result\": \"This is a sample image description.\"}";
    }
    if message.startsWith("Give me a random joke") {
        return "{\"result\": \"This is a random joke\"}";
    }
    return "INVALID";
}

# Builds a Vertex AI generateContent response that calls the getResults tool
# with the given arguments JSON string.
isolated function buildGetResultsToolCallResponse(string content) returns json|error {
    json args = check getTheMockLLMResult(content).fromJsonString();
    return {
        "candidates": [
            {
                "content": {
                    "role": "model",
                    "parts": [
                        {
                            "functionCall": {
                                "name": GET_RESULTS_TOOL_NAME,
                                "args": args
                            }
                        }
                    ]
                },
                "finishReason": "STOP",
                "index": 0
            }
        ],
        "usageMetadata": {
            "promptTokenCount": 10,
            "candidatesTokenCount": 20,
            "totalTokenCount": 30
        },
        "responseId": "test-response-id",
        "modelVersion": "gemini-2.0-flash-001"
    };
}

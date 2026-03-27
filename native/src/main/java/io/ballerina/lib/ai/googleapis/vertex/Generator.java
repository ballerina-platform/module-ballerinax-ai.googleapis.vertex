/*
 * Copyright (c) 2026, WSO2 LLC. (https://www.wso2.com).
 *
 * WSO2 LLC. licenses this file to you under the Apache License,
 * Version 2.0 (the "License"); you may not use this file except
 * in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing,
 * software distributed under the License is distributed on an
 * "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 * KIND, either express or implied. See the License for the
 * specific language governing permissions and limitations
 * under the License.
 */
package io.ballerina.lib.ai.googleapis.vertex;

import io.ballerina.runtime.api.Environment;
import io.ballerina.runtime.api.Module;
import io.ballerina.runtime.api.utils.StringUtils;
import io.ballerina.runtime.api.values.BMap;
import io.ballerina.runtime.api.values.BObject;
import io.ballerina.runtime.api.values.BTypedesc;

/**
 * This class provides the native function to generate a typed response from a Vertex AI model.
 *
 * @since 1.0.0
 */
public class Generator {

    /**
     * Bridges the Ballerina {@code ModelProvider.generate()} external declaration to the
     * {@code generateLlmResponse} function defined in {@code provider_utils.bal}.
     *
     * @param env                        the Ballerina runtime environment
     * @param modelProvider              the {@code ModelProvider} client object
     * @param prompt                     the {@code ai:Prompt} value
     * @param expectedResponseTypedesc   the typedesc of the expected return type
     * @return the generated value or an error
     */
    public static Object generate(Environment env, BObject modelProvider,
                                  BObject prompt, BTypedesc expectedResponseTypedesc) {
        Object auth = modelProvider.get(StringUtils.fromString("auth"));
        if (auth instanceof BMap && ((BMap<?, ?>) auth).getType().getName().equals("ServiceAccountConfig")) {
            env.getRuntime().callMethod(modelProvider, "getAccessToken", null);
        }
        return env.getRuntime().callFunction(
                new Module("ballerinax", "ai.googleapis.vertex", "1"), "generateLlmResponse", null,
                modelProvider.get(StringUtils.fromString("vertexAiClient")),
                modelProvider.get(StringUtils.fromString("accessToken")),
                modelProvider.get(StringUtils.fromString("modelType")),
                modelProvider.get(StringUtils.fromString("projectId")),
                modelProvider.get(StringUtils.fromString("location")),
                modelProvider.get(StringUtils.fromString("publisher")),
                modelProvider.get(StringUtils.fromString("maxTokens")),
                modelProvider.get(StringUtils.fromString("temperature")),
                prompt, expectedResponseTypedesc);
    }
}

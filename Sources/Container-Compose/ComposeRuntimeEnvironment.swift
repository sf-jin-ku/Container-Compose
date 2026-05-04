//===----------------------------------------------------------------------===//
// Copyright © 2025 Morris Richman and the Container-Compose project authors. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import Foundation

func composeRuntimeEnvironment(
    for service: Service,
    composeDirectory: String,
    interpolationEnvironment: [String: String],
    containerIps: [String: String]
) throws -> [String: String] {
    var combinedEnv: [String: String] = [:]

    if let envFileConfigurations = service.envFileConfigurations {
        let composeDirectoryURL = URL(fileURLWithPath: composeDirectory)
        for envFile in envFileConfigurations {
            if let format = envFile.format {
                throw ComposeError.unsupportedRuntimeOption(
                    "service env_file '\(envFile.path)' uses unsupported format '\(format)'"
                )
            }
            let additionalEnvVars = try loadEnvFile(
                path: URL(fileURLWithPath: envFile.path, relativeTo: composeDirectoryURL).path,
                required: envFile.required ?? true
            )
            combinedEnv.merge(additionalEnvVars) { _, new in new }
        }
    } else if let envFiles = service.env_file {
        let composeDirectoryURL = URL(fileURLWithPath: composeDirectory)
        for envFile in envFiles {
            let additionalEnvVars = try loadEnvFile(
                path: URL(fileURLWithPath: envFile, relativeTo: composeDirectoryURL).path,
                required: true
            )
            combinedEnv.merge(additionalEnvVars) { _, new in new }
        }
    }

    if let serviceEnv = service.environment {
        combinedEnv.merge(serviceEnv) { _, new in new }
    }

    let interpolationScope = interpolationEnvironment.merging(combinedEnv) { _, serviceValue in serviceValue }
    combinedEnv = combinedEnv.mapValues { value in
        guard value.contains("${") else { return value }
        return resolveVariable(value, with: interpolationScope)
    }

    return combinedEnv.mapValues { value in
        containerIps[value] ?? value
    }
}

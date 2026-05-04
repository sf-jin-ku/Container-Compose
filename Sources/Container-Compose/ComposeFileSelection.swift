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

struct ComposeFileSelection {
    static let supportedComposeFilenames = [
        "compose.yml",
        "compose.yaml",
        "docker-compose.yml",
        "docker-compose.yaml",
    ]

    let paths: [String]

    var primaryPath: String {
        paths[0]
    }

    var primaryDirectory: String {
        URL(fileURLWithPath: primaryPath).deletingLastPathComponent().path
    }

    static func resolve(
        explicitFilenames: [String],
        cwd: String,
        fileManager: FileManager = .default
    ) -> ComposeFileSelection {
        let cwdURL = URL(fileURLWithPath: cwd)
        if !explicitFilenames.isEmpty {
            return ComposeFileSelection(paths: explicitFilenames.map { resolvedPath(for: $0, relativeTo: cwdURL) })
        }

        for filename in supportedComposeFilenames {
            let candidate = cwdURL.appending(path: filename).path
            if fileManager.fileExists(atPath: candidate) {
                return ComposeFileSelection(paths: [candidate])
            }
        }

        return ComposeFileSelection(paths: [cwdURL.appending(path: supportedComposeFilenames[0]).path])
    }

    func load(
        fileManager: FileManager = .default,
        environmentVariables: [String: String] = [:]
    ) throws -> DockerCompose {
        if let missingPath = paths.first(where: { !fileManager.fileExists(atPath: $0) }) {
            throw YamlError.composeFileNotFound(URL(fileURLWithPath: missingPath).deletingLastPathComponent().path)
        }
        return try DockerComposeLoader(environmentVariables: environmentVariables).load(files: paths)
    }
}

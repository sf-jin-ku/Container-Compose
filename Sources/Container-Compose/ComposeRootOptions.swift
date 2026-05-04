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

import ArgumentParser
import Foundation

private enum RootComposeOptionKind {
    case file
    case profile
    case envFile
    case projectDirectory
}

private struct RootComposeOption {
    let kind: RootComposeOptionKind
    let tokens: [String]
}

public func normalizeRootComposeOptions(_ args: [String]) throws -> [String] {
    let composeSubcommands: Set<String> = [
        "up",
        "down",
        "build",
        "pull",
        "ps",
        "logs",
        "exec",
        "start",
        "stop",
        "restart",
    ]
    var rootOptions: [RootComposeOption] = []
    var index = 0

    while index < args.count {
        let arg = args[index]
        if composeSubcommands.contains(arg) {
            return [arg] + normalizedRootOptionTokens(rootOptions, for: arg) + Array(args.dropFirst(index + 1))
        }
        if arg == "--" || arg == "-h" || arg == "--help" || arg == "--version" {
            return args
        }
        if let parsed = try parseRootComposeOption(args: args, index: &index) {
            rootOptions.append(parsed)
            continue
        }
        return args
    }

    return args
}

private func normalizedRootOptionTokens(_ options: [RootComposeOption], for subcommand: String) -> [String] {
    options.flatMap { option in
        guard subcommand == "exec", option.kind == .envFile else {
            return option.tokens
        }
        return option.tokens.map { token in
            if token == "--env-file" {
                return "--compose-env-file"
            }
            if token.hasPrefix("--env-file=") {
                return token.replacingOccurrences(of: "--env-file=", with: "--compose-env-file=")
            }
            return token
        }
    }
}

private func parseRootComposeOption(args: [String], index: inout Int) throws -> RootComposeOption? {
    let arg = args[index]
    if arg == "-f" {
        return try consumeRootComposeOption(args: args, index: &index, kind: .file, name: arg)
    }
    if arg.hasPrefix("-f"), arg.count > 2 {
        index += 1
        return RootComposeOption(kind: .file, tokens: [arg])
    }

    let valueOptions: [String: RootComposeOptionKind] = [
        "--file": .file,
        "--profile": .profile,
        "--env-file": .envFile,
        "--project-directory": .projectDirectory,
    ]

    if let kind = valueOptions[arg] {
        return try consumeRootComposeOption(args: args, index: &index, kind: kind, name: arg)
    }

    for (prefix, kind) in valueOptions {
        let equalsPrefix = "\(prefix)="
        if arg.hasPrefix(equalsPrefix), arg.count > equalsPrefix.count {
            index += 1
            return RootComposeOption(kind: kind, tokens: [arg])
        }
    }

    return nil
}

private func consumeRootComposeOption(
    args: [String],
    index: inout Int,
    kind: RootComposeOptionKind,
    name: String
) throws -> RootComposeOption {
    guard index + 1 < args.count else {
        throw ValidationError("Missing value for \(name)")
    }
    let value = args[index + 1]
    guard value != "--" else {
        throw ValidationError("Missing value for \(name)")
    }
    index += 2
    return RootComposeOption(kind: kind, tokens: [name, value])
}

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

//
//  Helper Functions.swift
//  container-compose-app
//
//  Created by Morris Richman on 6/17/25.
//

import Foundation
import Yams
import Rainbow
import ContainerCommands

public func resolvedPath(for path: String, relativeTo baseURL: URL) -> String {
    let expandedPath = NSString(string: path).expandingTildeInPath
    return URL(fileURLWithPath: expandedPath, relativeTo: baseURL).standardizedFileURL.path
}


/// Loads environment variables from a .env file.
/// - Parameter path: The full path to the .env file.
/// - Returns: A dictionary of key-value pairs representing environment variables.
public func loadEnvFile(path: String) -> [String: String] {
    (try? loadEnvFile(path: path, required: false)) ?? [:]
}

public func loadEnvFile(path: String, required: Bool) throws -> [String: String] {
    var envVars: [String: String] = [:]
    let fileURL = URL(fileURLWithPath: path)
    do {
        let content = try String(contentsOf: fileURL, encoding: .utf8)
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines {
            var trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            // Ignore empty lines and comments
            if !trimmedLine.isEmpty && !trimmedLine.starts(with: "#") {
                if trimmedLine.hasPrefix("export ") {
                    trimmedLine = String(trimmedLine.dropFirst("export ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                // Parse key=value pairs
                if let eqIndex = trimmedLine.firstIndex(of: "=") {
                    let key = String(trimmedLine[..<eqIndex]).trimmingCharacters(in: .whitespaces)
                    var value = String(trimmedLine[trimmedLine.index(after: eqIndex)...]).trimmingCharacters(in: .whitespaces)
                    if value.count >= 2,
                       let first = value.first,
                       let last = value.last,
                       (first == "\"" && last == "\"") || (first == "'" && last == "'") {
                        value = String(value.dropFirst().dropLast())
                    }
                    envVars[key] = value
                }
            }
        }
    } catch {
        if required {
            throw ComposeError.missingEnvFile("required env_file '\(path)' could not be read: \(error.localizedDescription)")
        }
        // print("Warning: Could not read .env file at \(path): \(error.localizedDescription)")
        // Suppress error message if .env file is optional or missing
    }
    return envVars
}

public func loadEnvFiles(paths: [String]) -> [String: String] {
    var envVars: [String: String] = [:]
    for path in paths {
        envVars.merge(loadEnvFile(path: path)) { _, new in new }
    }
    return envVars
}

public func activeComposeProfiles(cliProfiles: [String]) -> [String] {
    let environmentProfiles = ProcessInfo.processInfo.environment["COMPOSE_PROFILES"]?
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty } ?? []
    var seen = Set<String>()
    return (cliProfiles + environmentProfiles).filter { seen.insert($0).inserted }
}

public func composeProjectLabelArguments(
    projectName: String,
    serviceName: String,
    workingDirectory: String,
    composeFilePaths: [String]
) -> [String] {
    [
        "com.docker.compose.project=\(projectName)",
        "com.docker.compose.service=\(serviceName)",
        "com.docker.compose.project.working_dir=\(workingDirectory)",
        "com.docker.compose.project.config_files=\(composeFilePaths.joined(separator: ","))",
    ].flatMap { ["--label", $0] }
}

public func composeShellSplit(_ input: String) -> [String] {
    enum Quote {
        case single
        case double
    }

    var tokens: [String] = []
    var current = ""
    var quote: Quote?
    var escaping = false
    var tokenStarted = false

    for character in input {
        if escaping {
            current.append(character)
            tokenStarted = true
            escaping = false
            continue
        }

        switch quote {
        case .single:
            if character == "'" {
                quote = nil
            } else {
                current.append(character)
            }
        case .double:
            if character == "\"" {
                quote = nil
            } else if character == "\\" {
                escaping = true
            } else {
                current.append(character)
            }
        case nil:
            if character == "\\" {
                escaping = true
                tokenStarted = true
            } else if character == "'" {
                quote = .single
                tokenStarted = true
            } else if character == "\"" {
                quote = .double
                tokenStarted = true
            } else if character.isWhitespace {
                if tokenStarted {
                    tokens.append(current)
                    current = ""
                    tokenStarted = false
                }
            } else {
                current.append(character)
                tokenStarted = true
            }
        }
    }

    if escaping {
        current.append("\\")
    }
    if tokenStarted {
        tokens.append(current)
    }
    return tokens
}

/// Resolves environment variables within a string (e.g., ${VAR:-default}, ${VAR:?error}).
/// This function supports default values and error-on-missing variable syntax.
/// - Parameters:
///   - value: The string possibly containing environment variable references.
///   - envVars: A dictionary of environment variables to use for resolution.
/// - Returns: The string with all recognized environment variables resolved.
public func resolveVariable(_ value: String, with envVars: [String: String]) -> String {
    let combinedEnv = ProcessInfo.processInfo.environment.merging(envVars) { (current, _) in current }
    return resolveVariableReferences(in: value, with: combinedEnv)
}

private func resolveVariableReferences(in value: String, with envVars: [String: String]) -> String {
    var resolvedValue = ""
    var index = value.startIndex

    while index < value.endIndex {
        guard value[index] == "$" else {
            resolvedValue.append(value[index])
            index = value.index(after: index)
            continue
        }

        let afterDollar = value.index(after: index)
        guard afterDollar < value.endIndex else {
            resolvedValue.append(value[index])
            index = afterDollar
            continue
        }

        if value[afterDollar] == "$" {
            resolvedValue.append("$")
            index = value.index(after: afterDollar)
            continue
        }

        guard value[afterDollar] == "{" else {
            guard let nameEnd = unbracedVariableNameEnd(in: value, start: afterDollar),
                  nameEnd > afterDollar
            else {
                resolvedValue.append(value[index])
                index = afterDollar
                continue
            }

            let variableName = String(value[afterDollar..<nameEnd])
            if let resolvedExpression = resolveComposeExpression(variableName, with: envVars) {
                resolvedValue.append(resolvedExpression)
            } else {
                resolvedValue.append(contentsOf: value[index..<nameEnd])
            }
            index = nameEnd
            continue
        }

        guard let closingBrace = matchingClosingBrace(in: value, openingBrace: afterDollar) else {
            resolvedValue.append(value[index])
            index = afterDollar
            continue
        }

        let expressionStart = value.index(after: afterDollar)
        let expression = String(value[expressionStart..<closingBrace])
        if let resolvedExpression = resolveComposeExpression(expression, with: envVars) {
            resolvedValue.append(resolvedExpression)
        } else {
            resolvedValue.append(contentsOf: value[index...closingBrace])
        }
        index = value.index(after: closingBrace)
    }

    return resolvedValue
}

private func unbracedVariableNameEnd(in value: String, start: String.Index) -> String.Index? {
    var index = start
    while index < value.endIndex {
        let character = value[index]
        guard character.isASCII && (character.isLetter || character.isNumber || character == "_") else {
            break
        }
        index = value.index(after: index)
    }
    return index
}

private func matchingClosingBrace(in value: String, openingBrace: String.Index) -> String.Index? {
    var depth = 1
    var index = value.index(after: openingBrace)

    while index < value.endIndex {
        if value[index] == "$" {
            let next = value.index(after: index)
            if next < value.endIndex, value[next] == "{" {
                depth += 1
                index = value.index(after: next)
                continue
            }
        }

        if value[index] == "}" {
            depth -= 1
            if depth == 0 {
                return index
            }
        }

        index = value.index(after: index)
    }

    return nil
}

private func resolveComposeExpression(_ expression: String, with envVars: [String: String]) -> String? {
    let nameEnd = expression.firstIndex { character in
        !(character.isASCII && (character.isLetter || character.isNumber || character == "_"))
    } ?? expression.endIndex
    guard nameEnd > expression.startIndex else { return nil }

    let variableName = String(expression[..<nameEnd])
    let suffix = String(expression[nameEnd...])
    let envValue = envVars[variableName]
    let isSet = envValue != nil
    let isNonEmpty = !(envValue?.isEmpty ?? true)

    if suffix.isEmpty {
        return envValue
    }

    if suffix.hasPrefix(":-") {
        return isNonEmpty ? envValue : resolveVariableReferences(in: String(suffix.dropFirst(2)), with: envVars)
    }

    if suffix.hasPrefix("-") {
        return isSet ? envValue : resolveVariableReferences(in: String(suffix.dropFirst()), with: envVars)
    }

    if suffix.hasPrefix(":?") {
        if isNonEmpty {
            return envValue
        }
        let errorMessage = resolveVariableReferences(in: String(suffix.dropFirst(2)), with: envVars)
        fputs("Error: Missing required environment variable '\(variableName)': \(errorMessage)\n", stderr)
        Application.exit(withError: "Error: Missing required environment variable '\(variableName)': \(errorMessage)\n")
    }

    if suffix.hasPrefix("?") {
        if isSet {
            return envValue
        }
        let errorMessage = resolveVariableReferences(in: String(suffix.dropFirst()), with: envVars)
        fputs("Error: Missing required environment variable '\(variableName)': \(errorMessage)\n", stderr)
        Application.exit(withError: "Error: Missing required environment variable '\(variableName)': \(errorMessage)\n")
    }

    return nil
}

/// Derives a project name from the current working directory. It replaces any '.' characters with
/// '_' to ensure compatibility with container naming conventions.
///
/// - Parameter cwd: The current working directory path.
/// - Returns: A sanitized project name suitable for container naming.
public func deriveProjectName(cwd: String) -> String {
    // We need to replace '.' with _ because it is not supported in the container name
    sanitizeComposeProjectName(URL(fileURLWithPath: cwd).lastPathComponent)
}

public func sanitizeComposeProjectName(_ name: String) -> String {
    let sanitized = String(name.map { character in
        character.isASCII && (character.isLetter || character.isNumber || character == "-" || character == "_") ? character : "_"
    })
    return sanitized.isEmpty ? "default" : sanitized
}

public let appleContainerNameMaxLength = 64

public func composeGeneratedContainerName(projectName: String, serviceName: String) -> String {
    let rawName = "\(projectName)-\(serviceName)-1"
    guard rawName.count > appleContainerNameMaxLength else { return rawName }

    let hash = fnv1a64(rawName)
    let suffix = "-" + String(hash, radix: 16, uppercase: false)
    let prefixLength = max(1, appleContainerNameMaxLength - suffix.count)
    return String(rawName.prefix(prefixLength)) + suffix
}

private func fnv1a64(_ value: String) -> UInt64 {
    var hash: UInt64 = 0xcbf29ce484222325
    for byte in value.utf8 {
        hash ^= UInt64(byte)
        hash &*= 0x100000001b3
    }
    return hash
}

func imageReferenceMatches(localReference: String, requestedReference: String) -> Bool {
    if localReference == requestedReference {
        return true
    }

    let localParts = localReference.split(separator: "/").map(String.init)
    let requestedParts = requestedReference.split(separator: "/").map(String.init)
    guard let localLeaf = localParts.last, let requestedLeaf = requestedParts.last else {
        return false
    }

    if requestedParts.count == 1 {
        return localLeaf == requestedLeaf
    }
    return localReference.hasSuffix(requestedReference)
}

/// Converts Docker Compose port specification into a container run -p format.
/// Handles various formats: "PORT", "HOST:PORT", "IP:HOST:PORT", and optional protocol.
/// - Parameter portSpec: The port specification string from docker-compose.yml.
/// - Returns: A properly formatted port binding for `container run -p`.
public func composePortToRunArg(_ portSpec: String) -> String {
    // Check for protocol suffix (e.g., "/tcp" or "/udp")
    var protocolSuffix = ""
    var portBody = portSpec
    if let slashRange = portSpec.range(of: "/", options: [.backwards]) {
        let afterSlash = portSpec[slashRange.lowerBound...]
        let protocolPart = String(afterSlash)
        if protocolPart == "/tcp" || protocolPart == "/udp" {
            protocolSuffix = protocolPart
            portBody = String(portSpec[..<slashRange.lowerBound])
        }
    }

    let components = portBody.split(separator: ":", maxSplits: 3).map(String.init)
    switch components.count {
    case 1:
        let containerPort = components[0]
        return "0.0.0.0:\(containerPort):\(containerPort)\(protocolSuffix)"
    case 2:
        let hostPart = components[0]
        let containerPart = components[1]
        let hasIPv4 = hostPart.contains(".")
        let hasIPv6 = hostPart.contains(":") && hostPart.hasPrefix("[") && hostPart.hasSuffix("]")
        if hasIPv4 || hasIPv6 {
            return "\(hostPart):\(containerPart)\(protocolSuffix)"
        } else {
            return "0.0.0.0:\(hostPart):\(containerPart)\(protocolSuffix)"
        }
    case 3:
        let ipPart = components[0]
        let hostPart = components[1]
        let containerPart = components[2]
        return "\(ipPart):\(hostPart):\(containerPart)\(protocolSuffix)"
    default:
        return portSpec
    }
}

extension String: @retroactive Error {}

/// A structure representing the result of a command-line process execution.
public struct CommandResult {
    /// The standard output captured from the process.
    public let stdout: String

    /// The standard error output captured from the process.
    public let stderr: String

    /// The exit code returned by the process upon termination.
    public let exitCode: Int32
}

extension NamedColor: @retroactive Codable {

}

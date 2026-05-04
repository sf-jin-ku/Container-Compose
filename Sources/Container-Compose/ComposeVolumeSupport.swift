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

let composeVolumeNamePattern = "^[A-Za-z0-9][A-Za-z0-9_.-]*$"
let appleContainerVolumeNameMaxLength = 255

struct ComposeVolumeReference: Equatable {
    let source: String?
    let destination: String
    let options: [String]

    var optionSuffix: String {
        options.isEmpty ? "" : ":\(options.joined(separator: ","))"
    }
}

struct ComposeVolumeCreateCandidate {
    let volumeKey: String
    let volume: Volume
}

func parseComposeVolumeReference(
    _ volume: String,
    environmentVariables: [String: String] = [:]
) -> ComposeVolumeReference? {
    let resolvedVolume = resolveVariable(volume, with: environmentVariables)
    let components = resolvedVolume.split(
        separator: ":",
        maxSplits: 2,
        omittingEmptySubsequences: false
    ).map(String.init)

    switch components.count {
    case 1:
        guard !components[0].isEmpty else { return nil }
        return ComposeVolumeReference(source: nil, destination: components[0], options: [])
    case 2, 3:
        guard !components[0].isEmpty, !components[1].isEmpty else { return nil }
        let options = components.count == 3
            ? components[2].split(separator: ",").map(String.init).filter { !$0.isEmpty }
            : []
        return ComposeVolumeReference(source: components[0], destination: components[1], options: options)
    default:
        return nil
    }
}

func composeVolumeName(projectName: String, volumeKey: String, volume: Volume?) -> String {
    if volume?.external?.isExternal == true {
        return volume?.external?.name ?? volume?.name ?? volumeKey
    }
    if let name = volume?.name, !name.isEmpty {
        return name
    }
    return "\(projectName)_\(volumeKey)"
}

func composeVolumeIsExternal(_ volume: Volume?) -> Bool {
    volume?.external?.isExternal == true
}

func composeVolumeMountArgument(
    _ volume: String,
    projectName: String,
    topLevelVolumes: [String: Volume?]?,
    environmentVariables: [String: String],
    composeDirectory: String,
    fileManager: FileManager = .default
) throws -> String? {
    guard let reference = parseComposeVolumeReference(volume, environmentVariables: environmentVariables) else {
        return nil
    }
    guard let source = reference.source else {
        throw ComposeError.unsupportedRuntimeOption(
            "anonymous service volume '\(reference.destination)' is unsupported because down -v cannot identify a cleanup target"
        )
    }

    if composeVolumeSourceIsBindMount(source) {
        let hostPath = try composeBindMountSourcePath(
            source,
            composeDirectory: composeDirectory,
            fileManager: fileManager
        )
        return "\(hostPath):\(reference.destination)\(reference.optionSuffix)"
    }

    let volumeConfig = topLevelVolumes?[source] ?? nil
    let actualVolumeName = composeVolumeName(projectName: projectName, volumeKey: source, volume: volumeConfig)
    try validateComposeVolumeName(actualVolumeName)
    return "\(actualVolumeName):\(reference.destination)\(reference.optionSuffix)"
}

func composeReferencedTopLevelVolumeKeys(
    topLevelVolumes: [String: Volume?]?,
    services: [(serviceName: String, service: Service)],
    environmentVariables: [String: String]
) -> Set<String> {
    guard let topLevelVolumes else { return [] }
    let topLevelKeys = Set(topLevelVolumes.keys)
    var referenced = Set<String>()

    for (_, service) in services {
        for volume in service.volumes ?? [] {
            guard let reference = parseComposeVolumeReference(volume, environmentVariables: environmentVariables),
                  let source = reference.source,
                  !composeVolumeSourceIsBindMount(source),
                  topLevelKeys.contains(source)
            else {
                continue
            }
            referenced.insert(source)
        }
    }

    return referenced
}

func composeVolumeCreateCandidates(
    topLevelVolumes: [String: Volume?]?,
    services: [(serviceName: String, service: Service)],
    environmentVariables: [String: String]
) -> [ComposeVolumeCreateCandidate] {
    var candidates: [String: Volume] = [:]

    for (_, service) in services {
        for volume in service.volumes ?? [] {
            guard let reference = parseComposeVolumeReference(volume, environmentVariables: environmentVariables),
                  let source = reference.source,
                  !composeVolumeSourceIsBindMount(source)
            else {
                continue
            }
            candidates[source] = topLevelVolumes?[source] ?? Volume()
        }
    }

    return candidates.keys.sorted().compactMap { key in
        guard let volume = candidates[key] else { return nil }
        return ComposeVolumeCreateCandidate(volumeKey: key, volume: volume)
    }
}

func composeVolumeDeleteCandidates(
    projectName: String,
    topLevelVolumes: [String: Volume?]?,
    services: [(serviceName: String, service: Service)],
    environmentVariables: [String: String]
) throws -> [String] {
    var candidates = Set<String>()

    for (_, service) in services {
        for volume in service.volumes ?? [] {
            guard let reference = parseComposeVolumeReference(volume, environmentVariables: environmentVariables),
                  let source = reference.source,
                  !composeVolumeSourceIsBindMount(source)
            else {
                continue
            }
            let volumeConfig = topLevelVolumes?[source] ?? nil
            guard !composeVolumeIsExternal(volumeConfig) else { continue }
            let volumeName = composeVolumeName(projectName: projectName, volumeKey: source, volume: volumeConfig)
            try validateComposeVolumeName(volumeName)
            candidates.insert(volumeName)
        }
    }

    return candidates.sorted()
}

func validateComposeVolumeName(_ name: String) throws {
    guard composeVolumeNameIsValid(name) else {
        throw ComposeError.invalidVolumeName("invalid volume name '\(name)': must match \(composeVolumeNamePattern)")
    }
}

func composeVolumeNameIsValid(_ name: String) -> Bool {
    guard !name.isEmpty, name.count <= appleContainerVolumeNameMaxLength else {
        return false
    }
    guard let first = name.unicodeScalars.first, composeVolumeScalarIsAlphaNumeric(first) else {
        return false
    }
    return name.unicodeScalars.allSatisfy(composeVolumeScalarIsAllowed)
}

func composeVolumeSourceIsBindMount(_ source: String) -> Bool {
    source.contains("/") || source == "." || source == ".." || source.hasPrefix(".") || source.hasPrefix("~")
}

func composeVolumeErrorIsAlreadyExists(_ error: Error) -> Bool {
    let message = "\(error) \(error.localizedDescription)"
    return message.contains("already exists")
}

func composeVolumeErrorIsNotFound(_ error: Error) -> Bool {
    let message = "\(error) \(error.localizedDescription)"
    return message.contains("not found")
}

private func composeVolumeScalarIsAllowed(_ scalar: UnicodeScalar) -> Bool {
    composeVolumeScalarIsAlphaNumeric(scalar) || scalar == "_" || scalar == "." || scalar == "-"
}

private func composeVolumeScalarIsAlphaNumeric(_ scalar: UnicodeScalar) -> Bool {
    (scalar.value >= 48 && scalar.value <= 57)
        || (scalar.value >= 65 && scalar.value <= 90)
        || (scalar.value >= 97 && scalar.value <= 122)
}

private func composeBindMountSourcePath(
    _ source: String,
    composeDirectory: String,
    fileManager: FileManager
) throws -> String {
    let hostPath: String
    if source.hasPrefix("~") {
        hostPath = NSString(string: source).expandingTildeInPath
    } else if source.hasPrefix("/") {
        hostPath = source
    } else {
        hostPath = URL(fileURLWithPath: composeDirectory)
            .appendingPathComponent(source)
            .standardizedFileURL
            .path
    }

    if !fileManager.fileExists(atPath: hostPath) {
        try fileManager.createDirectory(atPath: hostPath, withIntermediateDirectories: true)
    }

    return hostPath
}

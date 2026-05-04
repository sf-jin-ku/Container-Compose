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
import Yams

public struct DockerComposeLoader {
    private let environmentVariables: [String: String]
    private struct ComposeOverrideValue {
        let value: Any
    }

    public init(environmentVariables: [String: String] = [:]) {
        self.environmentVariables = environmentVariables
    }

    public func load(file path: String) throws -> DockerCompose {
        try decode(root: resolvedRoot(file: path))
    }

    public func load(files paths: [String]) throws -> DockerCompose {
        guard let first = paths.first else {
            throw DockerComposeLoaderError("at least one compose file is required")
        }
        var root = try resolvedRoot(file: first)
        for path in paths.dropFirst() {
            root = mergeMaps(base: root, override: try resolvedRoot(file: path))
        }
        return try decode(root: root)
    }

    private func resolvedRoot(file path: String) throws -> [String: Any] {
        let url = URL(fileURLWithPath: path)
        guard var root = try loadComposeObject(from: url) as? [String: Any] else {
            throw DockerComposeLoaderError("Compose document must be a mapping: \(path)")
        }
        let servicesRoot = root["services"] as? [String: Any] ?? [:]
        var resolvedServices: [String: Any] = [:]
        for (name, value) in servicesRoot {
            resolvedServices[name] = try resolveServiceMap(
                name: name,
                value: value,
                localServices: servicesRoot,
                baseDirectory: url.deletingLastPathComponent(),
                sourceID: url.path,
                seen: []
            )
        }
        root["services"] = resolvedServices
        return root
    }

    private func resolveServiceMap(
        name: String,
        value: Any,
        localServices: [String: Any],
        baseDirectory: URL,
        sourceID: String,
        seen: Set<String>
    ) throws -> [String: Any] {
        guard var service = value as? [String: Any] else {
            throw DockerComposeLoaderError("service \(name) must be a mapping")
        }
        let seenKey = "\(sourceID):\(name)"
        guard !seen.contains(seenKey) else {
            throw DockerComposeLoaderError("cyclic extends detected for service \(name)")
        }
        guard let extends = service["extends"] as? [String: Any] else {
            return service
        }
        guard let baseServiceName = extends["service"] as? String else {
            throw DockerComposeLoaderError("service \(name) extends entry must include service")
        }

        let baseService: [String: Any]
        if let file = extends["file"] as? String {
            let fileURL = URL(fileURLWithPath: file, relativeTo: baseDirectory).standardizedFileURL
            guard let root = try loadComposeObject(from: fileURL) as? [String: Any],
                  let services = root["services"] as? [String: Any],
                  let rawBase = services[baseServiceName] else {
                throw DockerComposeLoaderError("extended service \(baseServiceName) not found in \(file)")
            }
            baseService = try resolveServiceMap(
                name: baseServiceName,
                value: rawBase,
                localServices: services,
                baseDirectory: fileURL.deletingLastPathComponent(),
                sourceID: fileURL.path,
                seen: seen.union([seenKey])
            )
        } else {
            guard let rawBase = localServices[baseServiceName] else {
                throw DockerComposeLoaderError("extended service \(baseServiceName) not found")
            }
            baseService = try resolveServiceMap(
                name: baseServiceName,
                value: rawBase,
                localServices: localServices,
                baseDirectory: baseDirectory,
                sourceID: sourceID,
                seen: seen.union([seenKey])
            )
        }

        service.removeValue(forKey: "extends")
        return mergeMaps(base: baseService, override: service)
    }

    private func decode(root: [String: Any]) throws -> DockerCompose {
        let yaml = try Yams.dump(object: interpolate(root))
        return try YAMLDecoder().decode(DockerCompose.self, from: yaml)
    }

    private func mergeMaps(base: [String: Any], override: [String: Any], path: [String] = []) -> [String: Any] {
        var merged = base
        for (key, value) in override {
            let childPath = path + [key]
            if let overrideValue = value as? ComposeOverrideValue {
                merged[key] = overrideValue.value
            } else if let baseMap = merged[key] as? [String: Any], let overrideMap = value as? [String: Any] {
                merged[key] = mergeMaps(base: baseMap, override: overrideMap, path: childPath)
            } else if key == "volumes",
                      let baseList = merged[key] as? [Any],
                      let overrideList = value as? [Any] {
                merged[key] = mergeUniqueVolumeList(base: baseList, override: overrideList)
            } else {
                merged[key] = value
            }
        }
        return merged
    }

    private func mergeUniqueVolumeList(base: [Any], override: [Any]) -> [Any] {
        var merged = base
        var targetIndexes: [String: Int] = [:]

        for (index, item) in merged.enumerated() {
            if let target = composeVolumeTarget(item) {
                targetIndexes[target] = index
            }
        }

        for item in override {
            guard let target = composeVolumeTarget(item) else {
                merged.append(item)
                continue
            }
            if let existingIndex = targetIndexes[target] {
                merged[existingIndex] = item
            } else {
                targetIndexes[target] = merged.count
                merged.append(item)
            }
        }

        return merged
    }

    private func composeVolumeTarget(_ value: Any) -> String? {
        if let map = value as? [String: Any] {
            return map["target"] as? String
        }

        guard let string = value as? String else {
            return nil
        }
        let resolvedString = resolveVariable(string, with: environmentVariables)
        let components = resolvedString.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        switch components.count {
        case 1:
            return components[0].isEmpty ? nil : components[0]
        case 2, 3:
            return components[1].isEmpty ? nil : components[1]
        default:
            return nil
        }
    }

    private func loadComposeObject(from url: URL) throws -> Any? {
        let content = try String(contentsOf: url, encoding: .utf8)
        var sequenceMap = Constructor.defaultSequenceMap
        for tagName in composeOverrideTagNames {
            sequenceMap[tagName] = { sequence in
                ComposeOverrideValue(value: [Any].construct_seq(from: sequence))
            }
        }
        let constructor = Constructor(
            Constructor.defaultScalarMap,
            Constructor.defaultMappingMap,
            sequenceMap
        )
        return try Yams.load(yaml: content, .default, constructor)
    }

    private var composeOverrideTagNames: [Tag.Name] {
        [
            Tag.Name(rawValue: "!override"),
            Tag.Name(rawValue: "override"),
            Tag.Name(rawValue: "tag:yaml.org,2002:override"),
        ]
    }

    private func interpolate(_ value: Any) -> Any {
        if let overrideValue = value as? ComposeOverrideValue {
            return interpolate(overrideValue.value)
        }
        if let string = value as? String {
            return resolveVariable(string, with: environmentVariables)
        }
        if let list = value as? [Any] {
            return list.map(interpolate)
        }
        if let map = value as? [String: Any] {
            return map.mapValues(interpolate)
        }
        return value
    }
}

public struct DockerComposeLoaderError: Error, CustomStringConvertible {
    public let description: String

    public init(_ description: String) {
        self.description = description
    }
}

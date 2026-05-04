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

struct ComposeCommonOptions: ParsableArguments {
    @Option(name: [.customShort("f"), .customLong("file")], parsing: .singleValue, help: "The path to your Docker Compose file")
    var composeFilenames: [String] = []

    @Option(name: .customLong("profile"), parsing: .singleValue, help: "Enable a Compose profile")
    var profiles: [String] = []

    @Option(name: .customLong("env-file"), parsing: .singleValue, help: "Read variables from an environment file")
    var envFiles: [String] = []

    @Option(name: .customLong("project-directory"), help: "Compose project directory")
    var projectDirectory: String?

    var cwd: String {
        projectDirectory.map {
            resolvedPath(for: $0, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        } ?? FileManager.default.currentDirectoryPath
    }

    func loadContext(fileManager: FileManager = .default) throws -> ComposeProjectContext {
        try ComposeProjectContext.load(
            composeFilenames: composeFilenames,
            cwd: cwd,
            envFiles: envFiles,
            fileManager: fileManager
        )
    }

    var activeProfiles: [String] {
        activeComposeProfiles(cliProfiles: profiles)
    }
}

struct ComposeFileOptions: ParsableArguments {
    @Option(name: [.customShort("f"), .customLong("file")], parsing: .singleValue, help: "The path to your Docker Compose file")
    var composeFilenames: [String] = []

    @Option(name: .customLong("profile"), parsing: .singleValue, help: "Enable a Compose profile")
    var profiles: [String] = []

    @Option(name: .customLong("compose-env-file"), parsing: .singleValue, help: "Read compose interpolation variables from an environment file")
    var envFiles: [String] = []

    @Option(name: .customLong("project-directory"), help: "Compose project directory")
    var projectDirectory: String?

    var cwd: String {
        projectDirectory.map {
            resolvedPath(for: $0, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        } ?? FileManager.default.currentDirectoryPath
    }

    func loadContext(fileManager: FileManager = .default) throws -> ComposeProjectContext {
        try ComposeProjectContext.load(
            composeFilenames: composeFilenames,
            cwd: cwd,
            envFiles: envFiles,
            fileManager: fileManager
        )
    }

    var activeProfiles: [String] {
        activeComposeProfiles(cliProfiles: profiles)
    }
}

struct ComposeProjectContext {
    let dockerCompose: DockerCompose
    let projectName: String
    let composeFiles: ComposeFileSelection
    let cwd: String
    let environmentVariables: [String: String]

    var composeDirectory: String {
        composeFiles.primaryDirectory
    }

    static func load(
        composeFilenames: [String],
        cwd: String,
        envFiles: [String],
        fileManager: FileManager = .default
    ) throws -> ComposeProjectContext {
        let composeFiles = ComposeFileSelection.resolve(
            explicitFilenames: composeFilenames,
            cwd: cwd,
            fileManager: fileManager
        )
        let cwdURL = URL(fileURLWithPath: cwd)
        let envFilePaths = (envFiles.isEmpty ? [".env"] : envFiles).map {
            resolvedPath(for: $0, relativeTo: cwdURL)
        }
        let environmentVariables = loadEnvFiles(paths: envFilePaths)
        let dockerCompose = try composeFiles.load(
            fileManager: fileManager,
            environmentVariables: environmentVariables
        )
        return ComposeProjectContext(
            dockerCompose: dockerCompose,
            projectName: dockerCompose.name.map(sanitizeComposeProjectName) ?? deriveProjectName(cwd: cwd),
            composeFiles: composeFiles,
            cwd: cwd,
            environmentVariables: environmentVariables
        )
    }

    func selectedServices(
        requestedServices: [String],
        activeProfiles: [String],
        includeDependencies: Bool = true
    ) throws -> [(serviceName: String, service: Service)] {
        try ComposeServiceSelection.selectedServices(
            from: dockerCompose,
            requestedServices: requestedServices,
            activeProfiles: activeProfiles,
            includeDependencies: includeDependencies
        )
    }

    func serviceTargets(
        requestedServices: [String],
        activeProfiles: [String],
        includeDependencies: Bool = true
    ) throws -> [ComposeServiceTarget] {
        try selectedServices(
            requestedServices: requestedServices,
            activeProfiles: activeProfiles,
            includeDependencies: includeDependencies
        ).map { serviceName, service in
            ComposeServiceTarget(
                serviceName: serviceName,
                service: service,
                containerName: containerName(for: serviceName, service: service)
            )
        }
    }

    func containerName(for serviceName: String, service: Service) -> String {
        service.container_name ?? composeGeneratedContainerName(projectName: projectName, serviceName: serviceName)
    }

    func requiredService(named serviceName: String) throws -> Service {
        guard let service = dockerCompose.services[serviceName] ?? nil else {
            throw ComposeError.dependencyNotReady("service '\(serviceName)' not found")
        }
        return service
    }
}

struct ComposeServiceTarget {
    let serviceName: String
    let service: Service
    let containerName: String
}

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
//  ComposeDown.swift
//  Container-Compose
//
//  Created by Morris Richman on 6/19/25.
//

import ArgumentParser
import ContainerCommands
import ContainerAPIClient
import Foundation

public struct ComposeDown: AsyncParsableCommand {
    public init() {}

    public static let configuration: CommandConfiguration = .init(
        commandName: "down",
        abstract: "Stop containers with compose"
    )

    @Argument(help: "Specify the services to stop")
    var services: [String] = []

    @OptionGroup
    var process: Flags.Process

    private var cwd: String { process.cwd ?? FileManager.default.currentDirectoryPath }

    @Option(name: [.customShort("f"), .customLong("file")], parsing: .singleValue, help: "The path to your Docker Compose file")
    var composeFilenames: [String] = []

    @Option(name: .customLong("profile"), parsing: .singleValue, help: "Enable a Compose profile")
    var profiles: [String] = []

    private var composeFiles: ComposeFileSelection {
        ComposeFileSelection.resolve(explicitFilenames: composeFilenames, cwd: cwd, fileManager: fileManager)
    }

    private var fileManager: FileManager { FileManager.default }
    private var projectName: String?

    public mutating func run() async throws {
        let envFiles = process.envFile.isEmpty ? [".env"] : process.envFile
        let envFilePaths = envFiles.map { resolvedPath(for: $0, relativeTo: URL(fileURLWithPath: cwd)) }
        let environmentVariables = loadEnvFiles(paths: envFilePaths)
        let dockerCompose = try composeFiles.load(fileManager: fileManager, environmentVariables: environmentVariables)

        if let name = dockerCompose.name {
            projectName = sanitizeComposeProjectName(name)
            print("Info: Docker Compose project name parsed as: \(projectName ?? name)")
            print(
                "Note: The 'name' field affects generated container names and project-scoped volume names. Full project-level isolation for networks is not implemented by this tool."
            )
        } else {
            projectName = deriveProjectName(cwd: cwd)
            print("Info: No 'name' field found in docker-compose.yml. Using directory name as project name: \(projectName ?? "")")
        }

        let services = try ComposeServiceSelection.servicesToStopForDown(
            from: dockerCompose,
            requestedServices: self.services,
            activeProfiles: activeComposeProfiles(cliProfiles: profiles)
        )

        try await stopOldStuff(services, remove: false)
    }

    private func stopOldStuff(_ services: [(serviceName: String, service: Service)], remove: Bool) async throws {
        guard let projectName else { return }

        for (serviceName, service) in services {
            let containerName: String
            if let explicitContainerName = service.container_name {
                containerName = explicitContainerName
            } else {
                containerName = "\(projectName)-\(serviceName)"
            }

            print("Stopping container: \(containerName)")

            let client = ContainerClient()

            guard let container = try? await client.get(id: containerName) else {
                print("Warning: Container '\(containerName)' not found, skipping.")
                continue
            }

            do {
                try await client.stop(id: container.id)
                print("Successfully stopped container: \(containerName)")
            } catch {
                print("Error Stopping Container: \(error)")
            }
            if remove {
                do {
                    try await client.delete(id: container.id)
                    print("Successfully removed container: \(containerName)")
                } catch {
                    print("Error Removing Container: \(error)")
                }
            }
        }
    }
}

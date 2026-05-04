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
import ContainerAPIClient
import ContainerCommands
import Foundation

public struct ComposeLogs: AsyncParsableCommand {
    public init() {}

    public static let configuration: CommandConfiguration = .init(
        commandName: "logs",
        abstract: "Fetch compose service logs"
    )

    @Argument(help: "Services to fetch logs from")
    var services: [String] = []

    @OptionGroup
    var compose: ComposeCommonOptions

    @OptionGroup
    var logging: Flags.Logging

    @Flag(name: .customLong("follow"), help: "Follow log output")
    var follow = false

    @Option(name: .customLong("tail"), help: "Number of lines to show from the end")
    var tail: String?

    @Flag(name: .customLong("no-color"), help: "Accepted for Docker Compose compatibility")
    var noColor = false

    @Flag(name: .customLong("timestamps"), help: "Accepted for Docker Compose compatibility")
    var timestamps = false

    public mutating func run() async throws {
        let context = try compose.loadContext()
        let targets = try context.serviceTargets(
            requestedServices: services,
            activeProfiles: compose.activeProfiles,
            includeDependencies: false
        )
        let loggingArgs = logging.passThroughCommands()
        let follow = follow
        let tail = tail
        if follow {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for target in targets {
                    let args = Self.containerLogsArguments(
                        for: target.containerName,
                        follow: follow,
                        tail: tail
                    ) + loggingArgs
                    group.addTask {
                        let logs = try Application.ContainerLogs.parse(args)
                        try await logs.run()
                    }
                }
                try await group.waitForAll()
            }
        } else {
            for target in targets {
                let args = Self.containerLogsArguments(
                    for: target.containerName,
                    follow: follow,
                    tail: tail
                ) + loggingArgs
                let logs = try Application.ContainerLogs.parse(args)
                try await logs.run()
            }
        }
    }

    static func containerLogsArguments(
        for containerName: String,
        follow: Bool,
        tail: String?
    ) -> [String] {
        var args: [String] = []
        if follow {
            args.append("--follow")
        }
        if let tail, tail != "all" {
            args.append(contentsOf: ["-n", tail])
        }
        args.append(containerName)
        return args
    }
}

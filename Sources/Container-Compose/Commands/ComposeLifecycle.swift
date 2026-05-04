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

public struct ComposeStart: AsyncParsableCommand {
    public init() {}

    public static let configuration: CommandConfiguration = .init(
        commandName: "start",
        abstract: "Start compose service containers"
    )

    @Argument(help: "Services to start")
    var services: [String] = []

    @OptionGroup
    var compose: ComposeCommonOptions

    @OptionGroup
    var logging: Flags.Logging

    public mutating func run() async throws {
        for target in try composeTargets(compose: compose, services: services) {
            let start = try Application.ContainerStart.parse([target.containerName] + logging.passThroughCommands())
            try await start.run()
        }
    }
}

public struct ComposeStop: AsyncParsableCommand {
    public init() {}

    public static let configuration: CommandConfiguration = .init(
        commandName: "stop",
        abstract: "Stop compose service containers"
    )

    @Argument(help: "Services to stop")
    var services: [String] = []

    @OptionGroup
    var compose: ComposeCommonOptions

    @OptionGroup
    var logging: Flags.Logging

    @Option(name: [.customShort("t"), .customLong("timeout")], help: "Seconds to wait before killing containers")
    var timeout: Int32 = 5

    public mutating func run() async throws {
        let targets = try composeTargets(compose: compose, services: services)
        try await stopContainers(targets.reversed().map(\.containerName), timeout: timeout, logging: logging)
    }
}

public struct ComposeRestart: AsyncParsableCommand {
    public init() {}

    public static let configuration: CommandConfiguration = .init(
        commandName: "restart",
        abstract: "Restart compose service containers"
    )

    @Argument(help: "Services to restart")
    var services: [String] = []

    @OptionGroup
    var compose: ComposeCommonOptions

    @OptionGroup
    var logging: Flags.Logging

    @Option(name: [.customShort("t"), .customLong("timeout")], help: "Seconds to wait before killing containers")
    var timeout: Int32 = 5

    public mutating func run() async throws {
        let targets = try composeTargets(compose: compose, services: services)
        try await stopContainers(targets.reversed().map(\.containerName), timeout: timeout, logging: logging)
        for target in targets {
            let start = try Application.ContainerStart.parse([target.containerName] + logging.passThroughCommands())
            try await start.run()
        }
    }
}

private func composeTargets(
    compose: ComposeCommonOptions,
    services: [String]
) throws -> [ComposeServiceTarget] {
    let context = try compose.loadContext()
    return try context.serviceTargets(
        requestedServices: services,
        activeProfiles: compose.activeProfiles,
        includeDependencies: false
    )
}

private func stopContainers(
    _ containers: [String],
    timeout: Int32,
    logging: Flags.Logging
) async throws {
    guard !containers.isEmpty else { return }
    var args = ["--time", "\(timeout)"]
    args.append(contentsOf: containers)
    var stop = try Application.ContainerStop.parse(args + logging.passThroughCommands())
    try await stop.run()
}

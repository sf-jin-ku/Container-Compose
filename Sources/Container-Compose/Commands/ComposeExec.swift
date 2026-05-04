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

public struct ComposeExec: AsyncParsableCommand {
    public init() {}

    public static let configuration: CommandConfiguration = .init(
        commandName: "exec",
        abstract: "Run a command in a compose service container"
    )

    @OptionGroup
    var compose: ComposeFileOptions

    @OptionGroup
    var logging: Flags.Logging

    @Flag(name: [.customShort("d"), .customLong("detach")], help: "Run the process and detach from it")
    var detach = false

    @Flag(name: .customShort("T"), help: "Disable pseudo-TTY allocation")
    var noTTY = false

    @Flag(name: [.customShort("i"), .customLong("interactive")], help: "Keep STDIN open")
    var interactive = false

    @Flag(name: [.customShort("t"), .customLong("tty")], help: "Allocate a pseudo-TTY")
    var tty = false

    @Option(name: [.customShort("e"), .customLong("env")], parsing: .singleValue, help: "Set environment variables")
    var env: [String] = []

    @Option(name: .customLong("env-file"), parsing: .singleValue, help: "Read environment variables from a file")
    var envFiles: [String] = []

    @Option(name: [.customShort("u"), .customLong("user")], help: "Run as user")
    var user: String?

    @Option(name: [.customShort("w"), .customLong("workdir")], help: "Working directory inside the container")
    var workdir: String?

    @Option(name: .customLong("index"), help: "Compose service replica index")
    var index: Int = 1

    @Argument(help: "Service name")
    var serviceName: String

    @Argument(parsing: .captureForPassthrough, help: "Command and arguments")
    var command: [String]

    public mutating func run() async throws {
        guard index == 1 else {
            throw ComposeError.unsupportedDependencyCondition("compose exec --index currently supports only index 1")
        }
        guard !command.isEmpty else {
            throw ComposeError.dependencyNotReady("compose exec requires a command")
        }
        let context = try compose.loadContext()
        let service = try context.requiredService(named: serviceName)
        let containerName = context.containerName(for: serviceName, service: service)
        let exec = try Application.ContainerExec.parse(containerExecArguments(containerName: containerName) + logging.passThroughCommands())
        try await exec.run()
    }

    func containerExecArguments(containerName: String) -> [String] {
        var args: [String] = []
        if detach {
            args.append("--detach")
        }
        if interactive || (!noTTY && !detach) {
            args.append("--interactive")
        }
        if tty || (!noTTY && !detach) {
            args.append("--tty")
        }
        for item in env {
            args.append(contentsOf: ["--env", item])
        }
        for item in envFiles {
            args.append(contentsOf: ["--env-file", item])
        }
        if let user {
            args.append(contentsOf: ["--user", user])
        }
        if let workdir {
            args.append(contentsOf: ["--workdir", workdir])
        }
        args.append(containerName)
        args.append(contentsOf: command)
        return args
    }
}

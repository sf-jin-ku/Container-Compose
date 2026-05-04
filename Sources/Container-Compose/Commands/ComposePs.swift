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
import ContainerResource
import Foundation

public struct ComposePs: AsyncParsableCommand {
    public init() {}

    public static let configuration: CommandConfiguration = .init(
        commandName: "ps",
        abstract: "List compose containers"
    )

    @Argument(help: "Services to list")
    var services: [String] = []

    @OptionGroup
    var compose: ComposeCommonOptions

    @Flag(name: [.customShort("a"), .customLong("all")], help: "Show stopped containers")
    var all = false

    @Flag(name: [.customShort("q"), .customLong("quiet")], help: "Only display container IDs")
    var quiet = false

    @Flag(name: .customLong("services"), help: "Display service names")
    var servicesOnly = false

    public mutating func run() async throws {
        let context = try compose.loadContext()
        let targets = try context.serviceTargets(
            requestedServices: services,
            activeProfiles: compose.activeProfiles,
            includeDependencies: false
        )
        let names = targets.map(\.containerName)
        let filters = ContainerListFilters(ids: names, status: all ? nil : .running)
        let containers = try await ContainerClient().list(filters: filters)
        let byID = Dictionary(uniqueKeysWithValues: containers.map { ($0.id, $0) })
        if servicesOnly {
            for target in targets where byID[target.containerName] != nil {
                print(target.serviceName)
            }
            return
        }
        if !quiet {
            print("NAME\tIMAGE\tSTATE")
        }
        for target in targets {
            guard let container = byID[target.containerName] else { continue }
            if quiet {
                print(container.id)
            } else {
                print("\(container.id)\t\(container.configuration.image.reference)\t\(container.status.rawValue)")
            }
        }
    }
}

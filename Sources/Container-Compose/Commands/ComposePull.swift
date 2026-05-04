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

enum ComposePullPolicy: String, ExpressibleByArgument {
    case always
    case missing
}

public struct ComposePull: AsyncParsableCommand, @unchecked Sendable {
    public init() {}

    public static let configuration: CommandConfiguration = .init(
        commandName: "pull",
        abstract: "Pull service images with compose"
    )

    @Argument(help: "Services to pull")
    var services: [String] = []

    @OptionGroup
    var compose: ComposeCommonOptions

    @OptionGroup
    var logging: Flags.Logging

    @Flag(name: .customLong("include-deps"), help: "Also pull images for service dependencies")
    var includeDependencies = false

    @Flag(name: .customLong("ignore-pull-failures"), help: "Continue when an image pull fails")
    var ignorePullFailures = false

    @Flag(name: .customLong("ignore-buildable"), help: "Skip services that only define build")
    var ignoreBuildable = false

    @Flag(name: [.customShort("q"), .customLong("quiet")], help: "Reduce pull output where supported")
    var quiet = false

    @Option(name: .customLong("policy"), help: "Pull policy: missing or always")
    var policy: ComposePullPolicy = .missing

    public mutating func run() async throws {
        let context = try compose.loadContext()
        let targets = try context.serviceTargets(
            requestedServices: services,
            activeProfiles: compose.activeProfiles,
            includeDependencies: includeDependencies
        )
        var pulledImages = Set<String>()
        for target in targets {
            if Self.shouldSkipServiceForPull(target.service, ignoreBuildable: ignoreBuildable) {
                print("Skipping buildable service \(target.serviceName)")
                continue
            }
            guard let image = target.service.image else {
                throw ComposeError.imageNotFound(target.serviceName)
            }
            guard pulledImages.insert(image).inserted else { continue }
            do {
                if policy == .missing, try await imageIsPresent(image) {
                    if !quiet {
                        print("Image \(image) already exists")
                    }
                    continue
                }
                var pullArgs = [image]
                if let platform = target.service.platform {
                    pullArgs.append(contentsOf: ["--platform", platform])
                }
                let pull = try Application.ImagePull.parse(pullArgs + logging.passThroughCommands())
                try await pull.run()
            } catch {
                if ignorePullFailures {
                    print("Warning: failed to pull \(image): \(error)")
                    continue
                }
                throw error
            }
        }
    }

    static func shouldSkipServiceForPull(_ service: Service, ignoreBuildable: Bool) -> Bool {
        ignoreBuildable && service.build != nil
    }

    private func imageIsPresent(_ image: String) async throws -> Bool {
        let imageList = try await ClientImage.list()
        return imageList.contains { candidate in
            imageReferenceMatches(localReference: candidate.description.reference, requestedReference: image)
        }
    }
}

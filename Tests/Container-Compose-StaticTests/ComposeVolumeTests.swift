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
import Testing
import Yams
@testable import ContainerComposeCore

@Suite("Compose Volume Tests")
struct ComposeVolumeTests {
    @Test("Compose volume names follow project scoping and explicit names")
    func volumeNamesFollowComposeScoping() throws {
        let compose = try YAMLDecoder().decode(DockerCompose.self, from: """
        services:
          app:
            image: alpine:3.20
        volumes:
          data:
          explicit:
            name: shared-data
          external_data:
            external: true
          external_named:
            external:
              name: platform-data
        """)

        #expect(composeVolumeName(projectName: "demo", volumeKey: "data", volume: compose.volumes?["data"] ?? nil) == "demo_data")
        #expect(composeVolumeName(projectName: "demo", volumeKey: "explicit", volume: compose.volumes?["explicit"] ?? nil) == "shared-data")
        #expect(composeVolumeName(projectName: "demo", volumeKey: "external_data", volume: compose.volumes?["external_data"] ?? nil) == "external_data")
        #expect(composeVolumeName(projectName: "demo", volumeKey: "external_named", volume: compose.volumes?["external_named"] ?? nil) == "platform-data")
    }

    @Test("Compose volume mount arguments use Apple container named volumes")
    func namedVolumeMountArgumentsUseContainerVolumes() throws {
        let compose = try YAMLDecoder().decode(DockerCompose.self, from: """
        services:
          app:
            image: alpine:3.20
            volumes:
              - data:/data:ro
              - explicit:/cache
              - type: bind
                source: .
                target: /work
                read_only: true
              - type: volume
                source: data
                target: /copy
        volumes:
          data:
          explicit:
            name: shared-cache
        """)

        #expect(try composeVolumeMountArgument(
            "data:/data:ro",
            projectName: "demo",
            topLevelVolumes: compose.volumes,
            environmentVariables: [:],
            composeDirectory: "/tmp"
        ) == "demo_data:/data:ro")
        #expect(try composeVolumeMountArgument(
            "explicit:/cache",
            projectName: "demo",
            topLevelVolumes: compose.volumes,
            environmentVariables: [:],
            composeDirectory: "/tmp"
        ) == "shared-cache:/cache")
        #expect(compose.services["app"]??.volumes?.contains(".:/work:ro") == true)
        #expect(compose.services["app"]??.volumes?.contains("data:/copy") == true)
    }

    @Test("Anonymous service volumes fail fast before runtime")
    func anonymousServiceVolumesFailFastBeforeRuntime() throws {
        let compose = try YAMLDecoder().decode(DockerCompose.self, from: """
        services:
          app:
            image: alpine:3.20
            volumes:
              - /scratch
              - type: volume
                target: /cache
        """)
        let volumes = try #require(compose.services["app"]??.volumes)

        #expect(volumes == ["/scratch", "/cache"])
        for volume in volumes {
            #expect(throws: ComposeError.self) {
                try composeVolumeMountArgument(
                    volume,
                    projectName: "demo",
                    topLevelVolumes: compose.volumes,
                    environmentVariables: [:],
                    composeDirectory: "/tmp"
                )
            }
        }
    }

    @Test("Compose bind mounts resolve relative to compose directory")
    func bindMountsResolveRelativeToComposeDirectory() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Compose.Volume.Bind.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let mount = try composeVolumeMountArgument(
            "./fixture:/work:ro",
            projectName: "demo",
            topLevelVolumes: nil,
            environmentVariables: [:],
            composeDirectory: root.path
        )

        #expect(mount == "\(root.appendingPathComponent("fixture").standardizedFileURL.path):/work:ro")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("fixture").path))
    }

    @Test("Compose down volume candidates exclude external volumes")
    func downVolumeCandidatesExcludeExternalVolumes() throws {
        let compose = try YAMLDecoder().decode(DockerCompose.self, from: """
        services:
          app:
            image: alpine:3.20
            volumes:
              - data:/data
              - implicit:/implicit
              - external_data:/external
              - ./bind:/bind
        volumes:
          data:
          external_data:
            external: true
        """)
        let app = try #require(compose.services["app"] ?? nil)

        let candidates = try composeVolumeDeleteCandidates(
            projectName: "demo",
            topLevelVolumes: compose.volumes,
            services: [("app", app)],
            environmentVariables: [:]
        )

        #expect(candidates == ["demo_data", "demo_implicit"])
    }

    @Test("Compose volume lifecycle only targets selected service references")
    func volumeLifecycleOnlyTargetsSelectedServiceReferences() throws {
        let compose = try YAMLDecoder().decode(DockerCompose.self, from: """
        services:
          app:
            image: alpine:3.20
            volumes:
              - data:/data
          worker:
            image: alpine:3.20
            volumes:
              - unused_external:/unused
        volumes:
          data:
          unused_external:
            external:
              name: platform-unused
        """)
        let app = try #require(compose.services["app"] ?? nil)

        let referenced = composeReferencedTopLevelVolumeKeys(
            topLevelVolumes: compose.volumes,
            services: [("app", app)],
            environmentVariables: [:]
        )
        let candidates = try composeVolumeDeleteCandidates(
            projectName: "demo",
            topLevelVolumes: compose.volumes,
            services: [("app", app)],
            environmentVariables: [:]
        )

        #expect(referenced == ["data"])
        #expect(candidates == ["demo_data"])
    }

    @Test("Compose volume create candidates include implicit named volumes")
    func volumeCreateCandidatesIncludeImplicitNamedVolumes() throws {
        let compose = try YAMLDecoder().decode(DockerCompose.self, from: """
        services:
          app:
            image: alpine:3.20
            volumes:
              - data:/data
              - implicit:/implicit
              - external_data:/external
              - ./bind:/bind
          worker:
            image: alpine:3.20
            volumes:
              - worker_data:/worker
        volumes:
          data:
          external_data:
            external: true
        """)
        let app = try #require(compose.services["app"] ?? nil)

        let candidates = composeVolumeCreateCandidates(
            topLevelVolumes: compose.volumes,
            services: [("app", app)],
            environmentVariables: [:]
        )
        let names = candidates.map { candidate in
            composeVolumeName(projectName: "demo", volumeKey: candidate.volumeKey, volume: candidate.volume)
        }

        #expect(candidates.map(\.volumeKey) == ["data", "external_data", "implicit"])
        #expect(names == ["demo_data", "external_data", "demo_implicit"])
        #expect(candidates.first { $0.volumeKey == "external_data" }?.volume.external?.isExternal == true)
    }

    @Test("Compose volume names fail fast before Apple container runtime")
    func volumeNamesFailFastBeforeRuntime() throws {
        #expect(throws: ComposeError.self) {
            try composeVolumeMountArgument(
                "data:/data",
                projectName: "bad project",
                topLevelVolumes: ["data": Volume()],
                environmentVariables: [:],
                composeDirectory: "/tmp"
            )
        }
        #expect(throws: ComposeError.self) {
            try composeVolumeDeleteCandidates(
                projectName: "demo",
                topLevelVolumes: nil,
                services: [("app", Service(image: "alpine:3.20", volumes: ["bad name:/data"]))],
                environmentVariables: [:]
            )
        }
    }

    @Test("Unsupported long syntax mount types fail during decode")
    func unsupportedLongSyntaxMountTypesFailDuringDecode() throws {
        let yaml = """
        services:
          app:
            image: alpine:3.20
            volumes:
              - type: tmpfs
                target: /cache
        """

        #expect(throws: DecodingError.self) {
            _ = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
        }
    }
}

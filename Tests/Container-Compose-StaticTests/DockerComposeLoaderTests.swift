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
@testable import ContainerComposeCore

@Suite("DockerCompose Loader Tests")
struct DockerComposeLoaderTests {
    @Test("Resolve extends from external file")
    func resolveExtendsFromExternalFile() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let basePath = directory.path + "/base.yml"
        let composePath = directory.path + "/compose.yml"
        try """
        services:
          base:
            image: alpine:3.20
            environment:
              BASE: "yes"
              OVERRIDE: base
            command: echo base
        """.write(toFile: basePath, atomically: true, encoding: .utf8)
        try """
        services:
          app:
            extends:
              file: base.yml
              service: base
            environment:
              OVERRIDE: child
            command: echo child
        """.write(toFile: composePath, atomically: true, encoding: .utf8)

        let compose = try DockerComposeLoader().load(file: composePath)
        let app = try #require(compose.services["app"] ?? nil)

        #expect(app.image == "alpine:3.20")
        #expect(app.environment?["BASE"] == "yes")
        #expect(app.environment?["OVERRIDE"] == "child")
        #expect(app.command == ["echo", "child"])
    }

    @Test("Merge multiple compose files with later overrides")
    func mergeMultipleComposeFilesWithLaterOverrides() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let basePath = directory.path + "/base.yml"
        let overridePath = directory.path + "/override.yml"
        try """
        services:
          api:
            image: api:base
            environment:
              A: one
              B: base
            ports:
              - "8080:80"
          worker:
            image: worker:base
        networks:
          app: {}
        """.write(toFile: basePath, atomically: true, encoding: .utf8)
        try """
        services:
          api:
            environment:
              B: override
              C: three
            ports:
              - "9090:90"
          extra:
            image: extra:latest
        volumes:
          data: {}
        """.write(toFile: overridePath, atomically: true, encoding: .utf8)

        let compose = try DockerComposeLoader().load(files: [basePath, overridePath])
        let api = try #require(compose.services["api"] ?? nil)

        #expect(api.image == "api:base")
        #expect(api.environment == ["A": "one", "B": "override", "C": "three"])
        #expect(api.ports == ["9090:90"])
        #expect(compose.services["worker"]??.image == "worker:base")
        #expect(compose.services["extra"]??.image == "extra:latest")
        #expect(compose.networks?["app"] != nil)
        #expect(compose.volumes?["data"] != nil)
    }

    @Test("Preserve runtime fields through compose file merge")
    func preserveRuntimeFieldsThroughComposeFileMerge() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let basePath = directory.path + "/base.yml"
        let overridePath = directory.path + "/override.yml"
        try """
        services:
          app:
            image: alpine:3.20
            tmpfs:
              - /run
            cap_drop: ALL
            ulimits:
              nofile:
                soft: 1024
                hard: 2048
            init: true
        """.write(toFile: basePath, atomically: true, encoding: .utf8)
        try """
        services:
          app:
            environment:
              MODE: override
        """.write(toFile: overridePath, atomically: true, encoding: .utf8)

        let compose = try DockerComposeLoader().load(files: [basePath, overridePath])
        let app = try #require(compose.services["app"] ?? nil)

        #expect(app.tmpfs == ["/run"])
        #expect(app.cap_drop == ["ALL"])
        #expect(app.ulimits?["nofile"]?.soft == "1024")
        #expect(app.initProcess == true)
        #expect(app.environment?["MODE"] == "override")
    }

    @Test("Compose override tag replaces sequence values")
    func composeOverrideTagReplacesSequenceValues() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let basePath = directory.path + "/base.yml"
        let overridePath = directory.path + "/override.yml"
        try """
        services:
          app:
            image: alpine:3.20
            networks:
              frontend: {}
              backend: {}
        networks:
          frontend: {}
          backend: {}
          isolated: {}
        """.write(toFile: basePath, atomically: true, encoding: .utf8)
        try """
        services:
          app:
            networks: !override
              - isolated
        """.write(toFile: overridePath, atomically: true, encoding: .utf8)

        let compose = try DockerComposeLoader().load(files: [basePath, overridePath])
        let app = try #require(compose.services["app"] ?? nil)

        #expect(app.networks == ["isolated"])
    }

    @Test("Compose file merge appends service volumes by target")
    func composeFileMergeAppendsServiceVolumesByTarget() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let basePath = directory.path + "/base.yml"
        let overridePath = directory.path + "/override.yml"
        try """
        services:
          app:
            image: alpine:3.20
            volumes:
              - /host/tmp:/tmp
              - app-data:/data
        volumes:
          app-data: {}
        """.write(toFile: basePath, atomically: true, encoding: .utf8)
        try """
        services:
          app:
            volumes:
              - ./conf:/app/conf
        """.write(toFile: overridePath, atomically: true, encoding: .utf8)

        let compose = try DockerComposeLoader().load(files: [basePath, overridePath])
        let app = try #require(compose.services["app"] ?? nil)

        #expect(app.volumes == ["/host/tmp:/tmp", "app-data:/data", "./conf:/app/conf"])
    }

    @Test("Compose file merge replaces service volume with same target")
    func composeFileMergeReplacesServiceVolumeWithSameTarget() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let basePath = directory.path + "/base.yml"
        let overridePath = directory.path + "/override.yml"
        try """
        services:
          app:
            image: alpine:3.20
            volumes:
              - /host/tmp:/tmp
              - type: bind
                source: ./base-conf
                target: /app/conf
        """.write(toFile: basePath, atomically: true, encoding: .utf8)
        try """
        services:
          app:
            volumes:
              - type: bind
                source: ./override-conf
                target: /app/conf
        """.write(toFile: overridePath, atomically: true, encoding: .utf8)

        let compose = try DockerComposeLoader().load(files: [basePath, overridePath])
        let app = try #require(compose.services["app"] ?? nil)

        #expect(app.volumes == ["/host/tmp:/tmp", "./override-conf:/app/conf"])
    }

    @Test("Compose file merge replaces short named volume with short bind mount")
    func composeFileMergeReplacesShortNamedVolumeWithShortBindMount() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let basePath = directory.path + "/base.yml"
        let overridePath = directory.path + "/override.yml"
        try """
        services:
          search:
            image: example/search:1.0
            volumes:
              - search-data:/var/lib/search
        volumes:
          search-data: {}
        """.write(toFile: basePath, atomically: true, encoding: .utf8)
        try """
        services:
          search:
            volumes:
              - ./search-data:/var/lib/search
        """.write(toFile: overridePath, atomically: true, encoding: .utf8)

        let compose = try DockerComposeLoader().load(files: [basePath, overridePath])
        let search = try #require(compose.services["search"] ?? nil)

        #expect(search.volumes == ["./search-data:/var/lib/search"])
    }

    @Test("Compose file merge replaces extended named volume with interpolated bind mount")
    func composeFileMergeReplacesExtendedNamedVolumeWithInterpolatedBindMount() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let basePath = directory.path + "/docker-compose-base.yml"
        let composePath = directory.path + "/docker-compose-local-infra.yml"
        let overridePath = directory.path + "/docker-compose.bind-override.yml"
        try """
        services:
          search:
            image: example/search:1.0
            volumes:
              - search-data:/var/lib/search
        """.write(toFile: basePath, atomically: true, encoding: .utf8)
        try """
        services:
          search:
            extends:
              file: docker-compose-base.yml
              service: search
            ports:
              - 9201:9200
              - 9601:9600
          search-init:
            image: alpine:3.20
            depends_on:
              search:
                condition: service_healthy
        volumes:
          search-data: {}
        """.write(toFile: composePath, atomically: true, encoding: .utf8)
        try """
        services:
          search:
            volumes:
              - ${SEARCH_DATA_DIR:-/tmp/container-compose-demo/search-data}:/var/lib/search
        """.write(toFile: overridePath, atomically: true, encoding: .utf8)

        let environment = ["SEARCH_DATA_DIR": "/tmp/container-compose-demo/search-data"]
        let compose = try DockerComposeLoader(environmentVariables: environment).load(files: [composePath, overridePath])
        let search = try #require(compose.services["search"] ?? nil)

        #expect(search.volumes == ["/tmp/container-compose-demo/search-data:/var/lib/search"])
    }

    @Test("Compose override tag replaces service volume sequence")
    func composeOverrideTagReplacesServiceVolumeSequence() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let basePath = directory.path + "/base.yml"
        let overridePath = directory.path + "/override.yml"
        try """
        services:
          search:
            image: example/search:1.0
            volumes:
              - search-data:/var/lib/search
              - ./logs:/var/log/search
        volumes:
          search-data: {}
        """.write(toFile: basePath, atomically: true, encoding: .utf8)
        try """
        services:
          search:
            volumes: !override
              - ./search-data:/var/lib/search
        """.write(toFile: overridePath, atomically: true, encoding: .utf8)

        let compose = try DockerComposeLoader().load(files: [basePath, overridePath])
        let search = try #require(compose.services["search"] ?? nil)

        #expect(search.volumes == ["./search-data:/var/lib/search"])
    }

    @Test("Compose file selection resolves explicit repeated files")
    func composeFileSelectionResolvesExplicitRepeatedFiles() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }

        let selection = ComposeFileSelection.resolve(
            explicitFilenames: ["base.yml", "override.yml"],
            cwd: directory.path
        )

        #expect(selection.paths == [directory.path + "/base.yml", directory.path + "/override.yml"])
        #expect(selection.primaryDirectory == directory.path)
    }

    @Test("Compose file selection finds default compose filename")
    func composeFileSelectionFindsDefaultComposeFilename() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let composePath = directory.path + "/docker-compose.yaml"
        try "services: {}\n".write(toFile: composePath, atomically: true, encoding: .utf8)

        let selection = ComposeFileSelection.resolve(explicitFilenames: [], cwd: directory.path)

        #expect(selection.paths == [composePath])
    }

    @Test("Loader interpolates variables from env files")
    func loaderInterpolatesVariablesFromEnvFiles() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let composePath = directory.path + "/compose.yml"
        let envPath = directory.path + "/app.env"
        try """
        IMAGE_TAG=3.20
        HOST_PORT=9080
        """.write(toFile: envPath, atomically: true, encoding: .utf8)
        try """
        services:
          app:
            image: alpine:${IMAGE_TAG}
            ports:
              - "${HOST_PORT:-8080}:80"
            environment:
              MODE: ${MODE:-dev}
              LITERAL: keep
        """.write(toFile: composePath, atomically: true, encoding: .utf8)

        let selection = ComposeFileSelection.resolve(explicitFilenames: [composePath], cwd: directory.path)
        let compose = try selection.load(environmentVariables: loadEnvFiles(paths: [envPath]))
        let app = try #require(compose.services["app"] ?? nil)

        #expect(app.image == "alpine:3.20")
        #expect(app.ports == ["9080:80"])
        #expect(app.environment?["MODE"] == "dev")
        #expect(app.environment?["LITERAL"] == "keep")
    }
}

private struct TemporaryDirectory {
    let path: String

    init() throws {
        path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: path)
    }
}

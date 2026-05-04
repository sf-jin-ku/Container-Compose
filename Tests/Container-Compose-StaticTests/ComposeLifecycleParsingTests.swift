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
import Testing
import Yams
@testable import ContainerComposeCore

@Suite("Compose Lifecycle Parsing Tests")
struct ComposeLifecycleParsingTests {
    @Test("Compose lifecycle commands parse Docker Compose compatible options")
    func lifecycleCommandsParseOptions() throws {
        let pull = try ComposePull.parse([
            "-f", "base.yml",
            "-f", "override.yml",
            "--profile", "dev",
            "--include-deps",
            "--ignore-pull-failures",
            "--ignore-buildable",
            "--policy", "always",
            "app",
        ])
        #expect(pull.compose.composeFilenames == ["base.yml", "override.yml"])
        #expect(pull.compose.profiles == ["dev"])
        #expect(pull.includeDependencies)
        #expect(pull.ignorePullFailures)
        #expect(pull.ignoreBuildable)
        #expect(pull.policy == .always)
        #expect(pull.services == ["app"])

        let up = try ComposeUp.parse([
            "-f", "base.yml",
            "--remove-orphans",
            "--no-build",
            "--pull", "missing",
            "--force-recreate",
            "--no-deps",
            "-d",
            "app",
        ])
        #expect(up.composeFilenames == ["base.yml"])
        #expect(up.removeOrphans)
        #expect(up.noBuild)
        #expect(up.pullPolicy == .missing)
        #expect(up.forceRecreate)
        #expect(up.noDeps)
        #expect(up.detach)
        #expect(up.services == ["app"])

        let ps = try ComposePs.parse(["--all", "--quiet", "--services", "app"])
        #expect(ps.all)
        #expect(ps.quiet)
        #expect(ps.servicesOnly)
        #expect(ps.services == ["app"])

        let logs = try ComposeLogs.parse(["--follow", "--tail", "20", "--no-color", "--timestamps", "app"])
        #expect(logs.follow)
        #expect(logs.tail == "20")
        #expect(logs.noColor)
        #expect(logs.timestamps)
        #expect(logs.services == ["app"])

        let exec = try ComposeExec.parse([
            "-f", "compose.yml",
            "--compose-env-file", "compose.env",
            "-T",
            "-e", "A=B",
            "--env-file", "exec.env",
            "-u", "1000:1000",
            "-w", "/work",
            "--index", "1",
            "app",
            "sh", "-lc", "echo hi",
        ])
        #expect(exec.compose.composeFilenames == ["compose.yml"])
        #expect(exec.compose.envFiles == ["compose.env"])
        #expect(exec.noTTY)
        #expect(exec.env == ["A=B"])
        #expect(exec.envFiles == ["exec.env"])
        #expect(exec.user == "1000:1000")
        #expect(exec.workdir == "/work")
        #expect(exec.index == 1)
        #expect(exec.serviceName == "app")
        #expect(exec.command == ["sh", "-lc", "echo hi"])

        let start = try ComposeStart.parse(["app", "worker"])
        #expect(start.services == ["app", "worker"])

        let stop = try ComposeStop.parse(["--timeout", "2", "app"])
        #expect(stop.timeout == 2)
        #expect(stop.services == ["app"])

        let down = try ComposeDown.parse(["--remove-orphans", "app"])
        #expect(down.removeOrphans)
        #expect(down.services == ["app"])

        let restart = try ComposeRestart.parse(["-t", "3", "app"])
        #expect(restart.timeout == 3)
        #expect(restart.services == ["app"])
    }

    @Test("Compose up pull missing matches full registry references")
    func pullMissingMatchesFullRegistryReferences() {
        #expect(imageReferenceMatches(
            localReference: "registry.example.com/example/api:demo-test-fe06c768b3",
            requestedReference: "registry.example.com/example/api:demo-test-fe06c768b3"
        ))
        #expect(imageReferenceMatches(
            localReference: "docker.io/library/redis:7.0.11",
            requestedReference: "redis:7.0.11"
        ))
        #expect(!imageReferenceMatches(
            localReference: "docker.io/library/redis:7.0.11",
            requestedReference: "docker.io/library/redis:7.2"
        ))
    }

    @Test("Root compose options are normalized before subcommands")
    func rootComposeOptionsAreNormalizedBeforeSubcommands() throws {
        let up = try normalizeRootComposeOptions([
            "-f", "base.yml",
            "--file=override.yml",
            "--profile", "dev",
            "--project-directory", "fixtures/app",
            "up",
            "-d",
            "app",
        ])
        #expect(up == [
            "up",
            "-f", "base.yml",
            "--file=override.yml",
            "--profile", "dev",
            "--project-directory", "fixtures/app",
            "-d",
            "app",
        ])

        let logs = try normalizeRootComposeOptions([
            "--env-file", ".env.local",
            "logs",
            "--follow",
            "app",
        ])
        #expect(logs == [
            "logs",
            "--env-file", ".env.local",
            "--follow",
            "app",
        ])

        let exec = try normalizeRootComposeOptions([
            "--env-file", ".env.local",
            "exec",
            "app",
            "env",
        ])
        #expect(exec == [
            "exec",
            "--compose-env-file", ".env.local",
            "app",
            "env",
        ])

        let execWithEquals = try normalizeRootComposeOptions([
            "--env-file=.env.local",
            "exec",
            "app",
            "env",
        ])
        #expect(execWithEquals == [
            "exec",
            "--compose-env-file=.env.local",
            "app",
            "env",
        ])
    }

    @Test("Compose project context respects explicit container name")
    func contextRespectsExplicitContainerName() throws {
        let root = try makeComposeDirectory(named: "Compose.Context")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeCompose("""
        name: demo
        services:
          app:
            image: alpine:3.20
          db:
            image: postgres:16
            container_name: custom-db
        """, to: root)

        let context = try ComposeProjectContext.load(
            composeFilenames: [],
            cwd: root.path,
            envFiles: []
        )
        let app = try #require(context.dockerCompose.services["app"] ?? nil)
        let db = try #require(context.dockerCompose.services["db"] ?? nil)

        #expect(context.projectName == "demo")
        #expect(context.containerName(for: "app", service: app) == "demo-app-1")
        #expect(context.containerName(for: "db", service: db) == "custom-db")
    }

    @Test("Compose service targets can exclude dependencies for lifecycle commands")
    func serviceTargetsCanExcludeDependencies() throws {
        let root = try makeComposeDirectory(named: "Compose.Dependencies")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeCompose("""
        services:
          app:
            image: alpine:3.20
            depends_on:
              - db
          db:
            image: postgres:16
        """, to: root)

        let context = try ComposeProjectContext.load(
            composeFilenames: [],
            cwd: root.path,
            envFiles: []
        )
        let withDependencies = try context.serviceTargets(
            requestedServices: ["app"],
            activeProfiles: [],
            includeDependencies: true
        ).map(\.containerName).sorted()
        let exactOnly = try context.serviceTargets(
            requestedServices: ["app"],
            activeProfiles: [],
            includeDependencies: false
        ).map(\.containerName)

        #expect(withDependencies == [
            composeGeneratedContainerName(projectName: context.projectName, serviceName: "app"),
            composeGeneratedContainerName(projectName: context.projectName, serviceName: "db")
        ])
        #expect(exactOnly == [
            composeGeneratedContainerName(projectName: context.projectName, serviceName: "app")
        ])
    }

    @Test("Compose service targets reject unknown requested services")
    func serviceTargetsRejectUnknownRequestedServices() throws {
        let root = try makeComposeDirectory(named: "Compose.Unknown")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeCompose("""
        services:
          app:
            image: alpine:3.20
        """, to: root)

        let context = try ComposeProjectContext.load(
            composeFilenames: [],
            cwd: root.path,
            envFiles: []
        )

        #expect(throws: ComposeError.self) {
            try context.serviceTargets(
                requestedServices: ["missing"],
                activeProfiles: [],
                includeDependencies: false
            )
        }
    }

    @Test("Compose exec defaults to interactive TTY unless detached or TTY is disabled")
    func composeExecDefaultArgumentsMatchComposeSemantics() throws {
        var exec = try ComposeExec.parse(["app", "sh"])
        #expect(exec.containerExecArguments(containerName: "demo-app-1") == [
            "--interactive",
            "--tty",
            "demo-app-1",
            "sh",
        ])

        exec = try ComposeExec.parse(["-T", "app", "sh"])
        #expect(exec.containerExecArguments(containerName: "demo-app-1") == [
            "demo-app-1",
            "sh",
        ])

        exec = try ComposeExec.parse(["-T", "-i", "app", "sh"])
        #expect(exec.containerExecArguments(containerName: "demo-app-1") == [
            "--interactive",
            "demo-app-1",
            "sh",
        ])

        exec = try ComposeExec.parse(["--detach", "app", "sh"])
        #expect(exec.containerExecArguments(containerName: "demo-app-1") == [
            "--detach",
            "demo-app-1",
            "sh",
        ])
    }

    @Test("Compose pull ignore-buildable skips services that define build")
    func composePullIgnoreBuildableSkipsBuildServices() throws {
        let buildOnly = try #require(YAMLDecoder().decode(DockerCompose.self, from: """
        services:
          app:
            build: .
        """).services["app"] ?? nil)
        let buildAndImage = try #require(YAMLDecoder().decode(DockerCompose.self, from: """
        services:
          app:
            image: demo:latest
            build: .
        """).services["app"] ?? nil)
        let imageOnly = try #require(YAMLDecoder().decode(DockerCompose.self, from: """
        services:
          app:
            image: demo:latest
        """).services["app"] ?? nil)

        #expect(ComposePull.shouldSkipServiceForPull(buildOnly, ignoreBuildable: true))
        #expect(ComposePull.shouldSkipServiceForPull(buildAndImage, ignoreBuildable: true))
        #expect(!ComposePull.shouldSkipServiceForPull(imageOnly, ignoreBuildable: true))
        #expect(!ComposePull.shouldSkipServiceForPull(buildOnly, ignoreBuildable: false))
    }

    @Test("Compose down and stop order removes dependents before dependencies")
    func downAndStopOrderRemovesDependentsBeforeDependencies() throws {
        let root = try makeComposeDirectory(named: "Compose.DownOrder")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeCompose("""
        services:
          app:
            image: alpine:3.20
            depends_on:
              - db
          db:
            image: postgres:16
        """, to: root)

        let context = try ComposeProjectContext.load(
            composeFilenames: [],
            cwd: root.path,
            envFiles: []
        )
        let dependencyFirst = try context.serviceTargets(
            requestedServices: [],
            activeProfiles: [],
            includeDependencies: false
        ).map(\.serviceName)

        #expect(dependencyFirst == ["db", "app"])
        #expect(Array(dependencyFirst.reversed()) == ["app", "db"])
    }

    @Test("Compose logs arguments preserve multi-service follow inputs")
    func composeLogsArgumentsPreserveFollowInputs() throws {
        #expect(ComposeLogs.containerLogsArguments(
            for: "demo-app-1",
            follow: true,
            tail: "20"
        ) == [
            "--follow",
            "-n", "20",
            "demo-app-1",
        ])
        #expect(ComposeLogs.containerLogsArguments(
            for: "demo-app-1",
            follow: false,
            tail: "all"
        ) == [
            "demo-app-1",
        ])
    }

    private func makeComposeDirectory(named name: String) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeCompose(_ contents: String, to directory: URL) throws {
        try contents.write(
            to: directory.appendingPathComponent("compose.yml"),
            atomically: true,
            encoding: .utf8
        )
    }
}

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

import Testing
import Foundation
@testable import Yams
@testable import ContainerComposeCore

@Suite("Environment File Loading Tests")
struct EnvFileLoadingTests {
    
    @Test("Load simple key-value pairs from .env file")
    func loadSimpleEnvFile() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let envFile = tempDir.appendingPathComponent("test-\(UUID().uuidString).env")
        
        let content = """
        DATABASE_URL=postgres://localhost/mydb
        PORT=8080
        DEBUG=true
        """
        
        try content.write(to: envFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: envFile) }
        
        let envVars = loadEnvFile(path: envFile.path)
        
        #expect(envVars["DATABASE_URL"] == "postgres://localhost/mydb")
        #expect(envVars["PORT"] == "8080")
        #expect(envVars["DEBUG"] == "true")
        #expect(envVars.count == 3)
    }

    @Test("Parse env_file string and object syntax")
    func parseEnvFileStringAndObjectSyntax() throws {
        let yaml = """
        version: '3.8'
        services:
          app:
            image: myapp:latest
            env_file:
              - .env
              - path: ./optional.env
                required: false
                format: raw
          worker:
            image: myworker:latest
            env_file: worker.env
        """

        let compose = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
        let app = try #require(compose.services["app"] ?? nil)
        let worker = try #require(compose.services["worker"] ?? nil)

        #expect(app.env_file == [".env", "./optional.env"])
        #expect(app.envFileConfigurations?[1].required == false)
        #expect(app.envFileConfigurations?[1].format == "raw")
        #expect(worker.env_file == ["worker.env"])
        #expect(worker.envFileConfigurations?.first?.path == "worker.env")
    }
    
    @Test("Ignore comments in .env file")
    func ignoreComments() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let envFile = tempDir.appendingPathComponent("test-\(UUID().uuidString).env")
        
        let content = """
        # This is a comment
        DATABASE_URL=postgres://localhost/mydb
        # Another comment
        PORT=8080
        """
        
        try content.write(to: envFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: envFile) }
        
        let envVars = loadEnvFile(path: envFile.path)
        
        #expect(envVars["DATABASE_URL"] == "postgres://localhost/mydb")
        #expect(envVars["PORT"] == "8080")
        #expect(envVars.count == 2)
    }
    
    @Test("Ignore empty lines in .env file")
    func ignoreEmptyLines() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let envFile = tempDir.appendingPathComponent("test-\(UUID().uuidString).env")
        
        let content = """
        DATABASE_URL=postgres://localhost/mydb
        
        PORT=8080
        
        DEBUG=true
        """
        
        try content.write(to: envFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: envFile) }
        
        let envVars = loadEnvFile(path: envFile.path)
        
        #expect(envVars.count == 3)
    }
    
    @Test("Handle values with equals signs")
    func handleValuesWithEquals() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let envFile = tempDir.appendingPathComponent("test-\(UUID().uuidString).env")
        
        let content = """
        CONNECTION_STRING=Server=localhost;Database=mydb;User=admin
        """
        
        try content.write(to: envFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: envFile) }
        
        let envVars = loadEnvFile(path: envFile.path)
        
        #expect(envVars["CONNECTION_STRING"] == "Server=localhost;Database=mydb;User=admin")
    }
    
    @Test("Handle empty values")
    func handleEmptyValues() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let envFile = tempDir.appendingPathComponent("test-\(UUID().uuidString).env")
        
        let content = """
        EMPTY_VAR=
        NORMAL_VAR=value
        """
        
        try content.write(to: envFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: envFile) }
        
        let envVars = loadEnvFile(path: envFile.path)
        
        #expect(envVars["EMPTY_VAR"] == "")
        #expect(envVars["NORMAL_VAR"] == "value")
    }
    
    @Test("Handle values with spaces")
    func handleValuesWithSpaces() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let envFile = tempDir.appendingPathComponent("test-\(UUID().uuidString).env")
        
        let content = """
        MESSAGE=Hello World
        PATH_WITH_SPACES=/path/to/some directory
        """
        
        try content.write(to: envFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: envFile) }
        
        let envVars = loadEnvFile(path: envFile.path)
        
        #expect(envVars["MESSAGE"] == "Hello World")
        #expect(envVars["PATH_WITH_SPACES"] == "/path/to/some directory")
    }
    
    @Test("Return empty dict for non-existent file")
    func returnEmptyDictForNonExistentFile() {
        let nonExistentPath = "/tmp/non-existent-\(UUID().uuidString).env"
        let envVars = loadEnvFile(path: nonExistentPath)
        
        #expect(envVars.isEmpty)
    }
    
    @Test("Handle mixed content")
    func handleMixedContent() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let envFile = tempDir.appendingPathComponent("test-\(UUID().uuidString).env")
        
        let content = """
        # Application Configuration
        APP_NAME=MyApp
        
        # Database Settings
        DATABASE_URL=postgres://localhost/mydb
        DB_POOL_SIZE=10
        
        # Empty value
        OPTIONAL_VAR=
        
        # Comment at end
        """
        
        try content.write(to: envFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: envFile) }
        
        let envVars = loadEnvFile(path: envFile.path)
        
        #expect(envVars["APP_NAME"] == "MyApp")
        #expect(envVars["DATABASE_URL"] == "postgres://localhost/mydb")
        #expect(envVars["DB_POOL_SIZE"] == "10")
        #expect(envVars["OPTIONAL_VAR"] == "")
        #expect(envVars.count == 4)
    }

    @Test("Load export and quoted env values")
    func loadExportAndQuotedEnvValues() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let envFile = tempDir.appendingPathComponent("test-\(UUID().uuidString).env")

        let content = """
        export TOKEN="abc=123"
        NAME='Example App'
        PLAIN = value
        """

        try content.write(to: envFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: envFile) }

        let envVars = loadEnvFile(path: envFile.path)

        #expect(envVars["TOKEN"] == "abc=123")
        #expect(envVars["NAME"] == "Example App")
        #expect(envVars["PLAIN"] == "value")
    }

    @Test("Later env files override earlier env files")
    func laterEnvFilesOverrideEarlierEnvFiles() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let first = tempDir.appendingPathComponent("test-\(UUID().uuidString)-first.env")
        let second = tempDir.appendingPathComponent("test-\(UUID().uuidString)-second.env")

        try """
        VALUE=first
        KEEP=yes
        """.write(to: first, atomically: true, encoding: .utf8)
        try """
        VALUE=second
        NEW=ok
        """.write(to: second, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }

        let envVars = loadEnvFiles(paths: [first.path, second.path])

        #expect(envVars["VALUE"] == "second")
        #expect(envVars["KEEP"] == "yes")
        #expect(envVars["NEW"] == "ok")
    }

    @Test("Compose global env files do not leak into container runtime environment")
    func globalEnvFilesDoNotLeakIntoRuntimeEnvironment() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-compose-env-\(UUID().uuidString)")
        let serviceEnvFile = tempDir.appendingPathComponent("service.env")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try """
        SERVICE_FILE=present
        OVERRIDE=from-file
        """.write(to: serviceEnvFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let service = Service(
            environment: [
                "EXPLICIT": "yes",
                "FROM_GLOBAL": "${CONFIG_PATH}",
                "OVERRIDE": "from-service",
            ],
            env_file: ["service.env"]
        )
        let runtimeEnv = try composeRuntimeEnvironment(
            for: service,
            composeDirectory: tempDir.path,
            interpolationEnvironment: [
                "CONFIG_PATH": "/resolved/config.ini",
                "GLOBAL_ONLY": "must-not-leak",
                "GLOBAL_CONFIG_PATH": "./config/runtime/debug.ini",
            ],
            containerIps: [:]
        )

        #expect(runtimeEnv["SERVICE_FILE"] == "present")
        #expect(runtimeEnv["EXPLICIT"] == "yes")
        #expect(runtimeEnv["FROM_GLOBAL"] == "/resolved/config.ini")
        #expect(runtimeEnv["OVERRIDE"] == "from-service")
        #expect(runtimeEnv["GLOBAL_ONLY"] == nil)
        #expect(runtimeEnv["GLOBAL_CONFIG_PATH"] == nil)
    }

    @Test("Service env_file required true fails when missing")
    func serviceEnvFileRequiredTrueFailsWhenMissing() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-compose-env-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let service = Service(
            image: "alpine:3.20",
            env_file: ["required.env"],
            envFileConfigurations: [ServiceEnvFile(path: "required.env", required: true)]
        )

        #expect(throws: ComposeError.self) {
            try composeRuntimeEnvironment(
                for: service,
                composeDirectory: tempDir.path,
                interpolationEnvironment: [:],
                containerIps: [:]
            )
        }
    }

    @Test("Service env_file required false stays optional")
    func serviceEnvFileRequiredFalseStaysOptional() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-compose-env-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let service = Service(
            image: "alpine:3.20",
            environment: ["EXPLICIT": "yes"],
            env_file: ["optional.env"],
            envFileConfigurations: [ServiceEnvFile(path: "optional.env", required: false)]
        )

        let runtimeEnv = try composeRuntimeEnvironment(
            for: service,
            composeDirectory: tempDir.path,
            interpolationEnvironment: [:],
            containerIps: [:]
        )

        #expect(runtimeEnv == ["EXPLICIT": "yes"])
    }

    @Test("Service env_file raw format fails before runtime")
    func serviceEnvFileRawFormatFailsBeforeRuntime() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-compose-env-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let service = Service(
            image: "alpine:3.20",
            env_file: ["raw.env"],
            envFileConfigurations: [ServiceEnvFile(path: "raw.env", required: false, format: "raw")]
        )

        #expect(throws: ComposeError.self) {
            try composeRuntimeEnvironment(
                for: service,
                composeDirectory: tempDir.path,
                interpolationEnvironment: [:],
                containerIps: [:]
            )
        }
    }

    @Test("Service environment overrides service env_file values")
    func serviceEnvironmentOverridesServiceEnvFileValues() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-compose-env-\(UUID().uuidString)")
        let envFile = tempDir.appendingPathComponent("service.env")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try """
        SHARED=from-file
        FILE_ONLY=yes
        """.write(to: envFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let service = Service(
            image: "alpine:3.20",
            environment: ["SHARED": "from-service"],
            env_file: ["service.env"],
            envFileConfigurations: [ServiceEnvFile(path: "service.env")]
        )

        let runtimeEnv = try composeRuntimeEnvironment(
            for: service,
            composeDirectory: tempDir.path,
            interpolationEnvironment: [:],
            containerIps: [:]
        )

        #expect(runtimeEnv["FILE_ONLY"] == "yes")
        #expect(runtimeEnv["SHARED"] == "from-service")
    }
}

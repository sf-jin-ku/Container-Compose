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
import Yams
@testable import ContainerComposeCore

@Suite("Healthcheck Runtime Tests")
struct HealthcheckRuntimeTests {
    @Test("Healthcheck CMD maps to direct exec arguments")
    func healthcheckCMDMapsToDirectExecArguments() throws {
        let healthcheck = Healthcheck(test: ["CMD", "redis-cli", "ping"])

        #expect(try healthcheck.commandArguments() == ["redis-cli", "ping"])
    }

    @Test("Healthcheck CMD-SHELL maps to shell arguments")
    func healthcheckCMDShellMapsToShellArguments() throws {
        let healthcheck = Healthcheck(test: ["CMD-SHELL", "pg_isready -U postgres"])

        #expect(try healthcheck.commandArguments() == ["/bin/sh", "-c", "pg_isready -U postgres"])
    }

    @Test("Healthcheck string maps to shell arguments")
    func healthcheckStringMapsToShellArguments() throws {
        let compose = try YAMLDecoder().decode(DockerCompose.self, from: """
        services:
          db:
            image: postgres:16
            healthcheck:
              test: pg_isready -U postgres
        """)

        let healthcheck = try #require(compose.services["db"]??.healthcheck)

        #expect(try healthcheck.commandArguments() == ["/bin/sh", "-c", "pg_isready -U postgres"])
    }

    @Test("Healthcheck NONE maps to no-op true")
    func healthcheckNoneMapsToNoOpTrue() throws {
        let healthcheck = Healthcheck(test: ["NONE"])

        #expect(try healthcheck.commandArguments() == ["/bin/true"])
    }

    @Test("Compose duration strings convert to seconds")
    func composeDurationStringsConvertToSeconds() {
        #expect(composeDurationSeconds("500ms") == 0.5)
        #expect(composeDurationSeconds("2s") == 2)
        #expect(composeDurationSeconds("3m") == 180)
        #expect(composeDurationSeconds("4") == 4)
    }

    @Test("Healthcheck attempts do not add start period when absent")
    func healthcheckAttemptsDoNotAddStartPeriodWhenAbsent() {
        let healthcheck = Healthcheck(interval: "2s", retries: 3)

        #expect(healthcheck.attemptCountIncludingStartPeriod == 3)
    }

    @Test("Healthcheck attempts cover start period grace")
    func healthcheckAttemptsCoverStartPeriodGrace() {
        let healthcheck = Healthcheck(start_period: "10s", interval: "2s", retries: 3)

        #expect(healthcheck.attemptCountIncludingStartPeriod == 8)
    }

    @Test("Healthcheck attempts round fractional start period")
    func healthcheckAttemptsRoundFractionalStartPeriod() {
        let healthcheck = Healthcheck(start_period: "500ms", interval: "250ms", retries: 1)

        #expect(healthcheck.attemptCountIncludingStartPeriod == 3)
    }
}

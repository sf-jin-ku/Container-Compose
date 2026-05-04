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

@Suite("Compose Service Selection Tests")
struct ComposeServiceSelectionTests {
    @Test("Inactive profile services are excluded when no service is requested")
    func inactiveProfileServicesAreExcludedWhenNoServiceIsRequested() throws {
        let compose = try YAMLDecoder().decode(DockerCompose.self, from: """
        services:
          app:
            image: alpine:3.20
          debug:
            image: alpine:3.20
            profiles: debug
        """)

        let selected = try ComposeServiceSelection.selectedServices(
            from: compose,
            requestedServices: [],
            activeProfiles: []
        ).map(\.serviceName)

        #expect(selected == ["app"])
    }

    @Test("Active profile services are included")
    func activeProfileServicesAreIncluded() throws {
        let compose = try YAMLDecoder().decode(DockerCompose.self, from: """
        services:
          app:
            image: alpine:3.20
          debug:
            image: alpine:3.20
            profiles:
              - debug
        """)

        let selected = try ComposeServiceSelection.selectedServices(
            from: compose,
            requestedServices: [],
            activeProfiles: ["debug"]
        ).map(\.serviceName).sorted()

        #expect(selected == ["app", "debug"])
    }

    @Test("Explicit requested service bypasses inactive profile filtering")
    func explicitRequestedServiceBypassesInactiveProfileFiltering() throws {
        let compose = try YAMLDecoder().decode(DockerCompose.self, from: """
        services:
          debug:
            image: alpine:3.20
            profiles: debug
        """)

        let selected = try ComposeServiceSelection.selectedServices(
            from: compose,
            requestedServices: ["debug"],
            activeProfiles: []
        ).map(\.serviceName)

        #expect(selected == ["debug"])
    }

    @Test("Find services required to complete successfully")
    func findServicesRequiredToCompleteSuccessfully() throws {
        let compose = try YAMLDecoder().decode(DockerCompose.self, from: """
        services:
          migrate:
            image: alpine:3.20
            command: echo ok
          app:
            image: alpine:3.20
            depends_on:
              migrate:
                condition: service_completed_successfully
              db:
                condition: service_healthy
          db:
            image: alpine:3.20
        """)

        let completionServices = ComposeServiceSelection.servicesRequiredToCompleteSuccessfully(in: compose)

        #expect(completionServices == ["migrate"])
    }

    @Test("Full up includes dependencies in dependency-first order")
    func fullUpIncludesDependenciesInDependencyFirstOrder() throws {
        let compose = try YAMLDecoder().decode(DockerCompose.self, from: """
        services:
          app:
            image: alpine:3.20
            depends_on:
              - api
              - db
          api:
            image: alpine:3.20
            depends_on:
              - db
          db:
            image: postgres:16
          debug:
            image: alpine:3.20
            profiles: debug
            depends_on:
              - db
        """)

        let selected = try ComposeServiceSelection.selectedServices(
            from: compose,
            requestedServices: [],
            activeProfiles: []
        ).map(\.serviceName)

        #expect(Set(selected) == ["db", "api", "app"])
        let dbIndex = try #require(selected.firstIndex(of: "db"))
        let apiIndex = try #require(selected.firstIndex(of: "api"))
        let appIndex = try #require(selected.firstIndex(of: "app"))
        #expect(dbIndex < apiIndex)
        #expect(apiIndex < appIndex)
    }

    @Test("Full up includes required dependencies hidden behind inactive profiles")
    func fullUpIncludesRequiredDependenciesHiddenBehindInactiveProfiles() throws {
        let compose = try YAMLDecoder().decode(DockerCompose.self, from: """
        services:
          app:
            image: alpine:3.20
            depends_on:
              db:
                condition: service_started
          db:
            image: postgres:16
            profiles: storage
          debug:
            image: alpine:3.20
            profiles: debug
        """)

        let selected = try ComposeServiceSelection.selectedServices(
            from: compose,
            requestedServices: [],
            activeProfiles: []
        ).map(\.serviceName)

        #expect(selected == ["db", "app"])
    }

    @Test("Targeted up includes transitive dependencies unless no-deps")
    func targetedUpIncludesTransitiveDependenciesUnlessNoDeps() throws {
        let compose = try YAMLDecoder().decode(DockerCompose.self, from: """
        services:
          app:
            image: alpine:3.20
            depends_on:
              - api
          api:
            image: alpine:3.20
            depends_on:
              - db
          db:
            image: postgres:16
        """)

        let withDependencies = try ComposeServiceSelection.selectedServices(
            from: compose,
            requestedServices: ["app"],
            activeProfiles: []
        ).map(\.serviceName)
        let withoutDependencies = try ComposeServiceSelection.selectedServices(
            from: compose,
            requestedServices: ["app"],
            activeProfiles: [],
            includeDependencies: false
        ).map(\.serviceName)

        #expect(withDependencies == ["db", "api", "app"])
        #expect(withoutDependencies == ["app"])
    }

    @Test("Targeted down stops exact services without dependencies")
    func targetedDownStopsExactServicesWithoutDependencies() throws {
        let compose = try YAMLDecoder().decode(DockerCompose.self, from: """
        services:
          app:
            image: alpine:3.20
            depends_on:
              - api
          api:
            image: alpine:3.20
            depends_on:
              - db
          db:
            image: postgres:16
        """)

        let selected = try ComposeServiceSelection.servicesToStopForDown(
            from: compose,
            requestedServices: ["app"],
            activeProfiles: []
        ).map(\.serviceName)

        #expect(selected == ["app"])
    }

    @Test("Full down excludes inactive profile services")
    func fullDownExcludesInactiveProfileServices() throws {
        let compose = try YAMLDecoder().decode(DockerCompose.self, from: """
        services:
          app:
            image: alpine:3.20
          debug:
            image: alpine:3.20
            profiles: debug
        """)

        let selected = try ComposeServiceSelection.servicesToStopForDown(
            from: compose,
            requestedServices: [],
            activeProfiles: []
        ).map(\.serviceName)

        #expect(selected == ["app"])
    }

    @Test("No deps skips dependency condition validation")
    func noDepsSkipsDependencyConditionValidation() throws {
        let compose = try YAMLDecoder().decode(DockerCompose.self, from: """
        services:
          app:
            image: alpine:3.20
            depends_on:
              db:
                condition: service_ready
          db:
            image: postgres:16
        """)

        #expect(throws: ComposeError.self) {
            try ComposeServiceSelection.selectedServices(
                from: compose,
                requestedServices: ["app"],
                activeProfiles: []
            )
        }

        let selected = try ComposeServiceSelection.selectedServices(
            from: compose,
            requestedServices: ["app"],
            activeProfiles: [],
            includeDependencies: false
        ).map(\.serviceName)

        #expect(selected == ["app"])
    }

    @Test("Missing required dependencies fail before lifecycle")
    func missingRequiredDependenciesFailBeforeLifecycle() throws {
        let compose = try YAMLDecoder().decode(DockerCompose.self, from: """
        services:
          app:
            image: alpine:3.20
            depends_on:
              - db
        """)

        do {
            _ = try ComposeServiceSelection.selectedServices(
                from: compose,
                requestedServices: ["app"],
                activeProfiles: []
            )
            Issue.record("Expected missing required depends_on service to fail before lifecycle")
        } catch ComposeError.dependencyNotReady(let message) {
            #expect(message.contains("app"))
            #expect(message.contains("db"))
            #expect(message.contains("missing required service"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Missing optional dependencies do not fail selection")
    func missingOptionalDependenciesDoNotFailSelection() throws {
        let compose = try YAMLDecoder().decode(DockerCompose.self, from: """
        services:
          app:
            image: alpine:3.20
            depends_on:
              metrics:
                condition: service_started
                required: false
        """)

        let selected = try ComposeServiceSelection.selectedServices(
            from: compose,
            requestedServices: ["app"],
            activeProfiles: []
        ).map(\.serviceName)

        #expect(selected == ["app"])
    }

    @Test("Dependency conditions are represented and validated")
    func dependencyConditionsAreRepresentedAndValidated() throws {
        let compose = try YAMLDecoder().decode(DockerCompose.self, from: """
        services:
          app:
            image: alpine:3.20
            depends_on:
              db:
                condition: service_healthy
              migrate:
                condition: service_completed_successfully
          db:
            image: postgres:16
          migrate:
            image: alpine:3.20
        """)

        let app = try #require(compose.services["app"] ?? nil)

        #expect(app.dependencyConfigurations?["db"]?.condition == "service_healthy")
        #expect(app.dependencyConfigurations?["migrate"]?.condition == "service_completed_successfully")
        let selected = try ComposeServiceSelection.selectedServices(
            from: compose,
            requestedServices: ["app"],
            activeProfiles: []
        )
        try ComposeServiceSelection.validateDependencyConditions(in: selected)
    }

    @Test("Unsupported dependency conditions fail before runtime")
    func unsupportedDependencyConditionsFailBeforeRuntime() throws {
        let compose = try YAMLDecoder().decode(DockerCompose.self, from: """
        services:
          app:
            image: alpine:3.20
            depends_on:
              db:
                condition: service_ready
          db:
            image: postgres:16
        """)

        do {
            _ = try ComposeServiceSelection.selectedServices(
                from: compose,
                requestedServices: ["app"],
                activeProfiles: []
            )
            Issue.record("Expected unsupported depends_on condition to fail before runtime")
        } catch ComposeError.unsupportedDependencyCondition(let message) {
            #expect(message.contains("service_ready"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Up reuses only already-running implicit dependencies")
    func upReusesOnlyAlreadyRunningImplicitDependencies() {
        #expect(ComposeServiceSelection.shouldReuseExistingContainerForUp(
            serviceName: "db",
            requestedServices: ["app"],
            containerIsRunning: true
        ))
        #expect(!ComposeServiceSelection.shouldReuseExistingContainerForUp(
            serviceName: "db",
            requestedServices: ["app"],
            containerIsRunning: false
        ))
        #expect(!ComposeServiceSelection.shouldReuseExistingContainerForUp(
            serviceName: "app",
            requestedServices: ["app"],
            containerIsRunning: true
        ))
        #expect(!ComposeServiceSelection.shouldReuseExistingContainerForUp(
            serviceName: "db",
            requestedServices: [],
            containerIsRunning: true
        ))
    }

    @Test("Completed dependency rerun removes stopped metadata first")
    func completedDependencyRerunRemovesStoppedMetadataFirst() {
        #expect(ComposeServiceSelection.shouldRemoveExistingContainerBeforeCompletedUp(
            waitForSuccessfulCompletion: true,
            containerIsStopped: true
        ))
        #expect(!ComposeServiceSelection.shouldRemoveExistingContainerBeforeCompletedUp(
            waitForSuccessfulCompletion: true,
            containerIsStopped: false
        ))
        #expect(!ComposeServiceSelection.shouldRemoveExistingContainerBeforeCompletedUp(
            waitForSuccessfulCompletion: false,
            containerIsStopped: true
        ))
    }

    @Test("Requested services enforce running or healthy readiness")
    func requestedServicesEnforceRunningOrHealthyReadiness() {
        let plainService = Service(image: "alpine:3.20")
        let healthcheckedService = Service(
            image: "alpine:3.20",
            healthcheck: Healthcheck(test: ["CMD", "true"])
        )

        #expect(ComposeServiceSelection.readinessRequirementForUp(
            serviceName: "app",
            service: plainService,
            requestedServices: ["app"],
            waitForSuccessfulCompletion: false
        ) == .running)
        #expect(ComposeServiceSelection.readinessRequirementForUp(
            serviceName: "app",
            service: healthcheckedService,
            requestedServices: ["app"],
            waitForSuccessfulCompletion: false
        ) == .healthy)
        #expect(ComposeServiceSelection.readinessRequirementForUp(
            serviceName: "app",
            service: healthcheckedService,
            requestedServices: [],
            waitForSuccessfulCompletion: false
        ) == .healthy)
        #expect(ComposeServiceSelection.readinessRequirementForUp(
            serviceName: "db",
            service: healthcheckedService,
            requestedServices: ["app"],
            waitForSuccessfulCompletion: false
        ) == .running)
        #expect(ComposeServiceSelection.readinessRequirementForUp(
            serviceName: "migrate",
            service: plainService,
            requestedServices: ["app"],
            waitForSuccessfulCompletion: true
        ) == .completedSuccessfully)
    }

    @Test("Targeted up recreates only explicitly requested services")
    func targetedUpRecreatesOnlyExplicitlyRequestedServices() throws {
        let compose = try YAMLDecoder().decode(DockerCompose.self, from: """
        services:
          db:
            image: postgres:16
          cache:
            image: redis:7
          app:
            image: alpine:3.20
            depends_on:
              db:
                condition: service_healthy
              cache:
                condition: service_started
        """)

        let selected = try ComposeServiceSelection.selectedServices(
            from: compose,
            requestedServices: ["app"],
            activeProfiles: []
        )

        let selectedNames = selected.map(\.serviceName)
        #expect(Set(selectedNames) == ["db", "cache", "app"])
        let appIndex = try #require(selectedNames.firstIndex(of: "app"))
        let dbIndex = try #require(selectedNames.firstIndex(of: "db"))
        let cacheIndex = try #require(selectedNames.firstIndex(of: "cache"))
        #expect(dbIndex < appIndex)
        #expect(cacheIndex < appIndex)

        let recreated = ComposeServiceSelection.servicesToRecreateForUp(
            selectedServices: selected,
            requestedServices: ["app"]
        ).map(\.serviceName)

        #expect(recreated == ["app"])

        let forceRecreated = ComposeServiceSelection.servicesToRecreateForUp(
            selectedServices: selected,
            requestedServices: ["app"],
            forceRecreate: true
        ).map(\.serviceName)

        #expect(Set(forceRecreated) == ["db", "cache", "app"])
    }

    @Test("Full up recreates the selected project services")
    func fullUpRecreatesSelectedProjectServices() throws {
        let compose = try YAMLDecoder().decode(DockerCompose.self, from: """
        services:
          app:
            image: alpine:3.20
          debug:
            image: alpine:3.20
            profiles: debug
        """)

        let selected = try ComposeServiceSelection.selectedServices(
            from: compose,
            requestedServices: [],
            activeProfiles: []
        )

        let recreated = ComposeServiceSelection.servicesToRecreateForUp(
            selectedServices: selected,
            requestedServices: []
        ).map(\.serviceName)

        #expect(recreated == ["app"])
    }
}

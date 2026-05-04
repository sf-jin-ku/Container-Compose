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

enum ComposeServiceReadinessRequirement: Equatable {
    case running
    case healthy
    case completedSuccessfully
}

struct ComposeServiceSelection {
    private static let supportedDependencyConditions: Set<String> = [
        "service_started",
        "service_healthy",
        "service_completed_successfully",
    ]

    static func configuredServices(from dockerCompose: DockerCompose) -> [(serviceName: String, service: Service)] {
        dockerCompose.services.compactMap { serviceName, service in
            guard let service else { return nil }
            return (serviceName, service)
        }
    }

    static func selectedServices(
        from dockerCompose: DockerCompose,
        requestedServices: [String],
        activeProfiles: [String],
        includeDependencies: Bool = true
    ) throws -> [(serviceName: String, service: Service)] {
        let allServices = try Service.topoSortConfiguredServices(configuredServices(from: dockerCompose))
        let availableServiceNames = Set(allServices.map(\.serviceName))
        var services = allServices
        try validateRequestedServicesExist(requestedServices, in: allServices)
        if !requestedServices.isEmpty {
            services = includeDependencies
                ? filterByRequestedServices(allServices, requestedServices: requestedServices)
                : filterByExactRequestedServices(allServices, requestedServices: requestedServices)
        } else {
            let profileEnabledServices = filterByProfiles(allServices, activeProfiles: activeProfiles)
            if includeDependencies {
                let profileEnabledServiceNames = profileEnabledServices.map(\.serviceName)
                services = profileEnabledServiceNames.isEmpty
                    ? []
                    : filterByRequestedServices(allServices, requestedServices: profileEnabledServiceNames)
            } else {
                services = profileEnabledServices
            }
        }
        if includeDependencies {
            try validateRequiredDependenciesExist(in: services, availableServiceNames: availableServiceNames)
            try validateDependencyConditions(in: services)
        }
        return services
    }

    static func servicesToStopForDown(
        from dockerCompose: DockerCompose,
        requestedServices: [String],
        activeProfiles: [String]
    ) throws -> [(serviceName: String, service: Service)] {
        var services = try Service.topoSortConfiguredServices(configuredServices(from: dockerCompose))
        try validateRequestedServicesExist(requestedServices, in: services)
        if !requestedServices.isEmpty {
            return filterByExactRequestedServices(services, requestedServices: requestedServices)
        }
        services = filterByProfiles(services, activeProfiles: activeProfiles)
        return services
    }

    static func validateRequestedServicesExist(
        _ requestedServices: [String],
        in services: [(serviceName: String, service: Service)]
    ) throws {
        guard !requestedServices.isEmpty else { return }
        let serviceNames = Set(services.map(\.serviceName))
        for requestedService in requestedServices where !serviceNames.contains(requestedService) {
            throw ComposeError.dependencyNotReady("service '\(requestedService)' not found")
        }
    }

    static func filterByProfiles(
        _ services: [(serviceName: String, service: Service)],
        activeProfiles: [String]
    ) -> [(serviceName: String, service: Service)] {
        guard !activeProfiles.isEmpty else {
            return services.filter { serviceIsEnabled($0.service, activeProfiles: []) }
        }
        return services.filter { serviceIsEnabled($0.service, activeProfiles: activeProfiles) }
    }

    static func serviceIsEnabled(_ service: Service, activeProfiles: [String]) -> Bool {
        guard let profiles = service.profiles, !profiles.isEmpty else { return true }
        return !Set(profiles).isDisjoint(with: Set(activeProfiles))
    }

    static func filterByRequestedServices(
        _ services: [(serviceName: String, service: Service)],
        requestedServices: [String]
    ) -> [(serviceName: String, service: Service)] {
        guard !requestedServices.isEmpty else { return services }
        let serviceByName = Dictionary(uniqueKeysWithValues: services.map { ($0.serviceName, $0.service) })
        var included = Set<String>()

        func include(_ serviceName: String) {
            guard included.insert(serviceName).inserted else { return }
            for dependencyName in serviceByName[serviceName]?.depends_on ?? [] {
                include(dependencyName)
            }
        }

        for serviceName in requestedServices {
            include(serviceName)
        }

        return services.filter { serviceName, _ in included.contains(serviceName) }
    }

    static func filterByExactRequestedServices(
        _ services: [(serviceName: String, service: Service)],
        requestedServices: [String]
    ) -> [(serviceName: String, service: Service)] {
        guard !requestedServices.isEmpty else { return services }
        return services.filter { serviceName, _ in
            requestedServices.contains(serviceName)
        }
    }

    static func servicesRequiredToCompleteSuccessfully(in dockerCompose: DockerCompose) -> Set<String> {
        Set(configuredServices(from: dockerCompose).flatMap { _, service in
            (service.dependencyConfigurations ?? [:]).compactMap { dependencyName, dependency in
                dependency.condition == "service_completed_successfully" ? dependencyName : nil
            }
        })
    }

    static func validateRequiredDependenciesExist(
        in services: [(serviceName: String, service: Service)],
        availableServiceNames: Set<String>
    ) throws {
        for (serviceName, service) in services {
            for dependencyName in service.depends_on ?? [] {
                let required = service.dependencyConfigurations?[dependencyName]?.required ?? true
                guard required, !availableServiceNames.contains(dependencyName) else { continue }
                throw ComposeError.dependencyNotReady(
                    "service \(serviceName) depends on missing required service \(dependencyName)"
                )
            }
        }
    }

    static func validateDependencyConditions(
        in services: [(serviceName: String, service: Service)]
    ) throws {
        for (serviceName, service) in services {
            for (_, dependency) in service.dependencyConfigurations ?? [:] {
                let condition = dependency.condition ?? "service_started"
                guard supportedDependencyConditions.contains(condition) else {
                    throw ComposeError.unsupportedDependencyCondition(
                        "service '\(serviceName)' uses unsupported depends_on condition '\(condition)'"
                    )
                }
            }
        }
    }

    static func servicesToRecreateForUp(
        selectedServices: [(serviceName: String, service: Service)],
        requestedServices: [String],
        forceRecreate: Bool = false
    ) -> [(serviceName: String, service: Service)] {
        if forceRecreate { return selectedServices }
        guard !requestedServices.isEmpty else { return selectedServices }
        let requested = Set(requestedServices)
        return selectedServices.filter { serviceName, _ in requested.contains(serviceName) }
    }

    static func serviceIsExplicitlyRequested(_ serviceName: String, requestedServices: [String]) -> Bool {
        requestedServices.isEmpty || requestedServices.contains(serviceName)
    }

    static func shouldReuseExistingContainerForUp(
        serviceName: String,
        requestedServices: [String],
        containerIsRunning: Bool
    ) -> Bool {
        !serviceIsExplicitlyRequested(serviceName, requestedServices: requestedServices) && containerIsRunning
    }

    static func shouldRemoveExistingContainerBeforeCompletedUp(
        waitForSuccessfulCompletion: Bool,
        containerIsStopped: Bool
    ) -> Bool {
        waitForSuccessfulCompletion && containerIsStopped
    }

    static func readinessRequirementForUp(
        serviceName: String,
        service: Service,
        requestedServices: [String],
        waitForSuccessfulCompletion: Bool
    ) -> ComposeServiceReadinessRequirement {
        if waitForSuccessfulCompletion {
            return .completedSuccessfully
        }
        if serviceIsExplicitlyRequested(serviceName, requestedServices: requestedServices),
           service.healthcheck != nil {
            return .healthy
        }
        return .running
    }
}

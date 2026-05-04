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

struct ComposeServiceSelection {
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
        let services = try Service.topoSortConfiguredServices(configuredServices(from: dockerCompose))
        try validateRequestedServicesExist(requestedServices, in: services)
        if !requestedServices.isEmpty {
            return includeDependencies
                ? filterByRequestedServices(services, requestedServices: requestedServices)
                : filterByExactRequestedServices(services, requestedServices: requestedServices)
        }
        return filterByProfiles(services, activeProfiles: activeProfiles)
    }

    static func servicesToStopForDown(
        from dockerCompose: DockerCompose,
        requestedServices: [String],
        activeProfiles: [String]
    ) throws -> [(serviceName: String, service: Service)] {
        let services = try Service.topoSortConfiguredServices(configuredServices(from: dockerCompose))
        try validateRequestedServicesExist(requestedServices, in: services)
        if !requestedServices.isEmpty {
            return filterByExactRequestedServices(services, requestedServices: requestedServices)
        }
        return filterByProfiles(services, activeProfiles: activeProfiles)
    }

    static func validateRequestedServicesExist(
        _ requestedServices: [String],
        in services: [(serviceName: String, service: Service)]
    ) throws {
        guard !requestedServices.isEmpty else { return }
        let serviceNames = Set(services.map(\.serviceName))
        for requestedService in requestedServices where !serviceNames.contains(requestedService) {
            throw ComposeError.serviceNotFound(requestedService)
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
}

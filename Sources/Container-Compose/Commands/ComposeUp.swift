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

//
//  ComposeUp.swift
//  Container-Compose
//
//  Created by Morris Richman on 6/19/25.
//

import ArgumentParser
import ContainerCommands
//import ContainerClient
import ContainerAPIClient
import ContainerizationExtras
import Foundation
@preconcurrency import Rainbow

enum ComposeUpPullPolicy: String, ExpressibleByArgument {
    case always
    case missing
    case never
}

public struct ComposeUp: AsyncParsableCommand, @unchecked Sendable {
    public init() {}

    public static let configuration: CommandConfiguration = .init(
        commandName: "up",
        abstract: "Start containers with compose"
    )

    @Argument(help: "Specify the services to start")
    var services: [String] = []

    @Flag(
        name: [.customShort("d"), .customLong("detach")],
        help: "Detaches from container logs. Note: If you do NOT detach, killing this process will NOT kill the container. To kill the container, run container-compose down")
    var detach: Bool = false

    @Option(name: [.customShort("f"), .customLong("file")], parsing: .singleValue, help: "The path to your Docker Compose file")
    var composeFilenames: [String] = []

    @Option(name: .customLong("profile"), parsing: .singleValue, help: "Enable a Compose profile")
    var profiles: [String] = []

    @Flag(name: .customLong("remove-orphans"), help: "Accepted for Docker Compose compatibility")
    var removeOrphans: Bool = false

    @Flag(name: .customLong("no-build"), help: "Do not build images, even if a service defines a build section")
    var noBuild: Bool = false

    @Option(name: .customLong("pull"), help: "Pull policy: missing, always, or never")
    var pullPolicy: ComposeUpPullPolicy = .missing

    @Flag(name: .customLong("force-recreate"), help: "Accepted for Docker Compose compatibility")
    var forceRecreate: Bool = false

    @Flag(name: .customLong("no-deps"), help: "Do not start linked services")
    var noDeps: Bool = false

    private var cwdURL: URL {
        URL(fileURLWithPath: cwd)
    }

    private var composeFiles: ComposeFileSelection {
        ComposeFileSelection.resolve(explicitFilenames: composeFilenames, cwd: cwd, fileManager: fileManager)
    }

    private var composePath: String {
        composeFiles.primaryPath
    }

    private var envFilePaths: [String] {
        let envFiles = process.envFile.isEmpty ? [".env"] : process.envFile
        return envFiles.map { resolvedPath(for: $0, relativeTo: cwdURL) }
    }

    private var composeDirectory: String {
        composeFiles.primaryDirectory
    }

    @Flag(name: [.customShort("b"), .customLong("build")])
    var rebuild: Bool = false

    @Flag(name: .long, help: "Do not use cache")
    var noCache: Bool = false

    @OptionGroup
    var process: Flags.Process

    @OptionGroup
    var logging: Flags.Logging

    private var cwd: String { process.cwd ?? FileManager.default.currentDirectoryPath }

    private var fileManager: FileManager { FileManager.default }
    private var projectName: String?
    private var environmentVariables: [String: String] = [:]
    private var containerIps: [String: String] = [:]
    private var containerConsoleColors: [String: NamedColor] = [:]

    private static let availableContainerConsoleColors: Set<NamedColor> = [
        .blue, .cyan, .magenta, .lightBlack, .lightBlue, .lightCyan, .lightYellow, .yellow, .lightGreen, .green,
    ]

    public mutating func run() async throws {
        environmentVariables = loadEnvFiles(paths: envFilePaths)
        let dockerCompose = try composeFiles.load(fileManager: fileManager, environmentVariables: environmentVariables)

        // Handle 'version' field
        if let version = dockerCompose.version {
            print("Info: Docker Compose file version parsed as: \(version)")
            print("Note: The 'version' field influences how a Docker Compose CLI interprets the file, but this custom 'container-compose' tool directly interprets the schema.")
        }

        // Determine project name for container naming
        if let name = dockerCompose.name {
            projectName = sanitizeComposeProjectName(name)
            print("Info: Docker Compose project name parsed as: \(projectName ?? name)")
            print(
                "Note: The 'name' field affects generated container names and project-scoped volume names. Full project-level isolation for networks is not implemented by this tool."
            )
        } else {
            projectName = deriveProjectName(cwd: cwd)
            print("Info: No 'name' field found in docker-compose.yml. Using directory name as project name: \(projectName ?? "")")
        }

        let services = try ComposeServiceSelection.selectedServices(
            from: dockerCompose,
            requestedServices: self.services,
            activeProfiles: activeComposeProfiles(cliProfiles: profiles),
            includeDependencies: !noDeps
        )
        let servicesToRecreate = ComposeServiceSelection.servicesToRecreateForUp(
            selectedServices: services,
            requestedServices: self.services,
            forceRecreate: forceRecreate
        )

        // Stop Services
        try await stopOldStuff(servicesToRecreate, remove: true)

        // Process top-level networks
        // This creates named networks defined in the docker-compose.yml
        if let networks = dockerCompose.networks {
            print("\n--- Processing Networks ---")
            for (networkName, networkConfig) in networks {
                try await setupNetwork(name: networkName, config: networkConfig)
            }
            print("--- Networks Processed ---\n")
        }

        // Process top-level volumes
        // This creates named volumes defined in the docker-compose.yml
        if let volumes = dockerCompose.volumes {
            print("\n--- Processing Volumes ---")
            for (volumeName, volumeConfig) in volumes {
                guard let volumeConfig else { continue }
                await createVolumeHardLink(name: volumeName, config: volumeConfig)
            }
            print("--- Volumes Processed ---\n")
        }

        // Process each service defined in the docker-compose.yml
        print("\n--- Processing Services ---")

        print(services.map(\.serviceName))
        let servicesRequiredToComplete = ComposeServiceSelection.servicesRequiredToCompleteSuccessfully(in: dockerCompose)
        var completedServices = Set<String>()
        for (serviceName, service) in services {
            let waitForSuccessfulCompletion = servicesRequiredToComplete.contains(serviceName)
            if ComposeServiceSelection.shouldReuseExistingContainerForUp(
                serviceName: serviceName,
                requestedServices: self.services,
                containerIsRunning: try await existingContainerIsRunning(serviceName: serviceName, service: service)
            ) {
                try await updateEnvironmentWithServiceIP(serviceName, containerName: containerName(for: serviceName, service: service))
                continue
            }
            if !noDeps {
                try await waitForDependencies(of: service, in: dockerCompose, completedServices: completedServices)
            }
            if ComposeServiceSelection.shouldRemoveExistingContainerBeforeCompletedUp(
                waitForSuccessfulCompletion: waitForSuccessfulCompletion,
                containerIsStopped: try await existingContainerIsStopped(serviceName: serviceName, service: service)
            ) {
                try await removeExistingContainer(serviceName: serviceName, service: service)
            }
            if try await configService(
                service,
                serviceName: serviceName,
                from: dockerCompose,
                readinessRequirement: ComposeServiceSelection.readinessRequirementForUp(
                    serviceName: serviceName,
                    service: service,
                    requestedServices: self.services,
                    waitForSuccessfulCompletion: waitForSuccessfulCompletion
                )
            ) {
                completedServices.insert(serviceName)
            }
        }

        if !detach {
            await waitForever()
        }
    }

    private func existingContainerIsRunning(serviceName: String, service: Service) async throws -> Bool {
        let containerName = containerName(for: serviceName, service: service)
        let container = try? await ContainerClient().get(id: containerName)
        return container?.status == .running
    }

    private func existingContainerIsStopped(serviceName: String, service: Service) async throws -> Bool {
        let containerName = containerName(for: serviceName, service: service)
        let container = try? await ContainerClient().get(id: containerName)
        return container?.status == .stopped
    }

    private func removeExistingContainer(serviceName: String, service: Service) async throws {
        let containerName = containerName(for: serviceName, service: service)
        guard let container = try? await ContainerClient().get(id: containerName) else {
            return
        }
        try await ContainerClient().delete(id: container.id)
        print("Removed stopped one-shot container: \(containerName)")
    }

    func waitForever() async -> Never {
        for await _ in AsyncStream<Void>(unfolding: {}) {
            // This will never run
        }
        fatalError("unreachable")
    }

    private func getIPForRunningContainer(_ containerName: String) async throws -> String? {
        let client = ContainerClient()
        let container = try await client.get(id: containerName)
        let ip = container.networks.compactMap { $0.ipv4Gateway.description }.first

        return ip
    }

    /// Repeatedly checks `container list -a` until the given container is listed as `running`.
    /// - Parameters:
    ///   - containerName: The exact name of the container (e.g. "Assignment-Manager-API-db").
    ///   - timeout: Max seconds to wait before failing.
    ///   - interval: How often to poll (in seconds).
    /// - Returns: `true` if the container reached "running" state within the timeout.
    private func waitUntilContainerIsRunning(
        _ containerName: String,
        timeout: TimeInterval = 30,
        interval: TimeInterval = 0.5,
        allowStoppedAfterStart: Bool = false
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        let client = ContainerClient()
        var lastStatus = "not found"

        while Date() < deadline {
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            let container = try? await client.get(id: containerName)
            guard let container else {
                lastStatus = "not found"
                continue
            }
            lastStatus = container.status.rawValue
            if container.status == .running {
                return
            }
            if container.status == .stopped || container.status == .stopping {
                if allowStoppedAfterStart {
                    return
                }
                throw ComposeError.dependencyNotReady(
                    "container '\(containerName)' reached status '\(container.status.rawValue)' before running"
                )
            }
        }

        throw ComposeError.dependencyNotReady(
            "timed out waiting for container '\(containerName)' to be running; last status: \(lastStatus)"
        )
    }

    private func stopOldStuff(_ services: [(serviceName: String, service: Service)], remove: Bool) async throws {
        guard projectName != nil else { return }
        let containers = services.map { serviceName, service in
            containerName(for: serviceName, service: service)
        }

        for container in containers {
            print("Stopping container: \(container)")
            let client = ContainerClient()
            guard let container = try? await client.get(id: container) else { continue }

            do {
                try await client.stop(id: container.id)
            } catch {
                print("Error Stopping Container: \(error)")
            }
            if remove {
                do {
                    try await client.delete(id: container.id)
                } catch {
                    print("Error Removing Container: \(error)")
                    throw error
                }
            }
        }
    }

    // MARK: Compose Top Level Functions

    private mutating func updateEnvironmentWithServiceIP(_ serviceName: String, containerName: String) async throws {
        let ip = try await getIPForRunningContainer(containerName)
        self.containerIps[serviceName] = ip
        for (key, value) in environmentVariables.map({ ($0, $1) }) where value == serviceName {
            self.environmentVariables[key] = ip ?? value
        }
    }

    private func createVolumeHardLink(name volumeName: String, config volumeConfig: Volume) async {
        guard let projectName else { return }
        let actualVolumeName = volumeConfig.name ?? volumeName  // Use explicit name or key as name

        let volumeUrl = URL.homeDirectory.appending(path: ".containers/Volumes/\(projectName)/\(actualVolumeName)")
        let volumePath = volumeUrl.path(percentEncoded: false)

        print(
            "Warning: Volume source '\(actualVolumeName)' appears to be a named volume reference. The 'container' tool does not support named volume references in 'container run -v' command. Linking to \(volumePath) instead."
        )
        try? fileManager.createDirectory(atPath: volumePath, withIntermediateDirectories: true)
    }

    private func setupNetwork(name networkName: String, config networkConfig: Network?) async throws {
        let actualNetworkName = networkConfig?.name ?? networkName  // Use explicit name or key as name

        if let externalNetwork = networkConfig?.external, externalNetwork.isExternal {
            print("Info: Network '\(networkName)' is declared as external.")
            print("This tool assumes external network '\(externalNetwork.name ?? actualNetworkName)' already exists and will not attempt to create it.")
        } else {
            var networkCreateArgs: [String] = ["network", "create"]

            #warning("Docker Compose Network Options Not Supported")
            // Add driver and driver options
            if let driver = networkConfig?.driver, !driver.isEmpty {
                //                    networkCreateArgs.append("--driver")
                //                    networkCreateArgs.append(driver)
                print("Network Driver Detected, But Not Supported")
            }
            if let driverOpts = networkConfig?.driver_opts, !driverOpts.isEmpty {
                //                    for (optKey, optValue) in driverOpts {
                //                        networkCreateArgs.append("--opt")
                //                        networkCreateArgs.append("\(optKey)=\(optValue)")
                //                    }
                print("Network Options Detected, But Not Supported")
            }
            // Add various network flags
            if networkConfig?.attachable == true {
                //                    networkCreateArgs.append("--attachable")
                print("Network Attachable Flag Detected, But Not Supported")
            }
            if networkConfig?.enable_ipv6 == true {
                //                    networkCreateArgs.append("--ipv6")
                print("Network IPv6 Flag Detected, But Not Supported")
            }
            if networkConfig?.isInternal == true {
                //                    networkCreateArgs.append("--internal")
                print("Network Internal Flag Detected, But Not Supported")
            }  // CORRECTED: Use isInternal

            // Add labels
            if let labels = networkConfig?.labels, !labels.isEmpty {
                print("Network Labels Detected, But Not Supported")
                //                    for (labelKey, labelValue) in labels {
                //                        networkCreateArgs.append("--label")
                //                        networkCreateArgs.append("\(labelKey)=\(labelValue)")
                //                    }
            }

            print("Creating network: \(networkName) (Actual name: \(actualNetworkName))")
            print("Executing container network create: container \(networkCreateArgs.joined(separator: " "))")
            guard (try? await NetworkClient().get(id: actualNetworkName)) == nil else {
                print("Network '\(networkName)' already exists")
                return
            }
            let commands = [actualNetworkName]
            
            let networkCreate = try Application.NetworkCreate.parse(commands + logging.passThroughCommands())

            try await networkCreate.run()
            print("Network '\(networkName)' created")
        }
    }

    // MARK: Compose Service Level Functions
    private mutating func configService(
        _ service: Service,
        serviceName: String,
        from dockerCompose: DockerCompose,
        readinessRequirement: ComposeServiceReadinessRequirement = .running
    ) async throws -> Bool {
        guard projectName != nil else { throw ComposeError.invalidProjectName }
        let waitForSuccessfulCompletion = readinessRequirement == .completedSuccessfully

        var imageToRun: String
        
        var runCommandArgs: [String] = []

        // Handle 'build' configuration
        if let buildConfig = service.build, !noBuild {
            imageToRun = try await buildService(buildConfig, for: service, serviceName: serviceName)
        } else if let img = service.image {
            // Use specified image if no build config
            // Pull image if necessary
            try await pullImage(img, platform: service.platform, policy: pullPolicy)
            imageToRun = img
        } else {
            // Should not happen due to Service init validation, but as a fallback
            throw ComposeError.imageNotFound(serviceName)
        }
        
        // Set Run Platform
        if let platform = service.platform {
            runCommandArgs.append(contentsOf: ["--platform", "\(platform)"])
        }

        // Handle 'deploy' configuration (note that this tool only supports the local runtime subset)
        if service.deploy != nil {
            print("Note: The 'deploy' configuration for service '\(serviceName)' was parsed successfully.")
            print(
                "This tool maps deploy.resources.limits.cpus and deploy.resources.limits.memory to Apple container runtime flags; other deploy features such as replicas, placement, and update strategies are ignored."
            )
            print("The service will be run as a single container based on other configurations.")
        }

        // Add detach flag if specified on the CLI
        if detach && !waitForSuccessfulCompletion {
            runCommandArgs.append("-d")
        }

        // Determine container name
        let containerName: String
        if let explicitContainerName = service.container_name {
            containerName = explicitContainerName
            print("Info: Using explicit container_name: \(containerName)")
        } else {
            // Default container name based on project and service name
            containerName = self.containerName(for: serviceName, service: service)
        }
        runCommandArgs.append("--name")
        runCommandArgs.append(containerName)
        runCommandArgs.append(contentsOf: composeProjectLabelArguments(
            projectName: projectName ?? deriveProjectName(cwd: cwd),
            serviceName: serviceName,
            workingDirectory: composeDirectory,
            composeFilePaths: composeFiles.paths
        ))

        // REMOVED: Restart policy is not supported by `container run`
        // if let restart = service.restart {
        //     runCommandArgs.append("--restart")
        //     runCommandArgs.append(restart)
        // }

        // Add user
        if let user = service.user {
            runCommandArgs.append("--user")
            runCommandArgs.append(user)
        }

        // Add volume mounts
        if let volumes = service.volumes {
            for volume in volumes {
                let args = try await configVolume(volume)
                runCommandArgs.append(contentsOf: args)
            }
        }

        // Combine environment variables from .env files and service environment
        var combinedEnv: [String: String] = environmentVariables

        if let envFiles = service.env_file {
            for envFile in envFiles {
                let additionalEnvVars = loadEnvFile(path: URL(fileURLWithPath: envFile, relativeTo: URL(fileURLWithPath: composeDirectory)).path)
                combinedEnv.merge(additionalEnvVars) { (current, _) in current }
            }
        }

        if let serviceEnv = service.environment {
            combinedEnv.merge(serviceEnv) { (old, new) in
                guard !new.contains("${") else {
                    return old
                }
                return new
            }  // Service env overrides .env files
        }

        // Fill in variables
        combinedEnv = combinedEnv.mapValues({ value in
            guard value.contains("${") else { return value }

            let variableName = String(value.replacingOccurrences(of: "${", with: "").dropLast())
            return combinedEnv[variableName] ?? value
        })

        // Fill in IPs
        combinedEnv = combinedEnv.mapValues({ value in
            containerIps[value] ?? value
        })

        // MARK: Spinning Spot
        // Add environment variables to run command
        for (key, value) in combinedEnv {
            runCommandArgs.append("-e")
            runCommandArgs.append("\(key)=\(value)")
        }

         if let ports = service.ports {
             for port in ports {
                 let resolvedPort = resolveVariable(port, with: environmentVariables)
                 runCommandArgs.append("-p")
                 runCommandArgs.append(composePortToRunArg(resolvedPort))
             }
         }

        // Connect to specified networks
        if let serviceNetworks = service.networks {
            for network in serviceNetworks {
                let resolvedNetwork = resolveVariable(network, with: environmentVariables)
                // Use the explicit network name from top-level definition if available, otherwise resolved name
                let networkToConnect = dockerCompose.networks?[network]??.name ?? resolvedNetwork
                runCommandArgs.append("--network")
                runCommandArgs.append(networkToConnect)
            }
            print(
                "Info: Service '\(serviceName)' is configured to connect to networks: \(serviceNetworks.joined(separator: ", ")) ascertained from the Compose file set."
            )
            print(
                "Note: This tool assumes custom networks are defined at the top-level 'networks' key or are pre-existing. This tool does not create implicit networks for services if not explicitly defined at the top-level."
            )
        } else {
            print("Note: Service '\(serviceName)' is not explicitly connected to any networks. It will likely use the default bridge network.")
        }

        // Add hostname
        if let hostname = service.hostname {
            let resolvedHostname = resolveVariable(hostname, with: environmentVariables)
            runCommandArgs.append("--hostname")
            runCommandArgs.append(resolvedHostname)
        }

        // Add working directory
        if let workingDir = service.working_dir {
            let resolvedWorkingDir = resolveVariable(workingDir, with: environmentVariables)
            runCommandArgs.append("--workdir")
            runCommandArgs.append(resolvedWorkingDir)
        }

        // Add privileged flag
        if service.privileged == true {
            runCommandArgs.append("--privileged")
        }

        // Add read-only flag
        if service.read_only == true {
            runCommandArgs.append("--read-only")
        }

        // Add resource limits
        if let cpus = service.deploy?.resources?.limits?.cpus {
            runCommandArgs.append(contentsOf: ["--cpus", cpus])
        }
        if let memory = service.deploy?.resources?.limits?.memory {
            runCommandArgs.append(contentsOf: ["--memory", memory])
        }

        // Handle service-level configs (note: still only parsing/logging, not attaching)
        if let serviceConfigs = service.configs {
            print(
                "Note: Service '\(serviceName)' defines 'configs'. Docker Compose 'configs' are primarily used for Docker Swarm deployed stacks and are not directly translatable to 'container run' commands."
            )
            print("This tool will parse 'configs' definitions but will not create or attach them to containers during 'container run'.")
            for serviceConfig in serviceConfigs {
                print(
                    "  - Config: '\(serviceConfig.source)' (Target: \(serviceConfig.target ?? "default location"), UID: \(serviceConfig.uid ?? "default"), GID: \(serviceConfig.gid ?? "default"), Mode: \(serviceConfig.mode?.description ?? "default"))"
                )
            }
        }
        //
        // Handle service-level secrets (note: still only parsing/logging, not attaching)
        if let serviceSecrets = service.secrets {
            print(
                "Note: Service '\(serviceName)' defines 'secrets'. Docker Compose 'secrets' are primarily used for Docker Swarm deployed stacks and are not directly translatable to 'container run' commands."
            )
            print("This tool will parse 'secrets' definitions but will not create or attach them to containers during 'container run'.")
            for serviceSecret in serviceSecrets {
                print(
                    "  - Secret: '\(serviceSecret.source)' (Target: \(serviceSecret.target ?? "default location"), UID: \(serviceSecret.uid ?? "default"), GID: \(serviceSecret.gid ?? "default"), Mode: \(serviceSecret.mode?.description ?? "default"))"
                )
            }
        }

        // Add interactive and TTY flags
        if service.stdin_open == true {
            runCommandArgs.append("-i")  // --interactive
        }
        if service.tty == true {
            runCommandArgs.append("-t")  // --tty
        }

        runCommandArgs.append(imageToRun)  // Add the image name as the final argument before command/entrypoint

        // Add entrypoint or command
        if let entrypointParts = service.entrypoint {
            runCommandArgs.append("--entrypoint")
            runCommandArgs.append(contentsOf: entrypointParts)
        } else if let commandParts = service.command {
            runCommandArgs.append(contentsOf: commandParts)
        }

        var serviceColor: NamedColor = Self.availableContainerConsoleColors.randomElement()!

        if Array(Set(containerConsoleColors.values)).sorted(by: { $0.rawValue < $1.rawValue }) != Self.availableContainerConsoleColors.sorted(by: { $0.rawValue < $1.rawValue }) {
            while containerConsoleColors.values.contains(serviceColor) {
                serviceColor = Self.availableContainerConsoleColors.randomElement()!
            }
        }

        let assignedServiceColor = serviceColor
        self.containerConsoleColors[serviceName] = assignedServiceColor

        let handleOutput: @Sendable (String) -> Void = { output in
            print("\(serviceName): \(output)".applyingColor(assignedServiceColor))
        }

        if waitForSuccessfulCompletion {
            print("\nStarting service: \(serviceName)")
            print("Starting \(serviceName)")
            print("----------------------------------------\n")
            let exitCode = try await streamCommand("container", args: ["run"] + runCommandArgs, onStdout: handleOutput, onStderr: handleOutput)
            guard exitCode == 0 else {
                throw ComposeError.dependencyNotCompleted("service '\(serviceName)' exited with status \(exitCode)")
            }
            return true
        }

        if detach {
            print("\nStarting service: \(serviceName)")
            print("Starting \(serviceName)")
            print("----------------------------------------\n")
            let exitCode = try await streamCommand("container", args: ["run"] + runCommandArgs, onStdout: handleOutput, onStderr: handleOutput)
            guard exitCode == 0 else {
                throw ComposeError.dependencyNotReady("service '\(serviceName)' failed to start with status \(exitCode)")
            }
        } else {
            Task { [self, handleOutput] in
                do {
                    print("\nStarting service: \(serviceName)")
                    print("Starting \(serviceName)")
                    print("----------------------------------------\n")
                    let exitCode = try await streamCommand("container", args: ["run"] + runCommandArgs, onStdout: handleOutput, onStderr: handleOutput)
                    if exitCode != 0 {
                        handleOutput("container run exited with status \(exitCode)")
                    }
                } catch {
                    handleOutput("container run failed: \(error)")
                }
            }
        }

        switch readinessRequirement {
        case .running:
            try await waitUntilContainerIsRunning(containerName)
        case .healthy:
            try await waitUntilServiceIsHealthy(serviceName, service: service)
        case .completedSuccessfully:
            break
        }
        try await updateEnvironmentWithServiceIP(serviceName, containerName: containerName)
        return false
    }

    private func pullImage(_ imageName: String, platform: String?, policy: ComposeUpPullPolicy = .missing) async throws {
        guard policy != .never else {
            return
        }
        let imageList = try await ClientImage.list()
        guard policy == .always ||
              !imageList.contains(where: { imageReferenceMatches(localReference: $0.description.reference, requestedReference: imageName) }) else {
            return
        }

        print("Pulling Image \(imageName)...")
        
        var commands = [
            imageName
        ]
        
        if let platform {
            commands.append(contentsOf: ["--platform", platform])
        }

        let imagePull = try Application.ImagePull.parse(commands + logging.passThroughCommands())
        try await imagePull.run()
    }

    /// Builds Docker Service
    ///
    /// - Parameters:
    ///   - buildConfig: The configuration for the build
    ///   - service: The service you would like to build
    ///   - serviceName: The fallback name for the image
    ///
    /// - Returns: Image Name (`String`)
    private func buildService(_ buildConfig: Build, for service: Service, serviceName: String) async throws -> String {
        // Determine image tag for built image
        let imageToRun = service.image ?? "\(serviceName):latest"
        let imageList = try await ClientImage.list()
        if !rebuild, imageList.contains(where: { $0.description.reference.components(separatedBy: "/").last == imageToRun }) {
            return imageToRun
        }

        // Build command arguments
        var commands = [URL(fileURLWithPath: buildConfig.context, relativeTo: URL(fileURLWithPath: composeDirectory)).path]

        // Add build arguments
        for (key, value) in buildConfig.args ?? [:] {
            commands.append(contentsOf: ["--build-arg", "\(key)=\(resolveVariable(value, with: environmentVariables))"])
        }

        // Add Dockerfile path
        commands.append(contentsOf: ["--file", URL(fileURLWithPath: buildConfig.dockerfile ?? "Dockerfile", relativeTo: URL(fileURLWithPath: composeDirectory)).path])
        
        // Add caching options
        if noCache {
            commands.append("--no-cache")
        }
        
        // Add OS/Arch
        let split = service.platform?.split(separator: "/")
        let os = String(split?.first ?? "linux")
        let arch = String(((split ?? []).count >= 1 ? split?.last : nil) ?? "arm64")
        commands.append(contentsOf: ["--os", os])
        commands.append(contentsOf: ["--arch", arch])
        
        // Add image name
        commands.append(contentsOf: ["--tag", imageToRun])
        
        // Add CPU & Memory
        let cpuCount = Int64(service.deploy?.resources?.limits?.cpus ?? "2") ?? 2
        let memoryLimit = service.deploy?.resources?.limits?.memory ?? "2048MB"
        commands.append(contentsOf: ["--cpus", "\(cpuCount)"])
        commands.append(contentsOf: ["--memory", memoryLimit])

        var buildCommand = try Application.BuildCommand.parse(commands)
        print("\n----------------------------------------")
        print("Building image for service: \(serviceName) (Tag: \(imageToRun))")
        try buildCommand.validate()
        try await buildCommand.run()
        print("Image build for \(serviceName) completed.")
        print("----------------------------------------")

        return imageToRun
    }

    private func configVolume(_ volume: String) async throws -> [String] {
        let resolvedVolume = resolveVariable(volume, with: environmentVariables)

        var runCommandArgs: [String] = []

        // Parse the volume string: destination[:mode]
        let components = resolvedVolume.split(separator: ":", maxSplits: 2).map(String.init)

        guard components.count >= 2 else {
            print("Warning: Volume entry '\(resolvedVolume)' has an invalid format (expected 'source:destination'). Skipping.")
            return []
        }

        let source = components[0]
        let destination = components[1]

        // Check if the source looks like a host path (contains '/' or starts with '.')
        // This heuristic helps distinguish bind mounts from named volume references.
        if source.contains("/") || source.starts(with: ".") || source.starts(with: "..") {
            // This is likely a bind mount (local path to container path)
            var isDirectory: ObjCBool = false
            // Ensure the path is absolute or relative to the current directory for FileManager
            let fullHostPath = (source.starts(with: "/") || source.starts(with: "~")) ? source : (cwd + "/" + source)

            if fileManager.fileExists(atPath: fullHostPath, isDirectory: &isDirectory) {
                if isDirectory.boolValue {
                    // Host path exists and is a directory, add the volume
                    runCommandArgs.append("-v")
                    // Reconstruct the volume string without mode, ensuring it's source:destination
                    runCommandArgs.append("\(source):\(destination)")  // Use original source for command argument
                } else {
                    // Host path exists but is a file
                    print("Warning: Volume mount source '\(source)' is a file. The 'container' tool does not support direct file mounts. Skipping this volume.")
                }
            } else {
                // Host path does not exist, assume it's meant to be a directory and try to create it.
                do {
                    try fileManager.createDirectory(atPath: fullHostPath, withIntermediateDirectories: true, attributes: nil)
                    print("Info: Created missing host directory for volume: \(fullHostPath)")
                    runCommandArgs.append("-v")
                    runCommandArgs.append("\(source):\(destination)")  // Use original source for command argument
                } catch {
                    print("Error: Could not create host directory '\(fullHostPath)' for volume '\(resolvedVolume)': \(error.localizedDescription). Skipping this volume.")
                }
            }
        } else {
            guard let projectName else { return [] }
            let volumeUrl = URL.homeDirectory.appending(path: ".containers/Volumes/\(projectName)/\(source)")
            let volumePath = volumeUrl.path(percentEncoded: false)

            let destinationUrl = URL(fileURLWithPath: destination).deletingLastPathComponent()
            let destinationPath = destinationUrl.path(percentEncoded: false)

            print(
                "Warning: Volume source '\(source)' appears to be a named volume reference. The 'container' tool does not support named volume references in 'container run -v' command. Linking to \(volumePath) instead."
            )
            try fileManager.createDirectory(atPath: volumePath, withIntermediateDirectories: true)

            // Host path exists and is a directory, add the volume
            runCommandArgs.append("-v")
            // Reconstruct the volume string without mode, ensuring it's source:destination
            runCommandArgs.append("\(volumePath):\(destinationPath)")  // Use original source for command argument
        }

        return runCommandArgs
    }

    private func waitForDependencies(
        of service: Service,
        in dockerCompose: DockerCompose,
        completedServices: Set<String>
    ) async throws {
        let dependencies = service.dependencyConfigurations ?? [:]
        for (dependencyName, dependency) in dependencies.sorted(by: { $0.key < $1.key }) {
            let required = dependency.required ?? true
            do {
                switch dependency.condition ?? "service_started" {
                case "service_started":
                    try await waitUntilContainerIsRunning(
                        containerName(for: dependencyName, in: dockerCompose)
                    )
                case "service_healthy":
                    try await waitUntilServiceIsHealthy(dependencyName, in: dockerCompose)
                case "service_completed_successfully":
                    guard completedServices.contains(dependencyName) else {
                        throw ComposeError.dependencyNotCompleted("dependency '\(dependencyName)' has not completed successfully")
                    }
                case let condition:
                    throw ComposeError.unsupportedDependencyCondition("unsupported depends_on condition '\(condition)'")
                }
            } catch {
                if required {
                    throw error
                }
                print("Warning: Optional dependency '\(dependencyName)' was not ready: \(error)")
            }
        }
    }

    private func waitUntilServiceIsHealthy(_ serviceName: String, in dockerCompose: DockerCompose) async throws {
        guard let service = dockerCompose.services[serviceName] ?? nil,
              service.healthcheck != nil else {
            try await waitUntilContainerIsRunning(containerName(for: serviceName, in: dockerCompose))
            return
        }
        try await waitUntilServiceIsHealthy(serviceName, service: service)
    }

    private func waitUntilServiceIsHealthy(_ serviceName: String, service: Service) async throws {
        let containerName = containerName(for: serviceName, service: service)
        try await waitUntilContainerIsRunning(containerName)
        guard let healthcheck = service.healthcheck else { return }
        let command = try healthcheck.commandArguments()
        var lastExitCode: Int32?
        for _ in 0..<healthcheck.attemptCountIncludingStartPeriod {
            let exitCode = try await streamCommand(
                "container",
                args: ["exec", containerName] + command,
                onStdout: { _ in },
                onStderr: { _ in }
            )
            if exitCode == 0 {
                return
            }
            lastExitCode = exitCode
            if let container = try? await ContainerClient().get(id: containerName),
               container.status != .running {
                throw ComposeError.dependencyNotHealthy(
                    "service '\(serviceName)' stopped before becoming healthy"
                )
            }
            try await Task.sleep(nanoseconds: UInt64(healthcheck.intervalSeconds * 1_000_000_000))
        }
        let exitDescription = lastExitCode.map { " last healthcheck exit status \($0)." } ?? ""
        throw ComposeError.dependencyNotHealthy("service '\(serviceName)' did not become healthy.\(exitDescription)")
    }

    private func containerName(for serviceName: String, in dockerCompose: DockerCompose) throws -> String {
        guard let service = dockerCompose.services[serviceName] ?? nil else {
            throw ComposeError.dependencyNotReady("dependency service '\(serviceName)' not found")
        }
        return containerName(for: serviceName, service: service)
    }

    private func containerName(for serviceName: String, service: Service) -> String {
        if let explicitContainerName = service.container_name {
            return explicitContainerName
        }
        return composeGeneratedContainerName(projectName: projectName ?? deriveProjectName(cwd: cwd), serviceName: serviceName)
    }
}

// MARK: CommandLine Functions
extension ComposeUp {

    /// Runs a command, streams stdout and stderr via closures, and completes when the process exits.
    ///
    /// - Parameters:
    ///   - command: The name of the command to run (e.g., `"container"`).
    ///   - args: Command-line arguments to pass to the command.
    ///   - onStdout: Closure called with streamed stdout data.
    ///   - onStderr: Closure called with streamed stderr data.
    /// - Returns: The process's exit code.
    /// - Throws: If the process fails to launch.
    @discardableResult
    func streamCommand(
        _ command: String,
        args: [String] = [],
        onStdout: @escaping (@Sendable (String) -> Void),
        onStderr: @escaping (@Sendable (String) -> Void)
    ) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()

            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [command] + args
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            process.environment = ProcessInfo.processInfo.environment.merging([
                "PATH": "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            ]) { _, new in new }

            let stdoutHandle = stdoutPipe.fileHandleForReading
            let stderrHandle = stderrPipe.fileHandleForReading

            stdoutHandle.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                if let string = String(data: data, encoding: .utf8) {
                    onStdout(string)
                }
            }

            stderrHandle.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                if let string = String(data: data, encoding: .utf8) {
                    onStderr(string)
                }
            }

            process.terminationHandler = { proc in
                stdoutHandle.readabilityHandler = nil
                stderrHandle.readabilityHandler = nil
                continuation.resume(returning: proc.terminationStatus)
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

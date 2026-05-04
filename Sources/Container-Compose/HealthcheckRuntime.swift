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

public func composeDurationSeconds(_ value: String?) -> TimeInterval? {
    guard let value else { return nil }
    if value.hasSuffix("ms"), let number = Double(value.dropLast(2)) {
        return number / 1000
    }
    if value.hasSuffix("s"), let number = Double(value.dropLast()) {
        return number
    }
    if value.hasSuffix("m"), let number = Double(value.dropLast()) {
        return number * 60
    }
    return Double(value)
}

public extension Healthcheck {
    func commandArguments() throws -> [String] {
        guard let test, !test.isEmpty else {
            throw ComposeError.unsupportedHealthcheck("healthcheck test is empty")
        }
        let first = test[0]
        switch first {
        case "NONE":
            return ["/bin/true"]
        case "CMD":
            let command = Array(test.dropFirst())
            guard !command.isEmpty else {
                throw ComposeError.unsupportedHealthcheck("healthcheck CMD has no command")
            }
            return command
        case "CMD-SHELL":
            let command = test.dropFirst().joined(separator: " ")
            guard !command.isEmpty else {
                throw ComposeError.unsupportedHealthcheck("healthcheck CMD-SHELL has no command")
            }
            return ["/bin/sh", "-c", command]
        default:
            if test.count == 1 {
                return ["/bin/sh", "-c", first]
            }
            return test
        }
    }

    var intervalSeconds: TimeInterval {
        composeDurationSeconds(interval) ?? 1
    }

    var startPeriodSeconds: TimeInterval {
        composeDurationSeconds(start_period) ?? 0
    }

    var attemptCount: Int {
        max(retries ?? 30, 1)
    }

    var attemptCountIncludingStartPeriod: Int {
        let interval = max(intervalSeconds, 0.001)
        let startPeriodAttempts = Int(ceil(startPeriodSeconds / interval))
        return attemptCount + max(startPeriodAttempts, 0)
    }
}

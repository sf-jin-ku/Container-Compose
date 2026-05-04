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

public extension Service {
    func containerRunRuntimeOptionArguments() -> [String] {
        var arguments: [String] = []

        for tmpfsMount in tmpfs ?? [] {
            arguments += ["--tmpfs", appleContainerTmpfsTarget(from: tmpfsMount)]
        }
        for capability in cap_add ?? [] {
            arguments += ["--cap-add", capability]
        }
        for capability in cap_drop ?? [] {
            arguments += ["--cap-drop", capability]
        }
        for name in (ulimits ?? [:]).keys.sorted() {
            guard let ulimit = ulimits?[name] else { continue }
            if let value = ulimit.value {
                arguments += ["--ulimit", "\(name)=\(value)"]
            } else if let soft = ulimit.soft, let hard = ulimit.hard {
                arguments += ["--ulimit", "\(name)=\(soft):\(hard)"]
            } else if let soft = ulimit.soft {
                arguments += ["--ulimit", "\(name)=\(soft)"]
            }
        }
        if initProcess == true {
            arguments.append("--init")
        }

        return arguments
    }
}

public func appleContainerTmpfsTarget(from composeTmpfs: String) -> String {
    composeTmpfs.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? composeTmpfs
}

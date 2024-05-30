//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftAWSLambdaRuntime open source project
//
// Copyright (c) 2022 Apple Inc. and the SwiftAWSLambdaRuntime project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftAWSLambdaRuntime project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOConcurrencyHelpers
import NIOCore

/// Lambda terminator.
/// Utility to manage the lambda shutdown sequence.
public struct LambdaTerminator: Sendable {
    fileprivate typealias Handler = @Sendable () async throws -> Void

    private var storage: Storage

    init() {
        self.storage = Storage()
    }

    /// Register a shutdown handler with the terminator.
    ///
    /// - parameters:
    ///     - name: Display name for logging purposes.
    ///     - handler: The shutdown handler to call when terminating the Lambda.
    ///             Shutdown handlers are called in the reverse order of being registered.
    ///
    /// - Returns: A ``RegistrationKey`` that can be used to de-register the handler when its no longer needed.
    @discardableResult
    public func register(name: String, handler: @escaping @Sendable () async throws -> Void) async -> RegistrationKey {
        let key = RegistrationKey()
        await self.storage.add(key: key, name: name, handler: handler)
        return key
    }

    /// De-register a shutdown handler with the terminator.
    ///
    /// - parameters:
    ///     - key: A ``RegistrationKey`` obtained from calling the register API.
    public func deregister(_ key: RegistrationKey) async {
        await self.storage.remove(key)
    }

    /// Begin the termination cycle.
    /// Shutdown handlers are called in the reverse order of being registered.
    internal func terminate() async throws {
        var errors: [Error] = []
        for entry in await self.storage.handlers.reversed() {
            do {
                try await entry.handler()
            } catch {
                errors.append(error)
            }
        }
        
        if !errors.isEmpty {
            throw TerminationError(underlying: errors)
        }
    }
}

extension LambdaTerminator {
    /// Lambda terminator registration key.
    public struct RegistrationKey: Sendable, Hashable, CustomStringConvertible {
        var value: String

        init() {
            // UUID basically
            self.value = LambdaRequestID().uuidString
        }

        public var description: String {
            self.value
        }
    }
}

extension LambdaTerminator {
    fileprivate final actor Storage {
        private var index: [RegistrationKey]
        private var map: [RegistrationKey: (name: String, handler: Handler)]

        init() {
            self.index = []
            self.map = [:]
        }

        func add(key: RegistrationKey, name: String, handler: @escaping Handler) {
            self.index.append(key)
            self.map[key] = (name: name, handler: handler)
        }

        func remove(_ key: RegistrationKey) {
            self.index = self.index.filter { $0 != key }
            self.map[key] = nil
        }

        var handlers: [(name: String, handler: Handler)] {
            self.index.compactMap { self.map[$0] }
        }
    }
}

extension LambdaTerminator {
    struct TerminationError: Error {
        let underlying: [Error]
    }
}

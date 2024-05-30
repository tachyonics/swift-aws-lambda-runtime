//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftAWSLambdaRuntime open source project
//
// Copyright (c) 2017-2022 Apple Inc. and the SwiftAWSLambdaRuntime project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftAWSLambdaRuntime project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#if swift(<5.9)
@preconcurrency import Dispatch
#else
import Dispatch
#endif

import Logging
import NIOCore

// MARK: - InitializationContext

/// Lambda runtime initialization context.
/// The Lambda runtime generates and passes the `LambdaInitializationContext` to the Handlers
/// ``ByteBufferLambdaHandler/makeHandler(context:)`` or ``LambdaHandler/init(context:)``
/// as an argument.
public struct LambdaInitializationContext: Sendable {
    /// `Logger` to log with.
    ///
    /// - note: The `LogLevel` can be configured using the `LOG_LEVEL` environment variable.
    public let logger: Logger

    /// `ByteBufferAllocator` to allocate `ByteBuffer`.
    public let allocator: ByteBufferAllocator

    /// ``LambdaTerminator`` to register shutdown operations.
    public let terminator: LambdaTerminator

    init(logger: Logger, allocator: ByteBufferAllocator, terminator: LambdaTerminator) {
        self.logger = logger
        self.allocator = allocator
        self.terminator = terminator
    }

    /// This interface is not part of the public API and must not be used by adopters. This API is not part of semver versioning.
    public static func __forTestsOnly(
        logger: Logger
    ) -> LambdaInitializationContext {
        LambdaInitializationContext(
            logger: logger,
            allocator: ByteBufferAllocator(),
            terminator: LambdaTerminator()
        )
    }
}

// MARK: - Context

/// Lambda runtime context.
/// The Lambda runtime generates and passes the `LambdaContext` to the Lambda handler as an argument.
public struct LambdaContext: CustomDebugStringConvertible, Sendable {
    final class _Storage: Sendable {
        let requestID: String
        let traceID: String
        let invokedFunctionARN: String
        let deadline: DispatchWallTime
        let cognitoIdentity: String?
        let clientContext: String?
        let logger: Logger
        let allocator: ByteBufferAllocator

        init(
            requestID: String,
            traceID: String,
            invokedFunctionARN: String,
            deadline: DispatchWallTime,
            cognitoIdentity: String?,
            clientContext: String?,
            logger: Logger,
            allocator: ByteBufferAllocator
        ) {
            self.requestID = requestID
            self.traceID = traceID
            self.invokedFunctionARN = invokedFunctionARN
            self.deadline = deadline
            self.cognitoIdentity = cognitoIdentity
            self.clientContext = clientContext
            self.logger = logger
            self.allocator = allocator
        }
    }

    private var storage: _Storage

    /// The request ID, which identifies the request that triggered the function invocation.
    public var requestID: String {
        self.storage.requestID
    }

    /// The AWS X-Ray tracing header.
    public var traceID: String {
        self.storage.traceID
    }

    /// The ARN of the Lambda function, version, or alias that's specified in the invocation.
    public var invokedFunctionARN: String {
        self.storage.invokedFunctionARN
    }

    /// The timestamp that the function times out.
    public var deadline: DispatchWallTime {
        self.storage.deadline
    }

    /// For invocations from the AWS Mobile SDK, data about the Amazon Cognito identity provider.
    public var cognitoIdentity: String? {
        self.storage.cognitoIdentity
    }

    /// For invocations from the AWS Mobile SDK, data about the client application and device.
    public var clientContext: String? {
        self.storage.clientContext
    }

    /// `Logger` to log with.
    ///
    /// - note: The `LogLevel` can be configured using the `LOG_LEVEL` environment variable.
    public var logger: Logger {
        self.storage.logger
    }

    /// `ByteBufferAllocator` to allocate `ByteBuffer`.
    /// This is useful when implementing ``EventLoopLambdaHandler``.
    public var allocator: ByteBufferAllocator {
        self.storage.allocator
    }

    init(requestID: String,
         traceID: String,
         invokedFunctionARN: String,
         deadline: DispatchWallTime,
         cognitoIdentity: String? = nil,
         clientContext: String? = nil,
         logger: Logger,
         allocator: ByteBufferAllocator) {
        self.storage = _Storage(
            requestID: requestID,
            traceID: traceID,
            invokedFunctionARN: invokedFunctionARN,
            deadline: deadline,
            cognitoIdentity: cognitoIdentity,
            clientContext: clientContext,
            logger: logger,
            allocator: allocator
        )
    }

    public func getRemainingTime() -> TimeAmount {
        let deadline = self.deadline.millisSinceEpoch
        let now = DispatchWallTime.now().millisSinceEpoch

        let remaining = deadline - now
        return .milliseconds(remaining)
    }

    public var debugDescription: String {
        "\(Self.self)(requestID: \(self.requestID), traceID: \(self.traceID), invokedFunctionARN: \(self.invokedFunctionARN), cognitoIdentity: \(self.cognitoIdentity ?? "nil"), clientContext: \(self.clientContext ?? "nil"), deadline: \(self.deadline))"
    }

    /// This interface is not part of the public API and must not be used by adopters. This API is not part of semver versioning.
    public static func __forTestsOnly(
        requestID: String,
        traceID: String,
        invokedFunctionARN: String,
        timeout: DispatchTimeInterval,
        logger: Logger
    ) -> LambdaContext {
        LambdaContext(
            requestID: requestID,
            traceID: traceID,
            invokedFunctionARN: invokedFunctionARN,
            deadline: .now() + timeout,
            logger: logger,
            allocator: ByteBufferAllocator()
        )
    }
}

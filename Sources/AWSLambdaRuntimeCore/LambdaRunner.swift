//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftAWSLambdaRuntime open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftAWSLambdaRuntime project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftAWSLambdaRuntime project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Dispatch
import Logging
import NIOCore

private struct ByteBufferResponseWriter: ~Copyable, ResponseWriter {
    typealias Output = ByteBuffer?
    
    private let invocation: Invocation
    private let runtimeClient: LambdaRuntimeClient
    private let logger: Logger
    private var state: State
    
    private enum State {
        case initialized
        case finalized
    }
    
    init(invocation: Invocation, runtimeClient: LambdaRuntimeClient, logger: Logger) {
        self.invocation = invocation
        self.runtimeClient = runtimeClient
        self.logger = logger
        self.state = .initialized
    }
    
    private mutating func reportResults(_ result: Result<ByteBuffer?, Error>) async {
        // 3. report results to runtime engine
        do {
            try await self.runtimeClient.reportResults(logger: logger, invocation: invocation, result: result)
        } catch {
            logger.error("could not report results to lambda runtime engine: \(error)")
        }
        
        state = .finalized
    }
    
    internal mutating func finalizeIfRequired() async {
        guard case .initialized = state else {
            return
        }

        await reportResults(.success(nil))
    }
    
    mutating func submit(value: ByteBuffer?) async {
        guard case .initialized = state else {
            fatalError("Response provided multiple times.")
        }

        await reportResults(.success(value))
    }
    
    mutating func submit(error: Swift.Error) async {
        guard case .initialized = state else {
            fatalError("Response provided multiple times.")
        }
        
        logger.warning("lambda handler returned an error: \(error)")
        await reportResults(.failure(error))
    }
}

/// LambdaRunner manages the Lambda runtime workflow, or business logic.
internal final class LambdaRunner {
    private let runtimeClient: LambdaRuntimeClient
    private let allocator: ByteBufferAllocator

    private var isGettingNextInvocation = false

    init(configuration: LambdaConfiguration) {
        self.runtimeClient = LambdaRuntimeClient(configuration: configuration.runtimeEngine)
        self.allocator = ByteBufferAllocator()
    }

    /// Run the user provided initializer. This *must* only be called once.
    ///
    /// - Returns: An `EventLoopFuture<LambdaHandler>` fulfilled with the outcome of the initialization.
    func initialize<Handler: LambdaRuntimeHandler>(
        handlerProvider: @escaping (LambdaInitializationContext) async throws -> Handler,
        logger: Logger,
        terminator: LambdaTerminator
    ) async throws -> Handler {
        logger.debug("initializing lambda")
        // 1. create the handler from the factory
        // 2. report initialization error if one occurred
        let context = LambdaInitializationContext(
            logger: logger,
            allocator: self.allocator,
            terminator: terminator
        )
        
        do {
            return try await handlerProvider(context)
        } catch {
            do {
                try await self.runtimeClient.reportInitializationError(logger: logger, error: error)
            } catch let reportingError {
                // We're going to bail out because the init failed, so there's not a lot we can do other than log
                // that we couldn't report this error back to the runtime.
                logger.error("failed reporting initialization error to lambda runtime engine: \(reportingError)")
                
                throw error
            }
            throw error
        }
    }

    func run(handler: some LambdaRuntimeHandler, logger: Logger) async throws {
        logger.debug("lambda invocation sequence starting")
        // 1. request invocation from lambda runtime engine
        self.isGettingNextInvocation = true
        
        let invocation: Invocation
        let bytes: ByteBuffer
        do {
            (invocation, bytes) = try await self.runtimeClient.getNextInvocation(logger: logger)
        } catch {
            logger.debug("could not fetch work from lambda runtime engine: \(error)")
            
            throw error
        }
        
        // 2. send invocation to handler
        self.isGettingNextInvocation = false
        let context = LambdaContext(
            logger: logger,
            allocator: self.allocator,
            invocation: invocation
        )
        // when log level is trace or lower, print the first Kb of the payload
        if logger.logLevel <= .trace, let buffer = bytes.getSlice(at: 0, length: max(bytes.readableBytes, 1024)) {
            logger.trace("sending invocation to lambda handler",
                         metadata: ["1024 first bytes": .string(String(buffer: buffer))])
        } else {
            logger.debug("sending invocation to lambda handler")
        }
        
        var responseWriter = ByteBufferResponseWriter(invocation: invocation, runtimeClient: self.runtimeClient, logger: logger)
        
        do {
            try await handler.handle(bytes, context: context, responseWriter: &responseWriter)
            
            await responseWriter.finalizeIfRequired()
        } catch {
            await responseWriter.submit(error: error)
        }
    }

    /// cancels the current run, if we are waiting for next invocation (long poll from Lambda control plane)
    /// only needed for debugging purposes.
    func cancelWaitingForNextInvocation() {
        if self.isGettingNextInvocation {
            self.runtimeClient.cancel()
        }
    }
}

extension LambdaContext {
    init(logger: Logger, allocator: ByteBufferAllocator, invocation: Invocation) {
        self.init(requestID: invocation.requestID,
                  traceID: invocation.traceID,
                  invokedFunctionARN: invocation.invokedFunctionARN,
                  deadline: DispatchWallTime(millisSinceEpoch: invocation.deadlineInMillisSinceEpoch),
                  cognitoIdentity: invocation.cognitoIdentity,
                  clientContext: invocation.clientContext,
                  logger: logger,
                  allocator: allocator)
    }
}
/*
// TODO: move to nio?
extension EventLoopFuture {
    // callback does not have side effects, failing with original result
    func peekError(_ callback: @escaping (Error) -> Void) -> EventLoopFuture<Value> {
        self.flatMapError { error in
            callback(error)
            return self
        }
    }

    // callback does not have side effects, failing with original result
    func peekError(_ callback: @escaping (Error) -> EventLoopFuture<Void>) -> EventLoopFuture<Value> {
        self.flatMapError { error in
            let promise = self.eventLoop.makePromise(of: Value.self)
            callback(error).whenComplete { _ in
                promise.completeWith(self)
            }
            return promise.futureResult
        }
    }

    func mapResult<NewValue>(_ callback: @escaping (Result<Value, Error>) -> NewValue) -> EventLoopFuture<NewValue> {
        self.map { value in
            callback(.success(value))
        }.flatMapErrorThrowing { error in
            callback(.failure(error))
        }
    }
}
*/
extension Result {
    private var successful: Bool {
        switch self {
        case .success:
            return true
        case .failure:
            return false
        }
    }
}

/// This is safe since lambda runtime synchronizes by dispatching all methods to a single `EventLoop`
extension LambdaRunner: @unchecked Sendable {}

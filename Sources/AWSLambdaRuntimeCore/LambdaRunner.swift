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

private struct BodyStreamResponseWriter: ~Copyable, ResponseWriter {
    typealias Output = ByteBuffer?
    
    private let bodyStreamContinuation: AsyncStream<Result<ByteBuffer?, Error>>.Continuation
    private let logger: Logger
    private var state: State
    
    private enum State {
        case writable
        case finalized
    }
    
    init(bodyStreamContinuation: AsyncStream<Result<ByteBuffer?, Error>>.Continuation, logger: Logger) {
        self.bodyStreamContinuation = bodyStreamContinuation
        self.logger = logger
        self.state = .writable
    }
    
    internal mutating func finalizeIfRequired() async {
        guard case .writable = state else {
            return
        }

        self.bodyStreamContinuation.finish()
    }
    
    mutating func submit(value: ByteBuffer?) async {
        guard case .writable = state else {
            fatalError("ByteBuffer submitted to finalized BodyStreamResponseWriter")
        }

        self.bodyStreamContinuation.yield(.success(value))
    }
    
    mutating func submit(error: Swift.Error) async {
        guard case .writable = state else {
            fatalError("Error submitted to finalized BodyStreamResponseWriter")
        }
        
        logger.warning("lambda handler returned an error: \(error)")
        self.bodyStreamContinuation.yield(.failure(error))
    }
}

struct LambdaInvocationContext {
    let buffer: ByteBuffer
    let context: LambdaContext
    let bodyStreamContinuation: AsyncStream<Result<ByteBuffer?, Error>>.Continuation
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
    
    func handleInvocations(handler: some LambdaRuntimeHandler, invocationStream: AsyncStream<LambdaInvocationContext>, logger: Logger) async throws {
        // iterate through the invocation stream
        for await invocationContext in invocationStream {
            var responseWriter = BodyStreamResponseWriter(bodyStreamContinuation: invocationContext.bodyStreamContinuation, logger: logger)
            
            do {
                try await handler.handle(invocationContext.buffer, context: invocationContext.context, responseWriter: &responseWriter)
            } catch {
                await responseWriter.submit(error: error)
            }
            
            await responseWriter.finalizeIfRequired()
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

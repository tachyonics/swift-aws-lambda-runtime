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

import Logging
import NIOConcurrencyHelpers
import NIOCore

/// `LambdaRuntime` manages the Lambda process lifecycle.
///
/// Use this API, if you build a higher level web framework which shall be able to run inside the Lambda environment.
public final class LambdaRuntime<Handler: LambdaRuntimeHandler> {
    private let logger: Logger
    private let configuration: LambdaConfiguration

    private let handlerProvider: (LambdaInitializationContext) async throws -> Handler

    private var state = State.idle {
        willSet {
            precondition(newValue.order > self.state.order, "invalid state \(newValue) after \(self.state.order)")
        }
    }

    /// Create a new `LambdaRuntime`.
    ///
    /// - parameters:
    ///     - handlerProvider: A provider of the ``Handler`` the `LambdaRuntime` will manage.
    ///     - eventLoop: An `EventLoop` to run the Lambda on.
    ///     - logger: A `Logger` to log the Lambda events.
    @usableFromInline
    convenience init(
        handlerProvider: @escaping (LambdaInitializationContext) async throws -> Handler,
        logger: Logger
    ) {
        self.init(
            handlerProvider: handlerProvider,
            logger: logger,
            configuration: .init()
        )
    }

    /// Create a new `LambdaRuntime`.
    ///
    /// - parameters:
    ///     - handlerProvider: A provider of the ``Handler`` the `LambdaRuntime` will manage.
    ///     - eventLoop: An `EventLoop` to run the Lambda on.
    ///     - logger: A `Logger` to log the Lambda events.
    init(
        handlerProvider: @escaping (LambdaInitializationContext) async throws -> Handler,
        logger: Logger,
        configuration: LambdaConfiguration
    ) {
        self.logger = logger
        self.configuration = configuration

        self.handlerProvider = handlerProvider
    }

    deinit {
        guard case .shutdown = self.state else {
            preconditionFailure("invalid state \(self.state)")
        }
    }

    /// Start the `LambdaRuntime`.
    public func start() async -> Result<Int, Error> {
        logger.info("lambda runtime starting with \(self.configuration)")
        self.state = .initializing

        var logger = self.logger
        logger[metadataKey: "lifecycleId"] = .string(self.configuration.lifecycle.id)
        let terminator = LambdaTerminator()
        let runner = LambdaRunner(configuration: self.configuration)
        
        defer {
            // triggered when the Lambda has finished its last run or has a startup failure.
            self.markShutdown()
        }

        let runnerResult: Result<Int, Error>
        do {
            let handler = try await runner.initialize(handlerProvider: self.handlerProvider, logger: logger, terminator: terminator)
            
            self.state = .active(runner, handler)
            
            let iterationCount = try await self.run()
            runnerResult = .success(iterationCount)
        } catch {
            return .failure(error)
        }
        
        do {
            try await terminator.terminate()
        } catch {
            // if, we had an error shutting down the handler, we want to concatenate it with
            // the runner result
            logger.error("Error shutting down handler: \(error)")
            return .failure(LambdaRuntimeError.shutdownError(shutdownError: error, runnerResult: runnerResult))
        }
        
        return runnerResult
    }

    // MARK: -  Private

    /// Begin the `LambdaRuntime` shutdown.
    public func shutdown() {
        let oldState = self.state
        self.state = .shuttingdown
        if case .active(let runner, _) = oldState {
            runner.cancelWaitingForNextInvocation()
        }
    }

    private func markShutdown() {
        self.state = .shutdown
    }

    @inline(__always)
    private func run() async throws -> Int {
        var count = 0
        
        while true {
            switch self.state {
            case .active(let runner, let handler):
                if self.configuration.lifecycle.maxTimes > 0, count >= self.configuration.lifecycle.maxTimes {
                    break
                }
                var logger = self.logger
                logger[metadataKey: "lifecycleIteration"] = "\(count)"
                
                do {
                    try await runner.run(handler: handler, logger: logger)
                    
                    logger.log(level: .debug, "lambda invocation sequence completed successfully")
                    // recursive! per aws lambda runtime spec the polling requests are to be done one at a time
                    count += 1
                } catch HTTPClient.Errors.cancelled {
                    if case .shuttingdown = self.state {
                        // if we ware shutting down, we expect to that the get next
                        // invocation request might have been cancelled. For this reason we
                        // succeed the promise here.
                        logger.log(level: .info, "lambda invocation sequence has been cancelled for shutdown")
                        return count
                    }
                    logger.log(level: .error, "lambda invocation sequence has been cancelled unexpectedly")
                    throw HTTPClient.Errors.cancelled
                } catch {
                    logger.log(level: .error, "lambda invocation sequence completed with error: \(error)")
                    throw error
                }
            case .shuttingdown:
                break
            default:
                preconditionFailure("invalid run state: \(self.state)")
            }
        }

        return count
    }

    private enum State {
        case idle
        case initializing
        case active(LambdaRunner, any LambdaRuntimeHandler)
        case shuttingdown
        case shutdown

        internal var order: Int {
            switch self {
            case .idle:
                return 0
            case .initializing:
                return 1
            case .active:
                return 2
            case .shuttingdown:
                return 3
            case .shutdown:
                return 4
            }
        }
    }
}

public enum LambdaRuntimeFactory {
    /// Create a new `LambdaRuntime`.
    ///
    /// - parameters:
    ///     - handlerType: The ``SimpleLambdaHandler`` type the `LambdaRuntime` shall create and manage.
    ///     - eventLoop: An `EventLoop` to run the Lambda on.
    ///     - logger: A `Logger` to log the Lambda events.
    @inlinable
    public static func makeRuntime<Handler: SimpleLambdaHandler>(
        _ handlerType: Handler.Type,
        logger: Logger
    ) -> LambdaRuntime<some ByteBufferLambdaHandler> {
        LambdaRuntime<CodableSimpleLambdaHandler<Handler>>(
            handlerProvider: CodableSimpleLambdaHandler<Handler>.makeHandler(context:),
            logger: logger
        )
    }

    /// Create a new `LambdaRuntime`.
    ///
    /// - parameters:
    ///     - handlerType: The ``LambdaHandler`` type the `LambdaRuntime` shall create and manage.
    ///     - eventLoop: An `EventLoop` to run the Lambda on.
    ///     - logger: A `Logger` to log the Lambda events.
    @inlinable
    public static func makeRuntime<Handler: LambdaHandler>(
        _ handlerType: Handler.Type,
        logger: Logger
    ) -> LambdaRuntime<some LambdaRuntimeHandler> {
        LambdaRuntime<CodableLambdaHandler<Handler>>(
            handlerProvider: CodableLambdaHandler<Handler>.makeHandler(context:),
            logger: logger
        )
    }
/*
    /// Create a new `LambdaRuntime`.
    ///
    /// - parameters:
    ///     - handlerType: The ``EventLoopLambdaHandler`` type the `LambdaRuntime` shall create and manage.
    ///     - eventLoop: An `EventLoop` to run the Lambda on.
    ///     - logger: A `Logger` to log the Lambda events.
    @inlinable
    public static func makeRuntime<Handler: EventLoopLambdaHandler>(
        _ handlerType: Handler.Type,
        eventLoop: any EventLoop,
        logger: Logger
    ) -> LambdaRuntime<some LambdaRuntimeHandler> {
        LambdaRuntime<CodableEventLoopLambdaHandler<Handler>>(
            handlerProvider: CodableEventLoopLambdaHandler<Handler>.makeHandler(context:),
            eventLoop: eventLoop,
            logger: logger
        )
    }
*/
    /// Create a new `LambdaRuntime`.
    ///
    /// - parameters:
    ///     - handlerType: The ``ByteBufferLambdaHandler`` type the `LambdaRuntime` shall create and manage.
    ///     - eventLoop: An `EventLoop` to run the Lambda on.
    ///     - logger: A `Logger` to log the Lambda events.
    @inlinable
    public static func makeRuntime<Handler: ByteBufferLambdaHandler>(
        _ handlerType: Handler.Type,
        logger: Logger
    ) -> LambdaRuntime<some LambdaRuntimeHandler> {
        LambdaRuntime<Handler>(
            handlerProvider: Handler.makeHandler(context:),
            logger: logger
        )
    }

    /// Create a new `LambdaRuntime`.
    ///
    /// - parameters:
    ///     - handlerProvider: A provider of the ``Handler`` the `LambdaRuntime` will manage.
    ///     - eventLoop: An `EventLoop` to run the Lambda on.
    ///     - logger: A `Logger` to log the Lambda events.
    @inlinable
    public static func makeRuntime<Handler: LambdaRuntimeHandler>(
        handlerProvider: @escaping (LambdaInitializationContext) async throws -> Handler,
        logger: Logger
    ) -> LambdaRuntime<Handler> {
        LambdaRuntime(
            handlerProvider: handlerProvider,
            logger: logger
        )
    }
}

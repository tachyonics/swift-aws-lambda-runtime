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

import Dispatch
import NIOCore

// MARK: - SimpleTypedResponseWriter

public struct SimpleTypedResponseWriter<UnderlyingHandler: SimpleLambdaHandler, UnderlyingWriter: ResponseWriter<ByteBuffer?> & ~Copyable>: ResponseWriter, ~Copyable {
    @usableFromInline
    var writer: UnderlyingWriter
    @usableFromInline
    let handler: UnderlyingHandler
    @usableFromInline
    private(set) var outputBuffer: ByteBuffer
    
    @inlinable
    init(handler: UnderlyingHandler, writer: consuming UnderlyingWriter, outputBuffer: ByteBuffer) {
        self.writer = writer
        self.handler = handler
        self.outputBuffer = outputBuffer
    }
    
    public mutating func submit(value: UnderlyingHandler.Output) async throws {
        var outputBuffer = self.outputBuffer
        try self.handler.encode(value: value, into: &outputBuffer)
        
        try await self.writer.submit(value: outputBuffer)
    }
    
    public mutating func submit(error: Swift.Error) async throws {
        try await self.writer.submit(error: error)
    }
}

// MARK: - SimpleLambdaHandler

/// Strongly typed, processing protocol for a Lambda that takes a user defined
/// ``SimpleLambdaHandler/Event`` and returns a user defined
/// ``SimpleLambdaHandler/Output`` asynchronously.
///
/// - note: Most users should implement the ``LambdaHandler`` protocol instead
///         which defines the Lambda initialization method.
public protocol SimpleLambdaHandler {
    /// The lambda function's input. In most cases this should be `Codable`. If your event originates from an
    /// AWS service, have a look at [AWSLambdaEvents](https://github.com/swift-server/swift-aws-lambda-events),
    /// which provides a number of commonly used AWS Event implementations.
    associatedtype Event
    /// The lambda function's output. Can be `Void`.
    associatedtype Output

    init()

    /// The Lambda handling method.
    /// Concrete Lambda handlers implement this method to provide the Lambda functionality.
    ///
    /// - parameters:
    ///     - event: Event of type `Event` representing the event or request.
    ///     - context: Runtime ``LambdaContext``.
    ///     - responseWriter: Typed response writer to return the response to the caller.
    ///
    /// - Returns: A Lambda result ot type `Output`.
    func handle(_ event: Event, context: LambdaContext, responseWriter: inout some (ResponseWriter<Output> & ~Copyable)) async throws

    /// Encode a response of type ``Output`` to `ByteBuffer`.
    /// Concrete Lambda handlers implement this method to provide coding functionality.
    /// - parameters:
    ///     - value: Response of type ``Output``.
    ///     - buffer: A `ByteBuffer` to encode into, will be overwritten.
    ///
    /// - Returns: A `ByteBuffer` with the encoded version of the `value`.
    func encode(value: Output, into buffer: inout ByteBuffer) throws

    /// Decode a `ByteBuffer` to a request or event of type ``Event``.
    /// Concrete Lambda handlers implement this method to provide coding functionality.
    ///
    /// - parameters:
    ///     - buffer: The `ByteBuffer` to decode.
    ///
    /// - Returns: A request or event of type ``Event``.
    func decode(buffer: ByteBuffer) throws -> Event
}

@usableFromInline
final class CodableSimpleLambdaHandler<Underlying: SimpleLambdaHandler>: ByteBufferLambdaHandler {
    @usableFromInline
    let handler: Underlying
    @usableFromInline
    private(set) var outputBuffer: ByteBuffer

    @inlinable
    static func makeHandler(context: LambdaInitializationContext) async throws -> CodableSimpleLambdaHandler {
        let handler = Underlying()
        return CodableSimpleLambdaHandler(handler: handler, allocator: context.allocator)
    }

    @inlinable
    init(handler: Underlying, allocator: ByteBufferAllocator) {
        self.handler = handler
        self.outputBuffer = allocator.buffer(capacity: 1024 * 1024)
    }

    @inlinable
    func handle(_ buffer: ByteBuffer, context: LambdaContext, responseWriter: inout some (ResponseWriter<ByteBuffer?> & ~Copyable)) async throws {
        let input: Underlying.Event
        do {
            input = try self.handler.decode(buffer: buffer)
        } catch {
            throw CodecError.requestDecoding(error)
        }
        
        self.outputBuffer.clear()
        // create a typed response writer, consuming `responseWriter`
        var typedResponseWriter = SimpleTypedResponseWriter(handler: self.handler, writer: responseWriter, outputBuffer: self.outputBuffer)
        
        do {
            try await self.handler.handle(input, context: context, responseWriter: &typedResponseWriter)
        } catch {
            // rethrow the error after restoring`responseWriter` which was consumed by `typedResponseWriter`
            responseWriter = typedResponseWriter.writer
            throw error
        }
        
        // restore `responseWriter` which was consumed by `typedResponseWriter`
        responseWriter = typedResponseWriter.writer
    }
}

/// Implementation of `ByteBuffer` to `Void` decoding.
extension SimpleLambdaHandler where Output == Void {
    @inlinable
    public func encode(value: Output, into buffer: inout ByteBuffer) throws {}
}

extension SimpleLambdaHandler {
    /// Initializes and runs the Lambda function.
    ///
    /// If you precede your ``SimpleLambdaHandler`` conformer's declaration with the
    /// [@main](https://docs.swift.org/swift-book/ReferenceManual/Attributes.html#ID626)
    /// attribute, the system calls the conformer's `main()` method to launch the lambda function.
    ///
    /// The lambda runtime provides a default implementation of the method that manages the launch
    /// process.
    public static func main() async {
        _ = await Lambda.run(configuration: .init(), handlerType: Self.self)
    }
}

// MARK: - TypedResponseWriter

public struct TypedResponseWriter<UnderlyingHandler: LambdaHandler, UnderlyingWriter: ResponseWriter<ByteBuffer?> & ~Copyable>: ResponseWriter, ~Copyable {
    @usableFromInline
    var writer: UnderlyingWriter
    @usableFromInline
    let handler: UnderlyingHandler
    @usableFromInline
    private(set) var outputBuffer: ByteBuffer
    
    @inlinable
    init(handler: UnderlyingHandler, writer: consuming UnderlyingWriter, outputBuffer: ByteBuffer) {
        self.writer = writer
        self.handler = handler
        self.outputBuffer = outputBuffer
    }
    
    public mutating func submit(value: UnderlyingHandler.Output) async throws {
        var outputBuffer = self.outputBuffer
        try self.handler.encode(value: value, into: &outputBuffer)
        
        try await self.writer.submit(value: outputBuffer)
    }
    
    public mutating func submit(error: Swift.Error) async throws {
        try await self.writer.submit(error: error)
    }
}

// MARK: - LambdaHandler

/// Strongly typed, processing protocol for a Lambda that takes a user defined
/// ``LambdaHandler/Event`` and returns a user defined
/// ``LambdaHandler/Output`` asynchronously.
///
/// - note: Most users should implement this protocol instead of the lower
///         level protocols ``EventLoopLambdaHandler`` and
///         ``ByteBufferLambdaHandler``.
public protocol LambdaHandler {
    /// The lambda function's input. In most cases this should be `Codable`. If your event originates from an
    /// AWS service, have a look at [AWSLambdaEvents](https://github.com/swift-server/swift-aws-lambda-events),
    /// which provides a number of commonly used AWS Event implementations.
    associatedtype Event
    /// The lambda function's output. Can be `Void`.
    associatedtype Output

    /// The Lambda initialization method.
    /// Use this method to initialize resources that will be used in every request.
    ///
    /// Examples for this can be HTTP or database clients.
    /// - parameters:
    ///     - context: Runtime ``LambdaInitializationContext``.
    init(context: LambdaInitializationContext) async throws

    /// The Lambda handling method.
    /// Concrete Lambda handlers implement this method to provide the Lambda functionality.
    ///
    /// - parameters:
    ///     - event: Event of type `Event` representing the event or request.
    ///     - context: Runtime ``LambdaContext``.
    ///     - responseWriter: Typed response writer to return the response to the caller.
    ///
    /// - Returns: A Lambda result ot type `Output`.
    func handle(_ event: Event, context: LambdaContext, responseWriter: inout some (ResponseWriter<Output> & ~Copyable)) async throws

    /// Encode a response of type ``Output`` to `ByteBuffer`.
    /// Concrete Lambda handlers implement this method to provide coding functionality.
    /// - parameters:
    ///     - value: Response of type ``Output``.
    ///     - buffer: A `ByteBuffer` to encode into, will be overwritten.
    ///
    /// - Returns: A `ByteBuffer` with the encoded version of the `value`.
    func encode(value: Output, into buffer: inout ByteBuffer) throws

    /// Decode a `ByteBuffer` to a request or event of type ``Event``.
    /// Concrete Lambda handlers implement this method to provide coding functionality.
    ///
    /// - parameters:
    ///     - buffer: The `ByteBuffer` to decode.
    ///
    /// - Returns: A request or event of type ``Event``.
    func decode(buffer: ByteBuffer) throws -> Event
}

@usableFromInline
final class CodableLambdaHandler<Underlying: LambdaHandler>: ByteBufferLambdaHandler {
    @usableFromInline
    let handler: Underlying
    @usableFromInline
    private(set) var outputBuffer: ByteBuffer

    @inlinable
    static func makeHandler(context: LambdaInitializationContext) async throws -> CodableLambdaHandler {
        let handler = try await Underlying(context: context)
        return CodableLambdaHandler(handler: handler, allocator: context.allocator)
    }

    @inlinable
    init(handler: Underlying, allocator: ByteBufferAllocator) {
        self.handler = handler
        self.outputBuffer = allocator.buffer(capacity: 1024 * 1024)
    }

    @inlinable
    func handle(_ buffer: ByteBuffer, context: LambdaContext, responseWriter: inout some (ResponseWriter<ByteBuffer?> & ~Copyable)) async throws {
        let input: Underlying.Event
        do {
            input = try self.handler.decode(buffer: buffer)
        } catch {
            throw CodecError.requestDecoding(error)
        }
        
        self.outputBuffer.clear()
        // create a typed response writer, consuming `responseWriter`
        var typedResponseWriter = TypedResponseWriter(handler: self.handler, writer: responseWriter, outputBuffer: self.outputBuffer)
        
        do {
            try await self.handler.handle(input, context: context, responseWriter: &typedResponseWriter)
        } catch {
            // rethrow the error after restoring`responseWriter` which was consumed by `typedResponseWriter`
            responseWriter = typedResponseWriter.writer
            throw error
        }
        
        // restore `responseWriter` which was consumed by `typedResponseWriter`
        responseWriter = typedResponseWriter.writer
    }
}

/// Implementation of `ByteBuffer` to `Void` decoding.
extension LambdaHandler where Output == Void {
    @inlinable
    public func encode(value: Output, into buffer: inout ByteBuffer) throws {}
}

extension LambdaHandler {
    /// Initializes and runs the Lambda function.
    ///
    /// If you precede your ``LambdaHandler`` conformer's declaration with the
    /// [@main](https://docs.swift.org/swift-book/ReferenceManual/Attributes.html#ID626)
    /// attribute, the system calls the conformer's `main()` method to launch the lambda function.
    ///
    /// The lambda runtime provides a default implementation of the method that manages the launch
    /// process.
    public static func main() async {
        _ = await Lambda.run(configuration: .init(), handlerType: Self.self)
    }
}

/// unchecked sendable wrapper for the handler
/// this is safe since lambda runtime is designed to calls the handler serially
@usableFromInline
internal struct UncheckedSendableHandler<Underlying: LambdaHandler, Event, Output>: @unchecked Sendable where Event == Underlying.Event, Output == Underlying.Output {
    @usableFromInline
    let underlying: Underlying

    @inlinable
    init(underlying: Underlying) {
        self.underlying = underlying
    }

    @inlinable
    func handle(_ event: Event, context: LambdaContext, responseWriter: inout some (ResponseWriter<Output> & ~Copyable)) async throws {
        try await self.underlying.handle(event, context: context, responseWriter: &responseWriter)
    }
}

// MARK: - EventLoopLambdaHandler
/*
/// Strongly typed, `EventLoopFuture` based processing protocol for a Lambda that takes a user
/// defined ``EventLoopLambdaHandler/Event`` and returns a user defined ``EventLoopLambdaHandler/Output`` asynchronously.
///
/// - note: To implement a Lambda, implement either ``LambdaHandler`` or the
///         ``EventLoopLambdaHandler`` protocol. The ``LambdaHandler`` will offload
///         the Lambda execution to an async Task making processing safer but slower (due to
///         fewer thread hops).
///         The ``EventLoopLambdaHandler`` will execute the Lambda on the same `EventLoop`
///         as the core runtime engine, making the processing faster but requires more care from the
///         implementation to never block the `EventLoop`. Implement this protocol only in performance
///         critical situations and implement ``LambdaHandler`` in all other circumstances.
public protocol EventLoopLambdaHandler {
    /// The lambda functions input. In most cases this should be `Codable`. If your event originates from an
    /// AWS service, have a look at [AWSLambdaEvents](https://github.com/swift-server/swift-aws-lambda-events),
    /// which provides a number of commonly used AWS Event implementations.
    associatedtype Event
    /// The lambda functions output. Can be `Void`.
    associatedtype Output

    /// Create a Lambda handler for the runtime.
    ///
    /// Use this to initialize all your resources that you want to cache between invocations. This could be database
    /// connections and HTTP clients for example. It is encouraged to use the given `EventLoop`'s conformance
    /// to `EventLoopGroup` when initializing NIO dependencies. This will improve overall performance, as it
    /// minimizes thread hopping.
    static func makeHandler(context: LambdaInitializationContext) -> EventLoopFuture<Self>

    /// The Lambda handling method.
    /// Concrete Lambda handlers implement this method to provide the Lambda functionality.
    ///
    /// - parameters:
    ///     - context: Runtime ``LambdaContext``.
    ///     - event: Event of type `Event` representing the event or request.
    ///
    /// - Returns: An `EventLoopFuture` to report the result of the Lambda back to the runtime engine.
    ///            The `EventLoopFuture` should be completed with either a response of type ``Output`` or an `Error`.
    func handle(_ event: Event, context: LambdaContext) -> EventLoopFuture<Output>

    /// Encode a response of type ``Output`` to `ByteBuffer`.
    /// Concrete Lambda handlers implement this method to provide coding functionality.
    /// - parameters:
    ///     - value: Response of type ``Output``.
    ///     - buffer: A `ByteBuffer` to encode into, will be overwritten.
    ///
    /// - Returns: A `ByteBuffer` with the encoded version of the `value`.
    func encode(value: Output, into buffer: inout ByteBuffer) throws

    /// Decode a `ByteBuffer` to a request or event of type ``Event``.
    /// Concrete Lambda handlers implement this method to provide coding functionality.
    ///
    /// - parameters:
    ///     - buffer: The `ByteBuffer` to decode.
    ///
    /// - Returns: A request or event of type ``Event``.
    func decode(buffer: ByteBuffer) throws -> Event
}

/// Implementation of `ByteBuffer` to `Void` decoding.
extension EventLoopLambdaHandler where Output == Void {
    @inlinable
    public func encode(value: Output, into buffer: inout ByteBuffer) throws {}
}

@usableFromInline
final class CodableEventLoopLambdaHandler<Underlying: EventLoopLambdaHandler>: ByteBufferLambdaHandler {
    @usableFromInline
    let handler: Underlying
    @usableFromInline
    private(set) var outputBuffer: ByteBuffer

    @inlinable
    static func makeHandler(context: LambdaInitializationContext) -> EventLoopFuture<CodableEventLoopLambdaHandler> {
        Underlying.makeHandler(context: context).map { handler -> CodableEventLoopLambdaHandler<Underlying> in
            CodableEventLoopLambdaHandler(handler: handler, allocator: context.allocator)
        }
    }

    @inlinable
    init(handler: Underlying, allocator: ByteBufferAllocator) {
        self.handler = handler
        self.outputBuffer = allocator.buffer(capacity: 1024 * 1024)
    }

    @inlinable
    func handle(_ buffer: ByteBuffer, context: LambdaContext, responseWriter: inout some (ResponseWriter<ByteBuffer?> & ~Copyable)) async throws {
        let input: Underlying.Event
        do {
            input = try self.handler.decode(buffer: buffer)
        } catch {
            return context.eventLoop.makeFailedFuture(CodecError.requestDecoding(error))
        }

        return self.handler.handle(input, context: context).flatMapThrowing { output in
            do {
                self.outputBuffer.clear()
                try self.handler.encode(value: output, into: &self.outputBuffer)
                return self.outputBuffer
            } catch {
                throw CodecError.responseEncoding(error)
            }
        }
    }
}

extension EventLoopLambdaHandler {
    /// Initializes and runs the Lambda function.
    ///
    /// If you precede your ``EventLoopLambdaHandler`` conformer's declaration with the
    /// [@main](https://docs.swift.org/swift-book/ReferenceManual/Attributes.html#ID626)
    /// attribute, the system calls the conformer's `main()` method to launch the lambda function.
    ///
    /// The lambda runtime provides a default implementation of the method that manages the launch
    /// process.
    public static func main() {
        _ = Lambda.run(configuration: .init(), handlerType: Self.self)
    }
}
*/
// MARK: - ByteBufferLambdaHandler

/// An `EventLoopFuture` based processing protocol for a Lambda that takes a `ByteBuffer` and returns
/// an optional `ByteBuffer` asynchronously.
///
/// - note: This is a low level protocol designed to power the higher level ``EventLoopLambdaHandler`` and
///         ``LambdaHandler`` based APIs.
///         Most users are not expected to use this protocol.
public protocol ByteBufferLambdaHandler: LambdaRuntimeHandler {
    /// Create a Lambda handler for the runtime.
    ///
    /// Use this to initialize all your resources that you want to cache between invocations. This could be database
    /// connections and HTTP clients for example. It is encouraged to use the given `EventLoop`'s conformance
    /// to `EventLoopGroup` when initializing NIO dependencies. This will improve overall performance, as it
    /// minimizes thread hopping.
    static func makeHandler(context: LambdaInitializationContext) async throws -> Self

    /// The Lambda handling method.
    /// Concrete Lambda handlers implement this method to provide the Lambda functionality.
    ///
    /// - parameters:
    ///     - context: Runtime ``LambdaContext``.
    ///     - event: The event or input payload encoded as `ByteBuffer`.
    ///     - responseWriter: writer that returns response encoded as `ByteBuffer` to the caller.
    ///
    /// - Throws: An `Error` response to return to the caller.
    func handle(_ buffer: ByteBuffer, context: LambdaContext, responseWriter: inout some (ResponseWriter<ByteBuffer?> & ~Copyable)) async throws
}

extension ByteBufferLambdaHandler {
    /// Initializes and runs the Lambda function.
    ///
    /// If you precede your ``ByteBufferLambdaHandler`` conformer's declaration with the
    /// [@main](https://docs.swift.org/swift-book/ReferenceManual/Attributes.html#ID626)
    /// attribute, the system calls the conformer's `main()` method to launch the lambda function.
    ///
    /// The lambda runtime provides a default implementation of the method that manages the launch
    /// process.
    public static func main() async {
        _ = await Lambda.run(configuration: .init(), handlerType: Self.self)
    }
}

// MARK: - ResponseWriter

public protocol ResponseWriter<Output>: ~Copyable {
    associatedtype Output
    
    mutating func submit(value: Output) async throws
    
    mutating func submit(error: Swift.Error) async throws
}

// MARK: - LambdaRuntimeHandler

/// An `EventLoopFuture` based processing protocol for a Lambda that takes a `ByteBuffer` and returns
/// an optional `ByteBuffer` asynchronously.
///
/// - note: This is a low level protocol designed to enable use cases where a frameworks initializes the
///         runtime with a handler outside the normal initialization of
///         ``ByteBufferLambdaHandler``, ``EventLoopLambdaHandler`` and ``LambdaHandler`` based APIs.
///         Most users are not expected to use this protocol.
public protocol LambdaRuntimeHandler {
    /// The Lambda handling method.
    /// Concrete Lambda handlers implement this method to provide the Lambda functionality.
    ///
    /// - parameters:
    ///     - context: Runtime ``LambdaContext``.
    ///     - event: The event or input payload encoded as `ByteBuffer`.
    ///     - responseWriter: writer that returns response encoded as `ByteBuffer` to the caller.
    ///
    /// - Throws: An `Error` response to return to the caller.
    func handle(_ buffer: ByteBuffer, context: LambdaContext, responseWriter: inout some (ResponseWriter<ByteBuffer?> & ~Copyable)) async throws
}

// MARK: - Other

@usableFromInline
enum CodecError: Error {
    case requestDecoding(Error)
    case responseEncoding(Error)
    case invalidString
}

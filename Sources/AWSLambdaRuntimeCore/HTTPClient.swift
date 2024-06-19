//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftAWSLambdaRuntime open source project
//
// Copyright (c) 2017-2021 Apple Inc. and the SwiftAWSLambdaRuntime project authors
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
import NIOHTTP1
import NIOPosix
import AsyncAlgorithms

/// A barebone HTTP client to interact with AWS Runtime Engine which is an HTTP server.
/// Note that Lambda Runtime API dictate that only one requests runs at a time.
/// This means we can avoid locks and other concurrency concern we would otherwise need to build into the client
internal final class HTTPClient {
    private let eventLoop: EventLoop
    private let configuration: LambdaConfiguration.RuntimeEngine
    private let targetHost: String

    private var state = State.disconnected
    private var executing = false

    init(eventLoop: EventLoop, configuration: LambdaConfiguration.RuntimeEngine) {
        self.eventLoop = eventLoop
        self.configuration = configuration
        self.targetHost = "\(self.configuration.ip):\(self.configuration.port)"
    }

    func get(url: String, headers: HTTPHeaders, timeout: TimeAmount? = nil) async throws -> Response {
        try await self.execute(Request(targetHost: self.targetHost,
                                       url: url,
                                       method: .GET,
                                       headers: headers),
                                       timeout: timeout ?? self.configuration.requestTimeout)
    }

    func post(url: String, headers: HTTPHeaders, bodyStream: AsyncStream<ByteBuffer>?, timeout: TimeAmount? = nil) async throws -> Response {
        try await self.execute(Request(targetHost: self.targetHost,
                                       url: url,
                                       method: .POST,
                                       headers: headers),
                                       bodyStream: bodyStream,
                                       timeout: timeout ?? self.configuration.requestTimeout)
    }

    /// cancels the current request if there is one
    func cancel() {
        guard self.executing else {
            // there is no request running. nothing to cancel
            return
        }

        guard case .connected(let channel) = self.state else {
            preconditionFailure("if we are executing, we expect to have an open channel")
        }

        channel.triggerUserOutboundEvent(RequestCancelEvent(), promise: nil)
    }

    // TODO: cap reconnect attempt
    private func execute(_ request: Request, bodyStream: AsyncStream<ByteBuffer>? = nil, timeout: TimeAmount?, validate: Bool = true) async throws -> Response {
        if validate {
            precondition(self.executing == false, "expecting single request at a time")
            self.executing = true
        }

        switch self.state {
        case .disconnected:
            let channel = try await connect()
            
            self.state = .connected(channel)
            return try await execute(request, bodyStream: bodyStream, timeout: timeout, validate: false)
        case .connected(let channel):
            guard channel.isActive else {
                self.state = .disconnected
                return try await execute(request, bodyStream: bodyStream, timeout: timeout, validate: false)
            }

            let promise = channel.eventLoop.makePromise(of: Response.self)
            
            var headWritten = false
            if let bodyStream {
                for await bodyPart in bodyStream {
                    // if the head hasn't been written, do so when the first body part is received
                    if !headWritten {
                        let headWrapper = HTTPRequestWrapper(part: .head(request), promise: promise)
                        channel.writeAndFlush(headWrapper).cascadeFailure(to: promise)
                        
                        headWritten = true
                    }
                    let bodyWrapper = HTTPRequestWrapper(part: .body(bodyPart), promise: promise)
                    channel.writeAndFlush(bodyWrapper).cascadeFailure(to: promise)
                }
            }
            
            if !headWritten {
                let headWrapper = HTTPRequestWrapper(part: .head(request), promise: promise)
                channel.writeAndFlush(headWrapper).cascadeFailure(to: promise)
            }
            
            let endWrapper = HTTPRequestWrapper(part: .end(timeout: timeout), promise: promise)
            channel.writeAndFlush(endWrapper).cascadeFailure(to: promise)
            
            defer {
                precondition(self.executing == true, "invalid execution state")
                self.executing = false
            }
            
            return try await promise.futureResult.get()
        }
    }

    private func connect() async throws -> Channel {
        let bootstrap = ClientBootstrap(group: self.eventLoop)
            .channelInitializer { channel in
                do {
                    try channel.pipeline.syncOperations.addHTTPClientHandlers()
                    // Lambda quotas... An invocation payload is maximal 6MB in size:
                    //   https://docs.aws.amazon.com/lambda/latest/dg/gettingstarted-limits.html
                    try channel.pipeline.syncOperations.addHandler(
                        NIOHTTPClientResponseAggregator(maxContentLength: 6 * 1024 * 1024))
                    try channel.pipeline.syncOperations.addHandler(LambdaChannelHandler())
                    return channel.eventLoop.makeSucceededFuture(())
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }

        // connect directly via socket address to avoid happy eyeballs (perf)
        let address = try SocketAddress(ipAddress: self.configuration.ip, port: self.configuration.port)
        return try await bootstrap.connect(to: address).get()
    }

    internal struct Request: Equatable {
        let url: String
        let method: HTTPMethod
        let targetHost: String
        let headers: HTTPHeaders
        let bodySize: Int?

        init(targetHost: String, url: String, method: HTTPMethod = .GET, headers: HTTPHeaders = HTTPHeaders(), bodySize: Int? = nil) {
            self.targetHost = targetHost
            self.url = url
            self.method = method
            self.headers = headers
            self.bodySize = bodySize
        }
    }

    internal struct Response: Equatable {
        var version: HTTPVersion
        var status: HTTPResponseStatus
        var headers: HTTPHeaders
        var body: ByteBuffer?
    }

    internal enum Errors: Error {
        case connectionResetByPeer
        case timeout
        case cancelled
    }

    private enum State {
        case disconnected
        case connected(Channel)
    }
}

// no need in locks since we validate only one request can run at a time
private final class LambdaChannelHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = NIOHTTPClientResponseFull
    typealias OutboundIn = HTTPRequestWrapper
    typealias OutboundOut = HTTPClientRequestPart

    enum State {
        case idle
        case running(promise: EventLoopPromise<HTTPClient.Response>, timeout: Scheduled<Void>?)
        case waitForConnectionClose(HTTPClient.Response, EventLoopPromise<HTTPClient.Response>)
    }

    private var state: State = .idle
    private var lastError: Error?

    init() {}

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        guard case .idle = self.state else {
            preconditionFailure("invalid state, outstanding request")
        }
        let wrapper = unwrapOutboundIn(data)

        switch wrapper.part {
        case .head(let request):
            self.state = .running(promise: wrapper.promise, timeout: nil)
            
            var head = HTTPRequestHead(
                version: .http1_1,
                method: request.method,
                uri: request.url,
                headers: request.headers
            )
            head.headers.add(name: "host", value: request.targetHost)
            switch head.method {
            case .POST, .PUT:
                if let bodySize = request.bodySize {
                    head.headers.add(name: "content-length", value: String(bodySize))
                }
            default:
                break
            }

            context.write(wrapOutboundOut(.head(head)), promise: promise)
        case .body(let body):
            self.state = .running(promise: wrapper.promise, timeout: nil)
            
            if let body {
                context.write(wrapOutboundOut(.body(IOData.byteBuffer(body))), promise: promise)
            }
        case .end(let timeout):
            let timeoutTask = timeout.map {
                let pipeline = context.pipeline
                return context.eventLoop.scheduleTask(in: $0) {
                    guard case .running = self.state else {
                        preconditionFailure("invalid state")
                    }

                    pipeline.fireErrorCaught(HTTPClient.Errors.timeout)
                }
            }
            
            self.state = .running(promise: wrapper.promise, timeout: timeoutTask)
            
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: promise)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard case .running(let promise, let timeout) = self.state else {
            preconditionFailure("invalid state, no pending request")
        }

        let response = unwrapInboundIn(data)

        let httpResponse = HTTPClient.Response(
            version: response.head.version,
            status: response.head.status,
            headers: response.head.headers,
            body: response.body
        )

        timeout?.cancel()

        // As defined in RFC 7230 Section 6.3:
        // HTTP/1.1 defaults to the use of "persistent connections", allowing
        // multiple requests and responses to be carried over a single
        // connection.  The "close" connection option is used to signal that a
        // connection will not persist after the current request/response.  HTTP
        // implementations SHOULD support persistent connections.
        //
        // That's why we only assume the connection shall be closed if we receive
        // a "connection = close" header.
        let serverCloseConnection =
            response.head.headers["connection"].contains(where: { $0.lowercased() == "close" })

        let closeConnection = serverCloseConnection || response.head.version != .http1_1

        if closeConnection {
            // If we were succeeding the request promise here directly and closing the connection
            // after succeeding the promise we may run into a race condition:
            //
            // The lambda runtime will ask for the next work item directly after a succeeded post
            // response request. The desire for the next work item might be faster than the attempt
            // to close the connection. This will lead to a situation where we try to the connection
            // but the next request has already been scheduled on the connection that we want to
            // close. For this reason we postpone succeeding the promise until the connection has
            // been closed. This codepath will only be hit in the very, very unlikely event of the
            // Lambda control plane demanding to close connection. (It's more or less only
            // implemented to support http1.1 correctly.) This behavior is ensured with the test
            // `LambdaTest.testNoKeepAliveServer`.
            self.state = .waitForConnectionClose(httpResponse, promise)
            _ = context.channel.close()
            return
        } else {
            self.state = .idle
            promise.succeed(httpResponse)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        // pending responses will fail with lastError in channelInactive since we are calling context.close
        self.lastError = error
        context.channel.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        // fail any pending responses with last error or assume peer disconnected
        context.fireChannelInactive()

        switch self.state {
        case .idle:
            break
        case .running(let promise, let timeout):
            self.state = .idle
            timeout?.cancel()
            promise.fail(self.lastError ?? HTTPClient.Errors.connectionResetByPeer)

        case .waitForConnectionClose(let response, let promise):
            self.state = .idle
            promise.succeed(response)
        }
    }

    func triggerUserOutboundEvent(context: ChannelHandlerContext, event: Any, promise: EventLoopPromise<Void>?) {
        switch event {
        case is RequestCancelEvent:
            switch self.state {
            case .idle:
                break
            case .running(let promise, let timeout):
                self.state = .idle
                timeout?.cancel()
                promise.fail(HTTPClient.Errors.cancelled)

                // after the cancel error has been send, we want to close the connection so
                // that no more packets can be read on this connection.
                _ = context.channel.close()
            case .waitForConnectionClose(_, let promise):
                self.state = .idle
                promise.fail(HTTPClient.Errors.cancelled)
            }
        default:
            context.triggerUserOutboundEvent(event, promise: promise)
        }
    }
}

private enum HTTPRequestPart: Sendable {
    case head(HTTPClient.Request)
    case body(ByteBuffer?)
    case end(timeout: TimeAmount?)
}

private struct HTTPRequestWrapper {
    let part: HTTPRequestPart
    let promise: EventLoopPromise<HTTPClient.Response>
}

private struct RequestCancelEvent {}

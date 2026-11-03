import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOSSL
import RemoteCore

public struct RemoteRequest: Sendable {
    public let method: String
    public let path: String
    public let host: String
    public let origin: String?
    public let authorization: String?
    public let contentType: String?
    public let body: Data
    public let address: String
}
public struct RemoteResponse: Sendable {
    public var status: Int
    public var body: Data
    public var contentType: String
    public init(status: Int = 200, body: Data, contentType: String = "application/json; charset=utf-8") {
        self.status = status; self.body = body; self.contentType = contentType
    }
    public static func json<T: Encodable>(_ value: T, status: Int = 200) -> Self {
        .init(status: status, body: (try? JSONEncoder().encode(value)) ?? Data("{}".utf8))
    }
    public static func error(_ message: String, status: Int) -> Self { .json(["error": message], status: status) }
}

private final class ConnectionSet: @unchecked Sendable {
    let lock = NSLock()
    var channels: [ObjectIdentifier: Channel] = [:]
    func insert(_ channel: Channel) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard channels.count < 64 else { return false }
        channels[ObjectIdentifier(channel)] = channel
        return true
    }
    func remove(_ channel: Channel) { lock.lock(); channels.removeValue(forKey: ObjectIdentifier(channel)); lock.unlock() }
    func closeAll() {
        lock.lock(); let old = Array(channels.values); channels.removeAll(); lock.unlock()
        for channel in old { channel.close(promise: nil) }
    }
}

private final class ConnectionDeadline: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    var deadline: Scheduled<Void>?
    let connections: ConnectionSet
    init(connections: ConnectionSet) { self.connections = connections }
    func handlerAdded(context: ChannelHandlerContext) {
        deadline = context.eventLoop.scheduleTask(in: .seconds(25)) { context.close(promise: nil) }
    }
    func channelInactive(context: ChannelHandlerContext) {
        deadline?.cancel(); connections.remove(context.channel); context.fireChannelInactive()
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}

private final class RequestHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    let handler: @Sendable (RemoteRequest) async -> RemoteResponse
    var head: HTTPRequestHead?
    var body = Data()
    var responding = false
    init(handler: @escaping @Sendable (RemoteRequest) async -> RemoteResponse) { self.handler = handler }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !responding else { return }
        switch unwrapInboundIn(data) {
        case .head(let head):
            guard self.head == nil, head.uri.utf8.count <= 2048,
                  head.headers["host"].count == 1,
                  head.headers["origin"].count <= 1,
                  head.headers["authorization"].count <= 1 else {
                respond(.error("Invalid request.", status: 400), context: context); return
            }
            self.head = head
        case .body(var chunk):
            guard body.count + chunk.readableBytes <= 131072 else {
                respond(.error("Request too large.", status: 413), context: context); return
            }
            if let bytes = chunk.readBytes(length: chunk.readableBytes) { body.append(contentsOf: bytes) }
        case .end:
            guard let head else { respond(.error("Invalid request.", status: 400), context: context); return }
            responding = true
            let request = RemoteRequest(method: head.method.rawValue, path: head.uri,
                host: head.headers.first(name: "Host") ?? "", origin: head.headers.first(name: "Origin"),
                authorization: head.headers.first(name: "Authorization"), contentType: head.headers.first(name: "Content-Type"),
                body: body, address: context.remoteAddress?.ipAddress ?? "unknown")
            let eventLoop = context.eventLoop
            let contextBox = NIOLoopBound(context, eventLoop: eventLoop)
            let handlerBox = NIOLoopBound(self, eventLoop: eventLoop)
            let handler = self.handler
            Task {
                let response = await handler(request)
                eventLoop.execute { handlerBox.value.respond(response, context: contextBox.value) }
            }
        }
    }
    private func respond(_ response: RemoteResponse, context: ChannelHandlerContext) {
        responding = true
        guard context.channel.isActive else { return }
        let headers = HTTPHeaders([
            ("Content-Type", response.contentType), ("Content-Length", String(response.body.count)),
            ("Connection", "close"), ("Cache-Control", "no-store"), ("X-Content-Type-Options", "nosniff"),
            ("X-Frame-Options", "DENY"), ("Referrer-Policy", "no-referrer"),
            ("Content-Security-Policy", "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; media-src 'self' blob:; img-src 'self' data:; frame-ancestors 'none'; base-uri 'none'; form-action 'self'")
        ])
        context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1,
            status: HTTPResponseStatus(statusCode: response.status), headers: headers))), promise: nil)
        var buffer = context.channel.allocator.buffer(capacity: response.body.count)
        buffer.writeBytes(response.body)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in context.close(promise: nil) }
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}

public final class RemoteHTTPS {
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    private let connections = ConnectionSet()
    private var listeners: [Channel] = []
    var listeningAddresses: [String] { listeners.compactMap { $0.localAddress?.ipAddress } }
    public init() {}
    public func start(addresses: [String], port: Int, files: RemoteFiles, bindAllInterfaces: Bool = false,
                      handler: @escaping @Sendable (RemoteRequest) async -> RemoteResponse) async throws {
        let certificates = try NIOSSLCertificate.fromPEMFile(files.certificateURL.path)
        let key = try NIOSSLPrivateKey(file: files.keyURL.path, format: .pem)
        var tls = TLSConfiguration.makeServerConfiguration(certificateChain: certificates.map { .certificate($0) }, privateKey: .privateKey(key))
        tls.minimumTLSVersion = .tlsv12
        tls.applicationProtocols = ["http/1.1"]
        let context = try NIOSSLContext(configuration: tls)
        let connections = self.connections
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 32)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
            .childChannelInitializer { channel in
                guard connections.insert(channel) else { return channel.close() }
                do {
                    try channel.pipeline.syncOperations.addHandlers(ConnectionDeadline(connections: connections), NIOSSLServerHandler(context: context))
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline(withErrorHandling: true)
                    try channel.pipeline.syncOperations.addHandler(RequestHandler(handler: handler))
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch { connections.remove(channel); return channel.eventLoop.makeFailedFuture(error) }
            }
        do {
            let bindAddresses = bindAllInterfaces ? ["0.0.0.0"] : Set(addresses + ["127.0.0.1"]).sorted()
            for address in bindAddresses {
                let listener = try await bootstrap.bind(host: address, port: port).get()
                listeners.append(listener)
            }
        } catch { await stop(); throw error }
    }
    public func stop() async {
        let old = listeners; listeners.removeAll()
        connections.closeAll()
        for listener in old { try? await listener.close().get() }
    }
    deinit { connections.closeAll(); group.shutdownGracefully { _ in } }
}

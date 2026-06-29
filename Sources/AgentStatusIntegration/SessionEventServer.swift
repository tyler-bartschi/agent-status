import AgentStatusCore
import Darwin
import Foundation

/// Receives one bounded, normalized `SessionEvent` JSON object per local
/// Unix-domain socket connection.
public final class SessionEventServer: @unchecked Sendable {
    public typealias EventHandler = @MainActor @Sendable (SessionEvent) -> Void

    public enum ServerError: LocalizedError {
        case alreadyRunning
        case invalidSocketPath
        case unsafeExistingPath
        case systemCall(String, Int32)

        public var errorDescription: String? {
            switch self {
            case .alreadyRunning:
                "Agent Status is already listening for hook events."
            case .invalidSocketPath:
                "The Agent Status socket path is too long."
            case .unsafeExistingPath:
                "The Agent Status socket path is occupied by a file not owned by this user."
            case let .systemCall(name, code):
                "\(name) failed: \(String(cString: strerror(code)))"
            }
        }
    }

    public static var defaultSocketPath: String {
        "/tmp/agent-status-\(getuid()).sock"
    }

    public let socketPath: String
    public let maximumPayloadSize: Int

    private let queue = DispatchQueue(label: "com.agent-status.session-event-server")
    private let stateLock = NSLock()
    private var source: DispatchSourceRead?
    private var handler: EventHandler?

    public init(
        socketPath: String = SessionEventServer.defaultSocketPath,
        maximumPayloadSize: Int = 64 * 1024
    ) {
        precondition(maximumPayloadSize > 0)
        self.socketPath = socketPath
        self.maximumPayloadSize = maximumPayloadSize
    }

    deinit {
        stop()
    }

    public func start(handler: @escaping EventHandler) throws {
        stateLock.lock()
        defer { stateLock.unlock() }

        guard source == nil else {
            return
        }

        try prepareSocketPath()

        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw ServerError.systemCall("socket", errno)
        }

        do {
            try bind(descriptor: descriptor)

            guard chmod(socketPath, S_IRUSR | S_IWUSR) == 0 else {
                throw ServerError.systemCall("chmod", errno)
            }
            guard listen(descriptor, 16) == 0 else {
                throw ServerError.systemCall("listen", errno)
            }

            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
                throw ServerError.systemCall("fcntl", errno)
            }

            self.handler = handler
            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            source.setEventHandler { [weak self] in
                self?.acceptAvailableConnections(from: descriptor)
            }
            source.setCancelHandler { [socketPath] in
                Darwin.close(descriptor)
                Darwin.unlink(socketPath)
            }
            self.source = source
            source.resume()
        } catch {
            Darwin.close(descriptor)
            Darwin.unlink(socketPath)
            throw error
        }
    }

    public func stop() {
        stateLock.lock()
        let source = self.source
        self.source = nil
        handler = nil
        stateLock.unlock()
        source?.cancel()
        if source != nil {
            // Ensure the cancellation handler has closed and unlinked the old
            // socket before a caller attempts an immediate restart.
            queue.sync {}
        }
    }

    private func prepareSocketPath() throws {
        guard socketPath.utf8CString.count <= MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw ServerError.invalidSocketPath
        }

        var metadata = stat()
        guard lstat(socketPath, &metadata) == 0 else {
            if errno == ENOENT {
                return
            }
            throw ServerError.systemCall("lstat", errno)
        }

        let fileType = metadata.st_mode & mode_t(S_IFMT)
        guard fileType == mode_t(S_IFSOCK), metadata.st_uid == getuid() else {
            throw ServerError.unsafeExistingPath
        }

        if canConnectToExistingSocket() {
            throw ServerError.alreadyRunning
        }

        guard Darwin.unlink(socketPath) == 0 else {
            throw ServerError.systemCall("unlink", errno)
        }
    }

    private func canConnectToExistingSocket() -> Bool {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            return false
        }
        defer { Darwin.close(descriptor) }

        guard var address = socketAddress() else {
            return false
        }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                ) == 0
            }
        }
    }

    private func bind(descriptor: Int32) throws {
        guard var address = socketAddress() else {
            throw ServerError.invalidSocketPath
        }

        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        guard result == 0 else {
            throw ServerError.systemCall("bind", errno)
        }
    }

    private func socketAddress() -> sockaddr_un? {
        let bytes = socketPath.utf8CString
        let capacity = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
        guard bytes.count <= capacity else {
            return nil
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutablePointer(to: &address.sun_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                bytes.withUnsafeBufferPointer { source in
                    _ = memcpy(destination, source.baseAddress, source.count)
                }
            }
        }
        return address
    }

    private func acceptAvailableConnections(from descriptor: Int32) {
        while true {
            let connection = Darwin.accept(descriptor, nil, nil)
            guard connection >= 0 else {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    return
                }
                return
            }

            autoreleasepool {
                receiveEvent(from: connection)
                Darwin.close(connection)
            }
        }
    }

    private func receiveEvent(from descriptor: Int32) {
        var timeout = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        )

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count <= maximumPayloadSize {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.recv(descriptor, bytes.baseAddress, bytes.count, 0)
            }
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
            } else if count == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                return
            }
        }

        guard
            !data.isEmpty,
            data.count <= maximumPayloadSize,
            let event = try? JSONDecoder().decode(SessionEvent.self, from: data)
        else {
            return
        }

        stateLock.lock()
        let handler = self.handler
        stateLock.unlock()
        guard let handler else {
            return
        }

        Task { @MainActor in
            handler(event)
        }
    }
}

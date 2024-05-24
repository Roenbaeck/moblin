import AVFoundation
import ReplayKit

// | 4b header size | <m>b header | <n>b buffer |

// periphery:ignore
private struct Header: Codable {
    var bufferType: Int
    var bufferSize: Int
    var width: Int32
    var height: Int32
}

private func createContainerDir(appGroup: String) throws -> URL {
    guard let containerDir = FileManager.default
        .containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    else {
        throw "Failed to create container directory"
    }
    try FileManager.default.createDirectory(at: containerDir, withIntermediateDirectories: true)
    return containerDir
}

private func createSocketPath(containerDir: URL) -> URL {
    return containerDir.appendingPathComponent("sb.sock")
}

private func removeFile(path: URL) {
    do {
        try FileManager.default.removeItem(at: path)
    } catch {}
}

private func createAddr(path: URL) throws -> sockaddr_un {
    let path = path.path
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathLength = path.withCString { Int(strlen($0)) }
    guard MemoryLayout.size(ofValue: addr.sun_path) > pathLength else {
        throw "sample-buffer: unix socket path \(path) too long"
    }
    _ = withUnsafeMutablePointer(to: &addr.sun_path.0) { addrPtr in
        path.withCString {
            strncpy(addrPtr, $0, pathLength)
        }
    }
    return addr
}

private func socket() throws -> Int32 {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    if fd == -1 {
        throw "Failed to create unix socket"
    }
    return fd
}

private func setIgnoreSigPipe(fd: Int32) throws {
    var on: Int32 = 1
    if setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == -1 {
        throw "Failed to set ignore sigpipe"
    }
}

private func connect(fd: Int32, addr: sockaddr_un) throws {
    var addr = addr
    let res = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(fd, $0, UInt32(MemoryLayout<sockaddr_un>.stride))
        }
    }
    if res == -1 {
        throw "Failed to connect"
    }
}

private func bind(fd: Int32, addr: sockaddr_un) throws {
    var addr = addr
    let res = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(fd, $0, UInt32(MemoryLayout<sockaddr_un>.stride))
        }
    }
    if res == -1 {
        throw "Failed to bind"
    }
}

private func listen(fd: Int32) throws {
    if Darwin.listen(fd, 5) == -1 {
        throw "Failed to listen"
    }
}

private func accept(fd: Int32) throws -> Int32 {
    let senderFd = Darwin.accept(fd, nil, nil)
    if senderFd == -1 {
        throw "Failed to accept"
    }
    return senderFd
}

// periphery:ignore
class SampleBufferSender {
    private var fd: Int32

    init() {
        fd = -1
    }

    func start(appGroup: String) {
        do {
            fd = try socket()
            try setIgnoreSigPipe(fd: fd)
            let containerDir = try createContainerDir(appGroup: appGroup)
            let path = createSocketPath(containerDir: containerDir)
            let addr = try createAddr(path: path)
            try connect(fd: fd, addr: addr)
        } catch {}
    }

    func stop() {
        Darwin.close(fd)
    }

    func send(_ sampleBuffer: CMSampleBuffer, _ type: RPSampleBufferType) {
        guard let formatDescription = sampleBuffer.formatDescription,
              let imageBuffer = sampleBuffer.imageBuffer
        else {
            return
        }
        let bufferSize = CVPixelBufferGetDataSize(imageBuffer)
        let header = Header(bufferType: type.rawValue,
                            bufferSize: bufferSize,
                            width: formatDescription.dimensions.width,
                            height: formatDescription.dimensions.height)
        let encoder = PropertyListEncoder()
        guard let data = try? encoder.encode(header) else {
            return
        }
        send(data: Data([
            UInt8(data.count >> 24),
            UInt8(data.count >> 16),
            UInt8(data.count >> 8),
            UInt8(data.count),
        ]))
        send(data: data)
        // CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)
        // defer {
        //     CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly)
        // }
        // let pointer = CVPixelBufferGetBaseAddress(imageBuffer)
        // Darwin.write(fd, pointer, bufferSize)
    }

    private func send(data: Data) {
        _ = data.withUnsafeBytes { (pointer: UnsafeRawBufferPointer) in
            Darwin.write(fd, pointer.baseAddress, pointer.count)
        }
    }
}

protocol SampleBufferReceiverDelegate: AnyObject {
    func senderConnected()
    func senderDisconnected()
    func handleSampleBuffer(sampleBuffer: CMSampleBuffer?)
}

// periphery:ignore
class SampleBufferReceiver {
    private var listenerFd: Int32
    weak var delegate: (any SampleBufferReceiverDelegate)?

    init() {
        listenerFd = -1
    }

    func start(appGroup: String) {
        do {
            listenerFd = try socket()
            try setIgnoreSigPipe(fd: listenerFd)
            let containerDir = try createContainerDir(appGroup: appGroup)
            let path = createSocketPath(containerDir: containerDir)
            removeFile(path: path)
            let addr = try createAddr(path: path)
            try bind(fd: listenerFd, addr: addr)
            try listen(fd: listenerFd)
        } catch {
            return
        }
        DispatchQueue.global(qos: .userInteractive).async {
            try? self.acceptLoop()
        }
    }

    func stop() {}

    private func acceptLoop() throws {
        while true {
            let senderFd = try accept(fd: listenerFd)
            try setIgnoreSigPipe(fd: senderFd)
            delegate?.senderConnected()
            readLoop(senderFd: senderFd)
            delegate?.senderDisconnected()
        }
    }

    private func readLoop(senderFd: Int32) {
        while true {
            guard let data = read(senderFd: senderFd, count: 4) else {
                break
            }
            let headerSize = (Int(data[0]) << 24) | (Int(data[1]) << 16) | (Int(data[2]) << 8) | Int(data[3])
            guard let data = read(senderFd: senderFd, count: headerSize) else {
                break
            }
            let decoder = PropertyListDecoder()
            guard let header = try? decoder.decode(Header.self, from: data) else {
                break
            }
            // print("sample", header)
            // print("buffer", read(senderFd: senderFd, count: header.bufferSize))
            delegate?.handleSampleBuffer(sampleBuffer: nil)
        }
    }

    private func read(senderFd: Int32, count: Int) -> Data? {
        var data = Data(count: count)
        let readCount = data.withUnsafeMutableBytes { (pointer: UnsafeMutableRawBufferPointer) in
            Darwin.read(senderFd, pointer.baseAddress, pointer.count)
        }
        if readCount != data.count {
            return nil
        }
        return data
    }
}
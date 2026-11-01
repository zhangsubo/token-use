import Foundation
import Darwin

/// 零编译期外部依赖的 Zstandard (`.zst`) 解压工具：
/// 1. 优先通过 `dlopen` 动态加载本机 `libzstd.dylib` 在进程内流式解压（亚毫秒级、零子进程开销）；
/// 2. 若本机未安装动态库，则回退尝试系统 `zstd -dc` 命令行；
/// 3. 若均不可用则安全返回 `nil`，不影响 `.app` 在纯净机器上的启动与运行。
enum ZstdDecompressor {
    private final class DynamicLibZstd: @unchecked Sendable {
        typealias CreateDCtxFn = @convention(c) () -> OpaquePointer?
        typealias FreeDCtxFn = @convention(c) (OpaquePointer?) -> Int
        /// C 签名: `size_t ZSTD_decompressStream(ZSTD_DCtx* zds, ZSTD_outBuffer* output, ZSTD_inBuffer* input)`
        /// 其中 `ZSTD_inBuffer` / `ZSTD_outBuffer` 在 64 位平台上均为连续 3 个机器字 `[ptr, size, pos]`。
        typealias DecompressStreamFn = @convention(c) (
            OpaquePointer?,
            UnsafeMutablePointer<UInt>,
            UnsafeMutablePointer<UInt>
        ) -> Int
        typealias IsErrorFn = @convention(c) (Int) -> UInt32

        let createDCtx: CreateDCtxFn
        let freeDCtx: FreeDCtxFn
        let decompressStream: DecompressStreamFn
        let isError: IsErrorFn

        init?() {
            let candidates = [
                "/opt/homebrew/lib/libzstd.dylib",
                "/usr/local/lib/libzstd.dylib",
                "/opt/anaconda3/lib/libzstd.dylib",
                "libzstd.1.dylib",
                "libzstd.dylib",
            ]
            var loadedHandle: UnsafeMutableRawPointer?
            for path in candidates {
                if let h = dlopen(path, RTLD_LAZY | RTLD_LOCAL) {
                    loadedHandle = h
                    break
                }
            }
            guard let handle = loadedHandle,
                  let pCreate = dlsym(handle, "ZSTD_createDCtx"),
                  let pFree = dlsym(handle, "ZSTD_freeDCtx"),
                  let pDecomp = dlsym(handle, "ZSTD_decompressStream"),
                  let pIsErr = dlsym(handle, "ZSTD_isError") else {
                return nil
            }
            self.createDCtx = unsafeBitCast(pCreate, to: CreateDCtxFn.self)
            self.freeDCtx = unsafeBitCast(pFree, to: FreeDCtxFn.self)
            self.decompressStream = unsafeBitCast(pDecomp, to: DecompressStreamFn.self)
            self.isError = unsafeBitCast(pIsErr, to: IsErrorFn.self)
        }

        func decompress(_ compressed: Data) -> Data? {
            guard !compressed.isEmpty, let dctx = createDCtx() else { return nil }
            defer { _ = freeDCtx(dctx) }

            let chunkSize = 131_072
            var output = Data()
            output.reserveCapacity(min(compressed.count * 4, 8 * 1024 * 1024))
            let outChunk = UnsafeMutableRawPointer.allocate(byteCount: chunkSize, alignment: 8)
            defer { outChunk.deallocate() }

            let inWords = UnsafeMutablePointer<UInt>.allocate(capacity: 3)
            let outWords = UnsafeMutablePointer<UInt>.allocate(capacity: 3)
            defer {
                inWords.deallocate()
                outWords.deallocate()
            }

            let ok = compressed.withUnsafeBytes { rawIn -> Bool in
                guard let baseAddress = rawIn.baseAddress else { return false }
                inWords[0] = UInt(bitPattern: baseAddress)
                inWords[1] = UInt(rawIn.count)
                inWords[2] = 0

                var lastOutFull = false
                while inWords[2] < inWords[1] || lastOutFull {
                    outWords[0] = UInt(bitPattern: outChunk)
                    outWords[1] = UInt(chunkSize)
                    outWords[2] = 0

                    let ret = decompressStream(dctx, outWords, inWords)
                    if isError(ret) != 0 {
                        return false
                    }
                    let produced = Int(outWords[2])
                    if produced > 0 {
                        output.append(outChunk.assumingMemoryBound(to: UInt8.self), count: produced)
                    }
                    lastOutFull = (produced == chunkSize)
                    if ret == 0 && !lastOutFull && inWords[2] >= inWords[1] {
                        break
                    }
                }
                return true
            }
            return ok ? output : nil
        }
    }

    private static let dynamicLib = DynamicLibZstd()

    private static let cliExecutablePath: String? = {
        let candidates = [
            "/opt/homebrew/bin/zstd",
            "/usr/local/bin/zstd",
            "/opt/anaconda3/bin/zstd",
            "/usr/bin/zstd",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    static func decompressData(at fileURL: URL) -> Data? {
        if let lib = dynamicLib,
           let compressed = try? Data(contentsOf: fileURL, options: .mappedIfSafe),
           let decompressed = lib.decompress(compressed) {
            return decompressed
        }

        guard let cli = cliExecutablePath else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: cli)
        proc.arguments = ["-dc", "--quiet", fileURL.path]
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0, !data.isEmpty else { return nil }
            return data
        } catch {
            return nil
        }
    }

    static func decompressUTF8(at fileURL: URL) -> String? {
        guard let data = decompressData(at: fileURL) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }
}

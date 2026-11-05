// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Appends 48 kHz mono Float32 audio to a CAF file that stays readable after a crash.
///
/// The data chunk's size is `-1`, which `CAFFile.h` documents as "the rest of the file", so
/// no header needs updating. `AudioFile` doesn't offer this safety: it defers size updates.
public final class CAFTrackWriter {
    public enum WriterError: Error, Equatable {
        case open(errno: Int32)
        case write(errno: Int32)
    }

    /// `caff` header (8), `desc` chunk (12 + 32), `data` chunk header (12) and its edit count (4).
    public static let headerSize = 68

    public private(set) var framesWritten = 0
    private var descriptor: Int32

    public init(url: URL) throws {
        descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard descriptor >= 0 else {
            throw WriterError.open(errno: errno)
        }
        do {
            try writeAll(Self.header())
        } catch {
            Darwin.close(descriptor)
            descriptor = -1
            throw error
        }
    }

    deinit {
        close()
    }

    public func append(_ samples: UnsafeBufferPointer<Float>) throws {
        guard let base = samples.baseAddress, !samples.isEmpty else {
            return
        }
        try writeAll(UnsafeRawBufferPointer(start: base, count: samples.count * MemoryLayout<Float>.size))
        framesWritten += samples.count
    }

    public func appendSilence(frames: Int) throws {
        guard frames > 0 else {
            return
        }
        let zeros = [Float](repeating: 0, count: min(frames, 48000))
        var remaining = frames
        while remaining > 0 {
            let count = min(remaining, zeros.count)
            try zeros.withUnsafeBufferPointer {
                try append(UnsafeBufferPointer(rebasing: $0[0 ..< count]))
            }
            remaining -= count
        }
    }

    /// Forces data to the disk itself, not just the drive's cache.
    public func sync() {
        guard descriptor >= 0 else {
            return
        }
        _ = fcntl(descriptor, F_FULLFSYNC)
    }

    public func close() {
        guard descriptor >= 0 else {
            return
        }
        sync()
        Darwin.close(descriptor)
        descriptor = -1
    }

    /// Whole frames in a file written by this class, including one cut short by a crash.
    public static func frameCount(ofFileAt url: URL) throws -> Int {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        return max(0, size - headerSize) / MemoryLayout<Float>.size
    }

    private func writeAll(_ bytes: [UInt8]) throws {
        try bytes.withUnsafeBytes { try writeAll($0) }
    }

    private func writeAll(_ buffer: UnsafeRawBufferPointer) throws {
        var offset = 0
        while offset < buffer.count {
            let written = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
            if written < 0 {
                if errno == EINTR {
                    continue
                }
                throw WriterError.write(errno: errno)
            }
            offset += written
        }
    }

    static func header() -> [UInt8] {
        var bytes: [UInt8] = []
        func fourCC(_ code: String) {
            bytes += Array(code.utf8)
        }
        func bigEndian(_ value: some FixedWidthInteger) {
            withUnsafeBytes(of: value.bigEndian) { bytes += Array($0) }
        }

        fourCC("caff")
        bigEndian(UInt16(1)) // version
        bigEndian(UInt16(0)) // flags

        fourCC("desc")
        bigEndian(Int64(32))
        bigEndian(Double(TrackTimeline.sampleRate).bitPattern)
        fourCC("lpcm")
        bigEndian(UInt32(3)) // kCAFLinearPCMFormatFlagIsFloat | IsLittleEndian
        bigEndian(UInt32(4)) // bytes per packet
        bigEndian(UInt32(1)) // frames per packet
        bigEndian(UInt32(1)) // channels
        bigEndian(UInt32(32)) // bits

        fourCC("data")
        bigEndian(Int64(-1)) // unknown size: everything to the end of the file
        bigEndian(UInt32(0)) // edit count
        return bytes
    }
}

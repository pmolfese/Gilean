//
//  MGHFileReader.swift
//  Gilean
//
//  Created by Codex on 8/25/25.
//

import Foundation

struct MGHImage {
    struct ScanParameters {
        let repetitionTime: Float
        let flipAngle: Float
        let echoTime: Float
        let inversionTime: Float
        let fieldOfView: Float
    }

    let dimensions: [Int]
    let nFrames: Int
    let typeCode: Int32
    let typeName: String
    let degreesOfFreedom: Int32
    let goodRASFlag: Bool
    let spacing: [Float]
    let xDirectionCosines: [Float]
    let yDirectionCosines: [Float]
    let zDirectionCosines: [Float]
    let center: [Float]
    let rawData: Data
    let scanParameters: ScanParameters?
}

final class MGHFileReader {
    private enum Constants {
        static let headerLength = 284
        static let supportedVersion = 1
    }

    enum ReaderError: LocalizedError {
        case fileNotFound(URL)
        case unreadablePath(URL)
        case openFailed(URL)
        case unsupportedVersion(Int32)
        case invalidDimensions([Int32])
        case unsupportedType(Int32)
        case shortRead

        var errorDescription: String? {
            switch self {
            case let .fileNotFound(url):
                return "No file exists at \(url.path)."
            case let .unreadablePath(url):
                return "The path \(url.path) could not be encoded for the MGH reader."
            case let .openFailed(url):
                return "The MGH file at \(url.lastPathComponent) could not be opened."
            case let .unsupportedVersion(version):
                return "Unsupported MGH version \(version)."
            case let .invalidDimensions(dimensions):
                return "Invalid MGH dimensions: \(dimensions.map(String.init).joined(separator: ", "))."
            case let .unsupportedType(type):
                return "Unsupported MGH voxel type \(type)."
            case .shortRead:
                return "The MGH file ended earlier than expected."
            }
        }
    }

    func readImage(at url: URL) throws -> MGHImage {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ReaderError.fileNotFound(url)
        }

        guard let cPath = url.path.cString(using: .utf8) else {
            throw ReaderError.unreadablePath(url)
        }

        let useCompression = Self.usesCompression(for: url)
        var file = znzopen(cPath, "rb", useCompression ? 1 : 0)
        guard file != nil else {
            throw ReaderError.openFailed(url)
        }

        defer {
            _ = Xznzclose(&file)
        }

        let version = try readInt32(from: file)
        guard version == Constants.supportedVersion else {
            throw ReaderError.unsupportedVersion(version)
        }

        let width = try readInt32(from: file)
        let height = try readInt32(from: file)
        let depth = try readInt32(from: file)
        let nFrames = try readInt32(from: file)
        let type = try readInt32(from: file)
        let degreesOfFreedom = try readInt32(from: file)
        let goodRASFlag = try readInt16(from: file) != 0

        let dimensions = [width, height, depth]
        guard dimensions.allSatisfy({ $0 > 0 }), nFrames > 0 else {
            throw ReaderError.invalidDimensions(dimensions + [nFrames])
        }

        let spacing: [Float]
        let xDirectionCosines: [Float]
        let yDirectionCosines: [Float]
        let zDirectionCosines: [Float]
        let center: [Float]

        if goodRASFlag {
            spacing = try readFloatArray(count: 3, from: file)
            xDirectionCosines = try readFloatArray(count: 3, from: file)
            yDirectionCosines = try readFloatArray(count: 3, from: file)
            zDirectionCosines = try readFloatArray(count: 3, from: file)
            center = try readFloatArray(count: 3, from: file)
        } else {
            spacing = [1, 1, 1]
            xDirectionCosines = [-1, 0, 0]
            yDirectionCosines = [0, 0, -1]
            zDirectionCosines = [0, 1, 0]
            center = [0, 0, 0]
        }

        _ = znzseek(file, off_t(Constants.headerLength), SEEK_SET)

        let bytesPerVoxel = try bytesPerVoxel(for: type)
        let voxelCount = Int(width) * Int(height) * Int(depth) * Int(nFrames)
        let byteCount = voxelCount * bytesPerVoxel
        let rawData = try readData(count: byteCount, from: file)

        let scanParameters = try readScanParametersIfPresent(from: file)

        return MGHImage(
            dimensions: dimensions.map(Int.init),
            nFrames: Int(nFrames),
            typeCode: type,
            typeName: Self.typeName(for: type),
            degreesOfFreedom: degreesOfFreedom,
            goodRASFlag: goodRASFlag,
            spacing: spacing,
            xDirectionCosines: xDirectionCosines,
            yDirectionCosines: yDirectionCosines,
            zDirectionCosines: zDirectionCosines,
            center: center,
            rawData: rawData,
            scanParameters: scanParameters
        )
    }

    private func readScanParametersIfPresent(from file: znzFile?) throws -> MGHImage.ScanParameters? {
        let currentOffset = znztell(file)
        guard currentOffset >= 0 else {
            return nil
        }

        let endOffset = znzseek(file, 0, SEEK_END)
        guard endOffset >= 0 else {
            return nil
        }

        _ = znzseek(file, currentOffset, SEEK_SET)

        let trailingBytes = Int(endOffset - currentOffset)
        guard trailingBytes >= 20 else {
            return nil
        }

        return MGHImage.ScanParameters(
            repetitionTime: try readFloat(from: file),
            flipAngle: try readFloat(from: file),
            echoTime: try readFloat(from: file),
            inversionTime: try readFloat(from: file),
            fieldOfView: try readFloat(from: file)
        )
    }

    private func readData(count: Int, from file: znzFile?) throws -> Data {
        var data = Data(count: count)
        let bytesRead = data.withUnsafeMutableBytes { buffer in
            znzread(buffer.baseAddress, 1, count, file)
        }

        guard bytesRead == count else {
            throw ReaderError.shortRead
        }

        return data
    }

    private func readFloatArray(count: Int, from file: znzFile?) throws -> [Float] {
        try (0..<count).map { _ in
            try readFloat(from: file)
        }
    }

    private func readInt16(from file: znzFile?) throws -> Int16 {
        var value: UInt16 = 0
        let readCount = withUnsafeMutableBytes(of: &value) { buffer in
            znzread(buffer.baseAddress, 1, MemoryLayout<UInt16>.size, file)
        }

        guard readCount == MemoryLayout<UInt16>.size else {
            throw ReaderError.shortRead
        }

        return Int16(bitPattern: UInt16(bigEndian: value))
    }

    private func readInt32(from file: znzFile?) throws -> Int32 {
        var value: UInt32 = 0
        let readCount = withUnsafeMutableBytes(of: &value) { buffer in
            znzread(buffer.baseAddress, 1, MemoryLayout<UInt32>.size, file)
        }

        guard readCount == MemoryLayout<UInt32>.size else {
            throw ReaderError.shortRead
        }

        return Int32(bitPattern: UInt32(bigEndian: value))
    }

    private func readFloat(from file: znzFile?) throws -> Float {
        let raw = try readInt32(from: file)
        return Float(bitPattern: UInt32(bitPattern: raw))
    }

    private func bytesPerVoxel(for type: Int32) throws -> Int {
        switch type {
        case 0:
            return MemoryLayout<UInt8>.size
        case 1, 3:
            return MemoryLayout<Int32>.size
        case 4:
            return MemoryLayout<Int16>.size
        default:
            throw ReaderError.unsupportedType(type)
        }
    }

    static func isSupportedFile(_ url: URL) -> Bool {
        let lowercasePath = url.path.lowercased()
        return lowercasePath.hasSuffix(".mgh") || lowercasePath.hasSuffix(".mgz") || lowercasePath.hasSuffix(".mgh.gz")
    }

    private static func usesCompression(for url: URL) -> Bool {
        let lowercasePath = url.path.lowercased()
        return lowercasePath.hasSuffix(".mgz") || lowercasePath.hasSuffix(".mgh.gz")
    }

    private static func typeName(for type: Int32) -> String {
        switch type {
        case 0:
            return "UCHAR"
        case 1:
            return "INT"
        case 3:
            return "FLOAT"
        case 4:
            return "SHORT"
        default:
            return "Unknown"
        }
    }
}

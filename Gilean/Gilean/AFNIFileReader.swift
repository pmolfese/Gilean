//
//  AFNIFileReader.swift
//  Gilean
//
//  Created by Codex on 8/25/25.
//  In process of simplification by P. Molfese 26/30/26
//

import Foundation

struct AFNIImage {
    enum AttributeValue {
        case string(String)
        case integers([Int])
        case floats([Float])

        var stringValue: String? {
            guard case let .string(value) = self else {
                return nil
            }

            return value
        }

        var integerValues: [Int]? {
            guard case let .integers(values) = self else {
                return nil
            }

            return values
        }

        var floatValues: [Float]? {
            guard case let .floats(values) = self else {
                return nil
            }

            return values
        }
    }

    let dimensions: [Int]
    let brickCount: Int
    let voxelSizes: [Float]
    let timeStep: Float?
    let brickTypeCode: Int32
    let brickTypeName: String
    let byteOrder: String
    let brickFloatFactors: [Float]
    let volumeLabels: [String]
    let templateSpace: String?
    let affineRows: [[Float]]
    let rawData: Data
    let attributes: [String: AttributeValue]
}

final class AFNIFileReader {
    enum ReaderError: LocalizedError {
        case fileNotFound(URL)
        case unreadableText(URL)
        case missingPair(URL)
        case openFailed(URL)
        case invalidHeader(String)
        case mixedBrickTypes([Int])
        case unsupportedBrickType(Int)
        case shortRead

        var errorDescription: String? {
            switch self {
            case let .fileNotFound(url):
                return "No file exists at \(url.path)."
            case let .unreadableText(url):
                return "The AFNI header at \(url.lastPathComponent) could not be read as text."
            case let .missingPair(url):
                return "Could not find the matching AFNI header/image pair for \(url.lastPathComponent)."
            case let .openFailed(url):
                return "The AFNI brick file at \(url.lastPathComponent) could not be opened."
            case let .invalidHeader(message):
                return "Invalid AFNI header: \(message)"
            case let .mixedBrickTypes(types):
                return "AFNI datasets with mixed BRICK_TYPES are not supported: \(types.map(String.init).joined(separator: ", "))."
            case let .unsupportedBrickType(type):
                return "Unsupported AFNI BRICK_TYPES value \(type)."
            case .shortRead:
                return "The AFNI brick file ended earlier than expected."
            }
        }
    }

    func readImage(at url: URL) throws -> AFNIImage {
        let pair = try resolvePair(from: url)
        let attributes = try parseHeader(at: pair.headerURL)

        let datasetRank = try requiredIntegers(named: "DATASET_RANK", in: attributes, minimumCount: 2)
        let datasetDimensions = try requiredIntegers(named: "DATASET_DIMENSIONS", in: attributes, minimumCount: datasetRank[0])
        let brickTypes = try requiredIntegers(named: "BRICK_TYPES", in: attributes, minimumCount: 1)

        let uniqueBrickTypes = Array(Set(brickTypes)).sorted()
        guard uniqueBrickTypes.count == 1, let brickType = uniqueBrickTypes.first else {
            throw ReaderError.mixedBrickTypes(brickTypes)
        }

        let dimensions = Array(datasetDimensions.prefix(datasetRank[0]))
        let brickCount = datasetRank[1]
        let voxelSizes = try requiredFloats(named: "DELTA", in: attributes, minimumCount: 3).prefix(3).map { abs($0) }
        let timeStep = attributes["TAXIS_FLOATS"]?.floatValues.flatMap { $0.count > 1 ? $0[1] : nil }
        let byteOrder = attributes["BYTEORDER_STRING"]?.stringValue ?? nativeByteOrderString
        let brickFloatFactors = attributes["BRICK_FLOAT_FACS"]?.floatValues ?? []
        let volumeLabels = Self.parseVolumeLabels(attributes["BRICK_LABS"]?.stringValue, brickCount: brickCount)
        let templateSpace = attributes["TEMPLATE_SPACE"]?.stringValue
        let affineRows = Self.parseAffine(attributes["IJK_TO_DICOM_REAL"]?.floatValues)

        let bytesPerVoxel = try Self.bytesPerVoxel(for: brickType)
        let voxelCount = dimensions.reduce(1, *) * brickCount
        let rawData = try readBrickData(
            at: pair.imageURL,
            byteCount: voxelCount * bytesPerVoxel,
            usesCompression: Self.usesCompression(for: pair.imageURL)
        )

        return AFNIImage(
            dimensions: dimensions,
            brickCount: brickCount,
            voxelSizes: voxelSizes,
            timeStep: timeStep,
            brickTypeCode: Int32(brickType),
            brickTypeName: Self.brickTypeName(for: brickType),
            byteOrder: byteOrder,
            brickFloatFactors: brickFloatFactors,
            volumeLabels: volumeLabels,
            templateSpace: templateSpace,
            affineRows: affineRows,
            rawData: rawData,
            attributes: attributes
        )
    }

    static func isSupportedFile(_ url: URL) -> Bool {
        let lowercasePath = url.path.lowercased()
        return lowercasePath.hasSuffix(".head") || lowercasePath.hasSuffix(".brik") || lowercasePath.hasSuffix(".brik.gz")
    }

    private func resolvePair(from url: URL) throws -> (headerURL: URL, imageURL: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ReaderError.fileNotFound(url)
        }

        let lowercasePath = url.path.lowercased()

        if lowercasePath.hasSuffix(".head") {
            let stem = String(url.path.dropLast(5))
            let imageCandidates = [
                URL(fileURLWithPath: stem + ".BRIK"),
                URL(fileURLWithPath: stem + ".brik"),
                URL(fileURLWithPath: stem + ".BRIK.gz"),
                URL(fileURLWithPath: stem + ".brik.gz")
            ]

            guard let imageURL = imageCandidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
                throw ReaderError.missingPair(url)
            }

            return (url, imageURL)
        }

        if lowercasePath.hasSuffix(".brik.gz") {
            let stem = String(url.path.dropLast(8))
            let headerCandidates = [
                URL(fileURLWithPath: stem + ".HEAD"),
                URL(fileURLWithPath: stem + ".head")
            ]

            guard let headerURL = headerCandidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
                throw ReaderError.missingPair(url)
            }

            return (headerURL, url)
        }

        if lowercasePath.hasSuffix(".brik") {
            let stem = String(url.path.dropLast(5))
            let headerCandidates = [
                URL(fileURLWithPath: stem + ".HEAD"),
                URL(fileURLWithPath: stem + ".head")
            ]

            guard let headerURL = headerCandidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
                throw ReaderError.missingPair(url)
            }

            return (headerURL, url)
        }

        throw ReaderError.missingPair(url)
    }

    private func parseHeader(at url: URL) throws -> [String: AFNIImage.AttributeValue] {
        let contents: String
        do {
            contents = try String(contentsOf: url, encoding: .utf8)
        } catch {
            do {
                contents = try String(contentsOf: url, encoding: .ascii)
            } catch {
                throw ReaderError.unreadableText(url)
            }
        }

        let normalized = contents.replacingOccurrences(of: "\r\n", with: "\n")
        let blocks = normalized
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var attributes: [String: AFNIImage.AttributeValue] = [:]

        for block in blocks {
            let parsed = try parseAttributeBlock(block)
            attributes[parsed.name] = parsed.value
        }

        return attributes
    }

    private func parseAttributeBlock(_ block: String) throws -> (name: String, value: AFNIImage.AttributeValue) {
        let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= 4 else {
            throw ReaderError.invalidHeader("Malformed attribute block:\n\(block)")
        }

        guard let type = lines[0].split(separator: "=").last?.trimmingCharacters(in: .whitespaces),
              let name = lines[1].split(separator: "=").last?.trimmingCharacters(in: .whitespaces) else {
            throw ReaderError.invalidHeader("Could not parse attribute header:\n\(block)")
        }

        let valueText = lines.dropFirst(3).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        switch type {
        case "string-attribute":
            var text = valueText
            if text.hasPrefix("'") {
                text.removeFirst()
            }
            while text.hasSuffix("~") {
                text.removeLast()
            }
            return (name, .string(text))

        case "integer-attribute":
            let values = valueText.split(whereSeparator: { $0.isWhitespace }).compactMap { Int(String($0)) }
            return (name, .integers(values))

        case "float-attribute":
            let values = valueText.split(whereSeparator: { $0.isWhitespace }).compactMap { Float(String($0)) }
            return (name, .floats(values))

        default:
            throw ReaderError.invalidHeader("Unsupported attribute type \(type).")
        }
    }

    private func readBrickData(at url: URL, byteCount: Int, usesCompression: Bool) throws -> Data {
        guard let cPath = url.path.cString(using: .utf8) else {
            throw ReaderError.openFailed(url)
        }

        var file = znzopen(cPath, "rb", usesCompression ? 1 : 0)
        guard file != nil else {
            throw ReaderError.openFailed(url)
        }

        defer {
            _ = Xznzclose(&file)
        }

        var data = Data(count: byteCount)
        let bytesRead = data.withUnsafeMutableBytes { buffer in
            znzread(buffer.baseAddress, 1, byteCount, file)
        }

        guard bytesRead == byteCount else {
            throw ReaderError.shortRead
        }

        return data
    }

    private func requiredIntegers(
        named name: String,
        in attributes: [String: AFNIImage.AttributeValue],
        minimumCount: Int
    ) throws -> [Int] {
        guard let values = attributes[name]?.integerValues, values.count >= minimumCount else {
            throw ReaderError.invalidHeader("Missing or invalid \(name).")
        }

        return values
    }

    private func requiredFloats(
        named name: String,
        in attributes: [String: AFNIImage.AttributeValue],
        minimumCount: Int
    ) throws -> [Float] {
        guard let values = attributes[name]?.floatValues, values.count >= minimumCount else {
            throw ReaderError.invalidHeader("Missing or invalid \(name).")
        }

        return values
    }

    private static func parseVolumeLabels(_ labelString: String?, brickCount: Int) -> [String] {
        guard let labelString, !labelString.isEmpty else {
            return (0..<brickCount).map { "#\($0)" }
        }

        let labels = labelString.split(separator: "~").map(String.init).filter { !$0.isEmpty }
        return labels.isEmpty ? (0..<brickCount).map { "#\($0)" } : labels
    }

    private static func parseAffine(_ values: [Float]?) -> [[Float]] {
        guard let values, values.count >= 12 else {
            return []
        }

        return stride(from: 0, to: 12, by: 4).map { index in
            Array(values[index..<(index + 4)])
        }
    }

    private static func usesCompression(for url: URL) -> Bool {
        url.path.lowercased().hasSuffix(".gz")
    }

    private static func bytesPerVoxel(for brickType: Int) throws -> Int {
        switch brickType {
        case 0:
            return MemoryLayout<UInt8>.size
        case 1:
            return MemoryLayout<Int16>.size
        case 3:
            return MemoryLayout<Float>.size
        case 5:
            return MemoryLayout<Float>.size * 2
        default:
            throw ReaderError.unsupportedBrickType(brickType)
        }
    }

    private static func brickTypeName(for brickType: Int) -> String {
        switch brickType {
        case 0:
            return "UInt8"
        case 1:
            return "Int16"
        case 3:
            return "Float32"
        case 5:
            return "Complex64"
        default:
            return "Unknown"
        }
    }

    private var nativeByteOrderString: String {
        CFByteOrderGetCurrent() == CFByteOrderLittleEndian.rawValue ? "LSB_FIRST" : "MSB_FIRST"
    }
}

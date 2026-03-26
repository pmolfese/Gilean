//
//  NIfTIReader.swift
//  Gilean
//
//  Created by Codex on 8/25/25.
//  Edited by P. Molfese 26/03/26
//

import Foundation

struct NIfTIImage {
    let dimensions: [Int]
    let voxelSizes: [Float]
    let voxelCount: Int
    let bytesPerVoxel: Int
    let datatypeCode: Int32
    let datatypeName: String
    let description: String
    let rawData: Data
    let scaleSlope: Float
    let scaleIntercept: Float
    let qFormCode: Int32
    let sFormCode: Int32
}

final class NIfTIReader {
    enum ReaderError: LocalizedError {
        case fileNotFound(URL)
        case unreadablePath(URL)
        case imageReadFailed(URL)
        case missingVoxelData(URL)
        case unsupportedDatatype(Int32)

        var errorDescription: String? {
            switch self {
            case let .fileNotFound(url):
                return "No file exists at \(url.path)."
            case let .unreadablePath(url):
                return "The path \(url.path) could not be encoded for the NIfTI C API."
            case let .imageReadFailed(url):
                return "The NIfTI image at \(url.lastPathComponent) could not be read."
            case let .missingVoxelData(url):
                return "The NIfTI image at \(url.lastPathComponent) did not contain voxel data."
            case let .unsupportedDatatype(code):
                return "Datatype \(code) is not supported for float conversion."
            }
        }
    }

    func readImage(at url: URL) throws -> NIfTIImage {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ReaderError.fileNotFound(url)
        }

        guard let cPath = url.path.cString(using: .utf8) else {
            throw ReaderError.unreadablePath(url)
        }

        guard let imagePointer = nifti_image_read(cPath, 1) else {
            throw ReaderError.imageReadFailed(url)
        }

        defer {
            nifti_image_free(imagePointer)
        }

        let image = imagePointer.pointee

        guard let dataPointer = image.data else {
            throw ReaderError.missingVoxelData(url)
        }

        let voxelCount = Int(image.nvox)
        let bytesPerVoxel = Int(image.nbyper)
        let byteCount = voxelCount * bytesPerVoxel

        let rawData = Data(bytes: dataPointer, count: byteCount)

        return NIfTIImage(
            dimensions: Self.makeDimensions(from: image.dim),
            voxelSizes: Self.makeVoxelSizes(from: image.pixdim),
            voxelCount: voxelCount,
            bytesPerVoxel: bytesPerVoxel,
            datatypeCode: image.datatype,
            datatypeName: Self.datatypeName(for: image.datatype),
            description: Self.string(from: image.descrip),
            rawData: rawData,
            scaleSlope: image.scl_slope,
            scaleIntercept: image.scl_inter,
            qFormCode: image.qform_code,
            sFormCode: image.sform_code
        )
    }

    func floatValues(from image: NIfTIImage) throws -> [Float] {
        let slope = image.scaleSlope == 0 ? 1 as Float : image.scaleSlope
        let intercept = image.scaleIntercept
        switch image.datatypeCode {
        case Int32(DT_UINT8):
            return convert(image, as: UInt8.self, slope: slope, intercept: intercept)
        case Int32(DT_INT8):
            return convert(image, as: Int8.self, slope: slope, intercept: intercept)
        case Int32(DT_INT16):
            return convert(image, as: Int16.self, slope: slope, intercept: intercept)
        case Int32(DT_UINT16):
            return convert(image, as: UInt16.self, slope: slope, intercept: intercept)
        case Int32(DT_INT32):
            return convert(image, as: Int32.self, slope: slope, intercept: intercept)
        case Int32(DT_UINT32):
            return convert(image, as: UInt32.self, slope: slope, intercept: intercept)
        case Int32(DT_INT64):
            return convert(image, as: Int64.self, slope: slope, intercept: intercept)
        case Int32(DT_UINT64):
            return convert(image, as: UInt64.self, slope: slope, intercept: intercept)
        case Int32(DT_FLOAT32):
            return convert(image, as: Float.self, slope: slope, intercept: intercept)
        case Int32(DT_FLOAT64):
            return convert(image, as: Double.self, slope: slope, intercept: intercept)
        default:
            throw ReaderError.unsupportedDatatype(image.datatypeCode)
        }
    }

    private func convert<T: FixedWidthInteger>(
        _ image: NIfTIImage,
        as type: T.Type,
        slope: Float,
        intercept: Float
    ) -> [Float] {
        image.rawData.withUnsafeBytes { rawBuffer in
            let values = rawBuffer.bindMemory(to: T.self)
            return values.map { (Float($0) * slope) + intercept }
        }
    }

    private func convert(
        _ image: NIfTIImage,
        as type: Float.Type,
        slope: Float,
        intercept: Float
    ) -> [Float] {
        image.rawData.withUnsafeBytes { rawBuffer in
            let values = rawBuffer.bindMemory(to: Float.self)
            return values.map { ($0 * slope) + intercept }
        }
    }

    private func convert(
        _ image: NIfTIImage,
        as type: Double.Type,
        slope: Float,
        intercept: Float
    ) -> [Float] {
        image.rawData.withUnsafeBytes { rawBuffer in
            let values = rawBuffer.bindMemory(to: Double.self)
            return values.map { (Float($0) * slope) + intercept }
        }
    }

    private static func makeDimensions(from dim: (Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32)) -> [Int] {
        let values = [dim.0, dim.1, dim.2, dim.3, dim.4, dim.5, dim.6, dim.7].map(Int.init)
        let count = max(values[0], 0)
        guard count > 0 else {
            return []
        }

        return Array(values[1...min(count, 7)])
    }

    private static func makeVoxelSizes(from pixdim: (Float, Float, Float, Float, Float, Float, Float, Float)) -> [Float] {
        Array([pixdim.1, pixdim.2, pixdim.3, pixdim.4, pixdim.5, pixdim.6, pixdim.7])
    }

    private static func datatypeName(for code: Int32) -> String {
        guard let cString = nifti_datatype_string(code) else {
            return "Unknown"
        }

        return String(cString: cString)
    }

    private static func string(from tuple: (Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8)) -> String {
        let values = [
            tuple.0, tuple.1, tuple.2, tuple.3, tuple.4, tuple.5, tuple.6, tuple.7, tuple.8, tuple.9,
            tuple.10, tuple.11, tuple.12, tuple.13, tuple.14, tuple.15, tuple.16, tuple.17, tuple.18, tuple.19,
            tuple.20, tuple.21, tuple.22, tuple.23, tuple.24, tuple.25, tuple.26, tuple.27, tuple.28, tuple.29,
            tuple.30, tuple.31, tuple.32, tuple.33, tuple.34, tuple.35, tuple.36, tuple.37, tuple.38, tuple.39,
            tuple.40, tuple.41, tuple.42, tuple.43, tuple.44, tuple.45, tuple.46, tuple.47, tuple.48, tuple.49,
            tuple.50, tuple.51, tuple.52, tuple.53, tuple.54, tuple.55, tuple.56, tuple.57, tuple.58, tuple.59,
            tuple.60, tuple.61, tuple.62, tuple.63, tuple.64, tuple.65, tuple.66, tuple.67, tuple.68, tuple.69,
            tuple.70, tuple.71, tuple.72, tuple.73, tuple.74, tuple.75, tuple.76, tuple.77, tuple.78, tuple.79
        ]

        let bytes = values.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(bytes: bytes, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

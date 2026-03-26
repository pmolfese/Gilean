//
//  ContentView.swift
//  Gilean
//
//  Created by Molfese, Peter  [E] on 3/26/26.
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    private enum LoadedVolume {
        case nifti(NIfTIImage)
        case mgh(MGHImage)
    }

    @State private var selectedURL: URL?
    @State private var loadedVolume: LoadedVolume?
    @State private var errorMessage: String?
    @State private var isImporterPresented = false
    @State private var isDropTargeted = false
    @State private var isLoading = false

    private let niftiReader = NIfTIReader()
    private let mghReader = MGHFileReader()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            dropZone
            content
        }
        .padding(24)
        .frame(minWidth: 700, minHeight: 520, alignment: .topLeading)
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false,
            onCompletion: handleImport(result:)
        )
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("NIfTI Header Inspector")
                    .font(.title.bold())
                Text("Choose a NIfTI or MGH volume, or drop one onto the window.")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Choose File") {
                isImporterPresented = true
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    private var dropZone: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 28, weight: .medium))
            Text("Drop a `.nii`, `.hdr`, `.img`, `.mgh`, or `.mgz` file here")
                .font(.headline)
            Text("The selected file is read with the native readers and the header details appear below.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .background(dropZoneBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
        )
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted, perform: handleDrop(providers:))
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            HStack(spacing: 12) {
                ProgressView()
                Text("Reading NIfTI file...")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } else if let volume = loadedVolume {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let selectedURL {
                        infoSection("File") {
                            infoRow("Name", selectedURL.lastPathComponent)
                            infoRow("Path", selectedURL.path)
                            infoRow("Format", formatName(for: volume))
                        }
                    }

                    switch volume {
                    case let .nifti(image):
                        infoSection("Image") {
                            infoRow("Dimensions", image.dimensions.map(String.init).joined(separator: " x "))
                            infoRow("Voxel Sizes", formattedVoxelSizes(image.voxelSizes, count: image.dimensions.count))
                            infoRow("Voxel Count", "\(image.voxelCount)")
                            infoRow("Bytes / Voxel", "\(image.bytesPerVoxel)")
                            infoRow("Stored Bytes", "\(image.rawData.count)")
                        }

                        infoSection("Datatype") {
                            infoRow("Type", image.datatypeName)
                            infoRow("Code", "\(image.datatypeCode)")
                            infoRow("Scale Slope", formattedFloat(image.scaleSlope))
                            infoRow("Scale Intercept", formattedFloat(image.scaleIntercept))
                        }

                        infoSection("Transforms") {
                            infoRow("qform_code", "\(image.qFormCode)")
                            infoRow("sform_code", "\(image.sFormCode)")
                        }

                        if !image.description.isEmpty {
                            infoSection("Description") {
                                Text(image.description)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                        }

                    case let .mgh(image):
                        infoSection("Image") {
                            infoRow("Dimensions", image.dimensions.map(String.init).joined(separator: " x "))
                            infoRow("Frames", "\(image.nFrames)")
                            infoRow("Voxel Sizes", image.spacing.map(formattedFloat).joined(separator: ", "))
                            infoRow("Stored Bytes", "\(image.rawData.count)")
                        }

                        infoSection("Datatype") {
                            infoRow("Type", image.typeName)
                            infoRow("Code", "\(image.typeCode)")
                            infoRow("Degrees of Freedom", "\(image.degreesOfFreedom)")
                            infoRow("goodRASFlag", image.goodRASFlag ? "true" : "false")
                        }

                        infoSection("Orientation") {
                            infoRow("X Direction", formattedVector(image.xDirectionCosines))
                            infoRow("Y Direction", formattedVector(image.yDirectionCosines))
                            infoRow("Z Direction", formattedVector(image.zDirectionCosines))
                            infoRow("Center", formattedVector(image.center))
                        }

                        if let parameters = image.scanParameters {
                            infoSection("Scan Parameters") {
                                infoRow("TR (ms)", formattedFloat(parameters.repetitionTime))
                                infoRow("Flip Angle (rad)", formattedFloat(parameters.flipAngle))
                                infoRow("TE (ms)", formattedFloat(parameters.echoTime))
                                infoRow("TI (ms)", formattedFloat(parameters.inversionTime))
                                infoRow("FoV", formattedFloat(parameters.fieldOfView))
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if let errorMessage {
            ContentUnavailableView(
                "Unable to Read File",
                systemImage: "exclamationmark.triangle",
                description: Text(errorMessage)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(
                "No File Loaded",
                systemImage: "doc.text.magnifyingglass",
                description: Text("Use the file picker or drag a NIfTI file into the drop area to inspect its header.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var dropZoneBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(isDropTargeted ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08))
    }

    private func infoSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            VStack(alignment: .leading, spacing: 8, content: content)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value.isEmpty ? "Unavailable" : value)
                .textSelection(.enabled)
        }
    }

    private func handleImport(result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            guard let url = urls.first else {
                return
            }

            loadImage(from: url)
        case let .failure(error):
            isLoading = false
            loadedVolume = nil
            errorMessage = error.localizedDescription
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            return false
        }

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
            if let error {
                DispatchQueue.main.async {
                    isLoading = false
                    loadedVolume = nil
                    errorMessage = error.localizedDescription
                }
                return
            }

            guard let url = droppedFileURL(from: item) else {
                DispatchQueue.main.async {
                    isLoading = false
                    loadedVolume = nil
                    errorMessage = "The dropped item was not a valid file URL."
                }
                return
            }

            DispatchQueue.main.async {
                loadImage(from: url)
            }
        }

        return true
    }

    private func droppedFileURL(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL {
            return url
        }

        if let data = item as? Data {
            return URL(dataRepresentation: data, relativeTo: nil)
        }

        if let string = item as? String {
            return URL(string: string)
        }

        return nil
    }

    private func loadImage(from url: URL) {
        isLoading = true
        errorMessage = nil

        DispatchQueue.global(qos: .userInitiated).async {
            let hasSecurityScope = url.startAccessingSecurityScopedResource()
            defer {
                if hasSecurityScope {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let volume = try loadVolume(at: url)
                DispatchQueue.main.async {
                    selectedURL = url
                    loadedVolume = volume
                    errorMessage = nil
                    isLoading = false
                }
            } catch {
                DispatchQueue.main.async {
                    selectedURL = url
                    loadedVolume = nil
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }

    private func loadVolume(at url: URL) throws -> LoadedVolume {
        if MGHFileReader.isSupportedFile(url) {
            return .mgh(try mghReader.readImage(at: url))
        }

        return .nifti(try niftiReader.readImage(at: url))
    }

    private func formatName(for volume: LoadedVolume) -> String {
        switch volume {
        case .nifti:
            return "NIfTI"
        case .mgh:
            return "MGH/MGZ"
        }
    }

    private func formattedVoxelSizes(_ values: [Float], count: Int) -> String {
        let activeValues = values.prefix(max(count, 0))
        return activeValues.map(formattedFloat).joined(separator: ", ")
    }

    private func formattedVector(_ values: [Float]) -> String {
        values.map(formattedFloat).joined(separator: ", ")
    }

    private func formattedFloat(_ value: Float) -> String {
        if value.rounded() == value {
            return String(format: "%.0f", value)
        }

        return String(format: "%.4f", value)
    }
}

#Preview {
    ContentView()
}

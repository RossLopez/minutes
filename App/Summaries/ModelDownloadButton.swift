// SPDX-License-Identifier: GPL-3.0-or-later

import MinutesLLM
import SwiftUI

/// Downloads a model after confirming its exact size, the free space and whether this Mac has the
/// memory for it. Nothing goes to the network until it's clicked.
struct ModelDownloadButton: View {
    let model: CatalogModel
    var title = "Download"

    @State private var offer: RemoteModelFile?
    @State private var problem: String?
    @State private var isChecking = false

    private var center: SummaryCenter {
        .shared
    }

    var body: some View {
        Button(title) {
            check()
        }
        .disabled(isChecking)
        .accessibilityLabel(title == "Download" ? "Download \(model.name)" : title)
        .alert("Download \(model.name)?", isPresented: isOffering) {
            Button("Download") {
                if let offer {
                    center.download(model, remote: offer)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(offerMessage)
        }
        .alert("Minutes Can't Download \(model.name)", isPresented: hasProblem) {
            Button("OK") {}
        } message: {
            Text(problem ?? "")
        }
    }

    private var isOffering: Binding<Bool> {
        Binding(get: { offer != nil }, set: {
            if !$0 {
                offer = nil
            }
        })
    }

    private var hasProblem: Binding<Bool> {
        Binding(get: { problem != nil }, set: {
            if !$0 {
                problem = nil
            }
        })
    }

    private var offerMessage: String {
        guard let offer else {
            return ""
        }
        var parts = ["\(SummaryCenter.bytes(offer.size)) from Hugging Face."]
        if let free = ModelDownloader.volumeAvailableSpace(LibraryStore.shared.library.modelsFolder) {
            parts.append("\(SummaryCenter.bytes(free)) is free on this disk.")
        }
        if !model.fitsMemory() {
            let memory = Int64(ProcessInfo.processInfo.physicalMemory).formatted(.byteCount(style: .memory))
            parts.append("""
            This Mac has \(memory) of memory, and \(model.name) works best with \(model.recommendedMemoryGB) GB \
            or more, so summaries may be slow or fail to start.
            """)
        }
        return parts.joined(separator: " ")
    }

    private func check() {
        isChecking = true
        Task {
            do {
                offer = try await center.prepareDownload(of: model)
            } catch {
                problem = SummaryCenter.describe(error)
            }
            isChecking = false
        }
    }
}

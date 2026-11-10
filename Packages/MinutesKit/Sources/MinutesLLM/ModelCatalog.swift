// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A model Minutes can download. Only the repository and file are fixed here: the exact size,
/// checksum and commit are asked for when a download starts.
public struct CatalogModel: Identifiable, Equatable, Sendable {
    /// Stable, used in settings and `meeting.json`, like `gemma-4-12b`.
    public let id: String
    public let name: String
    /// The Hugging Face repository, like `google/gemma-4-12B-it-qat-q4_0-gguf`.
    public let repository: String
    public let file: String
    /// For showing before anything has been asked of the network.
    public let approximateBytes: Int64
    /// The Mac's memory below which the model is likely to be slow or fail to load.
    public let recommendedMemoryGB: Int
    /// Listed under Advanced, for Macs with a lot of memory.
    public let isAdvanced: Bool

    public init(
        id: String,
        name: String,
        repository: String,
        file: String,
        approximateBytes: Int64,
        recommendedMemoryGB: Int,
        isAdvanced: Bool = false,
    ) {
        self.id = id
        self.name = name
        self.repository = repository
        self.file = file
        self.approximateBytes = approximateBytes
        self.recommendedMemoryGB = recommendedMemoryGB
        self.isAdvanced = isAdvanced
    }

    /// The folder it's installed in, under `Models/`: the repository's own name.
    public var folderName: String {
        repository.split(separator: "/").last.map(String.init) ?? id
    }

    public func fitsMemory(_ bytes: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Bool {
        bytes >= UInt64(recommendedMemoryGB) << 30
    }
}

public enum ModelCatalog {
    public static let gemma12B = CatalogModel(
        id: "gemma-4-12b",
        name: "Gemma 4 12B",
        repository: "google/gemma-4-12B-it-qat-q4_0-gguf",
        file: "gemma-4-12b-it-qat-q4_0.gguf",
        approximateBytes: 6_975_879_296,
        recommendedMemoryGB: 16,
    )

    public static let gemmaE4B = CatalogModel(
        id: "gemma-4-e4b",
        name: "Gemma 4 E4B",
        repository: "google/gemma-4-E4B-it-qat-q4_0-gguf",
        file: "gemma-4-E4B_q4_0-it.gguf",
        approximateBytes: 5_154_941_280,
        recommendedMemoryGB: 8,
    )

    public static let all: [CatalogModel] = [
        gemma12B,
        gemmaE4B,
        CatalogModel(
            id: "gemma-4-e2b",
            name: "Gemma 4 E2B",
            repository: "google/gemma-4-E2B-it-qat-q4_0-gguf",
            file: "gemma-4-E2B_q4_0-it.gguf",
            approximateBytes: 3_349_516_256,
            recommendedMemoryGB: 8,
        ),
        CatalogModel(
            id: "gemma-4-26b-a4b",
            name: "Gemma 4 26B A4B",
            repository: "google/gemma-4-26B-A4B-it-qat-q4_0-gguf",
            file: "gemma-4-26B_q4_0-it.gguf",
            approximateBytes: 14_400_000_000,
            recommendedMemoryGB: 32,
            isAdvanced: true,
        ),
        CatalogModel(
            id: "gemma-4-31b",
            name: "Gemma 4 31B",
            repository: "google/gemma-4-31B-it-qat-q4_0-gguf",
            file: "gemma-4-31B_q4_0-it.gguf",
            approximateBytes: 17_700_000_000,
            recommendedMemoryGB: 32,
            isAdvanced: true,
        ),
    ]

    /// The model offered first: the 12B where there's memory for it, and E4B otherwise.
    public static func recommended(forMemory bytes: UInt64 = ProcessInfo.processInfo.physicalMemory) -> CatalogModel {
        gemma12B.fitsMemory(bytes) ? gemma12B : gemmaE4B
    }

    public static func model(id: String) -> CatalogModel? {
        all.first { $0.id == id }
    }
}

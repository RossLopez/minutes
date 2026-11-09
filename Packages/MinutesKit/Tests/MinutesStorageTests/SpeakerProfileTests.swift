// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import MinutesStorage
import Testing

private func makeStore() throws -> SpeakerProfileStore {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("MinutesTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return MinutesLibrary(root: root).speakerProfiles
}

private func sample(day: Int, meeting: UUID = UUID(), value: Float = 1) -> VoiceSample {
    VoiceSample(
        meeting: meeting,
        recordedAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(day) * 86400),
        seconds: 30,
        embedding: [value, 0, -value],
    )
}

private func fileNames(_ store: SpeakerProfileStore) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: store.folder.path).sorted()
}

@Test func `nothing is written until a voice is saved`() throws {
    let store = try makeStore()
    #expect(store.profiles().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: store.folder.path))
}

@Test func `saving a voice makes a readable file named after the person`() throws {
    let store = try makeStore()
    let profile = try store.addSample(sample(day: 0), toProfileNamed: "Dana Lee")
    #expect(try fileNames(store) == ["Dana Lee.json"])
    let text = try String(contentsOf: store.folder.appendingPathComponent("Dana Lee.json"), encoding: .utf8)
    #expect(text.contains("\"name\" : \"Dana Lee\""))
    // Dates in the file are whole seconds, so compare what matters.
    #expect(store.profiles().map(\.id) == [profile.id])
    #expect(store.profiles().first?.samples == profile.samples)
}

@Test func `the same name in any case adds to one profile`() throws {
    let store = try makeStore()
    try store.addSample(sample(day: 0), toProfileNamed: "Dana")
    try store.addSample(sample(day: 1), toProfileNamed: "dana")
    #expect(store.profiles().count == 1)
    #expect(store.profiles().first?.name == "Dana")
    #expect(store.profiles().first?.samples.count == 2)
}

@Test func `a meeting's second sample replaces its first`() throws {
    let store = try makeStore()
    let meeting = UUID()
    try store.addSample(sample(day: 0, meeting: meeting, value: 1), toProfileNamed: "Dana")
    try store.addSample(sample(day: 0, meeting: meeting, value: 2), toProfileNamed: "Dana")
    #expect(store.profiles().first?.samples.map(\.embedding) == [[2, 0, -2]])
}

@Test func `only the newest ten meetings are kept`() throws {
    let store = try makeStore()
    for day in (0 ..< 12).reversed() {
        try store.addSample(sample(day: day), toProfileNamed: "Dana")
    }
    let samples = try #require(store.profiles().first?.samples)
    #expect(samples.count == SpeakerProfile.maximumSamples)
    #expect(samples.first?.recordedAt == sample(day: 2).recordedAt)
    #expect(store.profiles().first?.lastHeard == sample(day: 11).recordedAt)
}

@Test func `removing a profile's last sample deletes it`() throws {
    let store = try makeStore()
    let first = UUID()
    let second = UUID()
    try store.addSample(sample(day: 0, meeting: first), toProfileNamed: "Dana")
    let profile = try store.addSample(sample(day: 1, meeting: second), toProfileNamed: "Dana")
    try store.removeSample(fromMeeting: first, profile: profile.id)
    #expect(store.profiles().first?.samples.map(\.meeting) == [second])
    try store.removeSample(fromMeeting: second, profile: profile.id)
    #expect(store.profiles().isEmpty)
    #expect(try fileNames(store).isEmpty)
}

@Test func `a file renamed by hand is still found by its ID`() throws {
    let store = try makeStore()
    let profile = try store.addSample(sample(day: 0), toProfileNamed: "Dana")
    try FileManager.default.moveItem(
        at: store.folder.appendingPathComponent("Dana.json"),
        to: store.folder.appendingPathComponent("Someone.json"),
    )
    #expect(store.profile(withID: profile.id)?.name == "Dana")
    try store.addSample(sample(day: 1), toProfileNamed: "Dana")
    #expect(try fileNames(store) == ["Someone.json"])
}

@Test func `a broken file is skipped and never overwritten`() throws {
    let store = try makeStore()
    try FileManager.default.createDirectory(at: store.folder, withIntermediateDirectories: true)
    let broken = store.folder.appendingPathComponent("Dana.json")
    try Data("{ not json".utf8).write(to: broken)
    try store.addSample(sample(day: 0), toProfileNamed: "Dana")
    #expect(try fileNames(store) == ["Dana 2.json", "Dana.json"])
    #expect(try String(contentsOf: broken, encoding: .utf8) == "{ not json")
    try store.deleteAll()
    #expect(try fileNames(store) == ["Dana.json"])
}

@Test func `a profile from a newer version is read but not changed`() throws {
    let store = try makeStore()
    var profile = try store.addSample(sample(day: 0), toProfileNamed: "Dana")
    profile.schemaVersion = SpeakerProfile.currentSchemaVersion + 1
    let url = store.folder.appendingPathComponent("Dana.json")
    try MeetingMetadata.encoder.encode(profile).write(to: url)
    let before = try Data(contentsOf: url)
    #expect(store.profiles().count == 1)
    #expect(throws: SpeakerProfileStore.StoreError.newerFileFormat) {
        try store.addSample(sample(day: 1), toProfileNamed: "Dana")
    }
    #expect(try Data(contentsOf: url) == before)
}

@Test func `deleting one profile leaves the others`() throws {
    let store = try makeStore()
    let dana = try store.addSample(sample(day: 0), toProfileNamed: "Dana")
    try store.addSample(sample(day: 0), toProfileNamed: "Sam")
    try store.delete(dana.id)
    #expect(store.profiles().map(\.name) == ["Sam"])
}

@Test func `a name with slashes still makes a safe file name`() throws {
    let store = try makeStore()
    try store.addSample(sample(day: 0), toProfileNamed: "A/B: Team")
    #expect(try fileNames(store) == ["A B Team.json"])
    #expect(store.profiles().first?.name == "A/B: Team")
}

@Test func `an empty name is refused`() throws {
    let store = try makeStore()
    #expect(throws: SpeakerProfileStore.StoreError.emptyName) {
        try store.addSample(sample(day: 0), toProfileNamed: "  ")
    }
}

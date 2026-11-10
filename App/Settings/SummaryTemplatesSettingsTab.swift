// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import MinutesStorage
import SwiftUI

/// Summary templates are Markdown files in `~/Minutes/Templates`, edited here or in any editor.
struct SummaryTemplatesSettingsTab: View {
    @Bindable private var center = SummaryCenter.shared
    @State private var templates: [SummaryTemplate] = []
    @State private var selection: String?
    @State private var draft = ""
    @State private var loadedName: String?
    @State private var renaming: String?
    @State private var newName = ""
    @State private var isConfirmingDelete = false
    @State private var problem: String?

    private var store: SummaryTemplateStore {
        center.templateStore
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(templates, selection: $selection) { template in
                    HStack {
                        Text(template.name)
                        if template.name == center.defaultTemplate {
                            Spacer()
                            Image(systemName: "checkmark")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .help("Used for new meetings")
                                .accessibilityLabel("Used for new meetings")
                        }
                    }
                    .tag(template.name)
                }
                .accessibilityIdentifier("templateList")
                Divider()
                listButtons
            }
            .frame(width: 210)
            Divider()
            editor
        }
        .task {
            reload(selecting: selection ?? center.defaultTemplate)
        }
        .onChange(of: selection) { _, name in
            load(name)
        }
        .onChange(of: draft) { _, text in
            save(text)
        }
        .alert("Rename Template", isPresented: isRenaming) {
            TextField("Name", text: $newName)
            Button("Rename") {
                rename()
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Move “\(selection ?? "")” to the Trash?", isPresented: $isConfirmingDelete) {
            Button("Move to Trash", role: .destructive) {
                delete()
            }
        } message: {
            Text("Summaries already written with it stay.")
        }
        .alert("Summary Templates", isPresented: hasProblem) {
            Button("OK") {}
        } message: {
            Text(problem ?? "")
        }
    }

    private var listButtons: some View {
        HStack(spacing: 2) {
            Button("New Template", systemImage: "plus") {
                add(named: "New Template", prompt: "")
            }
            .accessibilityIdentifier("templateNew")
            Button("Duplicate", systemImage: "plus.square.on.square") {
                if let selection {
                    add(named: selection, prompt: draft)
                }
            }
            .disabled(selection == nil)
            Button("Delete", systemImage: "minus") {
                isConfirmingDelete = true
            }
            .disabled(selection == nil || selection == SummaryTemplateStore.defaultName)
            Spacer()
            Menu("More", systemImage: "ellipsis.circle") {
                Button("Rename…") {
                    newName = selection ?? ""
                    renaming = selection
                }
                .disabled(selection == nil || selection == SummaryTemplateStore.defaultName)
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([store.folder])
                }
            }
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(6)
    }

    @ViewBuilder
    private var editor: some View {
        if let selection {
            VStack(alignment: .leading, spacing: 10) {
                Text("What the model is asked to write. The transcript, with times and names, follows it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                TextEditor(text: $draft)
                    .font(.body.monospaced())
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(.background, in: .rect(cornerRadius: 6))
                    .accessibilityLabel("Instructions for \(selection)")
                    .accessibilityIdentifier("templateEditor")
                HStack {
                    if selection == center.defaultTemplate {
                        Label("Used for new meetings", systemImage: "checkmark")
                            .foregroundStyle(.secondary)
                    } else {
                        Button("Use for New Meetings") {
                            center.defaultTemplate = selection
                        }
                        .accessibilityIdentifier("templateUseForNew")
                    }
                    Spacer()
                    if selection == SummaryTemplateStore.defaultName {
                        Button("Restore Default") {
                            restoreDefault()
                        }
                        .disabled(draft == store.defaultPrompt)
                        .accessibilityIdentifier("templateRestoreDefault")
                    }
                }
            }
            .padding(16)
        } else {
            ContentUnavailableView("No Template Selected", systemImage: "doc.text")
        }
    }

    private var isRenaming: Binding<Bool> {
        Binding(get: { renaming != nil }, set: {
            if !$0 {
                renaming = nil
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

    // MARK: - Files

    private func reload(selecting name: String?) {
        templates = store.templates()
        let name = templates.contains { $0.name == name } ? name : templates.first?.name
        loadedName = nil
        selection = name
        load(name)
        center.templatesChanged()
    }

    private func load(_ name: String?) {
        guard let name, name != loadedName else {
            return
        }
        // Set first, so the change of text it causes isn't saved back.
        loadedName = name
        draft = templates.first { $0.name == name }?.prompt ?? ""
    }

    private func save(_ text: String) {
        guard let name = loadedName, templates.first(where: { $0.name == name })?.prompt != text else {
            return
        }
        do {
            try store.save(SummaryTemplate(name: name, prompt: text))
            if let index = templates.firstIndex(where: { $0.name == name }) {
                templates[index].prompt = text
            }
        } catch {
            problem = "Minutes couldn't save this template. Check that the Templates folder can be written to."
        }
    }

    private func add(named name: String, prompt: String) {
        do {
            let added = try store.add(named: name, prompt: prompt)
            reload(selecting: added)
        } catch {
            problem = "Minutes couldn't add a template. Check that the Templates folder can be written to."
        }
    }

    private func rename() {
        guard let old = renaming else {
            return
        }
        do {
            let renamed = try store.rename(old, to: newName)
            if center.defaultTemplate == old {
                center.defaultTemplate = renamed
            }
            reload(selecting: renamed)
        } catch SummaryTemplateStore.StoreError.emptyName {
            problem = "A template needs a name."
        } catch SummaryTemplateStore.StoreError.nameTaken {
            problem = "There's already a template called “\(newName)”."
        } catch {
            problem = "Minutes couldn't rename this template."
        }
    }

    private func delete() {
        guard let name = selection else {
            return
        }
        do {
            try store.delete(name)
            if center.defaultTemplate == name {
                center.defaultTemplate = SummaryTemplateStore.defaultName
            }
            reload(selecting: SummaryTemplateStore.defaultName)
        } catch {
            problem = "Minutes couldn't move this template to the Trash."
        }
    }

    private func restoreDefault() {
        do {
            try store.restoreDefault()
            reload(selecting: SummaryTemplateStore.defaultName)
        } catch {
            problem = "Minutes couldn't restore the default template."
        }
    }
}

//
//  DomainDetailView.swift
//  Steward — Track E
//
//  Designer §3.4. Edit name + role_prompt; archive (no delete). Updates flow
//  through the existing Pod C `domain.update_prompt` / `domain.archive` tools
//  so audit-log entries and InverseActions stay consistent with everything
//  else the agent might do.
//

import SwiftUI

struct DomainDetailView: View {
    let domain: DomainRecord
    var onSaved: () async -> Void

    @State private var displayName: String
    @State private var rolePrompt: String
    @State private var archiveConfirmShown: Bool = false
    @State private var saveError: String?
    @Environment(\.dismiss) private var dismiss

    init(domain: DomainRecord, onSaved: @escaping () async -> Void) {
        self.domain = domain
        self.onSaved = onSaved
        _displayName = State(initialValue: domain.displayName)
        _rolePrompt = State(initialValue: domain.rolePrompt)
    }

    var body: some View {
        Form {
            Section("NAME") {
                TextField("Team name", text: $displayName)
                    .textInputAutocapitalization(.words)
            }
            Section {
                TextEditor(text: $rolePrompt)
                    .frame(minHeight: 180)
                    .font(.body)
                Text("This is the team's working brief. Edit it like you'd brief a new collaborator.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("ROLE PROMPT")
            }
            Section("ACTIONS") {
                Button("Archive this team", role: .destructive) {
                    archiveConfirmShown = true
                }
                .accessibilityIdentifier("settings.domain.archive")
            }
            if let saveError {
                Section {
                    Text(saveError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(domain.displayName)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") {
                    Task { await save() }
                }
            }
        }
        .confirmationDialog(
            "Archive \(domain.displayName) team? Its instruments stop updating. You can still see history.",
            isPresented: $archiveConfirmShown,
            titleVisibility: .visible
        ) {
            Button("Archive", role: .destructive) {
                Task { await archive() }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func save() async {
        if displayName != domain.displayName {
            do {
                try await DomainStore.shared.rename(domain: domain.domain, to: displayName)
            } catch {
                saveError = "Couldn't rename: \(error)"
                return
            }
        }
        if rolePrompt != domain.rolePrompt {
            let result = await invokeDomainTool(
                tool: DomainUpdatePromptTool(),
                argsJSON: """
                {
                  "domain": "\(escape(domain.domain))",
                  "new_prompt": "\(escape(rolePrompt))",
                  "reasoning": "User edited role prompt from Settings.",
                  "actor": "user"
                }
                """
            )
            if let error = result.error {
                saveError = "Couldn't update role: \(error)"
                return
            }
        }
        await onSaved()
        dismiss()
    }

    private func archive() async {
        let result = await invokeDomainTool(
            tool: DomainArchiveTool(),
            argsJSON: """
            {
              "domain": "\(escape(domain.domain))",
              "reasoning": "User archived team from Settings.",
              "actor": "user"
            }
            """
        )
        if let error = result.error {
            saveError = "Couldn't archive: \(error)"
            return
        }
        await onSaved()
        dismiss()
    }

    private struct ToolResult {
        let error: String?
    }

    private func invokeDomainTool(tool: any LLMTool, argsJSON: String) async -> ToolResult {
        do {
            _ = try await tool.invoke(argsJSON: argsJSON)
            return ToolResult(error: nil)
        } catch {
            return ToolResult(error: String(describing: error))
        }
    }

    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
         .replacingOccurrences(of: "\n", with: "\\n")
    }
}

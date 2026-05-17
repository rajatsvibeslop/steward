//
//  SettingsViewModel.swift
//  Steward
//
//  Backing store for the Settings tab. Loads the typed `Settings` blob and
//  the active domains. Mutations route back through `SettingsStore.shared`
//  so concurrent edits serialize per addendum §1.11.
//

import Foundation
import SwiftUI

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published private(set) var settings: Settings?
    @Published private(set) var domains: [DomainRecord] = []
    @Published private(set) var backendKind: LLMBackendKind?
    @Published private(set) var loadError: String?

    private let store: SettingsStore
    private let domainStore: DomainStore

    init(store: SettingsStore = .shared, domainStore: DomainStore = .shared) {
        self.store = store
        self.domainStore = domainStore
    }

    func load() async {
        do {
            self.settings = try await store.load()
            self.domains = try await domainStore.listActive()
            self.backendKind = await AgentLoopHost.shared.currentBackendKind()
            self.loadError = nil
        } catch {
            self.loadError = String(describing: error)
        }
    }

    func update(_ mutate: @escaping @Sendable (inout Settings) -> Void) async {
        do {
            self.settings = try await store.update(mutate)
        } catch {
            self.loadError = String(describing: error)
        }
    }

    /// User-driven UI mutation. Routes through `SettingsStore.update(audit:_:)`
    /// so a `settings_change` audit event is appended in the same db.write{}
    /// as the settings row update (v1.1 patch: Settings UI mutations
    /// audit-logged). If the mutation is a no-op on the audited field,
    /// `SettingsStore` skips the event write — no duplicate rows.
    func update(
        audit: SettingsAuditField,
        _ mutate: @escaping @Sendable (inout Settings) -> Void
    ) async {
        do {
            self.settings = try await store.update(audit: audit, mutate)
        } catch {
            self.loadError = String(describing: error)
        }
    }
}

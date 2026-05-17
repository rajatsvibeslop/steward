//
//  LifeTeamsSection.swift
//  Steward — Track E
//
//  Designer §3.4. List of active domain rows; tap to push DomainDetailView.
//  "+ Add a team via chat" row switches to the Chat tab (no auto-message).
//

import SwiftUI

struct LifeTeamsSection: View {
    let domains: [DomainRecord]
    var onOpenChat: () -> Void
    var onRefresh: () async -> Void

    var body: some View {
        Section("LIFE TEAMS") {
            ForEach(domains) { domain in
                NavigationLink {
                    DomainDetailView(domain: domain, onSaved: { await onRefresh() })
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "person.2.fill")
                            .foregroundStyle(DomainColor.for(domain: domain.domain))
                        Text(domain.displayName)
                        Spacer()
                    }
                }
            }
            Button(action: onOpenChat) {
                HStack {
                    Image(systemName: "plus.bubble")
                    Text("Add a team via chat")
                    Spacer()
                }
                .foregroundStyle(.primary)
            }
            .accessibilityIdentifier("settings.lifeteams.add_via_chat")
        }
    }
}

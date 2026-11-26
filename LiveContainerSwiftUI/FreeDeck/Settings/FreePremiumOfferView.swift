//
//  FreePremiumOfferView.swift
//  LiveContainerSwiftUI
//
//  FreeDeck: this screen used to sell a Premium subscription. FreeDeck is
//  free and open-source — there is no subscription, no checkout and no paid
//  certificate. The view is kept (and rebranded) because the app links to it
//  from Settings, the JIT section, the location spoofer and the app list;
//  it now simply states that everything is unlocked.
//

import SwiftUI

struct FreePremiumOfferView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 12) {
                        Image(systemName: "lock.open.fill")
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: "Everything is unlocked")
                                .font(.system(size: 22, weight: .bold))
                            Text(verbatim: "FreeDeck is free forever")
                                .font(.system(size: 15))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text(verbatim: "FreeDeck is a community fork that removed the subscription, the checkout and the paid certificate requirement. Every feature — built-in JIT, the location spoofer, the server library, web ports and multitasking — is available to everyone, with no account and no payment.")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 12) {
                        perk("checkmark.seal.fill", "No subscription", "Nothing to buy, nothing to renew.")
                        perk("person.crop.circle.badge.xmark", "No account", "FreeDeck works fully offline and self-hosted.")
                        perk("apple.logo", "Free signing", "Use a free Apple ID (7-day) or JIT-less mode — no paid certificates.")
                        perk("server.rack", "Your own server", "Apps, games and web ports live on your server, not your iPhone.")
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color(uiColor: .secondarySystemBackground))
                    )

                    Link(destination: URL(string: "https://github.com/DIGITTECH-5098/FreeDeck")!) {
                        Text(verbatim: "FreeDeck on GitHub")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(20)
            }
            .navigationTitle(verbatim: "FreeDeck Premium")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(verbatim: "Done") { dismiss() }
                }
            }
        }
    }

    private func perk(_ symbol: String, _ title: String, _ subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .font(.system(size: 15, weight: .semibold))
                Text(verbatim: subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

#Preview {
    FreePremiumOfferView()
}

//
//  FreeCertificateUnavailableView.swift
//  LiveContainerSwiftUI
//
//  The sheet General opens from "Why is this unavailable?": why a FreeDeck
//  that is not signed with a Development certificate cannot import one, what
//  still works, and the way to a FreeDeck that can.
//

import SwiftUI

struct FreeCertificateUnavailableView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("lc.free.certUnavailable.lead".loc)
                        .font(.system(size: 15, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("lc.free.certUnavailable.reason".loc)
                        .font(.system(size: 15))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(emphasizing: "lc.free.certUnavailable.options".loc)
                        .font(.system(size: 15))
                        .fixedSize(horizontal: false, vertical: true)
                    FreeSetUpWithFreeDeckStoreCard()
                        .padding(.top, 4)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .background(Color(UIColor.systemGroupedBackground).ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("lc.free.certUnavailable.title".loc)
                        .font(.headline)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("lc.common.close".loc)
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .apply { sheet in
            // The grabber the design draws. It is iOS 16 API, so the result is
            // erased: left in the static type, iOS 15 would trap resolving it
            // before the availability check ever ran.
            if #available(iOS 16.0, *) {
                AnyView(sheet.presentationDragIndicator(.visible))
            } else {
                AnyView(sheet)
            }
        }
    }
}

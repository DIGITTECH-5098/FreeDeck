//
//  FreeDeckStoreAPI.swift
//  LiveContainerSwiftUI
//
//  Where FreeDeck reaches its own server's API: the catalog and its app
//  pages, the device's record, the UDID profile, the pairing files.
//  Self-hosted — see server/ in this repository for the backend.
//

import Foundation

enum FreeDeckStoreAPI {
    /// FreeDeck is self-hosted: this is your own FreeDeck server (the FastAPI +
    /// Nginx service from server/ in this repository), reached over Tailscale.
    /// Set it in Settings, or via the "freedeck.server" UserDefaults key.
    static var base: String {
        let stored = UserDefaults.standard
            .string(forKey: "freedeck.server")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let stored, !stored.isEmpty {
            return stored
        }
        return "https://freedeck.tailnet.ts.net"
    }
}

//
//  FreeDeckSDKCompat.swift
//  LiveContainerSwiftUI
//
//  Compatibility shims for building FreeDeck with Xcode 26.x (iOS 26 SDK).
//  The upstream project targets the iOS 27 SDK, which adds the
//  `toolbarVerticalEdge` environment key (the SwiftUI twin of UIKit's
//  `UITraitCollection.verticalBarEdge`). Older SDKs do not declare it at all,
//  so `@Environment(\.toolbarVerticalEdge)` cannot compile there even behind
//  `#available`. This shim supplies the key as always-nil for those toolchains;
//  at runtime a build like that simply never sees a vertical toolbar bar.
//
//  Compiled out on Xcode 27+ toolchains, where the real key exists.
//

#if !compiler(>=6.4)
import SwiftUI

extension EnvironmentValues {
    /// Fallback for the iOS 27.1 `toolbarVerticalEdge` key: nil, meaning "no
    /// vertical toolbar bar", which is always true below that OS version.
    var toolbarVerticalEdge: HorizontalEdge? {
        get { nil }
        set { }
    }
}
#endif

# FreeDeck — Fork Audit & Modification Log

Complete record of every change made to upstream `flekstore/FlekDeck`
(v0.3.0, commit `afa5061`) to produce FreeDeck: paywall removal, rebrand,
and the new modules. Verified against the pristine upstream clone.

## Summary

| Category | Count |
|---|---|
| Files unchanged | 335 |
| Files modified for rebrand only | 133 |
| Files modified for paywall removal / CI (beyond renaming) | 16 |
| Files & directories renamed (rebrand) | 111 |
| Files deleted | 5 |
| New files added | 14 |

## 1. Paywall / gate removal (substantive edits)

Every subscription, ban/status-service, checkout and paid-certificate gate was
removed or neutralized. No account, network check or payment is required:

| File (new name) | Change |
|---|---|
| `LiveContainerSwiftUI/FreeDeckStore/Models/AccessVerification.swift` | `AccessVerificationService.fetchStatus` no longer contacts the remote status service; both variants return a synthetic unrestricted verdict (`.answered(.unrestricted)`). |
| `LiveContainerSwiftUI/FreeDeckStore/Models/DeviceStatusResponse.swift` | Added `DeviceStatusResponse.unrestricted` synthetic status factory for the gate stub. |
| `LiveContainerSwiftUI/FreeDeckStore/Models/FreePremium.swift` | `isActive` is now always `true`; `refresh()` is a no-network stub; `needsCheckAfterEnd`/`isEndUnseen` always `false`; `checkoutURL()` returns `nil`; the PayPal checkout URL was blanked. Upstream network logic is retained commented-out for reference. |
| `LiveContainerSwiftUI/Views/LCTabView.swift` | `refreshBlockedStatus` grants access unconditionally (no ban list, no status service); the upstream remote gate is retained commented-out and unreachable. |
| `LiveContainer/LCBootstrap.m` | Guest-side launch gate `isGuestLaunchAllowed` now always returns `YES`; the built-in-JIT Premium gate in `enableJITWithStikJIT` was deleted (JIT is free). |
| `LiveContainerSwiftUI/FreeDeck/Settings/FreePremiumOfferView.swift` | Paywall screen replaced with a static 'everything is unlocked' view (same call sites). |
| `LiveContainerSwiftUI/FreeDeckStore/Helpers/FreeDeckStoreAPI.swift` | API base is no longer `nestapi.flekstore.com`; it is now the self-hosted FreeDeck server, configurable via the `freedeck.server` user-default (default `https://freedeck.tailnet.ts.net`). |
| `LiveContainerSwiftUI/FreeDeck/Settings/FreeUDIDProfile.swift` | Device-lookup endpoint repointed from `flekstore.com` to the self-hosted server base. |
| `LiveContainerSwiftUI/FreeDeck/Settings/FreeCertificateImportView.swift` | The 'set up with FlekStore' upsell card now points at the FreeDeck build guide and states free Apple ID / JIT-less signing (no paid certificates). |
| `LiveContainerSwiftUI/FreeDeck/Install/FreeSourcesPopup.swift` | Default source placeholder no longer points at the paid store's repo. |

Also removed outright (paid/telemetry CI pipelines and funding links):

- `.github/apps_nightly.json`
- `.github/apps_ss_lc.json`
- `.github/build_github.sh`
- `.github/workflows/main.yml`
- `.github/workflows/build-external.yml`

## 2. Rebrand to FreeDeck

Mechanical, consistent rename across sources, Xcode project, string catalog,
assets and bundle identifiers:

- Identifiers & UI strings: `FlekDeck`→`FreeDeck`, `FlekStore`→`FreeDeckStore`, `FlekSt0re`→`FreeDeck`, `Flek*`→`Free*`, `flek*`→`free*`.
- Bundle identity: the app keeps upstream's identity — bundle ID `com.fs.flekdeck`, name `FlekDeck`, URL schemes `flekdeck`/`flekdeck2`/`flekdeck3` (extensions derive from the bundle ID).
- Product/display name: `FlekDeck.app`→`FreeDeck.app`.
- Asset names (`FlekIconFlekStore`, `FlekPremium`, `FlekJITShortcut`, wallpapers, app icon filenames) and their `Contents.json` references renamed in lockstep.
- Localizable.xcstrings keys and all ~30 language values renamed consistently.
- Preserved verbatim: URLs to external sites/repos, and external product names (FlekSign, FlekPair) so every reference stays consistent.
- `docs/` kept as historical upstream record, unmodified.

### Renamed files & directories

- `LiveContainerSwiftUI/FlekDeck` → `LiveContainerSwiftUI/FreeDeck`
- `LiveContainerSwiftUI/FlekDeck/Design` → `LiveContainerSwiftUI/FreeDeck/Design`
- `LiveContainerSwiftUI/FlekDeck/Design/FlekCornerRadii.swift` → `LiveContainerSwiftUI/FreeDeck/Design/FreeCornerRadii.swift`
- `LiveContainerSwiftUI/FlekDeck/Design/FlekDeckTheme.swift` → `LiveContainerSwiftUI/FreeDeck/Design/FreeDeckTheme.swift`
- `LiveContainerSwiftUI/FlekDeck/Design/FlekImageMemory.swift` → `LiveContainerSwiftUI/FreeDeck/Design/FreeImageMemory.swift`
- `LiveContainerSwiftUI/FlekDeck/Design/FlekImagePlaceholder.swift` → `LiveContainerSwiftUI/FreeDeck/Design/FreeImagePlaceholder.swift`
- `LiveContainerSwiftUI/FlekDeck/Design/FlekPageVisibility.swift` → `LiveContainerSwiftUI/FreeDeck/Design/FreePageVisibility.swift`
- `LiveContainerSwiftUI/FlekDeck/Home` → `LiveContainerSwiftUI/FreeDeck/Home`
- `LiveContainerSwiftUI/FlekDeck/Home/FlekAppCard.swift` → `LiveContainerSwiftUI/FreeDeck/Home/FreeAppCard.swift`
- `LiveContainerSwiftUI/FlekDeck/Home/FlekDeckModel.swift` → `LiveContainerSwiftUI/FreeDeck/Home/FreeDeckModel.swift`
- `LiveContainerSwiftUI/FlekDeck/Home/FlekGameWarningView.swift` → `LiveContainerSwiftUI/FreeDeck/Home/FreeGameWarningView.swift`
- `LiveContainerSwiftUI/FlekDeck/Home/FlekHomeListView.swift` → `LiveContainerSwiftUI/FreeDeck/Home/FreeHomeListView.swift`
- `LiveContainerSwiftUI/FlekDeck/Home/FlekInstallingCard.swift` → `LiveContainerSwiftUI/FreeDeck/Home/FreeInstallingCard.swift`
- `LiveContainerSwiftUI/FlekDeck/Home/FlekInternalPage.swift` → `LiveContainerSwiftUI/FreeDeck/Home/FreeInternalPage.swift`
- `LiveContainerSwiftUI/FlekDeck/Home/FlekSpringboardView.swift` → `LiveContainerSwiftUI/FreeDeck/Home/FreeSpringboardView.swift`
- `LiveContainerSwiftUI/FlekDeck/Home/FlekWallpaperView.swift` → `LiveContainerSwiftUI/FreeDeck/Home/FreeWallpaperView.swift`
- `LiveContainerSwiftUI/FlekDeck/Home/FlekWidgetSync.swift` → `LiveContainerSwiftUI/FreeDeck/Home/FreeWidgetSync.swift`
- `LiveContainerSwiftUI/FlekDeck/Home/StandaloneSettingsView.swift` → `LiveContainerSwiftUI/FreeDeck/Home/StandaloneSettingsView.swift`
- `LiveContainerSwiftUI/FlekDeck/Install` → `LiveContainerSwiftUI/FreeDeck/Install`
- `LiveContainerSwiftUI/FlekDeck/Install/FlekAppAdvancedSheet.swift` → `LiveContainerSwiftUI/FreeDeck/Install/FreeAppAdvancedSheet.swift`
- `LiveContainerSwiftUI/FlekDeck/Install/FlekAppDetailSheet.swift` → `LiveContainerSwiftUI/FreeDeck/Install/FreeAppDetailSheet.swift`
- `LiveContainerSwiftUI/FlekDeck/Install/FlekInstallOverrides.swift` → `LiveContainerSwiftUI/FreeDeck/Install/FreeInstallOverrides.swift`
- `LiveContainerSwiftUI/FlekDeck/Install/FlekInstallTray.swift` → `LiveContainerSwiftUI/FreeDeck/Install/FreeInstallTray.swift`
- `LiveContainerSwiftUI/FlekDeck/Install/FlekInstallerView.swift` → `LiveContainerSwiftUI/FreeDeck/Install/FreeInstallerView.swift`
- `LiveContainerSwiftUI/FlekDeck/Install/FlekScreenshotViewer.swift` → `LiveContainerSwiftUI/FreeDeck/Install/FreeScreenshotViewer.swift`
- `LiveContainerSwiftUI/FlekDeck/Install/FlekSourcesPopup.swift` → `LiveContainerSwiftUI/FreeDeck/Install/FreeSourcesPopup.swift`
- `LiveContainerSwiftUI/FlekDeck/Install/VariableBlurView.swift` → `LiveContainerSwiftUI/FreeDeck/Install/VariableBlurView.swift`
- `LiveContainerSwiftUI/FlekDeck/Search` → `LiveContainerSwiftUI/FreeDeck/Search`
- `LiveContainerSwiftUI/FlekDeck/Search/FlekSearchView.swift` → `LiveContainerSwiftUI/FreeDeck/Search/FreeSearchView.swift`
- `LiveContainerSwiftUI/FlekDeck/Search/LiquidGlassStable.swift` → `LiveContainerSwiftUI/FreeDeck/Search/LiquidGlassStable.swift`
- `LiveContainerSwiftUI/FlekDeck/Settings` → `LiveContainerSwiftUI/FreeDeck/Settings`
- `LiveContainerSwiftUI/FlekDeck/Settings/FlekAboutView.swift` → `LiveContainerSwiftUI/FreeDeck/Settings/FreeAboutView.swift`
- `LiveContainerSwiftUI/FlekDeck/Settings/FlekBuiltInJITSection.swift` → `LiveContainerSwiftUI/FreeDeck/Settings/FreeBuiltInJITSection.swift`
- `LiveContainerSwiftUI/FlekDeck/Settings/FlekCertificateImportView.swift` → `LiveContainerSwiftUI/FreeDeck/Settings/FreeCertificateImportView.swift`
- `LiveContainerSwiftUI/FlekDeck/Settings/FlekCertificateUnavailableView.swift` → `LiveContainerSwiftUI/FreeDeck/Settings/FreeCertificateUnavailableView.swift`
- `LiveContainerSwiftUI/FlekDeck/Settings/FlekDeviceModel.swift` → `LiveContainerSwiftUI/FreeDeck/Settings/FreeDeviceModel.swift`
- `LiveContainerSwiftUI/FlekDeck/Settings/FlekDevicePairing.swift` → `LiveContainerSwiftUI/FreeDeck/Settings/FreeDevicePairing.swift`
- `LiveContainerSwiftUI/FlekDeck/Settings/FlekGeneralView.swift` → `LiveContainerSwiftUI/FreeDeck/Settings/FreeGeneralView.swift`
- `LiveContainerSwiftUI/FlekDeck/Settings/FlekJITReport.swift` → `LiveContainerSwiftUI/FreeDeck/Settings/FreeJITReport.swift`
- `LiveContainerSwiftUI/FlekDeck/Settings/FlekJITSetup.swift` → `LiveContainerSwiftUI/FreeDeck/Settings/FreeJITSetup.swift`
- `LiveContainerSwiftUI/FlekDeck/Settings/FlekLocationSpoofer.swift` → `LiveContainerSwiftUI/FreeDeck/Settings/FreeLocationSpoofer.swift`
- `LiveContainerSwiftUI/FlekDeck/Settings/FlekLoopbackVPN.swift` → `LiveContainerSwiftUI/FreeDeck/Settings/FreeLoopbackVPN.swift`
- `LiveContainerSwiftUI/FlekDeck/Settings/FlekMemoryLimit.swift` → `LiveContainerSwiftUI/FreeDeck/Settings/FreeMemoryLimit.swift`
- `LiveContainerSwiftUI/FlekDeck/Settings/FlekMobileDataShortcut.swift` → `LiveContainerSwiftUI/FreeDeck/Settings/FreeMobileDataShortcut.swift`
- `LiveContainerSwiftUI/FlekDeck/Settings/FlekPairingDownload.swift` → `LiveContainerSwiftUI/FreeDeck/Settings/FlekPairingDownload.swift`
- `LiveContainerSwiftUI/FlekDeck/Settings/FlekPersonalizationView.swift` → `LiveContainerSwiftUI/FreeDeck/Settings/FreePersonalizationView.swift`
- `LiveContainerSwiftUI/FlekDeck/Settings/FlekPremiumOfferView.swift` → `LiveContainerSwiftUI/FreeDeck/Settings/FreePremiumOfferView.swift`
- `LiveContainerSwiftUI/FlekDeck/Settings/FlekStikDebugGuideView.swift` → `LiveContainerSwiftUI/FreeDeck/Settings/FreeStikDebugGuideView.swift`
- `LiveContainerSwiftUI/FlekDeck/Settings/FlekUDIDProfile.swift` → `LiveContainerSwiftUI/FreeDeck/Settings/FreeUDIDProfile.swift`
- `LiveContainerSwiftUI/FlekDeck/Settings/FlekUDIDProfileView.swift` → `LiveContainerSwiftUI/FreeDeck/Settings/FreeUDIDProfileView.swift`
- `LiveContainerSwiftUI/FlekDeck/Settings/FlekWallpaperCollectionView.swift` → `LiveContainerSwiftUI/FreeDeck/Settings/FreeWallpaperCollectionView.swift`
- `LiveContainerSwiftUI/FlekDeck/Springboard` → `LiveContainerSwiftUI/FreeDeck/Springboard`
- `LiveContainerSwiftUI/FlekDeck/Springboard/LCMinimizeToIconAnimator.swift` → `LiveContainerSwiftUI/FreeDeck/Springboard/LCMinimizeToIconAnimator.swift`
- `LiveContainerSwiftUI/FlekDeck/Springboard/LCSpringboardDragManager.swift` → `LiveContainerSwiftUI/FreeDeck/Springboard/LCSpringboardDragManager.swift`
- `LiveContainerSwiftUI/FlekDeck/Springboard/LCSpringboardIconCell.swift` → `LiveContainerSwiftUI/FreeDeck/Springboard/LCSpringboardIconCell.swift`
- `LiveContainerSwiftUI/FlekDeck/Springboard/LCSpringboardPageCell.swift` → `LiveContainerSwiftUI/FreeDeck/Springboard/LCSpringboardPageCell.swift`
- `LiveContainerSwiftUI/FlekDeck/Springboard/LCSpringboardRepresentable.swift` → `LiveContainerSwiftUI/FreeDeck/Springboard/LCSpringboardRepresentable.swift`
- `LiveContainerSwiftUI/FlekDeck/Springboard/LCSpringboardViewController.swift` → `LiveContainerSwiftUI/FreeDeck/Springboard/LCSpringboardViewController.swift`
- `LiveContainerSwiftUI/FlekStore` → `LiveContainerSwiftUI/FreeDeckStore`
- `LiveContainerSwiftUI/FlekStore/Helpers` → `LiveContainerSwiftUI/FreeDeckStore/Helpers`
- `LiveContainerSwiftUI/FlekStore/Helpers/FSCatalogFormat.swift` → `LiveContainerSwiftUI/FreeDeckStore/Helpers/FSCatalogFormat.swift`
- `LiveContainerSwiftUI/FlekStore/Helpers/FlekStoreAPI.swift` → `LiveContainerSwiftUI/FreeDeckStore/Helpers/FreeDeckStoreAPI.swift`
- `LiveContainerSwiftUI/FlekStore/Helpers/RepoCatalogCache.swift` → `LiveContainerSwiftUI/FreeDeckStore/Helpers/RepoCatalogCache.swift`
- `LiveContainerSwiftUI/FlekStore/Helpers/RepoCatalogLoader.swift` → `LiveContainerSwiftUI/FreeDeckStore/Helpers/RepoCatalogLoader.swift`
- `LiveContainerSwiftUI/FlekStore/Helpers/String+ext.swift` → `LiveContainerSwiftUI/FreeDeckStore/Helpers/String+ext.swift`
- `LiveContainerSwiftUI/FlekStore/Helpers/apiDateFormatter.swift` → `LiveContainerSwiftUI/FreeDeckStore/Helpers/apiDateFormatter.swift`
- `LiveContainerSwiftUI/FlekStore/Models` → `LiveContainerSwiftUI/FreeDeckStore/Models`
- `LiveContainerSwiftUI/FlekStore/Models/AccessVerification.swift` → `LiveContainerSwiftUI/FreeDeckStore/Models/AccessVerification.swift`
- `LiveContainerSwiftUI/FlekStore/Models/AppRepository.swift` → `LiveContainerSwiftUI/FreeDeckStore/Models/AppRepository.swift`
- `LiveContainerSwiftUI/FlekStore/Models/DeviceStatusResponse.swift` → `LiveContainerSwiftUI/FreeDeckStore/Models/DeviceStatusResponse.swift`
- `LiveContainerSwiftUI/FlekStore/Models/FSAppDescription.swift` → `LiveContainerSwiftUI/FreeDeckStore/Models/FSAppDescription.swift`
- `LiveContainerSwiftUI/FlekStore/Models/FSAppDetail.swift` → `LiveContainerSwiftUI/FreeDeckStore/Models/FSAppDetail.swift`
- `LiveContainerSwiftUI/FlekStore/Models/FSAppModel.swift` → `LiveContainerSwiftUI/FreeDeckStore/Models/FSAppModel.swift`
- `LiveContainerSwiftUI/FlekStore/Models/FSCategory.swift` → `LiveContainerSwiftUI/FreeDeckStore/Models/FSCategory.swift`
- `LiveContainerSwiftUI/FlekStore/Models/FlekDeviceRecord.swift` → `LiveContainerSwiftUI/FreeDeckStore/Models/FreeDeviceRecord.swift`
- `LiveContainerSwiftUI/FlekStore/Models/FlekPremium.swift` → `LiveContainerSwiftUI/FreeDeckStore/Models/FreePremium.swift`
- `LiveContainerSwiftUI/FlekStore/Models/FlekstoreSharedModel.swift` → `LiveContainerSwiftUI/FreeDeckStore/Models/FreeDeckStoreSharedModel.swift`
- `LiveContainerSwiftUI/FlekStore/Models/RepoResponse.swift` → `LiveContainerSwiftUI/FreeDeckStore/Models/RepoResponse.swift`
- `LiveContainerSwiftUI/FlekStore/Screens` → `LiveContainerSwiftUI/FreeDeckStore/Screens`
- `LiveContainerSwiftUI/FlekStore/Screens/Apps` → `LiveContainerSwiftUI/FreeDeckStore/Screens/Apps`
- `LiveContainerSwiftUI/FlekStore/Screens/Apps/FlekstoreAppsListViewModel.swift` → `LiveContainerSwiftUI/FreeDeckStore/Screens/Apps/FreeDeckStoreAppsListViewModel.swift`
- `LiveContainerSwiftUI/FlekStore/Screens/Repositories` → `LiveContainerSwiftUI/FreeDeckStore/Screens/Repositories`
- `LiveContainerSwiftUI/FlekStore/Screens/Repositories/AppRepositoryListView.swift` → `LiveContainerSwiftUI/FreeDeckStore/Screens/Repositories/AppRepositoryListView.swift`
- `LiveContainerSwiftUI/FlekStore/Views` → `LiveContainerSwiftUI/FreeDeckStore/Views`
- `LiveContainerSwiftUI/FlekStore/Views/AccessBlockedView.swift` → `LiveContainerSwiftUI/FreeDeckStore/Views/AccessBlockedView.swift`
- `LiveContainerSwiftUI/FlekStore/Views/AgeConfirmationView.swift` → `LiveContainerSwiftUI/FreeDeckStore/Views/AgeConfirmationView.swift`
- `LiveContainerSwiftUI/FlekStore/Views/RepositoryPicker.swift` → `LiveContainerSwiftUI/FreeDeckStore/Views/RepositoryPicker.swift`
- `LiveContainerSwiftUI/Utilities/FlekKeepAwake.swift` → `LiveContainerSwiftUI/Utilities/FreeKeepAwake.swift`
- `Resources/Assets.xcassets/AppIcon.appiconset/FlekDeck Logo 1024.jpg` → `Resources/Assets.xcassets/AppIcon.appiconset/FreeDeck Logo 1024.jpg`
- `Resources/Assets.xcassets/FlekIconFlekStore.imageset` → `Resources/Assets.xcassets/FreeIconFreeDeckStore.imageset`
- `Resources/Assets.xcassets/FlekIconFlekStore.imageset/Contents.json` → `Resources/Assets.xcassets/FreeIconFreeDeckStore.imageset/Contents.json`
- `Resources/Assets.xcassets/FlekIconFlekStore.imageset/icon_flekstore.png` → `Resources/Assets.xcassets/FreeIconFreeDeckStore.imageset/icon_freedeckstore.png`
- `Resources/Assets.xcassets/FlekIconInstaller.imageset` → `Resources/Assets.xcassets/FreeIconInstaller.imageset`
- `Resources/Assets.xcassets/FlekIconInstaller.imageset/Contents.json` → `Resources/Assets.xcassets/FreeIconInstaller.imageset/Contents.json`
- `Resources/Assets.xcassets/FlekIconInstaller.imageset/icon_installer.png` → `Resources/Assets.xcassets/FreeIconInstaller.imageset/icon_installer.png`
- `Resources/Assets.xcassets/FlekIconSettings.imageset` → `Resources/Assets.xcassets/FreeIconSettings.imageset`
- `Resources/Assets.xcassets/FlekIconSettings.imageset/Contents.json` → `Resources/Assets.xcassets/FreeIconSettings.imageset/Contents.json`
- `Resources/Assets.xcassets/FlekIconSettings.imageset/icon_settings.png` → `Resources/Assets.xcassets/FreeIconSettings.imageset/icon_settings.png`
- `Resources/Assets.xcassets/FlekJITShortcut.dataset` → `Resources/Assets.xcassets/FreeJITShortcut.dataset`
- `Resources/Assets.xcassets/FlekJITShortcut.dataset/Contents.json` → `Resources/Assets.xcassets/FreeJITShortcut.dataset/Contents.json`
- `Resources/Assets.xcassets/FlekJITShortcut.dataset/FlekJIT.shortcut` → `Resources/Assets.xcassets/FreeJITShortcut.dataset/FreeJIT.shortcut`
- `Resources/Assets.xcassets/FlekPremium.imageset` → `Resources/Assets.xcassets/FreePremium.imageset`
- `Resources/Assets.xcassets/FlekPremium.imageset/Contents.json` → `Resources/Assets.xcassets/FreePremium.imageset/Contents.json`
- `Resources/Assets.xcassets/FlekPremium.imageset/flekdeck-premium-upright-outline.svg` → `Resources/Assets.xcassets/FreePremium.imageset/freedeck-premium-upright-outline.svg`
- `Resources/Assets.xcassets/FlekWallpaperDefault.imageset` → `Resources/Assets.xcassets/FreeWallpaperDefault.imageset`
- `Resources/Assets.xcassets/FlekWallpaperDefault.imageset/Contents.json` → `Resources/Assets.xcassets/FreeWallpaperDefault.imageset/Contents.json`
- `Resources/Assets.xcassets/FlekWallpaperDefault.imageset/wallpaper_default.jpg` → `Resources/Assets.xcassets/FreeWallpaperDefault.imageset/wallpaper_default.jpg`
- `Tools/FlekJITShortcut` → `Tools/FreeJITShortcut`
- `Tools/FlekJITShortcut/make-shortcut.py` → `Tools/FreeJITShortcut/make-shortcut.py`
- `Tools/GameSheetPreview/Sources/FlekGameWarningView.swift` → `Tools/GameSheetPreview/Sources/FreeGameWarningView.swift`
- `TweakLoader/FlekStore+GuestHooks.m` → `TweakLoader/FreeDeckStore+GuestHooks.m`

### Content-modified files (rebrand only)

- `IdevicePairing/README.md`
- `IdevicePairing/build.sh`
- `LaunchAppExtension/LaunchAppExtension.swift`
- `LiveContainer.xcodeproj/project.pbxproj`
- `LiveContainer.xcodeproj/xcshareddata/xcschemes/LiveContainer.xcscheme`
- `LiveContainer.xcodeproj/xcshareddata/xcschemes/LiveProcess.xcscheme`
- `LiveContainer/Info.plist`
- `LiveContainer/LCSharedUtils.h`
- `LiveContainer/LCSharedUtils.m`
- `LiveContainer/Tweaks/LCGuestContacts.m`
- `LiveContainer/Tweaks/LCGuestPiP.m`
- `LiveContainer/Tweaks/LCGuestSafeArea.m`
- `LiveContainer/Tweaks/LCGuestSideBar.m`
- `LiveContainer/Tweaks/LCHostIdentity.m`
- `LiveContainer/Tweaks/NSBundle+GuestHooks.m`
- `LiveContainer/Tweaks/NSUserDefaults.m`
- `LiveContainerSwiftUI/App/LiveContainerSwiftUIApp.swift`
- `LiveContainerSwiftUI/FreeDeck/Design/FreeCornerRadii.swift`
- `LiveContainerSwiftUI/FreeDeck/Design/FreeDeckTheme.swift`
- `LiveContainerSwiftUI/FreeDeck/Design/FreeImageMemory.swift`
- `LiveContainerSwiftUI/FreeDeck/Design/FreeImagePlaceholder.swift`
- `LiveContainerSwiftUI/FreeDeck/Design/FreePageVisibility.swift`
- `LiveContainerSwiftUI/FreeDeck/Home/FreeAppCard.swift`
- `LiveContainerSwiftUI/FreeDeck/Home/FreeDeckModel.swift`
- `LiveContainerSwiftUI/FreeDeck/Home/FreeGameWarningView.swift`
- `LiveContainerSwiftUI/FreeDeck/Home/FreeHomeListView.swift`
- `LiveContainerSwiftUI/FreeDeck/Home/FreeInstallingCard.swift`
- `LiveContainerSwiftUI/FreeDeck/Home/FreeInternalPage.swift`
- `LiveContainerSwiftUI/FreeDeck/Home/FreeSpringboardView.swift`
- `LiveContainerSwiftUI/FreeDeck/Home/FreeWallpaperView.swift`
- `LiveContainerSwiftUI/FreeDeck/Home/FreeWidgetSync.swift`
- `LiveContainerSwiftUI/FreeDeck/Install/FreeAppAdvancedSheet.swift`
- `LiveContainerSwiftUI/FreeDeck/Install/FreeAppDetailSheet.swift`
- `LiveContainerSwiftUI/FreeDeck/Install/FreeInstallOverrides.swift`
- `LiveContainerSwiftUI/FreeDeck/Install/FreeInstallTray.swift`
- `LiveContainerSwiftUI/FreeDeck/Install/FreeInstallerView.swift`
- `LiveContainerSwiftUI/FreeDeck/Install/FreeScreenshotViewer.swift`
- `LiveContainerSwiftUI/FreeDeck/Search/FreeSearchView.swift`
- `LiveContainerSwiftUI/FreeDeck/Settings/FlekPairingDownload.swift`
- `LiveContainerSwiftUI/FreeDeck/Settings/FreeAboutView.swift`
- `LiveContainerSwiftUI/FreeDeck/Settings/FreeBuiltInJITSection.swift`
- `LiveContainerSwiftUI/FreeDeck/Settings/FreeCertificateUnavailableView.swift`
- `LiveContainerSwiftUI/FreeDeck/Settings/FreeDeviceModel.swift`
- `LiveContainerSwiftUI/FreeDeck/Settings/FreeDevicePairing.swift`
- `LiveContainerSwiftUI/FreeDeck/Settings/FreeGeneralView.swift`
- `LiveContainerSwiftUI/FreeDeck/Settings/FreeJITReport.swift`
- `LiveContainerSwiftUI/FreeDeck/Settings/FreeJITSetup.swift`
- `LiveContainerSwiftUI/FreeDeck/Settings/FreeLocationSpoofer.swift`
- `LiveContainerSwiftUI/FreeDeck/Settings/FreeLoopbackVPN.swift`
- `LiveContainerSwiftUI/FreeDeck/Settings/FreeMemoryLimit.swift`
- `LiveContainerSwiftUI/FreeDeck/Settings/FreeMobileDataShortcut.swift`
- `LiveContainerSwiftUI/FreeDeck/Settings/FreePersonalizationView.swift`
- `LiveContainerSwiftUI/FreeDeck/Settings/FreeStikDebugGuideView.swift`
- `LiveContainerSwiftUI/FreeDeck/Settings/FreeUDIDProfileView.swift`
- `LiveContainerSwiftUI/FreeDeck/Settings/FreeWallpaperCollectionView.swift`
- `LiveContainerSwiftUI/FreeDeck/Springboard/LCMinimizeToIconAnimator.swift`
- `LiveContainerSwiftUI/FreeDeck/Springboard/LCSpringboardDragManager.swift`
- `LiveContainerSwiftUI/FreeDeck/Springboard/LCSpringboardIconCell.swift`
- `LiveContainerSwiftUI/FreeDeck/Springboard/LCSpringboardPageCell.swift`
- `LiveContainerSwiftUI/FreeDeck/Springboard/LCSpringboardRepresentable.swift`
- `LiveContainerSwiftUI/FreeDeck/Springboard/LCSpringboardViewController.swift`
- `LiveContainerSwiftUI/FreeDeckStore/Helpers/FSCatalogFormat.swift`
- `LiveContainerSwiftUI/FreeDeckStore/Helpers/RepoCatalogCache.swift`
- `LiveContainerSwiftUI/FreeDeckStore/Helpers/RepoCatalogLoader.swift`
- `LiveContainerSwiftUI/FreeDeckStore/Helpers/apiDateFormatter.swift`
- `LiveContainerSwiftUI/FreeDeckStore/Models/FSAppDetail.swift`
- `LiveContainerSwiftUI/FreeDeckStore/Models/FSAppModel.swift`
- `LiveContainerSwiftUI/FreeDeckStore/Models/FreeDeckStoreSharedModel.swift`
- `LiveContainerSwiftUI/FreeDeckStore/Models/FreeDeviceRecord.swift`
- `LiveContainerSwiftUI/FreeDeckStore/Screens/Apps/FreeDeckStoreAppsListViewModel.swift`
- `LiveContainerSwiftUI/FreeDeckStore/Screens/Repositories/AppRepositoryListView.swift`
- `LiveContainerSwiftUI/FreeDeckStore/Views/RepositoryPicker.swift`
- `LiveContainerSwiftUI/Models/LCAppInfo.h`
- `LiveContainerSwiftUI/Models/LCAppInfo.m`
- `LiveContainerSwiftUI/Models/LCAppModel+Conversion.swift`
- `LiveContainerSwiftUI/Models/LCAppModel.swift`
- `LiveContainerSwiftUI/Utilities/FreeKeepAwake.swift`
- `LiveContainerSwiftUI/Utilities/GameDetector.swift`
- `LiveContainerSwiftUI/Utilities/LCDeviceLog.m`
- `LiveContainerSwiftUI/Utilities/LCDevicePairing.h`
- `LiveContainerSwiftUI/Utilities/LCProvisioningProfile.swift`
- `LiveContainerSwiftUI/Utilities/LCUtils.m`
- `LiveContainerSwiftUI/Utilities/LCUtilsExtensions.swift`
- `LiveContainerSwiftUI/Utilities/Shared.swift`
- `LiveContainerSwiftUI/Views/AppList/AppSettings/LCAppSettingsView.swift`
- `LiveContainerSwiftUI/Views/AppList/LCAppBanner/LCAppBannerViewController.swift`
- `LiveContainerSwiftUI/Views/AppList/LCAppListView.swift`
- `LiveContainerSwiftUI/Views/AppList/LCInstallBackgroundTask.swift`
- `LiveContainerSwiftUI/Views/AppList/LCInstallQueue.swift`
- `LiveContainerSwiftUI/Views/LCTweaksView.swift`
- `LiveContainerSwiftUI/Views/Settings/DataManagement/LCDataManagementView.swift`
- `LiveContainerSwiftUI/Views/Settings/LCJITLessDiagnoseView.swift`
- `LiveContainerSwiftUI/Views/Settings/LCMultiLCManagementView.swift`
- `LiveContainerSwiftUI/Views/Settings/LCSettingsView.swift`
- `LoopbackVPN/Info.plist`
- `MultitaskSupport/AppSceneViewController.h`
- `MultitaskSupport/AppSceneViewController.m`
- `MultitaskSupport/LCGuestContactsAccess.h`
- `MultitaskSupport/LCGuestContactsAccess.m`
- `MultitaskSupport/LCRotationLock.swift`
- `MultitaskSupport/MultitaskDockView.swift`
- `MultitaskSupport/MultitaskManager.swift`
- `MultitaskSupport/PiPManager.h`
- `MultitaskSupport/PiPManager.m`
- `MultitaskSupport/UIKitPrivate+MultitaskSupport.h`
- `MultitaskSupport/VirtualWindowsHostView.m`
- `README.md`
- `Resources/Assets.xcassets/AppIcon.appiconset/Contents.json`
- `Resources/Assets.xcassets/FreeIconFreeDeckStore.imageset/Contents.json`
- `Resources/Assets.xcassets/FreeJITShortcut.dataset/Contents.json`
- `Resources/Assets.xcassets/FreePremium.imageset/Contents.json`
- `Resources/Localizable.xcstrings`
- `ShareExtension/ShareExtensionViewModel.swift`
- `ShareExtension/ShareExtensionViews.swift`
- `ShareExtension/main.m`
- `SideStoreSupport/SideStoreHooks.m`
- `StikJITHeadless/main.m`
- `THIRD_PARTY_NOTICES.md`
- `Tools/FreeJITShortcut/make-shortcut.py`
- `Tools/GameSheetPreview/Info.plist`
- `Tools/GameSheetPreview/README.md`
- `Tools/GameSheetPreview/Sources/App.swift`
- `Tools/GameSheetPreview/Sources/FreeGameWarningView.swift`
- `Tools/GameSheetPreview/run.sh`
- `TweakLoader/FreeDeckStore+GuestHooks.m`
- `TweakLoader/TweakLoader.m`
- `WidgetExtension/AppsWidget.swift`
- `WidgetExtension/AppsWidgetConfiguration.swift`
- `WidgetExtension/AppsWidgetView.swift`
- `WidgetExtension/Info.plist`
- `WidgetExtension/WidgetAppList.swift`
- `WidgetExtension/WidgetExtension-Bridging-Header.h`
- `xcconfigs/Global.xcconfig`

## 3. New modules (deliverables)

- `BUILDING.md`
- `LiveContainerSwiftUI/FreeDeck/PairingManager.swift`
- `LiveContainerSwiftUI/FreeDeck/RemoteStorageHook.h`
- `LiveContainerSwiftUI/FreeDeck/RemoteStorageHook.m`
- `LiveContainerSwiftUI/FreeDeck/ServerLibraryView.swift`
- `LiveContainerSwiftUI/FreeDeck/WebPortRunnerView.swift`
- `server/.env.example`
- `server/Dockerfile`
- `server/README.md`
- `server/TEST_EVIDENCE.txt`
- `server/docker-compose.yml`
- `server/nginx.conf`
- `server/requirements.txt`
- `server/server.py`

See `README.md` for what each does and `BUILDING.md` for build/sideload instructions.

## 4. Build-compatibility fixes (iOS 26 SDK / Xcode 26.x)

Upstream builds against the iOS 27 SDK; these changes make FreeDeck build on
Xcode 26.x toolchains (GitHub-hosted runners) without losing iOS 27 behavior
when built with Xcode 27:

| File | Change |
|---|---|
| `LiveContainerSwiftUI/FreeDeck/Compat/FreeDeckSDKCompat.swift` (new) | Shim for the iOS 27.1 `toolbarVerticalEdge` environment key (nil below that SDK) |
| `WidgetExtension/AppsWidget.swift` | The 4x6 widget (`systemExtraLargePortrait`, iOS 27 SDK only) is behind `#if compiler(>=6.4)` |
| `WidgetExtension/AppsWidgetConfiguration.swift` | Explicit key path root in `parameterSummary` for older compilers |
| `LiveContainer/Tweaks/LCGuestSideBar.m` | iOS 27.1 `verticalBarEdge` measurement behind `__IPHONE_OS_VERSION_MAX_ALLOWED` with a stub |
| `MultitaskSupport/MultitaskDockView.swift` | Same guard for `UITraitCollection.verticalBarEdge` |
| `LiveContainerSwiftUI/Views/AppList/LCAppListView.swift` | Body chain split into three type-check stages; `jitNotReady` Binding hoisted |
| `LiveContainerSwiftUI/FreeDeck/Settings/FreePremiumOfferView.swift` | `Button`/`navigationTitle` take no `verbatim:` label |
| `LiveContainer.xcodeproj/project.pbxproj` | Deployment target 15.0 -> 16.0 (FreeDeck's modules need `NavigationStack`) |

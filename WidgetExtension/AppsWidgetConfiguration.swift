//
//  AppsWidgetConfiguration.swift
//  WidgetExtension
//
//  What an Apps widget shows, set in its Edit Widget sheet: the apps first on
//  FreeDeck's home screen, the ones opened most, or apps picked one by one.
//

import AppIntents
import WidgetKit

struct AppsWidgetConfiguration: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "Apps" }
    static var description: IntentDescription { "Choose which FreeDeck apps the widget shows." }

    @Parameter(title: "Show", default: .freeDeckOrder)
    var show: AppsWidgetSource

    // As many as each size holds. The 4×6 size can't be named here while the
    // widget still runs on iOS 17, so it takes any number and shows 24.
    @Parameter(title: "Apps", size: [.systemSmall: 4, .systemMedium: 8, .systemLarge: 16])
    var apps: [WidgetAppEntity]?

    static var parameterSummary: some ParameterSummary {
        When(\.$show, .equalTo, .chosen) {
            Summary {
                \.$show
                \.$apps
            }
        } otherwise: {
            Summary {
                \.$show
            }
        }
    }
}

enum AppsWidgetSource: String, AppEnum {
    case freeDeckOrder
    case mostUsed
    case chosen

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Apps to Show" }
    static var caseDisplayRepresentations: [AppsWidgetSource: DisplayRepresentation] {
        [
            .freeDeckOrder: "FreeDeck Order",
            .mostUsed: "Most Used",
            .chosen: "Chosen Apps",
        ]
    }
}

/// One of FreeDeck's apps, as the Edit Widget sheet lists it.
struct WidgetAppEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "App" }
    static let defaultQuery = WidgetAppQuery()

    let id: String
    let name: String
    let iconURL: URL

    var displayRepresentation: DisplayRepresentation {
        // The sheet is drawn by iOS, which can't read the app group, so the
        // icon goes along as data.
        let icon = try? Data(contentsOf: iconURL)
        return DisplayRepresentation(title: "\(name)", image: icon.map { DisplayRepresentation.Image(data: $0) })
    }
}

struct WidgetAppQuery: EntityStringQuery {
    func entities(for identifiers: [WidgetAppEntity.ID]) async throws -> [WidgetAppEntity] {
        let apps = Self.allApps()
        return identifiers.compactMap { id in apps.first { $0.id == id } }
    }

    func entities(matching string: String) async throws -> [WidgetAppEntity] {
        Self.allApps().filter { $0.name.localizedCaseInsensitiveContains(string) }
    }

    func suggestedEntities() async throws -> [WidgetAppEntity] {
        Self.allApps()
    }

    /// Every app on FreeDeck's home screen, in its order.
    private static func allApps() -> [WidgetAppEntity] {
        guard case .list(let list, let folder) = AppListReader.source() else { return [] }
        return list.apps.map { app in
            WidgetAppEntity(id: app.id, name: app.name, iconURL: WidgetAppList.iconURL(in: folder, for: app.id))
        }
    }
}

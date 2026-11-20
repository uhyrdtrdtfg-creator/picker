import CoreGraphics
import Foundation

#if canImport(PickerCore)
import PickerCore
#endif

#if canImport(PickerActions)
import PickerActions
#endif

// Local popup models used until project.yml links Packages/PickerCore and
// Packages/PickerActions into the Picker app target. When PickerCore and
// PickerActions are imported, PopupPlacement comes directly from PickerCore
// and PickerAction values bridge directly into PopupAction; replace these
// fallback definitions once the packages are linked into Picker.xcodeproj.

public enum PopupBuiltInAction: String, CaseIterable, Sendable {
    case copy
    case cut
    case paste
    case search
    case openLink
    case dictionary
    case reveal
    case spelling
    case sendToOrca

    public init?(actionID: String) {
        switch actionID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "copy", "app.popclip.builtin.copy":
            self = .copy
        case "cut", "app.popclip.builtin.cut":
            self = .cut
        case "paste", "app.popclip.builtin.paste":
            self = .paste
        case "search", "app.popclip.builtin.search":
            self = .search
        case "openlink", "open-link", "open_link", "app.popclip.builtin.openlink":
            self = .openLink
        case "dictionary", "lookup", "app.popclip.builtin.lookup", "app.popclip.builtin.dictionary":
            self = .dictionary
        case "reveal", "revealfile", "revealinfinder", "reveal-in-finder", "reveal_in_finder", "app.popclip.builtin.revealfile":
            self = .reveal
        case "spelling", "app.popclip.builtin.spelling":
            self = .spelling
        case "sendtoorca", "send-to-orca", "send_to_orca", "orca", "app.picker.builtin.orca":
            self = .sendToOrca
        default:
            return nil
        }
    }

    public var shortTitle: String {
        switch self {
        case .copy:
            return "Copy"
        case .cut:
            return "Cut"
        case .paste:
            return "Paste"
        case .search:
            return "Search"
        case .openLink:
            return "Open Link"
        case .dictionary:
            return "Dictionary"
        case .reveal:
            return "Reveal"
        case .spelling:
            return "Spelling"
        case .sendToOrca:
            return PickerOrcaStrings.popupButtonTitle
        }
    }

    public var symbolName: String {
        switch self {
        case .copy:
            return "doc.on.doc"
        case .cut:
            return "scissors"
        case .paste:
            return "doc.on.clipboard"
        case .search:
            return "magnifyingglass"
        case .openLink:
            return "link"
        case .dictionary:
            return "book"
        case .reveal:
            return "folder"
        case .spelling:
            return "textformat.abc.dottedunderline"
        case .sendToOrca:
            return "terminal"
        }
    }
}

public struct PopupAction: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let symbolName: String

    public init(id: String, title: String, symbolName: String) {
        self.id = id
        self.title = title
        self.symbolName = symbolName
    }

    public init(builtIn: PopupBuiltInAction) {
        self.id = builtIn.rawValue
        self.title = builtIn.shortTitle
        self.symbolName = builtIn.symbolName
    }

    public init(id: String) {
        if let builtIn = PopupBuiltInAction(actionID: id) {
            self.id = id
            self.title = builtIn.shortTitle
            self.symbolName = builtIn.symbolName
        } else {
            self.id = id
            self.title = id
            self.symbolName = "circle"
        }
    }

    public static let copy = PopupAction(builtIn: .copy)
    public static let cut = PopupAction(builtIn: .cut)
    public static let paste = PopupAction(builtIn: .paste)
    public static let search = PopupAction(builtIn: .search)
    public static let openLink = PopupAction(builtIn: .openLink)
    public static let dictionary = PopupAction(builtIn: .dictionary)
    public static let reveal = PopupAction(builtIn: .reveal)
    public static let spelling = PopupAction(builtIn: .spelling)
    public static var sendToOrca: PopupAction {
        PopupAction(builtIn: .sendToOrca)
    }

    public static let builtInActions: [PopupAction] = PopupBuiltInAction.allCases.map {
        PopupAction(builtIn: $0)
    }

    #if canImport(PickerActions)
    public init(pickerAction: PickerAction) {
        self.id = pickerAction.id.rawValue
        if pickerAction.id == .revealFile {
            self.title = "Reveal"
        } else {
            self.title = pickerAction.titleEn
        }
        self.symbolName = pickerAction.symbolName
    }
    #endif
}

#if !canImport(PickerCore)
public enum PopupPlacement {
    public static let gap: CGFloat = 6

    public static func place(
        selectionBounds: CGRect,
        screenVisible: CGRect,
        preferAbove: Bool = true,
        popupSize: CGSize
    ) -> CGRect {
        let selection = selectionBounds.standardized
        let visible = screenVisible.standardized

        let width = visible.width > 0 ? min(max(0, popupSize.width), visible.width) : max(0, popupSize.width)
        let height = visible.height > 0 ? min(max(0, popupSize.height), visible.height) : max(0, popupSize.height)

        let idealX = selection.midX - (width / 2)
        let aboveY = selection.maxY + gap
        let belowY = selection.minY - gap - height

        let preferredY = preferAbove ? aboveY : belowY
        let alternateY = preferAbove ? belowY : aboveY

        let preferredFits = preferredY >= visible.minY && (preferredY + height) <= visible.maxY
        let alternateFits = alternateY >= visible.minY && (alternateY + height) <= visible.maxY

        let unclampedY: CGFloat
        if preferredFits {
            unclampedY = preferredY
        } else if alternateFits {
            unclampedY = alternateY
        } else {
            let roomAbove = visible.maxY - selection.maxY
            let roomBelow = selection.minY - visible.minY
            if preferAbove {
                unclampedY = roomBelow > roomAbove ? belowY : aboveY
            } else {
                unclampedY = roomAbove > roomBelow ? aboveY : belowY
            }
        }

        let maxX = max(visible.minX, visible.maxX - width)
        let maxY = max(visible.minY, visible.maxY - height)

        let clampedX = min(max(idealX, visible.minX), maxX)
        let clampedY = min(max(unclampedY, visible.minY), maxY)

        return CGRect(x: clampedX, y: clampedY, width: width, height: height)
    }
}
#endif

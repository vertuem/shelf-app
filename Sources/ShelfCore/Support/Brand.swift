import Foundation

/// The product's public identity in one place.
///
/// The product, the modules (`ShelfCore`, `ShelfUI`, …) and the bottom panel
/// (`ShelfPanel`) all share the name Shelf. It was briefly called Cardsill.
public enum Brand {
    public static let name = "Shelf"
    /// Cask token and file names.
    public static let slug = "shelf"
    /// The URL scheme, distinct from the plain word so no other app's `shelf-app://` competes for it.
    public static let urlScheme = "shelf-app"
    public static let releaseBundleID = "com.vertuem.shelf"
    public static let devBundleID = "com.vertuem.shelf.dev"

    /// Added to every pasteboard write Shelf makes, so the monitor never records its own pastes.
    public static let originMarkerType = "com.vertuem.shelf.origin"
    /// Added when Shelf puts the previous clipboard back after a paste. The
    /// monitor skips these writes: the content is not a new copy, and it may have
    /// come from an ignored app or been copied while capture was paused.
    public static let restoredMarkerType = "com.vertuem.shelf.restored"
    /// Internal drag type carrying an item id, used to drop cards on pinboard chips.
    public static let itemDragType = "com.vertuem.shelf.item-id"
    /// Keychain service of the blob encryption key.
    public static let keychainService = "com.vertuem.shelf.blobkey"

    /// `owner/repo` on GitHub. Overridable through `ShelfRepository` in Info.plist for forks.
    public static var repository: String {
        Bundle.main.object(forInfoDictionaryKey: "ShelfRepository") as? String ?? "vertuem/shelf-app"
    }

    public static var repositoryURL: URL { URL(string: "https://github.com/\(repository)")! }
}

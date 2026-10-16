import ShelfCore
import UniformTypeIdentifiers

extension UTType {
    /// A card being dragged inside Shelf (onto a pinboard chip, or to reorder).
    public static let shelfItem = UTType(exportedAs: Brand.itemDragType)
    /// A pinboard chip being dragged to reorder.
    public static let shelfPinboard = UTType(exportedAs: "com.vertuem.shelf.pinboard-id")
}

extension NSItemProvider {
    /// Loads a UUID written by Shelf's own drags.
    func loadShelfID(for type: UTType, _ completion: @escaping @MainActor (UUID) -> Void) {
        _ = loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
            guard let data, let string = String(data: data, encoding: .utf8), let id = UUID(uuidString: string) else { return }
            Task { @MainActor in completion(id) }
        }
    }

    func registerShelfID(_ id: UUID, as type: UTType) {
        registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .ownProcess) { completion in
            completion(Data(id.uuidString.utf8), nil)
            return nil
        }
    }
}

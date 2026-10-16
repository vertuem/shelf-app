import AppKit
import LinkPresentation
import ShelfCore

/// Opt-in link previews (v1.1): fetches the title and image of each newly
/// copied web link with LinkPresentation.
///
/// Off by default. When on: http and https only, a
/// 5 second timeout, never for hosts on the local network, and never for links
/// from ignored apps (those are not recorded in the first place).
@MainActor
public final class LinkPreviewer {
    private let store: Store
    private let preferences: Preferences
    private var task: Task<Void, Never>?

    public init(store: Store, preferences: Preferences) {
        self.store = store
        self.preferences = preferences
    }

    public func start() {
        guard task == nil else { return }
        task = Task { [weak self, store] in
            for await event in store.events() {
                guard case .captured(let item, true) = event, item.kind == .link else { continue }
                await self?.fetchIfAllowed(item)
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    func fetchIfAllowed(_ item: ClipItem) async {
        guard preferences.generateLinkPreviews,
              let string = item.url, let url = URL(string: string), let host = url.host,
              Self.isFetchable(url), await Self.resolvesToPublicAddresses(host) else { return }
        let provider = LPMetadataProvider()
        provider.timeout = 5
        provider.shouldFetchSubresources = true
        guard let metadata = try? await provider.startFetchingMetadata(for: url) else { return }
        let title = metadata.title
        let image = await Self.loadImage(metadata.imageProvider ?? metadata.iconProvider)
        let thumbnail = image.flatMap { $0.cgImage(forProposedRect: nil, context: nil, hints: nil) }.flatMap(Thumbnailer.encode)
        try? await store.setLinkPreview(item.id, title: title, thumbnail: thumbnail)
    }

    /// Public web hosts only: no localhost, `.local`, or private, loopback and
    /// link-local addresses, however they are written (`127.1`, `0x7f.0.0.1`).
    public nonisolated static func isFetchable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = url.host?.lowercased(), !host.isEmpty else { return false }
        while host.hasSuffix(".") { host.removeLast() }
        if host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".localhost") || host.hasSuffix(".internal") {
            return false
        }
        if host.contains(":") { return false } // IPv6 literals: skip rather than classify
        if let address = ipv4Address(host) { return isPublic(ipv4: address) }
        return host.contains(".")
    }

    /// Resolves the host and requires every address to be public, so a public
    /// name pointing at a private address is refused too.
    nonisolated static func resolvesToPublicAddresses(_ host: String) async -> Bool {
        await Task.detached(priority: .utility) {
            var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                                 ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return false }
            defer { freeaddrinfo(first) }
            var cursor: UnsafeMutablePointer<addrinfo>? = first
            var sawAddress = false
            while let info = cursor {
                if info.pointee.ai_family == AF_INET, let address = info.pointee.ai_addr {
                    let ipv4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
                    if !isPublic(ipv4: ipv4) { return false }
                    sawAddress = true
                } else if info.pointee.ai_family == AF_INET6, let address = info.pointee.ai_addr {
                    // Loopback, link-local and unique-local IPv6 are refused; others pass.
                    let bytes = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
                        withUnsafeBytes(of: pointer.pointee.sin6_addr) { Array($0) }
                    }
                    let isLoopback = bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
                    if isLoopback || bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80 || bytes[0] & 0xFE == 0xFC { return false }
                    sawAddress = true
                }
                cursor = info.pointee.ai_next
            }
            return sawAddress
        }.value
    }

    /// Parses every IPv4 spelling `inet_aton` accepts: `127.1`, octal, hex.
    nonisolated static func ipv4Address(_ host: String) -> UInt32? {
        var address = in_addr()
        guard inet_aton(host, &address) != 0 else { return nil }
        return UInt32(bigEndian: address.s_addr)
    }

    nonisolated static func isPublic(ipv4 address: UInt32) -> Bool {
        let first = address >> 24
        let second = (address >> 16) & 0xFF
        switch (first, second) {
        case (0, _), (10, _), (127, _), (169, 254), (192, 168): return false
        case (172, 16...31): return false
        case (100, 64...127): return false
        case (224..., _): return false // multicast and reserved
        default: return true
        }
    }

    private static func loadImage(_ provider: NSItemProvider?) async -> NSImage? {
        guard let provider, provider.canLoadObject(ofClass: NSImage.self) else { return nil }
        return await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: NSImage.self) { object, _ in
                let image = object as? NSImage
                continuation.resume(returning: image)
            }
        }
    }
}

# Changelog

All notable changes are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/). Each pull request title becomes one line.

## [Unreleased]

## [0.1.0] - 2026-10-17

### Added
- The shelf: a full-width, non-activating glass panel at the bottom of the screen with color-coded cards, source app icons, relative times and keyboard navigation.
- Capture of text, rich text, links, images, files, colors and audio, with every pasteboard type stored losslessly, including multi-file copies.
- Pinboards with colors and icons, drag-to-pin, ⌘P, inline rename, drag reordering and soft limits.
- Instant fuzzy search with `type:`, `app:`, `after:`, `before:` and `pinned:` filters, and search across all tabs.
- Paste into the active app with a simulated ⌘V, leaving the pasted item on the clipboard (restoring the previous clipboard is an option); plain-text paste; quick paste with ⌘1 to ⌘9.
- Paste Stack: copy several things, then paste them in order with ⌘V.
- Privacy filters for concealed, transient and auto-generated data, ignored apps, hiding from screen sharing, an optional secrets heuristic, and encryption at rest with a Keychain key.
- History retention (day to forever) with a 50,000-item cap, disk usage display, and removal of old images.
- Settings, onboarding with the Accessibility explanation, a menu-bar item, pausing capture, and the `shelf-app://` URL scheme.
- In-app updates from GitHub Releases with signature, notarization, Team ID and checksum verification.
- Quick Look on Space, opt-in link previews, history export and import as a zip, import from Maccy, and dragging cards into other apps.
- Import from Paste: history and pinboards, including images and files kept outside Paste's database.
- Shelf positions: bottom, left edge, right edge, or a centered panel with a card grid (Settings, General).
- Invisible by default: no menu bar icon unless turned on, and the app registers itself to open at login.
- Select several cards with Shift and the arrows, ⌘-click or Shift-click; Return pastes them as lines (files as separate files), Delete removes them, ⌘P pins them.
- Filter suggestions under the search field for `type:`, `app:` and `pinned:`, accepted with Tab.
- Search matches highlighted on the cards; code from editors and terminals drawn in monospace; images edge to edge; a hover lift on cards.
- Cards snap to the grid when flicked, a mouse wheel scrolls the strip, Page Up and Page Down move a page, and the selection scrolls one card ahead.
- Pinboard chips show their item count, with a fade when more chips are hidden.
- The Paste Stack shows its progress, says when everything is pasted, and takes ↑, ↓, Return and Delete.
- Refined cards: a larger app icon tile, a heading line on text cards, syntax-colored code, rendered rich text (bold, italic), full-bleed images and colors with a pill, link cards with the page image across the top, file cards with the folder, centered footers.
- Titles: rename a card with ⌘R; the title shows in the header, is searchable, and comes along from Paste.
- Jump to History: ⌘G or "Show in Clipboard" / "Show in <pinboard>" takes a search result to its place in the list, with its neighbors.
- A global shortcut to pause or resume capture (Settings, Shortcuts; unset by default).
- Image cards drag out as PNG files, for upload fields and Finder.
- "Paste as" UPPERCASE, lowercase, Title Case, snake_case or kebab-case from the card menu.
- "Copy for AI": one text document from the selected cards or a whole pinboard, ready to paste into a chat.
- Translations into Dutch, German, French, Spanish and Japanese.
- A soft pop when you paste a card and an optional tick when you copy, each with its own setting and a preview button. The sounds are synthesized for Shelf and pitched so laptop speakers play them.
- Card headers in the color of the source app's icon, like Paste, with "By content type" as an option.
- The welcome tour and Settings list each permission with why it is needed and a check once granted, including macOS's new clipboard access setting (Paste from Other Apps).
- A layered Liquid Glass app icon with dark, clear and tinted styles on macOS 26.
- Liquid Glass throughout on macOS 26: a floating glass settings sidebar with System Settings–style icons, a redesigned welcome tour, glass controls on the shelf and the Paste Stack, and symbols in every menu.
- Text inside copied images is recognized on-device and searchable.

### Fixed
- With Paste from Other Apps set to Ask, Shelf no longer makes macOS alert on every copy: it stops reading and says once how to allow it.
- The app now records the SDK it was built with, so macOS 26 draws it with the current design instead of in compatibility mode.

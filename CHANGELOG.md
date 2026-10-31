# Changelog

All notable changes are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/). Each pull request title becomes one line.

## [Unreleased]

### Added
- Settings, General has a Quit button: with no Dock or menu bar icon there was no visible way to quit.

## [0.1.2] - 2026-10-31

### Fixed
- The shelf stopped opening, mostly over full-screen apps, until Shelf was restarted: macOS had lost the shelf's window (on no Space, while still reported as shown) and showing it again did not bring it back. Shelf now checks with the window server that the shelf really reached the screen, and if not, replaces the window and opens it again.

## [0.1.1] - 2026-10-29

**Coming from 0.1.0?** 0.1.0 cannot check for updates, so install this version by hand once: open the DMG and drag Shelf to Applications, replacing the old one. From 0.1.1 on, Shelf tells you when a new version is out.

### Added
- Update notices for releases that Apple did not sign: Shelf checks GitHub when it starts (also at login) and every six hours, shows the release notes, and Download fetches the new version to drag to Applications.
- After such an update, Shelf clears its old Accessibility entry, which macOS keeps but no longer accepts, and asks again, so one click turns pasting back on.

### Changed
- New versions are offered as soon as they are released; the three-day wait is off by default (Settings, About).
- When Return copies a card instead of pasting it, the message says why: Shelf needs Accessibility, or the app is on the paste-manually list.
- Several selected cards with images among them paste one after another, in order, instead of leaving the images out (or failing when every card was an image).

### Fixed
- Skipping Accessibility in the welcome tour no longer switches paste mode to the clipboard for good; once Accessibility is granted, Return pastes.
- Escape closes the shelf even when it does not have the keyboard, for example over a full-screen app, instead of reaching the app underneath and leaving full screen.
- ⇧⌘V no longer needs two presses after the system hid the shelf (Hide Others), which looked like the shelf not opening.
- The shelf no longer stops opening after the system took its window off screen (a full-screen Space closing, a close animation that never finished): it counted as open, so ⇧⌘V and `shelf-app://open` did nothing until Shelf was restarted.
- Search: a word typed after a filter chip no longer joins the word before it.
- Copying several cards with an image among them puts all the text in the first clipboard item and keeps plain text and Paste as.
- Pasting several cards keeps their order in the history.
- Escape cancels the Delete Pinboard dialog and closes the Paste Stack when it has the keyboard, instead of closing the shelf.
- Switching to another app closes the shelf; ⇧⌘V on an open shelf without the keyboard gives it the keyboard; Show in Finder and Open Link close the shelf first.
- After the Keyboard Shortcuts window closes, the next paste goes to the app you were in, not to Shelf.
- The Paste Stack no longer vanishes when reopened during its fade-out, and opens above a shelf on the right edge.

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

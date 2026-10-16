# Homebrew cask, published through the personal tap vertuem/homebrew-tap:
#   brew install vertuem/tap/shelf
# Scripts/bump-cask.sh updates version and sha256 for each release.
cask "shelf" do
  version "1.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/vertuem/shelf-app/releases/download/v#{version}/Shelf-#{version}.dmg"
  name "Shelf"
  desc "Clipboard manager with a shelf of cards along the bottom of the screen"
  homepage "https://github.com/vertuem/shelf-app"

  livecheck do
    url :url
    strategy :github_latest
  end

  # The app updates itself from GitHub Releases.
  auto_updates true
  depends_on arch: :arm64
  depends_on macos: ">= :sonoma"

  app "Shelf.app"

  uninstall quit:       "com.vertuem.shelf",
            login_item: "Shelf"

  zap trash: [
    "~/Library/Application Support/Shelf",
    "~/Library/Caches/com.vertuem.shelf",
    "~/Library/HTTPStorages/com.vertuem.shelf",
    "~/Library/Preferences/com.vertuem.shelf.plist",
  ]
end

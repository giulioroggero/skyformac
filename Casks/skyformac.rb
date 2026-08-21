cask "skyformac" do
  version "0.5.0"
  sha256 "612b67d6d7a8ea83e5c54b41d754a920a875e3693c59787a512eb84bd2ce8ff6"

  # Matches the actual asset name `gh release create`/the release workflow produces
  # (`skyformac-v<version>-macOS.dmg`), not `scripts/release.sh`'s own
  # `Skyformac-<version>.dmg` — update this line too if that script's naming is ever
  # actually used for a real release instead.
  url "https://github.com/giulioroggero/skyformac/releases/download/v#{version}/skyformac-v#{version}-macOS.dmg"
  name "Skyformac"
  desc "Native macOS ZWO ASI astrophotography camera control app"
  homepage "https://github.com/giulioroggero/skyformac"

  # Matches Info.plist's own LSMinimumSystemVersion.
  depends_on macos: ">= :ventura"

  app "skyformac.app"

  zap trash: [
    "~/Library/Preferences/com.giulioroggero.skyformac.plist",
    "~/Library/Saved Application State/com.giulioroggero.skyformac.savedState",
  ]
end

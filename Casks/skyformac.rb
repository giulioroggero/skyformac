cask "skyformac" do
  version "0.5.3"
  sha256 "d08854080d431422a24421f6add12bcbdb2e08b37f2da0574f0f0e8ae3a3e44f"

  # Matches the actual asset name `gh release create`/the release workflow produces
  # (`skyformac-v<version>-macOS.dmg`), not `scripts/release.sh`'s own
  # `Skyformac-<version>.dmg` — update this line too if that script's naming is ever
  # actually used for a real release instead.
  url "https://github.com/giulioroggero/skyformac/releases/download/v#{version}/skyformac-v#{version}-macOS.dmg"
  name "Skyformac"
  desc "Native macOS ZWO ASI astrophotography camera control app"
  homepage "https://github.com/giulioroggero/skyformac"

  # Matches Info.plist's own LSMinimumSystemVersion. A bare symbol already means ">=" —
  # the old ">= :ventura" string form is deprecated by Homebrew.
  depends_on macos: :ventura

  app "skyformac.app"

  zap trash: [
    "~/Library/Preferences/com.giulioroggero.skyformac.plist",
    "~/Library/Saved Application State/com.giulioroggero.skyformac.savedState",
  ]
end

cask "skyformac" do
  version "0.5.1"
  sha256 "69d3c0e59e4ef66af46a055558f80f7e34aae9cf24278ae4e036d15d490d6d8f"

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

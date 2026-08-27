cask "skyformac" do
  version "0.6.0"
  sha256 "26b5a4aa43b5e280d0b592971f9f6fcfa1c43a4cb6df098bb42ada33df3c89cc"

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

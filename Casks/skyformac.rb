cask "skyformac" do
  version "0.3.0"
  sha256 "REPLACE_WITH_REAL_SHA256_OF_THE_DMG" # shasum -a 256 build/release/Skyformac-<version>.dmg

  url "https://github.com/giulioroggero/skyformac/releases/download/v#{version}/Skyformac-#{version}.dmg"
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

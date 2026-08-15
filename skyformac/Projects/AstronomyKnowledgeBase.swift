import Foundation

/// A small, user-editable knowledge base of general astronomy reference facts, folded into every
/// AI request (`CameraManager.assistantContext()`) so a small local model (`qwen3:8b` and similar)
/// has something concrete to reason from instead of guessing — which Messier objects are best in
/// which season, that Venus/Mercury are only ever visible near dawn or dusk, and so on.
///
/// **This is not a substitute for real position calculation.** The app has no live ephemeris —
/// "what's actually above the horizon from this exact location at this exact time" still isn't
/// something these files (or a model reading them) can answer precisely, especially for planets,
/// which genuinely move night to night. What this *does* help with is the model reasoning
/// correctly about the *kind* of object and *roughly* when it's worth looking for, grounded in
/// real facts, rather than inventing a position outright.
///
/// Stored as one `.md` file per topic under a configurable folder (mirroring
/// `EquipmentLibrary`/`ProjectStore`'s own folder-setting pattern) that the user can freely add
/// to, edit, or delete from directly in Finder — nothing about this requires an in-app editor.
enum AstronomyKnowledgeBase {
    struct DefaultFile {
        let name: String
        let content: String
    }

    static let defaultFiles: [DefaultFile] = [
        DefaultFile(name: "messier-and-bright-objects.md", content: messierMarkdown),
        DefaultFile(name: "planets-and-moon.md", content: planetsMarkdown),
    ]

    static func defaultRootDirectory() -> URL {
        AppSettings.resolveRootDirectory(customPath: AppSettings.customKnowledgeBaseDirectoryPath, defaultFolderName: "Skyformac Knowledge")
    }

    /// Writes whichever of `defaultFiles` don't already exist in `directory` — called once at
    /// `CameraManager` startup so a fresh install (or a folder relocated to somewhere empty)
    /// always has real starting reference material, without ever overwriting a file the user has
    /// already edited (that's what `restoreDefaults` is for, explicitly).
    static func ensureDefaultsExist(in directory: URL = defaultRootDirectory(), fileManager: FileManager = .default) {
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        for file in defaultFiles {
            let url = directory.appendingPathComponent(file.name)
            guard !fileManager.fileExists(atPath: url.path) else { continue }
            try? file.content.data(using: .utf8)?.write(to: url)
        }
    }

    /// "Restore Defaults" — overwrites just the known default filenames back to their original
    /// bundled content. Any other `.md` file the user has added to the same folder (or a default
    /// file they've renamed) is left completely alone.
    static func restoreDefaults(in directory: URL = defaultRootDirectory(), fileManager: FileManager = .default) {
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        for file in defaultFiles {
            let url = directory.appendingPathComponent(file.name)
            try? file.content.data(using: .utf8)?.write(to: url, options: .atomic)
        }
    }

    /// Every `.md` file currently in `directory` (the shipped defaults plus anything the user's
    /// added or edited), concatenated for folding into an Ollama prompt. Capped at
    /// `characterLimit` so a large personal knowledge base doesn't balloon every single request
    /// into something a small local model takes forever to work through.
    static func contextText(in directory: URL = defaultRootDirectory(), fileManager: FileManager = .default, characterLimit: Int = 6000) -> String {
        guard let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return "" }
        let markdownFiles = files.filter { $0.pathExtension.lowercased() == "md" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var combined = ""
        for file in markdownFiles {
            guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }
            combined += "\n\n## \(file.deletingPathExtension().lastPathComponent)\n\(content)"
            if combined.count >= characterLimit { break }
        }
        return String(combined.prefix(characterLimit))
    }

    private static let messierMarkdown = """
    # Commonly Observed Deep-Sky Objects — Quick Reference

    General facts to reason from, not exact real-time positions — this app doesn't compute live \
    altitude/azimuth for these, so "visible tonight" still needs an actual planetarium app or \
    almanac to confirm, especially near the horizon.

    - **M13 (Hercules Cluster)** — globular cluster in Hercules. Best placed for northern-\
    hemisphere observers late spring through summer (roughly May-September), when Hercules is \
    high overhead after dark. Bright and resolvable into individual stars in a modest telescope.
    - **M57 (Ring Nebula)** — planetary nebula in Lyra, the same summer season as M13 (Lyra rises \
    alongside Hercules); small and faint, needs a darker sky and moderate magnification.
    - **M27 (Dumbbell Nebula)** — planetary nebula in Vulpecula, also a summer/autumn target, \
    relatively bright for a planetary nebula.
    - **M31 (Andromeda Galaxy)** — best autumn through winter (roughly September-February) for \
    northern-hemisphere observers; naked-eye under dark skies, a large faint glow through \
    binoculars or a short focal length, washed out badly by light pollution or a bright Moon.
    - **M42 (Orion Nebula)** — best in winter (roughly November-February), part of Orion's sword; \
    bright enough to see naked-eye from a suburban sky and rewarding even in short exposures.
    - **M45 (Pleiades)** — open cluster, the same winter season as M42, naked-eye, best in a wide \
    field (binoculars or a short focal length) rather than a narrow high-magnification view.
    - **M51 (Whirlpool Galaxy)** — spring target (roughly March-June), in Canes Venatici near the \
    Big Dipper's handle; faint, needs a dark sky.
    - **M8 (Lagoon Nebula)** — summer target, low in the southern sky for northern-hemisphere \
    observers (part of Sagittarius, near the galactic center) — needs a clear southern horizon.
    - **M56** — small, faint globular cluster in Lyra, same summer season as M13/M57.
    - **M81** — a bright northern-hemisphere galaxy in Ursa Major; circumpolar from many northern \
    latitudes (so technically up much of the year), but best placed in spring.

    General rule of thumb: a deep-sky object is best observed when its own constellation is high \
    in the sky well after dusk and well before dawn — for northern-hemisphere observers that \
    broadly tracks the seasons above. A bright Moon (roughly the week around full Moon) washes \
    out faint nebulae and galaxies far more than it does open/globular star clusters or planets.
    """

    private static let planetsMarkdown = """
    # Planets and the Moon — General Visibility Facts

    None of these positions are computed live by this app — treat this as background knowledge \
    for reasoning about *when in the night* something might be worth checking, not a substitute \
    for looking up tonight's actual positions in a planetarium app or almanac.

    - **Venus** is an inferior planet (its orbit is inside Earth's) — it is never visible in a \
    fully dark sky at midnight. It only ever appears either as an "evening star" low in the west \
    shortly after sunset, or a "morning star" low in the east shortly before sunrise, depending on \
    where it currently is in its orbit relative to Earth and the Sun. It's the brightest object in \
    the sky after the Sun and Moon, so it's unmistakable once above the horizon in twilight.
    - **Mercury** is also an inferior planet, with the same evening-or-morning-twilight-only \
    visibility as Venus, but much fainter and much closer to the Sun in the sky — genuinely \
    difficult to see, generally the hardest naked-eye planet to spot.
    - **Mars, Jupiter, Saturn** are superior planets (orbits outside Earth's) — each can appear \
    anywhere along the ecliptic and can be visible for a large part of the night, including near \
    midnight, especially around its own opposition (Earth passing between it and the Sun — \
    roughly every 1-2 years for Mars, about every 13 months for Jupiter, about every 12.5 months \
    for Saturn), when each is at its brightest and biggest and up essentially all night. Well away \
    from its own opposition, a superior planet may only be up for part of the night, rising later \
    or setting earlier than a full night's observing window.
    - **The Moon** cycles through its full ~29.5-day phase cycle every month: new Moon (not \
    visible, near the Sun in the sky), waxing crescent/quarter/gibbous (visible in the evening \
    sky, setting later each night), full Moon (up essentially all night, opposite the Sun), then \
    waning gibbous/quarter/crescent (visible in the morning sky, rising later each night, before \
    disappearing into the next new Moon). A Moon above the horizon — especially near full — \
    brightens the whole sky and is the single biggest obstacle to seeing faint deep-sky objects; \
    it's actually one of the best times to observe the Moon itself, or bright planets, neither of \
    which is affected by sky brightness the way faint nebulae/galaxies are.
    - General rule: if asked "what's visible tonight" without real position data to go on, it's \
    honest to describe *what kind* of object each candidate is and *roughly when* in the night \
    that kind of object is typically visible (dusk/dawn twilight only, up all night, or only near \
    its own opposition) rather than asserting an exact position or confirming it's above the \
    horizon at a specific time — and to recommend confirming tonight's exact times against a \
    planetarium app or almanac for the observer's exact location.
    """
}

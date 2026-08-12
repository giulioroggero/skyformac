import Foundation

/// One block of in-app Help content: an optional heading, a body paragraph (inline `**bold**`
/// markdown is rendered — `HelpView` builds each into `Text(.init(body))`), and an optional
/// bullet list. Plain structured data rather than a raw Markdown blob specifically so `HelpView`
/// can render it with real SwiftUI typography (headings, spacing, bullets) without pulling in a
/// full Markdown renderer for what's ultimately a fixed, known set of pages.
struct HelpSection {
    /// Stable anchor used by `HelpView`'s `ScrollViewReader` (`CameraManager.showHelp(topicID:
    /// sectionID:)`) and by search-result navigation — `nil` for sections nothing ever needs to
    /// jump to directly (most quick-start/prose sections). Sections a specific in-app control
    /// links to (see `ControlsPanelView`'s `HelpLinkButton` usages) all have one, conventionally
    /// `"setting.<camelCaseName>"`.
    var id: String?
    var heading: String?
    var body: String
    var bullets: [String] = []

    init(id: String? = nil, heading: String? = nil, body: String = "", bullets: [String] = []) {
        self.id = id
        self.heading = heading
        self.body = body
        self.bullets = bullets
    }
}

struct HelpTopic: Identifiable {
    let id: String
    let title: String
    let icon: String
    let sections: [HelpSection]
}

/// One matched section, surfaced by `HelpContent.search(_:)` — enough for `HelpView` to both
/// display a result row (topic + section heading) and jump straight to it (topic ID + section's
/// own anchor `id`, when it has one; sections without an anchor still show up as a search hit,
/// just scroll to the top of their topic instead of the exact paragraph).
struct HelpSearchResult: Identifiable {
    var id: String { "\(topicID)#\(sectionIndex)" }
    let topicID: String
    let topicTitle: String
    let topicIcon: String
    let sectionIndex: Int
    let sectionAnchorID: String?
    /// What to show in the result row — the section's own heading, or (for headerless intro
    /// sections) the topic's title, so a match never renders a blank row.
    let displayTitle: String
    /// A short excerpt of the matched text, for context under `displayTitle` in the result row.
    let snippet: String
}

/// Every page of the in-app Help window (`HelpView`). Content here describes only features that
/// actually exist in this build — see `docs/features.md`/`docs/design-notes.md` for the same
/// information aimed at a developer instead of an end user, and for the honest scoping notes
/// (no full plate solving, no geometric alignment in stacking, etc.) this content summarizes for
/// a general audience without re-deriving them from scratch.
enum HelpContent {
    static let topics: [HelpTopic] = [
        gettingStartedIPhone,
        gettingStartedZWO,
        usingIPhone,
        usingZWO,
        configurationReference,
        deepSkyObservation,
        planetaryObservation,
        troubleshooting,
        qAndA,
        licenseAndCredits,
    ]

    // MARK: - 5-minute quick starts

    static let gettingStartedIPhone = HelpTopic(
        id: "quickstart-iphone",
        title: "5-Minute Start: iPhone",
        icon: "iphone",
        sections: [
            HelpSection(
                body: "The fastest way to see something on screen — no ASI camera required. This uses your iPhone as a webcam via **Continuity Camera**, held up to an eyepiece (afocal projection) or a small telescope adapter."
            ),
            HelpSection(
                heading: "1. Pair the iPhone",
                body: "Your iPhone needs to be signed into the same Apple ID as this Mac, nearby, with Wi-Fi and Bluetooth on (Continuity Camera uses both, even though the actual video goes over Wi-Fi). In the sidebar's **Cameras** list, look under **iPhone / Webcam** — your iPhone should appear automatically once it's discoverable. If it doesn't, click **Add iPhone** for a checklist of the exact pairing prerequisites."
            ),
            HelpSection(
                heading: "2. Connect",
                body: "Click **Connect** next to your iPhone's name. The live view should appear within a couple of seconds, labeled \"Streaming\" at the top of the preview."
            ),
            HelpSection(
                heading: "3. Point it at something bright first",
                body: "Before hunting for anything faint, point the phone at the Moon, a streetlight, or just daytime sky. This confirms focus and framing work before you're fumbling with a dim target in the dark."
            ),
            HelpSection(
                heading: "4. Lock the focus",
                body: "Once it looks sharp, go to Camera Controls → **iPhone / Webcam** and turn on **Lock Focus** — otherwise the phone's own autofocus keeps hunting and refocusing away from the telescope's focal plane on its own."
            ),
            HelpSection(
                heading: "5. Try the zoom",
                body: "Pinch-to-zoom (trackpad) or double-click the preview to reset it. For steadier, more precise zooming, click the expand icon (top-right of the preview) for **Full Screen** — it adds an explicit zoom slider."
            ),
            HelpSection(
                heading: "What's next",
                body: "For actual imaging, see **Using: iPhone** for afocal projection tips, or jump to **Planetary Observation** (an iPhone at an eyepiece is a genuinely good lunar/planetary setup)."
            ),
        ]
    )

    static let gettingStartedZWO = HelpTopic(
        id: "quickstart-zwo",
        title: "5-Minute Start: ZWO Camera",
        icon: "camera.aperture",
        sections: [
            HelpSection(
                body: "Getting a real ASI camera from box to live view."
            ),
            HelpSection(
                heading: "1. Connect and rescan",
                body: "Plug the camera into USB (a direct port or a powered hub — some ASI cameras draw more current than an unpowered hub provides). In the sidebar's **Cameras** list, click the refresh icon, or use **Camera > Rescan Cameras** (⌘R). Your camera should appear under **Cameras**."
            ),
            HelpSection(
                heading: "2. Connect",
                body: "Click **Connect**. The status badge above the preview will read \"Connecting…\" then \"Streaming\". This can take a moment — the camera's own USB handshake takes real time, and the app now stays responsive while it happens instead of freezing."
            ),
            HelpSection(
                heading: "3. Trust the defaults, then adjust",
                body: "On a fresh connection this app sets **Gain to 5** and auto-stretches the display from the very first live frame's own histogram — deliberately conservative starting points for a real night sky, not the camera's own factory defaults (which are often tuned for a bright test bench, not a dark sky). If the view still looks too dim or too bright, see **Configuration Reference** for what Gain, Exposure, and the Black/White Point sliders each actually do."
            ),
            HelpSection(
                heading: "4. Pick a starting mode",
                body: "Use the sidebar's vertical tab strip on the right: **Camera** for raw hardware controls, **Improve** for denoise/sharpen/AI features, **Advanced** for focus assist, stacking, calibration, and the rest of the imaging workflow.",
                bullets: [
                    "Deep sky target (nebula, galaxy, star cluster): see **Deep Sky Observation**.",
                    "Moon or a planet: see **Planetary Observation**.",
                ]
            ),
            HelpSection(
                heading: "If nothing shows up",
                body: "See **Troubleshooting** — \"No ZWO Cameras Found\" and \"the image is black\" are both covered there with the actual, specific fixes."
            ),
        ]
    )

    // MARK: - How to use each source

    static let usingIPhone = HelpTopic(
        id: "using-iphone",
        title: "How to Use: iPhone",
        icon: "iphone.gen3",
        sections: [
            HelpSection(
                heading: "What this actually is",
                body: "The iPhone path uses AVFoundation's **Continuity Camera** — the same feature that lets an iPhone act as a webcam in FaceTime or Photo Booth. skyformac just treats it as another live video source, running the same debayer/histogram/live-stacking pipeline a ZWO camera uses, just fed RGB24 frames instead of RAW sensor data."
            ),
            HelpSection(
                heading: "Setup",
                body: "Requirements: both devices signed into the same Apple ID, Wi-Fi and Bluetooth on for both, and the iPhone nearby and unlocked (or at least awake). Click **Add iPhone** in the Cameras sidebar for a live checklist rather than guessing at Apple's own pairing requirements."
            ),
            HelpSection(
                heading: "Afocal projection",
                body: "Holding a phone camera up to an eyepiece — \"afocal projection\" — is the practical way to use this. A basic phone-to-eyepiece adapter clamp (widely available, inexpensive) makes this dramatically more stable than hand-holding.",
                bullets: [
                    "Focus the telescope normally for your eye first, then attach the phone.",
                    "Zoom the phone in slightly (either the iPhone's own optical zoom before framing, or skyformac's pinch-zoom afterward) to reduce the dark \"tunnel\" vignette around the eyepiece's field of view.",
                    "A slower (higher f-ratio) eyepiece/telescope combination generally affords more eye relief and an easier afocal setup than a very fast one.",
                ]
            ),
            HelpSection(
                id: "setting.lockFocus", heading: "Fixing the focus",
                body: "The iPhone/webcam's own continuous autofocus actively fights afocal projection — it keeps hunting for a \"normal\" subject distance and refocuses away from the telescope's actual focal plane, so the view drifts in and out of focus on its own. In Camera Controls → **iPhone / Webcam**, once the image looks sharp, turn on **Lock Focus** — it freezes focus at whatever position it currently sits at, rather than fighting it every few seconds."
            ),
            HelpSection(
                id: "setting.iphoneNightMode", heading: "Night Mode (10 sec / 60 sec)",
                body: "Also under Camera Controls → **iPhone / Webcam**. There's no controllable hardware exposure on this source, so this isn't a literal single long sensor exposure — instead it accumulates that many seconds of live frames via the same running-average technique **Live Stack** uses, then freezes on the brighter result. That's the same computational multi-frame-stacking mechanism Apple's own iPhone Night Mode actually uses internally, just triggered from here instead of the iPhone's own Camera app. **Lock Focus** first — the accumulation is worthless if focus drifts partway through it."
            ),
            HelpSection(
                heading: "What's still different from a real ASI camera",
                body: "\"Single Exposure\" on this source just freezes the current live frame rather than taking a real timed exposure (there's a warning label in the UI when this applies) — Night Mode above is the closest equivalent to an actual long exposure. Dark/flat calibration and Smart Exposure are unavailable: they need a controllable exposure and a bias frame, which a webcam feed doesn't have. Gain, Flip, and the other per-camera hardware controls in **Configuration Reference** don't apply either — what you get is whatever the iPhone's own camera is already doing."
            ),
            HelpSection(
                heading: "What still works well",
                body: "Live stacking, Lucky Imaging, Focus Assist, Planetary Auto-Center/Crop, Polar Alignment, all the Image Enhancement and AI Suite features, and export all work the same as with a ZWO camera — they all operate on whatever frames arrive, regardless of source."
            ),
        ]
    )

    static let usingZWO = HelpTopic(
        id: "using-zwo",
        title: "How to Use: ZWO Camera",
        icon: "camera.aperture",
        sections: [
            HelpSection(
                heading: "Connecting",
                body: "Plug in over USB, rescan (refresh icon in the Cameras list, or ⌘R), then **Connect**. If more than one ZWO camera is attached, each appears as its own entry — connect the one you want to use; the others stay available to switch to later."
            ),
            HelpSection(
                heading: "RAW8 vs RAW16",
                body: "If your camera supports both, a **Format** picker appears in the toolbar. RAW8 (1 byte/pixel) streams faster and is generally the right choice for live-rate planetary/lunar work; RAW16 (2 bytes/pixel, real 10-16 bit dynamic range depending on the sensor) is the right choice for deep-sky work where dynamic range actually matters. Switching format briefly restarts the video stream."
            ),
            HelpSection(
                heading: "Color vs mono cameras",
                body: "Color (Bayer-matrix) cameras are debayered automatically for on-screen display. Mono cameras skip that step entirely — what you see is the raw sensor luminance."
            ),
            HelpSection(
                heading: "Live Exposure vs Single Exposure — these are genuinely two different things",
                body: "**Live Exposure** (in the Camera Controls tab's dynamic control list) sets the exposure length for the continuous live-view video stream — this is what you're adjusting while just watching the live feed. **Single Exposure** (its own section, also in Camera Controls) triggers one dedicated timed capture — the camera briefly stops streaming, takes one exposure of exactly the length you set (which can be far longer than any live-view frame), then either shows you that still frame or, if you click **Resume Live View**, goes back to streaming. Use Single Exposure for an actual deep-sky sub-exposure; use Live Exposure just to get a comfortable live view for framing/focusing."
            ),
            HelpSection(
                heading: "Cooled cameras",
                body: "If your camera has active cooling, **Cooler On**, **Target Temp**, and a cooler-power/temperature readout appear in the dynamic controls list. Cooling reduces dark current (thermal noise) — worth turning on for any exposure of more than a few seconds."
            ),
            HelpSection(
                heading: "Disconnecting",
                body: "**Camera > Disconnect** (⌘K), or reconnect a different camera directly — no need to disconnect first."
            ),
        ]
    )

    // MARK: - Configuration reference

    static let configurationReference = HelpTopic(
        id: "config-reference",
        title: "Configuration Reference",
        icon: "slider.horizontal.3",
        sections: [
            HelpSection(
                body: "What every control actually does, organized by where you find it in the sidebar's four tabs."
            ),
            HelpSection(heading: "Camera Controls tab — the sensor itself",
                body: "These change what the camera hardware does — nothing here is a display effect."),
            HelpSection(
                id: "setting.gain", heading: "Gain",
                body: "Amplifies the sensor's signal before it's read out, at the cost of amplifying noise too. Low gain (this app defaults to 5) is cleaner but needs longer exposures for the same brightness; high gain shows something with a much shorter exposure but grainier. The slider gives most of its width to 0-20 specifically, since that low range is where deep-sky imaging actually lives and a linear slider over the camera's full range (often 0-500+) would make fine adjustment there nearly impossible.",
                bullets: ["Example: gain 0-10 for a bright target with a long exposure (minutes), gain 100+ for a quick, noisy live-view peek at something faint."]
            ),
            HelpSection(
                id: "setting.liveExposure", heading: "Live Exposure",
                body: "The continuous video stream's per-frame exposure length, from microseconds to seconds. Longer = brighter but slower-updating live view; shorter = snappier live view but dimmer.",
                bullets: ["Example: 10-50ms for a responsive live view on the Moon/planets; 0.5-2s for a usable live view on a dim deep-sky target (expect a slow, choppy feed at that length — that's normal, it's still just for framing)."]
            ),
            HelpSection(
                id: "setting.singleExposure", heading: "Single Exposure",
                body: "Its own section, not a dynamic control — one dedicated timed capture, independent of Live Exposure; see **Using: ZWO Camera** for exactly how the two differ.",
                bullets: ["Example: 30-300 seconds for one deep-sky sub-exposure at low gain."]
            ),
            HelpSection(
                id: "setting.flip", heading: "Flip",
                body: "None / Horizontal / Vertical / Both. Corrects orientation for whatever mirror/prism your optical train introduces (a star diagonal, an off-axis guider, etc.) so the live view matches what you'd see by eye."
            ),
            HelpSection(
                id: "setting.genericControl", heading: "Offset/Brightness (and other generic sliders)",
                body: "A raw min/max control for whatever else your specific camera model reports (bandwidth, gamma, white balance on color cameras, etc.); hover any control for its exact description from the camera's own SDK."
            ),
            HelpSection(
                id: "setting.binningModes", heading: "Hardware Bin / High Speed Mode / Mono Bin",
                body: "On/off toggles. Binning combines adjacent pixels for a brighter, lower-resolution image (useful in poor seeing or for faster readout); High Speed Mode trades some image quality for a faster frame rate; Mono Bin (color cameras only) bins in a way that reduces color-grid artifacts specifically when binning a Bayer sensor."
            ),
            HelpSection(
                id: "setting.cooler", heading: "Cooler On / Target Temp",
                body: "Cooled cameras only — see **Using: ZWO Camera**. Cooling reduces dark current (thermal noise); worth turning on for any exposure of more than a few seconds."
            ),
            HelpSection(
                id: "setting.droppedFrames", heading: "Dropped Frames",
                body: "ZWO cameras only. How many frames the camera captured but this app failed to read off the USB connection in time (`ASIGetDroppedFrames`), refreshed every couple of seconds while connected. A rising count during live view usually means Bandwidth (if your camera model reports it, under the generic sliders above) is set too high for your USB port/cable/hub — lowering it trades a little throughput for reliability."
            ),
            HelpSection(
                id: "setting.gainOffsetPresets", heading: "Gain/Offset Presets",
                body: "ZWO cameras only, and only shown for models the SDK reports these for. ZWO's own recommended Gain/Offset reference points for the specific connected camera — the same numbers SharpCap's gain presets and ZWO's own ASICap tool show — with a one-tap Apply that writes directly to the Gain/Offset controls above.",
                bullets: [
                    "Highest Dynamic Range is always Gain 0 by definition (dynamic range is best at the lowest gain) — only the recommended Offset for that setting varies by camera model.",
                    "Unity Gain (where 1 ADU of the recorded image corresponds to 1 photoelectron captured) only reports a recommended Offset — the ZWO SDK doesn't separately report which Gain value that actually is for a given model, so Apply leaves Gain untouched rather than guessing at one.",
                    "Lowest Read Noise reports both a Gain and an Offset — past this gain, further increases mostly amplify noise rather than meaningfully improving signal.",
                    "\"Frequently-used gain steps,\" when shown, are a simpler Low/Middle/High gain shortcut some camera models (mainly ones with a dual-conversion-gain sensor) expose — High matches Lowest Read Noise's own Gain/Offset for cameras that report both.",
                ]
            ),
            HelpSection(
                id: "setting.exportedFiles", heading: "Exported Files",
                body: "A running history of every single-frame export, continuous-recording folder, and SER video this app has written — persists across relaunches, so \"where did that go\" has an answer weeks later, not just this session. **Open File…** opens any FITS/PNG/TIFF/JPEG file directly, history or not — or just drag a file onto the window from Finder.",
                bullets: [
                    "Opening a FITS file re-renders it through this app's own debayer/stretch pipeline, with its own Black Point/White Point sliders and a \"Debayer as color\" override (with a Bayer pattern picker) for a file whose color metadata doesn't match what you actually want — useful for a file from another tool, or one written before this app started saving that metadata.",
                    "PNG/TIFF/JPEG files just display directly — they're already a finished picture, no debayering needed.",
                    "`.ser` recordings and recording folders aren't viewable in this window — \"Reveal in Finder\" is the path to AutoStakkert!3/PIPP/whatever actually processes them, the same scope line **Record SER Video** (Planetary tab) already draws.",
                    "This is a viewer, not an editor — no re-stacking, no plate solving, no saving changes back. For real processing, hand the file to a dedicated tool (PixInsight, Siril, AutoStakkert!3).",
                ]
            ),
            HelpSection(heading: "Improve tab — display-only effects",
                body: "Nothing here changes the sensor or what gets exported/recorded as raw data (except where noted) — these change how the live view *looks*."),
            HelpSection(
                id: "setting.denoise", heading: "Denoise",
                body: "A real-time bilateral filter (smooths noise while trying to preserve edges). Effect: a visibly smoother, less speckly live view, especially useful at high gain."
            ),
            HelpSection(
                id: "setting.waveletSharpening", heading: "Wavelet Sharpening (+ Amount)",
                body: "Multiscale sharpening in the style of RegiStax, good for pulling out fine lunar/planetary detail. Effect: crisper detail, but pushed too high it introduces a harsh, ringing look around edges — start low and increase gradually."
            ),
            HelpSection(
                id: "setting.liveGPU", heading: "Live GPU Enhancement Controls",
                body: "A separate, independent three-stage pipeline (GPU renderer only): temporal denoise (blends across frames — smoother but reacts more slowly to real motion), spatial denoise (a second, separately-tunable bilateral pass), and a non-linear (arcsinh) contrast stretch layered on top of the base Black/White Point.",
                bullets: ["**Auto-Stretch Safety Lock** sets the stretch from the current frame's own histogram — a good starting point before hand-tuning."]
            ),
            HelpSection(
                id: "setting.aiSuite", heading: "AI & Machine Learning Suite",
                body: "**Satellite/Aircraft Trail Masking** — Vision-detected streaks are excluded from the live stack, per-frame, on both the CPU and GPU render paths. A masked pixel on one frame still contributes normally to every *other* frame — its final average is over fewer frames than the rest of the image, not the same count with a zeroed-out value mixed in. Takes priority over **Reduce Drift** if both are on at once (the panel says so); combining per-pixel masking with drift alignment isn't supported yet. **Cloud Cover & Drift Sentinel** — watches for a sudden sky-brightness change, pauses active recording, and sends a notification."
            ),
            HelpSection(
                id: "setting.disableImprovements", heading: "Disable All Improvements",
                body: "One checkbox that turns everything in this tab off at once, for isolating whether an enhancement is causing a visual problem, or just to see the camera's own unmodified output."
            ),
            HelpSection(heading: "Planetary tab — the small-ROI, high-FPS, burst/video workflow",
                body: "Focus Assist appears here too (also in Deep Sky) — it genuinely serves both, so it isn't locked to one tab over the other."),
            HelpSection(
                id: "setting.focusAssist", heading: "Focus Assist",
                body: "Detects point sources (stars) and shows a sharpness/HFD readout to help focus. **Recognize Stars** additionally matches detected stars against a small built-in catalog and, once confident, overlays real catalog objects — this is real (if small-scale) astrometry, not a full plate solver."
            ),
            HelpSection(
                id: "setting.planetaryAutoCenter", heading: "Planetary Auto-Center",
                body: "Tracks the largest bright disk in view and can auto-crop to a small region around it, for keeping a fast-moving planet centered during high-frame-rate capture."
            ),
            HelpSection(
                id: "setting.planetaryPresets", heading: "Planetary Presets",
                body: "ZWO cameras only. One tap sets RAW8, a small **Capture ROI**, and a safe starting exposure/gain for a specific bright target (Saturn, Jupiter, Mars, Venus, or the Moon), tuned around a modern ~2µm-pixel planetary camera (e.g. ASI678MC) behind a modest f/10-f/12 Maksutov/SCT — that pixel-scale/focal-ratio pairing needs no Barlow lens to reach a good sampling rate.",
                bullets: [
                    "Starts exposure/gain at the *low* end of each target's recommended range on purpose — raise Gain first (planetary cameras like the ASI678MC have a High Conversion Gain threshold, 182 on that model, where read noise drops meaningfully; Saturn/Jupiter/Mars presets start there or above), then fine-tune Live Exposure, watching the histogram (under the live preview) until its peak sits in the preset's target percentage — the app can't automate that last step, since it depends on the actual night's seeing/transparency, not just which target this is.",
                    "Jupiter's own rotation blurs fine cloud detail in videos longer than ~2 minutes — its preset's shorter recommended duration reflects that, not a hardware limit.",
                    "Sets the **Record SER Video** duration slider to the target's recommended length too — still adjustable afterward, and recording itself is a separate manual step.",
                ]
            ),
            HelpSection(
                id: "setting.acquisitionWizard", heading: "Acquisition Wizard (⌘⇧W)",
                body: "Pick a target — Moon, Venus, Mars, Jupiter, Saturn, or a curated deep-sky list (M13, M56, M31, M42, M45) — and see a recommended setup: mode (Live Stack, Lucky Imaging, or both), ROI, gain, exposure, and Reduce Drift/Smart Live Stack. Edit anything before applying, then **Apply Setup** to configure the camera in one step.",
                bullets: [
                    "The Moon is the one target set up for *both* Live Stack and Lucky Imaging at once — high-resolution crater/terminator detail from a burst, plus a lower-noise full-disk or earthshine shot from the running average. Every other planet is Lucky-Imaging-only; every deep-sky object is Live-Stack-only with Reduce Drift on by default (a planetary burst is over in seconds, so mount drift barely matters there — deep-sky integration runs long enough for it to actually accumulate into trailing).",
                    "**Save Preset…**/**Load Preset…** round-trip a setup to/from its own JSON file — one file per preset, so a favorite setup for a specific object under your specific telescope/camera pairing survives beyond one session, and can be shared or backed up like any other file.",
                    "Doesn't auto-start a Lucky Imaging burst or SER recording — those stay a deliberate manual step after Apply, so framing/focus gets confirmed against the actual target first rather than wasting a burst on whatever happened to be in frame.",
                    "ZWO cameras only — an iPhone/webcam source has none of the ROI/exposure/gain hardware controls a setup applies.",
                ]
            ),
            HelpSection(
                id: "setting.acquisitionPresetStandalone", heading: "Save/Load Preset (without the Wizard)",
                body: "Saving or loading a preset doesn't need the Wizard sheet open at all — **Save Preset…** (⌘⇧S) snapshots *whatever's currently configured* (gain, exposure, ROI, Live Stack/Reduce Drift/Smart Live Stack — read straight from the live camera state, not a target's recommendation) into its own file; **Load Preset…** (⌘⇧L) loads a file and applies it immediately. Available from the **Camera** menu, from an \"Acquisition\" section in the Cameras sidebar itself right under the connected camera, and (Wizard/Load only) right beside that camera's own **Disconnect** button.",
                bullets: [
                    "A preset saved this way has no specific target — reopening it in the Wizard later shows it as an unrecognized target (settings still apply normally), since it's a snapshot of a moment, not a recommendation for a specific object.",
                    "Doesn't carry a Lucky Imaging burst-count or SER-duration recommendation — those two live in the Controls panel's own state, not tracked at the level this snapshot reads from.",
                    "**Reset to Default**, in the same \"Acquisition\" section, is the opposite direction — full sensor ROI, a safe starting gain, and every capture-affecting toggle (Live Stack, Lucky Imaging, Reduce Drift, Dark/Flat correction, Focus Assist, Planetary tracking/crop, Image Enhancement, the AI Suite) plus any active recording, all back off in one click, undoing a Wizard preset or manual adjustment without hunting down each toggle individually.",
                ]
            ),
            HelpSection(
                id: "setting.captureROI", heading: "Capture ROI (higher FPS)",
                body: "ZWO cameras only. Requests a smaller-than-full-sensor region from the camera itself (`ASISetROIFormat`) rather than just cropping the display — less data has to be read off the sensor per frame, which directly increases the achievable frame rate. Restarts the live stream to take effect.",
                bullets: [
                    "This is the standard \"small ROI, high FPS\" planetary/lunar lucky-imaging technique — e.g. a 640×480 or 800×600 region can push frame rate well past what the full sensor allows, at the cost of field of view (fine for a target — the Moon or a planet — that's small in the frame anyway).",
                    "Persists across Single Exposure and dark/flat calibration captures too, not just live view, until reset back to Full Sensor.",
                    "\"Custom size & center\" lets you type any width/height and any center position on the sensor — not just the two quick presets. The ROI is genuinely centered there (`ASISetStartPos`), so a target framed anywhere in the full-sensor preview is still in-frame after cropping — \"Center on Sensor\" resets to the sensor's own middle.",
                    "The live preview's own refresh rate is capped independently (~30fps) so a very small, very-high-frame-rate ROI can't flood the display pipeline with more frames than it can keep up with — recording (SER/FITS) and Lucky Imaging still process every single real frame regardless, only the visible preview is rate-limited.",
                    "The status line below the presets is a read-back confirmation from the camera itself (`ASIGetStartPos`), not just a repeat of what was requested — if the camera clamped the position somewhere unexpected (near the sensor's edge, for instance), that shows up here instead of being silently trusted.",
                ]
            ),
            HelpSection(
                id: "setting.serRecording", heading: "Record SER Video (planetary/lunar)",
                body: "ZWO cameras only. Writes every incoming frame, undiscarded, into a single `.ser` video file for a set duration — the standard raw-video container AutoStakkert!3, PIPP, and similar dedicated stacking tools expect, so their own frame alignment and best-frame selection has the full, unfiltered video to work with.",
                bullets: [
                    "The classic workflow this exists for: set a small **Capture ROI** above for high FPS, a short Live Exposure with Gain adjusted so the histogram sits around 50-60%, record a few minutes of SER video, then align/stack the sharpest 20-30% of frames in AutoStakkert!3 and sharpen with wavelets in RegiStax or AstroSurface — none of which skyformac itself does; it produces the raw input those tools expect.",
                    "Different from **Record to Disk** (Deep Sky tab): that one gates on a sharpness threshold and writes individual FITS files for unattended, self-curating recording. This one writes everything, because the whole point is handing a dedicated tool the complete video to make its own, better-informed frame selection from.",
                ]
            ),
            HelpSection(
                id: "setting.luckyImaging", heading: "Lucky Imaging",
                body: "Captures a burst, scores every frame's sharpness, and stacks only the sharpest fraction — the classic technique for beating atmospheric seeing on the Moon/planets. Works with a ZWO camera or an iPhone/webcam source equally."
            ),
            HelpSection(
                id: "setting.disablePlanetary", heading: "Disable All Planetary Features",
                body: "Turns off Focus Assist and Planetary tracking/crop in one click — for isolating whether one of them is causing a problem, or just to fall back to a plain, unmodified live view."
            ),
            HelpSection(heading: "Deep Sky tab — the long-exposure, many-subs workflow",
                body: "Focus Assist also appears here (see Planetary above) — it genuinely serves both, so it isn't locked to one tab over the other."),
            HelpSection(
                id: "setting.smartExposure", heading: "Smart Exposure",
                body: "Measures your camera's actual read noise (from a real bias frame) and the current sky brightness (from a short test exposure), then recommends a sub-exposure length. ZWO cameras only."
            ),
            HelpSection(
                id: "setting.polarAlignment", heading: "Polar Alignment",
                body: "A 2-capture, rotate-the-mount-90°-between-them procedure that solves your mount's actual mechanical rotation center from matched stars. Not a full plate solver — it tells you where the axis is pointing relative to the frame, not your absolute alt/az error in degrees."
            ),
            HelpSection(
                id: "setting.st4Guiding", heading: "ST4 Guiding",
                body: "ZWO cameras with a real ST4 guide port only (shown/hidden automatically based on what the connected camera reports) — sends a single pulse-guide correction in one of four directions for a set duration, then turns it back off, on the camera's own ST4 output.",
                bullets: [
                    "**Untested against real guiding hardware.** The underlying `ASIPulseGuideOn`/`ASIPulseGuideOff` calls are wired up exactly as the ZWO SDK documents, but this project has never had an actual ST4 cable connected to a real mount to confirm a correction actually happens end to end — treat this as plumbing ready for verification, not a proven feature, until checked against real hardware.",
                    "This is a single manual pulse, not an autoguiding loop — there's no star-tracking feedback here deciding *when* or *how much* to correct, unlike PHD2 or similar dedicated guiding software. Useful as a wiring sanity check (\"does pressing North actually nudge the mount north\"), not a guiding system on its own.",
                ]
            ),
            HelpSection(
                id: "setting.calibration", heading: "Calibration (Dark/Flat)",
                body: "Capture and manage named dark frames (lens capped, removes fixed-pattern noise/hot pixels) and flat frames (even illumination, corrects vignetting/dust shadows), and toggle whether the active one is applied. ZWO cameras only.",
                bullets: ["Each frame's own trash icon removes it individually; \"Clear All\" next to the enable toggle removes every dark (or every flat) and turns that correction off in one action."]
            ),
            HelpSection(
                id: "setting.liveStack", heading: "Live Stack",
                body: "A running average of incoming frames. By default no star alignment — this assumes a tracked, stationary mount, the same scoping SharpCap's basic live-stack mode uses. See **Reduce Drift** below for basic alignment. Exporting FITS/PNG/TIFF (Export, above) while this is on exports the actual stacked average, on both the GPU and CPU render paths — not just whatever the latest single frame happened to be. Works for an iPhone/webcam source too — it always accumulates on the CPU running-average regardless of the GPU/CPU toggle above, since the GPU accumulator only supports a ZWO camera's mono sensor data; the live preview still renders on the GPU either way. \"Save Stacked Image…\" saves the stack exactly as it looks right now as a PNG, without needing the Export section below. \"Pause\" freezes the stack exactly as it is — new frames stop being added, but nothing already stacked is lost — so you can actually look at the current result (focus, whether alignment is holding up) before deciding to keep going; \"Resume\" continues right where it left off. \"Reset\" is different — it discards the stack and starts over."
            ),
            HelpSection(
                id: "setting.liveStackDriftReduction", heading: "Reduce Drift (align to a locked star)",
                body: "GPU renderer only. Locks onto the brightest star in the first stacked frame, then re-locates it every subsequent frame and shifts that frame back (sub-pixel) to where the lock started before adding it into the running sum — so a mount that isn't tracking perfectly (an alt-azimuth mount, for example, which drifts and slowly field-rotates even when roughly following a target) doesn't smear stars into short trails across the stack the way plain Live Stack alone would.",
                bullets: [
                    "This is single-star translation alignment only — it corrects drift (the whole frame shifting), not field rotation (an alt-az mount's other real effect over a longer session), and it isn't full multi-star geometric registration the way a dedicated stacking tool's alignment is. It's built for real mount tracking error against a star field — genuinely point-like sources — not for stabilizing a handheld camera panned across an ordinary scene with no real point source in it at all.",
                    "The lock-on point is measured against the search window's own local sky background (not raw pixel brightness) — a plain brightness-weighted centroid gets swamped by the sky itself, which covers far more pixels than the star does, and ends up barely tracking anything.",
                    "The initial lock rejects isolated hot/warm sensor pixels — a real star's blur spreads over several pixels, a hot pixel doesn't, so the search looks for that spread rather than just the single brightest pixel in the frame.",
                    "It also rejects a lock candidate that turns out to be a huge overexposed area (a stray light source in frame, for instance) rather than a real star's small point-spread footprint — locking onto that would track the blob's edge, not star motion.",
                    "If the locked star drifts further than the search window can follow in one frame — or is briefly lost behind a passing cloud — that frame re-scans the whole frame to re-acquire, still measured against the original lock so alignment stays consistent, instead of derailing for the rest of the session.",
                    "Turning this on or off, or resetting Live Stack, always starts a fresh lock on the next frame — a lock from a previous session or target is never reused.",
                ]
            ),
            HelpSection(
                id: "setting.smartLiveStack", heading: "Smart Live Stack (Autopilot)",
                body: "Turns Live Stack from a plain running average into a self-curating one: every incoming frame is scored for sharpness (the same GPU scorer Record to Disk's quality gate and Lucky Imaging use), and only folded into the stack if it's at least the \"Quality floor\" fraction as sharp as the best frame this session has seen, or discarded if Cloud Sentinel currently reports an alert. Turns Live Stack on automatically when enabled.",
                bullets: [
                    "This live-curates instead of the traditional \"record everything, curate afterward\" workflow (PixInsight's SubframeSelector, AutoStakkert!3's quality graph) — the stack you're watching build is already the curated one, frame by frame, as it happens.",
                    "A frame that can't be scored at all (an RGB24 webcam/iPhone frame — the GPU scorer only supports ZWO mono RAW8/RAW16) is always kept rather than silently excluded from a stack it can't judge.",
                    "The \"Estimated SNR gain from 20 more frames\" readout is real math (stacking SNR scales with the square root of frame count), not a guess — a falling percentage over the course of a session means each additional stretch of frames is helping less, a genuine \"is this still worth it\" signal for a long unattended run.",
                    "The kept/rejected counts and quality floor both reset whenever Live Stack itself resets — a fresh session starts its own new \"best frame so far\" baseline rather than comparing against a previous target's.",
                ]
            ),
            HelpSection(
                id: "setting.recordToDisk", heading: "Record to Disk",
                body: "Continuously writes frames as FITS, discarding any below a sharpness threshold before they hit disk, with a disk-space guardrail."
            ),
            HelpSection(
                id: "setting.disableDeepSky", heading: "Disable All Deep Sky Features",
                body: "Same one-click reset shape as Improvements'/Planetary's equivalent checkboxes, plus it stops any active disk recording."
            ),
            HelpSection(heading: "Elsewhere in the app"),
            HelpSection(
                id: "setting.blackWhitePoint", heading: "Black Point / White Point",
                body: "Under the histogram — the base display stretch: what raw sensor range maps to on-screen black vs white. Auto-set from the first live frame's histogram on connect. Use the histogram's own **Zoom** slider for fine (0.01%) adjustment."
            ),
            HelpSection(
                id: "setting.gpuCpuToggle", heading: "GPU / CPU toggle",
                body: "Toolbar, ⌘M — switches the render path. GPU (Metal) is the default and faster; CPU is a fallback that produces the same result more slowly."
            ),
            HelpSection(
                id: "setting.nightModeApp", heading: "Night Mode (app-wide red tint)",
                body: "⌘⇧N — tints the whole app red-only, to preserve dark adaptation. Not the same as the iPhone/webcam source's own **Night Mode** capture feature — see **How to Use: iPhone**."
            ),
            HelpSection(
                id: "setting.allSkyMonitor", heading: "All-Sky Monitor",
                body: "⌘⇧A — an independent picture-in-picture feed from a second webcam/iPhone, for watching clouds or cables while the main camera does deep-sky work."
            ),
        ]
    )

    // MARK: - Observation guides

    static let deepSkyObservation = HelpTopic(
        id: "deep-sky",
        title: "Deep Sky Observation",
        icon: "sparkles",
        sections: [
            HelpSection(
                body: "Nebulae, galaxies, star clusters — faint, extended targets that need long exposure and a stable, tracked mount. A ZWO camera is strongly preferable here; the iPhone path can frame a target but can't take a real long exposure."
            ),
            HelpSection(
                heading: "Recommended setup",
                bullets: [
                    "Sidebar → **Advanced** tab for calibration/stacking, **Camera Controls** for exposure/gain.",
                    "Low gain (0-20 range — the default of 5 is a reasonable starting point) and long exposure — minimize noise, since you have time on your side.",
                    "Capture a dark frame (lens capped, same exposure length you'll actually use) and, ideally, a flat frame, and enable both under **Calibration (Dark/Flat)**.",
                    "Enable **Live Stack** for a running average as frames come in, watching the signal build up in real time. Remember: no star alignment — your mount needs to actually be tracking.",
                    "If your mount's polar alignment is uncertain, run **Polar Alignment** first — its 2-capture procedure shows you which way to nudge the mount's axis.",
                    "Use **Single Exposure** for individual sub-exposures if you want full control over each one rather than relying on Live Stack's running average.",
                ]
            ),
            HelpSection(
                heading: "If the image looks black or washed out",
                body: "See **Troubleshooting** — this is almost always the display stretch (Black/White Point) or gain being mismatched to how dim the actual signal is, not a broken camera."
            ),
        ]
    )

    static let planetaryObservation = HelpTopic(
        id: "planetary",
        title: "Planetary Observation",
        icon: "moon.stars",
        sections: [
            HelpSection(
                body: "The Moon and planets are bright, small, and best beaten by capturing fast and keeping only the sharpest frames — the opposite strategy from deep sky. This is also the strongest use case for the iPhone/afocal path."
            ),
            HelpSection(
                heading: "Recommended setup",
                bullets: [
                    "Sidebar → **Camera Controls** for exposure/gain, **Advanced** tab for tracking/Lucky Imaging.",
                    "Short exposure, higher gain than you'd ever use for deep sky — you're freezing atmospheric turbulence, not chasing faint signal.",
                    "RAW8 format (ZWO cameras) for the fastest frame rate, unless you specifically need RAW16's dynamic range.",
                    "Enable **Planetary Auto-Center** (Track Disk) to keep a moving/drifting target centered; add **Auto-Crop to ROI** for a smaller, faster-to-read-out region once tracking is confirmed working.",
                    "Run **Lucky Imaging**: set a burst count, **Start Burst**, then once complete, choose what fraction of the sharpest frames to keep and **Stack** them.",
                    "**Wavelet Sharpening** (Improve tab) is genuinely useful here for pulling out fine surface detail — start with a low Amount and increase gradually.",
                ]
            ),
            HelpSection(
                heading: "With an iPhone",
                body: "Afocal projection (see **How to Use: iPhone**) plus Lucky Imaging is a legitimately good combination — the phone's higher native resolution and Continuity Camera's stability compensate for the lack of hardware exposure control."
            ),
        ]
    )

    // MARK: - Troubleshooting

    static let troubleshooting = HelpTopic(
        id: "troubleshooting",
        title: "Troubleshooting",
        icon: "wrench.and.screwdriver",
        sections: [
            HelpSection(
                heading: "\"No ZWO Cameras Found\"",
                body: "Check the physical USB connection first — a direct port or a powered hub, not an unpowered hub some cameras can't draw enough current from. Click the refresh icon in the Cameras list (or ⌘R). If it's still not found, unplug/replug and rescan again; USB camera enumeration occasionally needs a fresh connection event."
            ),
            HelpSection(
                heading: "The image is solid black (or solid white)",
                body: "This is almost always the display stretch, not a broken camera or a broken capture.",
                bullets: [
                    "Check **Black Point / White Point** under the histogram — a real sensor's actual signal usually occupies a small slice of its full digital range, so if these are set too wide (or too narrow, on the wrong side of your signal), the image can round to solid black or solid white even though real data is arriving. On a fresh connection this app auto-stretches from the first live frame, but if you've since dragged those sliders far from that, drag them back toward the middle, or watch the histogram plot itself (it shows exactly where your signal actually sits).",
                    "Check **Gain** and **Live Exposure** — too low for the current sky brightness looks black; wildly too high can look washed-out white.",
                    "If you're on the **Improve** tab, try **Disable All Improvements** — a Live GPU Enhancement Controls stretch left over from a previous session can also cause this.",
                    "If you just switched from an iPhone/webcam session to a ZWO camera (or vice versa) in the same app run, the two sources have very different signal scales (8-bit already-bright video vs. 16-bit dim linear sensor data) — reconnecting resets the display stretch for exactly this reason.",
                ]
            ),
            HelpSection(
                heading: "Capture hangs, or live view doesn't come back after Capture",
                body: "If you're on a build where this still happens: click **Resume Live View** (it appears whenever live view isn't currently active) — if that doesn't help, disconnect and reconnect the camera. This was a real bug in earlier builds (the live-view poll loop could block a single-exposure capture from ever starting); it's fixed as of this build, so persistent hangs on a current build are worth reporting rather than working around."
            ),
            HelpSection(
                heading: "The app feels slow / the cursor keeps spinning with a camera connected",
                body: "Check the **Improve** and **Advanced** tabs for anything you don't actually need running — Focus Assist's star detection, Planetary tracking, and Streak Masking all do real per-frame image analysis, and having several running at once on a high-resolution/high-frame-rate ZWO feed adds up. **Disable All Improvements** / **Disable All Advanced Features** is the fastest way to confirm whether one of them is the cause."
            ),
            HelpSection(
                heading: "A control in the sidebar doesn't respond to clicks",
                body: "A specific, narrow screen position (right under the window's toolbar) has been unreliable for clicks in some builds, independent of which control sits there. If something up there won't respond, look for the same action elsewhere first — the menu bar mirrors most sidebar toggles (Sidebar Tab menu, Full Screen Preview, the render/night-mode/all-sky toggles), and the sidebar's own vertical tab strip has a Full Screen button as a second path to that specific feature."
            ),
            HelpSection(
                heading: "Continuity Camera / iPhone won't connect",
                body: "Both devices need the same Apple ID, Wi-Fi + Bluetooth on for both, and the iPhone nearby and awake. Click **Add iPhone** in the Cameras sidebar for the exact live checklist rather than guessing."
            ),
            HelpSection(
                heading: "The iPhone/webcam view keeps drifting in and out of focus",
                body: "That's the device's own continuous autofocus fighting afocal projection — it's designed to refocus on a normal subject, not hold still at a telescope's focal plane. In Camera Controls → **iPhone / Webcam**, turn on **Lock Focus** once the image looks sharp."
            ),
            HelpSection(
                heading: "Dark/Flat calibration or Smart Exposure are greyed out / do nothing",
                body: "These need a real ASI camera's controllable exposure and aren't available on the iPhone/webcam path — the app tells you this directly if you try them on that source."
            ),
        ]
    )

    // MARK: - Q&A

    static let qAndA = HelpTopic(
        id: "qa",
        title: "Q&A",
        icon: "questionmark.circle",
        sections: [
            HelpSection(
                heading: "Do I need a ZWO camera, or does the iPhone path work too?",
                body: "Both are real capture sources. A ZWO camera gives you actual hardware exposure control, RAW16, calibration frames, and cooling (if supported) — the right tool for serious deep-sky work. The iPhone path is genuinely useful for casual lunar/planetary afocal imaging and for framing/testing without any dedicated hardware."
            ),
            HelpSection(
                heading: "Does live stacking align stars between frames?",
                body: "No — it's a running average with no geometric alignment, the same honest scoping SharpCap's basic live-stack mode uses. It assumes your mount is actually tracking. The same is true of Lucky Imaging's stacking."
            ),
            HelpSection(
                heading: "Is the Catalog HUD / star recognition a full plate solver?",
                body: "No. It matches detected stars against a small, hand-curated bright-star catalog via triangle-shape similarity, then fits a real (small-angle, least-squares) astrometric solution once enough correspondences are confident. It's genuine geometry, not a placeholder — but it's not a general-purpose blind solver like astrometry.net, and it won't work on a field with too few recognizable bright stars."
            ),
            HelpSection(
                heading: "What does FITS export actually contain — the raw data or the stretched preview?",
                body: "FITS contains the raw sensor data (for processing in tools like PixInsight or Siril). PNG/TIFF contain the stretched preview you actually see on screen."
            ),
            HelpSection(
                heading: "Are the AI features real machine learning, or just relabeled classical processing?",
                body: "Mixed, and this app is upfront about which is which. Satellite/aircraft trail masking is real Vision-based contour detection. Live quality scoring reuses the same real Laplacian-variance sharpness metric Lucky Imaging already used. \"Denoise\" is a real classical bilateral filter, not a trained model. Two originally-planned features (a Neural-Engine AI denoiser, AI super-resolution) were deliberately **not** built, because they'd need a trained Core ML model this app doesn't have and can't fabricate — rather than fake something under an AI-sounding label, they were left out."
            ),
            HelpSection(
                heading: "Why does Gain only go 0-20 smoothly, when my camera supports much higher values?",
                body: "It doesn't stop at 20 — the slider just devotes most of its width to that low range specifically, since that's where deep-sky imaging actually happens and this app's own defaults live. Keep dragging past that point on the slider and you'll reach the camera's full range; it's simply less spread out."
            ),
            HelpSection(
                heading: "Can I use two cameras at once?",
                body: "Yes, for one specific purpose: the **All-Sky Monitor** is an independent second feed (another webcam or iPhone) shown picture-in-picture, for watching sky/cloud conditions or cabling while your main camera does the actual imaging. The main pipeline itself is single-camera."
            ),
        ]
    )

    // MARK: - License & credits

    static let licenseAndCredits = HelpTopic(
        id: "license",
        title: "License & Credits",
        icon: "doc.text",
        sections: [
            HelpSection(
                heading: "skyformac (Sky for Mac)",
                body: "Version \(appVersionString). Created by **Giulio Roggero** (giulio.roggero@gmail.com). Source code: [github.com/giulioroggero/skyformac](https://github.com/giulioroggero/skyformac)."
            ),
            HelpSection(
                heading: "Why a native Mac app",
                body: "Most software that can drive a ZWO ASI camera — SharpCap, FireCapture, and others — is Windows-native or Java-based, running on a Mac only through Wine/Parallels or a JVM, neither of which was built with this hardware or this OS in mind. skyformac is a ground-up SwiftUI/AppKit app instead, which is what makes a few things possible that a ported or cross-platform tool generally can't do as directly:",
                bullets: [
                    "**Real GPU acceleration, not a CPU fallback.** Debayering, the display stretch, denoise, wavelet sharpening, histogram computation, and live-stacking all run as actual Metal compute shaders (`Shaders.metal`) on Apple Silicon's GPU — a cross-platform tool's fast path is typically DirectX-only, leaving macOS on a slower CPU-only code path even when it runs at all.",
                    "**An iPhone as a capture source, natively.** Continuity Camera — using a paired iPhone as a live afocal-projection camera — is an Apple-ecosystem capability tied to macOS/iOS; it isn't something a cross-platform or Windows-native tool can offer at all, on any OS.",
                    "**Apple's Vision framework for real detection**, not a bundled third-party computer-vision library — star/streak/planet detection and the live WCS solve all go through the same system framework macOS itself uses for on-device vision tasks.",
                    "**Swift's actor model enforces the hardware-threading rules other apps only document.** Every blocking ZWO SDK call is structurally isolated onto `CaptureEngine`'s own actor — not just a convention to remember, but something the compiler checks — which is what keeps a multi-second USB handshake or a long exposure from ever freezing the UI (see `docs/design-notes.md` for the real hangs this caught and fixed during development).",
                    "**Runs entirely locally.** No telemetry, no cloud account, no network dependency for anything the camera itself doesn't need — and the source is open (GPLv3, see below), so any of this is independently verifiable rather than taken on faith.",
                ]
            ),
            HelpSection(
                heading: "License",
                body: "Copyright © 2026 Giulio Roggero. skyformac's own source code is free software, licensed under the **GNU General Public License, version 3 (GPLv3)** (or, at your option, any later version) — see `LICENSE.md` in the project repository for the complete license text. It is distributed in the hope that it will be useful, but **without any warranty**, including the implied warranties of merchantability or fitness for a particular purpose."
            ),
            HelpSection(
                heading: "Special exception: proprietary camera libraries",
                body: "As an additional permission under Section 7 of GPLv3, the copyright holder grants permission to link skyformac with closed-source third-party camera driver software and SDKs — specifically including the ZWO ASI Camera SDK described below — and to distribute the resulting binary application. All other source code written for skyformac remains governed strictly by GPLv3. See `LICENSE.md` for the exact wording."
            ),
            HelpSection(
                heading: "Third-party: ZWO ASI Camera SDK",
                body: "Camera control and image capture for ZWO ASI cameras uses ZWO's own ASI Camera SDK (`ASICamera2.h` and `libASICamera2.dylib`), **© ZWO Co., Ltd.** (astronomy-imaging-camera.com) — a proprietary, closed-source precompiled binary SDK. It remains ZWO's intellectual property and is **not** itself covered by skyformac's GPLv3 license; it's used here under the special exception above, which exists specifically so this proprietary SDK can be linked without requiring ZWO to disclose their driver source. See `THIRD_PARTY_NOTICES.md` in the project repository for the full notice."
            ),
            HelpSection(
                heading: "Apple frameworks",
                body: "Built with SwiftUI, AVFoundation (Continuity Camera / webcam capture), Metal (GPU rendering), Vision (star/streak/planet detection), Core Image, and Core ML frameworks provided by Apple as part of macOS."
            ),
        ]
    )

    /// `CFBundleShortVersionString` (`MARKETING_VERSION`), with the build number
    /// (`CFBundleVersion`/`CURRENT_PROJECT_VERSION`) appended only when it says something the
    /// marketing version doesn't already — reads the running app's actual `Bundle.main` rather
    /// than a hardcoded literal, so this can't drift out of sync with a real release the way a
    /// string typed here by hand eventually would.
    private static var appVersionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty || build == version ? version : "\(version) (\(build))"
    }

    /// Plain case-insensitive substring search over every topic's every section (heading + body +
    /// bullets) — no fuzzy matching or ranking beyond "topics/sections earlier in `topics` sort
    /// first", which is fine for a help corpus this size (a few dozen topics/sections total).
    /// Empty/whitespace-only `query` returns no results — `HelpView` treats that as "show the
    /// normal topic list", not "show everything".
    static func search(_ query: String) -> [HelpSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let needle = trimmed.lowercased()

        var results: [HelpSearchResult] = []
        for topic in topics {
            for (index, section) in topic.sections.enumerated() {
                let haystacks = [section.heading, section.body].compactMap { $0 } + section.bullets
                guard let matchedText = haystacks.first(where: { $0.lowercased().contains(needle) }) else { continue }
                results.append(HelpSearchResult(
                    topicID: topic.id,
                    topicTitle: topic.title,
                    topicIcon: topic.icon,
                    sectionIndex: index,
                    sectionAnchorID: section.id,
                    displayTitle: section.heading ?? topic.title,
                    snippet: excerpt(of: matchedText, around: needle)
                ))
            }
        }
        return results
    }

    /// Plain markdown (`**bold**`) stripped so the snippet reads cleanly as a search-result
    /// subtitle instead of showing literal asterisks.
    private static func excerpt(of text: String, around needle: String, contextLength: Int = 80) -> String {
        let stripped = text.replacingOccurrences(of: "**", with: "")
        guard let range = stripped.lowercased().range(of: needle) else {
            return String(stripped.prefix(contextLength))
        }
        let start = stripped.index(range.lowerBound, offsetBy: -contextLength, limitedBy: stripped.startIndex) ?? stripped.startIndex
        let end = stripped.index(range.upperBound, offsetBy: contextLength, limitedBy: stripped.endIndex) ?? stripped.endIndex
        let excerpt = stripped[start..<end]
        return (start > stripped.startIndex ? "…" : "") + excerpt + (end < stripped.endIndex ? "…" : "")
    }
}

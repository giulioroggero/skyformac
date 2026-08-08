# Claude Code Specification: Native Astronomical Catalog Parsing & HUD Overlay System

## 1. Overview & Objectives
**Feature Goal:** Provide an embedded, zero-dependency Sky Object Recognition and Heads-Up Display (HUD) overlay directly on top of the live ZWO camera feed. 

Instead of relying on external planetarium software (e.g., Stellarium, KStars) running in the background, the app will embed a local SQLite database containing astronomical catalogs (OpenNGC, Messier, and Bright Star Catalogs). Using telemetry from a plate solver (Center Right Ascension $\alpha$, Declination $\delta$, Field of View $\text{FOV}$, and Rotation $\theta$), the engine queries visible objects in real time, projects their 3D celestial coordinates onto 2D camera pixels, and renders vector badges, reticles, and object boundaries directly on the UI layer.

---

## 2. Catalog Database Architecture (SQLite)

### 2.1. Dataset & Bundled File
* **Source:** OpenNGC (CC-BY-SA-4.0) merged with Messier and Yale Bright Star (BS) catalogs.
* **Format:** SQLite 3 database file (`astro_catalog.sqlite`) bundled directly inside the macOS `.app` bundle Resources directory (read-only at runtime).
* **Target Size:** $< 15\text{ MB}$.

### 2.2. Database Schema
```sql
CREATE TABLE IF NOT EXISTS catalog_objects (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    catalog TEXT NOT NULL,          -- 'M' (Messier), 'NGC', 'IC', 'HD', 'HIP'
    catalog_number INTEGER,          -- e.g., 31 for M31, 224 for NGC224
    common_name TEXT,               -- e.g., 'Andromeda Galaxy', 'Ring Nebula'
    object_type TEXT NOT NULL,       -- 'G' (Galaxy), 'PN' (Planetary Neb), 'E' (Emission Neb), 'OC' (Open Cluster), 'GC' (Globular Cluster), 'S' (Star)
    ra_deg REAL NOT NULL,           -- Right Ascension in decimal degrees [0.0, 360.0)
    dec_deg REAL NOT NULL,          -- Declination in decimal degrees [-90.0, 90.0]
    v_mag REAL,                     -- Visual Magnitude (app_mag)
    major_axis_arcmin REAL,         -- Angular size major axis in arcminutes
    minor_axis_arcmin REAL,         -- Angular size minor axis in arcminutes
    position_angle_deg REAL         -- Object orientation angle in degrees
);

-- Spatial B-Tree indexes for fast bounding box range queries
CREATE INDEX IF NOT EXISTS idx_coords ON catalog_objects (dec_deg, ra_deg);
CREATE INDEX IF NOT EXISTS idx_magnitude ON catalog_objects (v_mag);
```

---

## 3. Spatial Bounding Box Query Engine

When a plate solver returns a solved field center $(\alpha_0, \delta_0)$ and field dimension $(\text{FOV}_{\text{width}}, \text{FOV}_{\text{height}})$, calculate the celestial bounding box to query SQLite efficiently in under $1\text{ ms}$.

### 3.1. Bounding Box Math
Given center $(\alpha_0, \delta_0)$ in degrees and padded field dimensions $(\text{w}_{\text{deg}}, \text{h}_{\text{deg}})$:

$$\delta_{\min} = \max(-90.0, \delta_0 - \frac{\text{h}_{\text{deg}}}{2})$$
$$\delta_{\max} = \min(90.0, \delta_0 + \frac{\text{h}_{\text{deg}}}{2})$$

Account for Right Ascension convergence near the poles ($\cos\delta$ scale factor):
$$\Delta\alpha = \frac{\text{w}_{\text{deg}}}{2 \cdot \cos(\max(|\delta_{\min}|, |\delta_{\max}|) \cdot \frac{\pi}{180})}$$
$$\alpha_{\min} = (\alpha_0 - \Delta\alpha) \pmod{360}$$
$$\alpha_{\max} = (\alpha_0 + \Delta\alpha) \pmod{360}$$

### 3.2. Query Swift Execution
```swift
struct SkyObject: Identifiable, Sendable {
    let id: Int
    let name: String
    let type: ObjectType
    let raDeg: Double
    let decDeg: Double
    let magnitude: Double?
    let sizeArcmin: CGSize?
}

// Executed off the Main Thread inside a Swift Actor
actor CatalogRepository {
    private var db: OpaquePointer?
    
    func fetchObjects(in bounds: BoundingBox, maxMagnitude: Double = 12.0) -> [SkyObject] {
        // SELECT * FROM catalog_objects 
        // WHERE dec_deg BETWEEN ? AND ? 
        // AND (ra_deg BETWEEN ? AND ?) 
        // AND (v_mag IS NULL OR v_mag <= ?)
    }
}
```

---

## 4. World Coordinate System (WCS) Projection Math

To place an object $(\alpha, \delta)$ onto camera frame pixel coordinates $(x_{\text{pixel}}, y_{\text{pixel}})$, apply **Gnomonic (Tangent Plane) Projection**:

### Step 1: Celestial to Tangent Plane Coordinates $(\xi, \eta)$
Let $\Delta\alpha = (\alpha - \alpha_0) \cdot \frac{\pi}{180}$, $\delta_0 = \text{Dec}_0 \cdot \frac{\pi}{180}$, and $\delta = \text{Dec} \cdot \frac{\pi}{180}$.

$$D = \sin\delta_0 \sin\delta + \cos\delta_0 \cos\delta \cos(\Delta\alpha)$$

$$\xi = \frac{\cos\delta \sin(\Delta\alpha)}{D} \quad \text{(radians)}$$

$$\eta = \frac{\cos\delta_0 \sin\delta - \sin\delta_0 \cos\delta \cos(\Delta\alpha)}{D} \quad \text{(radians)}$$

### Step 2: Tangent Plane to Screen Pixels
Apply camera sensor pixel scale $s_{\text{rad/px}}$ (derived from focal length and camera pixel size, e.g., $2.0\,\mu\text{m}$ for ASI678MC) and field rotation angle $\theta$:

$$\begin{bmatrix} x_{\text{pixel}} \\ y_{\text{pixel}} \end{bmatrix} = \begin{bmatrix} X_{\text{center}} \\ Y_{\text{center}} \end{bmatrix} + \frac{1}{s_{\text{rad/px}}} \begin{bmatrix} -\cos\theta & \sin\theta \\ \sin\theta & \cos\theta \end{bmatrix} \begin{bmatrix} \xi \\ \eta \end{bmatrix}$$

---

## 5. UI Rendering & HUD Overlay Engine

The HUD layer sits directly above the Metal live frame view in SwiftUI using a high-performance `Canvas` view or `MetalKit` overlay shader.

```
┌─────────────────────────────────────────────────────────────┐
│ Live Camera Feed (MetalView / ASI678MC)                     │
│  ┌───────────────────────────────────────────────────────┐  │
│  │ SwiftUI Canvas HUD Overlay Layer (Transparent)         │  │
│  │                                                       │  │
│  │      [+] NGC 224 (M31) - Andromeda Galaxy             │  │
│  │      │   Mag: 3.44 | Type: Spiral Galaxy              │  │
│  │      └─── Ellipse Boundary (Scaled to Focal Scale)    │  │
│  │                                                       │  │
│  │            (+) HIP 32349 (Bright Star)                │  │
│  └───────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### 5.1. Visual Style Guide

| Object Type | Badge Shape | Color | Default Label Content |
| :--- | :--- | :--- | :--- |
| **Messier Objects** | Concentric Circle + Reticle Crosshair | `#FFCC00` (Gold) | Common Name (e.g., "M31 Andromeda") |
| **Galaxies (NGC/IC)** | Major/Minor Axis Ellipse | `#FF3B30` (Red/Magenta) | Catalog ID + Mag (e.g., "NGC 891 | 9.9m") |
| **Emission/Planetary Nebulae** | Square / Rounded Box | `#28CD41` (Green) | Catalog ID + Type |
| **Open / Globular Clusters** | Dashed Circle | `#007AFF` (Blue) | Catalog ID + Diameter |
| **Alignment Stars** | Small Diamond Target `(+)` | `#5AC8FA` (Cyan) | Star Identifier / Bayer Designation |

### 5.2. SwiftUI Canvas Implementation
```swift
struct SkyHUDView: View {
    let solvedWCS: WCSFrame
    let visibleObjects: [SkyObject]
    @Binding var selectedObject: SkyObject?
    
    var body: some View {
        Canvas { context, size in
            for object in visibleObjects {
                if let screenPoint = solvedWCS.projectToPixel(ra: object.raDeg, dec: object.decDeg, frameSize: size) {
                    // Check if point falls within screen bounds
                    guard size.contains(screenPoint) else { continue }
                    
                    // Draw Vector Badge according to object type
                    drawBadge(context: &context, point: screenPoint, object: object)
                }
            }
        }
        .allowsHitTesting(true) // Enables click-to-inspect on sky targets
    }
}
```

---

## 6. Implementation Directives for Claude Code

1. **Zero Main-Thread Blocking:** Database queries (`CatalogRepository`) and WCS matrix calculations must be run in background actors. Never perform SQLite queries directly inside SwiftUI `body` evaluation.
2. **Dynamic Level of Detail (LOD):** Adjust query magnitude thresholds based on the solved Field of View:
   * $\text{FOV} > 5^\circ$: Render only Messier objects and stars $m_v \le 6.0$.
   * $1^\circ < \text{FOV} \le 5^\circ$: Render NGC/IC objects $m_v \le 10.0$.
   * $\text{FOV} \le 1^\circ$ (ASI678MC high magnification): Render deep-sky catalog items up to $m_v \le 14.0$.
3. **Canceled Query Handling:** Wrap fetch operations in Swift `Task` groups so rapid panning/plate solving updates instantly cancel outdated catalog queries.
4. **Interactive Target Selector:** Clicking/Hovering on any rendered HUD label must trigger a SwiftUI popover presenting detailed object metadata (Magnitude, Distance, Object Dimensions, Constellation).

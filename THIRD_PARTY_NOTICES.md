# Third-Party Notices and Licenses

Sky for Mac incorporates third-party software libraries subject to their respective copyright holders and licenses.

---

## 1. ZWO ASI Camera SDK (libASICamera2)

* **Copyright:** © ZWO Co., Ltd. (https://astronomy-imaging-camera.com)
* **License Type:** Proprietary / Closed-Source Binary SDK
* **Components Used:** `libASICamera2.dylib`, `ASICamera2.h`

### Notice
The ZWO ASI Camera SDK is provided by ZWO Co., Ltd. as a closed-source precompiled binary for camera hardware control. The SDK remains the intellectual property of ZWO Co., Ltd. 

"Sky for Mac" links to this proprietary SDK under a Special Exception authorized by Section 7 of the GNU General Public License v3 (see `LICENSE.md`). This exception permits linking the closed-source driver without requiring ZWO to disclose their driver source code, while preserving the GPLv3 rights for the rest of the Sky for Mac application.

---

## 2. Stellarium deep-sky object catalog and object-name data

* **Project:** Stellarium (https://stellarium.org / https://github.com/Stellarium/stellarium)
* **License Type:** GNU General Public License v2
* **Components Used:** Not Stellarium source code or binaries — a small, static subset of
  factual astronomical data (right ascension/declination, magnitude, object type, and common
  names) extracted from Stellarium's bundled `nebulae/default/catalog.txt` and
  `nebulae/default/names.dat` data files, covering the Messier and Caldwell catalogs plus a
  handful of bright stars, and bundled here as plain JSON (`skyformac/Resources/SkyCatalog/`).

### Notice
"Sky for Mac" does not link against or redistribute any Stellarium source code or compiled
binary. It bundles a small, pre-extracted subset of the astronomical reference data (object
positions, magnitudes, and common names — themselves public astronomical facts) that ships with
the Stellarium project, used entirely offline to resolve an observed object's name to its real
sky position for the app's own Sky Atlas view and AI assistant. Credit and thanks to the
Stellarium project and its contributors for compiling and maintaining this data.

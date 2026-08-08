#!/usr/bin/env python3
"""Builds skyformac/Resources/AstroCatalog/astro_catalog.sqlite from real astronomical data:

- Stellarium's bundled DSO catalog (nebulae/default/catalog.txt + names.dat) for
  NGC/IC/Messier galaxies, nebulae, and clusters — see
  https://github.com/Stellarium/stellarium, CC-BY-SA-4.0 data.
- This repo's own hand-curated skyformac/Resources/SkyCatalog/bright_stars.json for the
  bright-star layer (Stellarium's own star catalog is a proprietary binary format not
  worth reverse-engineering for a ~14-star list).

Schema matches spec/skyformac_Catalog_HUD_Spec.md section 2.2 exactly. Run this whenever the
Stellarium source or bright_stars.json changes; the output is checked in as a bundled
resource, not regenerated at build time.

Usage: python3 scripts/build_astro_catalog.py <path-to-stellarium-repo>
"""
import json
import re
import sqlite3
import sys
from pathlib import Path

SCHEMA = """
CREATE TABLE catalog_objects (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    catalog TEXT NOT NULL,
    catalog_number INTEGER,
    common_name TEXT,
    object_type TEXT NOT NULL,
    ra_deg REAL NOT NULL,
    dec_deg REAL NOT NULL,
    v_mag REAL,
    major_axis_arcmin REAL,
    minor_axis_arcmin REAL,
    position_angle_deg REAL
);
CREATE INDEX idx_coords ON catalog_objects (dec_deg, ra_deg);
CREATE INDEX idx_magnitude ON catalog_objects (v_mag);
"""

# Stellarium's terse type codes -> the spec's HUD object_type vocabulary
# ('G', 'PN', 'E', 'OC', 'GC', 'S').
TYPE_MAP = {
    "GX": "G", "G": "G", "IG": "G", "AGX": "G", "GC": "GC",
    "OC": "OC", "CL": "OC", "OCL": "OC", "SCL": "OC",
    "PN": "PN",
    "NB": "E", "HII": "E", "EN": "E", "RN": "E", "C+N": "E", "SNR": "E",
    "DN": "E", "BN": "E", "SA": "E", "SC": "E", "RG": "E",
}


def parse_names(stellarium_root: Path) -> dict[tuple[str, int], str]:
    """(prefix, number) -> first/preferred proper name, from names.dat's fixed columns
    (see the file's own header: bytes 1-5 prefix, 6-20 id, 21-end name)."""
    names: dict[tuple[str, int], str] = {}
    path = stellarium_root / "nebulae/default/names.dat"
    pattern = re.compile(r'_\("([^"]+)"\)')
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if not line or line.startswith("#"):
            continue
        prefix = line[0:5].strip()
        ident = line[5:20].strip()
        rest = line[20:]
        if prefix not in ("M", "NGC", "IC") or not ident.isdigit():
            continue
        match = pattern.search(rest)
        if not match:
            continue
        key = (prefix, int(ident))
        names.setdefault(key, match.group(1))  # first name in the file wins
    return names


def parse_dso_catalog(stellarium_root: Path, names: dict) -> list[tuple]:
    path = stellarium_root / "nebulae/default/catalog.txt"
    rows = []
    seen_keys: set[tuple[str, int]] = set()
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if not line or line.startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) < 19:
            continue

        def f(index, default=0.0):
            raw = fields[index].strip()
            try:
                return float(raw)
            except ValueError:
                return default

        ngc, ic, m = int(f(16)), int(f(17)), int(f(18))
        if not (ngc or ic or m):
            continue  # not cross-referenced to a catalog this app surfaces badges for

        # One row per physical object — prefer the most recognizable catalog identity.
        if m:
            catalog, number = "M", m
        elif ngc:
            catalog, number = "NGC", ngc
        else:
            catalog, number = "IC", ic
        key = (catalog, number)
        if key in seen_keys:
            continue
        seen_keys.add(key)

        v_mag_raw = f(4, 99.0)
        v_mag = None if v_mag_raw >= 99.0 else v_mag_raw
        # Messier objects are always kept (finite, small, historically important list);
        # everything else needs a real magnitude and a reasonable brightness limit so the
        # bundled file stays a manageable size (spec target: < 15 MB).
        if catalog != "M" and (v_mag is None or v_mag > 14.0):
            continue

        raw_type = fields[5].strip()
        object_type = TYPE_MAP.get(raw_type, "G" if catalog == "M" else "E")
        major = f(7, 0.0) or None
        minor = f(8, 0.0) or None
        position_angle = f(9, 0.0) or None

        common_name = names.get((catalog, number))
        if common_name is None and catalog == "M":
            common_name = names.get(("NGC", ngc)) if ngc else None

        rows.append((
            catalog, number, common_name, object_type,
            f(1), f(2), v_mag, major, minor, position_angle,
        ))
    return rows


def parse_bright_stars(repo_root: Path) -> list[tuple]:
    path = repo_root / "skyformac/Resources/SkyCatalog/bright_stars.json"
    stars = json.loads(path.read_text(encoding="utf-8"))
    rows = []
    for star in stars:
        rows.append((
            "HIP", None, star.get("commonName") or star["id"], "S",
            star["raDegrees"], star["decDegrees"], star.get("magnitude"),
            None, None, None,
        ))
    return rows


def main():
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <path-to-stellarium-repo>", file=sys.stderr)
        sys.exit(1)
    stellarium_root = Path(sys.argv[1])
    repo_root = Path(__file__).resolve().parent.parent
    out_path = repo_root / "skyformac/Resources/AstroCatalog/astro_catalog.sqlite"
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.unlink(missing_ok=True)

    names = parse_names(stellarium_root)
    dso_rows = parse_dso_catalog(stellarium_root, names)
    star_rows = parse_bright_stars(repo_root)

    conn = sqlite3.connect(out_path)
    conn.executescript(SCHEMA)
    conn.executemany(
        """INSERT INTO catalog_objects
           (catalog, catalog_number, common_name, object_type, ra_deg, dec_deg,
            v_mag, major_axis_arcmin, minor_axis_arcmin, position_angle_deg)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
        dso_rows + star_rows,
    )
    conn.commit()
    conn.execute("VACUUM")
    conn.close()

    size_mb = out_path.stat().st_size / (1024 * 1024)
    print(f"Wrote {len(dso_rows)} DSOs + {len(star_rows)} stars "
          f"({len(dso_rows) + len(star_rows)} rows) to {out_path} ({size_mb:.2f} MB)")


if __name__ == "__main__":
    main()

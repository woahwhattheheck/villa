#!/usr/bin/env python3
"""Regression for ScrollPrize/villa#1320 using a checked-in PHerc segment."""

from __future__ import annotations

import pathlib
import subprocess
import sys
import tempfile


def run(args: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        args,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> int:
    if len(sys.argv) != 4:
        print(
            "usage: test_obj2tifxyz_zero_raster.py "
            "<vc_tifxyz2obj> <vc_obj2tifxyz> <real-tifxyz-fixture>",
            file=sys.stderr,
        )
        return 2

    tifxyz2obj = pathlib.Path(sys.argv[1]).resolve()
    obj2tifxyz = pathlib.Path(sys.argv[2]).resolve()
    fixture = pathlib.Path(sys.argv[3]).resolve()

    require(tifxyz2obj.is_file(), f"missing vc_tifxyz2obj: {tifxyz2obj}")
    require(obj2tifxyz.is_file(), f"missing vc_obj2tifxyz: {obj2tifxyz}")
    require(fixture.is_dir(), f"missing real tifxyz fixture: {fixture}")

    with tempfile.TemporaryDirectory(prefix="vc_obj2tifxyz_1320_") as td:
        root = pathlib.Path(td)
        obj = root / "normalized.obj"

        # The fixture is a real PHerc 0172 segment already used by
        # test_quadsurface_fixtures. Recreate the normalized-UV input from #1320.
        to_obj = run([str(tifxyz2obj), str(fixture), str(obj), "--normalize-uv"])
        require(
            to_obj.returncode == 0 and obj.is_file(),
            "vc_tifxyz2obj failed on the PHerc fixture:\n" + to_obj.stdout,
        )

        rejected = root / "default"
        default = run([str(obj2tifxyz), str(obj), str(rejected)])
        require(
            default.returncode != 0,
            "default normalized-UV conversion incorrectly returned success:\n"
            + default.stdout,
        )
        require(
            "no valid grid points were rasterized" in default.stdout,
            "zero-raster failure did not explain the cause:\n" + default.stdout,
        )
        for axis in ("x.tif", "y.tif", "z.tif"):
            require(
                not (rejected / axis).exists(),
                f"default failure still wrote {axis}",
            )

        # Existing real-data fixture documentation uses stretch_factor=128.
        # Keep that successful route as the positive control.
        accepted = root / "scaled"
        scaled = run([str(obj2tifxyz), str(obj), str(accepted), "128"])
        require(
            scaled.returncode == 0,
            "explicit stretch_factor=128 regressed:\n" + scaled.stdout,
        )
        for axis in ("x.tif", "y.tif", "z.tif"):
            require((accepted / axis).is_file(), f"missing successful {axis}")

    print("obj2tifxyz zero-raster real-data regression: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""
Turn an Xcode asset catalog into plain bundle resources.

Xcode compiles .xcassets into Assets.car with actool, which only exists on
macOS. iOS 8 still loads images the "old" way, so instead we copy each image
into the bundle root using UIKit's naming rules:

  <Name>.png, <Name>@2x.png, <Name>@3x.png       (+[UIImage imageNamed:])
  AppIcon<size>.png, AppIcon<size>@2x~ipad.png    (CFBundleIconFiles)

Vector (PDF) image sets are skipped; they are pre-rendered in ios8/Resources.

usage: flatten_assets.py <Images.xcassets> <output .app directory>
"""

import json
import os
import shutil
import sys


def suffix(scale, idiom):
    s = "" if scale in (None, "1x") else "@" + scale
    if idiom == "ipad":
        s += "~ipad"
    return s


def copy_imageset(path, name, out):
    with open(os.path.join(path, "Contents.json")) as f:
        contents = json.load(f)
    for image in contents.get("images", []):
        filename = image.get("filename")
        if not filename or not filename.lower().endswith(".png"):
            continue
        idiom = image.get("idiom", "universal")
        if idiom not in ("universal", "iphone", "ipad"):
            continue
        dest = name + suffix(image.get("scale"), idiom if idiom == "ipad" else None) + ".png"
        shutil.copyfile(os.path.join(path, filename), os.path.join(out, dest))


def copy_appiconset(path, out):
    with open(os.path.join(path, "Contents.json")) as f:
        contents = json.load(f)
    for image in contents.get("images", []):
        filename = image.get("filename")
        idiom = image.get("idiom")
        if not filename or idiom not in ("iphone", "ipad"):
            continue
        size = image["size"]  # e.g. "60x60"
        dest = "AppIcon" + size + suffix(image.get("scale"), idiom) + ".png"
        shutil.copyfile(os.path.join(path, filename), os.path.join(out, dest))


def main():
    catalog, out = sys.argv[1], sys.argv[2]
    for entry in sorted(os.listdir(catalog)):
        path = os.path.join(catalog, entry)
        base, ext = os.path.splitext(entry)
        if ext == ".imageset":
            copy_imageset(path, base, out)
        elif ext == ".appiconset":
            copy_appiconset(path, out)


if __name__ == "__main__":
    main()

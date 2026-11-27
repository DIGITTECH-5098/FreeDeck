"""Regenerate .github/apps.json — the FreeDeck AltStore source — from the
latest GitHub release of this repository.

Runs from .github/workflows/update_source.yml whenever a release is published.
The AltStore convention is that the source URL stays stable:
https://github.com/<owner>/<repo>/releases/download/1.0/apps.json
"""

import json
import os
import sys
from datetime import datetime, timezone

import requests

REPO = os.environ.get("GITHUB_REPOSITORY", "DIGITTECH-5098/FreeDeck")
API = f"https://api.github.com/repos/{REPO}"
OUT = ".github/apps.json"

# The "1.0" release holds the always-current source JSON (AltStore convention).
SOURCE_RELEASE_TAG = "1.0"


def gh_headers():
    headers = {"Accept": "application/vnd.github+json"}
    token = os.environ.get("GITHUB_TOKEN")
    if token:
        headers["Authorization"] = f"Bearer {token}"
    return headers


def latest_release():
    """The newest published, non-source release carrying an IPA asset."""
    resp = requests.get(f"{API}/releases", headers=gh_headers(), timeout=30)
    resp.raise_for_status()
    for rel in resp.json():
        if rel.get("draft") or rel.get("tag_name") == SOURCE_RELEASE_TAG:
            continue
        if any(a["name"].endswith(".ipa") for a in rel.get("assets", [])):
            return rel
    return None


def build_source(release):
    ipa = next(a for a in release["assets"] if a["name"].endswith(".ipa"))
    tag = release["tag_name"]
    return {
        "name": "FreeDeck",
        "identifier": "com.freedeck.source",
        "website": f"https://github.com/{REPO}",
        "subtitle": "FreeDeck — free, open-source app environment for iOS.",
        "description": (
            "FreeDeck is a free, open-source app environment for iOS, built on "
            "LiveContainer: a multi-window launcher that offloads apps, games "
            "and web ports to your own server over Tailscale. No subscription, "
            "no account, no paid certificates."
        ),
        "tintColor": "#0784FC",
        "iconURL": f"https://raw.githubusercontent.com/{REPO}/main/Resources/AppIcon.png",
        "apps": [
            {
                "beta": False,
                "name": "FlekDeck",
                "bundleIdentifier": "com.fs.flekdeck",
                "developerName": "FreeDeck Community",
                "subtitle": "Your apps. Your server. Zero local storage.",
                "version": tag.lstrip("v"),
                "versionDate": (release.get("published_at") or datetime.now(timezone.utc).isoformat())[:10],
                "versionDescription": (release.get("body") or f"FreeDeck {tag}").strip(),
                "downloadURL": ipa["browser_download_url"],
                "localizedDescription": "Your apps. Your server. Zero local storage.",
                "iconURL": f"https://raw.githubusercontent.com/{REPO}/main/Resources/AppIcon.png",
                "tintColor": "#0784FC",
                "category": "utilities",
                "size": ipa.get("size", 0),
                "screenshotURLs": [],
            }
        ],
    }


def main():
    release = latest_release()
    if release is None:
        print("No published release with an IPA asset found; apps.json unchanged.")
        return 0

    source = build_source(release)
    with open(OUT, "w") as fh:
        json.dump(source, fh, indent=2)
        fh.write("\n")
    print(f"{OUT} updated for {release['tag_name']}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

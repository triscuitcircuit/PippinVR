#!/usr/bin/env python3
"""Apply the public Sparkle release configuration before signing the app."""
import base64
import binascii
import os
from pathlib import Path
import plistlib
import sys
from urllib.parse import urlsplit


def configure(path, environment):
    feed = environment.get("SPARKLE_FEED_URL", "").strip()
    key = environment.get("SPARKLE_PUBLIC_ED_KEY", "").strip()
    if not feed and not key:
        return
    url = urlsplit(feed)
    if url.scheme != "https" or not url.hostname or url.username or url.password or url.fragment:
        raise ValueError("SPARKLE_FEED_URL must be an HTTPS appcast URL without credentials or a fragment")
    try:
        valid_key = len(base64.b64decode(key, validate=True)) == 32
    except (ValueError, binascii.Error):
        valid_key = False
    if not valid_key:
        raise ValueError("SPARKLE_PUBLIC_ED_KEY must be the 32-byte public key printed by generate_keys")
    data = plistlib.loads(path.read_bytes())
    data.update(SUFeedURL=feed, SUPublicEDKey=key)
    path.write_bytes(plistlib.dumps(data, sort_keys=False))


if __name__ == "__main__":
    try:
        configure(Path(sys.argv[1]), os.environ)
    except (ValueError, OSError) as error:
        sys.exit(f"Update configuration: {error}")

"""Release plist validation without signing keys or network access."""
import base64
import importlib.util
from pathlib import Path
import plistlib
import tempfile
import sys

sys.dont_write_bytecode = True
server = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("updates", server / "build_scripts/configure-updates.py")
updates = importlib.util.module_from_spec(spec)
spec.loader.exec_module(updates)
with tempfile.TemporaryDirectory() as directory:
    path = Path(directory) / "Info.plist"
    original = plistlib.dumps({"CFBundleVersion": "101"})
    key = base64.b64encode(bytes(range(32))).decode()
    good = {"SPARKLE_FEED_URL": "https://example.com/appcast.xml", "SPARKLE_PUBLIC_ED_KEY": key}
    for environment in [
        {"SPARKLE_FEED_URL": good["SPARKLE_FEED_URL"]}, {"SPARKLE_PUBLIC_ED_KEY": key},
        {**good, "SPARKLE_FEED_URL": "http://example.com/appcast.xml"},
        {**good, "SPARKLE_FEED_URL": "https://user:password@example.com/appcast.xml"},
        {**good, "SPARKLE_PUBLIC_ED_KEY": "invalid"},
    ]:
        path.write_bytes(original)
        try:
            updates.configure(path, environment)
            raise AssertionError("invalid release configuration accepted")
        except ValueError:
            assert path.read_bytes() == original
    updates.configure(path, {})
    assert path.read_bytes() == original
    updates.configure(path, good)
    result = plistlib.loads(path.read_bytes())
    assert result == {"CFBundleVersion": "101", "SUFeedURL": good["SPARKLE_FEED_URL"], "SUPublicEDKey": key}
print("PASS: update configuration, disabled development builds, invalid-key/URL rejection, plist preservation")

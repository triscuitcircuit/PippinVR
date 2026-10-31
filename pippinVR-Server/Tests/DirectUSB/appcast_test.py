"""Feed publication regression checks using synthetic public metadata."""
import importlib.util
from pathlib import Path
import sys
import tempfile
import xml.etree.ElementTree as ET

sys.dont_write_bytecode = True
server = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('appcast', server / 'build_scripts/merge-appcast.py')
appcast = importlib.util.module_from_spec(spec)
spec.loader.exec_module(appcast)


def feed(path, number, tag, signature='synthetic-signature'):
    path.write_text(f'''<rss xmlns:sparkle="{appcast.SPARKLE}" version="2.0"><channel>
      <title>PippinVR</title><item><sparkle:version>{number}</sparkle:version>
      <enclosure url="https://github.com/owner/repo/releases/download/{tag}/PippinVR.dmg"
        length="100" sparkle:edSignature="{signature}" /></item></channel></rss>''')


with tempfile.TemporaryDirectory() as directory:
    source, destination = Path(directory)/'generated.xml', Path(directory)/'updates/appcast.xml'
    feed(source, 102, 'v1.2')
    appcast.merge(source, destination, 'owner/repo', 'v1.2')
    assert [appcast.build(i) for i in ET.parse(destination).findall('channel/item')] == [102]
    appcast.merge(source, destination, 'owner/repo', 'v1.2')
    assert len(ET.parse(destination).findall('channel/item')) == 1
    feed(source, 101, 'v1.1')
    appcast.merge(source, destination, 'owner/repo', 'v1.1')
    assert [appcast.build(i) for i in ET.parse(destination).findall('channel/item')] == [102,101]
    for number, tag, signature, expected_tag in [
        (103, 'v1.3', '', 'v1.3'), (103, 'v1.3', 'signed', 'v1.4'),
        (102, 'v1.2', 'different-archive', 'v1.2'),
    ]:
        original = destination.read_bytes()
        feed(source, number, tag, signature)
        try:
            appcast.merge(source, destination, 'owner/repo', expected_tag)
            raise AssertionError('Invalid feed accepted')
        except ValueError:
            assert destination.read_bytes() == original
print('PASS: first publication, idempotent rerun, release ordering, URL/signature checks and build-number reuse rejection')

#!/usr/bin/env python3
"""Merge a generated release into the public feed, keeping higher builds first."""
import argparse
from pathlib import Path
from urllib.parse import quote
import xml.etree.ElementTree as ET

SPARKLE = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', SPARKLE)


def build(item):
    enclosure = item.find('enclosure')
    value = item.findtext(f'{{{SPARKLE}}}version')
    if value is None and enclosure is not None:
        value = enclosure.get(f'{{{SPARKLE}}}version')
    if not value or not value.isascii() or not value.isdigit():
        raise ValueError('Feed entries must have numeric CFBundleVersion values')
    return int(value)


def merge(generated, destination, repository, tag):
    tree = ET.parse(generated)
    channel = tree.getroot().find('channel')
    if channel is None or not channel.findall('item'):
        raise ValueError('Generated appcast has no release entries')
    expected = f'https://github.com/{repository}/releases/download/{quote(tag, safe="")}/'
    items = {}
    if destination.exists():
        old_channel = ET.parse(destination).getroot().find('channel')
        if old_channel is None:
            raise ValueError('Existing appcast has no channel')
        items.update((build(item), item) for item in old_channel.findall('item'))
    for item in channel.findall('item'):
        enclosure = item.find('enclosure')
        if enclosure is None or not enclosure.get('url', '').startswith(expected):
            raise ValueError('Generated download URL does not match the published release')
        if not enclosure.get(f'{{{SPARKLE}}}edSignature') or int(enclosure.get('length', '0')) <= 0:
            raise ValueError('Generated archive is missing its signature or size')
        number = build(item)
        if number in items and items[number].find('enclosure').attrib != enclosure.attrib:
            raise ValueError('A published build number cannot be reused for a different archive')
        items[number] = item
    for item in list(channel.findall('item')):
        channel.remove(item)
    for number in sorted(items, reverse=True):
        channel.append(items[number])
    destination.parent.mkdir(parents=True, exist_ok=True)
    ET.indent(tree)
    tree.write(destination, encoding='utf-8', xml_declaration=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('generated', type=Path)
    parser.add_argument('destination', type=Path)
    parser.add_argument('--repository', required=True)
    parser.add_argument('--tag', required=True)
    args = parser.parse_args()
    merge(args.generated, args.destination, args.repository, args.tag)

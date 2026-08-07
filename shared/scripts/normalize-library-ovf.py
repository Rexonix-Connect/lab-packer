#!/usr/bin/env python3
"""Normalize the deploy-form ordering in an exported library item's OVF.

vCenter's OVF export does not write vApp properties in any deterministic
order, and the deploy wizard renders the OVF document order, so the form
came out scrambled. This runs right after the Packer build: it downloads the
library item's OVF descriptor, reorders the ProductSection so the deploy-form
properties appear in DESCRIPTORS order under their category markers (foreign
properties are preserved after them under "Other"), refreshes the manifest
hash, and uploads both files back through an update session. Property ids,
values, types and attributes are untouched.
"""
import hashlib
import importlib.util
import os
import re
import sys
import time
import xml.etree.ElementTree as ET

import requests
import urllib3

_HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location(
    "set_vapp_descriptors", os.path.join(_HERE, "set-vapp-descriptors.py"))
_descriptors_module = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_descriptors_module)
DESCRIPTORS = _descriptors_module.DESCRIPTORS

OVF_NS = "http://schemas.dmtf.org/ovf/envelope/1"


def env(name):
    value = os.environ.get(name, "")
    if not value:
        sys.exit("normalize-library-ovf: %s is not set" % name)
    return value


def register_document_namespaces(xml_text):
    # Keep the exported document's prefixes (including the default namespace)
    # stable across the ElementTree round trip.
    for prefix, uri in re.findall(r'xmlns(?::(\w+))?="([^"]+)"', xml_text):
        ET.register_namespace(prefix or "", uri)


def set_property_text(prop, name, text):
    # Property children are ordered Label?, Description?, Value* per the OVF
    # schema, so a created element goes first (Label) or right after an
    # existing Label (Description).
    tag = "{%s}%s" % (OVF_NS, name)
    element = prop.find(tag)
    if element is None:
        element = ET.Element(tag)
        label = prop.find("{%s}Label" % OVF_NS)
        index = 0
        if name != "Label" and label is not None:
            index = list(prop).index(label) + 1
        prop.insert(index, element)
    element.text = text


def normalize_ovf(xml_text):
    """Return (normalized xml bytes, foreign property ids).

    The exported Property elements are reordered, not rebuilt, so every
    exported attribute (type, ovf:password, userConfigurable, qualifiers,
    values) is preserved; only the document order, the Category markers and
    the Label/Description texts are made canonical.
    """
    register_document_namespaces(xml_text)
    root = ET.fromstring(xml_text)

    sections = root.findall(".//{%s}ProductSection" % OVF_NS)
    if not sections:
        sys.exit("normalize-library-ovf: no ProductSection in the OVF")

    known = {descriptor.id: descriptor for descriptor in DESCRIPTORS}
    collected = {}
    foreign = []
    for section in sections:
        for child in list(section):
            if child.tag == "{%s}Property" % OVF_NS:
                prop_id = child.get("{%s}key" % OVF_NS)
                if prop_id in known and prop_id not in collected:
                    collected[prop_id] = child
                else:
                    foreign.append(child)
                section.remove(child)
            elif child.tag == "{%s}Category" % OVF_NS:
                section.remove(child)

    missing = [d.id for d in DESCRIPTORS if d.id not in collected]
    if missing:
        sys.exit("normalize-library-ovf: OVF lacks expected properties: %s"
                 % ", ".join(missing))

    # Everything goes back into the first section; extra sections that only
    # carried properties are removed once emptied.
    canonical = sections[0]
    parent_map = {child: parent for parent in root.iter() for child in parent}
    for section in sections[1:]:
        if not [c for c in section if c.tag != "{%s}Info" % OVF_NS]:
            parent_map[section].remove(section)

    last_category = None
    for descriptor in DESCRIPTORS:
        if descriptor.category != last_category:
            category = ET.SubElement(canonical, "{%s}Category" % OVF_NS)
            category.text = descriptor.category
            last_category = descriptor.category
        prop = collected[descriptor.id]
        set_property_text(prop, "Label", descriptor.label)
        set_property_text(prop, "Description", descriptor.description)
        canonical.append(prop)
    if foreign:
        category = ET.SubElement(canonical, "{%s}Category" % OVF_NS)
        category.text = "Other"
        canonical.extend(foreign)

    body = ET.tostring(root, encoding="utf-8", xml_declaration=True)
    foreign_ids = [prop.get("{%s}key" % OVF_NS, "?") for prop in foreign]
    return body, foreign_ids


def update_manifest(mf_text, ovf_name, ovf_bytes):
    lines = []
    updated = False
    for line in mf_text.splitlines():
        match = re.match(r"^(SHA\d+)\((.+)\)=\s*(\S+)\s*$", line)
        if match and match.group(2) == ovf_name:
            algorithm = match.group(1).lower()
            digest = hashlib.new(algorithm, ovf_bytes).hexdigest()
            line = "%s(%s)= %s" % (match.group(1), ovf_name, digest)
            updated = True
        lines.append(line)
    if not updated:
        sys.exit("normalize-library-ovf: %s not found in manifest" % ovf_name)
    return "\n".join(lines) + "\n"


class LibraryClient:
    def __init__(self, host, username, password, insecure):
        self.base = "https://%s" % host
        self.session = requests.Session()
        self.session.verify = not insecure
        if insecure:
            urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)
        response = self.session.post(self.base + "/api/session",
                                     auth=(username, password))
        self._check(response, "login")
        self.session.headers["vmware-api-session-id"] = response.json()

    @staticmethod
    def _check(response, action):
        if response.status_code >= 400:
            sys.exit("normalize-library-ovf: %s failed with HTTP %d: %s"
                     % (action, response.status_code, response.text[:500]))

    def _post(self, path, action, payload=None, params=None):
        response = self.session.post(self.base + path, json=payload,
                                     params=params)
        self._check(response, action)
        return response.json() if response.text else None

    def find_item(self, library_name, item_name):
        libraries = self._post("/api/content/library", "find library",
                               {"name": library_name}, {"action": "find"})
        if not libraries:
            sys.exit("normalize-library-ovf: library %r not found"
                     % library_name)
        items = self._post("/api/content/library/item", "find item",
                           {"library_id": libraries[0], "name": item_name},
                           {"action": "find"})
        if not items:
            sys.exit("normalize-library-ovf: item %r not found in %r"
                     % (item_name, library_name))
        return items[0]

    def _prepared_file(self, sid, name):
        info = self._post(
            "/api/content/library/item/download-session/%s/file" % sid,
            "prepare %s" % name, {"file_name": name}, {"action": "prepare"})
        deadline = time.monotonic() + 300
        while info.get("status") != "PREPARED":
            if time.monotonic() > deadline:
                sys.exit("normalize-library-ovf: timed out preparing %s"
                         % name)
            time.sleep(2)
            response = self.session.get(
                self.base
                + "/api/content/library/item/download-session/%s/file/%s"
                % (sid, name))
            self._check(response, "poll %s" % name)
            info = response.json()
        return info

    def download_files(self, item_id, suffixes):
        sid = self._post("/api/content/library/item/download-session",
                         "create download session",
                         {"library_item_id": item_id})
        try:
            response = self.session.get(
                self.base + "/api/content/library/item/download-session/%s/file"
                % sid)
            self._check(response, "list session files")
            wanted = {}
            for info in response.json():
                name = info["name"]
                if not name.lower().endswith(suffixes):
                    continue
                prepared = self._prepared_file(sid, name)
                uri = prepared["download_endpoint"]["uri"]
                content = self.session.get(uri)
                self._check(content, "download %s" % name)
                wanted[name] = content.content
            return wanted
        finally:
            self.session.delete(
                self.base + "/api/content/library/item/download-session/%s"
                % sid)

    def upload_files(self, item_id, files):
        sid = self._post("/api/content/library/item/update-session",
                         "create update session",
                         {"library_item_id": item_id})
        try:
            for name, data in files.items():
                info = self._post(
                    "/api/content/library/item/update-session/%s/file" % sid,
                    "register %s" % name,
                    {"name": name, "source_type": "PUSH", "size": len(data)})
                response = self.session.put(
                    info["upload_endpoint"]["uri"], data=data)
                self._check(response, "upload %s" % name)
            self._post("/api/content/library/item/update-session/%s" % sid,
                       "complete update session", params={"action": "complete"})
        except SystemExit:
            self.session.post(
                self.base + "/api/content/library/item/update-session/%s" % sid,
                params={"action": "fail"})
            raise


def main():
    client = LibraryClient(
        env("VCENTER_SERVER"), env("VCENTER_USERNAME"),
        env("VCENTER_PASSWORD"),
        os.environ.get("VCENTER_INSECURE", "false").lower() == "true")
    item_id = client.find_item(env("LIBRARY_NAME"), env("TEMPLATE_NAME"))
    files = client.download_files(item_id, (".ovf", ".mf", ".cert"))

    ovf_names = [n for n in files if n.lower().endswith(".ovf")]
    if len(ovf_names) != 1:
        sys.exit("normalize-library-ovf: expected one .ovf, found %r"
                 % ovf_names)
    if any(n.lower().endswith(".cert") for n in files):
        sys.exit("normalize-library-ovf: item is signed (.cert present);"
                 " refusing to modify it")
    ovf_name = ovf_names[0]

    body, foreign_ids = normalize_ovf(files[ovf_name].decode("utf-8"))
    upload = {ovf_name: body}
    mf_names = [n for n in files if n.lower().endswith(".mf")]
    if mf_names:
        upload[mf_names[0]] = update_manifest(
            files[mf_names[0]].decode("utf-8"), ovf_name, body).encode("utf-8")

    client.upload_files(item_id, upload)
    message = ("normalize-library-ovf: deploy form normalized in %s"
               % env("TEMPLATE_NAME"))
    if foreign_ids:
        message += " (preserved foreign properties: %s)" % ", ".join(foreign_ids)
    print(message)


if __name__ == "__main__":
    main()

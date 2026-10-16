#!/usr/bin/env python3
"""Export exact Frame source packets for Haneoka renderer adapters."""

import argparse
import gzip
import hashlib
import json
import os
import tempfile
from pathlib import Path, PurePosixPath


def digest(data):
    return hashlib.sha256(data).hexdigest()


SNAPSHOT_RESOURCES = (
    "frames-source.json", "yume-frames-source.json", "frame-shader-metadata.json",
    "yume-frame-shader-bindings.json", "frame-canvas-scaler.json",
    "frame-view-root.json", "frame-tiled-texture-wrap.json",
)


def canonical(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=False, allow_nan=False,
                      separators=(",", ":")).encode()


def snapshot_compatibility(result, configuration):
    config = json.loads(configuration.read_bytes())
    if config["schema"] != "haneoka-frame-snapshot-input-v1":
        raise ValueError("Unknown Frame snapshot input schema")
    source_id = result["sourceId"]
    receipt = []

    def read(row):
        path = Path(row["path"])
        encoded = path.read_bytes()
        if digest(encoded) != row["sha256"]:
            raise ValueError(f"Frame snapshot input hash differs: {row['logicalName']}")
        packet = json.loads(encoded)
        if packet["sourceId"] != source_id:
            raise ValueError(f"Frame snapshot input source differs: {row['logicalName']}")
        receipt.append({"logicalName": row["logicalName"], "path": str(path.resolve()),
                        "sha256": digest(encoded), "sourceId": source_id})
        return packet

    if result != read(config["current"]):
        raise ValueError("Frame snapshot current packet differs from declared input")
    companion = read(config["companion"])
    auxiliary = config["resources"]
    if set(auxiliary) != set(SNAPSHOT_RESOURCES[2:]):
        raise ValueError("Frame snapshot auxiliary resource names differ")
    for row in auxiliary.values():
        read(row)

    def definitions(packet):
        frames = dict(packet["frames"])
        for ref, frame in companion["frames"].items():
            if ref in frames:
                raise ValueError(f"Frame snapshot duplicate definition: {ref}")
            frames[ref] = frame
        return {ref: digest(canonical({"sourceId": source_id, "ref": ref, "definition": frame}))
                for ref, frame in frames.items()}

    # Only build provenance changes here; archived definition entries remain intact.
    absolute_provenance = []
    def relative(path, marker):
        if not str(path).startswith("/"):
            return path
        parts = PurePosixPath(path).parts
        if marker not in parts:
            raise ValueError(f"Frame provenance path has no {marker} root: {path}")
        absolute_provenance.append(str(path))
        return str(PurePosixPath(*parts[parts.index(marker):]))

    result["sourceIndexPath"] = relative(result["sourceIndexPath"], "metadata")
    for archive in result["objectArchives"]:
        archive["archivePath"] = relative(archive["archivePath"], "objects")
    for ref in ("adv_frame_kirakira_1/adv_frame_kirakira_1",
                "adv_frame_comic_speedline/adv_frame_comic_speedline_white"):
        proof = result["frames"][ref]["particleEnvironment"]["globalSettingsProvenance"]
        absolute_provenance.extend([proof["path"], proof["source"]])
        result["frames"][ref]["particleEnvironment"]["globalSettingsProvenance"] = {
            "logicalName": "particle-global-settings-source.json", "sha256": proof["sha256"],
            "sourceLogicalName": "gekisou-effect-profile.json", "sourceSHA256": proof["SHA256"],
            "sourceId": source_id, "formalSource": proof["formalSource"],
        }
    current = definitions(result)
    legacy = []
    for row in config["legacyCatalogs"]:
        packet = read(row)
        known = definitions(packet)
        for ref, fingerprint in known.items():
            if current.get(ref) != fingerprint:
                raise ValueError(f"Archived Frame definition differs: {row['logicalName']}:{ref}")
        hashes = {"frames-source.json": row["sha256"],
                  "yume-frames-source.json": config["companion"]["sha256"],
                  **{name: value["sha256"] for name, value in auxiliary.items()}}
        legacy.append({"versions": [1, 2], "packetHashes": hashes, "definitions": known,
                       "provenance": {"logicalName": row["logicalName"], "sha256": row["sha256"],
                                      "sourceId": source_id}})
    result["snapshotCompatibility"] = {
        "schema": "haneoka-frame-snapshot-catalog-v1", "sourceId": source_id,
        "currentDefinitions": current, "legacyCatalogs": legacy,
        "provenance": {"companion": {"logicalName": config["companion"]["logicalName"],
                                     "sha256": config["companion"]["sha256"], "sourceId": source_id},
                       "resources": {name: {"logicalName": name, "sha256": row["sha256"],
                                             "sourceId": source_id}
                                     for name, row in auxiliary.items()}},
    }
    def validate_portable(value):
        if isinstance(value, dict):
            for item in value.values():
                validate_portable(item)
        elif isinstance(value, list):
            for item in value:
                validate_portable(item)
        elif isinstance(value, str) and (value.startswith("/home/") or value.startswith("/tmp/")):
            raise ValueError(f"Absolute build path remains in Frame packet: {value}")
    validate_portable(result)
    return {"inputs": receipt, "normalizedAbsoluteProvenance": absolute_provenance,
            "currentDefinitions": len(current), "legacyDefinitions": [len(row["definitions"]) for row in legacy]}


class SourceCatalog:
    def __init__(self, release_root, source_index, particle_global_settings=None):
        self.root = release_root
        self.particle_global_settings = particle_global_settings
        self.index_bytes = source_index.read_bytes()
        self.index = json.loads(self.index_bytes)
        release = json.loads((release_root / "release.json").read_bytes())
        if (release["sourceId"] != self.index["sourceId"] or
                release["server"] != self.index["server"]):
            raise ValueError("Frame source index and release identity differ")
        self.source_id = release["sourceId"]
        self.entries = {row["path"]: row for row in release["entries"]}
        self.archives = {}
        self.provenance = {}
        self.outputs = {}
        for asset, entry in self.index["sources"].items():
            for row in entry.get("outputs", []):
                key = (row.get("serializedFile"), str(row.get("objectId")))
                self.outputs.setdefault(key, []).append({"source_path": asset, **row})

    def read(self, relative):
        path = PurePosixPath(relative)
        if path.is_absolute() or ".." in path.parts:
            raise ValueError(f"Invalid release path: {relative}")
        expected = self.entries[relative]
        encoded = (self.root / relative).read_bytes()
        if len(encoded) != expected["bytes"] or digest(encoded) != expected["sha256"]:
            raise ValueError(f"Release content hash mismatch: {relative}")
        return encoded

    def objects(self, serialized_file):
        if serialized_file not in self.archives:
            entry = self.index["serializedFiles"][serialized_file]
            path = entry["objectArchive"]
            encoded = self.read(path)
            rows = [json.loads(line) for line in gzip.decompress(encoded).splitlines()]
            header = rows[0]
            if (header.get("record") != "header" or
                    header.get("bundleSha256") != entry["bundleSha256"] or
                    serialized_file not in header["serializedFiles"]):
                raise ValueError(f"Frame object archive identity mismatch: {path}")
            records = {str(row["pathId"]): row for row in rows[1:]
                       if row.get("record") == "object" and row["serializedFile"] == serialized_file}
            if len(records) != entry["objectCount"] or len(rows) - 1 != entry["archiveObjectCount"]:
                raise ValueError(f"Frame object archive count mismatch: {path}")
            self.archives[serialized_file] = records
            self.provenance[serialized_file] = {
                "serializedFile": serialized_file,
                "bundleSHA256": entry["bundleSha256"],
                "archivePath": path,
                "archiveSHA256": digest(encoded),
            }
        return self.archives[serialized_file]

    def resolve(self, pointer, owner, expected):
        path_id = str(pointer["m_PathID"])
        if path_id == "0":
            return None
        if pointer["m_FileID"] == 0:
            serialized_file = owner
        else:
            reference = pointer.get("reference", {})
            if reference.get("status") != "resolved" or str(reference["pathId"]) != path_id:
                raise ValueError(f"Unresolved Frame source reference: {owner}:{path_id}")
            serialized_file = reference["serializedFile"]
        record = self.objects(serialized_file)[path_id]
        if record["type"] != expected:
            raise ValueError(f"Expected {expected}: {serialized_file}:{path_id}")
        return record

    def particle_environment(self):
        def source(path):
            descriptor_path = "metadata/" + self.index["sources"][path]["descriptor"].removeprefix("metadata/")
            encoded = self.read(descriptor_path)
            descriptor = json.loads(encoded)
            return descriptor, self.objects(descriptor["serializedFile"]), {
                "path": path, "contentSHA256": descriptor["contentSha256"],
                "descriptorPath": descriptor_path, "descriptorSHA256": digest(encoded)}
        manager, objects, manager_proof = source("Assets/AddressableResources/Common/Prefab/UIManager.prefab")
        controllers = [row for row in objects.values() if "_uiCamera" in row.get("data", {})]
        if len(controllers) != 1:
            raise ValueError("Expected one formal UIManager camera controller")
        camera = self.resolve(controllers[0]["data"]["_uiCamera"], manager["serializedFile"], "Camera")
        transforms = {str(row["data"]["m_GameObject"]["m_PathID"]): row
                      for row in objects.values() if row["type"] == "Transform"}
        transform = transforms[str(camera["data"]["m_GameObject"]["m_PathID"])]
        chain, seen = [], set()
        while transform is not None:
            identity = str(transform["pathId"])
            if identity in seen:
                raise ValueError("Formal UI camera Transform cycle")
            seen.add(identity)
            chain.append(transform)
            transform = self.resolve(transform["data"]["m_Father"], manager["serializedFile"], "Transform")
        widget, widget_objects, widget_proof = source("Assets/AddressableResources/UI/Prefab/UIAdvWidget.prefab")
        canvases = [row for row in widget_objects.values() if row["type"] == "Canvas"
                    and row["data"].get("m_SortingOrder") == 303
                    and row["data"].get("m_RenderMode") == 1 and row["data"].get("m_Enabled")]
        if len(canvases) != 1 or not camera["data"]["orthographic"]:
            raise ValueError("Formal Frame canvas/camera contract differs")
        if self.particle_global_settings is None:
            raise ValueError("UIParticle source requires --particle-global-settings")
        encoded = self.particle_global_settings.read_bytes()
        global_document = json.loads(encoded)
        return {"camera": camera, "cameraTransformChain": chain,
                "cameraSource": manager_proof, "canvas": canvases[0],
                "canvasSource": widget_proof,
                "globalSettings": global_document["globalSettings"],
                "globalSettingsProvenance": {"path": str(self.particle_global_settings),
                                             "sha256": digest(encoded),
                                             **global_document.get("provenance", {})}}

    def particle_resources(self, objects, owner):
        renderers = [row for row in objects if row["type"] == "ParticleSystemRenderer"]
        if not renderers:
            return {}
        resources, outputs, bindings = {}, {}, []
        def take(pointer, source_owner, kind):
            identity = str(pointer["m_PathID"])
            if identity == "0":
                return None
            if pointer["m_FileID"] != 0 and not pointer.get("reference"):
                candidates, proofs = set(), []
                for asset, row in self.index["sources"].items():
                    if row.get("serializedFile") != source_owner:
                        continue
                    descriptor_path = row["descriptor"]
                    if not descriptor_path.startswith("metadata/"):
                        descriptor_path = "metadata/" + descriptor_path
                    encoded = self.read(descriptor_path)
                    descriptor = json.loads(encoded)
                    for target in descriptor.get("preloadObjectReferences", []):
                        if str(target["pathId"]) != identity:
                            continue
                        candidates.add(target["serializedFile"])
                        proofs.append({"path": descriptor_path, "sha256": digest(encoded)})
                if len(candidates) != 1:
                    raise ValueError(f"Ambiguous particle preload binding: {source_owner}:{identity}")
                target_owner = candidates.pop()
                record = self.objects(target_owner)[identity]
                if record["type"] != kind:
                    raise ValueError(f"Particle preload type differs: {source_owner}:{identity}:{kind}")
                bindings.append({"owner": source_owner, "fileId": pointer["m_FileID"],
                                 "pathId": identity, "serializedFile": target_owner,
                                 "type": kind, "provenance": proofs})
            else:
                record = self.resolve(pointer, source_owner, kind)
            if record is not None:
                resources[f"{record['serializedFile']}:{record['pathId']}"] = record
            return record
        for renderer in renderers:
            for pointer in renderer["data"]["m_Materials"]:
                material = take(pointer, owner, "Material")
                if material is None:
                    continue
                take(material["data"]["m_Shader"], material["serializedFile"], "Shader")
                for env in material["data"]["m_SavedProperties"]["m_TexEnvs"]:
                    value = env["second"] if isinstance(env, dict) else env[1]
                    texture = take(value["m_Texture"], material["serializedFile"], "Texture2D")
                    if texture is None:
                        continue
                    identity = (texture["serializedFile"], str(texture["pathId"]))
                    matches = [item for item in self.outputs.get(identity, [])
                               if item["type"] == "Texture2D" and item["path"].endswith(".png")]
                    if len(matches) != 1:
                        raise ValueError(f"Expected one source particle Texture2D output: {identity}")
                    self.read(matches[0]["path"])
                    outputs[":".join(identity)] = matches
        environment = {"server": self.index["server"], **self.particle_environment()}
        links = {(item["owner"], item["fileId"], item["pathId"]): item for item in bindings}
        def normalize(value, source_owner):
            if isinstance(value, list):
                return [normalize(item, source_owner) for item in value]
            if not isinstance(value, dict):
                return value
            result = {key: normalize(item, source_owner) for key, item in value.items()}
            if "m_PathID" in result and "m_FileID" in result:
                result["m_PathID"] = str(result["m_PathID"])
                link = links.get((source_owner, result["m_FileID"], result["m_PathID"]))
                if link is not None and not result.get("reference"):
                    result["reference"] = {"status": "resolved", "serializedFile": link["serializedFile"],
                                           "pathId": link["pathId"], "type": link["type"]}
            return result
        graph = {}
        for raw in [*objects, *resources.values(), environment["camera"], *environment["cameraTransformChain"]]:
            key = f"{raw['serializedFile']}:{raw['pathId']}"
            record = normalize(raw, raw["serializedFile"])
            record["pathId"] = str(record["pathId"])
            graph[key] = {"record": record, "normalization": "pptr-decimal64-v1",
                          "sha256": digest(json.dumps(raw, sort_keys=True, separators=(",", ":")).encode())}
        return {"particleResources": resources, "particleResourceOutputs": outputs,
                "particleExternalPreloads": bindings, "particleEnvironment": environment,
                "particleGraph": {"schema": "haneoka-native-fx-shared-render-data-v1", "objects": graph}}

    def frame(self, name):
        asset = f"Assets/AddressableResources/Adv/Frame/{name}.prefab"
        path = f"metadata/sources/{asset}.json"
        encoded = self.read(path)
        descriptor = json.loads(encoded)
        indexed = self.index["sources"][asset]
        if descriptor["contentSha256"] != indexed["contentSha256"]:
            raise ValueError(f"Frame descriptor and source index differ: {asset}")
        owner = descriptor["serializedFile"]
        objects = [row for row in self.objects(owner).values() if row["type"] != "AssetBundle"]
        scripts, sprites, materials, outputs = {}, {}, {}, {}
        adv = None
        for row in objects:
            if row["type"] != "MonoBehaviour":
                continue
            raw = row["data"]
            script = self.resolve(raw["m_Script"], owner, "MonoScript")
            if script is None:
                raise ValueError(f"Missing Frame source script: {asset}:{row['pathId']}")
            key = str(script["pathId"])
            if key in scripts and scripts[key] != script:
                raise ValueError(f"Ambiguous Frame script identity: {key}")
            scripts[key] = script
            if script["data"]["m_ClassName"] == "AdvFrame":
                if adv is not None:
                    raise ValueError(f"Multiple Frame controllers: {asset}")
                adv = row
            if script["data"]["m_ClassName"] != "Image":
                continue
            for field, kind, destination in [("m_Sprite", "Sprite", sprites),
                                              ("m_Material", "Material", materials)]:
                record = self.resolve(raw[field], owner, kind)
                if record is None:
                    continue
                identity = (record["serializedFile"], str(record["pathId"]))
                resource_key = ":".join(identity)
                destination[resource_key] = record
                if kind == "Sprite":
                    matches = [item for item in self.outputs.get(identity, [])
                               if item["type"] == "Sprite" and item["path"].endswith(".png")]
                    if len(matches) != 1:
                        raise ValueError(f"Expected one source Sprite output: {resource_key}")
                    self.read(matches[0]["path"])
                    outputs[resource_key] = matches
        if adv is None:
            raise ValueError(f"Missing AdvFrame source component: {asset}")
        animator = self.resolve(adv["data"]["_animator"], owner, "Animator")
        controller, clips = None, []
        if animator is not None:
            controller = self.resolve(animator["data"]["m_Controller"], owner, "AnimatorController")
            for pointer in controller["data"]["m_AnimationClips"]:
                clip = self.resolve(pointer, controller["serializedFile"], "AnimationClip")
                clips.append({"pointer": pointer, "object": clip})
        return {
            "source": {"source_path": asset, "content_sha256": descriptor["contentSha256"],
                       "descriptor_path": path, "selected_bundle_sha256": descriptor["selectedBundle"],
                       "serialized_file": owner},
            "descriptorSHA256": digest(encoded), "descriptorRootObjects": descriptor["rootObjects"],
            "objects": objects, "advFrame": adv, "animator": animator, "controller": controller,
            "clips": clips, "sprites": sprites, "materials": materials,
            "resourceOutputs": outputs, "resolvedScripts": scripts,
            **self.particle_resources(objects, owner),
        }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--release-root", type=Path, required=True)
    parser.add_argument("--source-index", type=Path, required=True)
    parser.add_argument("--frame", action="append", default=[])
    parser.add_argument("--merge-packet", type=Path)
    parser.add_argument("--particle-global-settings", type=Path)
    parser.add_argument("--snapshot-compatibility-input", type=Path)
    parser.add_argument("--snapshot-receipt", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if not args.frame and not (args.merge_packet and args.snapshot_compatibility_input):
        parser.error("--frame or --merge-packet with --snapshot-compatibility-input is required")
    if args.snapshot_compatibility_input and args.snapshot_receipt is None:
        parser.error("--snapshot-receipt is required with --snapshot-compatibility-input")
    catalog = SourceCatalog(args.release_root.resolve(), args.source_index.resolve(), args.particle_global_settings)
    result = json.loads(args.merge_packet.read_bytes()) if args.merge_packet else {
        "schema": "haneoka-frame-source-packet-v1", "sourceId": catalog.source_id,
        "sourceIndexPath": "metadata/source-index.json", "sourceIndexSHA256": digest(catalog.index_bytes),
        "frames": {}, "objectArchives": [],
    }
    if result["sourceId"] != catalog.source_id or result["schema"] != "haneoka-frame-source-packet-v1":
        raise ValueError("Cannot merge Frame packets from different sources")
    for name in args.frame:
        if PurePosixPath(name).is_absolute() or ".." in PurePosixPath(name).parts:
            raise ValueError(f"Invalid Frame asset name: {name}")
        packet = catalog.frame(name)
        # A non-finite raw Unity property needs an explicit wire encoding;
        # Python's permissive Infinity token cannot enter Dart/JSON packets.
        json.dumps(packet, allow_nan=False)
        result["frames"][name] = packet
    archives = {row["serializedFile"]: row for row in result["objectArchives"]}
    archives.update(catalog.provenance)
    result["objectArchives"] = [archives[key] for key in sorted(archives)]
    compatibility_receipt = None
    if args.snapshot_compatibility_input:
        compatibility_receipt = snapshot_compatibility(result, args.snapshot_compatibility_input)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    encoded = (json.dumps(result, ensure_ascii=False, allow_nan=False, separators=(",", ":")) + "\n").encode()
    with tempfile.NamedTemporaryFile(dir=args.output.parent, delete=False) as pending:
        pending.write(encoded)
        temporary = pending.name
    try:
        os.replace(temporary, args.output)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    if compatibility_receipt is not None:
        compatibility_receipt["output"] = {"path": str(args.output.resolve()), "sha256": digest(encoded)}
        args.snapshot_receipt.write_text(json.dumps(compatibility_receipt, indent=2) + "\n")
    print(json.dumps({"frameCount": len(result["frames"]), "exported": args.frame,
                      "bytes": len(encoded), "sha256": digest(encoded)}))


if __name__ == "__main__":
    main()

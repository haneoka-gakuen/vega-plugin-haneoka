#!/usr/bin/env python3
"""Compile release Chat prefab packets into a renderer-independent UI profile."""
import argparse
import hashlib
import json
import math
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--packet", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    packet = json.loads(args.packet.read_text())
    profiles = {}
    for asset, domain in packet["windows"].items():
        rows = {r["pathId"]: r for r in domain["records"]}
        transforms = {r["data"]["m_GameObject"]["m_PathID"]: r
                      for r in rows.values() if r["type"] == "RectTransform"}
        by_id = {r["pathId"]: r for r in transforms.values()}
        components = {}
        for row in rows.values():
            go = row["data"].get("m_GameObject", {}).get("m_PathID")
            if go and row["type"] != "RectTransform":
                components.setdefault(go, []).append(row)

        def script(row):
            return row["data"].get("m_Script", {}).get("reference", {}).get("name", row["type"])

        controller = next(r["data"] for r in rows.values() if script(r) == "AdvChatWindow")

        def pointer(value):
            return str((value or {}).get("m_PathID", "0"))

        def target(value):
            row = rows.get(pointer(value))
            if row is None:
                return None
            data = row["data"]
            if "_targetText" in data:
                return target(data["_targetText"])
            if row["type"] == "GameObject":
                return transforms[row["pathId"]]
            return transforms.get(pointer(data.get("m_GameObject")))

        def component(tr, kind):
            return next((r for r in components.get(pointer(tr["data"]["m_GameObject"]), [])
                         if script(r) == kind), None)

        root = target(controller["m_GameObject"])
        children = [by_id[pointer(p)] for p in root["data"]["m_Children"]]
        mask = next(r for r in children if component(r, "Mask"))
        overlay = next(r for r in children if component(r, "Image") and r != mask)
        mask_children = [by_id[pointer(p)] for p in mask["data"]["m_Children"]]

        def active(tr):
            return rows[pointer(tr["data"]["m_GameObject"])]["data"]["m_IsActive"] in [1, True]

        def area(tr):
            size = tr["data"]["m_SizeDelta"]
            return abs(size["x"] * size["y"])

        backgrounds = [r for r in mask_children if active(r) and component(r, "Image")
                       and component(r, "Image")["data"]["m_Color"]["a"] > 0]
        background = max(backgrounds, key=area)
        title = target(controller["_windowNameText"])
        top = by_id[pointer(title["data"]["m_Father"])]
        roles = {"root": root, "mask": mask, "overlay": overlay,
                 "background": background, "top": top}
        def descendants(tr):
            if tr is None:
                return
            yield tr
            for child in tr["data"]["m_Children"]:
                yield from descendants(by_id[pointer(child)])

        # The screen object is selected by the controller, not by a prefab name.
        for role, field in [("lockBackground", "_lockScreenObject"),
                            ("incomingBackground", "_incomingCallObject")]:
            candidates = [tr for tr in descendants(target(controller.get(field)))
                          if component(tr, "Image") and component(tr, "Image")["data"]["m_Color"]["a"] > 0]
            if candidates:
                roles[role] = max(candidates, key=area)
        # These are common source sprite semantics, shared by all window prefabs.
        graphic_roles = {"signal": "signal", "rss": "rss", "alarm": "alarm", "navi": "navi",
                         "arrow_back": "back", "call": "call", "bars": "bars", "battery_frame": "batteryFrame"}
        for tr in descendants(top):
            image = component(tr, "Image")
            name = image["data"]["m_Sprite"].get("reference", {}).get("name") if image else None
            if name in graphic_roles:
                roles[graphic_roles[name]] = tr
        for role, field in [("title", "_windowNameText"), ("batteryText", "_batteryPercentageText"),
                            ("batteryFill", "_batteryFillImage"), ("messages", "_viewport"),
                            ("typing", "_typingIndicatorBottomRect"),
                            ("incomingName", "_incomingCallNameText"),
                            ("incomingLabel", "_incomingCallStatusText"),
                            ("lockLabel", "_lockScreenStatusText"), ("typingText", "_typingContentText")]:
            tr = target(controller.get(field))
            if tr:
                roles[role] = tr
        for side, field in [("my", "_myChatNodePrefab"), ("other", "_otherChatNodePrefab")]:
            template = rows[pointer(controller[field])]["data"]
            for suffix, endpoint in [("Bubble", "_textBox"), ("Text", "_talkText"),
                                     ("Name", "_senderNameText"), ("Read", "_readText")]:
                tr = target(template.get(endpoint))
                if tr:
                    roles[side + suffix] = tr
        closure = {}
        for tr in roles.values():
            while tr and tr["pathId"] not in closure:
                closure[tr["pathId"]] = tr
                tr = by_id.get(pointer(tr["data"].get("m_Father")))
        nodes = []
        for pid, tr in closure.items():
            raw = tr["data"]
            parent = pointer(raw["m_Father"])
            q = raw["m_LocalRotation"]
            if abs(q["x"]) > 1e-7 or abs(q["y"]) > 1e-7:
                raise ValueError(f"Unexpected static Chat source rotation: {asset}:{pid}")
            nodes.append({"id": pid, **({"parent": parent} if parent in closure else {}),
                          "anchorMin": [raw["m_AnchorMin"][c] for c in ["x", "y"]],
                          "anchorMax": [raw["m_AnchorMax"][c] for c in ["x", "y"]],
                          "pivot": [raw["m_Pivot"][c] for c in ["x", "y"]],
                          "position": [raw["m_AnchoredPosition"][c] for c in ["x", "y"]],
                          "size": [raw["m_SizeDelta"][c] for c in ["x", "y"]],
                          "scale": [raw["m_LocalScale"]["x"], raw["m_LocalScale"]["y"]],
                          "rotation": 2 * math.atan2(q["z"], q["w"]), "opacity": 1, "active": True})
        role_data = {}
        for role, tr in roles.items():
            image = component(tr, "Image")
            text = next((r for r in components.get(pointer(tr["data"]["m_GameObject"]), [])
                         if "m_fontAsset" in r["data"]), None)
            value = {"node": tr["pathId"]}
            if image:
                image = image["data"]
                ref = image["m_Sprite"].get("reference")
                sprite = packet["sprites"].get(f"{ref['serializedFile']}:{ref['pathId']}") if ref else None
                outputs = (sprite["textureOutputs"] or sprite["outputs"]) if sprite else []
                value["image"] = {"color": [image["m_Color"][c] for c in ["r", "g", "b", "a"]],
                                  "source": outputs[0]["sourcePath"] if outputs else None,
                                  "type": image["m_Type"], "ppuMultiplier": image["m_PixelsPerUnitMultiplier"]}
                if sprite:
                    value["image"]["sprite"] = {"border": sprite["border"], "rect": sprite["rect"],
                                                  "ppu": sprite["pixelsToUnits"]}
            if text:
                text = text["data"]
                value["text"] = {"color": [text["m_fontColor"][c] for c in ["r", "g", "b", "a"]],
                                 "fontSize": text["m_fontSize"], "fontStyle": text["m_fontStyle"],
                                 "wrappingMode": text["m_TextWrappingMode"],
                                 "overflowMode": text["m_overflowMode"]}
            role_data[role] = value
        data_root = packet["chatAssets"]["dataRootsByWindowAsset"].get(asset, packet["chatAssets"]["defaultDataRoot"])
        group = bool(controller["_isGroupChat"])
        layout_mode = controller["_chatLayoutMode"]
        profiles[asset] = {"sourceHash": domain["sourceHash"], "dataRoot": data_root,
                           "rootSize": [root["data"]["m_SizeDelta"][c] for c in ["x", "y"]],
                           "roles": role_data, "layout": {"referenceWidth": root["data"]["m_SizeDelta"]["x"], "nodes": nodes},
                           "group": group, "layoutMode": layout_mode,
                           "visibility": {"identity": layout_mode != 1 or group,
                                          "read": layout_mode != 1},
                           "windowPosition": controller["_windowPosition"], "windowRotation": controller["_windowRotation"]}
    result = {"schema": "haneoka-chat-window-profile-v1", "sourceId": packet["sourceId"],
              "packetSHA256": hashlib.sha256(args.packet.read_bytes()).hexdigest(),
              "referencePixelsPerUnit": 100, "profiles": profiles}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, ensure_ascii=False, separators=(",", ":")) + "\n")
    print(f"Exported {len(profiles)} Source window profiles to {args.output}")


if __name__ == "__main__":
    main()

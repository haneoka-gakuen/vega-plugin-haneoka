/**
 * Copyright 2026 Haneoka Gakuen contributors.
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

const ADV_CHAT_COMMON_SPRITES =
  "Assets/AddressableResources/Adv/Chat/Common/Sprites";

/**
 * Source paths for the native ADV chat chrome.
 *
 * This is metadata only. The plugin does not contain, fetch, or redistribute
 * the referenced game assets; an authorized host decides how to resolve them.
 */
export const HANEOKA_CHAT_ICON_SOURCE_PATHS = Object.freeze({
  signal: `${ADV_CHAT_COMMON_SPRITES}/signal.png`,
  rss: `${ADV_CHAT_COMMON_SPRITES}/rss.png`,
  alarm: `${ADV_CHAT_COMMON_SPRITES}/alarm.png`,
  navi: `${ADV_CHAT_COMMON_SPRITES}/navi.png`,
  back: `${ADV_CHAT_COMMON_SPRITES}/arrow_back.png`,
  bars: `${ADV_CHAT_COMMON_SPRITES}/bars.png`,
  call: `${ADV_CHAT_COMMON_SPRITES}/call.png`,
  batteryFrame: `${ADV_CHAT_COMMON_SPRITES}/battery_frame.png`,
});

export type HaneokaChatIconSprites = Readonly<
  Record<keyof typeof HANEOKA_CHAT_ICON_SOURCE_PATHS, string>
>;

export const resolveHaneokaChatIconSprites = (
  sourceAsset: (path: string) => string,
): HaneokaChatIconSprites =>
  Object.freeze(
    Object.fromEntries(
      Object.entries(HANEOKA_CHAT_ICON_SOURCE_PATHS).map(([key, path]) => [
        key,
        sourceAsset(path),
      ]),
    ) as unknown as Record<
      keyof typeof HANEOKA_CHAT_ICON_SOURCE_PATHS,
      string
    >,
  );

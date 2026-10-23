# Vega Haneoka

Vega Haneoka connects [Vega](https://github.com/haneoka-gakuen/vega) to a
host that serves *BanG Dream! Our Notes* data the way
[haneoka.org](https://haneoka.org) does. It turns the game's story data into
something Vega can play — characters, Live2D models, chat-phone scenes, voice
and lip sync, backgrounds and stills — and routes resource loading, saves and
input through one small bridge your application implements. It also contains
the Home Spot scene: the game's 3D lobby with Spine characters, rendered with
Three.js.

Use it together with the [Haneoka theme](https://github.com/haneoka-gakuen/vega-theme-haneoka)
for the game's look, and [Vega Cubism](https://github.com/haneoka-gakuen/vega-plugin-cubism)
for Live2D.

## Install

```sh
pnpm add @haneoka/vega @haneoka/vega-plugin-haneoka
```

No game assets, model data or proprietary runtimes are included. Your host
serves the resources it is allowed to serve.

## Use it

```ts
import { VegaEngine } from "@haneoka/vega/engine";
import { createHaneokaPlugin } from "@haneoka/vega-plugin-haneoka";

const haneoka = createHaneokaPlugin({
  storageNamespace: "my-player",
  bridge: {
    loadResource: (key, signal) => fetch(`/assets/${key}`, { signal }).then(async (r) => new Uint8Array(await r.arrayBuffer())),
    readStorage: async (key) => JSON.parse(localStorage.getItem(key) ?? "null") ?? undefined,
    writeStorage: async (key, value) => localStorage.setItem(key, JSON.stringify(value)),
    deleteStorage: async (key) => localStorage.removeItem(key),
  },
});

const engine = new VegaEngine({ officialPlugins: [haneoka] });
```

The plugin (`haneoka.host`) contributes a resource provider, a storage port
and — if the bridge supports it — an input source, and provides the bridge as
the `HANEOKA_HOST_BRIDGE` service for other plugins.

### The bridge

| Method | Purpose |
| --- | --- |
| `loadResource(key, signal)` | Return the bytes of a resource. Keys are the canonical paths used in the story data. |
| `readStorage(key, signal?)` | Read a saved value; `undefined` if there is none. |
| `writeStorage(key, value, signal?)` | Save a value (saves, settings, read history). |
| `deleteStorage(key, signal?)` | Remove a value. |
| `subscribeInput(listener, signal)` (optional) | Feed host input — gamepad, native keys — into Vega. |
| `translate(key, fallback, locale?)` (optional) | Localize the plugin's own interface strings. |

Storage keys are prefixed with `storageNamespace`. `storagePriority` and
`inputPriority` decide which storage and input wins when several plugins
offer one.

## Story data

| Export | What it does |
| --- | --- |
| `createHaneokaStoryAdapter(fields)` | Returns a function that rewrites a story's provider-specific character fields into Vega's portable character model entries. |
| `hydrateStoryPayload`, `hydrateStoryTextPayload` | Resolve every resource a story refers to, and report the missing ones. |
| `haneokaStoryResourceAliases` | The resource kinds a story uses and how they map to paths. |
| `normalizeHaneokaCharacterEntry`, `…StoryCharacterEntry`, `…SpineCharacterEntry` | Character entries for Live2D, story and Spine characters. |
| `createHaneokaReleaseResourceScope` | Pins all resource requests to one game release. |
| `projectHaneokaTranscript` | A story as a readable transcript (lines, speakers, images, video), for text mode. |

## Live2D and lip sync

| Export | What it does |
| --- | --- |
| `resolveHaneokaCubismRuntimeSource` | Finds the right Cubism runtime and files for a model. |
| `resolveHaneokaLive2DCatalogSource` | Reads the Live2D catalogue, including background-model paths. |
| `haneokaFallbackMotionSyncAudioScales` | Vowel-to-mouth scales for lip sync when a model has no MotionSync data. |

## Native Cubism controls

The Dart `NativeCubismModelHost` evaluates source prefabs on the host's accepted
scene clock. `setBreathMotionEnabled` changes harmonic breathing on the next
accepted update while retaining the current motion, expression and physics state.

## Chat phone

`resolveHaneokaChatIconSprites` and `HANEOKA_CHAT_ICON_SOURCE_PATHS` provide
the icons used by the in-story chat phone; `HANEOKA_ADV_CHAT_DEFAULT_DATA_ROOT`
is where chat data lives.

## Home Spot

`createHaneokaThreeSpineHomeSpotScene` renders the game's lobby scene — the
room and its Spine characters — with Three.js. The scene's `exportPng()`
returns the current view as a PNG `Blob`.

## License

MPL-2.0. See [LICENSE](LICENSE).

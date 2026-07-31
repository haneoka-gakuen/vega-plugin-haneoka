# `@haneoka/vega-plugin-haneoka`

Connects Vega to Haneoka-compatible resources, storage, input, localization,
story data, phone scenes, and host-provided character metadata.

```ts
import { createVega } from "@haneoka/vega/engine";
import { createHaneokaPlugin } from "@haneoka/vega-plugin-haneoka";

const plugin = createHaneokaPlugin({
  bridge: {
    loadResource: (key, signal) => host.resources.read(key, signal),
    readStorage: (key, signal) => host.storage.read(key, signal),
    writeStorage: (key, value, signal) =>
      host.storage.write(key, value, signal),
    deleteStorage: (key, signal) => host.storage.delete(key, signal),
    subscribeInput: (listener, signal) =>
      host.input.subscribe(listener, signal),
  },
  storageNamespace: "my-game",
});

const engine = createVega({ plugins: [plugin] });
const stopInput = engine.onInput((event) => host.input.handle(event));

await engine.storage.set("settings", settings, signal);
const restored = await engine.storage.get("settings", signal);
```

The package includes no game assets, model data, or proprietary runtime. Hosts
provide authorized resources and runtimes separately. Pair it with
`@haneoka/vega-theme-haneoka` for the matching presentation.

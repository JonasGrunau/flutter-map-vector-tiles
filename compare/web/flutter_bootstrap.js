{{flutter_js}}
{{flutter_build_config}}

// The default bootstrap, plus removing the "Loading…" placeholder once the
// engine is up.
_flutter.loader.load({
  onEntrypointLoaded: async (engineInitializer) => {
    const appRunner = await engineInitializer.initializeEngine();
    document.getElementById('loading')?.remove();
    await appRunner.runApp();
  },
});

const GLOBAL_SINGLETON_RESETS_KEY = Symbol.for("openclaw.globalSingletonLifecycleResets");
function resolveGlobalSingletonResetRegistry()                                              {
  const globalStore = globalThis                                ;
  const existing = globalStore[GLOBAL_SINGLETON_RESETS_KEY];
  if (existing instanceof Map) {
    return existing                                               ;
  }
  const created = new Map                                        ();
  globalStore[GLOBAL_SINGLETON_RESETS_KEY] = created;
  return created;
}
export function resolveGlobalSingleton   (
  key        ,
  create         ,
  reset                          ,
  lifecycle                           = "close-and-restart",
)    {
  const globalStore = globalThis                                ;
  let value   ;
  if (Object.hasOwn(globalStore, key)) {
    value = globalStore[key]     ;
  } else {
    value = create();
    globalStore[key] = value;
  }
  if (reset) {
    // Rent: duplicated runtime chunks share both the slot and its lifecycle owner.
    // Keep the callback registered across restarts and reset the shared value in place.
    resolveGlobalSingletonResetRegistry().set(key, {
      lifecycle,
      reset: () => reset(value),
    });
  }
  return value;
}
export { GLOBAL_SINGLETON_RESETS_KEY, resolveGlobalSingletonResetRegistry };
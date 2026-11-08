/** Manual-control promise cache for lazy runtime resources. */
                                    
                                                                          
                         
                                                                    
                                     
                                                                
                    
  

                                 
                                                                          
                            
                                                                                         
                           
  

/** Returns the cached promise for a key, creating and storing it when absent. */
export function getOrCreatePromise      (
  cache                    ,
  key   ,
  create                  ,
  options                           = {},
)             {
  const cached = cache.get(key);
  if (cached) {
    return cached;
  }
  const created = create();
  cache.set(key, created);
  const evict = () => {
    if (cache.get(key) === created) {
      cache.delete(key);
    }
  };
  if (options.evictOnSettled === true) {
    void created.then(evict, evict);
  } else if (options.cacheRejections === false) {
    void created.catch(evict);
  }
  return created;
}

/** Options for controlling lazy promise cache behavior. */
                                 
                                                                                    
                            
  

/**
 * Creates a small promise cache that dedupes concurrent loads and can be cleared manually.
 *
 * Rejections are evicted by default so transient dynamic-import/runtime failures can recover.
 */
export function createLazyPromiseLoader   (
  load                      ,
  options                           = {},
)                       {
  let promise                        ;

  const createPromise = ()             => {
    const loaded = Promise.resolve().then(load);
    if (options.cacheRejections !== true) {
      void loaded.catch(() => {
        // Failed lazy loads are usually transient import/runtime issues; evict the exact
        // rejected promise so the next caller can retry without racing a newer load.
        if (promise === loaded) {
          promise = undefined;
        }
      });
    }
    return loaded;
  };

  return {
    load()             {
      promise ??= createPromise();
      return promise;
    },
    peek()                         {
      return promise;
    },
    clear()       {
      promise = undefined;
    },
  };
}

/** Creates a reusable function that resolves one cached promise at a time. */
export function createLazyPromise   (
  load                      ,
  options                           ,
)                   {
  const loader = createLazyPromiseLoader(load, options);
  return () => loader.load();
}

/** Convenience wrapper for dynamic-import-shaped loaders. */
export function createLazyImportLoader   (load                  )                       {
  return createLazyPromiseLoader(load);
}

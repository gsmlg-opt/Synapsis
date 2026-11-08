import { createLazyPromiseLoader } from "./lazy-promise.mjs";

export { createLazyPromise, createLazyPromiseLoader } from "./lazy-promise.mjs";

export function createLazyRuntimeSurface                   (
  importer                        ,
  select                               ,
) {
  const loader = createLazyPromiseLoader(() => importer().then(select), {
    cacheRejections: true,
  });
  return Object.assign(loader.load, { peek: loader.peek, clear: loader.clear });
}

/** Cache the raw dynamically imported runtime module behind a stable loader. */
export function createLazyRuntimeModule         (importer                        ) {
  return createLazyRuntimeSurface(importer, (module) => module);
}

/** Cache a single named runtime export without repeating a custom selector closure per caller. */
export function createLazyRuntimeNamedExport                                           (
  importer                        ,
  key      ,
)                               {
  return createLazyRuntimeSurface(importer, (module) => module[key]);
}

export function createLazyRuntimeMethod                                            (
  load                         ,
  select                                                    ,
)                                                {
  return async (...args       )                            => {
    const method = select(await load());
    return await method(...args);
  };
}

export function createLazyRuntimeMethodBinder          (load                         ) {
  return function                                   (
    select                                                    ,
  )                                                {
    return createLazyRuntimeMethod(load, select);
  };
}

export class LruCache    {
           #maxEntries        ;
           #maxBytes        ;
           #sizeOf                                    ;
           #entries = new Map           ();
  #bytes = 0;

  constructor(maxEntries        , options                                                     ) {
    this.#maxEntries =
      Number.isFinite(maxEntries) && maxEntries > 0 ? Math.max(1, Math.floor(maxEntries)) : 1;
    this.#maxBytes = options?.maxBytes ?? Number.POSITIVE_INFINITY;
    this.#sizeOf = options?.sizeOf;
  }

  get size()         {
    return this.#entries.size;
  }

  clear()       {
    this.#entries.clear();
    this.#bytes = 0;
  }

  keys()                           {
    return this.#entries.keys();
  }

  delete(cacheKey        )          {
    if (!this.#entries.has(cacheKey)) {
      return false;
    }
    // SAFETY: has() proved the key exists; undefined remains a valid cached T.
    this.#bytes -= this.#sizeOf?.(this.#entries.get(cacheKey)     ) ?? 0;
    return this.#entries.delete(cacheKey);
  }

  deleteValue(value   )       {
    for (const [key, entry] of this.#entries) {
      if (entry === value) {
        this.delete(key);
      }
    }
  }

  /** Reads without promoting a value whose revalidation is still pending. */
  peek(cacheKey        )                {
    return this.#entries.get(cacheKey);
  }

  /** Returns a cached value and refreshes its recency when present. */
  get(cacheKey        )                {
    if (!this.#entries.has(cacheKey)) {
      return undefined;
    }
    // SAFETY: has() proved the key exists; undefined remains a valid cached T.
    const cached = this.#entries.get(cacheKey)     ;
    this.#entries.delete(cacheKey);
    this.#entries.set(cacheKey, cached);
    return cached;
  }

  /** Stores a value as the newest entry and evicts oldest entries past capacity. */
  set(cacheKey        , value   )       {
    this.delete(cacheKey);
    this.#entries.set(cacheKey, value);
    this.#bytes += this.#sizeOf?.(value) ?? 0;
    for (const key of this.#entries.keys()) {
      if (this.#entries.size <= this.#maxEntries && this.#bytes <= this.#maxBytes) {
        break;
      }
      this.delete(key);
    }
  }
}
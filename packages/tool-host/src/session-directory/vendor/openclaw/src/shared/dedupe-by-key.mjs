export function indexFirstByKey   (
  items              ,
  keyOf                     ,
)                 {
  const deduped = new Map           ();
  for (const item of items) {
    const key = keyOf(item);
    if (!deduped.has(key)) {
      deduped.set(key, item);
    }
  }
  return deduped;
}
export function dedupeByKey   (items              , keyOf                     )      {
  return [...indexFirstByKey(items, keyOf).values()];
}
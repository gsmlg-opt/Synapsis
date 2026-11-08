export function groupPluginRecords      (
  records             ,
  keyOf                  ,
)              {
  const groups = new Map        ();
  for (const record of records) {
    const key = keyOf(record);
    const group = groups.get(key);
    if (group) {
      group.push(record);
    } else {
      groups.set(key, [record]);
    }
  }
  return groups;
}
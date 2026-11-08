export function hasUnresolvedImageCode(
  text        ,
  start        ,
  end        ,
  regions                                                           ,
  regionStart        ,
)          {
  let regionIndex = regionStart;
  const brackets                                           = [];
  for (let cursor = start; cursor < end; cursor += 1) {
    const region = regions[regionIndex];
    if (region?.start === cursor) {
      if (!region.block) {
        for (const bracket of brackets) {
          bracket.code ||= bracket.image;
        }
      }
      cursor = region.end - 1;
      regionIndex += 1;
    } else if (text[cursor] === "\\") {
      cursor += 1;
    } else if (text[cursor] === "!" && text[cursor + 1] === "[") {
      brackets.push({ image: true, code: false });
      cursor += 1;
    } else if (text[cursor] === "[") {
      brackets.push({ image: false, code: false });
    } else if (text[cursor] === "]" && brackets.pop()?.code) {
      return true;
    }
  }
  return false;
}

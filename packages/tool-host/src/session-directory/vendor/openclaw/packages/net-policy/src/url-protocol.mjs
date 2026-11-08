const HTTP_URL_PREFIX_RE = /^https?:\/\//i;

function parseUrl(value              )             {
  return value instanceof URL ? value : URL.parse(value);
}

export function hasHttpUrlPrefix(value        )          {
  return HTTP_URL_PREFIX_RE.test(value);
}

export function isHttpUrl(value              )          {
  const url = parseUrl(value);
  return url?.protocol === "http:" || url?.protocol === "https:";
}

export function isHttpsUrl(value              )          {
  return parseUrl(value)?.protocol === "https:";
}

export function isWebSocketUrl(value              )          {
  const url = parseUrl(value);
  return url?.protocol === "ws:" || url?.protocol === "wss:";
}

export function isWssUrl(value              )          {
  return parseUrl(value)?.protocol === "wss:";
}

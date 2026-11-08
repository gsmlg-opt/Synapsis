/*
 * Adapted from @clawdbot/lobster 2026.9.16:
 * dist/src/commands/stdlib/template.js
 *   SHA256 27ea3ef6d273a003d089b7c38ced0bd89233ee9615149e48ee732d0615b1d5ac
 * dist/src/core/filters.js
 *   SHA256 d7d2fa2481fd302ba699394bc7e8db0dd86f9844a8b399e2aa4d4cd0aedb0c14
 * dist/src/core/value_path.js
 *   SHA256 e07cfee4e8fb4953ffbf02b8b51b5bbb4f01a6950515b2a1f9d31b0eb922171f
 *
 * The original pure algorithms are combined here; command construction, file IO,
 * metadata and unused exports are omitted. The result remains a JS string so
 * every UTF-16 code unit survives, including lone surrogates.
 *
 * MIT License
 *
 * Copyright (c) 2026 Vignesh
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */

const FILTERS = new Map();
FILTERS.set('upper', (v) => String(v ?? '').toUpperCase());
FILTERS.set('lower', (v) => String(v ?? '').toLowerCase());
FILTERS.set('trim', (v) => String(v ?? '').trim());
FILTERS.set('truncate', (v, n) => {
  const s = String(v ?? '');
  const parsed = parseInt(n ?? '', 10);
  const len = Number.isNaN(parsed) ? 80 : parsed;
  return s.length > len ? `${s.slice(0, len)}...` : s;
});
FILTERS.set('replace', (v, from, to) => String(v ?? '').replaceAll(from ?? '', to ?? ''));
FILTERS.set('split', (v, sep) => String(v ?? '').split(sep ?? ','));
FILTERS.set('first', (v) => (Array.isArray(v) ? v[0] : v));
FILTERS.set('last', (v) => (Array.isArray(v) ? v[v.length - 1] : v));
FILTERS.set('length', (v) => {
  if (Array.isArray(v)) return v.length;
  if (typeof v === 'string') return v.length;
  return 0;
});
FILTERS.set('join', (v, sep) => (Array.isArray(v) ? v.join(sep ?? ', ') : String(v ?? '')));
FILTERS.set('json', (v) => JSON.stringify(v, null, 2));
FILTERS.set('string', (v) => String(v ?? ''));
FILTERS.set('default', (v, def) => (v == null || v === '' ? def : v));
FILTERS.set('round', (v, n) => {
  const num = Number(v);
  const dec = parseInt(n ?? '', 10) || 0;
  return Number.isNaN(num) ? v : Number(num.toFixed(dec));
});
FILTERS.set('date', (v, fmt) => {
  const d = typeof v === 'number' || (typeof v === 'string' && /^\d+$/.test(v.trim()))
    ? new Date(Number(v))
    : new Date(String(v));
  if (Number.isNaN(d.getTime())) return String(v);
  if (!fmt) return d.toISOString();
  return fmt
    .replace('YYYY', String(d.getUTCFullYear()))
    .replace('MM', String(d.getUTCMonth() + 1).padStart(2, '0'))
    .replace('DD', String(d.getUTCDate()).padStart(2, '0'))
    .replace('HH', String(d.getUTCHours()).padStart(2, '0'))
    .replace('mm', String(d.getUTCMinutes()).padStart(2, '0'))
    .replace('ss', String(d.getUTCSeconds()).padStart(2, '0'));
});

function parseFilterExpression(expr) {
  const trimmed = expr.trim();
  const parts = [];
  let i = 0;
  while (i < trimmed.length) {
    while (i < trimmed.length && trimmed[i] === ' ') i += 1;
    if (i >= trimmed.length) break;
    if (trimmed[i] === '"' || trimmed[i] === "'") {
      const quote = trimmed[i];
      i += 1;
      let arg = '';
      while (i < trimmed.length && trimmed[i] !== quote) {
        if (trimmed[i] === '\\' && i + 1 < trimmed.length) {
          arg += trimmed[i + 1];
          i += 2;
        } else {
          arg += trimmed[i];
          i += 1;
        }
      }
      if (i < trimmed.length) i += 1;
      parts.push(arg);
    } else {
      let arg = '';
      while (i < trimmed.length && trimmed[i] !== ' ') {
        arg += trimmed[i];
        i += 1;
      }
      parts.push(arg);
    }
  }
  if (parts.length === 0) return [trimmed];
  return parts;
}

function applyFilters(value, filterChain) {
  let result = value;
  for (const filterExpr of filterChain) {
    const [name, ...args] = parseFilterExpression(filterExpr);
    const fn = FILTERS.get(name);
    if (!fn) throw new Error(`Unknown template filter: ${name}`);
    result = fn(result, ...args);
  }
  return result;
}

function getByPath(value, path) {
  let current = value;
  for (const field of path.split('.').filter(Boolean)) {
    if (current == null) return undefined;
    current = current[field];
  }
  return current;
}

function splitFilterChain(expr) {
  const parts = [];
  let current = '';
  let i = 0;
  while (i < expr.length) {
    const ch = expr[i];
    if (ch === '"' || ch === "'") {
      const quote = ch;
      current += ch;
      i += 1;
      while (i < expr.length && expr[i] !== quote) {
        if (expr[i] === '\\' && i + 1 < expr.length) {
          current += expr[i] + expr[i + 1];
          i += 2;
        } else {
          current += expr[i];
          i += 1;
        }
      }
      if (i < expr.length) {
        current += expr[i];
        i += 1;
      }
    } else if (ch === '|') {
      parts.push(current.trim());
      current = '';
      i += 1;
    } else {
      current += ch;
      i += 1;
    }
  }
  parts.push(current.trim());
  return parts;
}

/** Render already-resolved template text against one real JS item. */
export function renderTemplate(tpl, ctx) {
  return tpl.replace(/\{\{\s*([^}]+?)\s*\}\}/g, (_m, expr) => {
    const rawExpr = String(expr ?? '').trim();
    const parts = splitFilterChain(rawExpr);
    const key = parts[0];
    let val = key === '.' || key === 'this' ? ctx : getByPath(ctx, key);
    if (parts.length > 1) val = applyFilters(val, parts.slice(1));
    if (val === undefined || val === null) return '';
    if (typeof val === 'string') return val;
    if (typeof val === 'number' || typeof val === 'boolean') return String(val);
    return JSON.stringify(val);
  });
}

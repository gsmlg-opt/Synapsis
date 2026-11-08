import Ajv from 'ajv';
import uriResolver from 'fast-uri';

// These are host resource limits, not a substitute schema dialect. Exceeding
// the retained-cache budget makes the session unavailable; nothing is evicted.
const MAX_CACHE_ENTRIES = 256;
const own = (object, key) => Object.prototype.hasOwnProperty.call(object, key);

/** Reconstruct the two roots together so aliases, own undefined and bits survive. */
export function decodeRoots(request, heap) {
  if (!request || !heap || heap.version !== 1 || !heap.nodes ||
      typeof heap.nodes !== 'object' || Array.isArray(heap.nodes)) {
    throw new TypeError('invalid_tagged_heap');
  }
  const shells = new Map();
  const pending = [];
  function decode(value) {
    if (!value || typeof value !== 'object') throw new TypeError('invalid_tagged_value');
    switch (value.type) {
      case 'undefined': return undefined;
      case 'null': return null;
      case 'boolean':
        if (typeof value.value !== 'boolean') throw new TypeError('invalid_boolean');
        return value.value;
      case 'string': {
        if (Object.keys(value).length !== 2) throw new TypeError('invalid_string');
        if (own(value, 'value')) {
          if (typeof value.value !== 'string' || !value.value.isWellFormed()) {
            throw new TypeError('invalid_string');
          }
          return value.value;
        }
        if (!own(value, 'utf16le') || typeof value.utf16le !== 'string') {
          throw new TypeError('invalid_string');
        }
        const bytes = Buffer.from(value.utf16le, 'base64');
        if (bytes.length % 2 !== 0 || bytes.toString('base64') !== value.utf16le) {
          throw new TypeError('invalid_string');
        }
        const string = bytes.toString('utf16le');
        if (string.isWellFormed()) throw new TypeError('invalid_string');
        return string;
      }
      case 'number':
        if (typeof value.bits !== 'string' || !/^[0-9a-f]{16}$/.test(value.bits)) {
          throw new TypeError('invalid_binary64');
        }
        return Buffer.from(value.bits, 'hex').readDoubleBE(0);
      case 'reference': {
        if (typeof value.id !== 'string' || !own(heap.nodes, value.id)) {
          throw new TypeError('invalid_reference');
        }
        if (!shells.has(value.id)) {
          const node = heap.nodes[value.id];
          if (!node || (node.type !== 'object' && node.type !== 'array')) {
            throw new TypeError('invalid_heap_node');
          }
          shells.set(value.id, node.type === 'array' ? [] : {});
          pending.push(value.id);
        }
        return shells.get(value.id);
      }
      default: throw new TypeError('unknown_tagged_value');
    }
  }

  const schema = decode(request.schema);
  const response = own(request, 'response') ? decode(request.response) : undefined;
  // Each referenced node receives a shell before its fields are visited. This
  // iterative worklist preserves sharing and cycles without recursive copying.
  for (let index = 0; index < pending.length; index++) {
    const id = pending[index];
    const node = heap.nodes[id];
    const shell = shells.get(id);
    if (node.type === 'array') {
      if (!Array.isArray(node.items)) throw new TypeError('invalid_array_node');
      for (const item of node.items) shell.push(decode(item));
    } else {
      if (!Array.isArray(node.keys) || !node.fields || typeof node.fields !== 'object' ||
          Array.isArray(node.fields) ||
          (own(node, 'fields_utf16le') && (!node.fields_utf16le ||
            typeof node.fields_utf16le !== 'object' || Array.isArray(node.fields_utf16le) ||
            Object.keys(node.fields_utf16le).length === 0))) {
        throw new TypeError('invalid_object_node');
      }
      const keys = new Set();
      for (const selector of node.keys) {
        let key, fields, name;
        if (typeof selector === 'string' && selector.isWellFormed()) {
          key = name = selector;
          fields = node.fields;
        } else if (selector?.type === 'string' && own(selector, 'utf16le')) {
          key = decode(selector);
          name = selector.utf16le;
          fields = node.fields_utf16le;
        } else {
          throw new TypeError('invalid_object_key');
        }
        if (keys.has(key) || !fields || !own(fields, name)) {
          throw new TypeError('invalid_object_key');
        }
        keys.add(key);
        Object.defineProperty(shell, key, {
          value: decode(fields[name]), enumerable: true, configurable: true, writable: true
        });
      }
    }
  }
  return { schema, response };
}

// Exact source algorithm from Lobster state/store.js. Sort a copy only for the
// key; compile the first original ordered schema and retain that validator.
function stableStringify(value) {
  return JSON.stringify(value, (_key, item) => {
    if (item && typeof item === 'object' && !Array.isArray(item)) {
      return Object.fromEntries(Object.keys(item).sort().map(key => [key, item[key]]));
    }
    return item;
  });
}

/** One actual Draft-07 Ajv instance/cache, explicitly owned by its caller. */
export function createValidator() {
  const ajv = new Ajv({
    allErrors: false, strict: false, addUsedSchema: false, uriResolver,
    // Ajv's unknown-format warnings may include schema input. Keep them off
    // process stderr; logger selection does not change assertion semantics.
    logger: false
  });
  const cache = new Map();
  const failure = (id, outcome, diagnostic) => ({
    id, result: 'error', outcome, ...(diagnostic ? { diagnostic } : {})
  });

  return {
    cacheSize: () => cache.size,
    fulfill(request, heap) {
      const id = request?.id;
      if (typeof id !== 'string' ||
          !['compile_schema', 'validate_response'].includes(request?.kind) ||
          !own(request, 'schema') ||
          (request.kind === 'validate_response' && !own(request, 'response'))) {
        return failure(id, 'invalid_request');
      }
      let schema, response;
      try {
        ({ schema, response } = decodeRoots(request, heap));
      } catch {
        return failure(id, 'invalid_request');
      }

      let validator;
      try {
        const key = stableStringify(schema);
        validator = cache.get(key);
        if (!validator) {
          if (cache.size >= MAX_CACHE_ENTRIES) return failure(id, 'resource_limit');
          validator = ajv.compile(schema);
          cache.set(key, validator);
        }
      } catch {
        return failure(id, 'invalid_schema');
      }
      if (request.kind === 'compile_schema') return { id, result: 'ok', outcome: 'compiled' };

      try {
        const valid = validator(response);
        if (valid && typeof valid.then === 'function') {
          // The source wrapper's truthy-Promise policy has not been selected.
          // Observe rejection, but never turn asynchronous settlement into an
          // operation acknowledgement or claim that it was awaited here.
          Promise.resolve(valid).catch(() => {});
          return { id, result: 'unevaluated', outcome: 'async_unevaluated' };
        }
        if (valid === true) return { id, result: 'ok', outcome: 'valid' };
        if (valid === false) {
          const first = validator.errors?.[0];
          return failure(id, 'invalid_response', {
            instancePath: first?.instancePath || '/', message: first?.message || ''
          });
        }
        return failure(id, 'validation_failed');
      } catch {
        return failure(id, 'validation_failed');
      }
    }
  };
}

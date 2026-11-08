// Adapted from OpenClaw 488631c18fae7cc541ba8fc8beff6cbb0438787b:
// extensions/browser/src/browser/{evaluate-source,pw-tools-core.interactions.content}.ts
// MIT License
// Copyright (c) 2026 OpenClaw Foundation
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

import { Script } from 'node:vm';

const FUNCTION_SOURCE_PATTERN = /^(?:async\s+)?(?:function\b|\([^)]*\)\s*=>|[A-Za-z_$][\w$]*\s*=>)/;

function normalizePredicateSource(source) {
  const trimmed = source.trim();
  let expression = true;
  // Parse only in Node; execute caller JavaScript exclusively in the page.
  try { new Script(`"use strict";\n(${trimmed});`); } catch { expression = false; }
  if (expression && FUNCTION_SOURCE_PATTERN.test(trimmed)) return trimmed;
  if (expression) return `() => {
    const __openclawEvaluateExpressionResult = (${trimmed});
    return typeof __openclawEvaluateExpressionResult === 'function' ? __openclawEvaluateExpressionResult() : __openclawEvaluateExpressionResult;
  }`;
  return `async () => {\n${trimmed}\n}`;
}

export function createBrowserWaitPredicate(source) {
  const normalized = normalizePredicateSource(source);
  // Playwright polls this synchronous wrapper. A pending promise is never a
  // successful truthy result, and each predicate invocation settles before reuse.
  return new Function('state', `
    if (state.document !== this.document) throw new Error('Wait predicate document changed');
    state.predicate ??= (${normalized});
    const settled = state.settled;
    if (settled) {
      delete state.settled;
      if (settled.kind === 'error') throw settled.error;
      if (settled.value) return true;
    }
    if (state.pending) return false;
    const predicate = state.predicate;
    const value = predicate();
    if (!value || typeof value.then !== 'function') return !!value;
    state.pending = true;
    value.then(
      resolved => { state.settled = { kind: 'value', value: resolved }; delete state.pending; },
      error => { state.settled = { kind: 'error', error }; delete state.pending; }
    );
    return false;
  `);
}

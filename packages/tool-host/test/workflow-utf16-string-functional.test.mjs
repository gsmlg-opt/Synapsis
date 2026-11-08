import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { renderTemplate } from '../src/workflow/template.mjs';

// Literal code units, base64 and JSON outputs frozen before the Elixir codec.
// Native JS is an independent string/JSON oracle, not the production decoder.
const { cases } = JSON.parse(readFileSync(new URL('./fixtures/workflow-utf16-string-cases.json', import.meta.url)));
const units = text => Array.from({ length: text.length }, (_, i) => text.charCodeAt(i));

for (const item of cases) {
  test(`native JS preserves the literal UTF16 string and JSON output: ${item.name}`, () => {
    const text = Buffer.from(item.base64, 'base64').toString('utf16le');
    assert.deepEqual(units(text), item.units);
    assert.equal(Buffer.from(text, 'utf16le').toString('base64'), item.base64);
    assert.equal(JSON.stringify(text), item.json);
    assert.deepEqual(units(JSON.parse(item.json)), item.units);
    assert.equal(text.isWellFormed(), item.utf8 !== null);
    if (item.utf8 !== null) assert.equal(text, item.utf8);
  });
}

test('the existing full formatter generates the four literal surrogate-bearing outputs', () => {
  const item = { text: '😀x', emoji: '😀' };
  for (const [name, template] of [
    ['truncate_emoji', '{{text|truncate 1}}'],
    ['split_first', '{{emoji|split ""|first}}'],
    ['split_last', '{{emoji|split ""|last}}'],
    ['replace_empty', '{{emoji|replace "" "-"}}']
  ]) {
    const expected = cases.find(entry => entry.name === name);
    const output = renderTemplate(template, item);
    assert.deepEqual(units(output), expected.units);
    assert.equal(JSON.stringify(output), expected.json);
  }
});

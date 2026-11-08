// Independent literal expectations authored before capture implementation/production.
// Whole templateCommand source executes directly, not the workflow runtime.
import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { captureLobsterTemplate } from './capture-lobster-template.mjs';

const CASES = [
  { id: "literal-unicode-and-braces", template: "\u96ea\ud83d\ude00 <b>plain</b>", item: {}, expected: "\u96ea\ud83d\ude00 <b>plain</b>" },
  { id: "fields-and-nested", template: "{{title}} / {{nested.name}}", item: {title:"one",nested:{name:"雪"}}, expected: "one / \u96ea" },
  { id: "path-empty-segments", template: "{{.nested..name.}}", item: {nested:{name:"yes"}}, expected: "yes" },
  { id: "array-index-and-length", template: "{{v.1.name}}/{{v.length}}", item: {v:[{name:"a"},{name:"b"}]}, expected: "b/2" },
  { id: "string-index-and-length", template: "{{v.1}}/{{v.length}}", item: {v:"cat"}, expected: "a/3" },
  { id: "whole-dot", template: "{{.}}", item: {z:1,a:2}, expected: "{\"z\":1,\"a\":2}" },
  { id: "whole-this", template: "{{this}}", item: [1,"雪",null], expected: "[1,\"\u96ea\",null]" },
  { id: "all-dots-whole", template: "{{...}}", item: {a:1}, expected: "{\"a\":1}" },
  { id: "this-property-is-literal", template: "{{this.name}}", item: {this:{name:"actual"},name:"root"}, expected: "actual" },
  { id: "missing-null-undefined", template: "a{{missing}}b{{nil}}c{{own}}d", item: {nil:null,own:undefined}, expected: "abcd" },
  { id: "nullish-intermediate", template: "{{nil.child}}/{{missing.child}}", item: {nil:null}, expected: "/" },
  { id: "whole-null", template: "[{{.}}]", item: null, expected: "[]" },
  { id: "whole-undefined", template: "[{{this}}]", item: undefined, expected: "[]" },
  { id: "whole-boolean", template: "{{.}}", item: false, expected: "false" },
  { id: "whole-number", template: "{{this}}", item: -12.5, expected: "-12.5" },
  { id: "whole-signed-zero", template: "{{.}}", item: -0, expected: "0" },
  { id: "compact-object-key-order", template: "{{v}}", item: {v:{z:1,"10":"ten","2":"two",a:2}}, expected: "{\"2\":\"two\",\"10\":\"ten\",\"z\":1,\"a\":2}" },
  { id: "compact-array-undefined", template: "{{v}}", item: {v:[1,undefined,null,"雪"]}, expected: "[1,null,null,\"\u96ea\"]" },
  { id: "replacement-is-not-recursive", template: "{{v}}", item: {v:"{{name}}",name:"later"}, expected: "{{name}}" },
  { id: "expression-ecmascript-whitespace", template: "{{\u00a0 v \ufeff}}", item: {v:"yes"}, expected: "yes" },
  { id: "upper-ascii", template: "{{v | upper}}", item: {v:"Ab c"}, expected: "AB C" },
  { id: "upper-unicode-expansion", template: "{{v | upper}}", item: {v:"Straße 雪😀"}, expected: "STRASSE \u96ea\ud83d\ude00" },
  { id: "upper-nullish", template: "{{v | upper}}", item: {v:null}, expected: "" },
  { id: "upper-array-coercion", template: "{{v | upper}}", item: {v:["a",null,"b"]}, expected: "A,,B" },
  { id: "upper-object-coercion", template: "{{v | upper}}", item: {v:{a:1}}, expected: "[OBJECT OBJECT]" },
  { id: "lower-ascii", template: "{{v | lower}}", item: {v:"Ab C"}, expected: "ab c" },
  { id: "lower-unicode-expansion", template: "{{v | lower}}", item: {v:"İ ΣΟΣ"}, expected: "i\u0307 \u03c3\u03bf\u03c2" },
  { id: "trim-ecmascript-whitespace", template: "{{v | trim}}", item: {v:"\t\n\r \u00a0\ufeffx\u3000\u2029"}, expected: "x" },
  { id: "trim-retains-next-line", template: "{{v | trim}}", item: {v:"\u0085x\u0085"}, expected: "\u0085x\u0085" },
  { id: "trim-upper-chain", template: "{{v | trim | upper}}", item: {v:"  hello  "}, expected: "HELLO" },
  { id: "truncate-short", template: "{{v | truncate 3}}", item: {v:"abcdef"}, expected: "abc..." },
  { id: "truncate-no-op", template: "{{v | truncate 6}}", item: {v:"abcdef"}, expected: "abcdef" },
  { id: "truncate-default", template: "{{v | truncate}}", item: {v:"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"}, expected: "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx..." },
  { id: "truncate-zero", template: "{{v | truncate 0}}", item: {v:"abc"}, expected: "..." },
  { id: "truncate-signed-length", template: "{{v | truncate -1}}", item: {v:"abcd"}, expected: "abc..." },
  { id: "truncate-decimal-prefix", template: "{{v | truncate 2tail}}", item: {v:"abcd"}, expected: "ab..." },
  { id: "truncate-whole-astral", template: "{{v | truncate 2}}", item: {v:"😀x"}, expected: "\ud83d\ude00..." },
  { id: "truncate-surrogate-half", template: "{{v | truncate 1}}", item: {v:"😀x"}, expected: "\ud83d..." },
  { id: "replace-all", template: "{{v | replace \"a\" \"x\"}}", item: {v:"banana"}, expected: "bxnxnx" },
  { id: "replace-pipe-in-quoted-arg", template: "{{v | replace \"|\" \":\" | upper}}", item: {v:"a|b"}, expected: "A:B" },
  { id: "replace-space-in-quoted-arg", template: "{{v | replace 'a b' 'c d'}}", item: {v:"a b a b"}, expected: "c d c d" },
  { id: "replace-escaped-quote", template: "{{v | replace \"\\\"\" \"'\"}}", item: {v:'a"b"'}, expected: "a'b'" },
  { id: "replace-escaped-backslash", template: "{{v | replace \"\\\\\" \"/\"}}", item: {v:'a\\b\\c'}, expected: "a/b/c" },
  { id: "quoted-backslash-is-not-json-escape", template: "{{v | replace \"\\n\" \"N\"}}", item: {v:"banana"}, expected: "baNaNa" },
  { id: "replace-dollar-match", template: "{{v | replace \"a\" \"[$&]\"}}", item: {v:"aba"}, expected: "[a]b[a]" },
  { id: "replace-dollar-dollar", template: "{{v | replace \"a\" \"$$\"}}", item: {v:"aba"}, expected: "$b$" },
  { id: "replace-empty-search", template: "{{v | replace \"\" \"-\"}}", item: {v:"ab"}, expected: "-a-b-" },
  { id: "replace-empty-search-surrogates", template: "{{v | replace \"\" \"-\"}}", item: {v:"😀"}, expected: "-\ud83d-\ude00-" },
  { id: "replace-omitted-arguments", template: "{{v | replace}}", item: {v:"abc"}, expected: "abc" },
  { id: "split-default", template: "{{v | split}}", item: {v:"a,b,,c"}, expected: "[\"a\",\"b\",\"\",\"c\"]" },
  { id: "split-custom", template: "{{v | split \"::\"}}", item: {v:"a::b"}, expected: "[\"a\",\"b\"]" },
  { id: "split-empty-ascii", template: "{{v | split \"\"}}", item: {v:"ab"}, expected: "[\"a\",\"b\"]" },
  { id: "split-empty-astral-json", template: "{{v | split \"\"}}", item: {v:"😀"}, expected: "[\"\\ud83d\",\"\\ude00\"]" },
  { id: "split-first", template: "{{v | split \",\" | first}}", item: {v:"one,two"}, expected: "one" },
  { id: "split-last", template: "{{v | split \",\" | last}}", item: {v:"one,two"}, expected: "two" },
  { id: "split-empty-first-surrogate", template: "{{v | split \"\" | first}}", item: {v:"😀"}, expected: "\ud83d" },
  { id: "split-empty-last-surrogate", template: "{{v | split \"\" | last}}", item: {v:"😀"}, expected: "\ude00" },
  { id: "split-empty-join-reconstructs", template: "{{v | split \"\" | join \"\"}}", item: {v:"😀"}, expected: "\ud83d\ude00" },
  { id: "first-array", template: "{{v | first}}", item: {v:["a","b"]}, expected: "a" },
  { id: "last-array", template: "{{v | last}}", item: {v:["a","b"]}, expected: "b" },
  { id: "first-string-pass-through", template: "{{v | first}}", item: {v:"abc"}, expected: "abc" },
  { id: "last-object-pass-through", template: "{{v | last}}", item: {v:{a:1}}, expected: "{\"a\":1}" },
  { id: "first-empty-array", template: "[{{v | first}}]", item: {v:[]}, expected: "[]" },
  { id: "last-empty-array", template: "[{{v | last}}]", item: {v:[]}, expected: "[]" },
  { id: "length-array", template: "{{v | length}}", item: {v:[1,null,undefined]}, expected: "3" },
  { id: "length-astral", template: "{{v | length}}", item: {v:"😀x"}, expected: "3" },
  { id: "length-object", template: "{{v | length}}", item: {v:{length:99}}, expected: "0" },
  { id: "length-null", template: "{{v | length}}", item: {v:null}, expected: "0" },
  { id: "join-default", template: "{{v | join}}", item: {v:["a","b","c"]}, expected: "a, b, c" },
  { id: "join-custom", template: "{{v | join \"|\"}}", item: {v:["a","b"]}, expected: "a|b" },
  { id: "join-nullish-nested", template: "{{v | join \":\"}}", item: {v:[null,undefined,[1,2],{x:1}]}, expected: "::1,2:[object Object]" },
  { id: "join-scalar", template: "{{v | join \":\"}}", item: {v:42}, expected: "42" },
  { id: "json-pretty-order-and-own-undefined", template: "{{v | json}}", item: {v:{z:1,"10":"ten","2":"two",own:undefined,a:[true,null]}}, expected: "{\n  \"2\": \"two\",\n  \"10\": \"ten\",\n  \"z\": 1,\n  \"a\": [\n    true,\n    null\n  ]\n}" },
  { id: "json-undefined-root", template: "[{{v | json}}]", item: {v:undefined}, expected: "[]" },
  { id: "json-array-undefined", template: "{{v | json}}", item: {v:[undefined,null]}, expected: "[\n  null,\n  null\n]" },
  { id: "json-string-quotes", template: "{{v | json}}", item: {v:"雪"}, expected: "\"\u96ea\"" },
  { id: "surrogate-json-filter-escape", template: "{{v | truncate 1 | json}}", item: {v:"😀x"}, expected: "\"\\ud83d...\"" },
  { id: "string-object", template: "{{v | string}}", item: {v:{a:1}}, expected: "[object Object]" },
  { id: "string-array", template: "{{v | string}}", item: {v:["a",null,[1,2]]}, expected: "a,,1,2" },
  { id: "string-null", template: "[{{v | string}}]", item: {v:null}, expected: "[]" },
  { id: "default-missing", template: "{{v | default \"fallback\"}}", item: {}, expected: "fallback" },
  { id: "default-null", template: "{{v | default \"fallback\"}}", item: {v:null}, expected: "fallback" },
  { id: "default-empty", template: "{{v | default \"fallback\"}}", item: {v:""}, expected: "fallback" },
  { id: "default-retains-false", template: "{{v | default \"fallback\"}}", item: {v:false}, expected: "false" },
  { id: "default-retains-zero", template: "{{v | default \"fallback\"}}", item: {v:0}, expected: "0" },
  { id: "default-retains-empty-array", template: "{{v | default \"fallback\"}}", item: {v:[]}, expected: "[]" },
  { id: "default-retains-empty-object", template: "{{v | default \"fallback\"}}", item: {v:{}}, expected: "{}" },
  { id: "default-pipe-quoted-chain", template: "{{v | default 'a|b' | upper}}", item: {}, expected: "A|B" },
  { id: "default-internal-tab-literal", template: "{{v | default a\tb}}", item: {}, expected: "a\tb" },
  { id: "extra-filter-arguments-ignored", template: "{{v | upper \"ignored\" \"also\"}}", item: {v:"abc"}, expected: "ABC" },
  { id: "round-two-decimals", template: "{{v | round 2}}", item: {v:12.345}, expected: "12.35" },
  { id: "round-binary64-low-tie", template: "{{v | round 2}}", item: {v:1.005}, expected: "1" },
  { id: "round-exact-tie", template: "{{v | round 1}}", item: {v:1.25}, expected: "1.3" },
  { id: "round-binary64-down", template: "{{v | round 1}}", item: {v:2.55}, expected: "2.5" },
  { id: "round-default-zero-digits", template: "{{v | round}}", item: {v:12.6}, expected: "13" },
  { id: "round-decimal-prefix", template: "{{v | round 2tail}}", item: {v:12.345}, expected: "12.35" },
  { id: "round-null-number-conversion", template: "{{v | round 2}}", item: {v:null}, expected: "0" },
  { id: "round-false-number-conversion", template: "{{v | round 2}}", item: {v:false}, expected: "0" },
  { id: "round-empty-string-number-conversion", template: "{{v | round 2}}", item: {v:""}, expected: "0" },
  { id: "round-hex-string-number-conversion", template: "{{v | round}}", item: {v:"0x10"}, expected: "16" },
  { id: "round-array-number-conversion", template: "{{v | round 1}}", item: {v:[1.25]}, expected: "1.3" },
  { id: "round-exponent-format", template: "{{v | round 2}}", item: {v:1e21}, expected: "1e+21" },
  { id: "round-signed-zero-string", template: "{{v | round 1}}", item: {v:-0.01}, expected: "0" },
  { id: "date-numeric-epoch", template: "{{v | date}}", item: {v:0}, expected: "1970-01-01T00:00:00.000Z" },
  { id: "date-digit-string-epoch", template: "{{v | date}}", item: {v:" 0 "}, expected: "1970-01-01T00:00:00.000Z" },
  { id: "date-milliseconds", template: "{{v | date}}", item: {v:1234}, expected: "1970-01-01T00:00:01.234Z" },
  { id: "date-offset-to-utc", template: "{{v | date}}", item: {v:"2024-02-29T12:34:56+02:00"}, expected: "2024-02-29T10:34:56.000Z" },
  { id: "date-format-all-utc-tokens", template: "{{v | date \"YYYY/MM/DD HH:mm:ss\"}}", item: {v:"2024-02-29T12:34:56.789Z"}, expected: "2024/02/29 12:34:56" },
  { id: "date-format-first-only", template: "{{v | date \"YYYY YYYY MM MM DD DD HH HH mm mm ss ss\"}}", item: {v:"2024-02-29T12:34:56Z"}, expected: "2024 YYYY 02 MM 29 DD 12 HH 34 mm 56 ss" },
  { id: "date-empty-format-iso", template: "{{v | date ''}}", item: {v:"2024-02-29T00:00:00Z"}, expected: "2024-02-29T00:00:00.000Z" },
  { id: "date-low-year-unpadded-format", template: "{{v | date \"YYYY-MM-DD\"}}", item: {v:"0001-01-02T00:00:00Z"}, expected: "1-01-02" },
  { id: "date-then-lower-chain", template: "{{v | date | lower}}", item: {v:0}, expected: "1970-01-01t00:00:00.000z" },
  { id: "string-index-surrogate", template: "{{v.0}}", item: {v:"😀"}, expected: "\ud83d" },
  { id: "full-astral-literal-and-field", template: "\ud800\udc00{{v}}\ud83d\ude00", item: {v:"雪🚀"}, expected: "\ud800\udc00\u96ea\ud83d\ude80\ud83d\ude00" }
];
const EXPECTED_SELECTION = [
  { id: 'text-wins-file-and-positional', output: ['TEXT Ada'] },
  { id: 'whitespace-text-wins', output: ['  '] },
  { id: 'file-wins-positional', output: ['FILE Ada'] },
  { id: 'empty-text-uses-file', output: ['FILE Ada'] },
  { id: 'empty-file-falls-back-positional', output: ['POSITIONAL Ada'] },
  { id: 'empty-text-and-file-name-use-positional', output: ['POSITIONAL Ada'] },
  { id: 'positional-joins-with-space', output: ['Hello Ada !'] },
  { id: 'file-content-retained-before-pull', output: ['BEFORE Ada', 'BEFORE Bob'] },
  { id: 'file-constructor-empty-input', output: [] },
];
const EXPECTED_LAZY = [
  { id: 'constructor-does-not-pull', before: { opens: 0, yields: 0, finishes: 0 },
    after: { opens: 1, yields: 1, finishes: 1 }, output: ['A'] },
  { id: 'empty-input', before: { opens: 0, yields: 0, finishes: 0 },
    after: { opens: 1, yields: 0, finishes: 1 }, output: [] },
  { id: 'latest-item-mutation-on-demand', before: { opens: 0, yields: 0, finishes: 0 },
    after: { opens: 1, yields: 2, finishes: 1 }, output: ['one', 'two'] },
];
const captured = await captureLobsterTemplate({
  referenceRoot: process.env.OPENCLAW_REFERENCE_ROOT ?? '/tmp/openclaw-488631c',
  archive: process.env.LOBSTER_ARCHIVE ?? '/tmp/synapsis-workflow183-70ivyzc0/lobster-2026.9.16.tgz',
});
const digest = bytes => createHash('sha256').update(bytes).digest('hex');

test('whole unchanged source matches every independent formatter literal including UTF16', () => {
  assert.equal(CASES.length, 114);
  assert.deepEqual(captured.renderCases, CASES.map(({ id, template, expected }) => ({ id, template, output: expected })));
});
test('actual benign source file reads preserve full text/file/positional precedence', () => {
  assert.deepEqual(captured.selectionCases, EXPECTED_SELECTION);
  assert.equal(captured.fileObservationScope, 'source-command-only');
});
test('source command remains lazy and observes item values at demand', () => {
  assert.deepEqual(captured.lazyCases, EXPECTED_LAZY);
});
test('archive lock integrity, full modules, license and harness provenance are exact', () => {
  assert.equal(captured.referencePin, '488631c18fae7cc541ba8fc8beff6cbb0438787b');
  assert.deepEqual(captured.sourcePackage, {
    name: '@clawdbot/lobster', version: '2026.9.16',
    integrity: 'sha512-F7Izhqs6tdaSOp5l2vocqa+HXvqiPw3ny8o81kIguqUPL/jJ+72tpib2A5twxTPM2ruK23cdG1B8kO6joHUlVw==',
    installed: false,
  });
  assert.deepEqual(Object.fromEntries(captured.sourceRecords.map(record => [record.path, record.sha256])), {
    'package/dist/src/commands/stdlib/template.js': '27ea3ef6d273a003d089b7c38ced0bd89233ee9615149e48ee732d0615b1d5ac',
    'package/dist/src/core/filters.js': 'd7d2fa2481fd302ba699394bc7e8db0dd86f9844a8b399e2aa4d4cd0aedb0c14',
    'package/dist/src/core/value_path.js': 'e07cfee4e8fb4953ffbf02b8b51b5bbb4f01a6950515b2a1f9d31b0eb922171f',
  });
  for (const record of captured.sourceRecords) {
    assert.equal(record.wholeModule, true, record.path);
    assert.equal(record.executed, true, record.path);
  }
  assert.deepEqual(captured.executedCommands, ['template']);
  assert.equal(captured.executedRuntime, false);
  assert.equal(captured.productionFormatterExecuted, false);
  assert.equal(captured.nativeToolExecution, false);
  assert.equal(captured.machineOrTransportExecuted, false);
  assert.equal(captured.fileFixturesRemoved, true);
  assert.equal(captured.harness.path, 'scripts/openclaw/capture-lobster-template.mjs');
  assert.equal(captured.harness.sha256, digest(readFileSync(new URL('./capture-lobster-template.mjs', import.meta.url))));
  assert.equal(captured.license.path, 'package/LICENSE');
  assert.equal(captured.license.sha256, '0197dda80dd142fdcaa45eaa2b55ad1d2adeb16c1fac2d445bd1cbaf9a7251fb');
  assert.equal(captured.license.sha256, digest(captured.license.text));
});
test('fresh source capture matches every field of the frozen fixture', () => {
  const frozen = JSON.parse(readFileSync(new URL('../../apps/synapsis_agent/test/fixtures/openclaw/488631c/lobster-template.json', import.meta.url)));
  assert.deepEqual(captured, frozen);
});

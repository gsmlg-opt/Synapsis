// Complete pinned Google provider with explicitly synthetic successful service boundaries.
import assert from 'node:assert/strict';
import { Buffer } from 'node:buffer';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { lstatSync, readFileSync, readlinkSync, realpathSync, writeFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';
import { FactoryHarness } from './capture-recipes.mjs';

export const GOOGLE_IMAGE_GENERATION_PIN = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const fixedRoot = '/tmp/openclaw-488631c';
const fixedNode = '/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node';
const entry = 'extensions/google/image-generation-provider.ts';
const assets = 'src/image-generation/image-assets.ts';
const caps = 'src/media/configured-max-bytes.ts';
const jsonPost = 'src/media-understanding/provider-json-post.ts';
const transform = 'node:module.stripTypeScriptTypes(mode=transform,sourceMap=false)';
const hash = value => createHash('sha256').update(value).digest('hex');
const plain = value => JSON.parse(JSON.stringify(value));
const selectedManifest = {
  "pin": "488631c18fae7cc541ba8fc8beff6cbb0438787b",
  "sources": [
    {
      "path": "extensions/google/image-generation-provider.ts",
      "git_blob": "ed98282a9e08110daa780a5d0c547498a33974a8",
      "sha256": "37be0cef2a96e0f8ab33a5caee2a2149d873bbab900da105464c2d0375be7686",
      "lines": 214,
      "verified": true
    },
    {
      "path": "extensions/google/generation-provider-metadata.ts",
      "git_blob": "65d98d1b72e805dc8076a721860a8693fc9aab8e",
      "sha256": "91f96db45247516a4185cca22ffb32eeae64670c789c5390e707900939d7ff8c",
      "lines": 162,
      "verified": true
    },
    {
      "path": "extensions/google/base64.ts",
      "git_blob": "4ea98c8c80ca704c10702b11a3a41ce8536f45ad",
      "sha256": "0ff3204da29c95866d135a75c66a527ff9417e9b9393db7575ff87967ddee39b",
      "lines": 27,
      "verified": true
    },
    {
      "path": "extensions/google/generation-auth.ts",
      "git_blob": "281aa46fd78eb3061d1137c13665c932417d0252",
      "sha256": "a42931d91c8968af9fff300bf9bb09f375dca827faeb1a4b2dd218f79d221322",
      "lines": 17,
      "verified": true
    },
    {
      "path": "extensions/google/http-request.ts",
      "git_blob": "ee800b4f4524bf6409a049da27284b98c2bfb155",
      "sha256": "462e5990037e2495794ecfe874a3b772c1def65b128a338beaa42c6dc549f9f5",
      "lines": 64,
      "verified": true
    },
    {
      "path": "extensions/google/model-id.ts",
      "git_blob": "26a75ad05ce50bf0c569bf375762d5924dd41657",
      "sha256": "2f3ba3e433b2a14c3475928f24972bd9b85e260317bd1412c6b72df684fb193b",
      "lines": 10,
      "verified": true
    },
    {
      "path": "extensions/google/gemini-auth.ts",
      "git_blob": "0ef503a624d98edfa58611d957b90bbd3c1c756a",
      "sha256": "78f2f4cf87e6ea2f950ce94316fd38cfbf3aa97113faec81dc514594315ff4d3",
      "lines": 28,
      "verified": true
    },
    {
      "path": "extensions/google/oauth-token-shared.ts",
      "git_blob": "5aad1c22c58972ce911261377aa957ff8d6ea0fc",
      "sha256": "f051b31931cb308201d4af70bf15f5b2d5c6566c27dfe9cd08204b529354acef",
      "lines": 32,
      "verified": true
    },
    {
      "path": "extensions/google/google-api-client-header.ts",
      "git_blob": "c0fe39265ec5061de6fe0814840a456f378c1a65",
      "sha256": "6da8b8186c9c8f46fa6ef0d57afda4edcb9e7b45f37de1d520a2a7bb7df8b601",
      "lines": 23,
      "verified": true
    },
    {
      "path": "extensions/google/provider-policy.ts",
      "git_blob": "7bdfe90b83ae2429a1722b0a957ab46f2415d7f4",
      "sha256": "cdd09be2c7968d99ccfc5ef9f46a8c0ba53d6f8ea40b83f4ea452efe77a7690f",
      "lines": 164,
      "verified": true
    },
    {
      "path": "extensions/google/src/google-api-base-url.ts",
      "git_blob": "f4e27a46e72fa516c441db411b524f11b9452b7f",
      "sha256": "353e26578bf2661f85dc27bdbaa2bbf9fd0205ff088ab52459dec1279662cfbe",
      "lines": 88,
      "verified": true
    },
    {
      "path": "packages/model-catalog-core/src/provider-model-id-normalize.ts",
      "git_blob": "f256d2d0cd0ba01279775690297066726cdf09f7",
      "sha256": "7baf8ecbed07f6c75c069e332052712c9c21eb4410e0617e8c8b14365d51adb3",
      "lines": 44,
      "verified": true
    },
    {
      "path": "src/image-generation/image-assets.ts",
      "git_blob": "ec73319b6e70662f7b537ae720ce3f4f0b3512a1",
      "sha256": "8c6d47d65f2ea808679c857532e4af96ddab6f9d68005ee53527b494f5e88682",
      "lines": 275,
      "verified": true
    },
    {
      "path": "packages/media-core/src/base64.ts",
      "git_blob": "31eead019c4aeecd081ba7836e7ec408a367ae1c",
      "sha256": "93e6ef481601a3bee0a6cbd304506a0b1ab4e1e05d363be78a00ebe7b63173ac",
      "lines": 141,
      "verified": true
    },
    {
      "path": "packages/media-core/src/constants.ts",
      "git_blob": "03db8b857c1d69601903eda22f204b02ce640f6f",
      "sha256": "eaf6503c56b32bab745da862d150c76896805e7db2f5bb12283e2930b64cb184",
      "lines": 45,
      "verified": true
    },
    {
      "path": "packages/normalization-core/src/number-coercion.ts",
      "git_blob": "00ac5bda035cd8e854059a0198c2a9a7928e1bc9",
      "sha256": "8c40eca65a8fd1dc3aa40d90c22bff35c3710fcb03d2bc8227864a264d20ddc4",
      "lines": 372,
      "verified": true
    },
    {
      "path": "packages/normalization-core/src/string-coerce.ts",
      "git_blob": "445a9cc4f8daff07f033c3958baf2b798e240e9d",
      "sha256": "0f62efe900e43b23b12025da27f5e65aa6e7fee369191cbbdcf4200f0de70cdf",
      "lines": 132,
      "verified": true
    },
    {
      "path": "packages/normalization-core/src/record-coerce.ts",
      "git_blob": "78eba9cd0e4c75f94e71dfb3fcb7f4cf4eeeef16",
      "sha256": "541c179840c2cad4edc5c8103f77cc7f8c6b1ee5ec3e52c7c9fe097b18917f1c",
      "lines": 83,
      "verified": true
    },
    {
      "path": "src/media/configured-max-bytes.ts",
      "git_blob": "0a0c31d1017e765bc1bd399fc7179e1aca4e97f8",
      "sha256": "07d61d83f1ed8c14e0cd7a5f5532d2cc64d28e0a6d15c36690670a3900df3a6d",
      "lines": 96,
      "verified": true
    },
    {
      "path": "src/plugin-sdk/image-generation.ts",
      "git_blob": "77ea74f07e0679b14379f276106cc63fdfc6219f",
      "sha256": "a231cd3d22750bb4ba9d8f42175803b8d9fa7a6c63fcde394f27855ece74257a",
      "lines": 35,
      "verified": true
    },
    {
      "path": "src/plugin-sdk/provider-http.ts",
      "git_blob": "ad703242d2aed595c471c02b60536043461be208",
      "sha256": "2256cc416a1d07c644917faed3c3d8bd4d6e44658197fc5ae6e1301ed85b42c4",
      "lines": 142,
      "verified": true
    },
    {
      "path": "src/plugin-sdk/media-generation-runtime.ts",
      "git_blob": "7f450ca174b41a9dfa5fd6143f244e6016840314",
      "sha256": "12167922a386fabe012fe14d7b8590fed6fbc5ab73ee7c571916e9e4b4f36744",
      "lines": 9,
      "verified": true
    },
    {
      "path": "src/plugin-sdk/model-ref-parse.ts",
      "git_blob": "12cc2f079be7290fd852906e3d08e64bde4155ca",
      "sha256": "95d4a55446f482bfffbb089d055c13f4ac2745dfb708a033f11be511da603586",
      "lines": 19,
      "verified": true
    },
    {
      "path": "src/plugin-sdk/provider-auth-runtime.ts",
      "git_blob": "2bfd1627ba6d1281148ea12c0ef992465e98019c",
      "sha256": "b1a1127b62cd8937aa6a3c744e45f74aa05373e80561533d58052401f12c6eee",
      "lines": 320,
      "verified": true
    },
    {
      "path": "src/plugin-sdk/string-coerce-runtime.ts",
      "git_blob": "ecb5392d5b93242bd2899b11246197a9fbd4ea26",
      "sha256": "9b3d30c868101d6005cadd5990dbcb62bf9afe91171aaf35191c996005484c47",
      "lines": 61,
      "verified": true
    },
    {
      "path": "src/plugin-sdk/number-runtime.ts",
      "git_blob": "e3d6a66fee2ed7aec780017ec71b61236a59ae21",
      "sha256": "77dd91a05253aab719ca61c22ef6d10db5aa79e360e9cab48cf0e62abf52184c",
      "lines": 43,
      "verified": true
    },
    {
      "path": "src/media-understanding/shared.ts",
      "git_blob": "c95cdc7df6b3084f8d5635fc018c8998d09b4ff7",
      "sha256": "756b347e82f780257c6fd5aa13617f9706db62af895b7faa9b450d6dff9cb910",
      "lines": 587,
      "verified": true
    },
    {
      "path": "src/media-understanding/provider-json-post.ts",
      "git_blob": "f566e8437db38bb5c90dbc27433bf26087bcf8b8",
      "sha256": "7c7af0bcb7c1b61f57cf0809214f8103323b8ef289a70142ba430e2c632a4104",
      "lines": 35,
      "verified": true
    },
    {
      "path": "src/agents/provider-request-config.ts",
      "git_blob": "bc9c0b4083a70e209329c71a16552189cefbd5f9",
      "sha256": "cc54d8fc777b682c64adbcf9c53e1c1e24967575cb4207e31ca7542037520fc8",
      "lines": 722,
      "verified": true
    },
    {
      "path": "src/agents/provider-attribution.ts",
      "git_blob": "9b5b9542657bc8798d5e74a9988b448920b96165",
      "sha256": "6b31e4bf70eda4ba54f7ea8d76d11e6c070f2e233ab16e71444f51658e8c4460",
      "lines": 549,
      "verified": true
    },
    {
      "path": "extensions/google/index.ts",
      "git_blob": "188aa5cc940b8d3abc3e4029785b6e9b932341e6",
      "sha256": "a74f71f3ae88d806bed81ebb2eb0d05be675e12deeef0b97106217a4ecba1a4c",
      "lines": 69,
      "verified": true
    },
    {
      "path": "extensions/google/openclaw.plugin.json",
      "git_blob": "1ffb372184978e7f4cfeda4c30423fc8c190d9c6",
      "sha256": "8ed0ba5e5ce3f7bf5cd9e4f9a516faf941e14d124ff08b6aec56bf93eb49feb6",
      "lines": 1063,
      "verified": true
    },
    {
      "path": "src/image-generation/types.ts",
      "git_blob": "d00009f368f3df2603d7d3df7fb7fd0c897b7c03",
      "sha256": "f59668a105c993a0ba2d4d02ccc022d0f811ab820beef4e18f8df577bc286405",
      "lines": 143,
      "verified": true
    }
  ]
};
const wholeSources = [entry, assets, jsonPost,
  'extensions/google/generation-provider-metadata.ts', 'extensions/google/base64.ts',
  'extensions/google/generation-auth.ts', 'extensions/google/http-request.ts',
  'extensions/google/model-id.ts', 'extensions/google/gemini-auth.ts',
  'extensions/google/oauth-token-shared.ts', 'extensions/google/google-api-client-header.ts',
  'extensions/google/provider-policy.ts', 'extensions/google/src/google-api-base-url.ts',
  'packages/model-catalog-core/src/provider-model-id-normalize.ts',
  'packages/media-core/src/base64.ts', 'packages/media-core/src/constants.ts',
  'packages/normalization-core/src/number-coercion.ts',
  'packages/normalization-core/src/string-coerce.ts', 'packages/normalization-core/src/record-coerce.ts'];
const extraProvenance = ['src/plugin-sdk/provider-auth.ts', 'src/plugin-sdk/realtime-voice-provider.ts',
  'src/plugin-sdk/provider-thinking-runtime.ts', 'src/agents/provider-http-errors.ts'];

function git(root, args) {
  return execFileSync('git', ['-C', root, ...args], { encoding: 'utf8', timeout: 30_000,
    maxBuffer: 64 * 1024 * 1024,
    env: { ...process.env, GIT_OPTIONAL_LOCKS: '0', GIT_NO_REPLACE_OBJECTS: '1' } }).trimEnd();
}

function checkout(root) {
  assert.equal(realpathSync(git(root, ['rev-parse', '--show-toplevel'])), root);
  assert.equal(git(root, ['rev-parse', 'HEAD']), GOOGLE_IMAGE_GENERATION_PIN);
  assert.equal(git(root, ['status', '--porcelain', '--untracked-files=no']), '');
  const files = git(root, ['ls-tree', '-rz', '--full-tree', GOOGLE_IMAGE_GENERATION_PIN]).split('\0').filter(Boolean).map(item => {
    const [header, source] = item.split('\t');
    const [mode, type, blob] = header.split(' ');
    assert.equal(type, 'blob');
    assert.ok(['100644', '100755', '120000'].includes(mode));
    assert.ok(!isAbsolute(source) && !source.split('/').includes('..'));
    const file = join(root, source);
    const status = lstatSync(file);
    const symlink = status.isSymbolicLink();
    assert.equal(symlink, mode === '120000');
    if (!symlink) assert.equal(Boolean(status.mode & 0o111), mode === '100755', source);
    assert.ok(realpathSync(file).startsWith(root + sep));
    const bytes = symlink ? Buffer.from(readlinkSync(file)) : readFileSync(file);
    assert.equal(createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex'), blob, source);
    return { path: source, mode, gitBlob: blob, sha256: hash(bytes), ...(symlink ? { symlinkTarget: readlinkSync(file) } : {}) };
  });
  return { tracked: new Map(files.map(row => [row.path, row.sha256])),
    receipt: { verified: true, commit: GOOGLE_IMAGE_GENERATION_PIN,
      tree: git(root, ['rev-parse', `${GOOGLE_IMAGE_GENERATION_PIN}^{tree}`]),
      verifiedTrackedFiles: files.length, filesSha256: hash(JSON.stringify(files)) } };
}

// Opaque bytes verify transport preservation, not codecs or visual quality.
const png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jVJkAAAAASUVORK5CYII=';
const inline = (data = png, mimeType = 'image/png') => ({ inlineData: { data, mimeType } });
const response = (...parts) => ({ candidates: [{ content: { parts } }] });

function vectors() {
  const input = { prompt: ' Draw a small blue square. ', model: 'gemini-3.1-flash-image', timeoutMs: 12345 };
  const base = (id, overrides = {}, json = response(inline()), config = {}) => ({ id, hostComparable: true,
    input: { ...input, ...overrides }, config: { baseUrl: 'https://generativelanguage.googleapis.com/v1beta', ...config },
    response: { json } });
  const defaults = base('source-only-defaults');
  delete defaults.input.model;
  delete defaults.input.timeoutMs;
  defaults.hostComparable = false;
  defaults.adaptationReason = 'Source defaults omitted model and timeout to gemini-3.1-flash-image and 180000 ms; host requires explicit model and finite timeout.';
  const aliases = ['gemini-3-pro', 'gemini-3-pro-preview', 'gemini-3-flash', 'gemini-3.1-pro',
    'gemini-3.1-flash-lite-preview', 'gemini-3.1-flash', 'gemini-3.1-flash-preview', 'gemini-4', 'gemma-4-26b'];
  return [defaults, base('explicit-default'), base('custom-model', { model: ' \u00a0Vendor/Image-X\ufeff ' }),
    ...aliases.map(model => base(`alias-${model}`, { model })),
    base('alias-prefixed', { model: 'google/gemini-3-pro' }),
    ...['1024x1024', '1024x1536', '1536x1024', '1024x1792', '1792x1024'].map(size => base(`size-${size}`, { size })),
    base('size-unmapped-small', { size: '800x600' }),
    base('size-tier-2k', { size: '2048x1152' }),
    base('size-tier-4k', { size: '4096x2304' }),
    base('size-js-whitespace', { size: '\u00a0\ufeff1024X1536\u2029' }),
    base('geometry-overrides-1k', { size: '1792x1024', aspectRatio: ' \u00a04:5\ufeff ', resolution: '1K' }),
    base('geometry-overrides-2k', { size: '4096x2304', aspectRatio: '21:9', resolution: '2K' }),
    base('geometry-overrides-4k', { size: '1024x1024', aspectRatio: '3:4', resolution: '4K' }),
    base('blank-aspect', { size: '1024x1536', aspectRatio: '\u00a0\ufeff\u2029' }),
    base('edit-one', { inputImages: [{ bytesBase64: png, mimeType: 'image/png', fileName: 'ignored/name.png' }] }),
    base('edit-five', { inputImages: [
      { bytesBase64: 'AQ==', mimeType: ' Image/JPEG; ColorSpace=RGB ', fileName: 'one.jpg' },
      { bytesBase64: 'Ag==', mimeType: 'image/webp' }, { bytesBase64: 'Aw==', mimeType: 'image/png' },
      { bytesBase64: 'BA==', mimeType: 'image/svg+xml' }, { bytesBase64: 'BQ==', mimeType: 'image/avif' }] }),
    base('count-one', { count: 1 }), base('count-four', { count: 4 }),
    base('ignored-controls', { count: 4, quality: 'high', outputFormat: 'jpeg', background: 'transparent',
      providerOptions: { google: { candidateCount: 3, imageSize: '4K' }, arbitrary: true } }),
    base('ordered-candidates', {}, { candidates: [ {}, { content: null }, { content: {} }, { content: { parts: null } },
      { content: { parts: [{ text: 'ignored lead', thought: true }, inline('AQ==', 'image/png'), { text: 'middle' }] } },
      { content: { parts: [{ inline_data: { data: 'Ag==', mime_type: 'image/webp' } }, inline('Aw==', 'image/avif')] }, finishReason: 'STOP' } ],
      usageMetadata: { totalTokenCount: 99 }, modelVersion: 'ignored', text: 'ignored envelope' }),
    base('mime-precedence', {}, response(
      { inlineData: { data: 'AQ==', mimeType: ' Image/JPEG; ColorSpace=RGB ', mime_type: 'image/webp', extra: true },
        inline_data: { data: 'CQ==', mimeType: 'image/avif' } },
      { inlineData: { data: 'Ag==', mimeType: ' \u00a0 ', mime_type: ' image/svg+xml; charset=UTF-8 ' } },
      { inline_data: { data: '/9j/', mimeType: '\ufeff', mime_type: '  ' } },
      { inlineData: null, inline_data: { data: 'BA==', mime_type: 'IMAGE/WEBP; Mode=Lossless' } },
      { inlineData: { data: 'BQ==', mimeType: 'application/octet-stream' } },
      { inlineData: { data: 'Bg==', mimeType: 'opaque' } })),
    base('base64-variants', {}, response(inline('AQ=='), inline('Ag'), inline('-_8='), inline('-_8'),
      inline(' \u00a0A Q = =\r\n\ufeff '))),
    base('more-than-four', { count: 1 }, response(...['AQ==', 'Ag==', 'Aw==', 'BA==', 'BQ==', 'Bg=='].map(data => inline(data)))),
    base('larger-media-cap', {}, undefined, { mediaMaxMb: 80.25 }),
    base('official-root-normalization', {}, undefined, { baseUrl: ' https://generativelanguage.googleapis.com/openai/// ' }),
    base('official-uppercase-host', {}, undefined, { baseUrl: 'https://GENERATIVELANGUAGE.GOOGLEAPIS.COM/openai///' }),
  ];
}

class GoogleImageHarness extends FactoryHarness {
  constructor(root, tracked) {
    super(root, tracked, { allowedSources: wholeSources });
    this.context = vm.createContext({ Buffer, ArrayBuffer, Uint8Array, Headers, Response, URL,
      process: { env: {} }, fetch: () => { throw Error('Live fetch is outside the Google image oracle'); },
      __platform: {
        key: params => { this.current.facadeCalls.push({ kind: 'explicit-key', input: plain(params) });
          return { apiKey: 'fixture-google-images', mode: 'api-key' }; },
        sanitize: value => { this.current.facadeCalls.push({ kind: 'request-sanitizer', input: value ?? null, output: null }); return undefined; },
        attribution: params => { this.current.facadeCalls.push({ kind: 'attribution', input: plain(params), output: {} }); return {}; },
        config: params => { const output = { baseUrl: params.baseUrl, headers: { ...params.defaultHeaders, ...params.headers }, allowPrivateNetwork: false };
          this.current.facadeCalls.push({ kind: 'request-config', input: plain(params), output: plain(output) }); return output; },
        post: params => this.post(params),
        status: (res, label, options) => { assert.equal(res.status, 200);
          this.current.facadeCalls.push({ kind: 'successful-status', label, options: options ?? null }); },
        read: async (res, label, options) => {
          this.current.readerCalls.push({ kind: 'json', label, maxBytes: options.maxBytes });
          this.current.requests.at(-1).maxBytes = options.maxBytes;
          return res.json();
        },
      } }, { codeGeneration: { strings: false, wasm: false } });
    this.sourceRecords = new Map();
    this.importBindings = new Map();
    this.dynamicImports = [];
  }

  module(file) {
    if (this.modules.has(file)) return this.modules.get(file);
    const source = relative(this.root, file);
    assert.ok(wholeSources.includes(source), `declared whole source: ${source}`);
    const bytes = readFileSync(file);
    assert.equal(hash(bytes), this.tracked.get(source), source);
    const executable = stripTypeScriptTypes(bytes.toString(), { mode: 'transform', sourceMap: false });
    this.sourceRecords.set(source, { path: source, sha256: hash(bytes), executed: true, wholeModule: true,
      transformation: transform, executableSha256: hash(executable) });
    const mod = new vm.SourceTextModule(executable, { context: this.context, identifier: file,
      importModuleDynamically: async specifier => {
        this.dynamicImports.push({ importer: source, specifier, permitted: false });
        throw Error(`Undeclared Google dynamic import: ${source} -> ${specifier}`);
      } });
    this.modules.set(file, mod);
    return mod;
  }

  binding(importer, specifier, kind, exports, code, source, extra = {}) {
    const key = importer + ':' + specifier;
    if (!this.importBindings.has(key)) this.importBindings.set(key, { importer, specifier, kind, exports,
      generatedCode: code, generatedSha256: hash(code),
      ...(source ? { source, sourceSha256: this.tracked.get(source) } : {}), ...extra });
    return this.synthetic('capture:google-image:' + key, code);
  }

  source(importer, specifier, source) {
    const key = importer + ':' + specifier;
    if (!this.importBindings.has(key)) this.importBindings.set(key, { importer, specifier,
      kind: 'whole-source-module', source, sourceSha256: this.tracked.get(source) });
    return this.module(join(this.root, source));
  }

  alias(importer, specifier, source, exports, origin) {
    return this.binding(importer, specifier, 'whole-source-export-alias', exports,
      `export {${exports.join(',')}} from ${JSON.stringify('capture:source:' + source)};`, source,
      ...(origin ? [{ origin, originSha256: this.tracked.get(origin) }] : []));
  }

  unused(importer, specifier, exports, source) {
    return this.binding(importer, specifier, 'uninvoked-throwing-facade', exports,
      exports.map(name => `export function ${name}(){throw Error('Uninvoked Google image dependency: ${name}');}`).join('\n'),
      source, { originalSourceExecuted: false });
  }

  capsProjection(importer, specifier) {
    const original = readFileSync(join(this.root, caps));
    assert.equal(hash(original), this.tracked.get(caps));
    const startMarker = 'const MB = 1024 * 1024;';
    const endMarker = '/** Reads channel/account media caps';
    const start = original.indexOf(startMarker);
    const end = original.indexOf(endMarker, start);
    assert.ok(start >= 0 && end > start);
    assert.equal(original.indexOf(startMarker, start + 1), -1);
    const selected = original.subarray(start, end);
    const prelude = "import {maxBytesForKind} from 'capture:source:packages/media-core/src/constants.ts';";
    const generated = prelude + '\n' + selected.toString();
    const executable = stripTypeScriptTypes(generated, { mode: 'transform', sourceMap: false });
    this.sourceRecords.set(caps, { path: caps, sha256: hash(original), executed: true, wholeModule: false,
      projection: { startByte: start, endByte: end, sourceRegionSha256: hash(selected), prelude,
        generatedCode: generated, generatedSha256: hash(generated) },
      transformation: transform, executableSha256: hash(executable) });
    return this.binding(importer, specifier, 'complete-source-region-projection', ['resolveGeneratedImageDownloadMaxBytes'],
      executable, caps, { origin: 'src/plugin-sdk/media-generation-runtime.ts',
        originSha256: this.tracked.get('src/plugin-sdk/media-generation-runtime.ts') });
  }

  import(specifier, parent) {
    const importer = relative(this.root, parent);
    if (parent.startsWith('capture:google-image:') && specifier.startsWith('capture:source:')) {
      return this.source(parent, specifier, specifier.slice('capture:source:'.length));
    }
    if (specifier === 'openclaw/plugin-sdk/image-generation' && importer === entry) {
      return this.alias(importer, specifier, assets, ['generatedImageAssetFromBase64', 'resolveInlineImageJsonResponseMaxBytes'], 'src/plugin-sdk/image-generation.ts');
    }
    if (specifier === 'openclaw/plugin-sdk/media-generation-runtime' && importer === entry) return this.capsProjection(importer, specifier);
    if (specifier === 'openclaw/plugin-sdk/number-runtime' && importer === entry) {
      return this.alias(importer, specifier, 'packages/normalization-core/src/number-coercion.ts', ['parseStrictPositiveInteger'], 'src/plugin-sdk/number-runtime.ts');
    }
    if (specifier === 'openclaw/plugin-sdk/model-ref-parse' && importer === 'extensions/google/model-id.ts') {
      return this.alias(importer, specifier, 'packages/model-catalog-core/src/provider-model-id-normalize.ts',
        ['normalizeAntigravityPreviewModelId', 'normalizeGooglePreviewModelId'], 'src/plugin-sdk/model-ref-parse.ts');
    }
    if (specifier === 'openclaw/plugin-sdk/realtime-voice-provider' && importer === 'extensions/google/base64.ts') {
      return this.alias(importer, specifier, 'packages/media-core/src/base64.ts', ['canonicalizeBase64'], 'src/plugin-sdk/realtime-voice-provider.ts');
    }
    if (specifier === 'openclaw/plugin-sdk/string-coerce-runtime' && importer.startsWith('extensions/google/')) {
      return this.binding(importer, specifier, 'whole-source-export-alias', ['isRecord', 'normalizeLowercaseStringOrEmpty', 'normalizeOptionalString', 'readStringValue'],
        "export {isRecord} from 'capture:source:packages/normalization-core/src/record-coerce.ts';\nexport {normalizeLowercaseStringOrEmpty,normalizeOptionalString,readStringValue} from 'capture:source:packages/normalization-core/src/string-coerce.ts';",
        undefined, { origin: 'src/plugin-sdk/string-coerce-runtime.ts', originSha256: this.tracked.get('src/plugin-sdk/string-coerce-runtime.ts') });
    }
    if (specifier === 'openclaw/plugin-sdk/provider-auth' && [entry, 'extensions/google/generation-provider-metadata.ts'].includes(importer)) {
      return this.unused(importer, specifier, ['isProviderApiKeyConfiguredAsync'], 'src/plugin-sdk/provider-auth.ts');
    }
    if (specifier === 'openclaw/plugin-sdk/provider-thinking-runtime' && importer === 'extensions/google/provider-policy.ts') {
      return this.unused(importer, specifier, ['isGoogleGemini3ProModel', 'isGoogleGemini3ThinkingLevelModel'], 'src/plugin-sdk/provider-thinking-runtime.ts');
    }
    if (specifier === 'openclaw/plugin-sdk/provider-auth-runtime' && importer === 'extensions/google/generation-auth.ts') {
      return this.binding(importer, specifier, 'successful-explicit-key-facade', ['resolveApiKeyForProvider'],
        'export async function resolveApiKeyForProvider(params){return globalThis.__platform.key(params);}',
        'src/plugin-sdk/provider-auth-runtime.ts', { originalSourceExecuted: false,
          boundary: 'Literal successful key fixture; records provider/cfg/store inputs. No credential discovery or readiness execution.' });
    }
    if (specifier === 'openclaw/plugin-sdk/provider-http' && [entry, 'extensions/google/http-request.ts', 'extensions/google/google-api-client-header.ts'].includes(importer)) {
      return this.binding(importer, specifier, 'successful-config-policy-attribution-facades-with-real-json-post',
        ['postJsonResponse', 'sanitizeConfiguredModelProviderRequest', 'resolveProviderHttpRequestConfig', 'resolveProviderRequestHeaders'],
        `export {postJsonResponse} from 'capture:source:${jsonPost}';\nexport const sanitizeConfiguredModelProviderRequest=globalThis.__platform.sanitize;\nexport const resolveProviderHttpRequestConfig=globalThis.__platform.config;\nexport const resolveProviderRequestHeaders=globalThis.__platform.attribution;`,
        'src/plugin-sdk/provider-http.ts', { originalSourceExecuted: false,
          facadeOwners: ['src/agents/provider-request-config.ts', 'src/agents/provider-attribution.ts'],
          boundary: 'Configuration/sanitizer/header policy and attribution are recorded successful facades. Empty attribution avoids claiming OpenClaw identity; Google wrapper/auth literal-key path and JSON-post owner execute unchanged.' });
    }
    if (importer === jsonPost && specifier === './shared.js') {
      return this.binding(importer, specifier, 'successful-http-transport-facade', ['postJsonRequest'],
        'export const postJsonRequest=globalThis.__platform.post;', 'src/media-understanding/shared.ts',
        { originalSourceExecuted: false, boundary: 'Synthetic literal successful HTTP Response; records exact source request. No external fetch, DNS, TLS, retry or deadline enforcement.' });
    }
    if (importer === jsonPost && specifier === '../agents/provider-http-errors.js') {
      return this.binding(importer, specifier, 'successful-status-native-json-reader-facades',
        ['assertOkOrThrowHttpError', 'readProviderJsonResponse', 'readProviderJsonObjectResponse'],
        "export const assertOkOrThrowHttpError=globalThis.__platform.status;\nexport const readProviderJsonResponse=globalThis.__platform.read;\nexport function readProviderJsonObjectResponse(){throw Error('Uninvoked object response reader');}",
        'src/agents/provider-http-errors.ts', { originalSourceExecuted: false,
          boundary: 'Records actual source cap; native Response.json parses literal fixture. Production streaming/body bounds are unexecuted. Actual whole JSON POST finally releases once.' });
    }
    const packages = {
      '@openclaw/normalization-core/number-coercion': 'packages/normalization-core/src/number-coercion.ts',
      '@openclaw/normalization-core/string-coerce': 'packages/normalization-core/src/string-coerce.ts',
      '@openclaw/normalization-core/record-coerce': 'packages/normalization-core/src/record-coerce.ts',
      '@openclaw/media-core/base64': 'packages/media-core/src/base64.ts',
      '@openclaw/media-core/constants': 'packages/media-core/src/constants.ts',
    };
    if (packages[specifier]) return this.source(importer, specifier, packages[specifier]);
    if (specifier.startsWith('.')) {
      const source = relative(this.root, resolve(dirname(parent), specifier)).replace(/\.js$/, '.ts');
      if (wholeSources.includes(source)) return this.source(importer, specifier, source);
    }
    throw Error(`Undeclared Google image import: ${importer} -> ${specifier}`);
  }

  async post(params) {
    assert.equal(typeof params.fetchFn, 'function');
    assert.equal(params.pinDns, false);
    this.current.requests.push({ url: params.url, method: 'POST', headers: plain(params.headers),
      body: plain(params.body), timeoutMs: params.timeoutMs });
    return { response: new Response(JSON.stringify(this.current.response.json), { status: 200,
      headers: { 'content-type': 'application/json' } }), release: async () => { this.current.releaseCount += 1; } };
  }

  async run(vector) {
    this.current = { response: plain(vector.response), requests: [], releaseCount: 0, readerCalls: [], facadeCalls: [] };
    const { inputImages, ...input } = plain(vector.input);
    const req = { ...input, provider: 'google', cfg: {
      models: { providers: { google: { apiKey: 'fixture-google-images', baseUrl: vector.config.baseUrl } } },
      ...(vector.config.mediaMaxMb === undefined ? {} : { agents: { defaults: { mediaMaxMb: vector.config.mediaMaxMb } } }) },
      ...(inputImages ? { inputImages: inputImages.map(({ bytesBase64, ...image }) => ({ ...image, buffer: Buffer.from(bytesBase64, 'base64') })) } : {}) };
    const cfgBefore = plain(req.cfg);
    this.context.__req = req;
    let timer;
    try {
      const promise = new vm.Script('__exports.googleImageGenerationProvider.generateImage(__req)').runInContext(this.context, { timeout: 1000 });
      const result = await Promise.race([promise, new Promise((_, reject) => {
        timer = setTimeout(() => reject(Error('Google image fixture asynchronous deadline exceeded')), 5000);
      })]);
      assert.equal(this.current.requests.length, 1);
      assert.equal(this.current.releaseCount, 1);
      assert.deepEqual(plain(req.cfg), cfgBefore);
      const { provider: _provider, cfg: _cfg, inputImages: afterImages, ...afterInput } = req;
      const inputAfter = { ...plain(afterInput), ...(afterImages ? { inputImages: afterImages.map(({ buffer, ...image }) =>
        ({ ...plain(image), bytesBase64: buffer.toString('base64') })) } : {}) };
      assert.deepEqual(inputAfter, vector.input);
      return { ...vector, inputAfter, request: this.current.requests[0],
        result: plain({ ...result, images: result.images.map(({ buffer, ...image }) =>
          ({ ...image, bytesBase64: buffer.toString('base64') })) }), releaseCount: this.current.releaseCount,
        readerCalls: this.current.readerCalls, facadeCalls: this.current.facadeCalls };
    } finally { clearTimeout(timer); }
  }
}

export async function captureGoogleImageGeneration(source = fixedRoot) {
  assert.equal(process.versions.node, '24.22.1');
  assert.equal(realpathSync(process.execPath), realpathSync(fixedNode));
  const root = realpathSync(source);
  assert.equal(root, fixedRoot);
  const before = checkout(root);
  assert.equal(before.receipt.verifiedTrackedFiles, 58558);
  assert.equal(selectedManifest.pin, GOOGLE_IMAGE_GENERATION_PIN);
  assert.equal(selectedManifest.sources.length, 33);
  for (const source of selectedManifest.sources) {
    const bytes = readFileSync(join(root, source.path));
    assert.equal(source.verified, true);
    assert.equal(hash(bytes), source.sha256, source.path);
    assert.equal(createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex'), source.git_blob, source.path);
    assert.equal(bytes.toString().split('\n').length - Number(bytes.at(-1) === 10), source.lines, source.path);
  }
  const harness = new GoogleImageHarness(root, before.tracked);
  await harness.load(entry);
  const metadata = plain(harness.context.__exports.googleImageGenerationProvider);
  const observations = [];
  for (const vector of vectors()) observations.push(await harness.run(vector));
  for (const source of wholeSources) assert.ok(harness.sourceRecords.has(source), `loaded whole source: ${source}`);
  const sourceRecords = [...harness.sourceRecords.values()];
  for (const source of [...selectedManifest.sources.map(row => row.path), ...extraProvenance]) {
    if (sourceRecords.some(row => row.path === source)) continue;
    const bytes = readFileSync(join(root, source));
    assert.equal(hash(bytes), before.tracked.get(source), source);
    sourceRecords.push({ path: source, sha256: hash(bytes), executed: false, provenanceOnly: true });
  }
  const after = checkout(root);
  assert.deepEqual(after.receipt, before.receipt);
  return { schemaVersion: 1, referencePin: GOOGLE_IMAGE_GENERATION_PIN,
    exporter: { path: 'scripts/openclaw/capture-google-image-generation.mjs', sha256: hash(readFileSync(fileURLToPath(import.meta.url))) },
    harness: { path: 'scripts/openclaw/capture-recipes.mjs', sha256: hash(readFileSync(new URL('./capture-recipes.mjs', import.meta.url))) },
    runtime: { executable: fixedNode, version: process.versions.node, sha256: hash(readFileSync(fixedNode)), platform: process.platform },
    selectedManifest, sourceTree: { before: before.receipt, after: after.receipt }, transformation: transform,
    sourceRecords, importBindings: [...harness.importBindings.values()], dynamicImports: harness.dynamicImports, metadata,
    vectorIds: observations.map(row => row.id), hostComparableIds: observations.filter(row => row.hostComparable).map(row => row.id),
    limits: [
      'Complete unchanged 214-line Google provider plus whole metadata/model/base64/asset/pure helpers and Google URL/HTTP/auth-wrapper modules execute. Generic successful literal-key boundary is synthetic; isConfiguredAsync and actual credential readiness are never invoked.',
      'All 58,558 tracked reference blobs, pin, modes and symlinks are verified before/after; exact source/executable/exporter/harness/runtime/import/facade hashes and empty dynamic-import receipt are recorded. No loader errors are caught or ignored.',
      'Generated image cap executes the complete original configured-max-bytes source region with byte offsets, original/generated/executable hashes and real media constants. Actual default response cap is 358962518 bytes; configured larger media caps execute the same source formula.',
      'Whole provider-json-post executes the actual finally release around synthetic successful transport/status/native Response.json facades. Production HTTP, bounded streaming read, retries, timeout enforcement, cancellation and cleanup beyond this literal release are unverified.',
      'Generic request sanitizer/config/header policy and attribution bodies are recorded successful facades. Empty attribution deliberately omits OpenClaw client identity; Synapsis must not impersonate OpenClaw. This is protocol body/result parity, not actual shared-policy execution.',
      'Source Google wrapper uses the official HTTPS generativelanguage.googleapis.com root. The host Gaoxy seam may replace only an independently compared official root after builder comparison; the source does not accept localhost. Bad-base rejection is source-reviewed only; no security/auth/negative tests execute.',
      'Source-only omitted model/timeout vector is hostComparable=false; host requires explicit model/finite timeout. Small opaque bytes prove preservation only. Input count capability and 64 MiB per-image host admission are tighter host bounds; source direct decoder preserves all returned images, including more than four.',
      'Inactive additive protocol groundwork only: no tool/config/provider selection, saved readiness, real provider, jobs, durable media, delivery or whole P10 completion. No failure/cancel/crash/mixed/auth/TLS/security/permission paths are exercised.',
    ], observations };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  assert.ok(process.argv[3], 'usage: capture-google-image-generation.mjs PINNED_SOURCE OUTPUT_JSON');
  const result = await captureGoogleImageGeneration(process.argv[2]);
  writeFileSync(process.argv[3], JSON.stringify(result, null, 2) + '\n');
  process.stdout.write(JSON.stringify({ output: process.argv[3], vectors: result.observations.length,
    wholeModules: result.sourceRecords.filter(row => row.executed && row.wholeModule).length,
    sourceProjections: result.sourceRecords.filter(row => row.executed && !row.wholeModule).length,
    trackedBlobs: result.sourceTree.before.verifiedTrackedFiles }) + '\n');
}

// Exact pinned source projections for public Diffs configuration and receipts.
// Renderer, storage, gateway fallback and HTTP effects are deliberately absent.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { posix } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';
import { captureDiffsRequest, DIFFS_REQUEST_PIN } from './capture-diffs-request.mjs';

const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const clone = value => JSON.parse(JSON.stringify(value));

export async function captureDiffsDelivery(root = '/tmp/openclaw-488631c') {
  const reference = await captureDiffsRequest(root);
  const sources = new Map(reference.sourceRecords.map(row => [row.path, row]));
  // url.ts is not in the preparation capture. Verify its bytes against the pin.
  const { execFileSync } = await import('node:child_process');
  const urlPath = 'extensions/diffs/src/url.ts';
  const records = 'packages/normalization-core/src/record-coerce.ts';
  for (const path of [urlPath, records]) {
    const bytes = readFileSync(root + '/' + path);
    assert.deepEqual(bytes, execFileSync('git', ['-C', root, 'show', `${DIFFS_REQUEST_PIN}:${path}`]));
    sources.set(path, { path, content: bytes.toString(), bytes: bytes.length, sha256: sha(bytes) });
  }
  const projections = [];
  function region(path, id, startText, endText) {
    const source = sources.get(path);
    const start = source.content.indexOf(startText);
    assert.ok(start >= 0 && source.content.indexOf(startText, start + 1) === -1, id);
    const end = endText === null ? source.content.length : source.content.indexOf(endText, start + startText.length);
    assert.ok(end > start, id);
    const selectedSource = source.content.slice(start, end);
    projections.push({ path, id, startByte: Buffer.byteLength(source.content.slice(0, start)), endByte: Buffer.byteLength(source.content.slice(0, end)), selectedSource, sha256: sha(selectedSource) });
    return selectedSource;
  }
  const config = 'extensions/diffs/src/config.ts';
  const tool = 'extensions/diffs/src/tool.ts';
  const numbers = 'packages/normalization-core/src/number-coercion.ts';
  const strings = 'packages/normalization-core/src/string-coerce.ts';
  const types = 'extensions/diffs/src/types.ts';
  const utils = 'src/utils.ts';
  const results = 'src/agents/tools/tool-results.ts';
  const generated = new Map();
  for (const path of [numbers, strings, records, results]) generated.set(path, sources.get(path).content);
  generated.set(types, region(types, 'enums', 'export const DIFF_LAYOUTS', '\nexport type DiffLayout'));
  generated.set(utils, region(utils, 'clamps', 'export function clampNumber(', '\n/** Alias for clampNumber'));
  generated.set(urlPath, region(urlPath, 'explicit-viewer-url', 'type ViewerBaseUrlFieldName', '\nfunction resolveGatewayBaseUrl('));
  generated.set(config, `import {asFiniteNumber} from '${numbers}';\nimport {asOptionalRecord} from '${records}';\nimport {clampInt,clampNumber} from '${utils}';\nimport {DIFF_IMAGE_QUALITY_PRESETS,DIFF_INDICATORS,DIFF_LAYOUTS,DIFF_MODES,DIFF_OUTPUT_FORMATS,DIFF_THEMES} from '${types}';\nimport {normalizeViewerBaseUrl} from '${urlPath}';\n` +
    region(config, 'default-constants', 'const DEFAULT_IMAGE_QUALITY_PROFILES', '\nconst VIEWER_BASE_URL_JSON_SCHEMA') +
    region(config, 'config-resolvers', 'export function resolveDiffsPluginDefaults(', null));
  generated.set(tool, `import {textResult} from '${results}';\nexport function receipt(params) {\nconst {mode,viewerUrl,viewerDetails,image,artifactFile,rendered,fileBytes,artifactContext}=params;\n` +
    region(tool, 'view-receipt', '      if (mode === "view") {', '\n\n      try {') + '\n' +
    region(tool, 'file-receipt', '        return textResult(\n          [', '\n      } catch (error) {') + '\n}\n');
  const modules = new Map();
  const context = vm.createContext({ URL });
  for (const [path, source] of generated) {
    const executable = stripTypeScriptTypes(source, { mode: 'strip', sourceMap: false });
    modules.set(path, new vm.SourceTextModule(executable, { context, identifier: path }));
  }
  const bindings = [];
  const link = (specifier, importer) => {
    const target = specifier.startsWith('.')
      ? posix.normalize(posix.join(posix.dirname(importer.identifier), specifier)).replace(/\.js$/, '.ts')
      : specifier;
    assert.ok(modules.has(target), `unknown import ${importer.identifier}:${specifier}`);
    bindings.push({ importer: importer.identifier, specifier, target });
    return modules.get(target);
  };
  for (const path of [config, tool]) {
    if (modules.get(path).status === 'unlinked') await modules.get(path).link(link);
    await modules.get(path).evaluate({ timeout: 10000 });
  }
  const configs = [
    { id: 'source-defaults', input: {} },
    { id: 'legacy-aliases', input: { defaults: { imageFormat: 'pdf', imageQuality: 'hq', imageScale: 2.75, imageMaxWidth: 1440 } } },
    { id: 'file-precedence', input: { defaults: { fileFormat: 'png', imageFormat: 'pdf', format: 'pdf', fileQuality: 'print', imageQuality: 'hq', fileScale: 2.25, imageScale: 3, fileMaxWidth: 1500, imageMaxWidth: 1200 } } },
    { id: 'presentation-and-url', input: { defaults: { fontFamily: ' Mono ', fontSize: 17, lineSpacing: 1.75, layout: 'split', theme: 'light', showLineNumbers: false, diffIndicators: 'classic', wordWrap: false, background: false, mode: 'view', ttlSeconds: 1801 }, viewerBaseUrl: ' https://diff.example.test/prefix/// ' } },
  ].map(row => ({ ...row, result: clone({ defaults: modules.get(config).namespace.resolveDiffsPluginDefaults(row.input), security: modules.get(config).namespace.resolveDiffsPluginSecurity(row.input), viewerBaseUrl: modules.get(config).namespace.resolveDiffsPluginViewerBaseUrl(row.input) }) }));
  const viewerPath = '/plugins/diffs/view/0123456789abcdef0123/' + 'a'.repeat(48);
  const urls = [
    { id: 'request-prefix', baseUrl: 'https://request.example.test/base/', viewerBaseUrl: 'https://configured.example.test/other' },
    { id: 'configured-prefix', viewerBaseUrl: 'https://configured.example.test/other/' },
  ].map(row => ({ ...row, viewerPath, result: modules.get(urlPath).namespace.buildViewerUrl({ ...row, viewerPath, config: {} }) }));
  const receipts = ['view', 'file', 'image', 'both'].map(mode => {
    const rendered = { title: 'source diff', inputKind: 'before_after', fileCount: 1 };
    const image = { format: mode === 'file' ? 'pdf' : 'png', qualityPreset: 'standard', scale: 2, maxWidth: 960 };
    const artifactFile = { id: 'f'.repeat(20), expiresAt: '2026-11-08T04:30:01.000Z', filePath: '/source-artifacts/' + 'f'.repeat(20) + '/preview.' + image.format };
    const artifactContext = { agentId: 'agent', sessionId: 'session' };
    const viewerUrl = 'https://diff.example.test' + viewerPath;
    const viewerDetails = { changed: true, artifactId: '0123456789abcdef0123', viewerUrl, viewerPath, ...rendered, expiresAt: '2026-11-08T04:30:00.000Z', mode, context: artifactContext };
    const input = { mode, rendered, image, artifactFile, artifactContext, fileBytes: 12345, ...(mode === 'view' || mode === 'both' ? { viewerUrl, viewerDetails } : {}) };
    return { id: mode, input, result: clone(modules.get(tool).namespace.receipt(input)) };
  });
  return { referenceCommit: DIFFS_REQUEST_PIN, sourceRecords: [...sources.values()].filter(row => [...generated.keys()].includes(row.path)), projections, executables: [...generated].map(([path, generatedSource]) => ({ path, generatedSource, executable: stripTypeScriptTypes(generatedSource, { mode: 'strip', sourceMap: false }), sha256: sha(generatedSource) })), importBindings: bindings, nativeBindings: ['URL=node:URL'], configs, urls, receipts, boundaries: { sourceProjectionsOnly: true, completeFactory: false, renderExecuted: false, storageExecuted: false, gatewayFallbackExecuted: false, failuresExecuted: false }, exporter: { sha256: sha(readFileSync(fileURLToPath(import.meta.url))) } };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const result = await captureDiffsDelivery();
  writeFileSync(process.argv[2], JSON.stringify(result, null, 2) + '\n');
}

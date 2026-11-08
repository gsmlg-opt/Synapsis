// Execute complete, pinned OpenClaw normalization modules with real Rastermill bytes.
// The source loader supplies explicit process/logging facades, not Browser services.
import { readFile, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { createRequire, stripTypeScriptTypes } from 'node:module';
import { dirname, resolve, relative } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { tmpdir } from 'node:os';
import { deflateSync } from 'node:zlib';
import vm from 'node:vm';

export const REFERENCE = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');

// Deterministic valid PNGs keep the oracle independent of browser rendering.
export function makeReferencePng({ width, height, pattern = 'solid', rgba = [12, 34, 56, 255] }) {
  const scan = Buffer.alloc((1 + width * 4) * height);
  let state = 0x12345678;
  for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) {
    const offset = y * (1 + width * 4) + 1 + x * 4;
    if (pattern === 'noise') {
      for (let c = 0; c < 3; c++) {
        state ^= state << 13; state ^= state >>> 17; state ^= state << 5;
        scan[offset + c] = state & 255;
      }
      scan[offset + 3] = 255;
    } else for (let c = 0; c < 4; c++) scan[offset + c] = rgba[c];
  }
  const crc = bytes => {
    let value = 0xffffffff;
    for (const byte of bytes) {
      value ^= byte;
      for (let bit = 0; bit < 8; bit++) value = (value >>> 1) ^ (value & 1 ? 0xedb88320 : 0);
    }
    return (value ^ 0xffffffff) >>> 0;
  };
  const chunk = (type, data) => {
    const name = Buffer.from(type); const result = Buffer.alloc(12 + data.length);
    result.writeUInt32BE(data.length); name.copy(result, 4); data.copy(result, 8);
    result.writeUInt32BE(crc(Buffer.concat([name, data])), 8 + data.length); return result;
  };
  const header = Buffer.alloc(13); header.writeUInt32BE(width); header.writeUInt32BE(height, 4);
  header[8] = 8; header[9] = 6;
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', header),
    chunk('IDAT', deflateSync(scan, { level: 9 })), chunk('IEND', Buffer.alloc(0))]);
}

export async function createReferenceImageOracle(sourceRoot, codecUrl) {
  const source = resolve(sourceRoot);
  const referenceHead = execFileSync('git', ['-C', source, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim();
  if (referenceHead !== REFERENCE) throw new Error(`Expected OpenClaw ${REFERENCE}, got ${referenceHead}`);
  const require = createRequire(resolve(root, 'packages/tool-host/package.json'));
  const codecEntry = codecUrl ?? pathToFileURL(require.resolve('rastermill')).href;
  const codecPackage = JSON.parse(await readFile(resolve(dirname(fileURLToPath(codecEntry)), '../package.json'), 'utf8'));
  if (codecPackage.name !== 'rastermill' || codecPackage.version !== '0.4.0') throw new Error('Reference requires published rastermill0.4.0');
  const rastermill = await import(codecEntry);
  const modules = new Map(); const records = new Map(); const facades = new Map();
  const synthetic = (name, values) => new vm.SyntheticModule(Object.keys(values), function () {
    for (const [key, value] of Object.entries(values)) this.setExport(key, value);
  }, { identifier: `facade:${name}` });
  const provide = (name, values) => { const module = synthetic(name, values); facades.set(name, module); return module; };
  provide('rastermill', rastermill);
  provide('node:crypto', await import('node:crypto'));
  provide('src/infra/resolve-system-bin.ts', { resolveSystemBin: () => null });
  provide('src/infra/tmp-openclaw-dir.ts', { resolvePreferredOpenClawTmpDir: () => tmpdir() });
  provide('src/logging/subsystem.ts', { createSubsystemLogger: () => ({ info() {}, warn() {} }) });

  const load = async name => {
    if (facades.has(name)) return facades.get(name);
    if (modules.has(name)) return modules.get(name);
    const input = await readFile(resolve(source, name));
    const pinned = execFileSync('git', ['-C', source, 'show', `${REFERENCE}:${name}`], { maxBuffer: 8 * 1024 * 1024 });
    if (!input.equals(pinned)) throw new Error(`Changed reference source: ${name}`);
    const executable = stripTypeScriptTypes(input.toString(), { mode: 'strip' });
    records.set(name, { path: name, sha256: sha(input), executableSha256: sha(executable), executed: true });
    const module = new vm.SourceTextModule(executable, { identifier: name });
    modules.set(name, module);
    await module.link(async (specifier, importing) => {
      if (facades.has(specifier)) return facades.get(specifier);
      if (specifier === 'openclaw/plugin-sdk/media-runtime' || specifier.endsWith('/media-services.js')) return load('src/media/image-ops.ts');
      if (specifier === '@openclaw/media-core/base64') return load('packages/media-core/src/base64.ts');
      if (specifier === '@openclaw/normalization-core') return facades.get(specifier);
      if (!specifier.startsWith('.')) throw new Error(`Unconfigured reference import: ${specifier}`);
      return load(relative(source, resolve(source, dirname(importing.identifier), specifier)).replace(/\.js$/, '.ts'));
    });
    return module;
  };
  const evaluate = async name => { const module = await load(name); if (module.status !== 'evaluated') await module.evaluate(); return module.namespace; };
  const config = await evaluate('src/media/image-processor-config.ts');
  provide('src/media/image-processor.ts', {
    createImageProcessor: () => config.createLocalImageProcessor('internal'),
    convertBmpToPngWithWorker: () => { throw new Error('BMP is outside this successful screenshot capture'); },
  });
  const format = await evaluate('packages/normalization-core/src/format.ts');
  const numbers = await evaluate('packages/normalization-core/src/number-coercion.ts');
  provide('@openclaw/normalization-core', { formatByteSize: format.formatByteSize, resolveIntegerOption: numbers.resolveIntegerOption });
  const browser = await evaluate('extensions/browser/src/browser/screenshot.ts');
  const annotation = await evaluate('extensions/browser/src/browser/screenshot-annotate.ts');
  const model = await evaluate('src/agents/tool-images.ts');
  const media = await evaluate('src/media/image-ops.ts');
  for (const name of ['src/media/image-processor.ts', 'src/media/image-processor.worker.ts',
    'src/infra/resolve-system-bin.ts', 'src/infra/tmp-openclaw-dir.ts', 'src/logging/subsystem.ts', 'package.json', 'LICENSE']) {
    const input = await readFile(resolve(source, name));
    const pinned = execFileSync('git', ['-C', source, 'show', `${REFERENCE}:${name}`], { maxBuffer: 8 * 1024 * 1024 });
    if (!input.equals(pinned)) throw new Error(`Changed reference source: ${name}`);
    records.set(name, { path: name, sha256: sha(input), executed: false, role: 'provenance-only; process facade, worker contract, package or license' });
  }
  const describe = async (buffer, mimeType) => ({ bytes: buffer.length, sha256: sha(buffer), mimeType,
    dimensions: await media.getImageMetadata(buffer) });
  return {
    records: () => [...records.values()].sort((a, b) => a.path.localeCompare(b.path)),
    async normalize(input, type = 'png', annotations = []) {
      const saved = await browser.normalizeBrowserScreenshot(input);
      const savedMime = saved.contentType ?? `image/${type}`;
      const savedFacts = await describe(saved.buffer, savedMime);
      const sourceDimensions = saved.sourceDimensions;
      let nextAnnotations = annotations;
      if (saved.buffer !== input && sourceDimensions?.width && sourceDimensions?.height &&
          (savedFacts.dimensions.width !== sourceDimensions.width || savedFacts.dimensions.height !== sourceDimensions.height)) {
        nextAnnotations = annotation.scaleAnnotations(annotations, savedFacts.dimensions.width / sourceDimensions.width,
          savedFacts.dimensions.height / sourceDimensions.height);
      }
      const content = [{ type: 'text', text: 'browser image' }, { type: 'image', data: saved.buffer.toString('base64'), mimeType: savedMime }];
      const result = await model.sanitizeToolResultImages({ content, details: { annotations: nextAnnotations } }, 'browser');
      if (result.content.length !== 2 || result.content[1].type !== 'image') throw new Error('Positive reference image was omitted');
      const inline = result.content[1];
      return { input: await describe(input, `image/${type}`), saved: savedFacts,
        inline: await describe(Buffer.from(inline.data, 'base64'), inline.mimeType), annotations: nextAnnotations,
        detailsPreserved: result.details.annotations === nextAnnotations };
    },
  };
}

async function main() {
  const args = process.argv.slice(2); const option = name => { const index = args.indexOf(name); return index < 0 ? undefined : args[index + 1]; };
  const source = option('--source'); const output = option('--output');
  if (!source || !output) throw new Error('Use --source PINNED_CHECKOUT --output FILE [--codec-url URL] with --experimental-vm-modules');
  const oracle = await createReferenceImageOracle(source, option('--codec-url'));
  const annotations = [{ ref: 'e1', number: 1, role: 'button', name: 'Fixture', box: { x: 121, y: 91, width: 97, height: 49 } }];
  const recipes = [
    { name: 'small-png', width: 320, height: 180 },
    { name: 'model-only-resize', width: 1500, height: 600 },
    { name: 'wide-two-stages', width: 2400, height: 900 },
    { name: 'tall-two-stages', width: 900, height: 2400 },
    { name: 'rounded-model-height', width: 1601, height: 903 },
    { name: 'byte-trigger-noise', width: 1400, height: 1400, pattern: 'noise' },
  ];
  const vectors = [];
  for (const { name, ...recipe } of recipes) vectors.push({ name, recipe, inputAnnotations: annotations,
    expected: await oracle.normalize(makeReferencePng(recipe), 'png', annotations) });
  const result = { referenceCommit: REFERENCE, scriptSha256: sha(await readFile(fileURLToPath(import.meta.url))),
    rastermillVersion: '0.4.0', sourceRecords: oracle.records(),
    boundaries: ['Complete pinned TypeScript modules, stripped types only; all loaded source bytes checked against git pin.',
      'Image-processor worker orchestration facade uses actual pinned createLocalImageProcessor(internal) and real Rastermill0.4.0/Photon codecs.',
      'Logging and system-command/temp resolvers are explicit facades; no external codec fallback, Browser route registration, storage, provider or full plugin assembly executed.',
      'Vectors prove normalization algorithms and annotation arithmetic, not route integration or full invalid-image/replay sanitization.'], vectors };
  await writeFile(output, JSON.stringify(result, null, 2) + '\n');
  process.stdout.write(JSON.stringify({ output, vectors: vectors.length, sources: result.sourceRecords.length }) + '\n');
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) await main();

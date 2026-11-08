import { parentPort } from 'node:worker_threads';
import { renderDiffDocument } from './packages/tool-host/src/diffs/openclaw/extensions/diffs/src/render.js';

// Highlighting and patch parsing stay off the control thread. No filesystem
// paths are taken from display labels in the prepared request.
parentPort.on('message', async ({ id, plan }) => {
  try {
    if (!plan || !['viewer', 'image', 'both'].includes(plan.renderTarget) ||
        plan.options?.languagePackAvailable !== false ||
        !['before_after', 'patch'].includes(plan.input?.kind)) throw new Error();
    const document = await renderDiffDocument(plan.input, plan.options, plan.renderTarget);
    for (const key of ['html', 'imageHtml']) {
      if (document[key] !== undefined && Buffer.byteLength(document[key]) > 32 * 1024 * 1024) throw new Error();
    }
    parentPort.postMessage({ id, document });
  } catch {
    parentPort.postMessage({ id, error: 'render_failed' });
  }
});
parentPort.postMessage({ type: 'ready' });

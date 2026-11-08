import { createRastermill, readImageProbeFromHeader } from 'rastermill';
import photon from '@silvia-odwyer/photon-node';

const MAX_IMAGE_PIXELS = 25_000_000;

// Called inside the existing owned filesystem worker. Internal processing never
// starts a native child; native-only fallback remains a full-read prerequisite.
export function createImageProcessor() {
  return createRastermill({
    execution: 'internal',
    limits: { inputPixels: MAX_IMAGE_PIXELS, outputPixels: MAX_IMAGE_PIXELS },
  });
}

// Adapted from pinned OpenClaw image-ops.ts and photon.runtime.ts. Keep the
// explicit BMP fallback, its header/pixel gate, and actual WASM image lifetime.
export async function convertImageToPng(buffer) {
  try {
    return (await createImageProcessor().encode(buffer, { format: 'png' })).data;
  } catch (error) {
    const probe = readImageProbeFromHeader(buffer);
    if (!probe || probe.format !== 'bmp' || probe.width <= 0 || probe.height <= 0 ||
        probe.width > MAX_IMAGE_PIXELS / probe.height) throw error;

    let image;
    try {
      image = photon.PhotonImage.new_from_byteslice(buffer);
      return Buffer.from(image.get_bytes());
    } catch {
      throw error;
    } finally {
      image?.free();
    }
  }
}

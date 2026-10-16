import { BadRequestException } from '@nestjs/common';

export interface ImageProbe {
  mimeType: string;
  ext: string;
  width: number;
  height: number;
}

export const ALLOWED_IMAGE_MIME = new Set([
  'image/png',
  'image/jpeg',
  'image/webp',
  'image/gif',
]);

const EXT_FOR_MIME: Record<string, string> = {
  'image/png': 'png',
  'image/jpeg': 'jpg',
  'image/webp': 'webp',
  'image/gif': 'gif',
};

const MIN_DIM = 16;
const MAX_DIM = 4096;

function u16be(b: Buffer, offset: number): number {
  return b.readUInt16BE(offset);
}
function u32be(b: Buffer, offset: number): number {
  return b.readUInt32BE(offset);
}

function looksPng(b: Buffer): boolean {
  return (
    b.length >= 24 &&
    b[0] === 0x89 &&
    b[1] === 0x50 &&
    b[2] === 0x4e &&
    b[3] === 0x47 &&
    b[4] === 0x0d &&
    b[5] === 0x0a &&
    b[6] === 0x1a &&
    b[7] === 0x0a &&
    b.toString('ascii', 12, 16) === 'IHDR'
  );
}

function looksJpeg(b: Buffer): boolean {
  return b.length >= 4 && b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff;
}

function looksGif(b: Buffer): boolean {
  const sig = b.toString('ascii', 0, 6);
  return b.length >= 10 && (sig === 'GIF87a' || sig === 'GIF89a');
}

function looksWebp(b: Buffer): boolean {
  return (
    b.length >= 12 &&
    b.toString('ascii', 0, 4) === 'RIFF' &&
    b.toString('ascii', 8, 12) === 'WEBP'
  );
}

function jpegDimensions(b: Buffer): { width: number; height: number } | null {
  let offset = 2;
  while (offset + 9 < b.length) {
    if (b[offset] !== 0xff) {
      offset += 1;
      continue;
    }
    const marker = b[offset + 1];
    // SOF0..SOF15 except DHT/JPG/DAC carry the frame size.
    if (marker >= 0xc0 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc) {
      const height = u16be(b, offset + 5);
      const width = u16be(b, offset + 7);
      return width > 0 && height > 0 ? { width, height } : null;
    }
    if (marker === 0xd8 || marker === 0xd9) {
      offset += 2;
      continue;
    }
    const segmentLen = u16be(b, offset + 2);
    if (segmentLen < 2) return null;
    offset += 2 + segmentLen;
  }
  return null;
}

function webpDimensions(b: Buffer): { width: number; height: number } | null {
  const chunk = b.toString('ascii', 12, 16);
  if (chunk === 'VP8X' && b.length >= 30) {
    const width = 1 + (b[24] | (b[25] << 8) | (b[26] << 16));
    const height = 1 + (b[27] | (b[28] << 8) | (b[29] << 16));
    return { width, height };
  }
  if (chunk === 'VP8L' && b.length >= 25 && b[20] === 0x2f) {
    const bits = b.readUInt32LE(21);
    const width = (bits & 0x3fff) + 1;
    const height = ((bits >> 14) & 0x3fff) + 1;
    return { width, height };
  }
  if (chunk === 'VP8 ' && b.length >= 30) {
    // Key-frame header: 3-byte frame tag, 3-byte sync code, then 16-bit dims.
    const width = u16be(b, 26) & 0x3fff;
    const height = u16be(b, 28) & 0x3fff;
    return width > 0 && height > 0 ? { width, height } : null;
  }
  return null;
}

/**
 * Sniffs the real image type from file signatures (never trusts the
 * client-supplied MIME or filename) and extracts dimensions from the
 * image header. Returns null for anything that is not a supported image.
 */
export function detectImage(buffer: Buffer): ImageProbe | null {
  let mimeType: string;
  let dims: { width: number; height: number } | null;

  if (looksPng(buffer)) {
    mimeType = 'image/png';
    dims = { width: u32be(buffer, 16), height: u32be(buffer, 20) };
  } else if (looksJpeg(buffer)) {
    mimeType = 'image/jpeg';
    dims = jpegDimensions(buffer);
  } else if (looksGif(buffer)) {
    mimeType = 'image/gif';
    dims = { width: u16le(buffer, 6), height: u16le(buffer, 8) };
  } else if (looksWebp(buffer)) {
    mimeType = 'image/webp';
    dims = webpDimensions(buffer);
  } else {
    return null;
  }

  if (!dims || dims.width <= 0 || dims.height <= 0) return null;
  return { mimeType, ext: EXT_FOR_MIME[mimeType], width: dims.width, height: dims.height };
}

function u16le(b: Buffer, offset: number): number {
  return b.readUInt16LE(offset);
}

/**
 * Full upload gate: size, signature, dimensions. Throws a 400 with a
 * human-readable reason the admin UI shows next to the file field.
 */
export function validateImageUpload(
  buffer: Buffer | undefined,
  maxBytes: number,
): ImageProbe {
  if (!buffer || buffer.length === 0) {
    throw new BadRequestException('A file is required');
  }
  if (buffer.length > maxBytes) {
    const mb = (maxBytes / (1024 * 1024)).toFixed(1);
    throw new BadRequestException(`File exceeds the ${mb} MB upload limit`);
  }
  const probe = detectImage(buffer);
  if (!probe) {
    throw new BadRequestException(
      'Unsupported or malformed image — accepted: PNG, JPEG, WebP, GIF',
    );
  }
  if (probe.width < MIN_DIM || probe.height < MIN_DIM) {
    throw new BadRequestException(
      `Image too small (${probe.width}×${probe.height}) — minimum ${MIN_DIM}×${MIN_DIM}`,
    );
  }
  if (probe.width > MAX_DIM || probe.height > MAX_DIM) {
    throw new BadRequestException(
      `Image too large (${probe.width}×${probe.height}) — maximum ${MAX_DIM}×${MAX_DIM}`,
    );
  }
  return probe;
}

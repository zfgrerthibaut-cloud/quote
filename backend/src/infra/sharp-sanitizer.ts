import sharp from 'sharp';

import { MAX_IMAGE_BYTES, type DecodedMedia } from '../domain/media.ts';

const MAX_DIMENSION = 4096;
const LOGO_BOUNDING_BOX = 256;

export async function sanitizeImageWithSharp(input: DecodedMedia): Promise<DecodedMedia> {
  const pipeline = sharp(Buffer.from(input.bytes), {
    failOn: 'error',
    limitInputPixels: MAX_DIMENSION * MAX_DIMENSION,
    pages: 1,
    sequentialRead: true,
  })
    .rotate()
    .resize({
      width: LOGO_BOUNDING_BOX,
      height: LOGO_BOUNDING_BOX,
      fit: 'inside',
      withoutEnlargement: true,
    })
    .png({
      compressionLevel: 9,
      adaptiveFiltering: true,
    });

  const { data, info } = await pipeline.toBuffer({ resolveWithObject: true });
  if (data.byteLength < 1 || data.byteLength > MAX_IMAGE_BYTES) {
    throw new Error('sanitized_media_size');
  }
  if (info.width < 1 || info.height < 1 || info.width > LOGO_BOUNDING_BOX || info.height > LOGO_BOUNDING_BOX) {
    throw new Error('sanitized_media_dimensions');
  }

  return {
    bytes: new Uint8Array(data),
    mime: 'image/png',
    width: info.width,
    height: info.height,
  };
}

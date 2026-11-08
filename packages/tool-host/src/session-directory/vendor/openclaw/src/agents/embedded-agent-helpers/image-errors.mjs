const IMAGE_DIMENSION_ERROR_RE =
  /image dimensions exceed max allowed size for many-image requests:\s*(\d+)\s*pixels/i;
const IMAGE_DIMENSION_PATH_RE = /messages\.(\d+)\.content\.(\d+)\.image/i;
const IMAGE_SIZE_ERROR_RE = /image exceeds\s*(\d+(?:\.\d+)?)\s*mb/i;
export function parseImageDimensionError(raw        )   
                          
                        
                        
         {
  if (!/image dimensions exceed max allowed size/i.test(raw)) {
    return null;
  }
  const limitMatch = raw.match(IMAGE_DIMENSION_ERROR_RE);
  const pathMatch = raw.match(IMAGE_DIMENSION_PATH_RE);
  return {
    maxDimensionPx: limitMatch?.[1] ? Number.parseInt(limitMatch[1], 10) : undefined,
    messageIndex: pathMatch?.[1] ? Number.parseInt(pathMatch[1], 10) : undefined,
    contentIndex: pathMatch?.[2] ? Number.parseInt(pathMatch[2], 10) : undefined,
  };
}
export function isImageDimensionErrorMessage(raw        )          {
  return Boolean(parseImageDimensionError(raw));
}
export function parseImageSizeError(raw        )   
                 
         {
  if (!/image exceeds[\s\S]*mb/i.test(raw)) {
    return null;
  }
  const match = raw.match(IMAGE_SIZE_ERROR_RE);
  return {
    maxMb: match?.[1] ? Number.parseFloat(match[1]) : undefined,
  };
}
export function isImageSizeError(errorMessage         )          {
  return Boolean(errorMessage && parseImageSizeError(errorMessage));
}
export { IMAGE_DIMENSION_ERROR_RE, IMAGE_DIMENSION_PATH_RE, IMAGE_SIZE_ERROR_RE };
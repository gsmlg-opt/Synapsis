import { fileURLToPath, URL } from "node:url";
const ENCODED_FILE_URL_SEPARATOR_RE = /%(?:2f|5c)/i;
export function hasEncodedFileUrlSeparator(pathname) {
    return ENCODED_FILE_URL_SEPARATOR_RE.test(pathname);
}
export function isWindowsNetworkPath(filePath, platform = process.platform) {
    if (platform !== "win32") {
        return false;
    }
    return isWindowsSeparator(filePath, 0) && isWindowsSeparator(filePath, 1) &&
        !(windowsNamespaceMarker(filePath) === "?" && rootedWindowsDriveColonIndex(filePath) === 5);
}
export function safeFileURLToPath(fileUrl, platform = process.platform) {
    let parsed;
    try {
        parsed = new URL(fileUrl);
    }
    catch {
        throw new Error(`Invalid file:// URL: ${fileUrl}`);
    }
    if (parsed.protocol !== "file:") {
        throw new Error(`Invalid file:// URL: ${fileUrl}`);
    }
    const normalizedHost = normalizeLowercaseStringOrEmpty(parsed.hostname);
    if (!(normalizedHost === "" || normalizedHost === "localhost")) {
        throw new Error(`file:// URLs with remote hosts are not allowed: ${fileUrl}`);
    }
    if (hasEncodedFileUrlSeparator(parsed.pathname)) {
        throw new Error(`file:// URLs cannot encode path separators: ${fileUrl}`);
    }
    const filePath = fileURLToPath(parsed, { windows: platform === "win32" });
    if (hasWindowsPathAlias(filePath, "filesystem", platform)) {
        throw new Error(`Local file URL cannot use Windows filesystem namespace aliases: ${filePath}`);
    }
    if (isWindowsNetworkPath(filePath, platform)) {
        throw new Error(`Local file URL cannot use Windows network paths: ${filePath}`);
    }
    return filePath;
}
export function normalizeNullableString(value) {
    if (typeof value !== "string") {
        return null;
    }
    const trimmed = value.trim();
    return trimmed ? trimmed : null;
}
export function normalizeOptionalString(value) {
    return normalizeNullableString(value) ?? undefined;
}
export function normalizeOptionalLowercaseString(value) {
    return normalizeOptionalString(value)?.toLowerCase();
}
export function normalizeLowercaseStringOrEmpty(value) {
    return normalizeOptionalLowercaseString(value) ?? "";
}
export function hasWindowsPathAlias(value, kind, platform = process.platform) {
    if (platform !== "win32")
        return false;
    const firstColon = value.indexOf(":");
    if (firstColon === -1)
        return false;
    if (kind === "relative")
        return true;
    return firstColon !== rootedWindowsDriveColonIndex(value) || value.indexOf(":", firstColon + 1) !== -1;
}
export function isWindowsSeparator(value, offset) {
    const code = value.charCodeAt(offset);
    return code === 0x2f || code === 0x5c;
}
export function hasWindowsDrivePrefix(value, offset = 0) {
    const letter = value.charCodeAt(offset) | 0x20;
    return letter >= 0x61 && letter <= 0x7a && value.charCodeAt(offset + 1) === 0x3a;
}
export function windowsNamespaceMarker(value) {
    const marker = value[2];
    return (marker === "." || marker === "?") &&
        isWindowsSeparator(value, 0) && isWindowsSeparator(value, 1) &&
        isWindowsSeparator(value, 3) ? marker : undefined;
}
export function rootedWindowsDriveColonIndex(value) {
    const colon = hasWindowsDrivePrefix(value)
        ? 1
        : windowsNamespaceMarker(value) !== undefined && hasWindowsDrivePrefix(value, 4) ? 5 : -1;
    return colon >= 0 && isWindowsSeparator(value, colon + 1) ? colon : -1;
}

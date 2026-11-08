import { AWS_SECRET_ACCESS_KEY_MATCHER } from "./redact-patterns.mjs";
import { FORM_BODY_KEY_INVISIBLE_CHARS } from "./redact-patterns.mjs";
const FIELD_KEY_PREFILTER_RE =
  /KEY|TOKEN|SECRET|PASSWORD|PASSWD|AUTH|COOKIE|SIGNATURE|CREDENTIAL|CARD|CVC|CVV|PAYMENT|security[-_]?code|\bpass\s*[=:]|\bpassphrase\s*[=:]|_(?:password|pass|passphrase|passwd)\s*[=:]|jwt\s*[=:]|session=|code=|\bsig\s*=/iu;
const SEPARATED_VENDOR_PREFILTER_RE =
  /sk-|gh[opsur]_|github_pat_|glpat-|gloas-|gldt-|glcbt-|glptt-|glft-|glimt-|glagent-|glwt-|glsoat-|glffct-|glrt-|glrtr-|_gitlab_session=|xox[baprs]-|xapp-|gsk_|pplx-|fal_|fc-|bb_live_|[sr]k_(?:live|test)_|npm_|pypi-|do[opr]_v1_|dckr_|bkua_|CCIPAT_|sbp_|dd[pw]_|glsa_|nfp_|CFPAT-|BBDC-|HRKU-|pat-(?:eu|na)1-|apify_api_|fio-u-|tvly-|exa_|syt_|retaindb_|mem0_|brv_|xai-|fw-|fw_|fpk_|(?:^|[^A-Za-z0-9_])(?:am_|sk_)|hf_|api_org_|r8_/iu;
const DEFAULT_REDACT_PREFILTER_RE =
  /PRIVATE KEY|\bBearer\s+|GR1348941|hooks\.slack\.com|discord|AIza|ya29\.|1\/\/0|eyJ|gAAAA|SG\.|dp\.(?:ct|pt|sa|st|scim|audit)\.|dapi[0-9a-f]|ATCTT3|ATATT|ATBB|FlyV1|A[KS]IA[A-Z0-9]|AKID|LTAI|\bbot\d{6,}:|\b\d{6,}:[A-Za-z0-9_-]{20,}/iu;
const OBFUSCATED_KEY_CHAR_RE = new RegExp(`[${FORM_BODY_KEY_INVISIBLE_CHARS}+%]`, "u");
const FULL_CONTEXT_REDACT_EXTRA_TRIGGERS_RE =
  /JWT|Bearer\s+|am_|sk_|(?<!\d)\d{6,}:[A-Za-z0-9_-]{20,}/i;
export function couldMatchDefaultRedactPatterns(text        )          {
  return (
    FIELD_KEY_PREFILTER_RE.test(text) ||
    ((text.includes("-") || text.includes("_")) && SEPARATED_VENDOR_PREFILTER_RE.test(text)) ||
    DEFAULT_REDACT_PREFILTER_RE.test(text) ||
    (text.includes("://") && text.includes("@")) ||
    (text.includes("=") && OBFUSCATED_KEY_CHAR_RE.test(text)) ||
    AWS_SECRET_ACCESS_KEY_MATCHER.couldMatch(text)
  );
}
export function couldMatchVendorRedactPatterns(text        )          {
  return (
    ((text.includes("-") || text.includes("_")) && SEPARATED_VENDOR_PREFILTER_RE.test(text)) ||
    DEFAULT_REDACT_PREFILTER_RE.test(text) ||
    FULL_CONTEXT_REDACT_EXTRA_TRIGGERS_RE.test(text)
  );
}
export { FIELD_KEY_PREFILTER_RE, SEPARATED_VENDOR_PREFILTER_RE, DEFAULT_REDACT_PREFILTER_RE, OBFUSCATED_KEY_CHAR_RE, FULL_CONTEXT_REDACT_EXTRA_TRIGGERS_RE };
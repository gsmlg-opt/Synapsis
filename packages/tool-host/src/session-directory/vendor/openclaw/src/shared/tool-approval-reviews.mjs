import { asNullableRecord } from "../../packages/normalization-core/src/record-coerce.mjs";
import { truncateUtf16Safe } from "../../packages/normalization-core/src/utf16-slice.mjs";
const REVIEW_STATUSES = new Set        ([
  "in_progress",
  "approved",
  "denied",
  "timed_out",
  "aborted",
]);
export const MAX_TOOL_APPROVAL_REVIEWS = 16;
function boundedString(value         , maxChars        )                     {
  const text = typeof value === "string" ? value.trim() : "";
  return text ? truncateUtf16Safe(text, maxChars) : undefined;
}
function isReviewStatus(value                    )                                        {
  return value !== undefined && REVIEW_STATUSES.has(value);
}
export function normalizeToolApprovalReview(value         )                            {
  const review = asNullableRecord(value);
  const id = boundedString(review?.id, 256);
  const label = boundedString(review?.label, 80);
  const status = boundedString(review?.status, 32);
  if (!id || !label || !isReviewStatus(status)) {
    return null;
  }
  const riskLevel = boundedString(review?.riskLevel, 40);
  const userAuthorization = boundedString(review?.userAuthorization, 40);
  const rationale = boundedString(review?.rationale, 2_000);
  return {
    id,
    label,
    status,
    ...(riskLevel ? { riskLevel } : {}),
    ...(userAuthorization ? { userAuthorization } : {}),
    ...(rationale ? { rationale } : {}),
  };
}
export { REVIEW_STATUSES, boundedString, isReviewStatus };
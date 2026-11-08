const PLAN_PROGRESS_TOOL_NAMES = new Set(["progress_card", "update_plan"]);
export function isAgentPlanProgressToolName(name                    )          {
  return PLAN_PROGRESS_TOOL_NAMES.has(name?.trim().toLowerCase() ?? "");
}
export { PLAN_PROGRESS_TOOL_NAMES };
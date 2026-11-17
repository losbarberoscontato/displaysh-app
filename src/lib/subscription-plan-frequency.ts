export type FixedSchedulePattern =
  | "CYCLE_1"
  | "CYCLE_2"
  | "WEEKLY_1"
  | "WEEKLY_2"
  | "WEEKLY_3"
  | "WEEKDAYS"
  | "MON_SAT";

export const FIXED_SCHEDULE_PATTERNS: Array<{
  value: FixedSchedulePattern;
  sessions: number;
  label: string;
  detail: string;
  monthlyOnly?: boolean;
}> = [
  { value: "CYCLE_1", sessions: 1, label: "Uma sessão por ciclo (1)", detail: "Repete uma vez por ciclo, no dia e horário escolhidos." },
  { value: "CYCLE_2", sessions: 2, label: "Duas sessões por ciclo (2)", detail: "Repete duas vezes por ciclo, nos dias e horários escolhidos." },
  { value: "WEEKLY_1", sessions: 4, label: "Uma sessão por semana (4)", detail: "Repete uma vez por semana. Ocorrências da quinta semana entram no mesmo preço.", monthlyOnly: true },
  { value: "WEEKLY_2", sessions: 8, label: "Duas sessões por semana (8)", detail: "Repete duas vezes por semana. Ocorrências da quinta semana entram no mesmo preço.", monthlyOnly: true },
  { value: "WEEKLY_3", sessions: 12, label: "Três sessões por semana (12)", detail: "Repete três vezes por semana. Ocorrências da quinta semana entram no mesmo preço.", monthlyOnly: true },
  { value: "WEEKDAYS", sessions: 20, label: "De segunda a sexta (20)", detail: "Repete de segunda a sexta. Meses com uma semana extra entram no mesmo preço.", monthlyOnly: true },
  { value: "MON_SAT", sessions: 24, label: "De segunda a sábado (24)", detail: "Repete de segunda a sábado. Meses com uma semana extra entram no mesmo preço.", monthlyOnly: true },
];

export function fixedSchedulePattern(value: unknown) {
  return FIXED_SCHEDULE_PATTERNS.find((item) => item.value === value) ?? null;
}

export function fixedSchedulePatternLabel(value: unknown) {
  return fixedSchedulePattern(value)?.label ?? "Frequência fixa";
}

function parseDateParts(value: string) {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/u.exec(value);
  if (!match) return null;
  return { year: Number(match[1]), month: Number(match[2]), day: Number(match[3]) };
}

export function addCalendarDays(value: string, days: number) {
  const parts = parseDateParts(value);
  if (!parts) return value;
  const date = new Date(Date.UTC(parts.year, parts.month - 1, parts.day + days));
  return `${date.getUTCFullYear()}-${String(date.getUTCMonth() + 1).padStart(2, "0")}-${String(date.getUTCDate()).padStart(2, "0")}`;
}

export function firstBillingCycleEndDate(value: string, billingPeriod: "MONTHLY" | "BIWEEKLY") {
  if (billingPeriod === "BIWEEKLY") return addCalendarDays(value, 14);
  const parts = parseDateParts(value);
  if (!parts) return value;
  const nextMonthLastDay = new Date(Date.UTC(parts.year, parts.month + 1, 0)).getUTCDate();
  const nextMonth = new Date(Date.UTC(parts.year, parts.month, Math.min(parts.day, nextMonthLastDay)));
  const nextMonthValue = `${nextMonth.getUTCFullYear()}-${String(nextMonth.getUTCMonth() + 1).padStart(2, "0")}-${String(nextMonth.getUTCDate()).padStart(2, "0")}`;
  return addCalendarDays(nextMonthValue, -1);
}

export function billingCycleDayCount(value: string, billingPeriod: "MONTHLY" | "BIWEEKLY") {
  const end = firstBillingCycleEndDate(value, billingPeriod);
  const startParts = parseDateParts(value);
  const endParts = parseDateParts(end);
  if (!startParts || !endParts) return billingPeriod === "BIWEEKLY" ? 15 : 31;
  const start = Date.UTC(startParts.year, startParts.month - 1, startParts.day);
  const finish = Date.UTC(endParts.year, endParts.month - 1, endParts.day);
  return Math.max(1, Math.round((finish - start) / 86_400_000) + 1);
}

export function dateForBillingCycleOffset(value: string, offset: number, billingPeriod: "MONTHLY" | "BIWEEKLY") {
  const maxOffset = billingCycleDayCount(value, billingPeriod) - 1;
  return addCalendarDays(value, Math.min(Math.max(0, offset), maxOffset));
}

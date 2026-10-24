/**
 * Recurrence rules from providers, reduced to what the apps compute (`Recurrence.swift` and
 * the web): `FREQ=DAILY|WEEKLY|MONTHLY|YEARLY`, `INTERVAL`, `BYDAY` (weekly, plain day codes),
 * `COUNT` and `UNTIL` (a day). Each next occurrence is computed from the task's due day, so a
 * part that only restates the due day (`BYMONTHDAY=20` on the 20th) is dropped, and anything
 * that picks other days (`BYDAY=2MO`, `BYSETPOS`, several `BYMONTHDAY`s) makes the rule
 * inexpressible: the caller keeps it as text or expands its occurrences.
 */

const FREQUENCIES = new Set(["DAILY", "WEEKLY", "MONTHLY", "YEARLY"]);
const DAY_CODES = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"] as const;

/** "MO" for a local day "2026-10-19". */
export function weekdayCode(day: string): string {
  return DAY_CODES[new Date(`${day}T12:00:00Z`).getUTCDay()]!;
}

/** "20261231" from "20261231T235959Z", "20261231" or "2026-12-31"; null otherwise. */
function untilDay(value: string): string | null {
  const m = value.replace(/-/g, "").match(/^(\d{8})(T\d{6}Z?)?$/);
  return m ? m[1]! : null;
}

/**
 * The rule as Zimam stores it, or null when Zimam cannot repeat it on the same days.
 * `dueDate` is the occurrence the task is due on ("2026-10-20").
 */
export function zimamRule(input: string, dueDate: string): string | null {
  const text = input.trim().replace(/^RRULE:/i, "");
  if (!text) return null;
  const parts = new Map<string, string>();
  for (const part of text.split(";")) {
    const [key, value, ...rest] = part.split("=");
    if (!key || value === undefined || rest.length) return null;
    parts.set(key.trim().toUpperCase(), value.trim().toUpperCase());
  }
  const freq = parts.get("FREQ");
  if (!freq || !FREQUENCIES.has(freq)) return null;
  const [, month, day] = dueDate.split("-").map(Number) as [number, number, number];
  const out = [`FREQ=${freq}`];
  for (const [key, value] of parts) {
    switch (key) {
      case "FREQ":
      case "WKST":
        break;
      case "INTERVAL": {
        const n = Number(value);
        if (!Number.isInteger(n) || n < 1) return null;
        if (n > 1) out.push(`INTERVAL=${n}`);
        break;
      }
      case "BYDAY": {
        const days = value.split(",");
        if (freq !== "WEEKLY" || !days.every((d) => (DAY_CODES as readonly string[]).includes(d))) return null;
        const sorted = DAY_CODES.filter((d) => days.includes(d));
        // One day that is the due day's adds nothing.
        if (!(sorted.length === 1 && sorted[0] === weekdayCode(dueDate))) out.push(`BYDAY=${sorted.join(",")}`);
        break;
      }
      case "BYMONTHDAY":
        if ((freq !== "MONTHLY" && freq !== "YEARLY") || Number(value) !== day) return null;
        break;
      case "BYMONTH":
        if (freq !== "YEARLY" || Number(value) !== month) return null;
        break;
      case "COUNT": {
        const n = Number(value);
        if (!Number.isInteger(n) || n < 1) return null;
        out.push(`COUNT=${n}`);
        break;
      }
      case "UNTIL": {
        const until = untilDay(value);
        if (!until) return null;
        out.push(`UNTIL=${until}`);
        break;
      }
      default:
        // A provider's own extension (TickTick's TT_SKIP=HOLIDAY, X-…) changes no day Zimam computes.
        if (key.startsWith("TT_") || key.startsWith("X-")) break;
        // BYSETPOS, BYYEARDAY, BYWEEKNO, BYHOUR...: other days or several a day.
        return null;
    }
  }
  return out.join(";");
}

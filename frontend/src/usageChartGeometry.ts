export type ChartGranularity = "15min" | "hourly" | "6hour" | "daily";

export function bucketMilliseconds(granularity: ChartGranularity) {
  switch (granularity) {
  case "15min": return 15 * 60 * 1_000;
  case "hourly": return 60 * 60 * 1_000;
  case "6hour": return 6 * 60 * 60 * 1_000;
  case "daily": return 24 * 60 * 60 * 1_000;
  }
}

export function alignedBucketStart(timestamp: string, granularity: ChartGranularity) {
  const date = new Date(timestamp);
  if (granularity === "15min") date.setMinutes(Math.floor(date.getMinutes() / 15) * 15, 0, 0);
  else if (granularity === "hourly") date.setMinutes(0, 0, 0);
  else if (granularity === "6hour") date.setHours(Math.floor(date.getHours() / 6) * 6, 0, 0, 0);
  else date.setHours(0, 0, 0, 0);
  return date;
}

export function nextBucket(date: Date, granularity: ChartGranularity) {
  const next = new Date(date);
  if (granularity === "daily") next.setDate(next.getDate() + 1);
  else next.setTime(next.getTime() + bucketMilliseconds(granularity));
  return next;
}

export function chartDateLabel(timestamp: string, granularity: ChartGranularity) {
  const date = new Date(timestamp);
  return {
    date: date.toLocaleDateString([], { month: "short", day: "numeric" }),
    time: granularity === "daily" ? undefined : date.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" }),
  };
}

export function niceChartMaximum(value: number) {
  if (value <= 0) return 1;
  const magnitude = 10 ** Math.floor(Math.log10(value));
  const normalized = value / magnitude;
  return (normalized <= 1 ? 1 : normalized <= 2 ? 2 : normalized <= 5 ? 5 : 10) * magnitude;
}

export function axisCurrency(value: number, step: number) {
  const fractionDigits = step >= 1 ? 2 : Math.min(6, Math.max(2, Math.ceil(-Math.log10(step)) + 1));
  return new Intl.NumberFormat("en-US", {
    style: "currency",
    currency: "USD",
    maximumFractionDigits: fractionDigits,
  }).format(value);
}

export function clippedInterval(startAt: string, endAt: string, domainStart: number, domainEnd: number) {
  const start = Math.max(new Date(startAt).getTime(), domainStart);
  const end = Math.min(new Date(endAt).getTime(), domainEnd);
  if (!Number.isFinite(start) || !Number.isFinite(end) || start >= end) return undefined;
  return { startAt: new Date(start).toISOString(), endAt: new Date(end).toISOString() };
}

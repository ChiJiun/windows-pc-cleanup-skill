// 共用的格式化與資料整理小工具。

/** 位元組轉成好讀的大小（1024 進位）。不是有效數字時回傳「—」。 */
export function formatBytes(n: number | null | undefined): string {
  if (typeof n !== "number" || !Number.isFinite(n)) return "—";
  if (n < 0) return "-" + formatBytes(-n);
  const units = ["B", "KB", "MB", "GB", "TB"];
  let v = n;
  let i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return i === 0 ? `${v} B` : `${v.toFixed(v >= 100 ? 0 : 1)} ${units[i]}`;
}

/** invoke 失敗時錯誤通常是字串；其他型別也盡量轉成可讀文字。 */
export function errorText(e: unknown): string {
  if (typeof e === "string") return e;
  if (e instanceof Error) return e.message;
  try {
    return JSON.stringify(e);
  } catch {
    return String(e);
  }
}

/**
 * PowerShell 的 ConvertTo-Json 會把單一元素的陣列變成純量、空陣列變成 null，
 * 這裡統一轉回陣列，避免畫面因為型別不符而當掉。
 */
export function asArray<T>(x: unknown): T[] {
  if (Array.isArray(x)) return x as T[];
  if (x === null || x === undefined || x === "") return [];
  return [x as T];
}

export function isObject(x: unknown): x is Record<string, unknown> {
  return typeof x === "object" && x !== null && !Array.isArray(x);
}

export function basename(p: string): string {
  const parts = p.split(/[\\/]/).filter(Boolean);
  return parts.length ? parts[parts.length - 1] : p;
}

export function dirname(p: string): string {
  const i = Math.max(p.lastIndexOf("\\"), p.lastIndexOf("/"));
  return i > 0 ? p.slice(0, i) : p;
}

export function truncate(s: string, max: number): { text: string; truncated: boolean } {
  if (s.length <= max) return { text: s, truncated: false };
  return { text: s.slice(0, max), truncated: true };
}

export function formatSeconds(ms: number): string {
  return `${Math.max(0, Math.round(ms / 1000))}s`;
}

// 前端元件統一從這裡取得 api。正式建置時就是 api.ts 的 api，原封不動。
// 只有在開發模式（pnpm dev）而且不在 Tauri 視窗裡時，才換成 src/dev/mockApi.ts 的假資料，方便在瀏覽器看外觀。
// import.meta.env.DEV 在正式建置時是常數 false，整段（含動態 import）會被移除，假資料不會進入正式建置。
import { api as realApi } from "./api";

export type Api = typeof realApi;

let current: Api = realApi;
let usingMock = false;

export async function initBackend(): Promise<void> {
  if (import.meta.env.DEV && !("__TAURI_INTERNALS__" in window)) {
    const mod = await import("./dev/mockApi");
    current = mod.mockApi;
    usingMock = true;
  }
}

export function isUsingMock(): boolean {
  return usingMock;
}

export const api: Api = new Proxy(realApi, {
  get(_target, key) {
    return (current as Record<string | symbol, unknown>)[key];
  },
}) as Api;

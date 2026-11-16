"use client";

import { useSyncExternalStore } from "react";

/** Ajustes que o perfil traz (meu_perfil → configuracoes), para as telas decidirem o que mostrar. */
let flags: Record<string, unknown> = {};
const ouvintes = new Set<() => void>();
export function definirFlags(f: Record<string, unknown> | null | undefined) { flags = f ?? {}; ouvintes.forEach((o) => o()); }
export function flag(chave: string, padrao = false): boolean { const v = flags[chave]; return typeof v === "boolean" ? v : v == null ? padrao : String(v) === "true"; }
export function useFlag(chave: string, padrao = false): boolean {
  return useSyncExternalStore((f) => { ouvintes.add(f); return () => ouvintes.delete(f); }, () => flag(chave, padrao), () => padrao);
}

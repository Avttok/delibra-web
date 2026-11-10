"use client";

import { useSyncExternalStore } from "react";

/** Mostrar/ocultar nomes de estabelecimentos em todos os mapas (lembrado neste navegador). */
const CHAVE = "pwex-estabelecimentos";
const ouvintes = new Set<() => void>();

export function estabelecimentosVisiveis(): boolean {
  try { return localStorage.getItem(CHAVE) !== "0"; } catch { return true; }
}

export function definirEstabelecimentos(v: boolean) {
  try { localStorage.setItem(CHAVE, v ? "1" : "0"); } catch {}
  ouvintes.forEach((f) => f());
}

export function aoMudarEstabelecimentos(f: () => void) {
  ouvintes.add(f);
  return () => { ouvintes.delete(f); };
}

export function useEstabelecimentos(): [boolean, (v: boolean) => void] {
  const v = useSyncExternalStore(aoMudarEstabelecimentos, estabelecimentosVisiveis, () => true);
  return [v, definirEstabelecimentos];
}

// ------------------------------------------------------------------ nomes de rua
/**
 * Nomes de rua: escritos na própria rua ou ocultos. É separado dos estabelecimentos
 * (ícones), que têm o botão próprio. "Ruas e ícones", "Só ruas" e "Só ícones" saem da combinação.
 */
export type ModoRuas = "rua" | "oculta";
const CHAVE_RUAS = "pwex-ruas";
const ouvintesRuas = new Set<() => void>();
export function modoRuas(): ModoRuas {
  // "placa" (modo antigo, removido) volta para "rua"
  try { return localStorage.getItem(CHAVE_RUAS) === "oculta" ? "oculta" : "rua"; } catch { return "rua"; }
}
export function definirModoRuas(v: ModoRuas) {
  try { localStorage.setItem(CHAVE_RUAS, v); } catch {}
  ouvintesRuas.forEach((f) => f());
}
export function aoMudarRuas(f: () => void) {
  ouvintesRuas.add(f);
  return () => { ouvintesRuas.delete(f); };
}
export function useModoRuas(): [ModoRuas, (v: ModoRuas) => void] {
  const v = useSyncExternalStore(aoMudarRuas, modoRuas, () => "rua" as ModoRuas);
  return [v, definirModoRuas];
}

// ------------------------------------------------------------------ o que aparece no mapa
/** Combinação de ruas + estabelecimentos num seletor só. */
export type Rotulos = "tudo" | "ruas" | "icones" | "nada";
export function rotulosAtuais(): Rotulos {
  const r = modoRuas() === "rua", e = estabelecimentosVisiveis();
  return r && e ? "tudo" : r ? "ruas" : e ? "icones" : "nada";
}
export function definirRotulos(v: Rotulos) {
  // cada parte só avisa quem a escuta: ruas mexem só nas ruas, ícones só nos ícones
  const ruas: ModoRuas = v === "tudo" || v === "ruas" ? "rua" : "oculta";
  const icones = v === "tudo" || v === "icones";
  if (ruas !== modoRuas()) definirModoRuas(ruas);
  if (icones !== estabelecimentosVisiveis()) definirEstabelecimentos(icones);
}
export function useRotulos(): [Rotulos, (v: Rotulos) => void] {
  const assinar = (f: () => void) => { const a = aoMudarRuas(f), b = aoMudarEstabelecimentos(f); return () => { a(); b(); }; };
  const v = useSyncExternalStore(assinar, rotulosAtuais, () => "tudo" as Rotulos);
  return [v, definirRotulos];
}

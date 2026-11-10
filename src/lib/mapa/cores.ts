"use client";

/** Resolve "var(--ouro)" para a cor de verdade (o MapLibre não entende variáveis CSS). */
export function resolverCor(cor: string): string {
  const m = /^var\((--[\w-]+)\)$/.exec(cor.trim());
  if (!m || typeof document === "undefined") return cor;
  return getComputedStyle(document.documentElement).getPropertyValue(m[1]).trim() || "#d4af37";
}

export const corOuro = () => resolverCor("var(--ouro)");

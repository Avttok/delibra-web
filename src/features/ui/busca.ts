/** Busca sem acento e sem caixa: todas as palavras precisam aparecer em algum campo. */
export const normal = (t: string) => t.normalize("NFD").replace(/\p{M}/gu, "").toLowerCase();
export function combina(termo: string, ...campos: (string | number | null | undefined)[]): boolean {
  const palavras = normal(termo).split(/\s+/).filter(Boolean);
  if (!palavras.length) return true;
  const tudo = campos.filter((c) => c != null).map((c) => normal(String(c))).join(" ");
  return palavras.every((p) => tudo.includes(p));
}

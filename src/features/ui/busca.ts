/**
 * Busca que perdoa: sem acento e sem caixa, cada palavra digitada pode estar escrita pela
 * metade ("conf" acha "configurações") ou com um erro de digitação ("pagamneto" acha
 * "pagamento"). Todas as palavras precisam combinar com algo dos campos.
 */
export const normal = (t: string) => t.normalize("NFD").replace(/\p{M}/gu, "").toLowerCase();

/** Distância de edição (com troca de letras vizinhas), parando cedo quando passa do limite. */
function distancia(a: string, b: string, limite: number): number {
  if (Math.abs(a.length - b.length) > limite) return limite + 1;
  const m = a.length, n = b.length;
  let ant2: number[] = [], ant = Array.from({ length: n + 1 }, (_, j) => j);
  for (let i = 1; i <= m; i++) {
    const cur = [i];
    let menor = i;
    for (let j = 1; j <= n; j++) {
      const custo = a[i - 1] === b[j - 1] ? 0 : 1;
      let v = Math.min(ant[j] + 1, cur[j - 1] + 1, ant[j - 1] + custo);
      if (i > 1 && j > 1 && a[i - 1] === b[j - 2] && a[i - 2] === b[j - 1]) v = Math.min(v, ant2[j - 2] + 1);
      cur.push(v); if (v < menor) menor = v;
    }
    if (menor > limite) return limite + 1;
    ant2 = ant; ant = cur;
  }
  return ant[n];
}

export function palavraCombina(p: string, tudo: string, palavras: string[]): boolean {
  if (tudo.includes(p)) return true;
  if (p.length < 4) return false;
  const limite = p.length >= 8 ? 2 : 1;
  return palavras.some((w) => distancia(p, w.slice(0, p.length + 1), limite) <= limite || distancia(p, w, limite) <= limite);
}

export function combina(termo: string, ...campos: (string | number | null | undefined)[]): boolean {
  const ps = normal(termo).split(/\s+/).filter(Boolean);
  if (!ps.length) return true;
  const tudo = campos.filter((c) => c != null).map((c) => normal(String(c))).join(" ");
  const palavras = tudo.split(/[^a-z0-9]+/).filter(Boolean);
  return ps.every((p) => palavraCombina(p, tudo, palavras));
}

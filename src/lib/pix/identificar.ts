/**
 * Identifica o tipo de uma chave PIX pelo que foi digitado (igual ao app, em core/perfil/ChavesPix.kt):
 *  • tem "@"                          → e-mail
 *  • 32 hex ou UUID com hífens        → aleatória
 *  • 14 caracteres (números ou CNPJ alfanumérico) → CNPJ (dígitos conferidos)
 *  • 11 números com CPF válido        → CPF
 *  • 11 números com DDD + 9 na frente → celular (também +55…)
 * Quando 11 números servem para CPF e celular ao mesmo tempo, devolve os dois e a pessoa escolhe.
 */

export type TipoPix = "cpf" | "cnpj" | "telefone" | "email" | "aleatoria";
export const ROTULO_PIX: Record<TipoPix, string> = { cpf: "CPF", cnpj: "CNPJ", telefone: "Celular", email: "E-mail", aleatoria: "Aleatória" };

export interface LeituraPix { tipos: TipoPix[]; erro?: string }

const UUID = /^[0-9a-f]{8}-?[0-9a-f]{4}-?[0-9a-f]{4}-?[0-9a-f]{4}-?[0-9a-f]{12}$/i;
const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/;
const CNPJ_ALFA = /^[A-Z0-9]{12}[0-9]{2}$/;

function celularValido(d: string) { return /^[1-9]{2}9\d{8}$/.test(d); }

function cpfValido(d: string) {
  if (!/^\d{11}$/.test(d) || /^(\d)\1+$/.test(d)) return false;
  const n = [...d].map(Number);
  const dv = (ate: number) => { let s = 0; for (let i = 0; i < ate; i++) s += n[i] * (ate + 1 - i); const r = (s * 10) % 11; return r === 10 ? 0 : r; };
  return dv(9) === n[9] && dv(10) === n[10];
}

/** CNPJ numérico ou alfanumérico (valor de cada caractere = código ASCII − 48). */
function cnpjValido(v: string) {
  if (v.length !== 14 || /^(.)\1+$/.test(v)) return false;
  const n = [...v].map((ch) => ch.charCodeAt(0) - 48);
  const p1 = [5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2], p2 = [6, ...p1];
  const dv = (p: number[]) => { const s = p.reduce((a, w, i) => a + n[i] * w, 0); const r = s % 11; return r < 2 ? 0 : 11 - r; };
  return dv(p1) === n[12] && dv(p2) === n[13];
}

export function lerPix(entrada: string): LeituraPix {
  const t = entrada.trim();
  if (!t) return { tipos: [] };
  if (t.includes("@")) return EMAIL.test(t) ? { tipos: ["email"] } : { tipos: [], erro: "E-mail incompleto." };
  if (UUID.test(t)) return { tipos: ["aleatoria"] };
  const semPontuacao = t.replace(/[\s.\-/()]/g, "");
  if (semPontuacao.startsWith("+")) {
    const d = semPontuacao.slice(1);
    return /^55\d+$/.test(d) && celularValido(d.slice(2)) ? { tipos: ["telefone"] } : { tipos: [], erro: "Celular inválido. Use DDD + número." };
  }
  const alfa = semPontuacao.toUpperCase();
  if (alfa.length === 14 && CNPJ_ALFA.test(alfa)) return cnpjValido(alfa) ? { tipos: ["cnpj"] } : { tipos: [], erro: "CNPJ com dígitos errados." };
  if (!/^\d+$/.test(semPontuacao)) return { tipos: [], erro: "Não parece CPF, CNPJ, celular, e-mail ou chave aleatória." };
  const d = semPontuacao;
  switch (d.length) {
    case 11: {
      const cpf = cpfValido(d), cel = celularValido(d);
      // pontuação de CPF desempata para CPF; parênteses ou espaço depois do DDD, para celular
      const pareceCpf = /^\d{3}\.\d{3}\.\d{3}-\d{2}$/.test(t);
      const pareceCel = t.includes("(") || /^\d{2}\s/.test(t);
      if (cpf && pareceCpf) return { tipos: ["cpf"] };
      if (cel && pareceCel) return { tipos: ["telefone"] };
      if (cpf && cel) return { tipos: ["cpf", "telefone"] };
      if (cpf) return { tipos: ["cpf"] };
      if (cel) return { tipos: ["telefone"] };
      return { tipos: [], erro: "CPF com dígitos errados." };
    }
    case 13: return d.startsWith("55") && celularValido(d.slice(2)) ? { tipos: ["telefone"] } : { tipos: [], erro: "Celular inválido." };
    case 14: return cnpjValido(d) ? { tipos: ["cnpj"] } : { tipos: [], erro: "CNPJ com dígitos errados." };
    case 10: return { tipos: [], erro: "Telefone fixo não serve: use o celular com o 9." };
    default: return { tipos: [], erro: d.length < 11 ? "Faltam números." : "Números demais." };
  }
}

/** Como a chave é guardada: CPF/CNPJ só caracteres, celular +55…, e-mail minúsculo, aleatória com hífens. */
export function normalizarPix(entrada: string, tipo: TipoPix): string {
  const t = entrada.trim();
  const limpo = t.replace(/[\s.\-/()+]/g, "");
  switch (tipo) {
    case "cpf": return limpo;
    case "cnpj": return limpo.toUpperCase();
    case "telefone": return "+" + (limpo.length === 13 ? limpo : "55" + limpo);
    case "email": return t.toLowerCase();
    case "aleatoria": {
      const h = t.toLowerCase().replace(/-/g, "");
      return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
    }
  }
}

/** Chave guardada → como mostrar. */
export function formatarPix(chave: string, tipo: string): string {
  if (tipo === "cpf" && chave.length === 11) return chave.replace(/^(\d{3})(\d{3})(\d{3})(\d{2})$/, "$1.$2.$3-$4");
  if (tipo === "cnpj" && chave.length === 14) return `${chave.slice(0, 2)}.${chave.slice(2, 5)}.${chave.slice(5, 8)}/${chave.slice(8, 12)}-${chave.slice(12)}`;
  if (tipo === "telefone") { const m = /^\+55(\d{2})(\d{5})(\d{4})$/.exec(chave); if (m) return `(${m[1]}) ${m[2]}-${m[3]}`; }
  return chave;
}

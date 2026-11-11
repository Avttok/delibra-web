/**
 * Estrutura de idiomas (fica pronta; até a versão 1.0 tudo é português do Brasil).
 * Para traduzir: crie o arquivo do idioma com as mesmas chaves e acrescente em IDIOMAS.
 * Uso: t("comum.salvar") ou t("pedido.numero", { n: 12 }).
 */
import ptBR from "./pt-BR";

export type Idioma = "pt-BR";
export type Chave = keyof typeof ptBR;
const IDIOMAS: Record<Idioma, Record<string, string>> = { "pt-BR": ptBR };
let atual: Idioma = "pt-BR";

export function definirIdioma(i: Idioma) { if (IDIOMAS[i]) atual = i; }
export function idioma() { return atual; }
export function t(chave: Chave | string, vars?: Record<string, string | number>): string {
  const base = IDIOMAS[atual][chave] ?? IDIOMAS["pt-BR"][chave] ?? chave;
  return vars ? base.replace(/\{(\w+)\}/g, (_, k) => String(vars[k] ?? `{${k}}`)) : base;
}

/** Tipos de relatório e a planilha (usados no navegador e no servidor). */
export type Tipo = "rotas" | "pedidos" | "motoboys" | "clientes";
export const TIPOS: { v: Tipo; r: string; dica: string; colunas: string[]; dinheiro: string[] }[] = [
  { v: "rotas", r: "Rotas", dica: "Cada rota concluída ou cancelada, com o que o motoboy recebe e o que fica.", colunas: ["Rota", "Data", "Situação", "Cliente", "Motoboy", "Paradas", "Km", "Valor", "Motoboy recebe", "Empresa fica"], dinheiro: ["Valor", "Motoboy recebe", "Empresa fica"] },
  { v: "pedidos", r: "Pedidos", dica: "Todos os pedidos que chegaram, de onde vieram e a situação.", colunas: ["Pedido", "Data", "Cliente", "Situação", "Origem", "Km estimado", "Valor", "Pagamento"], dinheiro: ["Valor"] },
  { v: "motoboys", r: "Motoboys", dica: "Quanto cada motoboy fez e tem a receber no período.", colunas: ["Motoboy", "Rotas", "Entregas", "Km", "Valor das rotas", "A receber"], dinheiro: ["Valor das rotas", "A receber"] },
  { v: "clientes", r: "Clientes", dica: "Pedidos e faturamento de cada cliente.", colunas: ["Cliente", "Pedidos", "Entregues", "Cancelados", "Faturado"], dinheiro: ["Faturado"] },
];
export type Linha = Record<string, string | number | null>;

/** Monta a planilha em CSV que o Excel abre direto (ponto e vírgula, vírgula decimal, acentos certos). */
export function paraCsv(colunas: string[], linhas: Linha[]) {
  const cel = (v: unknown) => {
    const s = typeof v === "number" ? String(v).replace(".", ",") : String(v ?? "");
    return /[;"\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
  };
  return "﻿" + [colunas.join(";"), ...linhas.map((l) => colunas.map((c) => cel(l[c])).join(";"))].join("\r\n");
}

export const COLUNAS_RELATORIO = Object.fromEntries(TIPOS.map((t) => [t.v, t])) as Record<Tipo, (typeof TIPOS)[number]>;
export const SITUACAO: Record<string, string> = { recebido: "Para revisar", aprovado: "Aprovado", roteirizado: "Em rota", em_rota: "Em rota", concluido: "Entregue", entregue: "Entregue", cancelado: "Cancelado", recusado: "Recusado" };
export const traduzirLinhas = (l: Linha[]) => l.map((x) => (x["Situação"] != null ? { ...x, "Situação": SITUACAO[String(x["Situação"])] ?? x["Situação"] } : x));

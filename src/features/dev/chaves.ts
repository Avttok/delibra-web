import { PARAMETROS } from "@/features/configuracoes/definicoes";
import { ACOES_GESTOR } from "@/features/conta/permissoes";

/** Tudo que o Dev pode decidir: módulos, ações, permissões especiais e cada ajuste do sistema. */
export type TipoChave = "modulo" | "acao" | "especial" | "ajuste" | "nivel";
export interface ChaveDev { chave: string; rotulo: string; tipo: TipoChave; grupo: string; valor: "booleano" | "numero" | "texto" | "opcoes"; opcoes?: { valor: string | number; rotulo: string }[] }
export interface ModuloBasico { chave: string; nome: string; grupo: string }

export const ROTULO_TIPO: Record<TipoChave, string> = { modulo: "Módulo", acao: "Ação", especial: "Permissão especial", ajuste: "Ajuste", nivel: "O que o gestor vê" };
const NIVEIS = [{ valor: "editar", rotulo: "Vê e muda" }, { valor: "ver", rotulo: "Só vê" }, { valor: "oculto", rotulo: "Escondido" }];

export function catalogoChaves(modulos: ModuloBasico[]): ChaveDev[] {
  return [
    ...modulos.map((m) => ({ chave: `modulo:${m.chave}`, rotulo: m.nome, tipo: "modulo" as const, grupo: m.grupo, valor: "booleano" as const })),
    ...ACOES_GESTOR.map((a) => ({ chave: `acao:${a.chave}`, rotulo: a.rotulo, tipo: "acao" as const, grupo: "Ações", valor: "booleano" as const })),
    ...PARAMETROS.map((p) => ({
      chave: p.chave, rotulo: p.rotulo.replace(/^Permissão especial: /, ""), tipo: p.chave.startsWith("especial_") ? "especial" as const : "ajuste" as const, grupo: p.grupo,
      valor: p.tipo === "booleano" ? "booleano" as const : p.tipo === "numero" ? "numero" as const : (p.tipo === "opcoes" || p.tipo === "escolha") ? "opcoes" as const : "texto" as const,
      opcoes: p.opcoes?.map((o) => ({ valor: o.valor, rotulo: o.rotulo })),
    })),
    // o nível de cada ajuste no painel do gestor (vê e muda / só vê / escondido)
    ...PARAMETROS.filter((p) => !p.soDev).map((p) => ({ chave: `nivel:${p.chave}`, rotulo: `${p.rotulo} (no painel do gestor)`, tipo: "nivel" as const, grupo: p.grupo, valor: "opcoes" as const, opcoes: NIVEIS })),
  ];
}

export function rotuloChave(cat: ChaveDev[], chave: string) {
  return cat.find((c) => c.chave === chave)?.rotulo ?? chave;
}

export function mostrarValor(v: unknown) {
  if (v === true) return "Sim";
  if (v === false) return "Não";
  if (v === null || v === undefined) return "—";
  return typeof v === "object" ? JSON.stringify(v) : String(v);
}

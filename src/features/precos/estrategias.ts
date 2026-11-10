/**
 * Estratégias de preço. Cada modalidade é uma função isolada:
 * para criar uma nova, adicione aqui e no enum modalidade_preco do banco.
 * Depois da estratégia, aplicam-se as regras gerais (mínimo e arredondamento).
 */
export type Modalidade = "por_km" | "fixo" | "por_zona";

export interface RegraPreco {
  modalidade: Modalidade;
  valor_km: number | null;
  valor_fixo: number | null;
}

/** Regras gerais vindas de Configurações. */
export interface RegrasGerais {
  valorKmPadrao: number;
  valorMinimo: number;
  arredondamento: number; // 0 = centavos
}

export const VALOR_KM_PADRAO = 2;
const GERAIS_PADRAO: RegrasGerais = { valorKmPadrao: VALOR_KM_PADRAO, valorMinimo: 0, arredondamento: 0 };

export const ROTULO_MODALIDADE: Record<Modalidade, string> = {
  por_km: "Por km rodado",
  fixo: "Preço fixo",
  por_zona: "Por região/zona",
};

export interface Orcamento {
  valor: number | null; // null = gestor informa manualmente
  explicacao: string;
}

const estrategias: Record<Modalidade, (regra: RegraPreco, distanciaM: number | null, g: RegrasGerais) => Orcamento> = {
  por_km(regra, distanciaM, g) {
    const porKm = Number(regra.valor_km ?? g.valorKmPadrao);
    if (distanciaM == null) return { valor: null, explicacao: "Aguardando cálculo da rota" };
    const km = distanciaM / 1000;
    return { valor: km * porKm, explicacao: `${km.toLocaleString("pt-BR", { maximumFractionDigits: 1 })} km × ${moeda(porKm)}` };
  },
  fixo(regra) {
    return { valor: regra.valor_fixo, explicacao: "Preço fixo do cliente" };
  },
  por_zona() {
    return { valor: null, explicacao: "Por zona: informe o valor" };
  },
};

export function orcar(regra: RegraPreco | null, distanciaM: number | null, gerais: Partial<RegrasGerais> = {}): Orcamento {
  const g = { ...GERAIS_PADRAO, ...gerais };
  const r = regra ?? { modalidade: "por_km" as const, valor_km: g.valorKmPadrao, valor_fixo: null };
  const base = estrategias[r.modalidade](r, distanciaM, g);
  if (base.valor == null) return base;

  let valor = base.valor;
  const notas: string[] = [];
  if (g.valorMinimo > 0 && valor < g.valorMinimo) {
    valor = g.valorMinimo;
    notas.push(`mínimo ${moeda(g.valorMinimo)}`);
  }
  if (g.arredondamento > 0) {
    const arred = Math.ceil(valor / g.arredondamento - 1e-9) * g.arredondamento;
    if (Math.abs(arred - valor) > 0.001) notas.push("arredondado");
    valor = arred;
  }
  valor = Math.round(valor * 100) / 100;
  return { valor, explicacao: [base.explicacao, ...notas].join(" · ") };
}

export function moeda(v: number | null | undefined): string {
  if (v == null || Number.isNaN(v)) return "—";
  return v.toLocaleString("pt-BR", { style: "currency", currency: "BRL" });
}

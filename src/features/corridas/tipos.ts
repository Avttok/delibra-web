import type { Modalidade } from "@/features/precos/estrategias";

export type StatusCorrida = "montada" | "aguardando_pagamento" | "agendada" | "reservada" | "aguardando_motoboy" | "sem_motoboy" | "aceita" | "em_andamento" | "concluida" | "cancelada";
export type TipoParada = "coleta" | "entrega";
export type StatusParada = "pendente" | "a_caminho" | "chegou" | "concluida";

/** Como o pagamento do motoboy foi calculado (privado.calcular_pagamento). */
export interface CalculoPagamento {
  modo: "rota" | "percentual" | "por_entrega" | "fixo" | "combinado";
  /** por entrega */ linhas?: { parada: string; ordem: number; km: number; valor: number }[]; fixo_entrega?: number;
  /** fixo */ valor_rota_fixo?: number; por_entrega?: number; por_coleta?: number;
  /** combinado */ combinar?: "soma" | "maior" | "menor" | "media"; partes?: (CalculoPagamento & { parte?: string })[]; acrescimo?: number; acrescimo_pct?: number;
  regras_rota?: Record<string, unknown>; parte?: string; regra?: string; percentil?: number | null; distancia?: string; distancias_km?: number[]; km_referencia?: number;
  valor_km?: number; valor_km_total?: number; entregas?: number; entregas_extras?: number; valor_entrega_extra?: number;
  coletas?: number; coletas_extras?: number; valor_coleta_extra?: number; fixo?: number; minimo?: number; pct?: number; total: number;
  /** Teto: o que a rota paga menos a parte do Dev. `limitado` = o cálculo passou dele e foi cortado. */
  teto?: number; limitado?: boolean; calculado?: number; valor_rota?: number; dev_pct?: number; dev_origem?: "gestor" | "total" | "proporcional";
}

export interface Parada {
  id: string;
  corrida_id: string;
  ordem: number;
  tipo: TipoParada;
  endereco: string;
  lat: number;
  lng: number;
  contato_nome: string | null;
  contato_telefone: string | null;
  instrucoes: string | null;
  referencias?: { nome: string; tipo?: string | null; distancia_m?: number | null; relacao?: string | null }[];
  status: StatusParada;
  chegou_em: string | null;
  concluida_em: string | null;
  recebedor_nome: string | null;
  foto_path: string | null;
  assinatura_path: string | null;
  distancia_chegada_m: number | null;
  local_ignorado: boolean;
  /** O gestor liberou: o motoboy confirma de onde estiver. */
  liberada_local?: boolean;
  /** Feita sem internet (chegou depois, com a hora certa). */
  feita_offline?: boolean;
  /** A rota fechou sozinha e esta etapa espera o app mandar os dados. */
  confirmacao_pendente?: boolean;
  pedido_id?: string | null;
  pedido_ponto_id?: string | null;
  dist_rua_m?: number | null;
  dist_acum_m?: number | null;
}

export interface Corrida {
  id: string;
  numero: number;
  urgente?: boolean;
  empresa_id: string | null;
  status: StatusCorrida;
  agendada_para?: string | null;
  reservada_em?: string | null;
  serie_id?: string | null;
  atraso_avisado_em?: string | null;
  modo_despacho: "direto" | "cascata" | "quadro" | "melhor_primeiro";
  origem?: "manual" | "roteirizador";
  tipo_pedido?: string | null;
  pag_calculo?: CalculoPagamento | null;
  pag_ajuste?: number;
  pag_ajuste_motivo?: string | null;
  sugerido_motoboy_id?: string | null;
  quadro_desde?: string | null;
  tem_perigoso?: boolean;
  teste: boolean;
  exigir_no_local: boolean;
  raio_chegada_m: number;
  motoboy_designado_id: string | null;
  motoboy_id: string | null;
  exige_foto: boolean;
  exige_assinatura: boolean;
  exige_nome: boolean;
  exige_codigo: boolean;
  codigo_entrega: string | null;
  distancia_planejada_m: number | null;
  duracao_planejada_s: number | null;
  rota_planejada: string | null;
  cliente_nome?: string | null;
  motoboy_nome_arquivado?: string | null;
  aplicar_acrescimo?: boolean;
  valor: number | null;
  valor_base?: number | null;
  fator_entrega?: number | null;
  fator_coleta?: number | null;
  repasse_pct: number | null;
  valor_motoboy: number | null;
  valor_gestao: number | null;
  valor_dev?: number | null;
  dev_pct?: number | null;
  pagamento_status?: string;
  /** Fechou sozinha (motoboy sem sinal): espera o app mandar as etapas. */
  aguardando_confirmacao?: boolean;
  pagamento_metodo?: string | null;
  por_cliente?: boolean;
  distancia_real_m: number | null;
  trajeto: string | null;
  observacoes: string | null;
  criada_em: string;
  aceita_em: string | null;
  iniciada_em: string | null;
  concluida_em: string | null;
  cancelada_em: string | null;
  paradas: Parada[];
}

export interface Oferta {
  id: string;
  corrida_id: string;
  motoboy_id: string;
  status: "pendente" | "aceita" | "recusada" | "expirada" | "cancelada";
  distancia_m: number | null;
  expira_em: string;
}

export interface Evento {
  id: number;
  corrida_id: string;
  tipo: string;
  dados: Record<string, unknown>;
  criado_em: string;
}

export interface Empresa {
  id: string;
  nome: string;
  cnpj: string | null;
  tipo?: "pj" | "pf";
  cpf?: string | null;
  pode_express?: boolean;
  repasse_pct?: number | null;
  dev_pct?: number | null;
  pagamento_metodos?: string[];
  modalidade_preco: Modalidade;
  valor_km: number | null;
  valor_fixo: number | null;
  cliente_ve_ao_vivo: boolean;
  observacoes: string | null;
  razao_social: string | null;
  nome_fantasia: string | null;
  situacao: string | null;
  telefone: string | null;
  email: string | null;
  endereco: string | null;
  lat: number | null;
  lng: number | null;
  instrucoes_coleta: string | null;
  consultado_em: string | null;
}

export const ROTULO_CORRIDA: Record<StatusCorrida, string> = {
  montada: "Montada · espera liberar",
  aguardando_pagamento: "Aguardando pagamento",
  agendada: "Planejada · livre",
  reservada: "Planejada · reservada",
  aguardando_motoboy: "Procurando motoboy",
  sem_motoboy: "Sem motoboy",
  aceita: "Aceita",
  em_andamento: "Em andamento",
  concluida: "Concluída",
  cancelada: "Cancelada",
};

export const COR_CORRIDA: Record<StatusCorrida, string> = {
  montada: "#a78bfa",
  aguardando_pagamento: "#f59e0b",
  agendada: "#60a5fa",
  reservada: "#38bdf8",
  aguardando_motoboy: "var(--ouro-claro)",
  sem_motoboy: "#e5484d",
  aceita: "var(--ouro)",
  em_andamento: "var(--ouro)",
  concluida: "#2ecc71",
  cancelada: "#8a8a8a",
};

export const ROTULO_PARADA: Record<StatusParada, string> = {
  pendente: "Pendente",
  a_caminho: "A caminho",
  chegou: "No local",
  concluida: "Concluída",
};

export const ATIVAS: StatusCorrida[] = ["montada", "aguardando_pagamento", "aguardando_motoboy", "sem_motoboy", "aceita", "em_andamento"];
/** Corridas com hora marcada que ainda não começaram. */
export const PLANEJADAS: StatusCorrida[] = ["agendada", "reservada"];

export function formatarKm(m: number | null | undefined) {
  return m == null ? "—" : `${(m / 1000).toLocaleString("pt-BR", { maximumFractionDigits: 1 })} km`;
}

export function formatarDuracao(s: number | null | undefined) {
  if (s == null) return "—";
  const min = Math.round(s / 60);
  return min < 60 ? `${min} min` : `${Math.floor(min / 60)} h ${min % 60} min`;
}

export function hora(iso: string | null | undefined) {
  return iso ? new Date(iso).toLocaleTimeString("pt-BR", { hour: "2-digit", minute: "2-digit" }) : "—";
}

/** Número de exibição: corridas reais "#12", de teste "T12" (sequências separadas). */
export const numeroCorrida = (c: { numero: number | null; teste?: boolean | null }) =>
  c.numero == null ? "" : c.teste ? `T${c.numero}` : `#${c.numero}`;

import type { Referencia } from "@/features/geo";

export type StatusPedido = "recebido" | "aprovado" | "roteirizado" | "em_rota" | "concluido" | "cancelado" | "recusado";

export interface LinhaOrcamento {
  rotulo: string; valor: number; detalhe?: string;
  /** Linhas com quantidade × valor unitário (km, entregas, volumes, kg). */
  qtd?: number; unit?: number; unidade?: string;
  /** Entra depois dos percentuais (taxa fixa). */
  fixo?: boolean; chave?: string;
}
export interface Orcamento {
  linhas: LinhaOrcamento[]; percentuais: { rotulo: string; pct: number }[]; subtotal: number; acrescimo_pct: number; minimo: number; total: number;
  km: number; distancia_m: number; coletas: number; entregas: number; volumes: number; peso_real_kg: number; peso_cubado_kg: number; peso_taxado_kg: number; perigoso: boolean;
  /** soma_entregas | rota | fixo */
  modo_distancia?: string;
  /** O gestor mudou as linhas à mão. */
  editado?: boolean; motivo?: string | null; original?: Orcamento;
}

export interface PontoPedido {
  id: string; pedido_id: string; ordem: number; tipo: "coleta" | "entrega"; endereco: string; lat: number; lng: number;
  contato_nome: string | null; contato_telefone: string | null; instrucoes: string | null; referencias: Referencia[];
  status: "pendente" | "em_rota" | "concluido" | "cancelado"; concluido_em: string | null; recebedor_nome: string | null;
}
export interface ItemPedido {
  id: string; pedido_id: string; coleta_id: string | null; entrega_id: string | null; descricao: string; categoria_id: string | null; quantidade: number;
  peso_kg: number | null; comprimento_cm: number | null; largura_cm: number | null; altura_cm: number | null; valor_declarado: number | null; observacoes: string | null;
}
export interface Pedido {
  id: string; numero: number; teste: boolean; empresa_id: string | null; cliente_nome: string | null; criado_por: string | null; origem: "cliente" | "gestor";
  tipo: "express" | "planejado"; tipo_pedido: string; quando: string | null; urgente: boolean; status: StatusPedido; observacoes: string | null;
  distancia_estimada_m: number | null; orcamento: Orcamento | null; valor_calculado: number | null; valor_ajuste: number; ajuste_motivo: string | null;
  valor: number | null; dev_pct: number | null; valor_dev: number | null; cobranca: "credito" | "pre_pago"; pagamento_status: "nao_exigido" | "pendente" | "pago" | "reembolsado";
  pagamento_metodo: string | null; fatura_id: string | null; revisado_em: string | null; aprovado_em: string | null; recusa_motivo: string | null;
  criado_em: string; concluido_em: string | null; cancelado_em: string | null;
  pedido_pontos?: PontoPedido[]; pedido_itens?: ItemPedido[];
}
export type Campo = "oculto" | "opcional" | "obrigatorio";
export interface Categoria {
  id: string; nome: string; descricao: string | null; perigoso: boolean; classe_risco: string | null; fragil: boolean; ativa?: boolean; icone?: string | null;
  campo_descricao?: Campo; campo_peso?: Campo; campo_medidas?: Campo; campo_valor?: Campo; campo_quantidade?: Campo;
}
export interface TipoPedido { chave: string; nome: string; descricao: string | null; ativo?: boolean; icone?: string | null }

export const ROTULO_PEDIDO: Record<StatusPedido, string> = {
  recebido: "Para revisar", aprovado: "Aprovado", roteirizado: "Em rota montada", em_rota: "Com motoboy", concluido: "Entregue", cancelado: "Cancelado", recusado: "Recusado",
};
export const COR_PEDIDO: Record<StatusPedido, string> = {
  recebido: "#f59e0b", aprovado: "#60a5fa", roteirizado: "#a78bfa", em_rota: "var(--ouro)", concluido: "#2ecc71", cancelado: "#8a8a8a", recusado: "#e5484d",
};

const ERROS: Record<string, string> = {
  cliente_sem_agendado: "Esta conta não faz pedidos agendados (libere em Ajustes → Clientes).",
  agendamento_longe_demais: "Data longe demais: escolha um dia mais perto.",
  cliente_sem_urgente: "Esta conta não pode marcar pedido urgente.",
  entregas_demais: "Entregas demais para um pedido só. Divida em dois pedidos.",
  coletas_demais: "Coletas demais para um pedido só.",
  pedidos_abertos_demais: "Já há pedidos demais em aberto. Espere algum terminar ou fale com a Delibra.",
  cliente_bloqueado: "Sua conta está sem pedidos novos por enquanto. Fale com a empresa.",
  motoboy_suspenso: "Motoboy suspenso por penalidades: não pode pegar rotas agora.",
  chamado_ja_aberto: "Já existe um pedido de cancelamento aberto para esta rota.",
  limite_motoboys_do_plano: "A empresa chegou ao limite de motoboys do plano.",
  limite_gestores_do_plano: "A empresa chegou ao limite de gestores do plano.",
  limite_clientes_do_plano: "A empresa chegou ao limite de clientes do plano.",
  fora_do_horario: "Fora do horário de pedidos na hora. Agende para mais tarde.",
  janela_invalida: "O horário de um ponto termina antes de começar.",
  chat_desligado: "A conversa está desligada.",
  fotos_desligadas: "O envio de fotos está desligado.",
  conversa_invalida: "Conversa não encontrada.",
  mensagem_vazia: "Escreva algo ou anexe uma foto.",
  anexo_invalido: "Esse anexo não pôde ser enviado.",
  orcamento_invalido: "O cálculo tem um valor inválido. Confira as linhas.",
  motoboy_sem_rota_em_andamento: "Esse motoboy não está em corrida agora.",
  rota_nao_esta_em_andamento: "Essa rota não está mais em andamento.",
  apenas_gestor_ou_cliente: "Só gestores e clientes fazem pedidos.",
  cliente_so_agendado: "Este cliente ainda pede só agendado (libere o Express no cadastro ou nas regras).",
  horario_muito_proximo: "Horário perto demais: agende com mais antecedência.",
  horario_passou: "Esse horário já passou.",
  pedido_precisa_coleta_e_entrega: "O pedido precisa de pelo menos uma coleta e uma entrega.",
  ponto_sem_localizacao: "Localize todos os endereços (escolha da lista ou marque no mapa).",
  pontos_demais: "No máximo 60 pontos por pedido.",
  tipo_pedido_invalido: "Tipo de pedido inválido.",
  pedido_finalizado: "Esse pedido já foi finalizado.",
  pedido_ja_faturado: "Esse pedido já está numa fatura emitida.",
  informe_o_motivo: "Informe o motivo do ajuste.",
  pedido_em_andamento: "Um motoboy já está com esse pedido.",
  pedido_ja_em_rota: "O pedido já está com um motoboy.",
  valor_invalido: "Valor inválido.",
  rota_ja_pegada: "Um motoboy já pegou essa rota.",
  rota_destino_invalida: "Essa rota não pode receber entregas agora.",
  rota_nao_pode_ser_liberada: "Essa rota não pode ser liberada agora.",
  holerite_fechado: "O holerite desse período já foi fechado (reabra para mudar).",
  nada_para_faturar: "Nenhum pedido concluído e sem fatura nesse período.",
  so_no_rascunho: "Só dá para fazer isso numa fatura em rascunho.",
  emita_antes: "Emita a fatura antes de marcar como paga.",
  fatura_paga: "Fatura paga não pode ser cancelada.",
  feche_o_holerite_antes: "Feche o holerite antes de marcar como pago.",
  apenas_dev: "Só o Dev altera isso.",
  item_sem_peso: "Informe o peso dos itens que pedem peso.",
  item_sem_valor: "Informe o valor declarado dos itens que pedem valor.",
  item_sem_descricao: "Descreva os itens que pedem descrição.",
  item_sem_medidas: "Informe as medidas dos itens que pedem medidas.",
  item_sem_categoria: "Escolha o tipo de cada item.",
  categoria_invalida: "Tipo de item inválido.",
  pedido_nao_pode_voltar: "Esse pedido não pode voltar para a revisão agora.",
  cliente_nao_cancela: "Para cancelar, fale com a Delibra.",
  cadastro_nao_encontrado: "Cadastro não encontrado.",
  versao_nao_autorizada: "Versão do app não autorizada.",
};
export function traduzir(msg: string | undefined): string {
  if (!msg) return "Erro desconhecido.";
  return Object.entries(ERROS).find(([k]) => msg.includes(k))?.[1] ?? msg;
}

export const moedaBr = (v: number | null | undefined) => (v == null ? "—" : Number(v).toLocaleString("pt-BR", { style: "currency", currency: "BRL" }));
export const quando = (iso: string | null | undefined) => (iso ? new Date(iso).toLocaleString("pt-BR", { dateStyle: "short", timeStyle: "short" }) : "—");

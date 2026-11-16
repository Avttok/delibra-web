import { ROTULO_PEDIDO } from "@/features/pedidos/tipos";
import { ROTULO_CORRIDA } from "@/features/corridas/tipos";

/**
 * Nomes próprios da empresa (Ajustes → Modalidades → Nomes): trocam os nomes padrão dos status e dos tipos de parada
 * em todas as telas. Chave do mapa: "<tipo de pedido>|<alvo>" (tipo vazio = todos), alvo = pedido:<status>, rota:<status>, parada:coleta|entrega.
 */
const PADRAO_PEDIDO = { ...ROTULO_PEDIDO };
const PADRAO_CORRIDA = { ...ROTULO_CORRIDA };
const PARADA: Record<string, string> = { coleta: "Coleta", entrega: "Entrega" };
let ativos: Record<string, string> = {};

export function aplicarRotulos(mapa: Record<string, string> | null | undefined) {
  ativos = mapa ?? {};
  Object.assign(ROTULO_PEDIDO, PADRAO_PEDIDO);
  Object.assign(ROTULO_CORRIDA, PADRAO_CORRIDA);
  PARADA.coleta = "Coleta"; PARADA.entrega = "Entrega";
  for (const [k, v] of Object.entries(ativos)) {
    const [tipo, alvo] = k.split("|");
    if (tipo || !alvo) continue;
    const [grupo, s] = alvo.split(":");
    if (grupo === "pedido" && s in ROTULO_PEDIDO) (ROTULO_PEDIDO as Record<string, string>)[s] = v;
    else if (grupo === "rota" && s in ROTULO_CORRIDA) (ROTULO_CORRIDA as Record<string, string>)[s] = v;
    else if (grupo === "parada" && s in PARADA) PARADA[s] = v;
  }
}

/** Nome do tipo de parada (coleta/entrega), com o nome próprio da empresa e do tipo de pedido, se houver. */
export function nomeParada(tipo: string, tipoPedido?: string | null) {
  return (tipoPedido && ativos[`${tipoPedido}|parada:${tipo}`]) || PARADA[tipo] || tipo;
}

/** Nome próprio de um status (ou o padrão dado). */
export function nomeStatus(grupo: "pedido" | "rota", status: string, padrao: string, tipoPedido?: string | null) {
  return (tipoPedido && ativos[`${tipoPedido}|${grupo}:${status}`]) || ativos[`|${grupo}:${status}`] || padrao;
}

export const ALVOS_PEDIDO = Object.entries(PADRAO_PEDIDO);
export const ALVOS_CORRIDA = Object.entries(PADRAO_CORRIDA);

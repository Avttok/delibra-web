"use client";

import { useState } from "react";
import { TriangleAlert } from "lucide-react";
import { Icone } from "@/features/ui/icones";

/** Um pacote como chega das telas (pedido_itens, corrida_json_completo ou meus_pedidos_cliente). */
export interface Pacote {
  id?: string; descricao: string; quantidade: number; categoria?: string | null; icone?: string | null;
  perigoso?: boolean; fragil?: boolean; peso_kg?: number | null; comprimento_cm?: number | null; largura_cm?: number | null; altura_cm?: number | null;
  valor_declarado?: number | null; observacoes?: string | null; coleta_id?: string | null; entrega_id?: string | null;
  /** Não está preso a este ponto: vai para todas as entregas (ou sai de qualquer coleta). */
  todas?: boolean;
}

/** Os pacotes de um ponto (os presos a ele + os que valem para todos), a partir da lista do pedido. */
export function pacotesDoPonto<T extends Pacote>(itens: T[], ponto: { id: string; tipo: "coleta" | "entrega" | string }, idsDoTipo?: string[]): (T & { todas: boolean })[] {
  const campo = ponto.tipo === "coleta" ? "coleta_id" : "entrega_id";
  return itens
    .filter((i) => i[campo] === ponto.id || !i[campo] || (idsDoTipo && !idsDoTipo.includes(i[campo] as string)))
    .map((i) => ({ ...i, todas: i[campo] !== ponto.id }));
}

const br = (v: number) => v.toLocaleString("pt-BR", { maximumFractionDigits: 2 });

/** Ícones dos pacotes de um ponto; toque num deles para ver o detalhe. */
export function PacotesPonto({ itens, vazio }: { itens: Pacote[]; vazio?: string }) {
  const [aberto, setAberto] = useState<number | null>(null);
  if (itens.length === 0) return vazio ? <span className="dica">{vazio}</span> : null;
  const it = aberto != null ? itens[aberto] : null;
  return (
    <div className="pacotes-ponto" onClick={(e) => e.stopPropagation()}>
      <div className="pacotes-chips">
        {itens.map((x, i) => (
          <button key={x.id ?? i} type="button" className={`pacote-chip${aberto === i ? " ativo" : ""}${x.perigoso ? " perigoso" : ""}${x.todas ? " todas" : ""}`}
            title={`${x.quantidade}× ${x.descricao}${x.todas ? " (vai para todas)" : ""}`} onClick={() => setAberto(aberto === i ? null : i)}>
            <Icone nome={x.icone ?? "box"} size={14} /> <span>{x.quantidade > 1 ? `${x.quantidade}× ` : ""}{x.descricao || x.categoria || "Pacote"}</span>
            {x.perigoso && <TriangleAlert size={11} aria-hidden />}
          </button>
        ))}
      </div>
      {it && (
        <dl className="pacote-detalhe">
          <div><dt>Item</dt><dd>{it.descricao || "—"}</dd></div>
          {it.categoria && <div><dt>Tipo</dt><dd>{it.categoria}{it.perigoso ? " · perigoso" : ""}{it.fragil ? " · frágil" : ""}</dd></div>}
          <div><dt>Quantidade</dt><dd>{it.quantidade}</dd></div>
          {it.peso_kg != null && <div><dt>Peso</dt><dd>{br(Number(it.peso_kg))} kg cada</dd></div>}
          {it.comprimento_cm != null && <div><dt>Medidas</dt><dd>{br(Number(it.comprimento_cm))}×{br(Number(it.largura_cm ?? 0))}×{br(Number(it.altura_cm ?? 0))} cm</dd></div>}
          {it.valor_declarado != null && <div><dt>Valor declarado</dt><dd>{Number(it.valor_declarado).toLocaleString("pt-BR", { style: "currency", currency: "BRL" })}</dd></div>}
          {it.observacoes && <div><dt>Obs.</dt><dd>{it.observacoes}</dd></div>}
          {it.todas && <div><dt>Onde</dt><dd>Vai para todas as entregas</dd></div>}
        </dl>
      )}
    </div>
  );
}

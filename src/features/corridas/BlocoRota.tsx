"use client";

import { useEffect, useState } from "react";
import { Dica } from "@/features/ui/Tour";
import Link from "next/link";
import { Calculator, ClipboardList, Crown, Megaphone, RefreshCw, Route, Send, Shuffle, Sparkles, Users } from "lucide-react";
import { supabase } from "@/lib/supabase/client";
import { moeda } from "@/features/precos/estrategias";
import { toast } from "@/features/ui/toast";
import { traduzir } from "@/features/pedidos/tipos";
import type { MembroEquipe } from "./dados";
import { PagamentoMotoboy } from "./PagamentoMotoboy";
import type { CalculoPagamento, Corrida } from "./tipos";

const REGRA: Record<string, string> = {
  mediana: "entrega do meio", percentil: "percentil", media: "média das entregas", mais_longe: "entrega mais longe", mais_perto: "entrega mais perto", total_rota: "rota inteira",
};

/** O cálculo do motoboy, linha a linha. */

export function ContaMotoboy({ calc }: { calc: CalculoPagamento }) {
  const v = (calc as CalculoPagamento & { volta?: { km: number; valor_km: number; pct: number; valor: number } }).volta;
  return (
    <>
      <ContaMotoboyBase calc={calc} />
      {v && <div className="orcamento-linha"><span>Volta até a partida<small>{Number(v.km).toLocaleString("pt-BR")} km × {moeda(v.valor_km)}{Number(v.pct) !== 100 ? ` · ${v.pct}%` : ""}</small></span><strong>+ {moeda(v.valor)}</strong></div>}
    </>
  );
}

function ContaMotoboyBase({ calc }: { calc: CalculoPagamento }) {
  const z = (calc as CalculoPagamento & { zona?: { raio_m: number; agrupada: boolean; juntas: number; entregas: number } }).zona;
  const zona = z && (
    <p className="dica" style={{ margin: 0 }}>
      Por zonas (raio de {Number(z.raio_m).toLocaleString("pt-BR")} m em cada entrega): {z.agrupada ? `entregas juntas (${z.juntas} de ${z.entregas}) → paga por km + fixo por entrega a mais` : `há entrega isolada (${z.juntas} de ${z.entregas} juntas) → paga a porcentagem da rota`}.
    </p>
  );
  const teto = calc.limitado && calc.teto != null && (
    <p className="dica" style={{ margin: 0, color: "var(--ouro)" }}>Limitado a {moeda(calc.teto)}: o motoboy nunca leva mais que o valor da rota.</p>
  );
  const regrasRota = calc.regras_rota && Object.keys(calc.regras_rota).length > 0 && (
    <p className="dica" style={{ margin: 0, color: "var(--ouro)" }}>Esta rota tem regras de pagamento próprias ({Object.keys(calc.regras_rota).length}).</p>
  );
  if (calc.modo === "combinado") {
    const nome: Record<string, string> = { zonas: "Zonas", rota: "Por km", percentual: "Percentual", por_entrega: "Por entrega", fixo: "Fixo" };
    const comb: Record<string, string> = { soma: "somados", maior: "vale o maior", menor: "vale o menor", media: "a média" };
    return (
      <div className="orcamento">
        {regrasRota}
        <p className="dica" style={{ margin: 0 }}>{calc.partes?.length} cálculos juntos · {comb[calc.combinar ?? "soma"]}</p>
        {calc.partes?.map((x, i) => (
          <details key={i} className="pag-parte">
            <summary className="orcamento-linha"><span>{nome[x.parte ?? x.modo] ?? x.modo}</span><strong>{moeda(x.calculado ?? x.total)}</strong></summary>
            <ContaMotoboy calc={x} />
          </details>
        ))}
        {Number(calc.acrescimo_pct) !== 0 && <div className="orcamento-linha pct"><span>Acréscimo</span><strong>{calc.acrescimo_pct}%</strong></div>}
        {Number(calc.acrescimo) !== 0 && <div className="orcamento-linha"><span>Valor somado no fim</span><strong>{moeda(calc.acrescimo)}</strong></div>}
        {calc.limitado && calc.calculado != null && <div className="orcamento-linha"><span>Pelo cálculo</span><strong>{moeda(calc.calculado)}</strong></div>}
        <div className="orcamento-linha total"><span>{calc.limitado ? "Fica (teto da rota)" : "O motoboy recebe"}</span><strong>{moeda(calc.total)}</strong></div>
        {teto}
      </div>
    );
  }
  if (calc.modo === "por_entrega") return (
    <div className="orcamento">
      {regrasRota}
      {(calc.linhas ?? []).map((l) => (
        <div key={l.parada} className="orcamento-linha"><span>Entrega {l.ordem + 1}<small>{l.km.toLocaleString("pt-BR")} km × {moeda(calc.valor_km)}{Number(calc.fixo_entrega) > 0 ? ` + ${moeda(calc.fixo_entrega)}` : ""}</small></span><strong>{moeda(l.valor)}</strong></div>
      ))}
      {Number(calc.minimo) > 0 && <div className="orcamento-linha pct"><span>Mínimo</span><strong>{moeda(calc.minimo)}</strong></div>}
      <div className="orcamento-linha total"><span>{calc.limitado ? "Fica (teto da rota)" : "Calculado"}</span><strong>{moeda(calc.total)}</strong></div>
      {teto}
    </div>
  );
  if (calc.modo === "fixo") return (
    <div className="orcamento">
      {regrasRota}
      {Number(calc.valor_rota_fixo) > 0 && <div className="orcamento-linha"><span>Por rota</span><strong>{moeda(calc.valor_rota_fixo)}</strong></div>}
      {Number(calc.por_entrega) > 0 && <div className="orcamento-linha"><span>Por entrega</span><strong>{calc.entregas} × {moeda(calc.por_entrega)}</strong></div>}
      {Number(calc.por_coleta) > 0 && <div className="orcamento-linha"><span>Por coleta</span><strong>{calc.coletas} × {moeda(calc.por_coleta)}</strong></div>}
      <div className="orcamento-linha total"><span>{calc.limitado ? "Fica (teto da rota)" : "Calculado"}</span><strong>{moeda(calc.total)}</strong></div>
      {teto}
    </div>
  );
  if (calc.modo === "percentual") return (
    <>
      {regrasRota}
      {zona}
      <p className="dica" style={{ margin: 0 }}>Percentual: {calc.pct}% do valor da rota = <strong>{moeda(calc.total)}</strong></p>
      {teto}
    </>
  );
  return (
    <div className="orcamento">
      {zona}
      <div className="orcamento-linha"><span>Km de referência<small>{REGRA[calc.regra ?? ""] ?? calc.regra}{calc.regra === "percentil" ? ` ${calc.percentil}%` : ""} · {calc.distancia === "acumulada" ? "acumulado na rota" : "coleta → entrega"} · {(calc.distancias_km ?? []).map((d) => d.toLocaleString("pt-BR")).join(", ")} km</small></span>
        <strong>{calc.km_referencia?.toLocaleString("pt-BR")} km × {moeda(calc.valor_km)} = {moeda(calc.valor_km_total)}</strong></div>
      {Number(calc.entregas_extras) > 0 && <div className="orcamento-linha"><span>Entregas a mais</span><strong>{calc.entregas_extras} × {moeda(calc.valor_entrega_extra)}</strong></div>}
      {Number(calc.coletas_extras) > 0 && Number(calc.valor_coleta_extra) > 0 && <div className="orcamento-linha"><span>Coletas a mais</span><strong>{calc.coletas_extras} × {moeda(calc.valor_coleta_extra)}</strong></div>}
      {Number(calc.fixo) > 0 && <div className="orcamento-linha"><span>Fixo por rota</span><strong>{moeda(calc.fixo)}</strong></div>}
      {Number(calc.minimo) > 0 && <div className="orcamento-linha pct"><span>Mínimo</span><strong>{moeda(calc.minimo)}</strong></div>}
      {calc.limitado && calc.calculado != null && <div className="orcamento-linha"><span>Pelo cálculo</span><strong>{moeda(calc.calculado)}</strong></div>}
      <div className="orcamento-linha total"><span>{calc.limitado ? "Fica (teto da rota)" : "Calculado"}</span><strong>{moeda(calc.total)}</strong></div>
      {teto}
    </div>
  );
}

/** Peças da rota automática no detalhe: pedidos, liberar, mover entregas e o pagamento do motoboy. */
export function BlocoRota({ corrida, equipe }: { corrida: Corrida; equipe: MembroEquipe[] }) {
  const [pedidos, setPedidos] = useState<{ id: string; numero: number; cliente: string }[]>([]);
  const [abertas, setAbertas] = useState<{ id: string; numero: number }[]>([]);
  const [motoboy, setMotoboy] = useState("");
  const [ajuste, setAjuste] = useState(String(corrida.pag_ajuste ?? 0).replace(".", ","));
  const [motivo, setMotivo] = useState(corrida.pag_ajuste_motivo ?? "");
  const pedidoIds = [...new Set(corrida.paradas.map((p) => p.pedido_id).filter(Boolean))] as string[];
  const aberta = !corrida.motoboy_id && ["montada", "agendada", "aguardando_motoboy", "sem_motoboy"].includes(corrida.status);

  useEffect(() => {
    if (!pedidoIds.length) { setPedidos([]); return; }
    supabase().from("pedidos").select("id,numero,cliente_nome,empresas(nome)").in("id", pedidoIds).then(({ data }) =>
      setPedidos(((data ?? []) as unknown as { id: string; numero: number; cliente_nome: string | null; empresas: { nome: string } | null }[])
        .map((p) => ({ id: p.id, numero: p.numero, cliente: p.empresas?.nome ?? p.cliente_nome ?? "Avulso" }))));
  }, [pedidoIds.join(",")]); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => {
    if (!aberta) return;
    supabase().from("corridas").select("id,numero").eq("teste", corrida.teste).is("motoboy_id", null).neq("id", corrida.id)
      .in("status", ["montada", "agendada", "aguardando_motoboy", "sem_motoboy"]).order("numero").then(({ data }) => setAbertas((data ?? []) as { id: string; numero: number }[]));
  }, [aberta, corrida.id, corrida.teste]);

  async function liberar(modo: string | null, moto: string | null = null) {
    const { error } = await supabase().rpc("liberar_rota", { p_corrida: corrida.id, p_modo: modo, p_motoboy: moto });
    if (error) return toast(traduzir(error.message), "erro");
    toast(moto ? "Rota entregue ao motoboy escolhido." : modo === "quadro" ? "No quadro: todos os motoboys veem." : "Rota liberada.", "ok");
  }
  async function mover(parada: string, destino: string) {
    const { error } = await supabase().rpc("mover_entrega", { p_parada: parada, p_destino: destino === "nova" ? null : destino });
    if (error) return toast(traduzir(error.message), "erro");
    toast(destino === "nova" ? "Entrega separada numa rota nova." : "Entrega movida.", "ok");
  }
  const [estender, setEstender] = useState("");
  async function estenderRota(perguntar: boolean) {
    if (!perguntar && !confirm("Juntar esta rota à que o motoboy está fazendo agora?")) return;
    const { error } = await supabase().rpc("estender_rota", { p_nova: corrida.id, p_motoboy: estender, p_perguntar: perguntar });
    if (error) return toast(error.message.includes("estender_rota") ? "Rode a migração 20261110000015_despacho_cliente.sql." : traduzir(error.message), "erro");
    toast(perguntar ? "Oferta de extensão enviada." : "Rota estendida: as paradas entraram na rota em andamento.", "ok");
    setEstender("");
  }
  async function salvarAjuste() {
    const v = Number(ajuste.replace(",", ".")) || 0;
    const { error } = await supabase().rpc("ajustar_pagamento_rota", { p_corrida: corrida.id, p_ajuste: v, p_motivo: motivo || null });
    if (error) return toast(traduzir(error.message), "erro");
    toast("Pagamento do motoboy ajustado.", "ok");
  }
  async function recalcular() {
    const { error } = await supabase().rpc("recalcular_pagamento_rota", { p_corrida: corrida.id });
    if (error) return toast(traduzir(error.message), "erro");
    toast("Recalculado com as regras de agora.", "ok");
  }
  const nome = (id?: string | null) => equipe.find((m) => m.id === id)?.nome;
  const pedidoDe = (id?: string | null) => pedidos.find((p) => p.id === id);

  return (
    <>
      {pedidos.length > 0 && (
        <section className="bloco">
          <span className="rotulo"><ClipboardList size={12} aria-hidden /> Pedidos nesta rota</span>
          <div className="linha-botoes">
            {pedidos.map((p) => <Link key={p.id} href={`/gestor/pedidos?p=${p.id}`} className="chip"><ClipboardList size={13} aria-hidden /> Ver pedido #{p.numero} · {p.cliente}</Link>)}
          </div>
          {aberta && corrida.paradas.filter((p) => p.tipo === "entrega").map((p) => (
            <div key={p.id} className="mover-entrega">
              <span className="dica"><strong>{p.ordem + 1}.</strong> {p.endereco.split(",")[0]} {pedidoDe(p.pedido_id) ? `· #${pedidoDe(p.pedido_id)!.numero}` : ""}</span>
              <select value="" onChange={(e) => e.target.value && mover(p.id, e.target.value)} aria-label="Mover entrega">
                <option value="">Mover…</option>
                <option value="nova">Para uma rota nova</option>
                {abertas.map((r) => <option key={r.id} value={r.id}>Para a rota #{r.numero}</option>)}
              </select>
            </div>
          ))}
        </section>
      )}

      {aberta && (
        <section className="bloco alerta-bloco">
          <span className="rotulo"><Megaphone size={12} aria-hidden /> {corrida.status === "montada" ? "Rota montada: solte para os motoboys" : "Despacho"}<Dica titulo="Como soltar a rota" texto="Quadro: todos veem e o primeiro que pegar leva. Melhor primeiro: só o mais indicado recebe a oferta; se não aceitar, vai para o quadro. Cascata: a oferta passa de um em um, do mais perto ao mais longe. Direto: o escolhido recebe a oferta." /></span>
          {corrida.sugerido_motoboy_id && <p className="dica" style={{ margin: 0 }}><Sparkles size={12} aria-hidden /> Melhor agora: <strong>{nome(corrida.sugerido_motoboy_id) ?? "motoboy"}</strong></p>}
          {corrida.modo_despacho === "quadro" && corrida.status !== "montada" && <p className="dica" style={{ margin: 0 }}><Users size={12} aria-hidden /> No quadro desde {corrida.quadro_desde ? new Date(corrida.quadro_desde).toLocaleTimeString("pt-BR", { hour: "2-digit", minute: "2-digit" }) : "agora"}: todos veem, o 1º que pegar leva.</p>}
          {corrida.agendada_para && <p className="dica" style={{ margin: 0, color: "#60a5fa" }}>Agendada para {new Date(corrida.agendada_para).toLocaleString("pt-BR", { dateStyle: "short", timeStyle: "short" })}: quem aceitar a oferta fica com a reserva (não começa agora).</p>}
          <div className="linha-botoes">
            <button className="botao-ouro" onClick={() => liberar("quadro")}><Users size={15} aria-hidden /> Quadro</button>
            <button className="botao-texto" onClick={() => liberar("melhor_primeiro")}><Crown size={15} aria-hidden /> Melhor primeiro</button>
            <button className="botao-texto" onClick={() => liberar("cascata")}><Shuffle size={15} aria-hidden /> Cascata</button>
          </div>
          <div className="linha-botoes">
            <select value={motoboy} onChange={(e) => setMotoboy(e.target.value)} style={{ flex: 1 }}>
              <option value="">Oferecer direto para…</option>
              {equipe.filter((m) => m.modo_teste === corrida.teste).map((m) => <option key={m.id} value={m.id}>{m.id === corrida.sugerido_motoboy_id ? "★ " : ""}{m.nome}</option>)}
            </select>
            <button className="botao-texto" disabled={!motoboy} onClick={() => liberar(null, motoboy)}><Send size={15} aria-hidden /> Enviar oferta</button>
          </div>
          {!corrida.agendada_para && equipe.some((m) => m.status === "em_corrida" && m.modo_teste === corrida.teste) && (
            <>
              <span className="rotulo" style={{ marginTop: 6 }}><Route size={12} aria-hidden /> Estender a rota de quem já está em corrida
                <Dica titulo="Extensão de rota" texto="As paradas desta rota entram no fim da rota que o motoboy já está fazendo. Pedindo, ele recebe a oferta e decide; direto, a rota dele já aumenta. O ganho dele nunca diminui por isso (Configurações → Extensão de rota)." /></span>
              <div className="linha-botoes">
                <select value={estender} onChange={(e) => setEstender(e.target.value)} style={{ flex: 1 }}>
                  <option value="">Motoboy em corrida…</option>
                  {equipe.filter((m) => m.status === "em_corrida" && m.modo_teste === corrida.teste).map((m) => <option key={m.id} value={m.id}>{m.nome}</option>)}
                </select>
                <button className="botao-texto" disabled={!estender} onClick={() => estenderRota(true)}><Send size={15} aria-hidden /> Perguntar</button>
                <button className="botao-texto" disabled={!estender} onClick={() => estenderRota(false)}><Route size={15} aria-hidden /> Estender direto</button>
              </div>
            </>
          )}
        </section>
      )}

      {corrida.pag_calculo && <PagamentoMotoboy corrida={corrida} conta={<ContaMotoboy calc={corrida.pag_calculo} />} />}
    </>
  );
}

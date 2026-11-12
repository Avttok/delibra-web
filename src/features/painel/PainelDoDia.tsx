"use client";

import { useEffect, useState } from "react";
import Link from "next/link";
import { AlertTriangle, Bike, CircleDollarSign, Clock, ClipboardList, CloudOff, Hand, LayoutDashboard, PackageCheck, Route, Siren, Star, Trophy, Users } from "lucide-react";
import type { LucideIcon } from "lucide-react";
import { supabase } from "@/lib/supabase/client";
import { CabecaPagina } from "@/features/ui/CabecaPagina";
import { moeda } from "@/features/precos/estrategias";

type Painel = {
  pedidos_hoje: number; para_revisar: number; rotas_ativas: number; rotas_esperando: number; sem_motoboy: number; concluidas_hoje: number;
  faturamento_hoje: number; gestao_hoje: number; km_hoje: number; motoboys_online: number; motoboys_em_rota: number; emergencias: number; chamados: number;
  aguardando_confirmacao: number; nota_media_30d: number | null; notas_ruins_hoje: number; por_hora: { hora: number; rotas: number }[]; top_motoboys: { nome: string; rotas: number }[];
  canceladas_hoje?: number; entregas_hoje?: number; tempo_medio_min?: number | null; pagar_motoboys_hoje?: number; ontem_concluidas?: number; hora_agora?: number;
  em_andamento?: { id: string; numero: number; motoboy: string; status: string; feitas: number; total: number }[];
};

/** Barras por hora em SVG: rótulos que não quebram, valor em cima e a hora de agora marcada. */
function GraficoHoras({ por, agora }: { por: { hora: number; rotas: number }[]; agora: number }) {
  const mapa = new Map(por.map((x) => [x.hora, x.rotas]));
  const horasCom = por.map((x) => x.hora);
  const ini = Math.max(0, Math.min(7, ...horasCom));
  const fim = Math.min(23, Math.max(agora, ini + 5, ...horasCom));
  const n = fim - ini + 1;
  const max = Math.max(1, ...por.map((x) => x.rotas));
  const W = 600, H = 170, base = H - 22, topo = 18, passo = W / n, larg = Math.min(26, passo * 0.62);
  const cada = n > 12 ? 2 : 1;
  return (
    <svg viewBox={`0 0 ${W} ${H}`} className="painel-grafico" role="img" aria-label="Rotas concluídas por hora do dia">
      <line x1={0} x2={W} y1={base} y2={base} className="g-base" />
      {Array.from({ length: n }, (_, k) => {
        const h = ini + k, v = mapa.get(h) ?? 0, cx = passo * k + passo / 2;
        const alt = v === 0 ? 2 : Math.max(5, ((base - topo) * v) / max);
        return (
          <g key={h}>
            <title>{`${h}h: ${v} rota${v === 1 ? "" : "s"}`}</title>
            <rect x={cx - larg / 2} y={base - alt} width={larg} height={alt} rx={5} className={h === agora ? "g-agora" : v ? "g-barra" : "g-vazia"} />
            {v > 0 && <text x={cx} y={base - alt - 5} textAnchor="middle" className="g-valor">{v}</text>}
            {(k % cada === 0 || h === agora) && <text x={cx} y={H - 4} textAnchor="middle" className={h === agora ? "g-hora atual" : "g-hora"}>{h}h</text>}
          </g>
        );
      })}
    </svg>
  );
}

function comparaOntem(p: Painel) {
  const o = p.ontem_concluidas ?? 0, d = p.concluidas_hoje - o;
  if (!o && !p.concluidas_hoje) return "nenhuma ainda";
  return d >= 0 ? `+${d} que ontem a esta hora` : `${d} que ontem a esta hora`;
}

function Numero({ icone: Ic, rotulo, valor, dica }: { icone: LucideIcon; rotulo: string; valor: number | string; dica: string }) {
  return (
    <div className="painel-numero">
      <span className="rotulo"><Ic size={12} aria-hidden /> {rotulo}</span>
      <strong className="figura">{valor}</strong>
      <span className="dica">{dica}</span>
    </div>
  );
}

/** Como está o dia: números que importam agora e o que precisa de você. */
export function PainelDoDia() {
  const [p, setP] = useState<Painel | null>(null);
  const [erro, setErro] = useState<string | null>(null);
  useEffect(() => {
    let vivo = true;
    const buscar = async () => {
      const { data, error } = await supabase().rpc("painel_do_dia");
      if (!vivo) return;
      if (error) setErro("Não deu para carregar o painel agora."); else { setP(data as Painel); setErro(null); }
    };
    void buscar();
    const t = setInterval(buscar, 30_000);
    return () => { vivo = false; clearInterval(t); };
  }, []);

  const alertas = p ? [
    p.emergencias > 0 && { icone: Siren, texto: `${p.emergencias} emergência${p.emergencias > 1 ? "s" : ""} aberta${p.emergencias > 1 ? "s" : ""}`, href: "/gestor/mapa", forte: true },
    p.chamados > 0 && { icone: Hand, texto: `${p.chamados} pedido${p.chamados > 1 ? "s" : ""} de motoboy esperando resposta`, href: "/gestor/corridas", forte: true },
    p.sem_motoboy > 0 && { icone: AlertTriangle, texto: `${p.sem_motoboy} rota${p.sem_motoboy > 1 ? "s" : ""} sem motoboy`, href: "/gestor/corridas", forte: false },
    p.para_revisar > 0 && { icone: ClipboardList, texto: `${p.para_revisar} pedido${p.para_revisar > 1 ? "s" : ""} para revisar`, href: "/gestor/pedidos", forte: false },
    p.aguardando_confirmacao > 0 && { icone: CloudOff, texto: `${p.aguardando_confirmacao} rota${p.aguardando_confirmacao > 1 ? "s" : ""} fechada${p.aguardando_confirmacao > 1 ? "s" : ""} sem sinal, aguardando confirmação`, href: "/gestor/corridas", forte: false },
    p.notas_ruins_hoje > 0 && { icone: Star, texto: `${p.notas_ruins_hoje} avaliação${p.notas_ruins_hoje > 1 ? "ões" : ""} ruim hoje`, href: "/gestor/corridas", forte: false },
  ].filter(Boolean) as { icone: typeof Siren; texto: string; href: string; forte: boolean }[] : [];
  return (
    <section className="conteudo painel-dia">
      <CabecaPagina icone={LayoutDashboard} titulo="Hoje" subtitulo={new Date().toLocaleDateString("pt-BR", { weekday: "long", day: "2-digit", month: "long" })} />
      {erro && <p className="erro">{erro}</p>}
      {!p && !erro && <p className="dica">Carregando…</p>}
      {p && <>
        {alertas.length > 0 ? (
          <div className="painel-alertas">
            {alertas.map((a) => (
              <Link key={a.texto} href={a.href} className={`painel-alerta${a.forte ? " forte" : ""}`}><a.icone size={16} aria-hidden /> {a.texto}</Link>
            ))}
          </div>
        ) : <p className="painel-tranquilo">Nada esperando por você agora.</p>}

        <div className="painel-numeros">
          <div className="painel-numero destaque">
            <span className="rotulo"><CircleDollarSign size={12} aria-hidden /> Faturado hoje</span>
            <strong className="figura texto-grad">{moeda(p.faturamento_hoje)}</strong>
            <div className="painel-mini">
              <span><small>Empresa</small><b>{moeda(p.gestao_hoje)}</b></span>
              <span><small>Motoboys</small><b>{moeda(p.pagar_motoboys_hoje ?? 0)}</b></span>
              <span><small>Rodado</small><b>{p.km_hoje.toLocaleString("pt-BR")} km</b></span>
            </div>
          </div>
          <Numero icone={Route} rotulo="Rotas feitas" valor={p.concluidas_hoje} dica={comparaOntem(p)} />
          <Numero icone={PackageCheck} rotulo="Entregas" valor={p.entregas_hoje ?? "—"} dica={`${p.canceladas_hoje ?? 0} rota(s) cancelada(s)`} />
          <Numero icone={Bike} rotulo="Na rua" valor={p.rotas_ativas} dica={`${p.rotas_esperando} esperando motoboy`} />
          <Numero icone={Users} rotulo="Motoboys" valor={p.motoboys_online} dica={`online · ${p.motoboys_em_rota} em rota`} />
          <Numero icone={ClipboardList} rotulo="Pedidos" valor={p.pedidos_hoje} dica={`${p.para_revisar} para revisar`} />
          <Numero icone={Clock} rotulo="Tempo médio" valor={p.tempo_medio_min != null ? `${p.tempo_medio_min} min` : "—"} dica="do aceite à conclusão" />
          <Numero icone={Star} rotulo="Nota (30 dias)" valor={p.nota_media_30d != null ? p.nota_media_30d.toLocaleString("pt-BR") : "—"} dica={p.nota_media_30d != null ? "média das avaliações" : "sem avaliações ainda"} />
        </div>

        <div className="painel-linha">
          <div className="bloco painel-horas">
            <div className="painel-cabeca-bloco">
              <span className="rotulo">Rotas concluídas por hora</span>
              {(() => { const pico = [...p.por_hora].sort((a, b) => b.rotas - a.rotas)[0]; return pico && pico.rotas > 0 ? <span className="dica">Pico às {pico.hora}h ({pico.rotas})</span> : null; })()}
            </div>
            <GraficoHoras por={p.por_hora} agora={p.hora_agora ?? new Date().getHours()} />
          </div>
          <div className="bloco painel-top">
            <span className="rotulo"><Trophy size={12} aria-hidden /> Quem mais entregou hoje</span>
            {p.top_motoboys.length ? <ol>{p.top_motoboys.map((m) => {
              const max = Math.max(1, ...p.top_motoboys.map((x) => x.rotas));
              return <li key={m.nome}><span>{m.nome}</span><i><em style={{ width: `${(m.rotas / max) * 100}%` }} /></i><strong>{m.rotas}</strong></li>;
            })}</ol> : <p className="dica">Nenhuma rota concluída ainda.</p>}
          </div>
        </div>

        {(p.em_andamento ?? []).length > 0 && (
          <div className="bloco painel-rua">
            <span className="rotulo"><Bike size={12} aria-hidden /> Na rua agora</span>
            <ul>{p.em_andamento!.map((r) => (
              <li key={r.id}><Link href={`/gestor/corridas?c=${r.id}`}><b>#{r.numero}</b><span>{r.motoboy || "Motoboy"}</span>
                <i><em style={{ width: `${(r.feitas / Math.max(1, r.total)) * 100}%` }} /></i><small>{r.feitas} de {r.total} paradas</small></Link></li>
            ))}</ul>
          </div>
        )}
      </>}
    </section>
  );
}

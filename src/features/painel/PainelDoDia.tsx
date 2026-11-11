"use client";

import { useEffect, useState } from "react";
import Link from "next/link";
import { AlertTriangle, Bike, CircleDollarSign, ClipboardList, CloudOff, Hand, LayoutDashboard, Route, Siren, Star, Trophy } from "lucide-react";
import { supabase } from "@/lib/supabase/client";
import { CabecaPagina } from "@/features/ui/CabecaPagina";
import { moeda } from "@/features/precos/estrategias";

type Painel = {
  pedidos_hoje: number; para_revisar: number; rotas_ativas: number; rotas_esperando: number; sem_motoboy: number; concluidas_hoje: number;
  faturamento_hoje: number; gestao_hoje: number; km_hoje: number; motoboys_online: number; motoboys_em_rota: number; emergencias: number; chamados: number;
  aguardando_confirmacao: number; nota_media_30d: number | null; notas_ruins_hoje: number; por_hora: { hora: number; rotas: number }[]; top_motoboys: { nome: string; rotas: number }[];
};

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
  const maxHora = Math.max(1, ...(p?.por_hora ?? []).map((h) => h.rotas));
  const horas = Array.from({ length: 24 }, (_, h) => ({ h, n: p?.por_hora.find((x) => x.hora === h)?.rotas ?? 0 })).slice(6, 24);

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
            <span className="dica">{moeda(p.gestao_hoje)} para a empresa · {p.km_hoje.toLocaleString("pt-BR")} km</span>
          </div>
          <div className="painel-numero"><span className="rotulo"><Route size={12} aria-hidden /> Rotas</span><strong className="figura">{p.concluidas_hoje}</strong>
            <span className="dica">concluídas · {p.rotas_ativas} em andamento · {p.rotas_esperando} esperando</span></div>
          <div className="painel-numero"><span className="rotulo"><Bike size={12} aria-hidden /> Motoboys</span><strong className="figura">{p.motoboys_online}</strong>
            <span className="dica">online · {p.motoboys_em_rota} em rota</span></div>
          <div className="painel-numero"><span className="rotulo"><ClipboardList size={12} aria-hidden /> Pedidos</span><strong className="figura">{p.pedidos_hoje}</strong>
            <span className="dica">hoje · {p.para_revisar} para revisar</span></div>
          <div className="painel-numero"><span className="rotulo"><Star size={12} aria-hidden /> Nota (30 dias)</span><strong className="figura">{p.nota_media_30d != null ? p.nota_media_30d.toLocaleString("pt-BR") : "—"}</strong>
            <span className="dica">{p.nota_media_30d != null ? "média das avaliações" : "sem avaliações ainda"}</span></div>
        </div>

        <div className="painel-linha">
          <div className="bloco painel-horas">
            <span className="rotulo">Rotas concluídas por hora</span>
            <div className="painel-barras" role="img" aria-label="Rotas concluídas por hora do dia">
              {horas.map((x) => (
                <div key={x.h} className="painel-barra" title={`${x.h}h: ${x.n} rota${x.n === 1 ? "" : "s"}`}>
                  <i style={{ height: `${(x.n / maxHora) * 100}%` }} />
                  <small>{x.h % 3 === 0 ? `${x.h}h` : ""}</small>
                </div>
              ))}
            </div>
          </div>
          <div className="bloco painel-top">
            <span className="rotulo"><Trophy size={12} aria-hidden /> Quem mais entregou hoje</span>
            {p.top_motoboys.length ? <ol>{p.top_motoboys.map((m) => <li key={m.nome}><span>{m.nome}</span><strong>{m.rotas}</strong></li>)}</ol> : <p className="dica">Nenhuma rota concluída ainda.</p>}
          </div>
        </div>
      </>}
    </section>
  );
}

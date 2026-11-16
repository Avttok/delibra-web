"use client";

import { AjustesRapidos } from "@/features/configuracoes/AjustesRapidos";
import { useEffect, useMemo, useState } from "react";
import { AlertTriangle, ArrowLeft, Bike, Building2, CalendarRange, Clock, ExternalLink, History, MapPin, Package, Receipt, Search, Star, WifiOff } from "lucide-react";
import Link from "next/link";
import { supabase } from "@/lib/supabase/client";
import { buscarPercursos } from "@/lib/mapa/percursos";
import { MapaCorridas, type PinoParada } from "./MapaCorridas";
import { Comprovante } from "./DetalheCorrida";
import { useEmpresas, useEquipe } from "./dados";
import { COR_CORRIDA, ROTULO_CORRIDA, ROTULO_PARADA, formatarKm, numeroCorrida, type StatusCorrida, type StatusParada } from "./tipos";
import { ROTULO_PEDIDO, moedaBr, type StatusPedido } from "@/features/pedidos/tipos";
import { nomeParada, nomeStatus } from "@/features/modalidades/rotulos";
import { useModoTeste } from "@/features/teste/modoTeste";

type ItemHist = {
  id: string; numero: number; status: StatusCorrida; teste: boolean; tipo_pedido: string | null; quando: string; criada_em: string; concluida_em: string | null;
  motoboy: string | null; cliente: string | null; pedidos: number[]; entregas: number; feitas: number; km: number; valor: number | null; valor_motoboy: number | null;
  minutos: number | null; problemas: number; nota: number | null;
};
type Parada = {
  id: string; ordem: number; tipo: "coleta" | "entrega"; endereco: string; lat: number; lng: number; status: StatusParada; recebedor_nome: string | null;
  foto_path: string | null; assinatura_path: string | null; respostas: Record<string, unknown> | null; chegou_em?: string | null; concluida_em: string | null;
  local_ignorado?: boolean; feita_offline?: boolean; distancia_chegada_m?: number | null; pedido_numero: number | null; cliente: string | null;
  contato_nome: string | null; itens: { descricao: string; quantidade: number; categoria: string | null }[];
};
type Ficha = {
  rota: Record<string, unknown> & { numero: number; teste: boolean; status: StatusCorrida; motoboy: string | null; cliente: string | null; rota_planejada?: string | null; tipo_pedido?: string | null;
    distancia_real_m: number | null; distancia_planejada_m: number | null; criada_em: string; aceita_em: string | null; concluida_em: string | null; cancelada_em: string | null; observacoes: string | null };
  paradas: Parada[];
  pedidos: { id: string; numero: number; status: StatusPedido; cliente: string | null; valor: number | null; pagamento: string; criado_em: string; observacoes: string | null; urgente: boolean;
    outras_rotas: { id: string; numero: number; status: StatusCorrida }[] }[];
  eventos: { tipo: string; dados: Record<string, unknown>; quando: string; autor: string | null }[];
  chamados: { tipo: string; status: string; motivo: string; resposta: string | null; criado_em: string }[];
  avaliacoes: { nota: number; comentario: string | null; autor: string; quando: string }[];
  ofertas: { motoboy: string | null; status: string; rodada: number; distancia_m: number | null; quando: string }[];
  pagamento: { valor: number | null; motoboy: number | null; gestao: number | null; ajuste: number | null; ajuste_motivo: string | null; calculo: { linhas?: { rotulo: string; valor: number }[] } | null };
};

const hoje = () => new Date().toISOString().slice(0, 10);
const diasAtras = (n: number) => new Date(Date.now() - n * 86_400_000).toISOString().slice(0, 10);
const dataHora = (s: string | null | undefined) => (s ? new Date(s).toLocaleString("pt-BR", { day: "2-digit", month: "2-digit", hour: "2-digit", minute: "2-digit" }) : "—");
const EVENTO: Record<string, string> = {
  criada: "Rota criada", oferta_expirada: "Oferta venceu", aceita: "Aceita", recusada: "Recusada", iniciada: "Saiu para a rota", chegou: "Chegou",
  concluida: "Concluída", cancelada: "Cancelada", parada_concluida: "Parada feita", pediu_pular: "Pediu para liberar", liberada: "Parada liberada",
  rota_atualizada: "Rota mudou", oferecida: "Oferecida", passada: "Passada para outro", confirmada_offline: "Confirmou o que fez sem internet",
};

/** Histórico de rotas: filtros à esquerda e, ao lado, tudo da rota (mapa com o percurso, paradas e comprovantes, pedidos, pagamento e linha do tempo). */
export function HistoricoRotas({ onVoltar, onAbrir }: { onVoltar: () => void; onAbrir: (id: string) => void }) {
  const { teste } = useModoTeste();
  const equipe = useEquipe();
  const { empresas } = useEmpresas();
  const [de, setDe] = useState(diasAtras(7));
  const [ate, setAte] = useState(hoje());
  const [motoboy, setMotoboy] = useState("");
  const [cliente, setCliente] = useState("");
  const [status, setStatus] = useState("concluida,cancelada");
  const [busca, setBusca] = useState("");
  const [lista, setLista] = useState<ItemHist[] | null>(null);
  const [sel, setSel] = useState<string | null>(null);
  useEffect(() => {
    let vivo = true;
    const t = setTimeout(async () => {
      const { data } = await supabase().rpc("historico_rotas", { p: { de, ate, motoboy: motoboy || null, cliente: cliente || null, status: status || null, busca: busca.trim() || null, teste } });
      if (vivo) setLista((data as ItemHist[] | null) ?? []);
    }, 300);
    return () => { vivo = false; clearTimeout(t); };
  }, [de, ate, motoboy, cliente, status, busca, teste]);
  const resumo = useMemo(() => {
    const l = lista ?? [];
    return { rotas: l.length, entregas: l.reduce((s, x) => s + x.feitas, 0), km: l.reduce((s, x) => s + Number(x.km ?? 0), 0), valor: l.reduce((s, x) => s + Number(x.valor ?? 0), 0) };
  }, [lista]);

  return (
    <>
      <aside className="lateral lateral-larga entrar">
        <button className="botao-texto" style={{ alignSelf: "flex-start" }} onClick={onVoltar}><ArrowLeft size={15} aria-hidden /> Rotas</button>
        <div className="lateral-cabecalho"><h2 className="display" style={{ margin: 0 }}><History size={18} aria-hidden /> Histórico de rotas</h2>
          <AjustesRapidos titulo="Ajustes do percurso e do pagamento" grupos={["percurso", "pagamento", "mb_ve", "avaliacoes"]} /></div>
        <section className="bloco hist-filtros">
          <div className="hist-datas">
            <label className="campo"><span><CalendarRange size={12} aria-hidden /> De</span><input type="date" value={de} max={ate} onChange={(e) => setDe(e.target.value)} /></label>
            <label className="campo"><span>Até</span><input type="date" value={ate} min={de} onChange={(e) => setAte(e.target.value)} /></label>
          </div>
          <div className="linha-chips">
            {[["Hoje", 0], ["7 dias", 7], ["30 dias", 30], ["90 dias", 90]].map(([r, n]) => (
              <button key={r} type="button" className={`chip${de === diasAtras(n as number) && ate === hoje() ? " ativo" : ""}`} onClick={() => { setDe(diasAtras(n as number)); setAte(hoje()); }}>{r}</button>
            ))}
          </div>
          <div className="hist-datas">
            <select value={motoboy} onChange={(e) => setMotoboy(e.target.value)} aria-label="Motoboy"><option value="">Todos os motoboys</option>{equipe.map((m) => <option key={m.id} value={m.id}>{m.nome}</option>)}</select>
            <select value={cliente} onChange={(e) => setCliente(e.target.value)} aria-label="Cliente"><option value="">Todos os clientes</option>{empresas.map((e) => <option key={e.id} value={e.id}>{e.nome}</option>)}</select>
          </div>
          <div className="linha-chips">
            {[["concluida,cancelada", "Encerradas"], ["concluida", "Concluídas"], ["cancelada", "Canceladas"], ["", "Todas"]].map(([v, r]) => (
              <button key={r} type="button" className={`chip${status === v ? " ativo" : ""}`} onClick={() => setStatus(v)}>{r}</button>
            ))}
          </div>
          <label className="busca-mini"><Search size={14} aria-hidden /><input placeholder="Nº da rota ou do pedido, endereço, quem recebeu…" value={busca} onChange={(e) => setBusca(e.target.value)} /></label>
        </section>
        <div className="hist-resumo">
          <div><strong>{resumo.rotas}</strong><span>rotas</span></div>
          <div><strong>{resumo.entregas}</strong><span>paradas feitas</span></div>
          <div><strong>{resumo.km.toLocaleString("pt-BR", { maximumFractionDigits: 1 })}</strong><span>km</span></div>
          <div><strong>{moedaBr(resumo.valor)}</strong><span>faturado</span></div>
        </div>
        {lista == null ? <p className="dica">Carregando…</p> : lista.length === 0 ? <p className="vazio">Nenhuma rota nesse período e filtro.</p> : (
          <ul className="hist-lista">
            {lista.map((x) => (
              <li key={x.id}>
                <button type="button" className={`hist-item${sel === x.id ? " ativo" : ""}`} onClick={() => setSel(x.id)}>
                  <span className="hist-linha1">
                    <strong>{numeroCorrida(x)}</strong>
                    <span className="selo" style={{ color: COR_CORRIDA[x.status] }}>{nomeStatus("rota", x.status, ROTULO_CORRIDA[x.status], x.tipo_pedido)}</span>
                    {x.problemas > 0 && <AlertTriangle size={13} aria-label="Teve ocorrência" style={{ color: "var(--vermelho)" }} />}
                    <span className="espaco" /><small>{dataHora(x.quando)}</small>
                  </span>
                  <span className="hist-linha2">{[x.motoboy, x.cliente].filter(Boolean).join(" · ") || "Sem motoboy"}</span>
                  <span className="hist-linha3">
                    {x.feitas}/{x.entregas} entrega{x.entregas === 1 ? "" : "s"} · {x.km.toLocaleString("pt-BR")} km{x.minutos != null && ` · ${x.minutos} min`}
                    {x.pedidos.length > 0 && ` · pedido ${x.pedidos.map((n) => `#${n}`).join(", ")}`}
                    {x.valor != null && <strong> · {moedaBr(Number(x.valor))}</strong>}
                    {x.nota != null && <> · <Star size={11} aria-hidden /> {x.nota}</>}
                  </span>
                </button>
              </li>
            ))}
          </ul>
        )}
      </aside>
      <main className="conteudo">
        {sel ? <FichaRota key={sel} id={sel} onAbrir={onAbrir} onTrocar={setSel} /> : (
          <div className="vazio vidro hist-vazio"><History size={28} aria-hidden /><p>Escolha uma rota na lista para ver tudo dela aqui: mapa com o percurso, paradas e comprovantes, pedidos, pagamento e o que aconteceu.</p></div>
        )}
      </main>
    </>
  );
}

function FichaRota({ id, onAbrir, onTrocar }: { id: string; onAbrir: (id: string) => void; onTrocar: (id: string) => void }) {
  const [f, setF] = useState<Ficha | null>(null);
  const [erro, setErro] = useState<string | null>(null);
  const [pedacos, setPedacos] = useState<[number, number][][]>([]);
  const [foco, setFoco] = useState<{ lat: number; lng: number; vez: number } | null>(null);
  useEffect(() => {
    void supabase().rpc("ficha_rota", { p_corrida: id }).then(({ data, error }) => (error ? setErro(error.message) : setF(data as Ficha)));
    void buscarPercursos({ corrida: id }).then((r) => setPedacos((r?.linhas ?? []).map((l) => l.map(([la, lo]) => [lo, la] as [number, number]))));
  }, [id]);
  const trilha = useMemo(() => pedacos.flat(), [pedacos]);
  if (erro) return <p className="erro">{erro}</p>;
  if (!f) return <p className="dica">Carregando a rota…</p>;
  const r = f.rota;
  const pinos: PinoParada[] = f.paradas.map((p) => ({ chave: p.id, lat: p.lat, lng: p.lng, tipo: p.tipo, rotulo: String(p.ordem + 1), concluida: p.status === "concluida" }));
  const planejada = typeof r.rota_planejada === "string" ? r.rota_planejada : null;
  const minutos = r.concluida_em && r.aceita_em ? Math.round((new Date(r.concluida_em).getTime() - new Date(r.aceita_em).getTime()) / 60000) : null;
  return (
    <div className="hist-ficha entrar">
      <section className="formulario vidro hist-cabeca">
        <div className="hist-linha1">
          <h2 className="display" style={{ margin: 0 }}>Rota {numeroCorrida(r)}</h2>
          <span className="selo" style={{ color: COR_CORRIDA[r.status] }}>{nomeStatus("rota", r.status, ROTULO_CORRIDA[r.status], r.tipo_pedido)}</span>
          <span className="espaco" />
          <button type="button" className="botao-vidro pequeno" onClick={() => onAbrir(id)}><ExternalLink size={13} aria-hidden /> Abrir para mexer</button>
        </div>
        <div className="resumo-rota">
          <div><span className="rotulo"><Bike size={11} aria-hidden /> Motoboy</span><strong>{r.motoboy ?? "—"}</strong></div>
          <div><span className="rotulo"><Building2 size={11} aria-hidden /> Cliente</span><strong>{r.cliente ?? (f.pedidos.map((p) => p.cliente).filter(Boolean).join(", ") || "—")}</strong></div>
          <div><span className="rotulo">Percurso</span><strong>{formatarKm(r.distancia_real_m ?? r.distancia_planejada_m)}</strong></div>
          <div><span className="rotulo"><Clock size={11} aria-hidden /> Tempo</span><strong>{minutos != null ? `${minutos} min` : "—"}</strong></div>
        </div>
        <p className="dica" style={{ margin: 0 }}>Criada {dataHora(r.criada_em)}{r.aceita_em && ` · aceita ${dataHora(r.aceita_em)}`}{r.concluida_em && ` · concluída ${dataHora(r.concluida_em)}`}{r.cancelada_em && ` · cancelada ${dataHora(r.cancelada_em)}`}</p>
        {r.observacoes && <p className="dica" style={{ margin: 0 }}>Observações: {r.observacoes}</p>}
      </section>

      <div className="pedido-mapa vidro hist-mapa">
        <MapaCorridas paradas={pinos} trilha={trilha} pedacos={pedacos} rotaPlanejada={planejada} enquadrar={id} foco={foco} caminhoAuto={false} />
      </div>

      <section className="formulario vidro">
        <h3 className="display" style={{ margin: 0 }}><MapPin size={17} aria-hidden /> Paradas</h3>
        <ol className="hist-paradas">
          {f.paradas.map((p) => (
            <li key={p.id} className={p.status === "concluida" ? "feita" : ""}>
              <button type="button" className="hist-parada-topo" onClick={() => setFoco({ lat: p.lat, lng: p.lng, vez: Date.now() })} title="Ver no mapa">
                <span className={`pino-mini ${p.tipo}`}>{p.ordem + 1}</span>
                <strong>{nomeParada(p.tipo, r.tipo_pedido)}</strong>
                <span className="dica">{ROTULO_PARADA[p.status]}{p.concluida_em && ` às ${new Date(p.concluida_em).toLocaleTimeString("pt-BR", { hour: "2-digit", minute: "2-digit" })}`}</span>
                {p.local_ignorado && <span className="selo" style={{ color: "var(--ouro)" }}>fora do raio</span>}
                {p.feita_offline && <span className="selo" style={{ color: "var(--texto-2)" }}><WifiOff size={10} aria-hidden /> sem internet</span>}
              </button>
              <div className="hist-parada-corpo">
                <span>{p.endereco}</span>
                {(p.pedido_numero || p.cliente) && <span className="dica">{p.pedido_numero ? `Pedido #${p.pedido_numero}` : ""}{p.cliente ? ` · ${p.cliente}` : ""}</span>}
                {p.itens.length > 0 && <span className="dica"><Package size={11} aria-hidden /> {p.itens.map((i) => `${i.quantidade}× ${i.descricao || i.categoria || "item"}`).join(", ")}</span>}
                {p.recebedor_nome && <span className="dica">{p.tipo === "coleta" ? "Entregou" : "Recebeu"}: {p.recebedor_nome}</span>}
                {p.respostas && Object.keys(p.respostas).length > 0 && (
                  <span className="dica">{Object.entries(p.respostas).filter(([, v]) => typeof v !== "string" || !String(v).includes("/")).map(([k, v]) => `${k.replace(/_/g, " ")}: ${typeof v === "boolean" ? (v ? "sim" : "não") : String(v)}`).join(" · ")}</span>
                )}
                {(p.foto_path || p.assinatura_path) && (
                  <div className="comprovantes">
                    {p.foto_path && <Comprovante caminho={p.foto_path} rotulo="Foto" />}
                    {p.assinatura_path && <Comprovante caminho={p.assinatura_path} rotulo="Assinatura" />}
                  </div>
                )}
              </div>
            </li>
          ))}
        </ol>
      </section>

      {f.pedidos.length > 0 && (
        <section className="formulario vidro">
          <h3 className="display" style={{ margin: 0 }}><Package size={17} aria-hidden /> Pedidos desta rota</h3>
          {f.pedidos.map((p) => (
            <div key={p.id} className="hist-pedido">
              <div className="hist-linha1">
                <strong>Pedido #{p.numero}</strong>
                <span className="selo">{nomeStatus("pedido", p.status, ROTULO_PEDIDO[p.status])}</span>
                {p.urgente && <span className="selo" style={{ color: "var(--vermelho)" }}>urgente</span>}
                <span className="espaco" />
                {p.valor != null && <strong>{moedaBr(Number(p.valor))}</strong>}
                <Link className="botao-texto pequeno" href={`/gestor/pedidos?p=${p.id}`}><ExternalLink size={12} aria-hidden /> Abrir</Link>
              </div>
              <span className="dica">{p.cliente ?? "Avulso"} · feito {dataHora(p.criado_em)} · pagamento {p.pagamento.replace(/_/g, " ")}</span>
              {p.observacoes && <span className="dica">{p.observacoes}</span>}
              {p.outras_rotas.length > 0 && (
                <span className="dica">Também passou pelas rotas: {p.outras_rotas.map((o) => (
                  <button key={o.id} type="button" className="link" onClick={() => onTrocar(o.id)}>{numeroCorrida({ numero: o.numero, teste: r.teste })}</button>
                ))}</span>
              )}
            </div>
          ))}
        </section>
      )}

      <div className="hist-duas">
        <section className="formulario vidro">
          <h3 className="display" style={{ margin: 0 }}><Receipt size={17} aria-hidden /> Valores</h3>
          <div className="orcamento">
            <div className="orcamento-linha"><span>Cliente paga</span><strong>{moedaBr(Number(f.pagamento.valor ?? 0))}</strong></div>
            {(f.pagamento.calculo?.linhas ?? []).map((l, i) => <div key={i} className="orcamento-linha pct"><span>{l.rotulo}</span><strong>{moedaBr(Number(l.valor))}</strong></div>)}
            {f.pagamento.ajuste ? <div className="orcamento-linha pct"><span>Ajuste{f.pagamento.ajuste_motivo ? ` (${f.pagamento.ajuste_motivo})` : ""}</span><strong>{moedaBr(Number(f.pagamento.ajuste))}</strong></div> : null}
            <div className="orcamento-linha"><span>Motoboy recebe</span><strong>{moedaBr(Number(f.pagamento.motoboy ?? 0))}</strong></div>
            <div className="orcamento-linha total"><span>Fica com a empresa</span><strong>{moedaBr(Number(f.pagamento.gestao ?? 0))}</strong></div>
          </div>
          {f.avaliacoes.length > 0 && <>
            <span className="rotulo"><Star size={11} aria-hidden /> Avaliações</span>
            {f.avaliacoes.map((a, i) => <span key={i} className="dica">{"★".repeat(a.nota)}{"☆".repeat(5 - a.nota)} · {a.autor === "cliente" ? "cliente" : "quem recebeu"}{a.comentario ? `: ${a.comentario}` : ""}</span>)}
          </>}
          {f.chamados.length > 0 && <>
            <span className="rotulo"><AlertTriangle size={11} aria-hidden /> Pedidos do motoboy</span>
            {f.chamados.map((h, i) => <span key={i} className="dica">{h.tipo === "pular" ? "Liberar parada" : "Cancelar"} · {h.status} · “{h.motivo}”{h.resposta ? ` → ${h.resposta}` : ""}</span>)}
          </>}
        </section>
        <section className="formulario vidro">
          <h3 className="display" style={{ margin: 0 }}><Clock size={17} aria-hidden /> O que aconteceu</h3>
          <ol className="linha-tempo">
            {f.eventos.map((e, i) => (
              <li key={i}><small>{dataHora(e.quando)}</small><span>{EVENTO[e.tipo] ?? e.tipo.replace(/_/g, " ")}{e.autor ? ` · ${e.autor}` : ""}
                {typeof e.dados?.motivo === "string" && e.dados.motivo ? ` · ${e.dados.motivo}` : ""}</span></li>
            ))}
            {f.ofertas.length > 0 && <li><small>Ofertas</small><span>{f.ofertas.map((o) => `${o.motoboy ?? "?"} (${o.status})`).join(", ")}</span></li>}
          </ol>
        </section>
      </div>
    </div>
  );
}

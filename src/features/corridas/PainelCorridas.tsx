"use client";

import { Idade } from "@/features/ui/Idade";

import { useEffect, useMemo, useState } from "react";
import { BadgeCheck, ArrowDownToLine, ArrowUpFromLine, Bike, Building2, CalendarClock, TriangleAlert, CheckSquare, Clock, FlaskConical, History, Megaphone, Plus, Route, Ruler, Search, Sparkles, Trash2, Users, X, Zap } from "lucide-react";
import { ExcluirCorridas } from "./ExcluirCorridas";
import { ApagarHistorico } from "./ApagarHistorico";
import { CabecaPagina } from "@/features/ui/CabecaPagina";
import { combina } from "@/features/ui/busca";
import { geo } from "@/features/geo";
import { moeda } from "@/features/precos/estrategias";
import { MapaCorridas } from "./MapaCorridas";
import { useConta } from "@/features/conta/conta";
import { NovaCorrida } from "./NovaCorrida";
import { DetalheCorrida } from "./DetalheCorrida";
import { nomeCliente, useCorridas, useEmpresas, useEquipe } from "./dados";
import { useModoTeste } from "@/features/teste/modoTeste";
import { ATIVAS, COR_CORRIDA, PLANEJADAS, ROTULO_CORRIDA, formatarKm, hora, numeroCorrida } from "./tipos";
import { formatarQuando, relativo } from "./planejadas";

type Visao = { tipo: "lista" } | { tipo: "nova" } | { tipo: "detalhe"; id: string };

export function PainelCorridas() {
  const { corridas: todasCorridas, ofertas, erro } = useCorridas();
  // modo teste: só corridas de teste; fora dele, só as reais
  const { teste } = useModoTeste();
  const corridas = useMemo(() => todasCorridas.filter((c) => c.teste === teste), [todasCorridas, teste]);
  const equipe = useEquipe();
  const { empresas } = useEmpresas();
  const [visao, setVisao] = useState<Visao>({ tipo: "lista" });
  // /gestor/corridas?c=<id> abre direto a rota (links vindos de Pedidos)
  useEffect(() => {
    const c = new URLSearchParams(window.location.search).get("c");
    if (c) setVisao({ tipo: "detalhe", id: c });
  }, []);
  const [filtro, setFiltro] = useState<"ativas" | "montadas" | "planejadas" | "concluidas" | "canceladas" | "todas">("ativas");
  const conta = useConta();
  const [selecionando, setSelecionando] = useState(false);
  const [marcadas, setMarcadas] = useState<string[]>([]);
  const [buscaRota, setBuscaRota] = useState("");
  // caminho de cada rota ativa: o planejado ou o calculado pelas paradas
  const [caminhosAtivos, setCaminhosAtivos] = useState<string[]>([]);
  const chaveAtivas = corridas.filter((c) => ATIVAS.includes(c.status)).map((c) => `${c.id}:${c.rota_planejada?.length ?? 0}`).join("|");
  useEffect(() => {
    let vivo = true;
    const ativas = corridas.filter((c) => ATIVAS.includes(c.status));
    Promise.all(ativas.map(async (c) => c.rota_planejada ?? (await geo.calcularRota(c.paradas.slice(0, 25).map((p) => ({ lat: p.lat, lng: p.lng }))).catch(() => null))?.polyline ?? null))
      .then((l) => { if (vivo) setCaminhosAtivos(l.filter((x): x is string => Boolean(x))); });
    return () => { vivo = false; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [chaveAtivas]);
  const [limpando, setLimpando] = useState(false);
  const [excluindo, setExcluindo] = useState(false);
  const alternar = (id: string) => setMarcadas((m) => (m.includes(id) ? m.filter((x) => x !== id) : [...m, id]));
  const sairSelecao = () => { setSelecionando(false); setMarcadas([]); };

  const planejadas = corridas.filter((c) => PLANEJADAS.includes(c.status))
    .sort((a, b) => new Date(a.agendada_para ?? 0).getTime() - new Date(b.agendada_para ?? 0).getTime());
  const montadas = corridas.filter((c) => c.status === "montada" || (c.status === "sem_motoboy"));
  const nome = (id: string | null) => equipe.find((m) => m.id === id)?.nome;
  const listaBase = filtro === "ativas" ? corridas.filter((c) => ATIVAS.includes(c.status))
    : filtro === "montadas" ? montadas
    : filtro === "planejadas" ? planejadas
    : filtro === "concluidas" ? corridas.filter((c) => c.status === "concluida")
    : filtro === "canceladas" ? corridas.filter((c) => c.status === "cancelada")
    : corridas;
  const lista = listaBase.filter((c) => combina(buscaRota, numeroCorrida(c), c.numero, nome(c.motoboy_id), (c as { motoboy_nome_arquivado?: string | null }).motoboy_nome_arquivado,
    c.cliente_nome, empresas.find((e) => e.id === c.empresa_id)?.nome, c.observacoes, c.paradas.map((p) => `${p.endereco} ${p.contato_nome ?? ""} ${p.recebedor_nome ?? ""}`).join(" ")));

  const pinosAtivos = useMemo(
    () => corridas.filter((c) => ATIVAS.includes(c.status)).flatMap((c) =>
      c.paradas.filter((p) => p.status !== "concluida").map((p) => ({
        chave: p.id, lat: p.lat, lng: p.lng, tipo: p.tipo, rotulo: numeroCorrida(c),
      }))),
    [corridas],
  );

  if (visao.tipo === "nova") {
    return <NovaCorrida onVoltar={() => setVisao({ tipo: "lista" })} onCriada={(id) => setVisao({ tipo: "detalhe", id })} />;
  }
  if (visao.tipo === "detalhe") {
    const corrida = todasCorridas.find((c) => c.id === visao.id);
    if (corrida) {
      return (
        <DetalheCorrida
          key={corrida.id}
          corrida={corrida}
          oferta={ofertas.find((o) => o.corrida_id === corrida.id)}
          onVoltar={() => setVisao({ tipo: "lista" })}
          onExcluida={() => setVisao({ tipo: "lista" })}
        />
      );
    }
  }

  return (
    <>
      <aside className="lateral lateral-larga entrar">
        <CabecaPagina icone={Route} titulo="Rotas" subtitulo={(() => { const n = corridas.filter((c) => ATIVAS.includes(c.status)).length; return `${n === 0 ? "Nenhuma ativa" : n === 1 ? "1 ativa" : `${n} ativas`} agora${teste ? " · modo teste" : ""}`; })()} />
        <div className="lateral-cabecalho">
          <span className="rotulo">Mostrar</span>
          <div className="filtro">
            {([["ativas", "Ativas"], ["montadas", "Esperando você"], ["planejadas", "Planejadas"], ["concluidas", "Concluídas"], ["canceladas", "Canceladas"], ["todas", "Todas"]] as const).map(([v, r]) => (
              <button key={v} className={filtro === v ? "ativo" : ""} onClick={() => setFiltro(v)}>
                {r}{v === "planejadas" && planejadas.length > 0 && <span className="contador">{planejadas.length}</span>}
                {v === "montadas" && montadas.length > 0 && <span className="contador">{montadas.length}</span>}
              </button>
            ))}
          </div>
        </div>
        <label className="busca-mini"><Search size={14} aria-hidden /><input placeholder="Nº, motoboy, cliente, endereço…" value={buscaRota} onChange={(e) => setBuscaRota(e.target.value)} /></label>
        <div className="linha-botoes">
          <button className="botao-ouro" style={{ flex: 1 }} onClick={() => setVisao({ tipo: "nova" })}><Plus size={17} aria-hidden /> Corrida avulsa</button>
          {conta.modulo("excluir_corridas") && <button className="botao-texto" onClick={() => (selecionando ? sairSelecao() : setSelecionando(true))} title="Selecionar para apagar">
            {selecionando ? <X size={16} aria-hidden /> : <CheckSquare size={16} aria-hidden />} {selecionando ? "Cancelar" : "Selecionar"}
          </button>}
          {conta.modulo("excluir_corridas") && !selecionando && <button className="botao-texto" onClick={() => setLimpando(true)} title="Apagar o histórico de todos">
            <History size={16} aria-hidden /> Histórico
          </button>}
        </div>
        {erro && <p className="erro">{erro}</p>}
        {lista.length === 0 && (filtro === "planejadas"
          ? <p className="vazio">Nenhuma corrida planejada. Em “Nova corrida”, escolha “Planejar” para marcar data e hora.</p>
          : filtro === "montadas" ? <p className="vazio">Nenhuma rota esperando você. As rotas montadas saem sozinhas, a não ser que a regra peça a sua revisão.</p>
          : <p className="vazio">Nenhuma rota {filtro === "ativas" ? "ativa" : filtro === "concluidas" ? "concluída" : filtro === "canceladas" ? "cancelada" : ""} nos últimos 30 dias.</p>)}
        {lista.map((c) => {
          const oferta = ofertas.find((o) => o.corrida_id === c.id);
          const coleta = c.paradas[0];
          const entregas = c.paradas.filter((p) => p.tipo === "entrega");
          return (
            <button key={c.id} className={`cartao-motoboy ${marcadas.includes(c.id) ? "marcado" : ""}`}
              onClick={() => (selecionando ? alternar(c.id) : setVisao({ tipo: "detalhe", id: c.id }))}>
              <div className="linha">
                {selecionando && <input type="checkbox" readOnly checked={marcadas.includes(c.id)} tabIndex={-1} style={{ pointerEvents: "none" }} />}
                <strong className="figura">{numeroCorrida(c)}</strong>
                <span className="selo" style={{ color: COR_CORRIDA[c.status] }}>{ROTULO_CORRIDA[c.status]}</span>
                {c.teste && <span className="selo" style={{ color: "var(--ouro)" }}><FlaskConical size={11} aria-hidden /> teste</span>}
                {(c as typeof c & { pagamento_status?: string | null }).pagamento_status === "pago" && <span className="selo selo-pago"><BadgeCheck size={11} aria-hidden /> PAGO</span>}
                {c.urgente && <span className="selo" style={{ color: "var(--vermelho)" }}><Zap size={11} aria-hidden /> urgente</span>}
                {c.origem === "roteirizador" && <span className="selo" style={{ color: "#a78bfa" }}><Sparkles size={11} aria-hidden /> auto</span>}
                {c.modo_despacho === "quadro" && !c.motoboy_id && c.status === "aguardando_motoboy" && <span className="selo" style={{ color: "var(--ouro-claro)" }}><Users size={11} aria-hidden /> quadro</span>}
                {c.status === "montada" && <span className="selo" style={{ color: "#a78bfa" }}><Megaphone size={11} aria-hidden /> liberar</span>}
                {c.tem_perigoso && <span className="selo" style={{ color: "var(--vermelho)" }}><FlaskConical size={11} aria-hidden /> perigoso</span>}
                <span className="espaco" />
                <span className="valor-lista">{moeda(c.valor)}</span>
              </div>
              {c.agendada_para && PLANEJADAS.includes(c.status) && (
                <div className={`quando-lista ${c.atraso_avisado_em ? "atrasada" : ""}`}>
                  {c.atraso_avisado_em ? <TriangleAlert size={13} aria-hidden /> : <CalendarClock size={13} aria-hidden />}
                  <strong>{formatarQuando(c.agendada_para)}</strong>
                  <span>{c.atraso_avisado_em ? "atrasada" : relativo(c.agendada_para)}</span>
                  <span className="espaco" />
                  <span className={c.motoboy_id ? "reservada-por" : "livre"}>{c.motoboy_id ? `Reservada · ${nome(c.motoboy_id) ?? "—"}` : "Livre para reservar"}</span>
                </div>
              )}
              <div className="trajeto-lista">
                <span><ArrowUpFromLine size={13} aria-hidden style={{ color: "var(--ouro)" }} /> {coleta?.endereco}</span>
                <span><ArrowDownToLine size={13} aria-hidden /> {entregas[entregas.length - 1]?.endereco}{entregas.length > 1 ? ` (+${entregas.length - 1})` : ""}</span>
              </div>
              <div className="detalhes">
                <span><Building2 size={12} aria-hidden /> {nomeCliente(c, empresas)}</span>
                <span><Clock size={12} aria-hidden /> {hora(c.criada_em)}</span>
                <Idade desde={c.criada_em} aberto={["montada", "aguardando_motoboy", "sem_motoboy"].includes(c.status)} />
                <span><Ruler size={12} aria-hidden /> {formatarKm(c.distancia_planejada_m)}</span>
                {entregas.length > 1 && <span><ArrowDownToLine size={12} aria-hidden /> {entregas.length} entregas</span>}
                {c.motoboy_id && !PLANEJADAS.includes(c.status) && <span><Bike size={12} aria-hidden /> {nome(c.motoboy_id)}</span>}
                {!c.motoboy_id && c.motoboy_nome_arquivado && <span><Bike size={12} aria-hidden /> {c.motoboy_nome_arquivado} (conta excluída)</span>}
                {oferta && <span>Enviada para {nome(oferta.motoboy_id)}</span>}
              </div>
            </button>
          );
        })}
        {selecionando && (
          <div className="barra-selecao vidro">
            <span style={{ flex: 1, fontSize: 13 }}>{marcadas.length} selecionada{marcadas.length === 1 ? "" : "s"}</span>
            <button className="botao-texto" onClick={() => setMarcadas(lista.filter((c) => !["aceita", "em_andamento", "reservada"].includes(c.status)).map((c) => c.id))}>Todas</button>
            <button className="botao-excluir" disabled={marcadas.length === 0} onClick={() => setExcluindo(true)}><Trash2 size={15} aria-hidden /> Apagar</button>
          </div>
        )}
        {limpando && <ApagarHistorico teste={teste} equipe={equipe} onFechar={() => setLimpando(false)} />}
        {excluindo && (
          <ExcluirCorridas
            corridas={corridas.filter((c) => marcadas.includes(c.id))}
            onFechar={() => setExcluindo(false)}
            onExcluidas={() => { setExcluindo(false); sairSelecao(); }}
          />
        )}
      </aside>
      <MapaCorridas maximizavel={false}
        paradas={pinosAtivos}
        rotas={caminhosAtivos}
        caminhoAuto={false}
        motoboys={equipe.filter((m) => m.status !== "offline" && m.lat != null && m.lng != null && m.modo_teste === teste)
          .map((m) => ({ id: m.id, nome: m.nome, lat: m.lat!, lng: m.lng!, status: m.status, foto: m.foto }))}
        enquadrar={String(pinosAtivos.length)}
      />
    </>
  );
}

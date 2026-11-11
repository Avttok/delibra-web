"use client";

import { BotaoCompartilhar } from "@/features/chat/PaginaChat";
import { ChamadosDaCorrida } from "@/features/penalidades/Chamados";
import { useEffect, useMemo, useState } from "react";
import { ArrowLeft, CheckCircle2, FlaskConical, Landmark, MapPinned, Route, Trash2, XCircle } from "lucide-react";
import { ExcluirCorridas } from "./ExcluirCorridas";
import { PassarCorrida } from "./PassarCorrida";
import { CabecaPagina } from "@/features/ui/CabecaPagina";
import { supabase } from "@/lib/supabase/client";
import { decodificarPolyline } from "@/lib/geo/polyline";
import { buscarPercursos } from "@/lib/mapa/percursos";
import { SelosPonto, type OpcoesDoPonto } from "@/features/pedidos/OpcoesPonto";
import { PacotesPonto, pacotesDoPonto, type Pacote } from "@/features/pedidos/Pacotes";
import { moeda } from "@/features/precos/estrategias";
import { MapaCorridas } from "./MapaCorridas";
import { EditarPercurso, encaixarVia, type ViaPercurso } from "./EditarPercurso";
import { nomeCliente, traduzirErro, useEmpresas, useEquipe } from "./dados";
import { GestaoPlanejada } from "./GestaoPlanejada";
import { BlocoRota } from "./BlocoRota";
import { useConfiguracoes } from "@/features/configuracoes/useConfiguracoes";
import { useConta } from "@/features/conta/conta";
import { toast } from "@/features/ui/toast";
import {
  COR_CORRIDA, ROTULO_CORRIDA, ROTULO_PARADA, formatarDuracao, formatarKm, hora, numeroCorrida,
  type Corrida, type Evento, type Oferta,
} from "./tipos";

const ROTULO_EVENTO: Record<string, string> = {
  criada: "Corrida criada",
  oferta_enviada: "Corrida enviada ao motoboy",
  oferta_recusada: "Motoboy recusou",
  oferta_expirada: "Motoboy não respondeu a tempo",
  sem_motoboy: "Nenhum motoboy disponível",
  redespachada: "Novo despacho",
  aceita: "Aceita",
  chegou: "Chegou na parada",
  parada_concluida: "Parada concluída",
  concluida: "Corrida concluída",
  cancelada: "Cancelada",
  reservada: "Reservada",
  reserva_cancelada: "Reserva desfeita",
  reagendada: "Horário mudado",
  planejada_despachada: "Planejada foi para o despacho",
  planejada_atrasada: "Atrasada: não iniciada no horário",
  rota_montada: "Rota montada pelo sistema",
  rota_atualizada: "Entrega nova encaixada na rota",
  liberada: "Liberada para os motoboys",
  foi_para_o_quadro: "Foi para o quadro (todos veem)",
  entrega_movida: "Entrega movida para esta rota",
  pagamento_ajustado: "Pagamento do motoboy ajustado",
};

function useEventos(corridaId: string) {
  const [eventos, setEventos] = useState<Evento[]>([]);
  useEffect(() => {
    const sb = supabase();
    const carregar = () =>
      sb.from("eventos_corrida").select("*").eq("corrida_id", corridaId).order("criado_em")
        .then(({ data }) => data && setEventos(data as Evento[]));
    const canal = sb.channel(`eventos-${corridaId}`)
      .on("postgres_changes", { event: "INSERT", schema: "public", table: "eventos_corrida", filter: `corrida_id=eq.${corridaId}` }, carregar)
      .subscribe();
    carregar();
    return () => { sb.removeChannel(canal); };
  }, [corridaId]);
  return eventos;
}

/** Trilha real (o feito), traçada pelas ruas pelo servidor; ao vivo, os pings novos entram no fim. */
function useTrilha(corrida: Corrida, ativa: boolean) {
  const [pontos, setPontos] = useState<[number, number][]>([]);
  const compactada = corrida.trajeto;
  useEffect(() => {
    const sb = supabase();
    let vivo = true;
    async function carregar() {
      const r = await buscarPercursos({ corrida: corrida.id });
      if (!vivo) return;
      if (r && r.linha.length) { setPontos(r.linha.map(([la, lo]) => [lo, la] as [number, number])); return; }
      if (compactada) { setPontos(decodificarPolyline(compactada)); return; }
      const { data } = await sb.from("localizacoes").select("lat,lng,registrado_em").eq("corrida_id", corrida.id).order("registrado_em").limit(5000);
      if (vivo && data) setPontos(data.map((p) => [p.lng, p.lat] as [number, number]));
    }
    void carregar();
    // em andamento: retraça pelas ruas de tempos em tempos
    const refazer = ativa ? setInterval(() => void carregar(), 90_000) : undefined;
    const canal = sb.channel(`trilha-${corrida.id}`)
      .on("postgres_changes", { event: "INSERT", schema: "public", table: "localizacoes", filter: `corrida_id=eq.${corrida.id}` },
        (payload) => {
          const p = payload.new as { lat: number; lng: number };
          setPontos((l) => [...l, [p.lng, p.lat]]);
        })
      .subscribe();
    return () => { vivo = false; if (refazer) clearInterval(refazer); sb.removeChannel(canal); };
  }, [corrida.id, compactada, ativa]);
  return pontos;
}

function Comprovante({ caminho, rotulo }: { caminho: string; rotulo: string }) {
  const [url, setUrl] = useState<string | null>(null);
  useEffect(() => {
    supabase().storage.from("comprovantes").createSignedUrl(caminho, 3600).then(({ data }) => setUrl(data?.signedUrl ?? null));
  }, [caminho]);
  if (!url) return <span className="dica">Carregando {rotulo.toLowerCase()}…</span>;
  return (
    <a href={url} target="_blank" rel="noreferrer" className="comprovante">
      {/* eslint-disable-next-line @next/next/no-img-element */}
      <img src={url} alt={rotulo} />
      <span>{rotulo}</span>
    </a>
  );
}

/** Pacotes dos pedidos da rota (com o tipo, para os ícones). */
function usePacotes(pedidos: string[]): (Pacote & { pedido_id: string })[] {
  const chave = [...new Set(pedidos)].sort().join(",");
  const [itens, setItens] = useState<(Pacote & { pedido_id: string })[]>([]);
  useEffect(() => {
    if (!chave) { setItens([]); return; }
    let vivo = true;
    void supabase().from("pedido_itens").select("*, categorias_produto(nome, icone, perigoso, fragil)").in("pedido_id", chave.split(",")).then(({ data }) => {
      if (!vivo) return;
      setItens(((data ?? []) as (Pacote & { pedido_id: string; categorias_produto?: { nome: string; icone: string | null; perigoso: boolean; fragil: boolean } | null })[])
        .map(({ categorias_produto: k, ...i }) => ({ ...i, categoria: k?.nome, icone: k?.icone, perigoso: k?.perigoso, fragil: k?.fragil })));
    });
    return () => { vivo = false; };
  }, [chave]);
  return itens;
}

export function DetalheCorrida({ corrida, oferta, onVoltar, onExcluida }: { corrida: Corrida; oferta?: Oferta; onVoltar: () => void; onExcluida?: () => void }) {
  const [foco, setFoco] = useState<{ lat: number; lng: number; vez: number } | null>(null);
  const conta = useConta();
  const [excluindo, setExcluindo] = useState(false);
  const [editandoPercurso, setEditandoPercurso] = useState(false);
  const [vias, setVias] = useState<ViaPercurso[]>([]);
  const [percursoNovo, setPercursoNovo] = useState<string | null>(null);
  const [mapaCheio, setMapaCheio] = useState(false);
  const painelPercurso = (
    <EditarPercurso corridaId={corrida.id} paradas={[...corrida.paradas].sort((a, b) => a.ordem - b.ordem).map((p) => ({ lat: p.lat, lng: p.lng }))}
      vias={vias} setVias={setVias} onPolyline={setPercursoNovo} distanciaAntes={corrida.distancia_planejada_m}
      onFechar={() => { setEditandoPercurso(false); setVias([]); setPercursoNovo(null); }} />
  );
  const equipe = useEquipe();
  const { empresas } = useEmpresas();
  const cfg = useConfiguracoes();
  const eventos = useEventos(corrida.id);
  const [agora, setAgora] = useState(() => Date.now());
  const [erro, setErro] = useState<string | null>(null);
  const [motoboyRedespacho, setMotoboyRedespacho] = useState("");

  useEffect(() => {
    const t = setInterval(() => setAgora(Date.now()), 1000);
    return () => clearInterval(t);
  }, []);

  const nome = (id: string | null | undefined) => equipe.find((m) => m.id === id)?.nome ?? "Motoboy";
  const motoboy = equipe.find((m) => m.id === corrida.motoboy_id);
  const ativa = ["aceita", "em_andamento"].includes(corrida.status);
  const trilha = useTrilha(corrida, ativa);
  const pacotes = usePacotes(corrida.paradas.map((p) => p.pedido_id).filter((x): x is string => Boolean(x)));
  const pacotesDe = (p: (typeof corrida.paradas)[number]) => {
    if (!p.pedido_ponto_id || !p.pedido_id) return [];
    const doTipo = corrida.paradas.filter((y) => y.tipo === p.tipo && y.pedido_id === p.pedido_id).map((y) => y.pedido_ponto_id!).filter(Boolean);
    // na coleta: só o que vai para uma entrega desta rota
    const entregasDaRota = corrida.paradas.filter((y) => y.tipo === "entrega" && y.pedido_id === p.pedido_id).map((y) => y.pedido_ponto_id).filter(Boolean);
    const doPedido = pacotes.filter((i) => i.pedido_id === p.pedido_id && (p.tipo !== "coleta" || !i.entrega_id || entregasDaRota.includes(i.entrega_id)));
    return pacotesDoPonto(doPedido, { id: p.pedido_ponto_id, tipo: p.tipo }, doTipo);
  };

  const pinos = useMemo(
    () => corrida.paradas.map((p) => ({
      chave: p.id, lat: p.lat, lng: p.lng, tipo: p.tipo, rotulo: String(p.ordem + 1), concluida: p.status === "concluida",
    })),
    [corrida.paradas],
  );

  async function confirmarPagamento() {
    const { error } = await supabase().rpc("confirmar_pagamento", { p_corrida: corrida.id, p_metodo: corrida.pagamento_metodo ?? null });
    if (error) return toast(error.message.includes("nao_aguarda") ? "Essa corrida não está aguardando pagamento." : error.message, "erro");
    toast(corrida.agendada_para ? "Pago. A corrida planejada já aparece para os motoboys." : "Pago. A corrida foi para o despacho.", "ok", { titulo: "Pagamento confirmado" });
  }

  async function cancelar() {
    if (!confirm(`Cancelar a corrida ${numeroCorrida(corrida)}?`)) return;
    const { error } = await supabase().rpc("cancelar_corrida", { p_corrida: corrida.id, p_motivo: "Cancelada pelo gestor" });
    if (error) setErro(traduzirErro(error.message));
  }

  async function redespachar() {
    const { error } = await supabase().rpc("redespachar", { p_corrida: corrida.id, p_motoboy: motoboyRedespacho || null });
    if (error) setErro(traduzirErro(error.message));
  }

  const restante = oferta ? Math.max(0, Math.round((new Date(oferta.expira_em).getTime() - agora) / 1000)) : 0;

  return (
    <>
      <aside className="lateral lateral-larga entrar">
        <div className="lateral-cabecalho">
          <button className="botao-texto" onClick={onVoltar}><ArrowLeft size={15} aria-hidden /> Rotas</button>
          {corrida.teste && <span className="selo" style={{ color: "#a78bfa" }}><FlaskConical size={11} aria-hidden /> TESTE</span>}
        </div>
        <CabecaPagina icone={Route} titulo={`${corrida.origem === "roteirizador" ? "Rota" : "Corrida"} ${numeroCorrida(corrida)}`} subtitulo={`${nomeCliente(corrida, empresas)} · criada às ${hora(corrida.criada_em)}`} />
        <BotaoCompartilhar anexo={{ tipo: "rota", id: corrida.id, titulo: `${corrida.origem === "roteirizador" ? "Rota" : "Corrida"} ${numeroCorrida(corrida)}`, sub: `${nomeCliente(corrida, empresas)} · ${corrida.paradas.filter((p) => p.tipo === "entrega").length} entrega(s)` }} />

        {!["concluida", "cancelada"].includes(corrida.status) && corrida.paradas.length >= 2 && (editandoPercurso
          ? (mapaCheio ? <p className="dica">Editando na tela cheia do mapa.</p> : painelPercurso)
          : <button type="button" className="botao-texto" onClick={() => setEditandoPercurso(true)}><Route size={15} aria-hidden /> Editar percurso</button>)}

        <section className="bloco">
          <div className="status-grande display" style={{ color: COR_CORRIDA[corrida.status] }}>{ROTULO_CORRIDA[corrida.status]}</div>
          {oferta && (
            <p className="dica">Enviada para <strong>{nome(oferta.motoboy_id)}</strong> ({formatarKm(oferta.distancia_m)} da coleta) · responde em {restante}s</p>
          )}
          {!corrida.motoboy_id && corrida.motoboy_nome_arquivado && (
            <p className="pessoa"><span>Motoboy: <strong>{corrida.motoboy_nome_arquivado}</strong> <span className="dica">(conta excluída)</span></span></p>
          )}
          {corrida.motoboy_id && (
            <p className="pessoa">
              {motoboy?.foto
                // eslint-disable-next-line @next/next/no-img-element
                ? <img src={motoboy.foto} alt="" className="foto-mini" style={{ borderColor: "var(--ouro)" }} />
                : <span className="avatar grad" style={{ width: 26, height: 26, fontSize: 11 }}>{nome(corrida.motoboy_id).charAt(0)}</span>}
              <span>{corrida.status === "reservada" ? "Reservada para" : "Motoboy"}: <strong>{nome(corrida.motoboy_id)}</strong></span>
            </p>
          )}
          <ChamadosDaCorrida corridaId={corrida.id} comMotoboy={Boolean(corrida.motoboy_id) && ["aceita", "em_andamento", "reservada"].includes(corrida.status)} />
          {corrida.motoboy_id && ["aceita", "em_andamento"].includes(corrida.status) && !corrida.paradas.some((x) => x.tipo === "coleta" && x.status === "concluida")
            && cfg.passar_corrida_ligado !== false && <PassarCorrida corrida={corrida} equipe={equipe} />}
          <div className="numeros">
            <div><span className="rotulo">Valor</span><strong>{moeda(corrida.valor)}</strong></div>
            <div><span className="rotulo">Planejado</span><strong>{formatarKm(corrida.distancia_planejada_m)}</strong><small>{formatarDuracao(corrida.duracao_planejada_s)}</small></div>
            <div><span className="rotulo">Real</span><strong>{formatarKm(corrida.distancia_real_m)}</strong></div>
          </div>
          {(Number(corrida.fator_entrega) > 0 || Number(corrida.fator_coleta) > 0) && (
            <p className="acrescimo" style={{ margin: 0 }}>
              <span>
                Base {moeda(corrida.valor_base)}
                {Number(corrida.fator_entrega) > 0 && <> · percurso <strong>+{Number(corrida.fator_entrega).toLocaleString("pt-BR")}×</strong></>}
                {Number(corrida.fator_coleta) > 0 && <> · motoboy longe da coleta <strong>+{Number(corrida.fator_coleta).toLocaleString("pt-BR")}×</strong></>}
              </span>
            </p>
          )}
          {corrida.valor_motoboy != null && (
            <div className="numeros">
              <div><span className="rotulo">Motoboy{corrida.pag_calculo?.modo === "percentual" ? ` (${Number(corrida.repasse_pct)}%)` : ""}</span><strong>{moeda(corrida.valor_motoboy)}</strong></div>
              <div><span className="rotulo">Gestor</span><strong className="texto-grad">{moeda(Number(corrida.valor ?? 0) - Number(corrida.valor_motoboy ?? 0))}</strong></div>
              {conta.dev && Number(corrida.valor_dev) > 0 && <div><span className="rotulo">Plataforma ({Number(corrida.dev_pct)}%)</span><strong>{moeda(corrida.valor_dev ?? 0)}</strong></div>}
            </div>
          )}
          {corrida.status === "aguardando_pagamento" && (
            <div className="bloco alerta-bloco">
              <strong>Aguardando pagamento{corrida.pagamento_metodo ? ` · ${corrida.pagamento_metodo === "pix" ? "PIX" : "cartão"}` : ""}</strong>
              <span className="dica">Pedido feito pelo cliente. Só vai para os motoboys depois de pago.</span>
              <button className="botao-ouro" onClick={confirmarPagamento}><CheckCircle2 size={16} aria-hidden /> Confirmar pagamento</button>
            </div>
          )}
          <p className="dica" style={{ display: "flex", alignItems: "center", gap: 6 }}>
            <MapPinned size={13} aria-hidden />
            {corrida.exigir_no_local ? `Etapas exigem estar no local (raio de ${corrida.raio_chegada_m} m)` : "Etapas liberadas em qualquer lugar"}
          </p>
          {corrida.exige_codigo && corrida.codigo_entrega && (
            <p className="codigo">Código de entrega: <strong className="texto-grad">{corrida.codigo_entrega}</strong> <span className="dica">(passe para quem vai receber)</span></p>
          )}
        </section>

        <BlocoRota corrida={corrida} equipe={equipe} />

        {(corrida.status === "agendada" || corrida.status === "reservada") && (
          <GestaoPlanejada corrida={corrida} equipe={equipe} cfg={cfg} agora={agora} />
        )}

        {corrida.status === "sem_motoboy" && (
          <section className="bloco alerta-bloco">
            <span className="rotulo">Despachar de novo</span>
            <select value={motoboyRedespacho} onChange={(e) => setMotoboyRedespacho(e.target.value)}>
              <option value="">Mais próximo da coleta</option>
              {equipe.map((m) => <option key={m.id} value={m.id}>{m.nome}</option>)}
            </select>
            <button className="botao-ouro" onClick={redespachar}>Despachar</button>
          </section>
        )}

        <section className="bloco">
          <span className="rotulo">Paradas · clique para ver no mapa</span>
          {corrida.paradas.map((p) => (
            <div key={p.id} className={`parada-detalhe clicavel ${p.status}`} title="Ver no mapa" onClick={() => setFoco({ lat: p.lat, lng: p.lng, vez: Date.now() })}>
              <span className={`pino-mini ${p.tipo}`}>{p.ordem + 1}</span>
              <div className="parada-texto">
                <strong>{p.tipo === "coleta" ? "Coleta" : "Entrega"} · {ROTULO_PARADA[p.status]}{p.dist_rua_m != null && p.tipo === "entrega" ? <span className="dica"> · {formatarKm(p.dist_rua_m)} da coleta</span> : null}</strong>
                <span>{p.endereco}</span>
                {(p.contato_nome || p.contato_telefone) && <span className="dica">{p.contato_nome} {p.contato_telefone}</span>}
                {p.instrucoes && <span className="dica">{p.instrucoes}</span>}
                <PacotesPonto itens={pacotesDe(p)} />
                {(() => {
                  // o que esta parada exige: o que o cliente pediu no ponto ou, vazio, o padrão da rota (só nas entregas)
                  const x = p as typeof p & OpcoesDoPonto & { codigo?: string | null };
                  const ent = p.tipo === "entrega";
                  const ef = (v: boolean | null | undefined, r: boolean) => (v ?? (ent && r)) || null;
                  return <SelosPonto p={{ exige_foto: ef(x.exige_foto, corrida.exige_foto), exige_nome: ef(x.exige_nome, corrida.exige_nome), exige_assinatura: ef(x.exige_assinatura, corrida.exige_assinatura),
                    exige_codigo: ef(x.exige_codigo, corrida.exige_codigo), codigo: x.codigo ?? (ent ? corrida.codigo_entrega : null), janela_de: x.janela_de ?? undefined, janela_ate: x.janela_ate ?? undefined }} />;
                })()}
                {(p.referencias?.length ?? 0) > 0 && (
                  <span className="referencias-detalhe">
                    <Landmark size={12} aria-hidden /> {p.referencias!.map((r) => r.relacao ?? (r.nome + (r.distancia_m != null ? ` (${r.distancia_m} m)` : ""))).join(" · ")}
                  </span>
                )}
                {p.concluida_em && <span className="dica">Concluída às {hora(p.concluida_em)}</span>}
                {p.distancia_chegada_m != null && (
                  <span className="dica">Marcado a {p.distancia_chegada_m} m do endereço{p.local_ignorado ? " · localização ignorada (teste)" : ""}</span>
                )}
                {p.recebedor_nome && <span>Recebido por <strong>{p.recebedor_nome}</strong></span>}
                <div className="comprovantes">
                  {p.foto_path && <Comprovante caminho={p.foto_path} rotulo="Foto" />}
                  {p.assinatura_path && <Comprovante caminho={p.assinatura_path} rotulo="Assinatura" />}
                </div>
              </div>
            </div>
          ))}
        </section>

        {corrida.observacoes && (
          <section className="bloco"><span className="rotulo">Observações</span><p>{corrida.observacoes}</p></section>
        )}

        <section className="bloco">
          <span className="rotulo">Linha do tempo</span>
          <ol className="timeline">
            {eventos.map((e) => (
              <li key={e.id}>
                <span className="hora">{new Date(e.criado_em).toLocaleTimeString("pt-BR")}</span>
                <span>
                  {ROTULO_EVENTO[e.tipo] ?? e.tipo}
                  {typeof e.dados.motoboy_id === "string" && ` · ${nome(e.dados.motoboy_id)}`}
                  {typeof e.dados.parada === "number" && ` · parada ${e.dados.parada + 1}`}
                  {typeof e.dados.distancia_m === "number" && ` · a ${e.dados.distancia_m} m`}
                  {e.dados.local_ignorado === true && " · local ignorado"}
                </span>
              </li>
            ))}
          </ol>
        </section>

        {erro && <p className="erro">{erro}</p>}
        {!["concluida", "cancelada"].includes(corrida.status) && (
          <button className="botao-perigo" onClick={cancelar}><XCircle size={16} aria-hidden /> Cancelar corrida</button>
        )}
        {["aceita", "em_andamento"].includes(corrida.status) ? (
          <p className="dica">Para apagar esta corrida, cancele-a primeiro.</p>
        ) : conta.modulo("excluir_corridas") && (
          <button className="botao-texto" style={{ justifyContent: "center", color: "var(--vermelho)" }} onClick={() => setExcluindo(true)}>
            <Trash2 size={15} aria-hidden /> Apagar corrida
          </button>
        )}
        {excluindo && (
          <ExcluirCorridas corridas={[corrida]} onFechar={() => setExcluindo(false)} onExcluidas={() => { setExcluindo(false); (onExcluida ?? onVoltar)(); }} />
        )}
      </aside>

      <MapaCorridas
        titulo={`Rota #${corrida.numero}`}
        onCheio={setMapaCheio}
        painelCheio={editandoPercurso ? painelPercurso : undefined}
        paradas={pinos}
        rotaPlanejada={editandoPercurso && percursoNovo ? percursoNovo : corrida.rota_planejada}
        aoClicar={editandoPercurso ? (lat, lng) => setVias((v) => v.length >= 20 ? v : [...v, encaixarVia(lat, lng, [...corrida.paradas].sort((a, b) => a.ordem - b.ordem))]) : undefined}
        vias={editandoPercurso ? vias : undefined}
        onMoverVia={editandoPercurso ? (i, lat, lng) => setVias((v) => v.map((x, j) => j === i ? encaixarVia(lat, lng, [...corrida.paradas].sort((a, b) => a.ordem - b.ordem)) : x)) : undefined}
        onTirarVia={editandoPercurso ? (i) => setVias((v) => v.filter((_, j) => j !== i)) : undefined}
        onArrastarLinha={editandoPercurso ? (lat, lng) => setVias((v) => v.length >= 20 ? v : [...v, encaixarVia(lat, lng, [...corrida.paradas].sort((a, b) => a.ordem - b.ordem))]) : undefined}
        trilha={trilha}
        motoboys={ativa && motoboy?.lat != null && motoboy.lng != null
          ? [{ id: motoboy.id, nome: motoboy.nome, lat: motoboy.lat, lng: motoboy.lng, status: motoboy.status, foto: motoboy.foto }] : []}
        enquadrar={corrida.id}
        foco={foco}
        restanteDe={ativa && motoboy?.lat != null && motoboy.lng != null ? { lat: motoboy.lat, lng: motoboy.lng } : null}
      />
    </>
  );
}

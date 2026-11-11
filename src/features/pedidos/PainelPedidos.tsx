"use client";

import { PacotesPonto, pacotesDoPonto } from "./Pacotes";
import { BotaoCompartilhar } from "@/features/chat/PaginaChat";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import Link from "next/link";
import {
  Ban, CalendarClock, Check, CheckCircle2, CircleDollarSign, ClipboardList, FlaskConical, Package, PackagePlus, RefreshCw, Route, Search, Undo2, Wallet, X, Zap,
} from "lucide-react";
import { supabase } from "@/lib/supabase/client";
import { useEmpresas, useEquipe, useRecarregarAoMudar } from "@/features/corridas/dados";
import { MapaCorridas, type PinoParada } from "@/features/corridas/MapaCorridas";
import { buscarPercursos } from "@/lib/mapa/percursos";
import { SelosPonto, type OpcoesDoPonto } from "./OpcoesPonto";
import { EditarOrcamento } from "./EditarOrcamento";
import { OrcamentoNoMapa } from "./OrcamentoNoMapa";
import { RotasDoPedido } from "./RotasDoPedido";
import { useConfiguracoes } from "@/features/configuracoes/useConfiguracoes";
import { formatarKm } from "@/features/corridas/tipos";
import { useModoTeste } from "@/features/teste/modoTeste";
import { CabecaPagina } from "@/features/ui/CabecaPagina";
import { toast } from "@/features/ui/toast";
import { FormPedido, OrcamentoDetalhe } from "./FormPedido";
import { RegrasPedido } from "./RegrasPedido";
import { Dica } from "@/features/ui/Tour";
import { Icone } from "@/features/ui/icones";
import { COR_PEDIDO, ROTULO_PEDIDO, moedaBr, quando, traduzir, type Categoria, type Pedido, type StatusPedido } from "./tipos";

type Filtro = "revisar" | "andamento" | "entregues" | "fora" | "todos";
const FILTROS: { k: Filtro; rotulo: string; st: StatusPedido[] | null }[] = [
  { k: "revisar", rotulo: "Para revisar", st: ["recebido"] },
  { k: "andamento", rotulo: "Em andamento", st: ["aprovado", "roteirizado", "em_rota"] },
  { k: "entregues", rotulo: "Entregues", st: ["concluido"] },
  { k: "fora", rotulo: "Cancelados", st: ["cancelado", "recusado"] },
  { k: "todos", rotulo: "Todos", st: null },
];
const sem = (t: string) => t.normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase();

export function PainelPedidos() {
  const { teste } = useModoTeste();
  const { empresas } = useEmpresas();
  const [pedidos, setPedidos] = useState<Pedido[] | null>(null);
  const [rotas, setRotas] = useState<{ pedido_id: string; corrida_id: string; numero: number; status: string; motoboy?: string | null; motoboy_id?: string | null }[]>([]);
  const equipe = useEquipe();
  const equipeRef = useRef(equipe); equipeRef.current = equipe;
  const [categorias, setCategorias] = useState<Categoria[]>([]);
  const [filtro, setFiltro] = useState<Filtro>("revisar");
  const [busca, setBusca] = useState("");
  const [tipoF, setTipoF] = useState<"todos" | "agora" | "planejados" | "urgentes" | "pagamento">("todos");
  const [sel, setSel] = useState<string | null>(null);
  // link direto (ex.: cartão do chat): /gestor/pedidos?p=<id>
  useEffect(() => { const q = new URLSearchParams(window.location.search).get("p"); if (q) setSel(q); }, []);
  const [novo, setNovo] = useState(false);

  useRecarregarAoMudar(["pedidos", "pedido_pontos", "corridas"], async () => {
    const sb = supabase();
    const desde = new Date(Date.now() - 45 * 86400_000).toISOString();
    const [p, k] = await Promise.all([
      sb.from("pedidos").select("*, pedido_pontos(*), pedido_itens(*)").eq("teste", teste).or(`criado_em.gte.${desde},status.in.(recebido,aprovado,roteirizado,em_rota)`)
        .order("criado_em", { ascending: false }).limit(600),
      sb.from("categorias_produto").select("*"),
    ]);
    const lista = (p.data ?? []) as Pedido[];
    setPedidos(lista);
    setCategorias((k.data ?? []) as Categoria[]);
    const ids = lista.filter((x) => ["roteirizado", "em_rota", "concluido"].includes(x.status)).map((x) => x.id).slice(0, 300);
    if (ids.length) {
      const { data } = await sb.from("paradas").select("pedido_id, corrida_id, corridas(numero,status,motoboy_id,motoboy_nome_arquivado)").in("pedido_id", ids);
      setRotas(((data ?? []) as unknown as { pedido_id: string; corrida_id: string; corridas: { numero: number; status: string; motoboy_id: string | null; motoboy_nome_arquivado: string | null } }[])
        .map((r) => ({ pedido_id: r.pedido_id, corrida_id: r.corrida_id, numero: r.corridas?.numero, status: r.corridas?.status,
          motoboy_id: r.corridas?.motoboy_id ?? null,
          motoboy: equipeRef.current.find((m) => m.id === r.corridas?.motoboy_id)?.nome ?? r.corridas?.motoboy_nome_arquivado ?? null })));
    } else setRotas([]);
  }, `pedidos-${teste}`);

  const cliente = (p: Pedido) => (p.empresa_id ? empresas.find((e) => e.id === p.empresa_id)?.nome ?? "Cliente" : p.cliente_nome ? `${p.cliente_nome} (avulso)` : "Avulso");
  const termo = sem(busca.trim());
  const lista = useMemo(() => (pedidos ?? []).filter((p) => {
    const f = FILTROS.find((x) => x.k === filtro)!;
    if (f.st && !f.st.includes(p.status)) return false;
    if (tipoF === "agora" && p.tipo === "planejado") return false;
    if (tipoF === "planejados" && p.tipo !== "planejado") return false;
    if (tipoF === "urgentes" && !p.urgente) return false;
    if (tipoF === "pagamento" && !(p.cobranca === "pre_pago" && p.pagamento_status === "pendente")) return false;
    if (!termo) return true;
    const motoboys = rotas.filter((r) => r.pedido_id === p.id).map((r) => r.motoboy ?? "").join(" ");
    return termo.split(/\s+/).every((w) => sem(`${p.numero} ${cliente(p)} ${(p.pedido_pontos ?? []).map((x) => `${x.endereco} ${x.contato_nome ?? ""}`).join(" ")} ${(p.pedido_itens ?? []).map((i) => i.descricao).join(" ")} ${p.observacoes ?? ""} ${motoboys}`).includes(w));
  }), [pedidos, filtro, termo, tipoF, rotas]); // eslint-disable-line react-hooks/exhaustive-deps
  const contagem = (f: Filtro) => (pedidos ?? []).filter((p) => { const st = FILTROS.find((x) => x.k === f)!.st; return !st || st.includes(p.status); }).length;
  const atual = pedidos?.find((p) => p.id === sel) ?? null;

  if (novo) return <FormPedido onVoltar={() => setNovo(false)} onCriado={(id) => { setNovo(false); setSel(id); setFiltro("todos"); }} />;

  return (
    <>
      <aside className="lateral entrar">
        <CabecaPagina icone={ClipboardList} titulo="Pedidos" subtitulo={teste ? "Pedidos de teste" : `${contagem("revisar")} para revisar · ${contagem("andamento")} em andamento`} />
        <div className="linha-botoes">
          <button className="botao-ouro" onClick={() => setNovo(true)}><PackagePlus size={16} aria-hidden /> Novo pedido</button>
          <button className="botao-texto" title="Roda o roteirizador agora" onClick={async () => {
            const { data, error } = await supabase().rpc("roteirizar_agora", { p_teste: teste });
            toast(error ? traduzir(error.message) : data ? `${data} entrega(s) encaixadas em rotas.` : "Nada novo para montar.", error ? "erro" : "ok");
          }}><Route size={15} aria-hidden /> Montar rotas</button><Dica titulo="Montar rotas" texto="O roteirizador já roda sozinho a cada minuto. Este botão monta na hora, sem esperar o tempo de juntar pedidos Express." />
        </div>
        <label className="busca-mini"><Search size={14} aria-hidden /><input placeholder="Nº, cliente, endereço, item, motoboy…" value={busca} onChange={(e) => setBusca(e.target.value)} /></label>
        <div className="fichas-filtro">
          {([["todos", "Todos"], ["agora", "Agora"], ["planejados", "Planejados"], ["urgentes", "Urgentes"], ["pagamento", "Aguardando pagamento"]] as const).map(([k, r]) =>
            <button key={k} type="button" className={tipoF === k ? "ativo" : ""} onClick={() => setTipoF(k)}>{r}</button>)}
        </div>
        <div className="filtro filtro-rolavel">
          {FILTROS.map((f) => <button key={f.k} className={filtro === f.k ? "ativo" : ""} onClick={() => setFiltro(f.k)}>{f.rotulo}{f.k !== "todos" && contagem(f.k) > 0 && <span className="filtro-n">{contagem(f.k)}</span>}</button>)}
        </div>
        <div className="lista-pedidos">
          {pedidos == null ? <p className="dica">Carregando…</p> : lista.length === 0 ? <p className="vazio">{filtro === "revisar" ? "Nada para revisar. 🎉" : "Nenhum pedido aqui."}</p> : lista.map((p) => {
            const ent = (p.pedido_pontos ?? []).filter((x) => x.tipo === "entrega").length;
            return (
              <button key={p.id} className={`linha-pedido ${sel === p.id ? "ativo" : ""}`} onClick={() => setSel(p.id)}>
                <div className="linha-pedido-topo">
                  <strong>{p.teste ? "T" : "#"}{p.numero}</strong>
                  <span className="selo" style={{ color: COR_PEDIDO[p.status] }}>{ROTULO_PEDIDO[p.status]}</span>
                  {p.cobranca === "pre_pago" && p.pagamento_status === "pendente" && !["cancelado", "recusado", "concluido"].includes(p.status) && <span className="selo" style={{ color: "#38bdf8" }}>Aguardando pagamento</span>}
                  {p.tipo === "planejado" ? <CalendarClock size={13} aria-label="Planejado" /> : <Zap size={13} aria-label="Express" />}
                  {p.urgente && <span className="selo" style={{ color: "var(--vermelho)" }}>Urgente</span>}
                  {p.orcamento?.perigoso && <FlaskConical size={13} style={{ color: "var(--vermelho)" }} aria-label="Perigoso" />}
                  <span className="espaco" /><strong>{moedaBr(p.valor)}</strong>
                </div>
                <span className="linha-pedido-cliente">{cliente(p)}</span>
                <span className="dica">{p.tipo === "planejado" ? `Para ${quando(p.quando)}` : `Pedido ${quando(p.criado_em)}`} · {ent} entrega{ent === 1 ? "" : "s"}{p.origem === "cliente" ? " · pelo site" : ""}</span>
              </button>
            );
          })}
        </div>
      </aside>
      <main className="conteudo">
        {atual ? <DetalhePedido key={atual.id} p={atual} cliente={cliente(atual)} categorias={categorias} rotas={rotas.filter((r) => r.pedido_id === atual.id)} onFechar={() => setSel(null)} />
          : <div className="formulario vidro entrar"><p className="vazio">Escolha um pedido para ver, revisar e ajustar.</p></div>}
      </main>
    </>
  );
}

function DetalhePedido({ p, cliente, categorias, rotas, onFechar }: {
  p: Pedido; cliente: string; categorias: Categoria[]; rotas: { corrida_id: string; numero: number; status: string; motoboy_id?: string | null }[]; onFechar: () => void;
}) {
  const equipe = useEquipe();
  const cfg = useConfiguracoes();
  const [valor, setValor] = useState(String(p.valor ?? "").replace(".", ","));
  const [motivo, setMotivo] = useState(p.ajuste_motivo ?? "");
  const [ocupado, setOcupado] = useState(false);
  const [foco, setFoco] = useState<{ lat: number; lng: number; vez: number } | null>(null);
  const [regras, setRegras] = useState<Record<string, unknown>>((p as Pedido & { regras?: Record<string, unknown> }).regras ?? {});
  const pontos = [...(p.pedido_pontos ?? [])].sort((a, b) => a.ordem - b.ordem);
  const pinos: PinoParada[] = pontos.map((x, i) => ({ chave: x.id, lat: x.lat, lng: x.lng, tipo: x.tipo, rotulo: String(i + 1), concluida: x.status === "concluido" }));
  const unicas = [...new Map(rotas.map((r) => [r.corrida_id, r])).values()];
  // feito (trilha pelas ruas de cada rota deste pedido) e a fazer (do motoboy até o que falta)
  const [trilha, setTrilha] = useState<[number, number][]>([]);
  const idsRotas = unicas.map((r) => r.corrida_id).join(",");
  const emRota = unicas.find((r) => ["aceita", "em_andamento"].includes(r.status));
  useEffect(() => {
    if (!idsRotas) { setTrilha([]); return; }
    let vivo = true;
    async function carregar() {
      const partes = await Promise.all(idsRotas.split(",").map((id) => buscarPercursos({ corrida: id })));
      if (vivo) setTrilha(partes.flatMap((r) => (r?.linha ?? []).map(([la, lo]) => [lo, la] as [number, number])));
    }
    void carregar();
    const t = emRota ? setInterval(() => void carregar(), 60_000) : undefined;
    return () => { vivo = false; if (t) clearInterval(t); };
  }, [idsRotas, Boolean(emRota)]); // eslint-disable-line react-hooks/exhaustive-deps
  const motoEmRota = emRota?.motoboy_id ? equipe.find((m) => m.id === emRota.motoboy_id) : undefined;
  const valorNum = Number(valor.replace(",", "."));
  const mudouValor = Number.isFinite(valorNum) && valor.trim() !== "" && valorNum !== Number(p.valor);

  async function acao(a: "aprovar" | "ajustar" | "recusar" | "recalcular" | "voltar_revisao") {
    if (a === "recusar" && !confirm(`Recusar o pedido #${p.numero}?`)) return;
    if (a === "voltar_revisao" && !confirm(`Voltar o pedido #${p.numero} para a revisão? Ele sai das rotas (as que ficarem vazias são canceladas) e espera você aprovar de novo.`)) return;
    setOcupado(true);
    const { error } = await supabase().rpc("revisar_pedido", { p_pedido: p.id, p_acao: a, p_valor: (a === "aprovar" || a === "ajustar") && mudouValor ? valorNum : null, p_motivo: motivo || null });
    setOcupado(false);
    if (error) return toast(traduzir(error.message), "erro");
    const esperaPagamento = p.cobranca === "pre_pago" && p.pagamento_status === "pendente";
    toast(a === "aprovar" ? (esperaPagamento ? "Aprovado. Cliente pré-pago: a rota sai assim que você confirmar o pagamento." : "Aprovado: o roteirizador já está montando a rota.") : a === "recusar" ? "Pedido recusado." : a === "recalcular" ? "Orçamento refeito com as regras de agora."
      : a === "voltar_revisao" ? "Pedido de volta à revisão: ajuste as regras e aprove de novo." : "Valor ajustado.", "ok");
  }
  async function cancelar() {
    const m = prompt(`Cancelar o pedido #${p.numero}? Motivo (opcional):`);
    if (m === null) return;
    const { error } = await supabase().rpc("cancelar_pedido", { p_pedido: p.id, p_motivo: m || null });
    if (error) return toast(traduzir(error.message), "erro");
    toast("Pedido cancelado e retirado das rotas.", "ok");
  }
  async function pago(metodo: string) {
    const { error } = await supabase().rpc("confirmar_pagamento_pedido", { p_pedido: p.id, p_metodo: metodo });
    if (error) return toast(traduzir(error.message), "erro");
    toast("Pagamento confirmado: o pedido segue para as rotas.", "ok");
  }

  const finalizado = ["concluido", "cancelado", "recusado"].includes(p.status);
  return (
    <div className="pedido-detalhe entrar">
      <div className="formulario vidro">
        <div className="titulo-linha">
          <div>
            <h2 className="display" style={{ margin: 0 }}>Pedido {p.teste ? "T" : "#"}{p.numero}</h2>
            <p className="dica" style={{ margin: 0 }}>{cliente} · {p.tipo === "planejado" ? `planejado para ${quando(p.quando)}` : "express"} · criado {quando(p.criado_em)}{p.origem === "cliente" ? " pelo cliente" : ""}</p>
          </div>
          <span className="selo" style={{ color: COR_PEDIDO[p.status] }}>{ROTULO_PEDIDO[p.status]}</span>
          <button className="icone" aria-label="Fechar" onClick={onFechar}><X size={16} /></button>
        </div>
        {p.recusa_motivo && <p className="erro" style={{ margin: 0 }}>Recusado: {p.recusa_motivo}</p>}
        <div className="pedido-mapa-p"><MapaCorridas paradas={pinos} enquadrar={p.id} foco={foco} trilha={trilha}
          motoboys={motoEmRota?.lat != null && motoEmRota.lng != null ? [{ id: motoEmRota.id, nome: motoEmRota.nome, lat: motoEmRota.lat, lng: motoEmRota.lng, status: "em_corrida", foto: motoEmRota.foto }] : []}
          restanteDe={motoEmRota?.lat != null && motoEmRota.lng != null ? { lat: motoEmRota.lat, lng: motoEmRota.lng } : null} /></div>
        <ol className="pedido-pontos">
          {pontos.map((x, i) => {
            const idsTipo = pontos.filter((y) => y.tipo === x.tipo).map((y) => y.id);
            const itens = pacotesDoPonto((p.pedido_itens ?? []).map((it) => { const k = categorias.find((c) => c.id === it.categoria_id); return { ...it, categoria: k?.nome, icone: k?.icone, perigoso: k?.perigoso, fragil: (k as { fragil?: boolean } | undefined)?.fragil }; }), x, idsTipo);
            return (
              <li key={x.id} className={`clicavel${x.status === "concluido" ? " feita" : ""}`} title="Ver no mapa" onClick={() => setFoco({ lat: x.lat, lng: x.lng, vez: Date.now() })}>
                <span className={`pino-mini ${x.tipo}`}>{i + 1}</span>
                <div>
                  <strong>{x.tipo === "coleta" ? "Coleta" : "Entrega"}</strong> · {x.endereco}
                  <div className="dica">{[x.contato_nome, x.contato_telefone, x.instrucoes].filter(Boolean).join(" · ")}</div>
                  <PacotesPonto itens={itens} />
                  {x.concluido_em && <div className="dica"><CheckCircle2 size={12} aria-hidden /> {quando(x.concluido_em)}{x.recebedor_nome ? ` · ${x.recebedor_nome}` : ""}</div>}
                  <SelosPonto p={x as unknown as OpcoesDoPonto} />
                </div>
              </li>
            );
          })}
        </ol>
        {(p.pedido_itens ?? []).length > 0 && (
          <div className="dev-rolagem">
            <table className="tabela"><thead><tr><th>Item</th><th>Categoria</th><th>Qtd.</th><th>Peso</th><th>Medidas</th><th>Valor decl.</th></tr></thead>
              <tbody>{p.pedido_itens!.map((it) => {
                const k = categorias.find((c) => c.id === it.categoria_id);
                return (
                  <tr key={it.id}><td>{it.descricao}</td><td>{k ? <span className="pessoa"><Icone nome={k.icone} size={13} style={{ color: k.perigoso ? "var(--vermelho)" : "var(--ouro)" }} /> {k.nome}</span> : "—"}</td>
                    <td>{it.quantidade}</td><td>{it.peso_kg != null ? `${it.peso_kg} kg` : "—"}</td>
                    <td>{it.comprimento_cm ? `${it.comprimento_cm}×${it.largura_cm}×${it.altura_cm} cm` : "—"}</td><td>{moedaBr(it.valor_declarado)}</td></tr>
                );
              })}</tbody></table>
          </div>
        )}
        {p.observacoes && <p className="dica" style={{ margin: 0 }}>Obs.: {p.observacoes}</p>}
        {unicas.length > 0 && (
          <div className="linha-botoes">
            <span className="rotulo">Rotas</span>
            {unicas.map((r) => <Link key={r.corrida_id} href={`/gestor/corridas?c=${r.corrida_id}`} className="chip"><Route size={13} aria-hidden /> Rota #{r.numero}</Link>)}
            <BotaoCompartilhar anexo={{ tipo: "pedido", id: p.id, titulo: `Pedido ${p.teste ? "T" : "#"}${p.numero}`, sub: cliente }} />
          </div>
        )}
      </div>

      <div className="formulario vidro">
        <h3 className="display" style={{ margin: 0 }}><Wallet size={18} aria-hidden /> Cobrança</h3>
        {p.orcamento ? <EditarOrcamento key={JSON.stringify(p.orcamento.linhas)} pedidoId={p.id} orc={p.orcamento} bloqueado={["cancelado", "recusado"].includes(p.status)} /> : <p className="dica">Sem orçamento.</p>}
        {p.orcamento && pontos.length >= 2 && (
          <details className="avancado">
            <summary>Como chegou no valor, no mapa</summary>
            <OrcamentoNoMapa pontos={pontos.map((x) => ({ id: x.id, tipo: x.tipo, lat: x.lat, lng: x.lng }))}
              linhas={(p.orcamento.linhas ?? []) as { chave?: string; valor?: number }[]} trajeto={(p.orcamento as { trajeto?: string }).trajeto} />
          </details>
        )}
        <div className="pedido-valor">
          <label className="campo"><span>Valor final</span>
            <span className="passo-campo"><span className="unidade">R$</span><input inputMode="decimal" value={valor} disabled={p.status === "cancelado" || p.status === "recusado"} onChange={(e) => setValor(e.target.value)} /></span></label>
          <label className="campo" style={{ flex: 2 }}><span>Motivo do ajuste</span><input placeholder="Ex.: desconto de cliente fiel, volume a mais na coleta…" value={motivo} onChange={(e) => setMotivo(e.target.value)} /></label>
        </div>
        <p className="dica" style={{ margin: 0 }}>
          Calculado {moedaBr(p.valor_calculado)}{p.valor_ajuste ? ` · ajuste ${p.valor_ajuste > 0 ? "+" : ""}${moedaBr(p.valor_ajuste)}` : ""} · Dev {moedaBr(p.valor_dev)} ·
          {p.cobranca === "credito" ? (p.fatura_id ? " já na fatura" : " entra na próxima fatura") : p.pagamento_status === "pago" ? ` pago (${p.pagamento_metodo ?? ""})` : " pagamento antecipado pendente"}
        </p>
        {p.cobranca === "pre_pago" && p.pagamento_status === "pendente" && !finalizado && (
          <p className="alerta-pagamento">
            <Wallet size={15} aria-hidden /> Cliente pré-pago: {p.status === "recebido" ? "depois de aprovado, o pedido" : "o pedido"} só vira rota quando o pagamento for confirmado.
            Confirme abaixo (PIX ou cartão) ou ligue “Montar rota sem esperar o pagamento” nas regras deste pedido ou do cliente.
          </p>
        )}
        <div className="linha-botoes">
          {p.status === "recebido" && <button className="botao-ouro" disabled={ocupado} onClick={() => acao("aprovar")}><Check size={16} aria-hidden /> Aprovar{mudouValor ? " com o valor novo" : ""}</button>}
          {p.status !== "recebido" && p.status !== "cancelado" && p.status !== "recusado" && mudouValor && <button className="botao-ouro" disabled={ocupado} onClick={() => acao("ajustar")}><CircleDollarSign size={16} aria-hidden /> Salvar valor</button>}
          {!finalizado && <button className="botao-texto" disabled={ocupado} onClick={() => acao("recalcular")}><RefreshCw size={15} aria-hidden /> Recalcular</button>}
          {["aprovado", "roteirizado", "em_rota"].includes(p.status) && !pontos.some((x) => x.status === "concluido") &&
            <button className="botao-texto" disabled={ocupado} onClick={() => acao("voltar_revisao")} title="Desfaz a rota enquanto nenhuma coleta/entrega foi feita"><Undo2 size={15} aria-hidden /> Voltar à revisão</button>}
          {["aprovado", "roteirizado", "em_rota"].includes(p.status) && <Dica titulo="Voltar à revisão" texto="Tira o pedido das rotas (as que ficarem vazias são canceladas, e o motoboy é avisado) para você mudar valor ou regras e aprovar de novo. Só dá enquanto nenhuma coleta ou entrega foi feita." />}
          {p.cobranca === "pre_pago" && p.pagamento_status === "pendente" && !finalizado && <>
            <button className="botao-texto" onClick={() => pago("pix")}><Package size={15} aria-hidden /> PIX recebido</button>
            <button className="botao-texto" onClick={() => pago("cartao")}><Package size={15} aria-hidden /> Cartão recebido</button>
          </>}
          <span className="espaco" />
          {p.status === "recebido" && <button className="botao-perigo" disabled={ocupado} onClick={() => acao("recusar")}><Ban size={15} aria-hidden /> Recusar</button>}
          {!finalizado && p.status !== "recebido" && <button className="botao-perigo" onClick={cancelar}><X size={15} aria-hidden /> Cancelar</button>}
        </div>
        {!finalizado && p.status !== "recebido" && <SituacaoRota pedidoId={p.id} chave={`${p.status}|${p.pagamento_status}|${JSON.stringify(regras)}|${rotas.length}`} />}
        <p className="dica" style={{ margin: 0 }}>{formatarKm(p.distancia_estimada_m)} estimados · {(p.pedido_pontos ?? []).filter((x) => x.tipo === "entrega").length} entrega(s)</p>
      </div>
      {!["cancelado", "recusado"].includes(p.status) && (p.status !== "recebido" || cfg.revisao_previa_rotas !== false) && (
        <div className="formulario vidro">
          <RotasDoPedido pedidoId={p.id} status={p.status} chave={`${p.status}|${p.valor}|${JSON.stringify(regras)}|${rotas.map((r) => r.corrida_id + r.status).join()}`} />
        </div>
      )}
      {!finalizado && <RegrasPedido pedidoId={p.id} valor={regras} onMudar={setRegras} aberto={Object.keys(regras).length > 0} />}
    </div>
  );
}

/** Diz por que o pedido ainda não virou rota (ou em que pé a rota está) e deixa montar na hora */
function SituacaoRota({ pedidoId, chave }: { pedidoId: string; chave: string }) {
  const [sit, setSit] = useState<{ codigo: string; motivo: string | null } | null>(null);
  const [rodando, setRodando] = useState(false);
  const carregar = useCallback(async () => {
    const { data, error } = await supabase().rpc("situacao_rota", { p_pedido: pedidoId });
    if (error) { setSit(error.message.includes("situacao_rota") ? { codigo: "sem_migracao", motivo: "Rode a migração 20261110000004_situacao_rota.sql para ver aqui por que o pedido ainda não virou rota." } : { codigo: "erro", motivo: traduzir(error.message) }); return; }
    setSit(data as { codigo: string; motivo: string | null });
  }, [pedidoId]);
  useEffect(() => { void carregar(); const t = setInterval(carregar, 20000); return () => clearInterval(t); }, [carregar, chave]);
  async function montar() {
    setRodando(true);
    const { data, error } = await supabase().rpc("roteirizar_pedido", { p_pedido: pedidoId });
    setRodando(false);
    if (error) { setSit({ codigo: "erro", motivo: "O roteirizador deu erro: " + error.message }); return toast(error.message, "erro"); }
    setSit(data as { codigo: string; motivo: string | null });
    toast((data as { codigo: string }).codigo.startsWith("rota_") ? "Rota montada." : "Ainda sem rota: veja o motivo no pedido.", (data as { codigo: string }).codigo.startsWith("rota_") ? "ok" : "aviso");
  }
  if (!sit?.motivo) return null;
  const semRota = !sit.codigo.startsWith("rota_");
  return (
    <div className={`situacao-rota${semRota ? " parada" : ""}`}>
      <Route size={15} aria-hidden />
      <span>{sit.motivo}</span>
      {semRota && sit.codigo !== "sem_migracao" && <button className="botao-texto" disabled={rodando} onClick={montar}><RefreshCw size={14} aria-hidden /> {rodando ? "Montando…" : "Montar rota agora"}</button>}
    </div>
  );
}

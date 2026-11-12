"use client";

import { EmpresasCards, type EmpresaCard } from "./EmpresasCards";

import { useCallback, useEffect, useMemo, useState } from "react";
import { Pagar } from "@/features/pagamentos/Pagar";
import { comSessao } from "@/features/pagamentos/Recebimentos";
import {
  ArrowLeft, BadgeCheck, Bookmark, BookmarkPlus, Boxes, Building2, CalendarClock, CheckCircle2, Clock, CreditCard, FileText, FlaskConical, KeyRound, Lock, MapPinned, Package,
  PackagePlus, Plus, QrCode, Receipt, Truck, Undo2, UserRound, Wallet, X, Zap,
} from "lucide-react";
import { supabase } from "@/lib/supabase/client";
import { distanciasColetaEntrega, geo, type Referencia, type Rota } from "@/features/geo";
import { CampoEndereco } from "@/features/corridas/CampoEndereco";
import { CampoReferencias } from "@/features/corridas/CampoReferencias";
import { MapaCorridas, type PinoParada } from "@/features/corridas/MapaCorridas";
import { trilhaDoPedido } from "@/lib/mapa/trilhaPedido";
import { Dica, Tour, abrirTour, type PassoTour } from "@/features/ui/Tour";
import { Compass, LifeBuoy, MessagesSquare, Palette } from "lucide-react";
import { ESTILOS, useTema } from "@/features/tema/tema";
import { Chat } from "@/features/chat/Chat";
import { formatarDuracao, formatarKm } from "@/features/corridas/tipos";
import { paraCampo, sugestaoHorario } from "@/features/corridas/planejadas";
import { toast } from "@/features/ui/toast";
import { moedaBr, quando, traduzir, type Categoria, type Orcamento } from "@/features/pedidos/tipos";
import { ItensPedido, dadosDoObjeto, faltandoItens, itensParaEnvio, novoItem, type ItemForm, type ObjetoSalvo } from "@/features/pedidos/ItensPedido";
import { OpcoesPonto, SelosPonto, type Confirmacao, type OpcoesDoPonto } from "@/features/pedidos/OpcoesPonto";
import { PacotesPonto, pacotesDoPonto } from "@/features/pedidos/Pacotes";
import { ListaOrdenavel } from "@/features/ui/ListaOrdenavel";
import { Icone } from "@/features/ui/icones";
import { AvaliarPedido, BotaoRastreio } from "@/features/avaliacoes/Avaliacao";

// ------------------------------------------------------------------ dados

interface Conta {
  id: string; nome: string; tipo: "pj" | "pf"; documento: string | null; telefone: string | null; email: string | null;
  endereco: string | null; lat: number | null; lng: number | null; instrucoes_coleta: string | null;
  pode_express: boolean; ve_ao_vivo: boolean; cobranca: "credito" | "pre_pago"; fatura_ciclo: string; metodos: string[]; antecedencia_min: number;
  tipos_pedido: { chave: string; nome: string; descricao: string | null; icone?: string | null }[];
  categorias: Categoria[];
  em_aberto: number; icone?: string | null; teste?: boolean;
  pode_modelos?: boolean; pode_cancelar?: boolean; pode_avaliar?: boolean; pode_rastreio?: boolean; ve_nota_motoboy?: boolean; troca_senha?: boolean; categoria_obrigatoria?: boolean;
  /** Peças do lego do pedido sob medida (o gestor liga/desliga no geral e por cliente). */
  confirmacoes?: Partial<Record<Confirmacao, boolean>>; padrao_confirmacoes?: Partial<Record<Confirmacao, boolean>>;
  pode_janela?: boolean; pode_objetos?: boolean; modelo_horario?: boolean;
  /** Controles do gestor (geral e por cliente). */
  pode_agendar?: boolean; pode_urgente?: boolean; max_entregas?: number | null; max_coletas?: number | null; agendar_max_dias?: number | null;
  pode_ida_volta?: boolean; coleta_fixa?: boolean; pode_observacoes?: boolean; ve_faturas?: boolean; pode_chat?: boolean;
  pedido_de?: string | null; pedido_ate?: string | null; modo_distancia?: string;
  /** O que aparece da rota no mapa: feito, restante, motoboy, planejada, outras_paradas. */
  ve_rota?: string[];
}
interface Modelo { id: string; nome: string; icone: string | null; dados: DadosModelo; usos: number; usado_em: string | null }
interface DadosModelo {
  tipo_pedido?: string; urgente?: boolean; observacoes?: string;
  /** Agora ou agendado; agendado guarda a hora (HH:MM) e o próximo dia possível é usado ao carregar. */
  agendar?: boolean; hora?: string; metodo?: string;
  pontos?: Omit<Ponto, "chave">[]; itens?: Omit<ItemForm, "chave">[];
}
type StatusP = "recebido" | "aprovado" | "roteirizado" | "em_rota" | "concluido" | "cancelado" | "recusado";
interface PedidoC {
  id: string; numero: number; tipo: "express" | "planejado"; tipo_pedido: string; quando: string | null; urgente: boolean; status: StatusP; valor: number | null;
  orcamento: Orcamento | null; cobranca: "credito" | "pre_pago"; pagamento_status: string; pagamento_metodo: string | null; fatura_id: string | null;
  observacoes: string | null; recusa_motivo: string | null; criado_em: string; concluido_em: string | null; cancelado_em: string | null;
  pontos: ({ id: string; tipo: "coleta" | "entrega"; endereco: string; lat: number; lng: number; contato_nome: string | null; status: string; concluido_em: string | null; recebedor_nome: string | null; codigo?: string | null } & OpcoesDoPonto)[];
  itens: { id?: string; coleta_id?: string | null; entrega_id?: string | null; descricao: string; quantidade: number; peso_kg: number | null; categoria: string | null; categoria_id?: string | null; icone?: string | null; perigoso: boolean }[];
  motoboys: string[]; codigos: string[];
}
interface FaturaC {
  id: string; numero: number; inicio: string; fim: string; status: "emitida" | "paga"; subtotal: number; ajuste: number; ajuste_motivo: string | null; total: number;
  vencimento: string | null; emitida_em: string | null; paga_em: string | null; pedidos: { numero: number; concluido_em: string; valor: number; entregas: number }[];
}

const STATUS: Record<StatusP, { rotulo: string; cor: string; dica: string }> = {
  recebido: { rotulo: "Recebido", cor: "#f59e0b", dica: "A empresa está conferindo o seu pedido." },
  aprovado: { rotulo: "Confirmado", cor: "#60a5fa", dica: "Confirmado. Estamos montando a rota." },
  roteirizado: { rotulo: "Em preparação", cor: "#a78bfa", dica: "A rota está pronta e um motoboy vai pegar." },
  em_rota: { rotulo: "A caminho", cor: "var(--ouro)", dica: "Um motoboy está com o seu pedido." },
  concluido: { rotulo: "Entregue", cor: "#2ecc71", dica: "Tudo entregue." },
  cancelado: { rotulo: "Cancelado", cor: "#8a8a8a", dica: "Pedido cancelado." },
  recusado: { rotulo: "Não aceito", cor: "#e5484d", dica: "A empresa não pôde aceitar este pedido." },
};
const ATIVOS: StatusP[] = ["recebido", "aprovado", "roteirizado", "em_rota"];
const CICLO: Record<string, string> = { diario: "todo dia", semanal: "toda semana", quinzenal: "a cada 15 dias", mensal: "todo mês", manual: "quando combinado" };
const dataBr = (d: string | null) => (d ? new Date(`${d.slice(0, 10)}T12:00:00`).toLocaleDateString("pt-BR") : "—");

type Aba = "pedidos" | "novo" | "faturas" | "chat" | "conta";

/** Painel do cliente. */
export function PainelCliente() {
  const [conta, setConta] = useState<Conta | null | undefined>(undefined);
  const [pedidos, setPedidos] = useState<PedidoC[] | null>(null);
  const [faturas, setFaturas] = useState<FaturaC[]>([]);
  const [aba, setAba] = useState<Aba>("pedidos");
  const [aberto, setAberto] = useState<string | null>(null);

  const carregar = useCallback(async () => {
    const sb = supabase();
    const [c, p, f] = await Promise.all([sb.rpc("minha_conta_cliente"), sb.rpc("meus_pedidos_cliente", { p_dias: 400 }), sb.rpc("minhas_faturas")]);
    setConta((c.data as Conta | null) ?? null);
    setPedidos((p.data as PedidoC[] | null) ?? []);
    setFaturas((f.data as FaturaC[] | null) ?? []);
  }, []);
  useEffect(() => { void carregar(); const t = setInterval(carregar, 15_000); return () => clearInterval(t); }, [carregar]);
  // voltou da página de cartão do Mercado Pago: confere o pagamento
  useEffect(() => {
    const ref = new URLSearchParams(window.location.search).get("pagamento");
    if (!ref) return;
    window.history.replaceState(null, "", window.location.pathname);
    void comSessao("/api/pagamentos/verificar", { id: ref }).then((r) => {
      if (r.status === "aprovado") toast("Pagamento confirmado. Seu pedido já segue.", "ok", { titulo: "Pago" });
      else if (r.status === "recusado") toast("O pagamento foi recusado. Tente outro cartão ou PIX.", "erro");
      else toast("Pagamento em análise. Avisamos assim que confirmar.", "aviso");
      void carregar();
    });
  }, [carregar]);

  if (conta === undefined || pedidos === null) return <p className="subtitulo" style={{ padding: 24 }}>Carregando…</p>;
  if (!conta) return <div className="cliente-cartao vidro"><p className="erro">Sua conta ainda não está ligada a um cadastro de cliente. Fale com a empresa.</p></div>;

  const pedido = pedidos.find((p) => p.id === aberto);
  const abertas = faturas.filter((f) => f.status === "emitida");
  return (
    <div className="cliente-painel entrar">
      <div className="cliente-cabeca">
        <div>
          <h1 className="display" style={{ margin: 0 }}>{conta.nome}</h1>
          <p className="dica" style={{ margin: 0 }}>
            {conta.pode_express ? <><Zap size={12} aria-hidden /> Peça na hora ou agende.</> : <><CalendarClock size={12} aria-hidden /> Pedidos agendados (o Express é liberado pela empresa).</>}
            {" · "}{conta.cobranca === "credito" ? <>Fatura {CICLO[conta.fatura_ciclo] ?? ""}</> : <>Pagamento antes de sair</>}
          </p>
        </div>
        <div className="cliente-cabeca-numeros" aria-label="Resumo">
          <span><b>{pedidos.filter((p) => ATIVOS.includes(p.status)).length}</b><small>a caminho</small></span>
          <span><b>{pedidos.length}</b><small>pedidos</small></span>
          {conta.ve_faturas !== false && <span><b>{abertas.length}</b><small>{conta.cobranca === "credito" ? "faturas abertas" : "a pagar"}</small></span>}
        </div>
        <button className="botao-ouro" onClick={() => { setAba("novo"); setAberto(null); }}><PackagePlus size={17} aria-hidden /> Novo pedido</button>
      </div>
      <Tour id="cliente" passos={TOUR_CLIENTE} />
      <div className="segmentado abas-cliente">
        {([["pedidos", "Pedidos", Package], ["novo", "Novo pedido", PackagePlus], ["faturas", conta.cobranca === "credito" ? "Faturas" : "Pagamentos", Receipt], ["chat", "Conversa", MessagesSquare], ["conta", "Minha conta", Building2]] as [Aba, string, typeof Package][])
          .filter(([k]) => (k !== "faturas" || conta.ve_faturas !== false) && (k !== "chat" || conta.pode_chat === true)).map(([k, r, I]) => (
          <button key={k} type="button" data-tour={`aba-${k}`} className={aba === k ? "ativo" : ""} onClick={() => { setAba(k); setAberto(null); }}>
            <I size={14} aria-hidden /> {r}{k === "faturas" && abertas.length > 0 && <span className="filtro-n">{abertas.length}</span>}
          </button>
        ))}
      </div>
      {aba === "pedidos" && (pedido
        ? <DetalhePedido pedido={pedido} conta={conta} onVoltar={() => setAberto(null)} onMudou={carregar} />
        : <ListaPedidos pedidos={pedidos} onAbrir={setAberto} onNovo={() => setAba("novo")} />)}
      {aba === "novo" && <NovoPedido conta={conta} onCriado={async (id) => { await carregar(); setAba("pedidos"); setAberto(id); }} />}
      {aba === "chat" && conta.pode_chat === true && <div className="cliente-chat"><ChatCliente /></div>}
      {aba === "faturas" && conta.ve_faturas !== false && <Faturas conta={conta} faturas={faturas} pedidos={pedidos} />}
      {aba === "conta" && <MinhaConta conta={conta} />}
    </div>
  );
}

/** Pagamento confirmado (pelo site ou pelo gestor). */
function SeloPago() {
  return <span className="selo selo-pago"><BadgeCheck size={11} aria-hidden /> PAGO</span>;
}

function Selo({ s }: { s: StatusP }) {
  return <span className="selo" style={{ color: STATUS[s].cor }}>{STATUS[s].rotulo}</span>;
}

// ------------------------------------------------------------------ lista

function ListaPedidos({ pedidos, onAbrir, onNovo }: { pedidos: PedidoC[]; onAbrir: (id: string) => void; onNovo: () => void }) {
  const ativos = pedidos.filter((p) => ATIVOS.includes(p.status));
  const outros = pedidos.filter((p) => !ATIVOS.includes(p.status));
  if (!pedidos.length)
    return (
      <div className="cliente-cartao vidro vazio-cliente">
        <Package size={34} aria-hidden />
        <p>Você ainda não fez nenhum pedido.</p>
        <button className="botao-ouro" onClick={onNovo}><Plus size={16} aria-hidden /> Fazer o primeiro</button>
      </div>
    );
  const linha = (p: PedidoC) => {
    const ent = p.pontos.filter((x) => x.tipo === "entrega");
    const feitas = ent.filter((x) => x.status === "concluido").length;
    return (
      <button key={p.id} className="cliente-pedido vidro" onClick={() => onAbrir(p.id)}>
        <div className="cliente-pedido-topo">
          <strong>#{p.numero}</strong><Selo s={p.status} />{p.pagamento_status === "pago" && <SeloPago />}
          {p.tipo === "planejado" ? <CalendarClock size={13} aria-label="Agendado" /> : <Zap size={13} aria-label="Express" />}
          <span className="espaco" /><strong>{p.valor == null && (p as { preco_oculto?: boolean }).preco_oculto ? "Revisando" : moedaBr(p.valor)}</strong>
        </div>
        <span className="dica">{p.pontos.find((x) => x.tipo === "coleta")?.endereco} → {ent.length > 1 ? `${ent.length} entregas` : ent[0]?.endereco}</span>
        <span className="dica">{p.tipo === "planejado" ? `Agendado para ${quando(p.quando)}` : `Pedido ${quando(p.criado_em)}`}{ent.length > 1 && p.status === "em_rota" ? ` · ${feitas}/${ent.length} entregues` : ""}</span>
        {ent.length > 1 && <div className="progresso"><i style={{ width: `${(feitas / ent.length) * 100}%` }} /></div>}
      </button>
    );
  };
  // em andamento: blocos por cima do mapa com todos os pontos (toque no bloco abre o pedido)
  const pinosAtivos: PinoParada[] = ativos.slice(0, 12).flatMap((p) => p.pontos.filter((x) => x.lat != null).map((x, i) => ({
    chave: `${p.id}-${x.id}`, lat: x.lat, lng: x.lng, tipo: x.tipo, rotulo: i === 0 ? `#${p.numero}` : String(i + 1), concluida: x.status === "concluido",
  })));
  return (
    <>
      {ativos.length > 0 && (
        <section className="cliente-palco">
          <div className="cliente-palco-mapa"><MapaCorridas paradas={pinosAtivos} enquadrar={ativos.map((p) => p.id).join()} caminhoAuto={false} legenda={false} /></div>
          <div className="cliente-palco-blocos">
            {ativos.map((p) => {
              const ent = p.pontos.filter((x) => x.tipo === "entrega");
              const feitas = ent.filter((x) => x.status === "concluido").length;
              const passo = ["recebido", "aprovado"].includes(p.status) ? 0 : p.status === "roteirizado" ? 1 : p.status === "em_rota" ? 2 : 3;
              return (
                <button key={p.id} type="button" className="cliente-bloco vidro" onClick={() => onAbrir(p.id)}>
                  <span className="cliente-bloco-topo"><strong>#{p.numero}</strong><Selo s={p.status} />{p.pagamento_status === "pago" && <SeloPago />}</span>
                  <span className="cliente-bloco-destino"><MapPinned size={14} aria-hidden /> {ent.length > 1 ? `${ent.length} entregas` : ent[0]?.endereco ?? "Entrega"}</span>
                  <span className="cliente-bloco-passos" aria-label="Andamento">{[0, 1, 2, 3].map((i) => <i key={i} className={i <= passo ? "feito" : ""} />)}</span>
                  <span className="dica">{p.tipo === "planejado" ? `Agendado para ${quando(p.quando)}` : STATUS[p.status].dica}{ent.length > 1 ? ` · ${feitas}/${ent.length}` : ""}</span>
                </button>
              );
            })}
          </div>
        </section>
      )}
      {outros.length > 0 && <><h3 className="rotulo">Histórico</h3><div className="cliente-lista">{outros.map(linha)}</div></>}
    </>
  );
}

// ------------------------------------------------------------------ detalhe

function DetalhePedido({ pedido: p, conta, onVoltar, onMudou }: { pedido: PedidoC; conta: Conta; onVoltar: () => void; onMudou: () => void }) {
  // pedido pré-pago que acabou de ser feito: já abre o pagamento
  const [pagando, setPagando] = useState(() => p.cobranca === "pre_pago" && p.pagamento_status === "pendente" && Number(p.valor) > 0
    && !["cancelado", "recusado"].includes(p.status) && Date.now() - new Date(p.criado_em).getTime() < 120_000);
  const [motoboys, setMotoboys] = useState<{ lat: number; lng: number; nome: string; foto: string | null }[]>([]);
  const [planejada, setPlanejada] = useState<string | null>(null);
  const [outras, setOutras] = useState<{ lat: number; lng: number; tipo: "coleta" | "entrega"; feita: boolean }[]>([]);
  // o que o gestor deixa o cliente ver da rota (Ajustes → Clientes → O que o cliente vê)
  const ve = new Set(conta.ve_rota ?? ["feito", "motoboy"]);
  // feito: o caminho do motoboy com o seu pedido (da coleta em diante), pelas ruas
  const [trilha, setTrilha] = useState<[number, number][]>([]);
  useEffect(() => {
    if (!conta.ve_ao_vivo || !ve.has("feito") || !["em_rota", "concluido"].includes(p.status)) { setTrilha([]); return; }
    let vivo = true;
    const buscar = () => trilhaDoPedido(p.id).then((t) => { if (vivo) setTrilha(t); });
    void buscar();
    const t = p.status === "em_rota" ? setInterval(buscar, 60_000) : undefined;
    return () => { vivo = false; if (t) clearInterval(t); };
  }, [p.id, p.status, conta.ve_ao_vivo]);
  useEffect(() => {
    if (!conta.ve_ao_vivo || p.status !== "em_rota") { setMotoboys([]); return; }
    let vivo = true;
    async function buscar() {
      const { data } = await supabase().rpc("acompanhar_pedido_cliente", { p_pedido: p.id });
      const l = (data ?? []) as { lat: number | null; lng: number | null; nome: string; foto?: string | null; rota_planejada?: string | null; outras_paradas?: { lat: number; lng: number; tipo: "coleta" | "entrega"; feita: boolean }[] | null }[];
      if (!vivo) return;
      setMotoboys(l.filter((m) => m.lat != null).map((m) => ({ lat: m.lat!, lng: m.lng!, nome: m.nome, foto: m.foto ?? null })));
      setPlanejada(l.find((m) => m.rota_planejada)?.rota_planejada ?? null);
      setOutras(l.flatMap((m) => m.outras_paradas ?? []));
    }
    void buscar();
    const t = setInterval(buscar, 10_000);
    return () => { vivo = false; clearInterval(t); };
  }, [p.id, p.status, conta.ve_ao_vivo]);

  async function cancelar() {
    if (!confirm(`Cancelar o pedido #${p.numero}?`)) return;
    const { error } = await supabase().rpc("cancelar_pedido", { p_pedido: p.id, p_motivo: "Cancelado pelo cliente" });
    if (error) return toast(traduzir(error.message), "erro");
    toast("Pedido cancelado.", "ok");
    onMudou();
  }
  const pinos: PinoParada[] = [...p.pontos.map((x, i) => ({ chave: x.id, lat: x.lat, lng: x.lng, tipo: x.tipo, rotulo: String(i + 1), concluida: x.status === "concluido" })),
    ...(ve.has("outras_paradas") ? outras.map((x, i) => ({ chave: `o${i}`, lat: x.lat, lng: x.lng, tipo: x.tipo, rotulo: "·", concluida: x.feita })) : [])];
  const [foco, setFoco] = useState<{ lat: number; lng: number; vez: number } | null>(null);
  const podeCancelar = conta.pode_cancelar !== false && ["recebido", "aprovado", "roteirizado"].includes(p.status);

  return (
    <div className="cliente-detalhe">
      <button className="botao-texto" onClick={onVoltar}><ArrowLeft size={15} aria-hidden /> Pedidos</button>
      <div className="cliente-cartao vidro">
        <div className="cliente-pedido-topo">
          <h2 className="display" style={{ margin: 0 }}>Pedido #{p.numero}</h2><Selo s={p.status} />{p.pagamento_status === "pago" && <SeloPago />}<span className="espaco" />
          <strong className="figura" style={{ fontSize: 24 }}>{p.valor == null && (p as { preco_oculto?: boolean }).preco_oculto ? "Revisando" : moedaBr(p.valor)}</strong>
        </div>
        {!["cancelado", "recusado"].includes(p.status) && (() => {
          const passo = ["recebido", "aprovado"].includes(p.status) ? 0 : p.status === "roteirizado" ? 1 : p.status === "em_rota" ? 2 : 3;
          return (
            <ol className="detalhe-passos" aria-label="Andamento do pedido">
              {["Recebido", "Rota pronta", "A caminho", "Entregue"].map((t, i) => (
                <li key={t} className={i < passo ? "feito" : i === passo ? "atual" : ""} aria-current={i === passo ? "step" : undefined}>
                  <span>{i < passo ? <CheckCircle2 size={14} aria-hidden /> : i + 1}</span>{t}
                </li>
              ))}
            </ol>
          );
        })()}
        <p className="dica" style={{ margin: 0 }}>{STATUS[p.status].dica}{p.recusa_motivo ? ` Motivo: ${p.recusa_motivo}` : ""}</p>
        <div className="cliente-mapa">
          <MapaCorridas paradas={pinos} enquadrar={p.id} foco={foco} trilha={trilha} rotaPlanejada={ve.has("planejada") ? planejada : null}
            caminhoAuto={ve.has("planejada") || ve.has("restante") ? !planejada : false}
            restanteDe={ve.has("restante") && motoboys[0] ? { lat: motoboys[0].lat, lng: motoboys[0].lng } : null}
            motoboys={(ve.has("motoboy") ? motoboys : []).map((m, i) => ({ id: `m${i}`, nome: m.nome, lat: m.lat, lng: m.lng, status: "em_corrida", foto: m.foto }))} />
        </div>
        {p.cobranca === "pre_pago" && p.pagamento_status === "pendente" && !["cancelado", "recusado"].includes(p.status) && (
          <div className="cliente-pagar">
            <Lock size={18} aria-hidden />
            <div style={{ flex: 1 }}><strong>Aguardando pagamento{p.pagamento_metodo ? ` (${p.pagamento_metodo === "pix" ? "PIX" : "cartão"})` : ""}</strong>
              <p className="dica" style={{ margin: 0 }}>O pedido sai assim que o pagamento for confirmado.</p></div>
            {Number(p.valor) > 0 && <button type="button" className="botao-ouro" onClick={() => setPagando(true)}><CreditCard size={15} aria-hidden /> Pagar agora</button>}
          </div>
        )}
        {pagando && <Pagar alvo="pedido" id={p.id} valor={Number(p.valor)} onFechar={() => setPagando(false)} onPago={() => { setPagando(false); onMudou(); }} />}
        {p.codigos.length > 0 && <p className="cliente-codigo">Código de entrega: <strong>{p.codigos.join(" · ")}</strong> <span className="dica">passe só para quem vai receber</span></p>}
        <ol className="cliente-paradas">
          {p.pontos.map((x, i) => (
            <li key={x.id} className={`clicavel${x.status === "concluido" ? " feita" : ""}`} title="Ver no mapa" onClick={() => setFoco({ lat: x.lat, lng: x.lng, vez: Date.now() })}>
              <span className={`pino-mini ${x.tipo}`}>{i + 1}</span>
              <div><strong>{x.tipo === "coleta" ? "Coleta" : "Entrega"}</strong> · {x.endereco}
                {x.contato_nome && <span className="dica"> · {x.contato_nome}</span>}
                {x.concluido_em && <div className="dica"><CheckCircle2 size={12} aria-hidden /> {quando(x.concluido_em)}{x.recebedor_nome ? ` · recebido por ${x.recebedor_nome}` : ""}</div>}
                <SelosPonto p={x} />
                {x.tipo === "entrega" && p.itens.some((it) => it.entrega_id !== undefined) && <PacotesPonto itens={pacotesDoPonto(p.itens, x, p.pontos.filter((y) => y.tipo === "entrega").map((y) => y.id))} />}
              </div>
            </li>
          ))}
        </ol>
        {p.itens.length > 0 && !p.itens.some((it) => it.entrega_id !== undefined) && (
          <div className="itens-lista">
            {p.itens.map((it, i) => (
              <span key={i} className="chip">{it.perigoso ? <FlaskConical size={12} style={{ color: "var(--vermelho)" }} aria-label="Perigoso" /> : <Icone nome={it.icone} size={12} />} {it.quantidade}× {it.descricao}</span>
            ))}
          </div>
        )}
        <p className="dica" style={{ margin: 0 }}>
          {p.tipo === "planejado" ? `Agendado para ${quando(p.quando)}` : `Pedido em ${quando(p.criado_em)}`}
          {p.motoboys.length ? ` · ${p.motoboys.map((n) => n.split(" ")[0]).join(", ")}` : ""}
          {p.cobranca === "pre_pago" && p.pagamento_status === "pago" ? " · pago" : ""}
        </p>
        {conta.pode_rastreio && !["cancelado", "recusado"].includes(p.status) && <BotaoRastreio pedidoId={p.id} />}
        {conta.pode_avaliar && p.status === "concluido" && <AvaliarPedido pedidoId={p.id} />}
        {podeCancelar && <button className="botao-perigo" onClick={cancelar}><X size={15} aria-hidden /> Cancelar pedido</button>}
      </div>
    </div>
  );
}

function Orcamento({ orc }: { orc: Orcamento }) {
  return (
    <div className="orcamento">
      {orc.linhas.map((l, i) => <div key={i} className="orcamento-linha"><span>{l.rotulo}{l.detalhe && <small>{l.detalhe}</small>}</span><strong>{moedaBr(l.valor)}</strong></div>)}
      {orc.percentuais.map((x, i) => <div key={`p${i}`} className="orcamento-linha pct"><span>{x.rotulo}</span><strong>+{x.pct.toLocaleString("pt-BR")}%</strong></div>)}
      <div className="orcamento-linha total"><span>Total</span><strong>{moedaBr(orc.total)}</strong></div>
    </div>
  );
}

// ------------------------------------------------------------------ novo pedido

interface Ponto extends OpcoesDoPonto { chave: string; tipo: "coleta" | "entrega"; endereco: string; lat: number | null; lng: number | null; contato_nome: string; contato_telefone: string; instrucoes: string; referencias: Referencia[] }
let seq = 0;
const ponto = (tipo: Ponto["tipo"], base: Partial<Ponto> = {}): Ponto => ({ chave: `p${++seq}`, tipo, endereco: "", lat: null, lng: null, contato_nome: "", contato_telefone: "", instrucoes: "", referencias: [], ...base });

/** Modelos (pedidos recorrentes) salvos pelo cliente: tudo pode ser mudado depois de carregar. */
function useModelos(conta: Conta) {
  const [modelos, setModelos] = useState<Modelo[]>([]);
  const recarregar = useCallback(async () => {
    if (conta.pode_modelos === false) return setModelos([]);
    const { data } = await supabase().from("pedido_modelos").select("id,nome,icone,dados,usos,usado_em").eq("empresa_id", conta.id).order("usos", { ascending: false }).order("nome");
    setModelos((data ?? []) as Modelo[]);
  }, [conta.id, conta.pode_modelos]);
  useEffect(() => { void recarregar(); }, [recarregar]);
  return { modelos, recarregar };
}

/** Objetos salvos (produtos que o cliente manda sempre). */
function useObjetos(conta: Conta) {
  const [objetos, setObjetos] = useState<ObjetoSalvo[]>([]);
  const recarregar = useCallback(async () => {
    if (conta.pode_objetos === false) return setObjetos([]);
    const { data } = await supabase().from("cliente_objetos").select("id,nome,dados,usos").eq("empresa_id", conta.id).order("usos", { ascending: false }).order("nome");
    setObjetos((data ?? []) as ObjetoSalvo[]);
  }, [conta.id, conta.pode_objetos]);
  useEffect(() => { void recarregar(); }, [recarregar]);
  return { objetos, recarregar };
}

/** Próximo horário com esta hora (HH:MM) que respeita a antecedência mínima. */
/** Fora do horário de pedidos na hora (pedido_de/pedido_ate, HH:MM; pode virar a meia-noite). */
function foraDoHorario(c: { pedido_de?: string | null; pedido_ate?: string | null }): boolean {
  if (!c.pedido_de || !c.pedido_ate) return false;
  const d = new Date(), agora = `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
  const de = c.pedido_de.slice(0, 5), ate = c.pedido_ate.slice(0, 5);
  return de <= ate ? agora < de || agora > ate : agora < de && agora > ate;
}

function proximoComHora(hora: string, antecedenciaMin: number): string {
  const [h, m] = hora.split(":").map(Number);
  const d = new Date(); d.setSeconds(0, 0); d.setHours(h || 0, m || 0);
  while (d.getTime() < Date.now() + antecedenciaMin * 60_000) d.setDate(d.getDate() + 1);
  return paraCampo(d);
}

const PASSOS_PEDIDO = ["Endereços", "Pacotes", "Horário", "Pagamento"];

function NovoPedido({ conta, onCriado }: { conta: Conta; onCriado: (id: string) => void }) {
  const [passo, setPasso] = useState(0);
  const coletaPadrao = (): Ponto => ponto("coleta", conta.endereco ? { endereco: conta.endereco, lat: conta.lat, lng: conta.lng, instrucoes: conta.instrucoes_coleta ?? "" } : {});
  const [pontos, setPontos] = useState<Ponto[]>(() => [coletaPadrao(), ponto("entrega")]);
  const [itens, setItens] = useState<ItemForm[]>([]);
  const podeAgendar = conta.pode_agendar !== false;
  const podeAgora = conta.pode_express && !foraDoHorario(conta);
  const [agendar, setAgendar] = useState(!podeAgora && podeAgendar);
  const [horario, setHorario] = useState(() => paraCampo(sugestaoHorario(Math.max(60, conta.antecedencia_min))));
  const [tipoPedido, setTipoPedido] = useState(conta.tipos_pedido[0]?.chave ?? "padrao");
  const [urgente, setUrgente] = useState(false);
  const [metodo, setMetodo] = useState(conta.metodos[0] ?? "pix");
  const [obs, setObs] = useState("");
  const [rota, setRota] = useState<Rota | null>(null);
  const [orc, setOrc] = useState<Orcamento | null>(null);
  const [escolhendo, setEscolhendo] = useState<string | null>(null);
  const [aberto, setAberto] = useState<string | null>(null);
  const [enviando, setEnviando] = useState(false);
  const [modeloId, setModeloId] = useState<string | null>(null);
  const [salvarComo, setSalvarComo] = useState<string | null>(null);
  const { modelos, recarregar: recarregarModelos } = useModelos(conta);
  const { objetos, recarregar: recarregarObjetos } = useObjetos(conta);
  const liberadas = conta.confirmacoes ?? {};
  const algumaConfirmacao = Object.values(liberadas).some(Boolean);

  const nEntregas = pontos.filter((p) => p.tipo === "entrega").length, nColetas = pontos.filter((p) => p.tipo === "coleta").length;
  const podeEntrega = !conta.max_entregas || nEntregas < conta.max_entregas;
  const podeColeta = !conta.coleta_fixa && (!conta.max_coletas || nColetas < conta.max_coletas);
  const fixa = (p: Ponto) => Boolean(conta.coleta_fixa) && p.tipo === "coleta" && pontos.findIndex((x) => x.tipo === "coleta") === pontos.indexOf(p);
  const atualizar = (k: string, d: Partial<Ponto>) => setPontos((l) => l.map((p) => (p.chave === k ? { ...p, ...d } : p)));
  const chaveRota = pontos.map((p) => `${p.lat},${p.lng}`).join("|");
  useEffect(() => {
    const ok = pontos.filter((p) => p.lat != null);
    if (ok.length < 2 || ok.length !== pontos.length) { setRota(null); return; }
    const t = setTimeout(async () => setRota(await geo.calcularRota(ok.map((p) => ({ lat: p.lat!, lng: p.lng! }))).catch(() => null)), 500);
    return () => clearTimeout(t);
  }, [chaveRota]); // eslint-disable-line react-hooks/exhaustive-deps

  // distância pelas ruas da coleta até cada entrega (base do preço "soma das entregas")
  const chaveDist = pontos.map((p) => `${p.tipo}${p.lat},${p.lng}`).join("|");
  const [distEnt, setDistEnt] = useState<(number | null)[]>([]);
  useEffect(() => {
    if (pontos.some((p) => p.lat == null)) { setDistEnt([]); return; }
    let vivo = true;
    const t = setTimeout(() => distanciasColetaEntrega(pontos).then((d) => { if (vivo) setDistEnt(d); }).catch(() => {}), 500);
    return () => { vivo = false; clearTimeout(t); };
  }, [chaveDist]); // eslint-disable-line react-hooks/exhaustive-deps
  const comDist = <T extends { tipo: string }>(p: T, i: number) => ({ ...p, dist_coleta_m: p.tipo === "entrega" ? distEnt[i] ?? null : null });

  const dadosItens = itensParaEnvio(itens, pontos.map((p) => p.chave));
  const quandoIso = agendar && horario ? new Date(horario).toISOString() : null;
  const chaveOrc = JSON.stringify([tipoPedido, urgente, quandoIso, rota?.distanciaM, pontos.map((p) => [p.tipo, p.lat, p.lng]), distEnt, dadosItens]);
  useEffect(() => {
    if (pontos.some((p) => p.lat == null)) { setOrc(null); return; }
    const t = setTimeout(async () => {
      const { data } = await supabase().rpc("orcar_previa", { dados: {
        tipo: agendar ? "planejado" : "express", tipo_pedido: tipoPedido, quando: quandoIso, urgente, distancia_m: rota?.distanciaM ?? null,
        pontos: pontos.map((p, i) => comDist({ tipo: p.tipo, lat: p.lat, lng: p.lng }, i)), itens: dadosItens } });
      setOrc((data as Orcamento) ?? null);
    }, 400);
    return () => clearTimeout(t);
  }, [chaveOrc]); // eslint-disable-line react-hooks/exhaustive-deps

  function usarModelo(m: Modelo) {
    const d = m.dados ?? {};
    const novos = (d.pontos ?? []).map((p) => ponto(p.tipo, p));
    // os itens apontam para os pontos pela posição no modelo
    const chaves = novos.map((p) => p.chave);
    const idx = (s: string) => (s === "" ? "" : chaves[Number(s)] ?? "");
    setPontos(novos.length >= 2 ? novos : [coletaPadrao(), ponto("entrega")]);
    setItens((d.itens ?? []).map((x) => ({ ...novoItem(x.categoria_id), ...x, coleta: idx(String(x.coleta ?? "")), entrega: idx(String(x.entrega ?? "")) })));
    if (d.tipo_pedido && conta.tipos_pedido.some((t) => t.chave === d.tipo_pedido)) setTipoPedido(d.tipo_pedido);
    setUrgente(Boolean(d.urgente) && conta.pode_urgente !== false);
    setObs(conta.pode_observacoes !== false ? d.observacoes ?? "" : "");
    if (d.metodo && conta.metodos.includes(d.metodo)) setMetodo(d.metodo);
    // agora ou agendado, como foi salvo (agendado: a mesma hora, no próximo dia possível)
    if (conta.modelo_horario !== false && d.agendar != null) {
      const agendado = (d.agendar || !podeAgora) && podeAgendar;
      setAgendar(agendado);
      if (agendado && d.hora) setHorario(proximoComHora(d.hora, conta.antecedencia_min));
    }
    setModeloId(m.id);
    toast(`Modelo “${m.nome}” carregado. Mude o que precisar antes de enviar.`, "ok");
  }

  async function salvarModelo() {
    const nome = (salvarComo ?? "").trim();
    if (!nome) return;
    const chaves = pontos.map((p) => p.chave);
    const dados: DadosModelo = {
      tipo_pedido: tipoPedido, urgente, observacoes: obs.trim() || undefined,
      agendar, hora: agendar && horario ? horario.slice(11, 16) : undefined, metodo: conta.cobranca === "pre_pago" ? metodo : undefined,
      pontos: pontos.map(({ chave, ...p }) => { void chave; return p; }),
      itens: itens.map(({ chave, ...x }) => { void chave; return { ...x, coleta: x.coleta ? String(chaves.indexOf(x.coleta)) : "", entrega: x.entrega ? String(chaves.indexOf(x.entrega)) : "" }; }),
    };
    const existente = modelos.find((m) => m.nome.toLowerCase() === nome.toLowerCase());
    const { error } = existente
      ? await supabase().from("pedido_modelos").update({ dados }).eq("id", existente.id)
      : await supabase().from("pedido_modelos").insert({ empresa_id: conta.id, nome, dados });
    if (error) return toast(traduzir(error.message), "erro");
    setSalvarComo(null);
    toast(existente ? `Modelo “${nome}” atualizado.` : `Modelo “${nome}” salvo. Ele aparece no topo do próximo pedido.`, "ok");
    void recarregarModelos();
  }

  async function salvarObjeto(x: ItemForm) {
    const k = conta.categorias.find((c) => c.id === x.categoria_id);
    const sugestao = x.descricao.trim() || k?.nome || "Objeto";
    const nome = prompt("Nome do objeto (aparece em Meus objetos):", sugestao)?.trim();
    if (!nome) return;
    const existente = objetos.find((o) => o.nome.toLowerCase() === nome.toLowerCase());
    const { error } = existente
      ? await supabase().from("cliente_objetos").update({ dados: dadosDoObjeto(x) }).eq("id", existente.id)
      : await supabase().from("cliente_objetos").insert({ empresa_id: conta.id, nome: nome.slice(0, 80), dados: dadosDoObjeto(x) });
    if (error) return toast(traduzir(error.message), "erro");
    toast(existente ? `Objeto “${nome}” atualizado.` : `Objeto “${nome}” salvo. Ele aparece em Meus objetos.`, "ok");
    void recarregarObjetos();
  }
  async function apagarObjeto(o: ObjetoSalvo) {
    if (!confirm(`Apagar o objeto “${o.nome}”?`)) return;
    const { error } = await supabase().from("cliente_objetos").delete().eq("id", o.id);
    if (error) return toast(traduzir(error.message), "erro");
    void recarregarObjetos();
  }

  async function apagarModelo(m: Modelo) {
    if (!confirm(`Apagar o modelo “${m.nome}”?`)) return;
    const { error } = await supabase().from("pedido_modelos").delete().eq("id", m.id);
    if (error) return toast(traduzir(error.message), "erro");
    if (modeloId === m.id) setModeloId(null);
    void recarregarModelos();
  }

  async function enviar() {
    if (pontos.some((p) => p.lat == null)) return toast("Localize todos os endereços (escolha da lista ou marque no mapa).", "aviso");
    if (conta.categoria_obrigatoria && itens.some((x) => !x.categoria_id)) return toast("Escolha o tipo de cada item.", "aviso");
    const falta = faltandoItens(itens, conta.categorias);
    if (falta) return toast(falta, "aviso");
    if (!agendar && !podeAgora) return toast(podeAgendar ? "Agora não dá para pedir na hora. Escolha Agendar." : "Agora não dá para fazer pedidos. Fale com a empresa.", "aviso");
    if (agendar && horario && conta.agendar_max_dias && new Date(horario).getTime() > Date.now() + conta.agendar_max_dias * 86_400_000) return toast(`Dá para agendar até ${conta.agendar_max_dias} dias à frente.`, "aviso");
    const jan = pontos.find((p) => p.janela_de && p.janela_ate && p.janela_de >= p.janela_ate);
    if (jan) return toast(`O horário do ponto ${pontos.indexOf(jan) + 1} termina antes de começar.`, "aviso");
    setEnviando(true);
    const { data, error } = await supabase().rpc("criar_pedido", { dados: {
      como_cliente: true, modelo_id: modeloId, objetos_usados: [...new Set(itens.map((x) => x.objeto_id).filter(Boolean))],
      quando: quandoIso, urgente, tipo_pedido: tipoPedido, metodo: conta.cobranca === "pre_pago" ? metodo : null, observacoes: obs.trim() || null,
      distancia_m: rota?.distanciaM ?? null, pontos: pontos.map(({ chave, ...p }, i) => { void chave; return comDist(p, i); }), itens: dadosItens } });
    setEnviando(false);
    if (error) return toast(traduzir(error.message), "erro");
    toast("Recebemos o seu pedido.", "ok", { titulo: "Pedido enviado" });
    onCriado(data as string);
  }

  const pinos: PinoParada[] = pontos.filter((p) => p.lat != null).map((p) => ({ chave: p.chave, lat: p.lat!, lng: p.lng!, tipo: p.tipo, rotulo: String(pontos.indexOf(p) + 1) }));
  const perigoso = dadosItens.some((x) => conta.categorias.find((k) => k.id === x.categoria_id)?.perigoso);
  return (
    <div className="cliente-novo">
      <div className="cliente-coluna">
        <nav className="passos-pedido" aria-label="Etapas do pedido">
          {PASSOS_PEDIDO.map((t, i) => (
            <button key={t} type="button" className={`passo-pedido${i === passo ? " atual" : i < passo ? " feito" : ""}`} aria-current={i === passo ? "step" : undefined} onClick={() => setPasso(i)}>
              <span>{i < passo ? <CheckCircle2 size={14} aria-hidden /> : i + 1}</span>{t}
            </button>
          ))}
        </nav>
        {conta.pode_modelos !== false && (modelos.length > 0 || salvarComo != null) && (
          <div className={`cliente-cartao vidro${passo !== 0 ? " passo-oculto" : ""}`}>
            <span className="rotulo"><Bookmark size={13} aria-hidden /> Meus modelos<Dica titulo="Modelos" texto="Um pedido que se repete, guardado. Toque nele para preencher tudo de novo; dá para mudar o que quiser antes de enviar." /></span>
            <div className="linha-chips modelos">
              {modelos.map((m) => (
                <span key={m.id} className={`chip modelo ${modeloId === m.id ? "ativo" : ""}`}>
                  <button type="button" onClick={() => usarModelo(m)}><Icone nome={m.icone} padrao={Bookmark} size={13} /> {m.nome}</button>
                  <button type="button" className="tirar" aria-label={`Apagar o modelo ${m.nome}`} onClick={() => apagarModelo(m)}><X size={12} /></button>
                </span>
              ))}
            </div>
          </div>
        )}

        <div className={`cliente-cartao vidro${passo !== 2 ? " passo-oculto" : ""}`}>
          <span className="rotulo">Quando</span>
          <div className="segmentado" style={{ gridTemplateColumns: "1fr 1fr" }}>
            <button type="button" className={!agendar ? "ativo" : ""} disabled={!podeAgora} onClick={() => setAgendar(false)}><Zap size={14} aria-hidden /> Agora</button>
            <button type="button" className={agendar ? "ativo" : ""} disabled={!podeAgendar} onClick={() => setAgendar(true)}><CalendarClock size={14} aria-hidden /> Agendar</button>
          </div>
          {!podeAgendar && <p className="dica" style={{ margin: 0 }}><Lock size={11} aria-hidden /> Sua conta faz só pedidos na hora.</p>}
          {conta.pode_express && foraDoHorario(conta) && <p className="dica" style={{ margin: 0 }}><Clock size={11} aria-hidden /> Pedidos na hora: das {conta.pedido_de?.slice(0, 5)} às {conta.pedido_ate?.slice(0, 5)}.{podeAgendar ? " Agora, só agendado." : ""}</p>}
          {!conta.pode_express && podeAgendar && <p className="dica" style={{ margin: 0 }}><Lock size={11} aria-hidden /> Agende com pelo menos {conta.antecedencia_min} min.</p>}
          {agendar && <input type="datetime-local" value={horario} min={paraCampo(new Date(Date.now() + conta.antecedencia_min * 60_000))}
            max={conta.agendar_max_dias ? paraCampo(new Date(Date.now() + conta.agendar_max_dias * 86_400_000)) : undefined} onChange={(e) => setHorario(e.target.value)} />}
          {conta.tipos_pedido.length > 1 && (
            <div className="tipos-pedido">
              {conta.tipos_pedido.map((t) => (
                <button key={t.chave} type="button" className={`tipo-pedido ${tipoPedido === t.chave ? "ativo" : ""}`} onClick={() => setTipoPedido(t.chave)} title={t.descricao ?? undefined}>
                  <Icone nome={t.icone} size={16} /><strong>{t.nome}</strong>
                </button>
              ))}
            </div>
          )}
          {conta.pode_urgente !== false && <label className="opcao"><span><Zap size={14} aria-hidden style={{ color: "var(--vermelho)" }} /> Urgente<Dica titulo="Urgente" texto="Passa na frente: a rota sai sozinha, não espera juntar com outros pedidos e chega até motoboys fora do raio deles. Pode custar mais, conforme o combinado com a empresa." /></span><input type="checkbox" role="switch" checked={urgente} onChange={(e) => setUrgente(e.target.checked)} /></label>}
        </div>

        <div className={`cliente-cartao vidro${passo !== 0 && passo !== 1 ? " passo-oculto" : ""}${passo === 1 ? " passo-pacotes" : ""}`}>
          <span className="rotulo">Endereços</span>
          <ListaOrdenavel itens={pontos} chave={(p) => p.chave} onMudar={setPontos} render={(p, i, alca) => (
            <div className={`parada-form ${p.tipo}`}>
              <div className="parada-topo">
                {pontos.length > 2 && alca}
                <span className={`pino-mini ${p.tipo}`}>{i + 1}</span>
                {fixa(p) ? <span className="selo"><Lock size={11} aria-hidden /> Coleta</span>
                  : <select value={p.tipo} onChange={(e) => atualizar(p.chave, { tipo: e.target.value as Ponto["tipo"] })}><option value="coleta" disabled={!podeColeta && p.tipo !== "coleta"}>Coleta</option><option value="entrega" disabled={!podeEntrega && p.tipo !== "entrega"}>Entrega</option></select>}
                <span className="espaco" />
                {pontos.length > 2 && !fixa(p) && <button type="button" className="icone" title="Remover" onClick={() => setPontos((l) => l.filter((x) => x.chave !== p.chave))}><X size={14} /></button>}
              </div>
              {fixa(p) ? <p className="dica" style={{ margin: 0 }}><strong>{p.endereco || "Endereço de coleta da conta"}</strong> (a coleta é sempre aqui)</p> : <CampoEndereco valor={p.endereco} onTexto={(t) => atualizar(p.chave, { endereco: t, lat: null, lng: null })} onEscolher={(e) => atualizar(p.chave, { endereco: e.descricao, lat: e.lat, lng: e.lng })} />}
              <div className="parada-acoes">
                {!fixa(p) && <button type="button" className={`link ${escolhendo === p.chave ? "ativo" : ""}`} onClick={() => setEscolhendo(escolhendo === p.chave ? null : p.chave)}>
                  <MapPinned size={13} aria-hidden /> {escolhendo === p.chave ? "Clique no mapa…" : "Marcar no mapa"}
                </button>}
                {p.lat != null ? <span className="ok"><CheckCircle2 size={13} aria-hidden /> Localizado</span> : <span className="pendente">Sem localização</span>}
                <button type="button" className="link" onClick={() => setAberto(aberto === p.chave ? null : p.chave)}><UserRound size={13} aria-hidden /> {aberto === p.chave ? "Menos" : "Contato e referências"}</button>
              </div>
              {aberto === p.chave && (
                <div className="parada-extra">
                  <input placeholder={p.tipo === "coleta" ? "Quem entrega ao motoboy" : "Quem recebe"} value={p.contato_nome} onChange={(e) => atualizar(p.chave, { contato_nome: e.target.value })} />
                  <input placeholder="Telefone" value={p.contato_telefone} onChange={(e) => atualizar(p.chave, { contato_telefone: e.target.value })} />
                  <input placeholder="Instruções (portaria, bloco, horário…)" value={p.instrucoes} onChange={(e) => atualizar(p.chave, { instrucoes: e.target.value })} />
                  <CampoReferencias valor={p.referencias} lat={p.lat} lng={p.lng} onMudar={(r) => atualizar(p.chave, { referencias: r })} />
                </div>
              )}
              {p.tipo === "entrega" && (
                <div className="itens-ponto">
                  <span className="rotulo"><Boxes size={12} aria-hidden /> O que vai para esta entrega{itens.some((x) => x.entrega === p.chave) && <span className="filtro-n">{itens.filter((x) => x.entrega === p.chave).length}</span>}</span>
                  <ItensPedido itens={itens} onMudar={setItens} categorias={conta.categorias} pontos={pontos} semCategoria={!conta.categoria_obrigatoria} entregaFixa={p.chave} compacto
                    objetos={conta.pode_objetos !== false ? objetos : undefined} onSalvarObjeto={conta.pode_objetos !== false ? salvarObjeto : undefined} onApagarObjeto={apagarObjeto} />
                </div>
              )}
              {(algumaConfirmacao || conta.pode_janela) && (
                <OpcoesPonto tipo={p.tipo} valor={p} onMudar={(d) => atualizar(p.chave, d)} liberadas={liberadas} padrao={conta.padrao_confirmacoes} comJanela={conta.pode_janela !== false} />
              )}
            </div>
          )} />
          <div className="linha-botoes">
            <button type="button" className="botao-texto" disabled={!podeEntrega} onClick={() => setPontos((l) => [...l, ponto("entrega")])}><Plus size={15} /> Entrega</button>
            {!conta.coleta_fixa && <button type="button" className="botao-texto" disabled={!podeColeta} onClick={() => setPontos((l) => [...l, ponto("coleta")])}><Plus size={15} /> Coleta</button>}
            {conta.pode_ida_volta !== false && <button type="button" className="botao-texto" disabled={!podeEntrega} title="O motoboy volta ao primeiro endereço (ex.: devolver canhoto, maquininha ou documento assinado)"
              onClick={() => setPontos((l) => { const o = l[0]; return o ? [...l, ponto("entrega", { endereco: o.endereco, lat: o.lat, lng: o.lng, contato_nome: o.contato_nome, contato_telefone: o.contato_telefone, instrucoes: "Retorno ao início" })] : l; })}>
              <Undo2 size={15} aria-hidden /> Ida e volta
            </button>}
          </div>
          {(conta.max_entregas || conta.max_coletas) ? <p className="dica" style={{ margin: 0 }}>Até {conta.max_entregas ? `${conta.max_entregas} entregas` : ""}{conta.max_entregas && conta.max_coletas ? " e " : ""}{conta.max_coletas ? `${conta.max_coletas} coletas` : ""} por pedido.</p> : null}
        </div>

        <div className={`cliente-cartao vidro${passo !== 1 ? " passo-oculto" : ""}`}>
          <span className="rotulo"><Boxes size={13} aria-hidden /> {nEntregas > 1 ? "O que vai para todas as entregas" : "Outros itens"}<Dica titulo="Itens" texto="Cada pacote fica no endereço para onde vai (em cada entrega, acima). Aqui ficam os itens que vão para todas as entregas ou que você ainda não ligou a um endereço." /></span>
          <ItensPedido itens={itens} onMudar={setItens} categorias={conta.categorias} pontos={pontos} semCategoria={!conta.categoria_obrigatoria} soGerais compacto
            objetos={conta.pode_objetos !== false ? objetos : undefined} onSalvarObjeto={conta.pode_objetos !== false ? salvarObjeto : undefined} onApagarObjeto={apagarObjeto} />
          {perigoso && <p className="alerta-perigo"><FlaskConical size={14} aria-hidden /> Produto perigoso: embale e identifique.</p>}
          {conta.pode_observacoes !== false && <textarea placeholder="Observações (opcional)" value={obs} maxLength={1000} onChange={(e) => setObs(e.target.value)} />}
        </div>
        {passo === 3 && <div className="cliente-cartao vidro"><span className="rotulo"><CheckCircle2 size={13} aria-hidden /> Tudo certo?</span>
          <p className="dica" style={{ margin: 0 }}>Confira o valor e o pagamento ao lado e toque em “Fazer pedido”.</p></div>}
        <div className="passos-nav">
          {passo > 0 && <button type="button" className="botao-texto" onClick={() => setPasso(passo - 1)}><ArrowLeft size={15} aria-hidden /> Voltar</button>}
          <span className="espaco" />
          {passo < PASSOS_PEDIDO.length - 1 && <button type="button" className="botao-ouro" onClick={() => { setPasso(passo + 1); window.scrollTo({ top: 0, behavior: "smooth" }); }}>Continuar: {PASSOS_PEDIDO[passo + 1]}</button>}
        </div>
      </div>

      <div className="cliente-lado">
        <div className="cliente-mapa vidro">
          <MapaCorridas paradas={pinos} rotaPlanejada={rota?.polyline} modoEscolha={escolhendo != null} enquadrar={chaveRota}
            aoClicar={async (lat, lng) => { const k = escolhendo; if (!k) return; setEscolhendo(null); atualizar(k, { lat, lng }); atualizar(k, { endereco: await geo.enderecoDoPonto(lat, lng) }); }} />
        </div>
        <div className="cliente-cartao vidro">
          <div className="resumo-rota">
            <div><span className="rotulo">Distância</span><strong>{formatarKm(rota?.distanciaM ?? orc?.distancia_m)}</strong></div>
            <div><span className="rotulo">Tempo</span><strong>{formatarDuracao(rota?.duracaoS)}</strong></div>
            <div><span className="rotulo">Valor</span><strong className="texto-grad">{(orc as { oculto?: boolean } | null)?.oculto ? "Revisando" : orc ? moedaBr(orc.total) : "—"}</strong></div>
          </div>
          {!orc && <p className="dica" style={{ margin: 0 }}>Localize os endereços para ver o valor.</p>}
          {conta.cobranca === "pre_pago" ? (
            <div className="segmentado" style={{ gridTemplateColumns: `repeat(${Math.max(1, conta.metodos.length)}, 1fr)` }}>
              {conta.metodos.map((m) => (
                <button key={m} type="button" className={metodo === m ? "ativo" : ""} onClick={() => setMetodo(m)}>
                  {m === "pix" ? <QrCode size={14} aria-hidden /> : <CreditCard size={14} aria-hidden />} {m === "pix" ? "PIX" : "Cartão"}
                </button>
              ))}
            </div>
          ) : <p className="dica" style={{ margin: 0 }}><FileText size={11} aria-hidden /> Vai para a sua fatura.</p>}
          <button className="botao-ouro" disabled={enviando} onClick={enviar}><Truck size={17} aria-hidden /> {enviando ? "Enviando…" : "Fazer pedido"}</button>
          {conta.pode_modelos !== false && (salvarComo == null
            ? <button type="button" className="botao-texto" onClick={() => setSalvarComo(modelos.find((m) => m.id === modeloId)?.nome ?? "")}><BookmarkPlus size={15} aria-hidden /> Salvar como modelo</button>
            : (
              <div className="linha-botoes">
                <input autoFocus placeholder="Nome do modelo (ex.: Banco toda segunda)" value={salvarComo} maxLength={60} onChange={(e) => setSalvarComo(e.target.value)}
                  onKeyDown={(e) => { if (e.key === "Enter") void salvarModelo(); }} style={{ flex: 1, minWidth: 0 }} />
                <button type="button" className="botao-texto" disabled={!salvarComo.trim()} onClick={salvarModelo}><CheckCircle2 size={15} aria-hidden /> Salvar</button>
                <button type="button" className="icone" aria-label="Cancelar" onClick={() => setSalvarComo(null)}><X size={14} /></button>
              </div>
            ))}
        </div>
      </div>
    </div>
  );
}

// ------------------------------------------------------------------ faturas

function Faturas({ conta, faturas, pedidos }: { conta: Conta; faturas: FaturaC[]; pedidos: PedidoC[] }) {
  const [pagarFatura, setPagarFatura] = useState<string | null>(null);
  const [aberta, setAberta] = useState<string | null>(null);
  if (conta.cobranca === "pre_pago") {
    const pagos = pedidos.filter((p) => p.pagamento_status === "pago");
    const pend = pedidos.filter((p) => p.pagamento_status === "pendente" && !["cancelado", "recusado"].includes(p.status));
    return (
      <>
        <div className="grade-3">
          <div className="bloco vidro"><span className="rotulo"><Wallet size={12} aria-hidden /> Pago</span><strong className="figura texto-grad" style={{ fontSize: 26 }}>{moedaBr(pagos.reduce((s, p) => s + Number(p.valor ?? 0), 0))}</strong></div>
          <div className="bloco vidro"><span className="rotulo"><Clock size={12} aria-hidden /> A pagar</span><strong className="figura" style={{ fontSize: 22 }}>{moedaBr(pend.reduce((s, p) => s + Number(p.valor ?? 0), 0))}</strong><span className="dica">{pend.length} pedido(s)</span></div>
        </div>
        <div className="cliente-cartao vidro">
          <table className="tabela"><thead><tr><th>Pedido</th><th>Data</th><th>Forma</th><th>Situação</th><th>Valor</th></tr></thead>
            <tbody>{[...pend, ...pagos].map((p) => <tr key={p.id}><td>#{p.numero}</td><td>{quando(p.criado_em)}</td><td>{p.pagamento_metodo === "pix" ? "PIX" : p.pagamento_metodo === "cartao" ? "Cartão" : "—"}</td><td>{p.pagamento_status === "pago" ? "Pago" : "Aguardando"}</td><td>{moedaBr(p.valor)}</td></tr>)}</tbody></table>
        </div>
      </>
    );
  }
  const abertas = faturas.filter((f) => f.status === "emitida");
  return (
    <>
      <div className="grade-3">
        <div className="bloco vidro"><span className="rotulo"><Receipt size={12} aria-hidden /> A pagar</span><strong className="figura texto-grad" style={{ fontSize: 26 }}>{moedaBr(abertas.reduce((s, f) => s + Number(f.total), 0))}</strong><span className="dica">{abertas.length} fatura(s)</span></div>
        <div className="bloco vidro"><span className="rotulo"><Clock size={12} aria-hidden /> Ainda sem fatura</span><strong className="figura" style={{ fontSize: 22 }}>{moedaBr(conta.em_aberto)}</strong><span className="dica">entra na próxima ({CICLO[conta.fatura_ciclo] ?? ""})</span></div>
        <div className="bloco vidro"><span className="rotulo"><CheckCircle2 size={12} aria-hidden /> Pagas</span><strong className="figura" style={{ fontSize: 22 }}>{faturas.filter((f) => f.status === "paga").length}</strong></div>
      </div>
      <div className="cliente-cartao vidro">
        {faturas.length === 0 ? <p className="vazio">Nenhuma fatura ainda.</p> : (
          <table className="tabela tabela-clicavel"><thead><tr><th>Fatura</th><th>Período</th><th>Vencimento</th><th>Situação</th><th>Total</th></tr></thead>
            <tbody>{faturas.map((f) => (
              <tr key={f.id} className={aberta === f.id ? "ativo" : ""} onClick={() => setAberta(aberta === f.id ? null : f.id)}>
                <td>{f.numero}</td><td>{dataBr(f.inicio)} – {dataBr(f.fim)}</td><td>{dataBr(f.vencimento)}</td>
                <td><span className="selo" style={{ color: f.status === "paga" ? "#2ecc71" : "#60a5fa" }}>{f.status === "paga" ? "Paga" : "Em aberto"}</span></td><td><strong>{moedaBr(f.total)}</strong></td>
              </tr>
            ))}</tbody></table>
        )}
      </div>
      {faturas.filter((f) => f.id === aberta).map((f) => (
        <div key={f.id} className="cliente-cartao vidro">
          <h3 className="display" style={{ margin: 0 }}>Fatura {f.numero}</h3>
          <table className="tabela"><thead><tr><th>Pedido</th><th>Entregue</th><th>Entregas</th><th>Valor</th></tr></thead>
            <tbody>{f.pedidos.map((p) => <tr key={p.numero}><td>#{p.numero}</td><td>{quando(p.concluido_em)}</td><td>{p.entregas}</td><td>{moedaBr(p.valor)}</td></tr>)}</tbody></table>
          <div className="orcamento">
            <div className="orcamento-linha"><span>Subtotal</span><strong>{moedaBr(f.subtotal)}</strong></div>
            {Number(f.ajuste) !== 0 && <div className="orcamento-linha"><span>Ajuste{f.ajuste_motivo && <small>{f.ajuste_motivo}</small>}</span><strong>{moedaBr(f.ajuste)}</strong></div>}
            <div className="orcamento-linha total"><span>Total</span><strong>{moedaBr(f.total)}</strong></div>
          </div>
          <p className="dica" style={{ margin: 0 }}>{f.status === "paga" ? `Paga em ${quando(f.paga_em)}.` : `Vence em ${dataBr(f.vencimento)}. Pague por PIX ou cartão.`}</p>
          {f.status === "emitida" && <div className="linha-botoes"><button type="button" className="botao-ouro" onClick={() => setPagarFatura(f.id)}><CreditCard size={15} aria-hidden /> Pagar agora</button></div>}
          {pagarFatura === f.id && <Pagar alvo="fatura" id={f.id} valor={Number(f.total)} onFechar={() => setPagarFatura(null)} onPago={() => { setPagarFatura(null); window.location.reload(); }} />}
        </div>
      ))}
    </>
  );
}

// ------------------------------------------------------------------ conta

/** Ser cliente de mais de uma transportadora: as minhas e pedir para outra. */
function OutrasEmpresas() {
  const [minhas, setMinhas] = useState<{ empresa_id: string; nome: string; cliente: string; slug: string | null; atual: boolean }[] | null>(null);
  const [todas, setTodas] = useState<EmpresaCard[] | null>(null);
  const [abrir, setAbrir] = useState(false);
  const carregar = () => void supabase().rpc("minhas_empresas_cliente").then(({ data }) => setMinhas((data ?? []) as typeof minhas));
  useEffect(carregar, []);
  useEffect(() => { if (abrir && !todas) void supabase().rpc("empresas_cadastro").then(({ data }) => setTodas((data ?? []) as EmpresaCard[])); }, [abrir, todas]);
  async function pedir(slug: string) {
    const { data, error } = await supabase().rpc("pedir_outra_empresa", { p_slug: slug });
    if (error) return toast(error.message.includes("ja_cliente") ? "Você já é cliente dessa transportadora." : error.message.includes("ja_pedido") ? "Seu pedido para essa transportadora já está em análise."
      : error.message.includes("cadastro_desligado") ? "Essa transportadora não está aceitando cadastros agora." : "Não deu para pedir agora.", "erro");
    toast((data as { status?: string })?.status === "aprovado" ? "Pronto: você já pode pedir para ela (troque no topo)." : "Pedido enviado. Assim que a transportadora aprovar, ela aparece aqui.", "ok");
    setAbrir(false); carregar();
  }
  async function trocar(id: string) {
    const { error } = await supabase().rpc("trocar_empresa_cliente", { p_empresa: id });
    if (error) return toast("Não deu para trocar agora.", "erro");
    window.location.reload();
  }
  const ja = new Set((minhas ?? []).map((m) => m.slug).filter(Boolean));
  return (
    <div className="cliente-cartao vidro">
      <h3 className="display" style={{ margin: 0 }}>Transportadoras</h3>
      <p className="dica" style={{ margin: 0 }}>A mesma conta pode pedir para mais de uma transportadora. Escolha com qual está pedindo agora.</p>
      <div className="linha-chips">
        {(minhas ?? []).map((m) => (
          <button key={m.empresa_id} type="button" className={`chip${m.atual ? " ativo" : ""}`} disabled={m.atual} onClick={() => trocar(m.empresa_id)}>
            {m.atual ? <BadgeCheck size={13} aria-hidden /> : <Building2 size={13} aria-hidden />} {m.nome}
          </button>
        ))}
      </div>
      {!abrir ? <button className="botao-texto" style={{ justifySelf: "start" }} onClick={() => setAbrir(true)}><Plus size={15} aria-hidden /> Ser cliente de outra transportadora</button>
        : todas === null ? <p className="dica">Carregando…</p>
        : <EmpresasCards empresas={todas.filter((e) => !ja.has(e.slug))} onEscolher={pedir} />}
    </div>
  );
}

function MinhaConta({ conta }: { conta: Conta }) {
  return (
    <>
      <div className="cliente-cartao vidro">
        <div className="cliente-pedido-topo"><span className="item-icone"><Icone nome={conta.icone} padrao={Building2} size={18} /></span><h3 className="display" style={{ margin: 0 }}>{conta.nome}</h3></div>
        <div className="dados-conta">
          <div><span className="rotulo">{conta.tipo === "pf" ? "CPF" : "CNPJ"}</span><strong>{formatarDoc(conta.documento)}</strong></div>
          <div><span className="rotulo">Telefone</span><strong>{conta.telefone ?? "—"}</strong></div>
          <div><span className="rotulo">E-mail</span><strong>{conta.email ?? "—"}</strong></div>
          <div><span className="rotulo">Coleta padrão</span><strong>{conta.endereco ?? "—"}</strong></div>
          <div><span className="rotulo">Pagamento</span><strong>{conta.cobranca === "credito" ? `Fatura ${CICLO[conta.fatura_ciclo] ?? ""}` : conta.metodos.map((m) => (m === "pix" ? "PIX" : "Cartão")).join(" ou ")}</strong></div>
        </div>
        <p className="dica" style={{ margin: 0 }}>Para mudar algum dado, fale com a empresa.</p>
      </div>
      <OutrasEmpresas />
      <CoresDoSite />
      {conta.troca_senha !== false && <TrocarSenha />}
      <div className="bloco vidro linha-botoes">
        <a className="botao-texto" href="/suporte?p=cliente" target="_blank" rel="noopener"><LifeBuoy size={15} aria-hidden /> Central de ajuda</a>
        <button type="button" className="botao-texto" onClick={() => abrirTour("cliente")}><Compass size={15} aria-hidden /> Ver o tour</button>
      </div>
    </>
  );
}

function ChatCliente() {
  const [eu, setEu] = useState<string | null>(null);
  useEffect(() => { void supabase().auth.getUser().then(({ data }) => setEu(data.user?.id ?? null)); }, []);
  if (!eu) return <p className="subtitulo" style={{ padding: 24 }}>Carregando…</p>;
  return <Chat meuId={eu} gestor={false} />;
}

function CoresDoSite() {
  const { estilo, definirEstilo } = useTema();
  return (
    <div className="cliente-cartao vidro">
      <div className="menu-cores" style={{ padding: 0 }}>
        <div className="menu-cores-topo"><Palette size={17} aria-hidden /> Cores do site<small>{ESTILOS.find((e) => e.k === estilo)?.rotulo}</small></div>
        <div className="menu-cores-bolas" style={{ justifyContent: "flex-start", gap: 12 }}>
          {ESTILOS.map((e) => (
            <button key={e.k} type="button" title={e.rotulo} aria-label={e.rotulo} className={`menu-cor${estilo === e.k ? " ativo" : ""}`} onClick={() => definirEstilo(e.k)}>
              <span style={{ background: `linear-gradient(135deg, ${e.fundo} 50%, ${e.cor} 50%)` }} />
            </button>
          ))}
        </div>
      </div>
      <p className="dica" style={{ margin: 0 }}>Fica guardado neste aparelho. O claro/escuro fica no botão do topo.</p>
    </div>
  );
}

function formatarDoc(d: string | null): string {
  const n = (d ?? "").replace(/\D/g, "");
  if (n.length === 14) return n.replace(/^(\d{2})(\d{3})(\d{3})(\d{4})(\d{2})$/, "$1.$2.$3/$4-$5");
  if (n.length === 11) return n.replace(/^(\d{3})(\d{3})(\d{3})(\d{2})$/, "$1.$2.$3-$4");
  return d ?? "—";
}

function TrocarSenha() {
  const [nova, setNova] = useState("");
  const [conf, setConf] = useState("");
  const [salvando, setSalvando] = useState(false);
  const erro = nova && nova.length < 8 ? "A senha precisa ter pelo menos 8 caracteres." : conf && conf !== nova ? "As senhas não são iguais." : null;
  async function salvar() {
    if (erro || !nova) return;
    setSalvando(true);
    const { error } = await supabase().auth.updateUser({ password: nova });
    setSalvando(false);
    if (error) return toast(/same|different/i.test(error.message) ? "A senha nova precisa ser diferente da atual." : /weak|short/i.test(error.message) ? "Senha fraca demais. Use letras e números." : error.message, "erro");
    setNova(""); setConf("");
    toast("Senha trocada. Use a nova no próximo acesso.", "ok");
  }
  return (
    <div className="cliente-cartao vidro">
      <span className="rotulo"><KeyRound size={13} aria-hidden /> Trocar senha</span>
      <div className="dados-conta">
        <label className="campo"><span>Senha nova</span><input type="password" autoComplete="new-password" value={nova} onChange={(e) => setNova(e.target.value)} /></label>
        <label className="campo"><span>Repita a senha</span><input type="password" autoComplete="new-password" value={conf} onChange={(e) => setConf(e.target.value)} /></label>
      </div>
      {erro && <p className="erro" style={{ margin: 0 }}>{erro}</p>}
      <button className="botao-ouro" style={{ alignSelf: "flex-start" }} disabled={!nova || !conf || Boolean(erro) || salvando} onClick={salvar}>
        <Lock size={15} aria-hidden /> {salvando ? "Salvando…" : "Salvar senha"}
      </button>
    </div>
  );
}

/** Tour do site do cliente: abre na primeira vez; depois, em Minha conta → Ver o tour. */
const TOUR_CLIENTE: PassoTour[] = [
  { titulo: "Bem-vindo", texto: "Um passeio rápido pelo seu painel. Dá para rever quando quiser, em Minha conta." },
  { alvo: '[data-tour="aba-novo"]', titulo: "Novo pedido", texto: "Marque a coleta e as entregas, diga o que vai em cada uma e escolha agora ou agendado. O mapa mostra o caminho." },
  { alvo: '[data-tour="aba-pedidos"]', titulo: "Pedidos", texto: "Todos os seus pedidos. Abra um para ver o mapa, a situação de cada entrega e quem recebeu." },
  { alvo: '[data-tour="aba-faturas"]', titulo: "Faturas e pagamentos", texto: "No crédito, as faturas de cada ciclo. No pagamento antecipado, os pagamentos de cada pedido." },
  { alvo: '[data-tour="aba-conta"]', titulo: "Minha conta", texto: "Seus dados, a troca de senha, a central de ajuda e este tour." },
];

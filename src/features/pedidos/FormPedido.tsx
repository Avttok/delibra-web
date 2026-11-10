"use client";

import { useEffect, useMemo, useState } from "react";
import { ArrowLeft, Boxes, CalendarClock, CheckCircle2, FlaskConical, MapPinned, PackagePlus, Plus, Receipt, Trash2, UserRound, X, Zap } from "lucide-react";
import { supabase } from "@/lib/supabase/client";
import { geo, type Referencia, type Rota, distanciasColetaEntrega } from "@/features/geo";
import { CampoEndereco } from "@/features/corridas/NovaCorrida";
import { CampoReferencias } from "@/features/corridas/CampoReferencias";
import { MapaCorridas, type PinoParada } from "@/features/corridas/MapaCorridas";
import { useEmpresas } from "@/features/corridas/dados";
import { formatarDuracao, formatarKm } from "@/features/corridas/tipos";
import { paraCampo, sugestaoHorario } from "@/features/corridas/planejadas";
import { useModoTeste } from "@/features/teste/modoTeste";
import { CabecaPagina } from "@/features/ui/CabecaPagina";
import { toast } from "@/features/ui/toast";
import { moedaBr, traduzir, type Categoria, type Orcamento, type TipoPedido } from "./tipos";
import { ItensPedido, faltandoItens, itensParaEnvio, type ItemForm, type ObjetoSalvo } from "./ItensPedido";
import { OpcoesPonto, type Confirmacao, type OpcoesDoPonto } from "./OpcoesPonto";
import { useConfiguracoes } from "@/features/configuracoes/useConfiguracoes";
import { ListaOrdenavel } from "@/features/ui/ListaOrdenavel";
import { RegrasPedido } from "./RegrasPedido";

interface Ponto extends OpcoesDoPonto { chave: string; tipo: "coleta" | "entrega"; endereco: string; lat: number | null; lng: number | null; contato_nome: string; contato_telefone: string; instrucoes: string; referencias: Referencia[] }

let seq = 0;
const ponto = (tipo: Ponto["tipo"], base: Partial<Ponto> = {}): Ponto => ({ chave: `p${++seq}`, tipo, endereco: "", lat: null, lng: null, contato_nome: "", contato_telefone: "", instrucoes: "", referencias: [], ...base });

/** Lançar um pedido em nome de um cliente (ou avulso). Vira rota pelo roteirizador. */
export function FormPedido({ onCriado, onVoltar }: { onCriado: (id: string) => void; onVoltar: () => void }) {
  const { empresas } = useEmpresas();
  const { teste } = useModoTeste();
  const [categorias, setCategorias] = useState<Categoria[]>([]);
  const [tipos, setTipos] = useState<TipoPedido[]>([]);
  const [cliente, setCliente] = useState<string>("");
  const [avulso, setAvulso] = useState("");
  const [agendar, setAgendar] = useState(false);
  const [horario, setHorario] = useState(() => paraCampo(sugestaoHorario(60)));
  const [tipoPedido, setTipoPedido] = useState("padrao");
  const [urgente, setUrgente] = useState(false);
  const [pontos, setPontos] = useState<Ponto[]>(() => [ponto("coleta"), ponto("entrega")]);
  const [itens, setItens] = useState<ItemForm[]>([]);
  const [regras, setRegras] = useState<Record<string, unknown>>({});
  const [obs, setObs] = useState("");
  const [rota, setRota] = useState<Rota | null>(null);
  const [orc, setOrc] = useState<Orcamento | null>(null);
  const [escolhendo, setEscolhendo] = useState<string | null>(null);
  const [aberto, setAberto] = useState<string | null>(null);
  const [enviando, setEnviando] = useState(false);
  // o gestor pode pedir qualquer confirmação em qualquer ponto; o padrão da rota aparece fixo nas entregas
  const cfg = useConfiguracoes();
  const padraoConf: Partial<Record<Confirmacao, boolean>> = { foto: cfg.padrao_exige_foto === true, nome: cfg.padrao_exige_nome !== false, assinatura: cfg.padrao_exige_assinatura === true, codigo: cfg.padrao_exige_codigo === true };
  const todasConf = { foto: true, nome: true, assinatura: true, codigo: true };
  // objetos que o cliente escolhido salvou
  const [objetos, setObjetos] = useState<ObjetoSalvo[]>([]);
  useEffect(() => {
    if (!cliente) { setObjetos([]); return; }
    supabase().from("cliente_objetos").select("id,nome,dados,usos").eq("empresa_id", cliente).order("usos", { ascending: false }).then(({ data }) => setObjetos((data ?? []) as ObjetoSalvo[]));
  }, [cliente]);

  useEffect(() => {
    const sb = supabase();
    sb.from("categorias_produto").select("*").eq("ativa", true).order("ordem").then(({ data }) => setCategorias((data ?? []) as Categoria[]));
    sb.from("tipos_pedido").select("*").eq("ativo", true).order("ordem").then(({ data }) => setTipos((data ?? []) as TipoPedido[]));
  }, []);
  // coleta padrão do cliente
  useEffect(() => {
    const e = empresas.find((x) => x.id === cliente);
    if (e?.endereco && e.lat != null && pontos[0].tipo === "coleta" && !pontos[0].endereco) {
      setPontos((l) => l.map((p, i) => (i === 0 ? { ...p, endereco: e.endereco!, lat: e.lat, lng: e.lng, instrucoes: e.instrucoes_coleta ?? "" } : p)));
    }
  }, [cliente]); // eslint-disable-line react-hooks/exhaustive-deps

  const atualizar = (k: string, d: Partial<Ponto>) => setPontos((l) => l.map((p) => (p.chave === k ? { ...p, ...d } : p)));

  // rota pelas ruas (coletas e depois entregas, na ordem digitada)
  const ordenados = useMemo(() => [...pontos.filter((p) => p.tipo === "coleta"), ...pontos.filter((p) => p.tipo === "entrega")], [pontos]);
  const chaveRota = ordenados.map((p) => `${p.lat},${p.lng}`).join("|");
  useEffect(() => {
    const ok = ordenados.filter((p) => p.lat != null);
    if (ok.length < 2 || ok.length !== ordenados.length) { setRota(null); return; }
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
  const chaveOrc = JSON.stringify([cliente, tipoPedido, urgente, quandoIso, rota?.distanciaM, pontos.map((p) => [p.tipo, p.lat, p.lng]), distEnt, dadosItens, regras]);
  useEffect(() => {
    if (pontos.some((p) => p.lat == null)) { setOrc(null); return; }
    const t = setTimeout(async () => {
      const { data } = await supabase().rpc("orcar_previa", { dados: {
        empresa_id: cliente || null, tipo: agendar ? "planejado" : "express", tipo_pedido: tipoPedido, quando: quandoIso, urgente,
        distancia_m: rota?.distanciaM ?? null, pontos: pontos.map((p, i) => comDist({ tipo: p.tipo, lat: p.lat, lng: p.lng }, i)), itens: dadosItens, regras } });
      setOrc((data as Orcamento) ?? null);
    }, 400);
    return () => clearTimeout(t);
  }, [chaveOrc]); // eslint-disable-line react-hooks/exhaustive-deps

  async function criar() {
    if (pontos.some((p) => p.lat == null)) return toast("Localize todos os endereços.", "aviso");
    const falta = faltandoItens(itens, categorias);
    if (falta) return toast(falta, "aviso");
    setEnviando(true);
    const { data, error } = await supabase().rpc("criar_pedido", { dados: {
      empresa_id: cliente || null, cliente_nome: cliente ? null : avulso.trim() || null, quando: quandoIso, urgente, tipo_pedido: tipoPedido, teste,
      observacoes: obs.trim() || null, distancia_m: rota?.distanciaM ?? null,
      pontos: pontos.map(({ chave, ...p }, i) => { void chave; return comDist(p, i); }), itens: dadosItens, regras } });
    setEnviando(false);
    if (error) return toast(traduzir(error.message), "erro");
    toast("O roteirizador já está montando a rota.", "ok", { titulo: "Pedido criado" });
    onCriado(data as string);
  }

  const pinos: PinoParada[] = pontos.filter((p) => p.lat != null).map((p, i) => ({ chave: p.chave, lat: p.lat!, lng: p.lng!, tipo: p.tipo, rotulo: String(i + 1) }));
  const perigoso = dadosItens.some((x) => categorias.find((k) => k.id === x.categoria_id)?.perigoso);

  return (
    <>
      <aside className="lateral entrar">
        <button className="botao-texto" style={{ alignSelf: "flex-start" }} onClick={onVoltar}><ArrowLeft size={15} aria-hidden /> Pedidos</button>
        <CabecaPagina icone={PackagePlus} titulo="Novo pedido" subtitulo={teste ? "Pedido de teste" : "O sistema monta as rotas sozinho"} />
        <section className="bloco">
          <span className="rotulo">Cliente</span>
          <select value={cliente} onChange={(e) => setCliente(e.target.value)}>
            <option value="">Avulso (sem cadastro)</option>
            {empresas.map((e) => <option key={e.id} value={e.id}>{e.nome}</option>)}
          </select>
          {!cliente && <input placeholder="Nome do cliente avulso" value={avulso} onChange={(e) => setAvulso(e.target.value)} />}
        </section>
        <section className="bloco">
          <span className="rotulo">Quando</span>
          <div className="segmentado" style={{ gridTemplateColumns: "1fr 1fr" }}>
            <button type="button" className={!agendar ? "ativo" : ""} onClick={() => setAgendar(false)}><Zap size={14} aria-hidden /> Express</button>
            <button type="button" className={agendar ? "ativo" : ""} onClick={() => setAgendar(true)}><CalendarClock size={14} aria-hidden /> Planejado</button>
          </div>
          {agendar && <input type="datetime-local" value={horario} onChange={(e) => setHorario(e.target.value)} />}
          <label className="campo"><span>Tipo de pedido</span>
            <select value={tipoPedido} onChange={(e) => setTipoPedido(e.target.value)}>{tipos.map((t) => <option key={t.chave} value={t.chave}>{t.nome}</option>)}</select></label>
          <label className="opcao"><span><Zap size={14} aria-hidden style={{ color: "var(--vermelho)" }} /> Urgente</span><input type="checkbox" role="switch" checked={urgente} onChange={(e) => setUrgente(e.target.checked)} /></label>
        </section>
        <section className="bloco">
          <span className="rotulo">Endereços</span>
          <ListaOrdenavel itens={pontos} chave={(p) => p.chave} onMudar={setPontos} render={(p, i, alca) => (
            <div className={`parada-form ${p.tipo}`}>
              <div className="parada-topo">
                {alca}
                <span className={`pino-mini ${p.tipo}`}>{i + 1}</span>
                <select value={p.tipo} onChange={(e) => atualizar(p.chave, { tipo: e.target.value as Ponto["tipo"] })}>
                  <option value="coleta">Coleta</option><option value="entrega">Entrega</option>
                </select>
                <span className="espaco" />
                {pontos.length > 2 && <button type="button" className="icone" title="Remover" onClick={() => setPontos((l) => l.filter((x) => x.chave !== p.chave))}><X size={14} /></button>}
              </div>
              <CampoEndereco valor={p.endereco} onTexto={(t) => atualizar(p.chave, { endereco: t, lat: null, lng: null })} onEscolher={(e) => atualizar(p.chave, { endereco: e.descricao, lat: e.lat, lng: e.lng })} />
              <div className="parada-acoes">
                <button type="button" className={`link ${escolhendo === p.chave ? "ativo" : ""}`} onClick={() => setEscolhendo(escolhendo === p.chave ? null : p.chave)}>
                  <MapPinned size={13} aria-hidden /> {escolhendo === p.chave ? "Clique no mapa…" : "Marcar no mapa"}
                </button>
                {p.lat != null ? <span className="ok"><CheckCircle2 size={13} aria-hidden /> Localizado</span> : <span className="pendente">Sem localização</span>}
                <button type="button" className="link" onClick={() => setAberto(aberto === p.chave ? null : p.chave)}><UserRound size={13} aria-hidden /> {aberto === p.chave ? "Menos" : "Contato e referências"}</button>
              </div>
              {aberto === p.chave && (
                <div className="parada-extra">
                  <input placeholder="Nome do contato" value={p.contato_nome} onChange={(e) => atualizar(p.chave, { contato_nome: e.target.value })} />
                  <input placeholder="Telefone" value={p.contato_telefone} onChange={(e) => atualizar(p.chave, { contato_telefone: e.target.value })} />
                  <input placeholder="Instruções (portaria, bloco…)" value={p.instrucoes} onChange={(e) => atualizar(p.chave, { instrucoes: e.target.value })} />
                  <CampoReferencias valor={p.referencias} lat={p.lat} lng={p.lng} onMudar={(r) => atualizar(p.chave, { referencias: r })} />
                </div>
              )}
              {p.tipo === "entrega" && (
                <div className="itens-ponto">
                  <span className="rotulo"><Boxes size={12} aria-hidden /> O que vai para esta entrega{itens.some((x) => x.entrega === p.chave) && <span className="filtro-n">{itens.filter((x) => x.entrega === p.chave).length}</span>}</span>
                  <ItensPedido itens={itens} onMudar={setItens} categorias={categorias} pontos={pontos} objetos={objetos} entregaFixa={p.chave} compacto />
                </div>
              )}
              <OpcoesPonto tipo={p.tipo} valor={p} onMudar={(d) => atualizar(p.chave, d)} liberadas={todasConf} padrao={padraoConf} comJanela />
            </div>
          )} />
          <div className="linha-botoes">
            <button type="button" className="botao-texto" onClick={() => setPontos((l) => [...l, ponto("coleta")])}><Plus size={15} /> Coleta</button>
            <button type="button" className="botao-texto" onClick={() => setPontos((l) => [...l, ponto("entrega")])}><Plus size={15} /> Entrega</button>
          </div>
        </section>
      </aside>
      <main className="conteudo">
        <div className="pedido-form-corpo entrar">
          <div className="pedido-mapa vidro">
            <MapaCorridas paradas={pinos} rotaPlanejada={rota?.polyline} modoEscolha={escolhendo != null} enquadrar={chaveRota}
              aoClicar={async (lat, lng) => { const k = escolhendo; if (!k) return; setEscolhendo(null); atualizar(k, { lat, lng }); atualizar(k, { endereco: await geo.enderecoDoPonto(lat, lng) }); }} />
          </div>
          <section className="formulario vidro">
            <h3 className="display" style={{ margin: 0 }}><Boxes size={18} aria-hidden /> Itens</h3>
            {itens.length === 0 && <p className="dica" style={{ margin: 0 }}>Toque no tipo do que vai ser levado. Sem itens, o pedido conta como 1 volume sem peso.</p>}
            <p className="dica" style={{ margin: 0 }}>Cada pacote fica na entrega para onde vai (na lista de endereços). Aqui, os que vão para todas ou ainda sem endereço.</p>
            <ItensPedido itens={itens} onMudar={setItens} categorias={categorias} pontos={pontos} objetos={objetos} soGerais />
            {perigoso && <p className="alerta-perigo"><FlaskConical size={14} aria-hidden /> Produto perigoso: vai com cuidado especial e, se a regra estiver ligada, em rota própria.</p>}
            <textarea placeholder="Observações para o motoboy" value={obs} onChange={(e) => setObs(e.target.value)} />
          </section>
          <RegrasPedido valor={regras} onMudar={setRegras} />
          <section className="formulario vidro">
            <h3 className="display" style={{ margin: 0 }}><Receipt size={18} aria-hidden /> Orçamento</h3>
            <div className="resumo-rota">
              <div><span className="rotulo">Distância</span><strong>{formatarKm(rota?.distanciaM ?? orc?.distancia_m)}</strong></div>
              <div><span className="rotulo">Tempo</span><strong>{formatarDuracao(rota?.duracaoS)}</strong></div>
              <div><span className="rotulo">Total</span><strong className="texto-grad">{orc ? moedaBr(orc.total) : "—"}</strong></div>
            </div>
            {orc ? <OrcamentoDetalhe orc={orc} /> : <p className="dica" style={{ margin: 0 }}>Localize os endereços para calcular.</p>}
            <button className="botao-ouro" disabled={enviando} onClick={criar}><PackagePlus size={17} aria-hidden /> {enviando ? "Criando…" : "Criar pedido"}</button>
          </section>
        </div>
      </main>
    </>
  );
}

/** As linhas do orçamento, como o cliente também vê. */
export function OrcamentoDetalhe({ orc }: { orc: Orcamento }) {
  return (
    <div className="orcamento">
      {orc.linhas.map((l, i) => (
        <div key={i} className="orcamento-linha"><span>{l.rotulo}{l.detalhe && <small>{l.detalhe}</small>}</span><strong>{moedaBr(l.valor)}</strong></div>
      ))}
      {orc.percentuais.map((p, i) => (
        <div key={`p${i}`} className="orcamento-linha pct"><span>{p.rotulo}</span><strong>+{p.pct.toLocaleString("pt-BR")}%</strong></div>
      ))}
      {orc.minimo > 0 && <div className="orcamento-linha pct"><span>Mínimo</span><strong>{moedaBr(orc.minimo)}</strong></div>}
      <div className="orcamento-linha total"><span>Total</span><strong>{moedaBr(orc.total)}</strong></div>
      <p className="dica" style={{ margin: 0 }}>
        {orc.volumes} volume{orc.volumes === 1 ? "" : "s"} · peso real {orc.peso_real_kg.toLocaleString("pt-BR")} kg · cubado {orc.peso_cubado_kg.toLocaleString("pt-BR")} kg
        {orc.perigoso && " · perigoso"}
      </p>
    </div>
  );
}

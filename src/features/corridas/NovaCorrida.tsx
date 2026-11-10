"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import {
  ArrowDown, ArrowLeft, ArrowUp, Building2, CalendarClock, Repeat, Zap, CheckCircle2, FlaskConical, TrendingUp, UserRound as Pessoa, MapPin, MapPinned, PackagePlus, Plus, Radar, Receipt, Send, StickyNote, UserRound, X,
} from "lucide-react";
import { supabase } from "@/lib/supabase/client";
import { geo, type Endereco, type Referencia, type Rota } from "@/features/geo";
import { ListaOrdenavel } from "@/features/ui/ListaOrdenavel";
import { CampoReferencias } from "./CampoReferencias";
import { useConta } from "@/features/conta/conta";
import { DIAS_SEMANA, formatarQuando, gerarDatas, paraCampo, relativo, sugestaoHorario, type Repeticao } from "./planejadas";
import { moeda, orcar, ROTULO_MODALIDADE, type Modalidade } from "@/features/precos/estrategias";
import { useModoTeste } from "@/features/teste/modoTeste";
import { useConfiguracoes } from "@/features/configuracoes/useConfiguracoes";
import { CabecaPagina } from "@/features/ui/CabecaPagina";
import { ROTULO_STATUS } from "@/features/rastreamento/tipos";
import { MapaCorridas, type PinoParada } from "./MapaCorridas";
import { traduzirErro, useEmpresas, useEquipe } from "./dados";
import { formatarDuracao, formatarKm, type TipoParada } from "./tipos";

interface ParadaForm {
  chave: string;
  tipo: TipoParada;
  endereco: string;
  lat: number | null;
  lng: number | null;
  contato_nome: string;
  contato_telefone: string;
  instrucoes: string;
  referencias: Referencia[];
}

let seq = 0;
const novaParada = (tipo: TipoParada, base: Partial<ParadaForm> = {}): ParadaForm => ({
  chave: `p${++seq}`, tipo, endereco: "", lat: null, lng: null, contato_nome: "", contato_telefone: "", instrucoes: "", referencias: [], ...base,
});

// ------------------------------------------------------------------ campo de endereço

export function CampoEndereco({ valor, onTexto, onEscolher }: { valor: string; onTexto: (t: string) => void; onEscolher: (e: Endereco) => void }) {
  const [sugestoes, setSugestoes] = useState<Endereco[]>([]);
  const [aberto, setAberto] = useState(false);
  const digitado = useRef(false);

  useEffect(() => {
    if (!digitado.current) return;
    const t = setTimeout(async () => {
      const r = await geo.buscarEnderecos(valor);
      setSugestoes(r);
      setAberto(r.length > 0);
    }, 600);
    return () => clearTimeout(t);
  }, [valor]);

  return (
    <div className="campo-endereco">
      <input value={valor} placeholder="Rua, número, cidade"
        onChange={(e) => { digitado.current = true; onTexto(e.target.value); }}
        onFocus={() => setAberto(sugestoes.length > 0)}
        onBlur={() => setTimeout(() => setAberto(false), 150)} />
      {aberto && (
        <ul className="sugestoes">
          {sugestoes.map((s, i) => (
            <li key={i}>
              <button type="button" onMouseDown={() => { digitado.current = false; onEscolher(s); setAberto(false); }}>
                <MapPin size={13} aria-hidden style={{ verticalAlign: -2, marginRight: 6 }} />{s.descricao}
              </button>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

// ------------------------------------------------------------------ formulário

export function NovaCorrida({ onCriada, onVoltar }: { onCriada: (id: string) => void; onVoltar: () => void }) {
  const { empresas, favoritos } = useEmpresas();
  const equipe = useEquipe();
  const cfg = useConfiguracoes();

  const [tipoCliente, setTipoCliente] = useState<"avulso" | "cliente">("avulso");
  const [empresaId, setEmpresaId] = useState("");
  // avulso: modalidade e preço só desta corrida
  const [modAvulso, setModAvulso] = useState<Modalidade>("por_km");
  const [kmAvulso, setKmAvulso] = useState<string | null>(null);
  const [fixoAvulso, setFixoAvulso] = useState("");
  const [nomeAvulso, setNomeAvulso] = useState("");
  const [avulsosConhecidos, setAvulsosConhecidos] = useState<string[]>([]);
  const [cobrarAcrescimo, setCobrarAcrescimo] = useState(true);
  // quando: agora ou planejada (com repetição)
  const conta = useConta();
  const [quando, setQuando] = useState<"agora" | "planejar">("agora");
  const [horario, setHorario] = useState(() => paraCampo(sugestaoHorario(Number(cfg.agendada_antecedencia_min) || 30)));
  const [repetir, setRepetir] = useState<Repeticao>("nao");
  const [diasSemana, setDiasSemana] = useState<number[]>([]);
  const [vezes, setVezes] = useState("4");
  const [paradas, setParadas] = useState<ParadaForm[]>(() => [novaParada("coleta"), novaParada("entrega")]);
  const [escolhendo, setEscolhendo] = useState<string | null>(null);
  const [aberta, setAberta] = useState<string | null>(null);
  const [rota, setRota] = useState<Rota | null>(null);
  const [calculando, setCalculando] = useState(false);
  const [valorManual, setValorManual] = useState<string | null>(null);
  const [exige, setExige] = useState<{ foto: boolean; assinatura: boolean; nome: boolean; codigo: boolean } | null>(null);
  const [noLocal, setNoLocal] = useState<boolean | null>(null);
  const [raio, setRaio] = useState<string | null>(null);
  const { teste } = useModoTeste(); // no modo teste, toda corrida criada é de teste
  const [modo, setModo] = useState<"cascata" | "direto">("cascata");
  const [urgente, setUrgente] = useState(false);
  const [repasseManual, setRepasseManual] = useState("");
  const [devManual, setDevManual] = useState("");
  const [motoboyId, setMotoboyId] = useState("");
  const [observacoes, setObservacoes] = useState("");
  const [enviando, setEnviando] = useState(false);
  const [erro, setErro] = useState<string | null>(null);

  // padrões vindos das Configurações (até o gestor mexer)
  const exigeAtual = exige ?? {
    nome: Boolean(cfg.padrao_exige_nome), foto: Boolean(cfg.padrao_exige_foto),
    assinatura: Boolean(cfg.padrao_exige_assinatura), codigo: Boolean(cfg.padrao_exige_codigo),
  };
  const noLocalAtual = noLocal ?? Boolean(cfg.exigir_no_local);
  const raioAtual = raio ?? String(cfg.raio_chegada_m);

  const empresa = tipoCliente === "cliente" ? empresas.find((e) => e.id === empresaId) ?? null : null;
  const favoritosDaEmpresa = favoritos.filter((f) => f.empresa_id === empresaId).map((f) => f.motoboy_id);

  const atualizar = (chave: string, mudanca: Partial<ParadaForm>) =>
    setParadas((lista) => lista.map((p) => (p.chave === chave ? { ...p, ...mudanca } : p)));

  function escolherTipo(t: "avulso" | "cliente") {
    setTipoCliente(t);
    setValorManual(null);
    if (t === "avulso") setEmpresaId("");
  }

  function escolherEmpresa(id: string) {
    setEmpresaId(id);
    setValorManual(null);
    const e = empresas.find((x) => x.id === id);
    // coleta padrão da empresa entra na primeira parada (se ela ainda estiver vazia ou veio de outra empresa)
    if (e?.endereco && e.lat != null && e.lng != null) {
      setParadas((l) => l.map((p, i) => (i === 0 && p.tipo === "coleta"
        ? { ...p, endereco: e.endereco!, lat: e.lat, lng: e.lng, contato_nome: e.nome_fantasia ?? e.nome, contato_telefone: e.telefone ?? "", instrucoes: e.instrucoes_coleta ?? "" }
        : p)));
    }
  }

  // nomes de avulsos já usados (sugestões ao digitar)
  useEffect(() => {
    supabase().rpc("clientes_avulsos").then(({ data }) => {
      if (Array.isArray(data)) setAvulsosConhecidos((data as { nome: string }[]).map((x) => x.nome));
    });
  }, []);

  // rota: recalcula quando as coordenadas mudam
  const chaveCoords = paradas.map((p) => `${p.lat},${p.lng}`).join("|");
  useEffect(() => {
    const pontos = paradas.filter((p) => p.lat != null && p.lng != null) as (ParadaForm & { lat: number; lng: number })[];
    if (pontos.length < 2) { setRota(null); return; }
    let cancelado = false;
    setCalculando(true);
    const t = setTimeout(async () => {
      const r = await geo.calcularRota(pontos).catch(() => null);
      if (!cancelado) { setRota(r); setCalculando(false); }
    }, 400);
    return () => { cancelado = true; clearTimeout(t); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [chaveCoords]);

  const numero = (t: string | null) => (t == null || t.trim() === "" ? null : Number(t.replace(",", ".")));
  const kmAvulsoAtual = kmAvulso ?? String(cfg.valor_km_padrao).replace(".", ",");
  const regra = empresa
    ? { modalidade: empresa.modalidade_preco, valor_km: empresa.valor_km, valor_fixo: empresa.valor_fixo }
    : { modalidade: modAvulso, valor_km: numero(kmAvulsoAtual), valor_fixo: numero(fixoAvulso) };
  const orcamento = orcar(
    regra,
    rota?.distanciaM ?? null,
    { valorKmPadrao: Number(cfg.valor_km_padrao), valorMinimo: Number(cfg.valor_minimo), arredondamento: Number(cfg.arredondamento) },
  );
  const valorFinal = valorManual !== null ? Number(valorManual.replace(",", ".")) : orcamento.valor;

  // acréscimo do percurso (coleta → entrega), igual ao do servidor; o da coleta depende do motoboy
  const faixas = (m: number | null | undefined, cada: number, fator: number) => (m != null && cada > 0 ? Math.floor(m / 1000 / cada) * fator : 0);
  const acrescimoLigado = Boolean(cfg.acrescimo_distancia) && cobrarAcrescimo;
  const fatorEntrega = acrescimoLigado ? faixas(rota?.distanciaM, Number(cfg.acrescimo_entrega_cada_km), Number(cfg.acrescimo_entrega_fator)) : 0;
  const arredondar = (v: number) => {
    const a = Number(cfg.arredondamento);
    return a > 0 ? Math.ceil(v / a - 1e-9) * a : Math.round(v * 100) / 100;
  };
  const valorComAcrescimo = valorFinal != null && !Number.isNaN(valorFinal) ? arredondar(valorFinal * (1 + fatorEntrega)) : null;

  async function aoClicarMapa(lat: number, lng: number) {
    if (!escolhendo) return;
    const chave = escolhendo;
    setEscolhendo(null);
    atualizar(chave, { lat, lng, endereco: "Buscando endereço…" });
    atualizar(chave, { endereco: await geo.enderecoDoPonto(lat, lng) });
  }

  function mover(i: number, direcao: -1 | 1) {
    setParadas((l) => {
      const n = [...l];
      const j = i + direcao;
      if (j < 0 || j >= n.length) return l;
      [n[i], n[j]] = [n[j], n[i]];
      return n;
    });
  }

  async function enviar() {
    setErro(null);
    if (paradas.some((p) => p.lat == null)) return setErro("Defina a localização de todas as paradas (busque o endereço ou marque no mapa).");
    if (paradas[0].tipo !== "coleta") return setErro("A primeira parada precisa ser uma coleta.");
    if (!paradas.some((p) => p.tipo === "entrega")) return setErro("Inclua pelo menos uma entrega.");
    if (valorFinal == null || Number.isNaN(valorFinal)) return setErro("Informe o valor da corrida.");
    if (modo === "direto" && !motoboyId) return setErro("Escolha o motoboy.");
    if (tipoCliente === "cliente" && !empresa) return setErro("Escolha o cliente (ou mude para avulso).");
    if (planejada && (!datas.length || Number.isNaN(datas[0].getTime()))) return setErro("Escolha a data e a hora da corrida.");
    if (planejada && datas[0].getTime() < Date.now() + antecedenciaMin * 60000) {
      return setErro(`Planeje com pelo menos ${antecedenciaMin} min de antecedência (ou crie para agora).`);
    }

    setEnviando(true);
    const dados = {
        empresa_id: empresa?.id ?? null,
        cliente_nome: empresa ? null : nomeAvulso.trim() || null,
        aplicar_acrescimo: acrescimoLigado,
        repasse_pct: repasseManual.trim() ? Number(repasseManual.replace(",", ".")) : null,
        dev_pct: devManual.trim() ? Number(devManual.replace(",", ".")) : null,
        teste,
        modo_despacho: modo,
        urgente: modo === "cascata" && !planejada && urgente,
        motoboy_id: modo === "direto" ? motoboyId : null,
        exige_foto: exigeAtual.foto,
        exige_assinatura: exigeAtual.assinatura,
        exige_nome: exigeAtual.nome,
        exige_codigo: exigeAtual.codigo,
        exigir_no_local: noLocalAtual,
        raio_chegada_m: Number(raioAtual) || Number(cfg.raio_chegada_m),
        distancia_planejada_m: rota?.distanciaM ?? null,
        duracao_planejada_s: rota?.duracaoS ?? null,
        rota_planejada: rota?.polyline ?? null,
        valor: valorFinal,
        observacoes,
        paradas: paradas.map(({ tipo, endereco, lat, lng, contato_nome, contato_telefone, instrucoes, referencias }) => ({
          tipo, endereco, lat, lng, contato_nome, contato_telefone, instrucoes, referencias,
        })),
    };
    const sb = supabase();
    const { data, error } = !planejada
      ? await sb.rpc("criar_corrida", { dados })
      : datas.length === 1
        ? await sb.rpc("criar_corrida", { dados: { ...dados, agendada_para: datas[0].toISOString() } })
        : await sb.rpc("criar_serie", { dados, p_datas: datas.map((d) => d.toISOString()) });
    setEnviando(false);
    if (error) return setErro(traduzirErro(error.message));
    onCriada(Array.isArray(data) ? (data[0] as string) : (data as string));
  }

  const planejada = quando === "planejar";
  const antecedenciaMin = Number(cfg.agendada_antecedencia_min) || 30;
  const datas = useMemo(
    () => (planejada ? gerarDatas(new Date(horario), repetir, diasSemana, Math.min(60, Math.max(1, Number(vezes) || 1))) : []),
    [planejada, horario, repetir, diasSemana, vezes],
  );

  const pinos: PinoParada[] = useMemo(
    () => paradas.flatMap((p, i) => (p.lat == null || p.lng == null ? [] : [{ chave: p.chave, lat: p.lat, lng: p.lng, tipo: p.tipo, rotulo: String(i + 1) }])),
    [paradas],
  );

  // só aparecem motoboys compatíveis com o tipo da corrida (teste ↔ modo teste)
  const motoboysCompativeis = equipe
    .filter((m) => m.modo_teste === teste)
    .sort((a, b) => Number(favoritosDaEmpresa.includes(b.id)) - Number(favoritosDaEmpresa.includes(a.id)));

  return (
    <>
      <aside className="lateral lateral-larga entrar">
        <div className="lateral-cabecalho">
          <button className="botao-texto" onClick={onVoltar}><ArrowLeft size={15} aria-hidden /> Voltar</button>
        </div>
        <CabecaPagina icone={PackagePlus} titulo="Nova corrida" subtitulo="Defina as paradas, o preço e o despacho" />

        {teste && (
          <section className="bloco bloco-teste">
            <div className="opcao">
              <FlaskConical size={17} aria-hidden style={{ color: "var(--ouro)" }} />
              <span><strong>Modo teste ligado</strong><br /><span className="dica">Esta corrida será de teste: só vai para motoboys com o modo teste ligado e não entra no financeiro real.</span></span>
            </div>
          </section>
        )}

        {conta.modulo("corridas_planejadas") && <section className={`bloco ${planejada ? "bloco-planejada" : ""}`}>
          <span className="rotulo">Quando</span>
          <div className="segmentado" style={{ gridTemplateColumns: "1fr 1fr" }}>
            <button type="button" className={!planejada ? "ativo" : ""} onClick={() => setQuando("agora")}><Zap size={15} aria-hidden /> Express</button>
            <button type="button" className={planejada ? "ativo" : ""} onClick={() => setQuando("planejar")}><CalendarClock size={15} aria-hidden /> Planejar</button>
          </div>
          {planejada && (
            <>
              <label className="campo">
                <span>Começa em</span>
                <input type="datetime-local" value={horario} min={paraCampo(new Date(Date.now() + antecedenciaMin * 60000))} onChange={(e) => setHorario(e.target.value)} />
              </label>
              <label className="campo">
                <span><Repeat size={13} aria-hidden style={{ verticalAlign: -2 }} /> Repetir</span>
                <select value={repetir} onChange={(e) => setRepetir(e.target.value as Repeticao)}>
                  <option value="nao">Não repetir</option>
                  <option value="diario">Todo dia</option>
                  <option value="semanal">Em dias da semana</option>
                </select>
              </label>
              {repetir === "semanal" && (
                <div className="dias-semana" role="group" aria-label="Dias da semana">
                  {DIAS_SEMANA.map((d, i) => (
                    <button key={i} type="button" className={diasSemana.includes(i) ? "ativo" : ""} aria-pressed={diasSemana.includes(i)}
                      onClick={() => setDiasSemana((l) => (l.includes(i) ? l.filter((x) => x !== i) : [...l, i]))}>{d}</button>
                  ))}
                </div>
              )}
              {repetir !== "nao" && (
                <label className="opcao">
                  <span>Quantas corridas no total</span>
                  <input inputMode="numeric" style={{ width: 80, textAlign: "right" }} value={vezes} onChange={(e) => setVezes(e.target.value.replace(/\D/g, "").slice(0, 2))} />
                </label>
              )}
              <div className="datas-previa">
                {datas.slice(0, 6).map((d) => (
                  <span key={d.toISOString()} className="chip"><CalendarClock size={12} aria-hidden /> {formatarQuando(d.toISOString())}</span>
                ))}
                {datas.length > 6 && <span className="dica">+ {datas.length - 6} datas</span>}
              </div>
              <p className="dica" style={{ margin: 0 }}>
                {datas[0] && !Number.isNaN(datas[0].getTime()) ? `Começa ${relativo(datas[0].toISOString())}. ` : ""}
                Aparece no app para todos os motoboys{teste ? " em modo teste" : ""}, mesmo offline. Quem reservar pode desistir até {Number(cfg.agendada_cancelar_ate_min)} min antes.
                {cfg.agendada_despacho_auto ? ` Se ninguém reservar até ${Number(cfg.agendada_despacho_auto_min)} min antes, vai para o despacho normal.` : " Se ninguém reservar, fica “sem motoboy” no horário."}
              </p>
            </>
          )}
        </section>}

        <section className="bloco">
          <span className="rotulo">Cliente</span>
          <div className="segmentado" style={{ gridTemplateColumns: "1fr 1fr" }}>
            <button type="button" className={tipoCliente === "avulso" ? "ativo" : ""} onClick={() => escolherTipo("avulso")}><Pessoa size={15} aria-hidden /> Avulso</button>
            <button type="button" className={tipoCliente === "cliente" ? "ativo" : ""} onClick={() => escolherTipo("cliente")}><Building2 size={15} aria-hidden /> Cliente cadastrado</button>
          </div>

          {tipoCliente === "cliente" ? (
            <>
              <select value={empresaId} onChange={(e) => escolherEmpresa(e.target.value)} aria-label="Cliente">
                <option value="">Escolha o cliente…</option>
                {empresas.map((e) => <option key={e.id} value={e.id}>{e.nome}{e.situacao && e.situacao !== "ATIVA" ? ` (${e.situacao})` : ""}</option>)}
              </select>
              {empresa && <p className="dica" style={{ margin: 0 }}>Preço do cliente: {ROTULO_MODALIDADE[empresa.modalidade_preco]}{empresa.modalidade_preco === "por_km" ? ` · ${moeda(empresa.valor_km)}/km` : empresa.modalidade_preco === "fixo" ? ` · ${moeda(empresa.valor_fixo)}` : ""}</p>}
              {empresa?.situacao && empresa.situacao !== "ATIVA" && <p className="erro">Atenção: situação cadastral {empresa.situacao} na Receita.</p>}
            </>
          ) : (
            <>
              <label className="campo">
                <span>Nome do cliente</span>
                <input value={nomeAvulso} maxLength={80} placeholder="Ex.: Dona Maria · Padaria do Centro" list="avulsos-conhecidos"
                  onChange={(e) => setNomeAvulso(e.target.value)} />
                <datalist id="avulsos-conhecidos">{avulsosConhecidos.map((n) => <option key={n} value={n} />)}</datalist>
                <span className="dica">Opcional, mas ajuda a separar nos registros e no financeiro.</span>
              </label>
              <label className="campo">
                <span>Modalidade desta corrida</span>
                <select value={modAvulso} onChange={(e) => { setModAvulso(e.target.value as Modalidade); setValorManual(null); }}>
                  {(Object.keys(ROTULO_MODALIDADE) as Modalidade[]).map((m) => <option key={m} value={m}>{ROTULO_MODALIDADE[m]}</option>)}
                </select>
              </label>
              {modAvulso === "por_km" && (
                <label className="opcao">
                  <span>Valor do km</span>
                  <span className="unidade">R$</span>
                  <input inputMode="decimal" style={{ width: 100, textAlign: "right" }} value={kmAvulsoAtual}
                    onChange={(e) => { setKmAvulso(e.target.value); setValorManual(null); }} />
                </label>
              )}
              {modAvulso === "fixo" && (
                <label className="opcao">
                  <span>Preço fixo</span>
                  <span className="unidade">R$</span>
                  <input inputMode="decimal" placeholder="0,00" style={{ width: 110, textAlign: "right" }} value={fixoAvulso}
                    onChange={(e) => { setFixoAvulso(e.target.value); setValorManual(null); }} />
                </label>
              )}
              {modAvulso === "por_zona" && <p className="dica" style={{ margin: 0 }}>Informe o valor da corrida no resumo abaixo.</p>}
            </>
          )}
        </section>

        <section className="bloco">
          <span className="rotulo">Paradas</span>
          <ListaOrdenavel itens={paradas} chave={(p) => p.chave} onMudar={setParadas} render={(p, i, alca) => (
            <div className={`parada-form ${p.tipo}`}>
              <div className="parada-topo">
                {alca}
                <span className={`pino-mini ${p.tipo}`}>{i + 1}</span>
                <select value={p.tipo} onChange={(e) => atualizar(p.chave, { tipo: e.target.value as TipoParada })}>
                  <option value="coleta">Coleta</option>
                  <option value="entrega">Entrega</option>
                </select>
                <span className="espaco" />
                {paradas.length > 2 && (
                  <button type="button" className="icone" title="Remover" onClick={() => setParadas((l) => l.filter((x) => x.chave !== p.chave))}><X size={14} /></button>
                )}
              </div>
              <CampoEndereco
                valor={p.endereco}
                onTexto={(t) => atualizar(p.chave, { endereco: t, lat: null, lng: null })}
                onEscolher={(e) => atualizar(p.chave, { endereco: e.descricao, lat: e.lat, lng: e.lng })}
              />
              <div className="parada-acoes">
                <button type="button" className={`link ${escolhendo === p.chave ? "ativo" : ""}`} onClick={() => setEscolhendo(escolhendo === p.chave ? null : p.chave)}>
                  <MapPinned size={13} aria-hidden /> {escolhendo === p.chave ? "Clique no mapa…" : "Marcar no mapa"}
                </button>
                {p.lat != null ? <span className="ok"><CheckCircle2 size={13} aria-hidden /> Localizado</span> : <span className="pendente">Sem localização</span>}
                <button type="button" className="link" onClick={() => setAberta(aberta === p.chave ? null : p.chave)}>
                  <UserRound size={13} aria-hidden /> {aberta === p.chave ? "Menos" : `Contato e referências${p.referencias.length ? ` (${p.referencias.length})` : ""}`}
                </button>
              </div>
              {aberta === p.chave && (
                <div className="parada-extra">
                  <input placeholder="Nome do contato" value={p.contato_nome} onChange={(e) => atualizar(p.chave, { contato_nome: e.target.value })} />
                  <input placeholder="Telefone" value={p.contato_telefone} onChange={(e) => atualizar(p.chave, { contato_telefone: e.target.value })} />
                  <input placeholder="Instruções (portaria, bloco…)" value={p.instrucoes} onChange={(e) => atualizar(p.chave, { instrucoes: e.target.value })} />
                  {conta.modulo("pontos_referencia") && <CampoReferencias valor={p.referencias} lat={p.lat} lng={p.lng} onMudar={(r) => atualizar(p.chave, { referencias: r })} />}
                </div>
              )}
            </div>
          )} />
          <div className="linha-botoes">
            <button type="button" className="botao-texto" onClick={() => setParadas((l) => [...l, novaParada("coleta")])}><Plus size={15} /> Coleta</button>
            <button type="button" className="botao-texto" onClick={() => setParadas((l) => [...l, novaParada("entrega")])}><Plus size={15} /> Entrega</button>
          </div>
        </section>

        <section className="bloco resumo-rota">
          <div><span className="rotulo">Distância</span><strong>{calculando ? "…" : formatarKm(rota?.distanciaM)}</strong></div>
          <div><span className="rotulo">Tempo</span><strong>{calculando ? "…" : formatarDuracao(rota?.duracaoS)}</strong></div>
          <div>
            <span className="rotulo">Valor</span>
            <input className="valor" inputMode="decimal"
              value={valorManual ?? (orcamento.valor != null ? orcamento.valor.toFixed(2).replace(".", ",") : "")}
              placeholder="0,00" onChange={(e) => setValorManual(e.target.value)} />
          </div>
          <p className="dica">
            {ROTULO_MODALIDADE[regra.modalidade]} · {orcamento.explicacao}
            {valorManual !== null && <> · <button type="button" className="link" onClick={() => setValorManual(null)}>voltar ao calculado ({moeda(orcamento.valor)})</button></>}
          </p>
          {Boolean(cfg.acrescimo_distancia) && (
            <label className="opcao">
              <TrendingUp size={15} aria-hidden style={{ color: "var(--ouro)" }} />
              <span><strong>Acréscimo por distância</strong><br /><span className="dica">{cobrarAcrescimo ? "Cobra a mais em percursos longos e para motoboys longe da coleta." : "Esta corrida fica com o valor acima, sem acréscimo."}</span></span>
              <input type="checkbox" role="switch" checked={cobrarAcrescimo} onChange={(e) => setCobrarAcrescimo(e.target.checked)} />
            </label>
          )}
          {acrescimoLigado && (
            <div className="acrescimo">
              <TrendingUp size={14} aria-hidden />
              <span>
                {fatorEntrega > 0
                  ? <>Percurso longo: <strong>+{fatorEntrega.toLocaleString("pt-BR")}×</strong> → <strong>{moeda(valorComAcrescimo)}</strong>. </>
                  : <>Sem acréscimo de percurso. </>}
                Se o motoboy estiver a mais de {Number(cfg.acrescimo_coleta_cada_km)} km da coleta, soma +{Number(cfg.acrescimo_coleta_fator).toLocaleString("pt-BR")}× a cada {Number(cfg.acrescimo_coleta_cada_km)} km no valor que ele recebe.
              </span>
            </div>
          )}
        </section>

        <section className="bloco">
          <span className="rotulo"><MapPinned size={12} aria-hidden style={{ verticalAlign: -1 }} /> Localização</span>
          <label className="opcao">
            <span>Exigir que o motoboy esteja no local para avançar as etapas</span>
            <input type="checkbox" checked={noLocalAtual} onChange={(e) => setNoLocal(e.target.checked)} />
          </label>
          {noLocalAtual && (
            <label className="opcao">
              <span className="dica">Raio permitido</span>
              <input inputMode="numeric" style={{ width: 90, textAlign: "right" }} value={raioAtual} onChange={(e) => setRaio(e.target.value.replace(/\D/g, ""))} />
              <span className="unidade">m</span>
            </label>
          )}
        </section>

        <section className="bloco">
          <span className="rotulo"><Receipt size={12} aria-hidden style={{ verticalAlign: -1 }} /> Comprovantes na entrega</span>
          {([["nome", "Nome de quem recebeu"], ["foto", "Foto"], ["assinatura", "Assinatura"], ["codigo", "Código de 4 dígitos"]] as const).map(([k, r]) => (
            <label key={k} className="opcao">
              <span>{r}</span>
              <input type="checkbox" checked={exigeAtual[k]} onChange={(e) => setExige({ ...exigeAtual, [k]: e.target.checked })} />
            </label>
          ))}
        </section>

        <section className="bloco">
          <span className="rotulo"><Radar size={12} aria-hidden style={{ verticalAlign: -1 }} /> Despacho</span>
          <div className="checks">
            <label><input type="radio" checked={modo === "cascata"} onChange={() => setModo("cascata")} /> {planejada
              ? "Aberta: o primeiro motoboy que reservar no app fica com ela"
              : <>Mais próximo da coleta{favoritosDaEmpresa.length && cfg.favoritos_primeiro ? " · favoritos primeiro" : ""}</>}</label>
            <label><input type="radio" checked={modo === "direto"} onChange={() => setModo("direto")} /> {planejada ? "Já reservar para um motoboy" : "Motoboy específico"}</label>
          </div>
          {modo === "direto" && (
            <>
              <select value={motoboyId} onChange={(e) => setMotoboyId(e.target.value)}>
                <option value="">Escolha…</option>
                {motoboysCompativeis.map((m) => (
                  <option key={m.id} value={m.id}>{favoritosDaEmpresa.includes(m.id) ? "★ " : ""}{m.nome} · {ROTULO_STATUS[m.status]}</option>
                ))}
              </select>
              {motoboysCompativeis.length === 0 && (
                <p className="dica">{teste ? "Nenhum motoboy com o modo teste ligado." : "Nenhum motoboy fora do modo teste."}</p>
              )}
            </>
          )}
          <details className="avancado">
            <summary>Divisão desta corrida</summary>
            <div className="grade-2">
              <label className="campo curto"><span>Motoboy (%)</span><input inputMode="decimal" placeholder="padrão" value={repasseManual} onChange={(e) => setRepasseManual(e.target.value)} /></label>
              {conta.dev && <label className="campo curto"><span>Plataforma (%)</span><input inputMode="decimal" placeholder="padrão" value={devManual} onChange={(e) => setDevManual(e.target.value)} /></label>}
            </div>
            <p className="dica">Vazio = usa o do cliente ou o padrão. A gestão fica com o restante.</p>
          </details>
          {modo === "cascata" && !planejada && (
            <label className="opcao">
              <span><strong>Urgente</strong><br /><span className="dica">{urgente ? "Vai para o mais próximo mesmo se estiver fora do raio que ele escolheu." : "Respeita o raio de disponibilidade de cada motoboy."}</span></span>
              <input type="checkbox" role="switch" checked={urgente} onChange={(e) => setUrgente(e.target.checked)} />
            </label>
          )}
        </section>

        <section className="bloco">
          <label className="campo">
            <span><StickyNote size={13} aria-hidden style={{ verticalAlign: -2 }} /> Observações para o motoboy</span>
            <textarea rows={2} value={observacoes} onChange={(e) => setObservacoes(e.target.value)} />
          </label>
        </section>

        {erro && <p className="erro">{erro}</p>}
        <button className="botao-ouro" disabled={enviando} onClick={enviar}>
          <Send size={17} aria-hidden /> {enviando ? "Criando…" : planejada
            ? `${datas.length > 1 ? `Planejar ${datas.length} corridas` : "Planejar corrida"}${teste ? " de teste" : ""} · ${moeda(valorComAcrescimo)}${datas.length > 1 ? " cada" : ""}`
            : `${teste ? "Criar teste" : "Criar e despachar"} · ${moeda(valorComAcrescimo)}`}
        </button>
      </aside>

      <MapaCorridas
        paradas={pinos}
        rotaPlanejada={rota?.polyline}
        motoboys={equipe.filter((m) => m.status !== "offline" && m.lat != null && m.lng != null && m.modo_teste === teste)
          .map((m) => ({ id: m.id, nome: m.nome, lat: m.lat!, lng: m.lng!, status: m.status, foto: m.foto }))}
        aoClicar={aoClicarMapa}
        modoEscolha={escolhendo !== null}
        enquadrar={chaveCoords}
      />
    </>
  );
}

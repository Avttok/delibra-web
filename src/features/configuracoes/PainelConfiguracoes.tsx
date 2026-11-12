"use client";

import { combina } from "@/features/ui/busca";
import { useMemo, useRef, useState, type ReactNode } from "react";
import { Dica } from "@/features/ui/Tour";
import {
  Bike, Boxes, Building2, CalendarClock, Check, CircleDot, Clock, FileText, Map as MapIcon, FlaskConical, Layers, Lock, MapPinned, Minus, Plus, Radar, Receipt, Route, Ruler, Search, Settings2,
  MessageCircle, RotateCcw, ShieldCheck, Tags, TriangleAlert, Wallet, X, type LucideIcon,
} from "lucide-react";
import { useConta } from "@/features/conta/conta";
import { Excecoes } from "./Excecoes";
import { CatalogoCategorias, CatalogoHorarios, CatalogoTipos, CatalogoZonas } from "./Catalogos";
import { supabase } from "@/lib/supabase/client";
import { CabecaPagina } from "@/features/ui/CabecaPagina";
import { CampoRaio } from "@/features/ui/CampoRaio";
import { AREAS, GRUPOS, PARAMETROS, ehRaio, igualPadrao, type AreaParametro, type DefParametro, type GrupoParametro, type ValorParametro } from "./definicoes";
import { CampoNumero } from "@/features/ui/CampoNumero";
import { CompartilharMotoboys } from "@/features/equipe/CompartilharMotoboys";
import { useConfiguracoes } from "./useConfiguracoes";

const ICONES_AREA: Record<AreaParametro, LucideIcon> = {
  clientes: Building2, preco: Tags, operacao: Route, motoboys: Bike, mapa: MapIcon, comunicacao: MessageCircle, sistema: FlaskConical,
};

type Estado = "salvando" | "salvo" | "erro" | undefined;
type Extra = "excecoes" | "zonas" | "horarios" | "categorias" | "tipos";
type Pagina = AreaParametro | Extra;
/** Catálogos (peças do lego que são listas) e em que área eles aparecem. */
const PAGINAS_EXTRAS: { chave: Extra; titulo: string; descricao: string; icone: LucideIcon; area?: AreaParametro }[] = [
  { chave: "excecoes", titulo: "Exceções", descricao: "Regras diferentes para um cliente, um motoboy ou um tipo de pedido.", icone: Layers },
  { chave: "zonas", titulo: "Zonas de preço", descricao: "Raios no mapa com acréscimo (bairros, regiões, cidades).", icone: CircleDot, area: "preco" },
  { chave: "horarios", titulo: "Horários de pico", descricao: "Faixas de horário com acréscimo.", icone: Clock, area: "preco" },
  { chave: "categorias", titulo: "Categorias de produto", descricao: "Eletrônicos, químicos, frágeis… com taxas próprias.", icone: Boxes, area: "preco" },
  { chave: "tipos", titulo: "Tipos de pedido", descricao: "Os tipos que o cliente escolhe (e que podem ter regras próprias).", icone: Tags, area: "operacao" },
];

const sem = (t: string) => t.normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase();
const casas = (passo = 1) => (String(passo).split(".")[1]?.length ?? 0);
const formatar = (n: number, passo?: number) => n.toLocaleString("pt-BR", { maximumFractionDigits: Math.max(2, casas(passo)) });
const mudou = (p: DefParametro, v: ValorParametro | undefined) => !igualPadrao(p, v);

/**
 * Configurações em dois níveis: áreas (Clientes, Preço, Operação, Motoboys, Mapa e GPS, Comunicação, Sistema)
 * e, dentro de cada uma, os grupos em seções. Busca em tudo, "só o que mudei" e voltar ao padrão em cada ajuste.
 */
export function PainelConfiguracoes() {
  const cfg = useConfiguracoes();
  const [pagina, setPagina] = useState<Pagina>(() => {
    // link direto (?area=operacao) vence a última página aberta
    try { return (new URLSearchParams(window.location.search).get("area") as Pagina) || (localStorage.getItem("pwex-config-pagina") as Pagina) || "clientes"; } catch { return "clientes"; }
  });
  const conta = useConta();
  const visiveis = PARAMETROS.filter((p) => conta.dev || !p.escondido);
  const [busca, setBusca] = useState("");
  const [soMudados, setSoMudados] = useState(false);
  const [estado, setEstado] = useState<Record<string, Estado>>({});
  const ir = (p: Pagina) => { setPagina(p); setBusca(""); try { localStorage.setItem("pwex-config-pagina", p); } catch {} };

  async function salvar(p: DefParametro, valor: ValorParametro) {
    setEstado((e) => ({ ...e, [p.chave]: "salvando" }));
    // grava na empresa de quem está logado (o Dev sem empresa escolhida grava o padrão da plataforma)
    const r = await supabase().rpc("salvar_ajuste", { p_chave: p.chave, p_valor: valor });
    setEstado((e) => ({ ...e, [p.chave]: r.error ? "erro" : "salvo" }));
    if (!r.error) setTimeout(() => setEstado((e) => ({ ...e, [p.chave]: undefined })), 1800);
  }

  const termo = sem(busca.trim());
  const filtrar = (lista: DefParametro[]) => (soMudados ? lista.filter((p) => mudou(p, cfg[p.chave])) : lista);
  const resultado = useMemo(
    () => (termo ? filtrar(visiveis.filter((p) => combina(termo, p.rotulo, p.descricao, p.descricaoDesligado, GRUPOS[p.grupo].titulo, p.chave))) : []),
    [termo, soMudados, cfg], // eslint-disable-line react-hooks/exhaustive-deps
  );
  const extra = PAGINAS_EXTRAS.find((x) => x.chave === pagina);
  const area = AREAS.find((a) => a.chave === pagina);
  const gruposDaArea = area ? (Object.keys(GRUPOS) as GrupoParametro[]).filter((g) => GRUPOS[g].area === area.chave) : [];
  const nMudados = (lista: DefParametro[]) => lista.filter((p) => mudou(p, cfg[p.chave])).length;

  const linha = (p: DefParametro, comGrupo: boolean) => (
    <Parametro key={p.chave} p={p} valor={cfg[p.chave] ?? p.padrao} estado={estado[p.chave]} mostrarGrupo={comGrupo} onSalvar={(v) => salvar(p, v)}
      bloqueado={p.soDev && !conta.dev} onPadrao={mudou(p, cfg[p.chave]) && !(p.soDev && !conta.dev) ? () => salvar(p, p.padrao) : undefined} />
  );

  return (
    <>
      <aside className="lateral config-lateral">
        <CabecaPagina icone={Settings2} titulo="Configurações" subtitulo="Padrões do sistema · exceções por tipo, cliente, motoboy e pedido" />
        <label className="config-busca">
          <Search size={16} aria-hidden />
          <input placeholder="Buscar em todos os ajustes…" value={busca} onChange={(e) => setBusca(e.target.value)} />
          {busca && <button type="button" onClick={() => setBusca("")} aria-label="Limpar busca"><X size={15} /></button>}
        </label>
        <label className="config-so-mudados"><input type="checkbox" role="switch" checked={soMudados} onChange={(e) => setSoMudados(e.target.checked)} /> Só o que mudei do padrão</label>
        <nav className="config-grupos" aria-label="Áreas das configurações">
          {AREAS.map((a) => {
            const I = ICONES_AREA[a.chave];
            const params = visiveis.filter((p) => GRUPOS[p.grupo].area === a.chave);
            const nm = nMudados(params);
            return (
              <button key={a.chave} type="button" className={`config-grupo ${!termo && pagina === a.chave ? "ativo" : ""}`} onClick={() => ir(a.chave)}>
                <span className="config-grupo-icone"><I size={17} aria-hidden /></span>
                <span className="config-grupo-texto"><strong>{a.titulo}</strong><span>{a.descricao}</span></span>
                <span className="config-grupo-n" title={nm ? `${nm} mudado(s) do padrão` : `${params.length} ajustes`}>{nm ? <><b>{nm}</b>/{params.length}</> : params.length}</span>
              </button>
            );
          })}
          <span className="rotulo" style={{ margin: "10px 4px 2px" }}>Peças do lego<Dica titulo="Peças do lego" texto="Cada regra tem um valor geral e pode ter exceção por tipo de pedido, cliente, motoboy ou num pedido só. Vale a mais específica: pedido, motoboy, cliente, tipo e, por último, a geral." /></span>
          {PAGINAS_EXTRAS.map((x) => {
            const I = x.icone;
            return (
              <button key={x.chave} type="button" className={`config-grupo compacto ${!termo && pagina === x.chave ? "ativo" : ""}`} onClick={() => ir(x.chave)}>
                <span className="config-grupo-icone"><I size={17} aria-hidden /></span>
                <span className="config-grupo-texto"><strong>{x.titulo}</strong><span>{x.descricao}</span></span>
              </button>
            );
          })}
        </nav>
      </aside>

      <main className="conteudo">
        <div className={`config-pagina entrar ${!termo && pagina === "zonas" ? "larga" : ""}`} key={termo ? "busca" : pagina}>
          {termo ? (
            <>
              <header className="config-titulo">
                <span className="cabeca-icone grad-suave"><Search size={18} aria-hidden /></span>
                <div><h2 className="display">Busca</h2><p className="dica">{resultado.length} ajuste{resultado.length === 1 ? "" : "s"} para “{busca.trim()}”</p></div>
              </header>
              <div className="config-lista">
                {resultado.map((p) => linha(p, true))}
                {resultado.length === 0 && <p className="vazio">Nenhum ajuste encontrado.</p>}
              </div>
            </>
          ) : extra ? (
            <>
              <header className="config-titulo">
                <span className="cabeca-icone grad-suave"><extra.icone size={18} aria-hidden /></span>
                <div><h2 className="display">{extra.titulo}</h2><p className="dica">{extra.descricao}</p></div>
              </header>
              {pagina === "excecoes" ? <Excecoes cfg={cfg} /> : pagina === "zonas" ? <CatalogoZonas /> : pagina === "horarios" ? <CatalogoHorarios />
                : pagina === "categorias" ? <CatalogoCategorias /> : <CatalogoTipos />}
            </>
          ) : area ? (
            <>
              <header className="config-titulo">
                <span className="cabeca-icone grad-suave">{(() => { const I = ICONES_AREA[area.chave]; return <I size={18} aria-hidden />; })()}</span>
                <div><h2 className="display">{area.titulo}</h2><p className="dica">{area.descricao}</p></div>
              </header>
              <nav className="config-atalhos" aria-label="Seções">
                {gruposDaArea.map((g) => <a key={g} href={`#cfg-${g}`} className="chip">{GRUPOS[g].titulo}</a>)}
                {PAGINAS_EXTRAS.filter((x) => x.area === area.chave).map((x) => <button key={x.chave} type="button" className="chip" onClick={() => ir(x.chave)}><x.icone size={13} aria-hidden /> {x.titulo}</button>)}
              </nav>
              {gruposDaArea.map((g) => {
                const lista = filtrar(visiveis.filter((p) => p.grupo === g));
                if (!lista.length && soMudados) return null;
                return (
                  <section key={g} id={`cfg-${g}`} className="config-secao">
                    <h3><span>{GRUPOS[g].titulo}</span>{nMudados(visiveis.filter((p) => p.grupo === g)) > 0 && <small>{nMudados(visiveis.filter((p) => p.grupo === g))} mudado(s)</small>}</h3>
                    <p className="dica">{GRUPOS[g].descricao}</p>
                    {g === "distancia" && <ExemploAcrescimo cfg={cfg} />}
                    {g === "pagamento" && <ExemploPagamento cfg={cfg} />}
                    {g === "despacho" && <CompartilharMotoboys />}
                    {g === "pag_zonas" && <ExemploZonas cfg={cfg} />}
                    <div className="config-lista">{lista.map((p) => linha(p, false))}</div>
                    {g === "rastreamento" && <p className="dica">O app aplica estes ajustes na próxima sincronização. Cada motoboy pode ter um ritmo próprio em Exceções.</p>}
                  </section>
                );
              })}
              {soMudados && nMudados(visiveis.filter((p) => GRUPOS[p.grupo].area === area.chave)) === 0 && <p className="vazio">Tudo nesta área está no padrão.</p>}
            </>
          ) : null}
        </div>
      </main>
    </>
  );
}

// ------------------------------------------------------------------ um ajuste

export function Parametro({ p, valor, estado, mostrarGrupo, onSalvar, bloqueado, extra, onPadrao }: {
  p: DefParametro; valor: ValorParametro; estado: Estado; mostrarGrupo: boolean; onSalvar: (v: ValorParametro) => void;
  bloqueado?: boolean; extra?: ReactNode;
  /** Mostra "voltar ao padrão" (quando o valor está diferente do padrão). */
  onPadrao?: () => void;
}) {
  const [rascunho, setRascunho] = useState<string | null>(null);
  const timer = useRef<ReturnType<typeof setTimeout>>(undefined);
  const passo = p.passo ?? 1;
  const limitar = (n: number) => Math.min(p.max ?? Infinity, Math.max(p.min ?? -Infinity, n));
  const arred = (n: number) => Number(n.toFixed(Math.max(2, casas(passo))));

  // número: botões e digitação mudam só o rascunho; salva no ✓ (ou Enter)
  void timer;
  function digitar(t: string) { setRascunho(t); }
  function somar(d: number) {
    const atual = rascunho != null ? Number(rascunho.replace(",", ".")) || 0 : Number(valor);
    setRascunho(formatar(arred(limitar(atual + d)), passo));
  }
  const rascunhoNum = rascunho == null ? null : Number(rascunho.replace(/\./g, "").replace(",", "."));
  const rascunhoValido = rascunhoNum != null && rascunho!.trim() !== "" && !Number.isNaN(rascunhoNum);
  const mudou = rascunho != null && (!rascunhoValido || arred(limitar(rascunhoNum!)) !== Number(valor));
  function confirmar() {
    if (!rascunhoValido) return;
    onSalvar(arred(limitar(rascunhoNum!)));
    setRascunho(null);
  }

  const status = (
    <span className="config-status" aria-live="polite">
      {bloqueado && <span title="Só a plataforma altera"><Lock size={13} aria-hidden /> Plataforma</span>}
      {estado === "salvo" && <><Check size={14} aria-hidden /> salvo</>}
      {estado === "erro" && <span className="erro"><TriangleAlert size={14} aria-hidden /> erro</span>}
      {onPadrao && !estado && (
        <button type="button" className="config-padrao" onClick={(e) => { e.preventDefault(); onPadrao(); }} title={`Voltar ao padrão (${typeof p.padrao === "boolean" ? (p.padrao ? "ligado" : "desligado") : p.opcoes?.find((o) => o.valor === p.padrao)?.rotulo ?? String(p.padrao || "vazio")})`}>
          <RotateCcw size={12} aria-hidden /> padrão
        </button>
      )}
    </span>
  );

  if (p.tipo === "texto") {
    return (
      <div className={`config-item ${bloqueado ? "bloqueado" : ""}`}>
        <span className="config-item-texto">
          {mostrarGrupo && <span className="rotulo">{GRUPOS[p.grupo].titulo}</span>}
          <strong>{p.rotulo}</strong>
          {p.descricao && <span className="dica">{p.descricao}</span>}
          {extra}
        </span>
        <div className="config-controle">
          {status}
          <input className="config-texto" defaultValue={String(valor ?? "")} placeholder={p.exemplo} disabled={bloqueado} maxLength={60}
            onBlur={(e) => { if (e.target.value !== String(valor ?? "")) onSalvar(e.target.value.trim()); }} aria-label={p.rotulo} />
        </div>
      </div>
    );
  }

  if (p.tipo === "multi") {
    const lista = Array.isArray(valor) ? valor : [];
    const alternar = (k: string) => onSalvar(lista.includes(k) ? lista.filter((x) => x !== k) : [...lista, k]);
    return (
      <div className={`config-item config-item-escolha ${bloqueado ? "bloqueado" : ""}`}>
        <span className="config-item-texto">
          {mostrarGrupo && <span className="rotulo">{GRUPOS[p.grupo].titulo}</span>}
          <strong>{p.rotulo}</strong>
          {p.descricao && <span className="dica">{p.descricao}</span>}
          {extra}
        </span>
        <div className="config-controle">
          {status}
          <div className="escolhas multi" role="group" aria-label={p.rotulo}>
            {p.opcoes!.map((o) => {
              const on = lista.includes(String(o.valor));
              return (
                <button key={String(o.valor)} type="button" role="checkbox" aria-checked={on} disabled={bloqueado}
                  className={on ? "ativo" : ""} onClick={() => alternar(String(o.valor))} title={o.dica}>
                  {on ? <Check size={13} aria-hidden /> : <Plus size={13} aria-hidden />} {o.rotulo}
                </button>
              );
            })}
          </div>
          <span className="dica" style={{ textAlign: "right" }}>{lista.length === 0 ? "Nenhum marcado" : `${lista.length} marcado${lista.length > 1 ? "s" : ""}`}</span>
        </div>
      </div>
    );
  }

  if (ehRaio(p)) {
    return (
      <div className={`config-item config-item-raio ${bloqueado ? "bloqueado" : ""}`}>
        <span className="config-item-texto">
          {mostrarGrupo && <span className="rotulo">{GRUPOS[p.grupo].titulo}</span>}
          <strong>{p.rotulo}</strong>
          {p.descricao && <span className="dica">{p.descricao}</span>}
          {extra}
        </span>
        <div className="config-controle">{status}</div>
        <CampoRaio valor={Number(valor)} unidade={p.unidade as "m" | "km"} min={p.min ?? 0} max={p.max ?? (p.unidade === "km" ? 50 : 5000)} passo={p.passo ?? 1}
          desabilitado={bloqueado} onMudar={(n) => onSalvar(n)} exemplo={/entrega/.test(p.chave) ? "dupla" : /chegada|percurso/.test(p.chave) ? "endereco" : "coleta"} />
      </div>
    );
  }

  if (p.tipo === "escolha") {
    const atual = p.opcoes!.find((o) => o.valor === valor);
    return (
      <div className={`config-item config-item-escolha ${bloqueado ? "bloqueado" : ""}`}>
        <span className="config-item-texto">
          {mostrarGrupo && <span className="rotulo">{GRUPOS[p.grupo].titulo}</span>}
          <strong>{p.rotulo}</strong>
          {(atual?.dica || p.descricao) && <span className="dica">{atual?.dica ?? p.descricao}</span>}
          {extra}
        </span>
        <div className="config-controle">
          {status}
          <div className="escolhas" role="radiogroup" aria-label={p.rotulo}>
            {p.opcoes!.map((o) => (
              <button key={String(o.valor)} type="button" role="radio" aria-checked={valor === o.valor} disabled={bloqueado}
                className={valor === o.valor ? "ativo" : ""} onClick={() => onSalvar(o.valor)} title={o.dica}>{o.rotulo}</button>
            ))}
          </div>
        </div>
      </div>
    );
  }

  if (p.tipo === "booleano") {
    return (
      <label className={`config-item config-item-bool ${bloqueado ? "bloqueado" : ""}`}>
        <span className="config-item-texto">
          {mostrarGrupo && <span className="rotulo">{GRUPOS[p.grupo].titulo}</span>}
          <strong>{p.rotulo}</strong>
          {(valor ? p.descricao : p.descricaoDesligado ?? p.descricao) && <span className="dica">{valor ? p.descricao : p.descricaoDesligado ?? p.descricao}</span>}
          {extra}
        </span>
        {status}
        <input type="checkbox" role="switch" checked={Boolean(valor)} disabled={bloqueado} onChange={(e) => onSalvar(e.target.checked)} aria-label={p.rotulo} />
      </label>
    );
  }

  return (
    <div className={`config-item ${bloqueado ? "bloqueado" : ""}`}>
      <span className="config-item-texto">
        {mostrarGrupo && <span className="rotulo">{GRUPOS[p.grupo].titulo}</span>}
        <strong>{p.rotulo}</strong>
        {p.descricao && <span className="dica">{p.descricao}</span>}
        {extra}
      </span>
      <div className="config-controle">
        {status}
        {p.tipo === "opcoes" ? (
          <div className="segmentado config-opcoes" style={{ gridTemplateColumns: `repeat(${p.opcoes!.length}, 1fr)` }}>
            {p.opcoes!.map((o) => (
              <button key={String(o.valor)} type="button" disabled={bloqueado} className={Number(valor) === o.valor ? "ativo" : ""} onClick={() => onSalvar(o.valor)}>{o.rotulo}</button>
            ))}
          </div>
        ) : (
          // barra ou digitando (a pessoa escolhe no ícone; vale no site todo); salva só no ✓
          <CampoNumero valor={Number(valor)} min={p.min ?? 0} max={p.max ?? 1e9} passo={passo} unidade={p.unidade} desabilitado={bloqueado}
            onSalvar={(v) => onSalvar(arred(limitar(v)))} />
        )}
      </div>
    </div>
  );
}

// ------------------------------------------------------------------ exemplo vivo do acréscimo

/** O cálculo do motoboy com o exemplo de 1 coleta e 5 entregas (3, 9, 12, 15 e 22 km). */
function ExemploPagamento({ cfg }: { cfg: Record<string, ValorParametro> }) {
  const ds = [3, 9, 12, 15, 22];
  const regra = String(cfg.pag_km_regra ?? "mediana");
  const n = ds.length;
  const ref = regra === "media" ? ds.reduce((a, b) => a + b, 0) / n : regra === "mais_longe" ? ds[n - 1] : regra === "mais_perto" ? ds[0]
    : regra === "percentil" ? ds[Math.max(1, Math.ceil((Number(cfg.pag_km_percentil) || 75) / 100 * n)) - 1] : regra === "total_rota" ? 22 : ds[Math.floor(n / 2)];
  const vkm = Number(cfg.pag_valor_km) || 0, vext = Number(cfg.pag_entrega_extra) || 0, fixo = Number(cfg.pag_fixo_rota) || 0, min = Number(cfg.pag_minimo) || 0;
  const total = Math.max(min, fixo + ref * vkm + (n - 1) * vext);
  const m = (v: number) => v.toLocaleString("pt-BR", { style: "currency", currency: "BRL" });
  // divisão de uma rota de R$ 100 (o mesmo cálculo do banco)
  const pct = Number(cfg.repasse_motoboy_pct ?? 67.5) || 0;
  const r2 = (v: number) => Math.round(v * 100) / 100;
  const teto = 100;
  const pMoto = Math.min(teto, r2(100 * pct / 100));
  if (cfg.pag_modo === "percentual") return (
    <div className="config-exemplo"><span className="rotulo">Exemplo</span>
      <p>Rota de <strong>R$ 100,00</strong>, motoboy {pct.toLocaleString("pt-BR")}%:</p>
      <p className="config-exemplo-conta">Motoboy <strong className="texto-grad">{m(pMoto)}</strong> · Gestor <strong>{m(r2(100 - pMoto))}</strong></p>
    </div>
  );
  return (
    <div className="config-exemplo">
      <span className="rotulo">Exemplo</span>
      <p>Rota com <strong>1 coleta</strong> e <strong>5 entregas</strong> a 3, 9, 12, 15 e 22 km:</p>
      <p className="config-exemplo-conta">
        {fixo ? <>{m(fixo)} + </> : null}{ref.toLocaleString("pt-BR", { maximumFractionDigits: 1 })} km × {m(vkm)} + 4 × {m(vext)} = <strong className="texto-grad">{m(total)}</strong>
      </p>
      <p className="dica" style={{ margin: 0 }}>Nunca passa do que a rota paga: numa rota de {m(100)}, o máximo é {m(teto)}{total > teto ? `, então esta pagaria ${m(teto)}` : ""}.</p>
    </div>
  );
}

function ExemploAcrescimo({ cfg }: { cfg: Record<string, ValorParametro> }) {
  const faixa = (km: number, cada: number, fator: number) => (cada > 0 ? Math.floor(km / cada) * fator : 0);
  const ligado = Boolean(cfg.acrescimo_distancia);
  const fc = faixa(250, Number(cfg.acrescimo_coleta_cada_km), Number(cfg.acrescimo_coleta_fator));
  const fe = faixa(450, Number(cfg.acrescimo_entrega_cada_km), Number(cfg.acrescimo_entrega_fator));
  const total = ligado ? 100 * (1 + fc + fe) : 100;
  return (
    <div className="config-exemplo">
      <span className="rotulo">Exemplo</span>
      <p>
        Corrida de <strong>R$ 100,00</strong>, motoboy a <strong>250 km</strong> da coleta e <strong>450 km</strong> de percurso:
      </p>
      <p className="config-exemplo-conta">
        {ligado
          ? <>100 × (1 + {formatar(fc)} da coleta + {formatar(fe)} do percurso) = <strong className="texto-grad">{total.toLocaleString("pt-BR", { style: "currency", currency: "BRL" })}</strong></>
          : <>Acréscimo desligado: fica <strong>R$ 100,00</strong>.</>}
      </p>
    </div>
  );
}

// ------------------------------------------------------------------ exemplo vivo do pagamento por zonas

/** Duas rotas de R$ 100: entregas juntas (paga por km + fixo) e espalhadas (paga a porcentagem). */
function ExemploZonas({ cfg }: { cfg: Record<string, ValorParametro> }) {
  const m = (v: number) => v.toLocaleString("pt-BR", { style: "currency", currency: "BRL" });
  const raio = Number(cfg.zona_entrega_raio_m ?? 1500), vkm = Number(cfg.zona_valor_km ?? 2), ext = Number(cfg.zona_entrega_extra ?? 10);
  const fixo = Number(cfg.zona_fixo_rota ?? 0), min = Number(cfg.zona_minimo ?? 0), pct = Number(cfg.zona_fora_pct ?? 65);
  const regra = String(cfg.zona_km_regra ?? "mais_perto");
  const ds = [4, 4.8, 5.5];
  const ref = regra === "mais_longe" ? ds[2] : regra === "media" ? (ds[0] + ds[1] + ds[2]) / 3 : regra === "mediana" ? ds[1] : regra === "total_rota" ? 7.2 : ds[0];
  const teto = 100;
  const juntas = Math.min(teto, Math.max(min, fixo + ref * vkm + 2 * ext));
  const espalhadas = Math.min(teto, (100 * pct) / 100);
  return (
    <div className="config-exemplo">
      <span className="rotulo">Exemplo · raio de {raio.toLocaleString("pt-BR")} m em cada entrega</span>
      <p><strong>3 entregas juntas</strong> (a {ds.map((d) => d.toLocaleString("pt-BR")).join(", ")} km da coleta):</p>
      <p className="config-exemplo-conta">{fixo ? <>{m(fixo)} + </> : null}{ref.toLocaleString("pt-BR", { maximumFractionDigits: 1 })} km × {m(vkm)} + 2 × {m(ext)} = <strong className="texto-grad">{m(juntas)}</strong></p>
      <p><strong>Entregas espalhadas</strong> numa rota de {m(100)}: {pct.toLocaleString("pt-BR")}% = <strong className="texto-grad">{m(espalhadas)}</strong> · o gestor fica com o resto.</p>
      <p className="dica" style={{ margin: 0 }}>Nos dois casos o motoboy nunca passa do valor da rota ({m(teto)}).</p>
    </div>
  );
}

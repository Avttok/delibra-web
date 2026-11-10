"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { CircleDot, Clock, FlaskConical, Package, Plus, Save, Trash2, TriangleAlert } from "lucide-react";
import type { GeoJSONSource } from "maplibre-gl";
import { supabase } from "@/lib/supabase/client";
import { useMapa } from "@/lib/mapa/useMapa";
import { useEmpresas } from "@/features/corridas/dados";
import { Icone, SeletorIcone } from "@/features/ui/icones";
import { toast } from "@/features/ui/toast";

const num = (s: string) => { const n = Number(String(s).replace(",", ".")); return Number.isFinite(n) ? n : 0; };
const tx = (n: number | null | undefined) => (n == null ? "" : String(n).replace(".", ","));

function useTabela<T extends { id?: string }>(tabela: string, ordem: string) {
  const [linhas, setLinhas] = useState<T[] | null>(null);
  const carregar = useCallback(() => {
    supabase().from(tabela).select("*").order(ordem).then(({ data, error }) => { if (!error) setLinhas((data ?? []) as T[]); });
  }, [tabela, ordem]);
  useEffect(() => { carregar(); }, [carregar]);
  async function salvar(linha: Partial<T> & { id?: string }, chave = "id") {
    const sb = supabase();
    const id = (linha as Record<string, unknown>)[chave];
    const r = id && linhas?.some((l) => (l as Record<string, unknown>)[chave] === id)
      ? await sb.from(tabela).update(linha).eq(chave, id as string)
      : await sb.from(tabela).insert(linha);
    if (r.error) { toast(r.error.message, "erro"); return false; }
    toast("Salvo.", "ok"); carregar(); return true;
  }
  async function apagar(id: string, chave = "id") {
    const { error } = await supabase().from(tabela).delete().eq(chave, id);
    if (error) return toast(error.message.includes("foreign key") ? "Em uso por pedidos: desative em vez de apagar." : error.message, "erro");
    carregar();
  }
  return { linhas, salvar, apagar };
}

// ------------------------------------------------------------------ zonas

interface Zona { id?: string; nome: string; cliente_id: string | null; lat: number; lng: number; raio_m: number; fator_pct: number; adicional: number; cor: string; ativa: boolean; icone?: string | null }
const CORES = ["#d4af37", "#38bdf8", "#22c55e", "#f97316", "#a78bfa", "#ef4444"];

/** Zonas de preço. Com `clienteId`, mostra e cria só as zonas daquele cliente (aba no perfil dele). */
export function CatalogoZonas({ clienteId }: { clienteId?: string } = {}) {
  const { linhas: todas, salvar, apagar } = useTabela<Zona>("zonas", "nome");
  const linhas = clienteId ? todas?.filter((z) => z.cliente_id === clienteId) ?? null : todas;
  const [cheio, setCheio] = useState(false);
  const { empresas } = useEmpresas();
  const [ed, setEd] = useState<Zona | null>(null);
  const caixa = useRef<HTMLDivElement>(null);
  const { mapa, pronto } = useMapa(caixa);
  const edRef = useRef(ed);
  edRef.current = ed;

  useEffect(() => {
    const m = mapa.current;
    if (!m || !pronto) return;
    if (!m.getSource("zonas")) {
      m.addSource("zonas", { type: "geojson", data: { type: "FeatureCollection", features: [] } });
      m.addLayer({ id: "zonas-fundo", type: "fill", source: "zonas", paint: { "fill-color": ["get", "cor"], "fill-opacity": ["case", ["get", "ed"], 0.28, 0.14] } });
      m.addLayer({ id: "zonas-borda", type: "line", source: "zonas", paint: { "line-color": ["get", "cor"], "line-width": ["case", ["get", "ed"], 3, 1.5] } });
      m.addLayer({ id: "zonas-nome", type: "symbol", source: "zonas", filter: ["==", ["get", "centro"], true],
        layout: { "text-field": ["get", "nome"], "text-font": ["Noto Sans Bold"], "text-size": 12 }, paint: { "text-color": ["get", "cor"], "text-halo-color": "#000", "text-halo-width": 1.2 } });
      m.on("click", (e) => { const z = edRef.current; if (z) setEd({ ...z, lat: e.lngLat.lat, lng: e.lngLat.lng }); });
    }
  }, [mapa, pronto]);

  useEffect(() => {
    const m = mapa.current;
    if (!m || !pronto || !m.getSource("zonas")) return;
    const base = clienteId ? (todas ?? []).filter((z) => z.cliente_id === clienteId || z.cliente_id == null) : (todas ?? []);
    const lista = [...base.filter((z) => z.id !== ed?.id), ...(ed && ed.lat ? [ed] : [])];
    const circ = (z: Zona) => Array.from({ length: 65 }, (_, i) => {
      const a = (i / 64) * 2 * Math.PI, r = z.raio_m / 6371000, la = (z.lat * Math.PI) / 180, lo = (z.lng * Math.PI) / 180;
      const la2 = Math.asin(Math.sin(la) * Math.cos(r) + Math.cos(la) * Math.sin(r) * Math.cos(a));
      const lo2 = lo + Math.atan2(Math.sin(a) * Math.sin(r) * Math.cos(la), Math.cos(r) - Math.sin(la) * Math.sin(la2));
      return [(lo2 * 180) / Math.PI, (la2 * 180) / Math.PI];
    });
    (m.getSource("zonas") as GeoJSONSource).setData({
      type: "FeatureCollection",
      features: lista.flatMap((z) => [
        { type: "Feature" as const, properties: { cor: z.cor, ed: z === ed, nome: z.nome, centro: false }, geometry: { type: "Polygon" as const, coordinates: [circ(z)] } },
        { type: "Feature" as const, properties: { cor: z.cor, ed: z === ed, nome: z.nome, centro: true }, geometry: { type: "Point" as const, coordinates: [z.lng, z.lat] } },
      ]),
    });
  }, [mapa, pronto, todas, ed, clienteId]);

  function nova() {
    const c = mapa.current?.getCenter();
    setEd({ nome: "Nova zona", cliente_id: clienteId ?? null, icone: "map-pin", lat: c?.lat ?? -27.2, lng: c?.lng ?? -49.5, raio_m: 2000, fator_pct: 10, adicional: 0, cor: CORES[(linhas?.length ?? 0) % CORES.length], ativa: true });
  }
  function focar(z: Zona) {
    setEd(z);
    mapa.current?.flyTo({ center: [z.lng, z.lat], zoom: Math.max(10, 15 - Math.log2(z.raio_m / 300)) });
  }

  useEffect(() => { const t = setTimeout(() => mapa.current?.resize(), 60); return () => clearTimeout(t); }, [cheio, mapa]);
  return (
    <div className="catalogo">
      <p className="dica" style={{ margin: 0 }}>
        {clienteId ? "Zonas só deste cliente: valem nos pedidos dele (junto com as gerais, ou no lugar delas se a regra “Zona exclusiva do cliente” estiver ligada)."
          : "Se algum ponto do pedido (coleta ou entrega) cair dentro do raio, a zona soma no orçamento. Zona de um cliente só vale para ele."}
      </p>
      <div className={`catalogo-zonas ${cheio ? "tela-cheia" : ""}`}>
        <div className="catalogo-mapa" ref={caixa} />
        <div className="catalogo-zonas-acoes">
          <button type="button" className="botao-ouro" onClick={nova}><Plus size={16} aria-hidden /> Nova zona</button>
          <button type="button" className="botao-texto vidro" onClick={() => setCheio(!cheio)}>{cheio ? "Sair da tela cheia" : "Tela cheia"}</button>
        </div>
        <div className="catalogo-lado vidro">
          {ed && (
            <div className="catalogo-form vidro">
              <p className="dica" style={{ margin: 0 }}>Clique no mapa para mudar o centro.</p>
              <div className="linha-icone"><SeletorIcone valor={ed.icone} onMudar={(v) => setEd({ ...ed, icone: v })} padrao={CircleDot} />
                <label className="campo" style={{ flex: 1 }}><span>Nome</span><input value={ed.nome} onChange={(e) => setEd({ ...ed, nome: e.target.value })} /></label></div>
              <label className="campo"><span>Raio: {(ed.raio_m / 1000).toLocaleString("pt-BR")} km</span>
                <input type="range" className="barra-raio" style={{ ["--pct" as string]: `${((ed.raio_m - 100) / 29900) * 100}%` }} min={100} max={30000} step={100} value={ed.raio_m} onChange={(e) => setEd({ ...ed, raio_m: Number(e.target.value) })} /></label>
              <div className="grade-campos">
                <label className="campo"><span>Acréscimo %</span><input inputMode="decimal" value={tx(ed.fator_pct)} onChange={(e) => setEd({ ...ed, fator_pct: num(e.target.value) })} /></label>
                <label className="campo"><span>Taxa fixa R$</span><input inputMode="decimal" value={tx(ed.adicional)} onChange={(e) => setEd({ ...ed, adicional: num(e.target.value) })} /></label>
              </div>
              {!clienteId && <label className="campo"><span>Vale para</span>
                <select value={ed.cliente_id ?? ""} onChange={(e) => setEd({ ...ed, cliente_id: e.target.value || null })}>
                  <option value="">Todos os clientes</option>
                  {empresas.map((c) => <option key={c.id} value={c.id}>{c.nome}</option>)}
                </select></label>}
              <div className="cores">{CORES.map((c) => <button key={c} type="button" aria-label={c} className={ed.cor === c ? "ativo" : ""} style={{ background: c }} onClick={() => setEd({ ...ed, cor: c })} />)}</div>
              <label className="opcao"><span>Ativa</span><input type="checkbox" role="switch" checked={ed.ativa} onChange={(e) => setEd({ ...ed, ativa: e.target.checked })} /></label>
              <div className="linha-botoes">
                <button type="button" className="botao-ouro" onClick={async () => { const { id, ...resto } = ed; if (await salvar(id ? ed : resto)) setEd(null); }}><Save size={15} aria-hidden /> Salvar</button>
                <button type="button" className="botao-texto" onClick={() => setEd(null)}>Cancelar</button>
              </div>
            </div>
          )}
          <div className="catalogo-lista">
            {linhas?.length === 0 && <p className="vazio">Nenhuma zona ainda.</p>}
            {linhas?.map((z) => (
              <div key={z.id} className={`catalogo-linha ${ed?.id === z.id ? "ativo" : ""} ${z.ativa ? "" : "inativa"}`}>
                <button type="button" className="catalogo-linha-corpo" onClick={() => focar(z)}>
                  <Icone nome={z.icone} padrao={CircleDot} size={15} style={{ color: z.cor }} />
                  <span><strong>{z.nome}</strong><small>{(z.raio_m / 1000).toLocaleString("pt-BR")} km · {z.fator_pct ? `+${tx(z.fator_pct)}%` : ""}{z.adicional ? ` +R$ ${tx(z.adicional)}` : ""}{z.cliente_id ? ` · ${empresas.find((c) => c.id === z.cliente_id)?.nome ?? "cliente"}` : ""}</small></span>
                </button>
                <button type="button" className="icone" aria-label="Apagar zona" onClick={() => z.id && apagar(z.id)}><Trash2 size={14} /></button>
              </div>
            ))}
          </div>
        </div>
      </div>
    </div>
  );
}

// ------------------------------------------------------------------ horários de pico

interface Faixa { id?: string; nome: string; cliente_id: string | null; dias: number[]; inicio: string; fim: string; fator_pct: number; adicional: number; ativa: boolean; icone?: string | null }
const DIAS = ["Dom", "Seg", "Ter", "Qua", "Qui", "Sex", "Sáb"];

export function CatalogoHorarios() {
  const { linhas, salvar, apagar } = useTabela<Faixa>("faixas_horario", "inicio");
  const { empresas } = useEmpresas();
  const [ed, setEd] = useState<Faixa | null>(null);
  return (
    <div className="catalogo">
      <p className="dica" style={{ margin: 0 }}>Vale pelo horário da coleta (ou do agendamento). Se cair em duas faixas, vale a de maior acréscimo.</p>
      <button type="button" className="botao-ouro" style={{ alignSelf: "flex-start" }} onClick={() => setEd({ nome: "Pico", cliente_id: null, dias: [1, 2, 3, 4, 5], inicio: "17:00", fim: "19:00", fator_pct: 15, adicional: 0, ativa: true })}>
        <Plus size={16} aria-hidden /> Nova faixa
      </button>
      {ed && (
        <div className="catalogo-form vidro">
          <div className="linha-icone"><SeletorIcone valor={ed.icone} onMudar={(v) => setEd({ ...ed, icone: v })} padrao={Clock} />
            <label className="campo" style={{ flex: 1 }}><span>Nome</span><input value={ed.nome} onChange={(e) => setEd({ ...ed, nome: e.target.value })} /></label></div>
          <div className="dias-semana">{DIAS.map((d, i) => (
            <button key={d} type="button" className={ed.dias.includes(i) ? "ativo" : ""} onClick={() => setEd({ ...ed, dias: ed.dias.includes(i) ? ed.dias.filter((x) => x !== i) : [...ed.dias, i].sort() })}>{d}</button>
          ))}</div>
          <div className="grade-campos">
            <label className="campo"><span>Das</span><input type="time" value={ed.inicio.slice(0, 5)} onChange={(e) => setEd({ ...ed, inicio: e.target.value })} /></label>
            <label className="campo"><span>Até</span><input type="time" value={ed.fim.slice(0, 5)} onChange={(e) => setEd({ ...ed, fim: e.target.value })} /></label>
            <label className="campo"><span>Acréscimo %</span><input inputMode="decimal" value={tx(ed.fator_pct)} onChange={(e) => setEd({ ...ed, fator_pct: num(e.target.value) })} /></label>
            <label className="campo"><span>Taxa fixa R$</span><input inputMode="decimal" value={tx(ed.adicional)} onChange={(e) => setEd({ ...ed, adicional: num(e.target.value) })} /></label>
          </div>
          <label className="campo"><span>Vale para</span>
            <select value={ed.cliente_id ?? ""} onChange={(e) => setEd({ ...ed, cliente_id: e.target.value || null })}>
              <option value="">Todos os clientes</option>{empresas.map((c) => <option key={c.id} value={c.id}>{c.nome}</option>)}
            </select></label>
          <label className="opcao"><span>Ativa</span><input type="checkbox" role="switch" checked={ed.ativa} onChange={(e) => setEd({ ...ed, ativa: e.target.checked })} /></label>
          <div className="linha-botoes">
            <button type="button" className="botao-ouro" onClick={async () => { const { id, ...resto } = ed; if (await salvar(id ? ed : resto)) setEd(null); }}><Save size={15} aria-hidden /> Salvar</button>
            <button type="button" className="botao-texto" onClick={() => setEd(null)}>Cancelar</button>
          </div>
        </div>
      )}
      <div className="catalogo-lista">
        {linhas?.length === 0 && <p className="vazio">Nenhuma faixa de horário.</p>}
        {linhas?.map((f) => (
          <div key={f.id} className={`catalogo-linha ${f.ativa ? "" : "inativa"}`}>
            <button type="button" className="catalogo-linha-corpo" onClick={() => setEd(f)}>
              <Icone nome={f.icone} padrao={Clock} size={15} />
              <span><strong>{f.nome}</strong><small>{f.dias.map((d) => DIAS[d]).join(", ")} · {f.inicio.slice(0, 5)}–{f.fim.slice(0, 5)} · {f.fator_pct ? `+${tx(f.fator_pct)}%` : ""}{f.adicional ? ` +R$ ${tx(f.adicional)}` : ""}{f.cliente_id ? ` · ${empresas.find((c) => c.id === f.cliente_id)?.nome ?? ""}` : ""}</small></span>
            </button>
            <button type="button" className="icone" aria-label="Apagar faixa" onClick={() => f.id && apagar(f.id)}><Trash2 size={14} /></button>
          </div>
        ))}
      </div>
    </div>
  );
}

// ------------------------------------------------------------------ categorias

type Campo = "oculto" | "opcional" | "obrigatorio";
interface Categoria { id?: string; nome: string; descricao: string | null; perigoso: boolean; classe_risco: string | null; fragil: boolean; adicional_item: number; adicional_fixo: number; fator_pct: number; ativa: boolean; ordem: number;
  icone?: string | null; campo_descricao?: Campo; campo_peso?: Campo; campo_medidas?: Campo; campo_valor?: Campo; campo_quantidade?: Campo }
const CAMPOS: [keyof Categoria, string][] = [["campo_quantidade", "Quantidade"], ["campo_descricao", "Descrição"], ["campo_peso", "Peso"], ["campo_medidas", "Medidas"], ["campo_valor", "Valor declarado"]];
const ROTULO_CAMPO: Record<Campo, string> = { oculto: "Não pede", opcional: "Opcional", obrigatorio: "Obrigatório" };

export function CatalogoCategorias() {
  const { linhas, salvar, apagar } = useTabela<Categoria>("categorias_produto", "ordem");
  const [ed, setEd] = useState<Categoria | null>(null);
  return (
    <div className="catalogo">
      <p className="dica" style={{ margin: 0 }}>O cliente escolhe a categoria de cada item. Perigoso soma a taxa de perigoso (em Preço do cliente) e, se ligado em Rotas, vai em rota separada.</p>
      <button type="button" className="botao-ouro" style={{ alignSelf: "flex-start" }} onClick={() => setEd({ nome: "", descricao: "", perigoso: false, classe_risco: null, fragil: false, adicional_item: 0, adicional_fixo: 0, fator_pct: 0, ativa: true, ordem: (linhas?.length ?? 0),
        icone: "package", campo_descricao: "opcional", campo_peso: "opcional", campo_medidas: "opcional", campo_valor: "oculto", campo_quantidade: "opcional" })}>
        <Plus size={16} aria-hidden /> Nova categoria
      </button>
      {ed && (
        <div className="catalogo-form vidro">
          <div className="linha-icone"><SeletorIcone valor={ed.icone} onMudar={(v) => setEd({ ...ed, icone: v })} />
            <label className="campo" style={{ flex: 1 }}><span>Nome</span><input value={ed.nome} onChange={(e) => setEd({ ...ed, nome: e.target.value })} /></label></div>
          <label className="campo"><span>Descrição</span><input value={ed.descricao ?? ""} onChange={(e) => setEd({ ...ed, descricao: e.target.value })} /></label>
          <span className="rotulo">O que o cliente preenche</span>
          <div className="campos-categoria">
            {CAMPOS.map(([k, r]) => (
              <label key={k} className="campo"><span>{r}</span>
                <select value={(ed[k] as Campo | undefined) ?? "opcional"} onChange={(e) => setEd({ ...ed, [k]: e.target.value as Campo })}>
                  {(Object.keys(ROTULO_CAMPO) as Campo[]).map((c) => <option key={c} value={c}>{ROTULO_CAMPO[c]}</option>)}
                </select></label>
            ))}
          </div>
          <div className="grade-campos">
            <label className="campo"><span>Por item R$</span><input inputMode="decimal" value={tx(ed.adicional_item)} onChange={(e) => setEd({ ...ed, adicional_item: num(e.target.value) })} /></label>
            <label className="campo"><span>Por pedido R$</span><input inputMode="decimal" value={tx(ed.adicional_fixo)} onChange={(e) => setEd({ ...ed, adicional_fixo: num(e.target.value) })} /></label>
            <label className="campo"><span>Acréscimo %</span><input inputMode="decimal" value={tx(ed.fator_pct)} onChange={(e) => setEd({ ...ed, fator_pct: num(e.target.value) })} /></label>
          </div>
          <label className="opcao"><span><FlaskConical size={14} aria-hidden /> Perigoso (químico, inflamável, corrosivo…)</span><input type="checkbox" role="switch" checked={ed.perigoso} onChange={(e) => setEd({ ...ed, perigoso: e.target.checked })} /></label>
          {ed.perigoso && <label className="campo"><span>Classe de risco</span><input placeholder="Ex.: Inflamável" value={ed.classe_risco ?? ""} onChange={(e) => setEd({ ...ed, classe_risco: e.target.value })} /></label>}
          <label className="opcao"><span>Frágil (o motoboy é avisado)</span><input type="checkbox" role="switch" checked={ed.fragil} onChange={(e) => setEd({ ...ed, fragil: e.target.checked })} /></label>
          <label className="opcao"><span>Ativa</span><input type="checkbox" role="switch" checked={ed.ativa} onChange={(e) => setEd({ ...ed, ativa: e.target.checked })} /></label>
          <div className="linha-botoes">
            <button type="button" className="botao-ouro" disabled={!ed.nome.trim()} onClick={async () => { const { id, ...resto } = ed; if (await salvar(id ? ed : resto)) setEd(null); }}><Save size={15} aria-hidden /> Salvar</button>
            <button type="button" className="botao-texto" onClick={() => setEd(null)}>Cancelar</button>
          </div>
        </div>
      )}
      <div className="catalogo-lista">
        {linhas?.map((k) => (
          <div key={k.id} className={`catalogo-linha ${k.ativa ? "" : "inativa"}`}>
            <button type="button" className="catalogo-linha-corpo" onClick={() => setEd(k)}>
              <Icone nome={k.icone} padrao={k.perigoso ? TriangleAlert : Package} size={15} style={k.perigoso ? { color: "var(--vermelho)" } : undefined} />
              <span><strong>{k.nome}</strong><small>{[k.perigoso && (k.classe_risco || "Perigoso"), k.fragil && "Frágil", k.adicional_item ? `+R$ ${tx(k.adicional_item)}/item` : "", k.adicional_fixo ? `+R$ ${tx(k.adicional_fixo)}` : "", k.fator_pct ? `+${tx(k.fator_pct)}%` : "",
                CAMPOS.filter(([c]) => k[c] === "obrigatorio").map(([, r]) => r.toLowerCase()).join(", ") && `pede ${CAMPOS.filter(([c]) => k[c] === "obrigatorio").map(([, r]) => r.toLowerCase()).join(", ")}`].filter(Boolean).join(" · ") || "sem taxa"}</small></span>
            </button>
            <button type="button" className="icone" aria-label="Apagar categoria" onClick={() => k.id && apagar(k.id)}><Trash2 size={14} /></button>
          </div>
        ))}
      </div>
    </div>
  );
}

// ------------------------------------------------------------------ tipos de pedido

interface Tipo { chave: string; nome: string; descricao: string | null; ativo: boolean; ordem: number; icone?: string | null }

export function CatalogoTipos() {
  const { linhas, salvar } = useTabela<Tipo & { id?: string }>("tipos_pedido", "ordem");
  const [ed, setEd] = useState<(Tipo & { nova?: boolean }) | null>(null);
  return (
    <div className="catalogo">
      <p className="dica" style={{ margin: 0 }}>Cada tipo pode ter regras próprias em Exceções (despacho, preço, revisão, rotas).</p>
      <button type="button" className="botao-ouro" style={{ alignSelf: "flex-start" }} onClick={() => setEd({ chave: "", nome: "", descricao: "", ativo: true, ordem: linhas?.length ?? 0, nova: true })}>
        <Plus size={16} aria-hidden /> Novo tipo
      </button>
      {ed && (
        <div className="catalogo-form vidro">
          <div className="linha-icone"><SeletorIcone valor={ed.icone} onMudar={(v) => setEd({ ...ed, icone: v })} />
          <label className="campo" style={{ flex: 1 }}><span>Nome</span><input value={ed.nome} onChange={(e) => setEd({ ...ed, nome: e.target.value, chave: ed.nova ? e.target.value.normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase().replace(/[^a-z0-9]+/g, "_").replace(/^_|_$/g, "").slice(0, 40) : ed.chave })} /></label></div>
          <label className="campo"><span>Descrição</span><input value={ed.descricao ?? ""} onChange={(e) => setEd({ ...ed, descricao: e.target.value })} /></label>
          <label className="opcao"><span>Ativo</span><input type="checkbox" role="switch" checked={ed.ativo} onChange={(e) => setEd({ ...ed, ativo: e.target.checked })} /></label>
          <div className="linha-botoes">
            <button type="button" className="botao-ouro" disabled={ed.chave.length < 2 || !ed.nome.trim()} onClick={async () => { const { nova, ...l } = ed; void nova; if (await salvar(l, "chave")) setEd(null); }}><Save size={15} aria-hidden /> Salvar</button>
            <button type="button" className="botao-texto" onClick={() => setEd(null)}>Cancelar</button>
          </div>
        </div>
      )}
      <div className="catalogo-lista">
        {linhas?.map((t) => (
          <div key={t.chave} className={`catalogo-linha ${t.ativo ? "" : "inativa"}`}>
            <button type="button" className="catalogo-linha-corpo" onClick={() => setEd(t)}>
              <Icone nome={t.icone} size={15} /><span><strong>{t.nome}</strong><small>{t.descricao || t.chave}</small></span>
            </button>
          </div>
        ))}
      </div>
    </div>
  );
}

"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import { AlertTriangle, BatteryMedium, Bike, Crosshair, Flame, FlaskConical, LocateFixed, Map as IconeMapa, Search, Signpost, Timer } from "lucide-react";
import { maplibregl } from "@/lib/mapa/maplibre";
import { useMapa } from "@/lib/mapa/useMapa";
import { useModoRuas, useRotulos, type ModoRuas, type Rotulos } from "@/lib/mapa/estabelecimentos";
import { aplicarAjustes, criarCamadasPercurso, desenharCalor, desenharPercursos, kmRegistro, separarRegistros, type Registro } from "@/lib/mapa/percursos";
import { corOuro } from "@/lib/mapa/cores";
import { CabecaPagina } from "@/features/ui/CabecaPagina";
import { useModoTeste } from "@/features/teste/modoTeste";
import { useConta } from "@/features/conta/conta";
import { useRastreamento } from "./useRastreamento";
import { carregarCalor, ROTULO_CALOR, type TipoCalor } from "./calor";
import { COR_STATUS, ROTULO_STATUS, type Motoboy } from "./tipos";
import { SimuladorGps } from "./Simulador";
import { useConfiguracoes } from "@/features/configuracoes/useConfiguracoes";

const MOTO = `<svg viewBox="0 0 24 24" width="11" height="11" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><circle cx="18.5" cy="17.5" r="3.5"/><circle cx="5.5" cy="17.5" r="3.5"/><circle cx="15" cy="5" r="1"/><path d="M12 17.5V14l-3-3 4-3 2 3h2"/></svg>`;
const FRASCO = `<svg viewBox="0 0 24 24" width="11" height="11" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M10 2v7.31"/><path d="M14 9.3V1.99"/><path d="M8.5 2h7"/><path d="M14 9.3a6.5 6.5 0 1 1-4 0"/><path d="M5.52 16h12.96"/></svg>`;
/** Cores do motoboy em modo teste (seguem o violeta do tema de teste). */
const COR_TESTE: Record<Motoboy["status"], string> = { offline: "#8a8a8a", disponivel: "#a78bfa", em_corrida: "#8b5cf6" };
export const corMotoboy = (m: Motoboy) => (m.modo_teste ? COR_TESTE : COR_STATUS)[m.status];

/** Offline vai esmaecendo com o tempo sem sinal; passou do limite, some do mapa (null). */
function opacidade(m: Motoboy, agora: number, someH: number, esmaecer: boolean): number | null {
  if (m.status !== "offline") return 1;
  const h = m.posicao_em ? (agora - new Date(m.posicao_em).getTime()) / 3_600_000 : Infinity;
  if (someH > 0 && h > someH) return null;
  if (!esmaecer) return 0.6;
  return Math.max(0.15, 0.7 - 0.55 * Math.min(1, h / Math.max(someH || 24, 1)));
}

const ORDEM: Record<Motoboy["status"], number> = { em_corrida: 0, disponivel: 1, offline: 2 };
type Filtro = "todos" | Motoboy["status"];
const FILTROS: [Filtro, string][] = [["todos", "Todos"], ["em_corrida", "Em corrida"], ["disponivel", "Disponíveis"], ["offline", "Offline"]];

/** Tempo máximo sem posição antes de marcar "sem sinal" (3 ciclos do intervalo). */
function limiteSemSinalMs(m: Motoboy): number {
  if (m.status === "em_corrida") return (m.modo_economia ? 90 : 45) * 3 * 1000;
  if (m.status === "disponivel") return 3 * 60 * 3 * 1000;
  return Infinity;
}

function ha(agora: number, iso: string | null): string {
  if (!iso) return "—";
  const s = Math.max(0, Math.round((agora - new Date(iso).getTime()) / 1000));
  if (s < 60) return `há ${s}s`;
  if (s < 3600) return `há ${Math.floor(s / 60)} min`;
  if (s < 86400) return `há ${Math.floor(s / 3600)} h`;
  return `há ${Math.floor(s / 86400)} d`;
}
const horaCurta = (iso: string) => new Date(iso).toLocaleTimeString("pt-BR", { hour: "2-digit", minute: "2-digit" });

export function MapaAoVivo() {
  const { motoboys, nomes, fotos, trilhas: todasTrilhas, ajustes, conectado, erro } = useRastreamento();
  const conta = useConta();
  const { teste } = useModoTeste();
  const trilhas = useMemo(() => (conta.modulo("trilhas_mapa") ? todasTrilhas : {}), [conta, todasTrilhas]);
  const container = useRef<HTMLDivElement>(null);
  const { mapa, pronto } = useMapa(container);
  const marcadores = useRef<Record<string, maplibregl.Marker>>({});
  const enquadrado = useRef(false);
  const [seguindo, setSeguindo] = useState<string | null>(null);
  const [agora, setAgora] = useState(() => Date.now());
  const [filtro, setFiltro] = useState<Filtro>("todos");
  const [busca, setBusca] = useState("");
  const [calor, setCalor] = useState<TipoCalor | "">("");
  const [destaque, setDestaque] = useState<number | null>(null);
  const [ruas, setRuas] = useModoRuas();
  const [rotulos, setRotulos] = useRotulos();
  const comIcones = conta.modulo("estabelecimentos");
  const cfg = useConfiguracoes() as unknown as Record<string, unknown>;
  const someH = Number(cfg.mapa_offline_some_h ?? 24);
  const esmaecer = cfg.mapa_offline_esmaecer !== false;

  useEffect(() => {
    const t = setInterval(() => setAgora(Date.now()), 1000);
    return () => clearInterval(t);
  }, []);

  // camadas (recriadas sempre que o mapa é recriado, ex.: troca de tema)
  useEffect(() => {
    const m = mapa.current;
    if (!m || !pronto) return;
    marcadores.current = {};
    enquadrado.current = false;
    criarCamadasPercurso(m, teste);
  }, [mapa, pronto, teste]);

  // registros: de quem está selecionado, todos do período (com pings); dos outros, só o trecho atual
  const registros = useMemo(() => {
    const porMotoboy: Record<string, Registro[]> = {};
    for (const [id, lista] of Object.entries(trilhas)) porMotoboy[id] = aplicarAjustes(separarRegistros(lista), id, ajustes);
    return porMotoboy;
  }, [trilhas, ajustes]);
  useEffect(() => { setDestaque(null); }, [seguindo]);
  useEffect(() => {
    const m = mapa.current;
    if (!m || !pronto) return;
    if (seguindo) desenharPercursos(m, registros[seguindo] ?? [], teste, destaque, true);
    else desenharPercursos(m, Object.entries(registros).filter(([id]) => motoboys[id]?.status !== "offline").map(([, rs]) => rs[rs.length - 1]).filter(Boolean), teste, null, false);
  }, [mapa, pronto, registros, seguindo, destaque, teste, motoboys]);

  // mapa de calor
  useEffect(() => {
    const m = mapa.current;
    if (!m || !pronto) return;
    if (!calor) { desenharCalor(m, null, corOuro()); return; }
    let vivo = true;
    carregarCalor(calor, teste).then((p) => { if (vivo && mapa.current) desenharCalor(mapa.current, p, corOuro()); });
    return () => { vivo = false; };
  }, [mapa, pronto, calor, teste]);

  // marcadores: alfinete com a foto (ou inicial) e a moto
  useEffect(() => {
    const m = mapa.current;
    if (!m || !pronto) return;
    const vistos = new Set<string>();
    const limites = new maplibregl.LngLatBounds();
    for (const mb of Object.values(motoboys)) {
      if (mb.lat == null || mb.lng == null) continue;
      const op = opacidade(mb, Date.now(), someH, esmaecer);
      if (op == null && seguindo !== mb.id) continue; // sumido há tempo demais
      vistos.add(mb.id);
      limites.extend([mb.lng, mb.lat]);
      const nome = nomes[mb.id] || "Motoboy";
      let marcador = marcadores.current[mb.id];
      if (!marcador) {
        const el = document.createElement("button");
        el.className = "pino";
        el.innerHTML = `<span class="pino-foto"></span><span class="pino-moto"></span><span class="pino-nome"></span>`;
        el.addEventListener("click", () => setSeguindo((s) => (s === mb.id ? null : mb.id)));
        marcador = new maplibregl.Marker({ element: el, anchor: "bottom" }).setLngLat([mb.lng, mb.lat]).addTo(m);
        marcadores.current[mb.id] = marcador;
      }
      const el = marcador.getElement();
      const foto = fotos[mb.id];
      const caixa = el.querySelector<HTMLElement>(".pino-foto")!;
      caixa.textContent = foto ? "" : nome.trim().charAt(0).toUpperCase();
      caixa.style.backgroundImage = foto ? `url("${foto}")` : "";
      el.querySelector<HTMLElement>(".pino-nome")!.textContent = nome.split(" ")[0];
      el.title = `${nome} · ${ROTULO_STATUS[mb.status]}`;
      el.style.setProperty("--cor", corMotoboy(mb));
      el.style.opacity = String(op ?? 0.5);
      el.dataset.status = mb.status;
      el.classList.toggle("teste", Boolean(mb.modo_teste));
      const icone = el.querySelector<HTMLElement>(".pino-moto")!;
      const queria = mb.modo_teste ? "frasco" : "moto";
      if (icone.dataset.icone !== queria) { icone.innerHTML = mb.modo_teste ? FRASCO : MOTO; icone.dataset.icone = queria; }
      el.classList.toggle("seguindo", seguindo === mb.id);
      // disponível e em corrida sempre por cima dos offline (e quem está sendo seguido no topo)
      el.style.zIndex = seguindo === mb.id ? "6" : mb.status === "offline" ? "1" : mb.status === "disponivel" || mb.status === "em_corrida" ? "4" : "2";
      el.classList.toggle("escondido", filtro !== "todos" && mb.status !== filtro);
      marcador.setLngLat([mb.lng, mb.lat]);
    }
    for (const id of Object.keys(marcadores.current)) {
      if (!vistos.has(id)) { marcadores.current[id].remove(); delete marcadores.current[id]; }
    }
    if (!enquadrado.current && !limites.isEmpty()) {
      m.fitBounds(limites, { padding: { top: 80, bottom: 80, left: window.innerWidth > 860 ? 420 : 40, right: 80 }, maxZoom: 15, duration: 0 });
      enquadrado.current = true;
    }
  }, [mapa, motoboys, nomes, fotos, pronto, seguindo, filtro, someH, esmaecer, Math.floor(agora / 60_000)]); // eslint-disable-line react-hooks/exhaustive-deps

  // seguir motoboy
  const alvo = seguindo ? motoboys[seguindo] : null;
  useEffect(() => {
    if (!alvo || alvo.lat == null || alvo.lng == null) return;
    mapa.current?.easeTo({ center: [alvo.lng, alvo.lat], zoom: Math.max(mapa.current.getZoom(), 15), duration: 800 });
  }, [mapa, alvo?.lat, alvo?.lng, alvo]);

  const todos = useMemo(
    () => Object.values(motoboys).sort((a, b) => ORDEM[a.status] - ORDEM[b.status] || (nomes[a.id] ?? "").localeCompare(nomes[b.id] ?? "")),
    [motoboys, nomes],
  );
  const contagem = (s: Filtro) => (s === "todos" ? todos.length : todos.filter((m) => m.status === s).length);
  const termo = busca.trim().toLowerCase();
  const lista = todos.filter((m) => (filtro === "todos" || m.status === filtro) && (!termo || (nomes[m.id] ?? "").toLowerCase().includes(termo)));
  const ativos = todos.filter((m) => m.status !== "offline").length;
  const regsSeguindo = seguindo ? registros[seguindo] ?? [] : [];

  return (
    <>
      <aside className="lateral entrar">
        <CabecaPagina icone={IconeMapa} titulo="Mapa" subtitulo={`${ativos} em serviço · ${todos.length} motoboy${todos.length === 1 ? "" : "s"}`} />
        <span className={`conexao ${conectado ? "on" : ""}`}>{conectado ? "Tempo real conectado" : "Conectando…"}</span>
        {erro && <p className="erro">{erro}</p>}

        <div className="camadas-mapa">
          <label className="camada-sel"><Flame size={14} aria-hidden />
            <select value={calor} onChange={(e) => setCalor(e.target.value as TipoCalor | "")} aria-label="Mapa de calor">
              <option value="">Sem mapa de calor</option>
              {(Object.keys(ROTULO_CALOR) as TipoCalor[]).map((k) => <option key={k} value={k}>Calor: {ROTULO_CALOR[k]}</option>)}
            </select>
          </label>
          <label className="camada-sel"><Signpost size={14} aria-hidden />
            {comIcones ? (
              <select value={rotulos} onChange={(e) => setRotulos(e.target.value as Rotulos)} aria-label="Nomes no mapa">
                <option value="tudo">Ruas e ícones</option>
                <option value="ruas">Só ruas</option>
                <option value="icones">Só ícones</option>
                <option value="nada">Sem nomes</option>
              </select>
            ) : (
              <select value={ruas} onChange={(e) => setRuas(e.target.value as ModoRuas)} aria-label="Nomes de rua">
                <option value="rua">Ruas: nome na rua</option>
                <option value="oculta">Ruas: ocultar nomes</option>
              </select>
            )}
          </label>
        </div>

        <div className="filtro filtro-rolavel">
          {FILTROS.map(([f, r]) => (
            <button key={f} className={filtro === f ? "ativo" : ""} onClick={() => setFiltro(f)}>{r} <span className="contagem">{contagem(f)}</span></button>
          ))}
        </div>
        {todos.length > 6 && (
          <label className="busca-mini"><Search size={14} aria-hidden /><input placeholder="Buscar motoboy" value={busca} onChange={(e) => setBusca(e.target.value)} /></label>
        )}
        {todos.length === 0 && !erro && <p className="vazio">Nenhum motoboy ainda. Abra o app no celular e fique &quot;Disponível&quot;.</p>}
        {lista.map((mb) => {
          const semSinal = mb.status !== "offline" && (!mb.posicao_em || agora - new Date(mb.posicao_em).getTime() > limiteSemSinalMs(mb));
          const sel = seguindo === mb.id;
          return (
            <div key={mb.id} className={`linha-motoboy ${sel ? "selecionado" : ""}`}>
              <button className="linha-motoboy-topo" onClick={() => setSeguindo((s) => (s === mb.id ? null : mb.id))}>
                {fotos[mb.id]
                  // eslint-disable-next-line @next/next/no-img-element
                  ? <img src={fotos[mb.id]} alt="" className="foto-mini" style={{ borderColor: corMotoboy(mb) }} />
                  : <span className="foto-mini inicial" style={{ borderColor: corMotoboy(mb) }}>{(nomes[mb.id] || "M").charAt(0)}</span>}
                <span className="linha-motoboy-texto">
                  <strong>{nomes[mb.id] || "Motoboy"}{mb.modo_teste && <FlaskConical size={12} aria-label="teste" style={{ color: "#a78bfa", marginLeft: 5 }} />}</strong>
                  <span><Timer size={11} aria-hidden /> {ha(agora, mb.posicao_em)}
                    {mb.precisao_m != null && <> · <Crosshair size={11} aria-hidden /> ±{Math.round(mb.precisao_m)} m</>}
                    {mb.bateria != null && <> · <BatteryMedium size={11} aria-hidden /> {mb.bateria}%</>}</span>
                </span>
                <span className="selo" style={{ color: corMotoboy(mb) }}>{ROTULO_STATUS[mb.status]}</span>
              </button>
              {semSinal && <div className="alerta"><AlertTriangle size={13} aria-hidden /> Sem sinal recente</div>}
              {sel && (
                <div className="registros">
                  <span className="seguindo"><LocateFixed size={13} aria-hidden /> Seguindo no mapa · clique de novo para soltar</span>
                  {mb.modo_teste && cfg.simulador_ligado !== false && (
                    <SimuladorGps motoboyId={mb.id} mapa={mapa} posicao={mb.lat != null && mb.lng != null ? { lat: mb.lat, lng: mb.lng } : null}
                      velocidadePadrao={Number(cfg.simulador_velocidade_kmh ?? 35)} />
                  )}
                  {regsSeguindo.length === 0 ? <span className="dica">Sem percursos nas últimas 12 h.</span> : regsSeguindo.map((r, i) => (
                    <button key={i} className={`registro ${destaque === i ? "ativo" : ""}`} onClick={() => setDestaque((d) => (d === i ? null : i))}>
                      {r.tipo === "corrida" ? <Bike size={13} aria-hidden /> : <Search size={13} aria-hidden />}
                      <span>{r.tipo === "corrida" ? "Corrida" : "Procurando corrida"}</span>
                      <span className="dica">{horaCurta(r.inicio)}–{horaCurta(r.fim)} · {kmRegistro(r).toLocaleString("pt-BR", { maximumFractionDigits: 1 })} km · {r.pontos.length} pings</span>
                    </button>
                  ))}
                </div>
              )}
            </div>
          );
        })}
        {seguindo && (
          <div className="legenda-percurso">
            <span>Início</span><span className={`degrade ${teste ? "teste" : ""}`} /><span>Agora</span>
          </div>
        )}
      </aside>
      <div ref={container} className="mapa" />
    </>
  );
}

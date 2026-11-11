"use client";

import { useEffect, useRef, useState, type ReactNode } from "react";
import { Crosshair, Maximize2, Minus, Plus, X } from "lucide-react";
import { maplibregl } from "@/lib/mapa/maplibre";
import { useMapa } from "@/lib/mapa/useMapa";
import { corOuro } from "@/lib/mapa/cores";
import { decodificarPolyline } from "@/lib/geo/polyline";
import { geo } from "@/features/geo";
import { COR_STATUS, type StatusMotoboy } from "@/features/rastreamento/tipos";

export interface PinoParada {
  chave: string;
  lat: number;
  lng: number;
  tipo: "coleta" | "entrega";
  rotulo: string;
  concluida?: boolean;
}

export interface PinoMotoboy {
  id: string;
  nome: string;
  lat: number;
  lng: number;
  status: StatusMotoboy;
  foto?: string | null;
}

interface Props {
  paradas?: PinoParada[];
  rotaPlanejada?: string | null;
  trilha?: [number, number][];
  motoboys?: PinoMotoboy[];
  aoClicar?: (lat: number, lng: number) => void;
  modoEscolha?: boolean;
  /** Quando muda, o mapa reenquadra tudo. */
  enquadrar?: string;
  /** Clique num endereço da lista: centraliza e aproxima nele (mude "vez" para repetir). */
  foco?: { lat: number; lng: number; vez: number } | null;
  /** Vários caminhos (polylines) de uma vez: as rotas ativas. */
  rotas?: string[];
  /** false: não traça sozinho o caminho entre as paradas. */
  caminhoAuto?: boolean;
  /** Posição do motoboy em corrida: o "a fazer" sai dele e passa pelas paradas que faltam. */
  restanteDe?: { lat: number; lng: number } | null;
  /** Legenda "Feito / A fazer" no canto (padrão: aparece quando há os dois tipos de linha). */
  legenda?: boolean;
  /** Botão de tela cheia (padrão: sim). Desligue nos mapas que já ocupam a página. */
  maximizavel?: boolean;
  /** Título mostrado na tela cheia. */
  titulo?: string;
  /** Painel embaixo na tela cheia (ex.: ferramentas de editar o percurso). */
  painelCheio?: ReactNode;
  /** Avisa quando entra/sai da tela cheia. */
  onCheio?: (cheio: boolean) => void;
  /** Pontos de passagem do percurso (editar percurso): aparecem e dá para arrastar. */
  vias?: { lat: number; lng: number }[];
  onMoverVia?: (i: number, lat: number, lng: number) => void;
  onTirarVia?: (i: number) => void;
  /** Puxar a linha do caminho: solta onde quiser e vira um ponto de passagem. */
  onArrastarLinha?: (lat: number, lng: number) => void;
}

const VAZIO = { type: "FeatureCollection" as const, features: [] };
const CACHE_CAMINHO = new Map<string, string>();

function linha(coords: [number, number][]) {
  return {
    type: "FeatureCollection" as const,
    features: coords.length < 2 ? [] : [{ type: "Feature" as const, properties: {}, geometry: { type: "LineString" as const, coordinates: coords } }],
  };
}

/** Mapa genérico das telas de corrida: paradas numeradas, rota planejada, trilha real e motoboys. */
export function MapaCorridas({ paradas = [], rotaPlanejada, trilha = [], motoboys = [], aoClicar, modoEscolha, enquadrar, foco, rotas = [], caminhoAuto = true, restanteDe, legenda = true, maximizavel = true, titulo, painelCheio, onCheio, vias, onMoverVia, onTirarVia, onArrastarLinha }: Props) {
  const [cheio, setCheioBase] = useState(false);
  const setCheio = (v: boolean) => { setCheioBase(v); onCheio?.(v); };
  // sem rota pronta: traça o caminho pelas ruas entre as paradas, na ordem
  const chaveParadas = paradas.map((p) => `${p.lat.toFixed(5)},${p.lng.toFixed(5)}`).join(";");
  const [caminho, setCaminho] = useState<string | null>(null);
  useEffect(() => {
    if (rotaPlanejada || paradas.length < 2 || !caminhoAuto) { setCaminho(null); return; }
    let vivo = true;
    const guardado = CACHE_CAMINHO.get(chaveParadas);
    if (guardado) { setCaminho(guardado); return; }
    geo.calcularRota(paradas.slice(0, 25).map((p) => ({ lat: p.lat, lng: p.lng }))).then((r) => {
      if (!vivo || !r) return;
      CACHE_CAMINHO.set(chaveParadas, r.polyline); setCaminho(r.polyline);
    }).catch(() => {});
    return () => { vivo = false; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [rotaPlanejada, chaveParadas]);
  const rotaDesenhada = rotaPlanejada || caminho;

  // "a fazer" de verdade: do motoboy até as paradas que faltam (recalcula ao andar ~80 m ou concluir uma parada)
  const pendentes = paradas.filter((p) => !p.concluida);
  const todasFeitas = paradas.length > 0 && pendentes.length === 0;
  const chavePend = pendentes.map((p) => `${p.lat.toFixed(5)},${p.lng.toFixed(5)}`).join(";");
  const [restante, setRestante] = useState<string | null>(null);
  const origemRest = useRef<{ lat: number; lng: number; chave: string } | null>(null);
  useEffect(() => {
    if (!restanteDe || !pendentes.length) { setRestante(null); origemRest.current = null; return; }
    const o = origemRest.current;
    const perto = o && o.chave === chavePend && Math.hypot((o.lat - restanteDe.lat) * 111_000, (o.lng - restanteDe.lng) * 111_000 * Math.cos((o.lat * Math.PI) / 180)) < 80;
    if (perto) return;
    origemRest.current = { ...restanteDe, chave: chavePend };
    let vivo = true;
    geo.calcularRota([restanteDe, ...pendentes.slice(0, 24).map((p) => ({ lat: p.lat, lng: p.lng }))]).then((r) => { if (vivo && r) setRestante(r.polyline); }).catch(() => {});
    return () => { vivo = false; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [restanteDe?.lat, restanteDe?.lng, chavePend]);
  // o que mostrar como "a fazer" e o que fica só de fundo (a rota inteira planejada)
  const aFazer = todasFeitas ? [] : restante ? [restante] : [...(rotaDesenhada ? [rotaDesenhada] : []), ...rotas];
  const fundo = todasFeitas || restante ? [...(rotaDesenhada ? [rotaDesenhada] : []), ...rotas] : [];
  const container = useRef<HTMLDivElement>(null);
  const { mapa, pronto } = useMapa(container);
  const pinos = useRef<Record<string, maplibregl.Marker>>({});
  const cliqueRef = useRef(aoClicar);
  const arrastouEm = useRef(0);
  cliqueRef.current = aoClicar;

  // camadas e clique
  useEffect(() => {
    const m = mapa.current;
    if (!m || !pronto) return;
    pinos.current = {}; // mapa (re)criado: pinos antigos pertenciam ao mapa anterior
    m.addSource("rota", { type: "geojson", data: VAZIO });
    m.addSource("plano", { type: "geojson", data: VAZIO });
    m.addSource("trilha", { type: "geojson", data: VAZIO });
    // rota planejada inteira, só de fundo (quando já há o "a fazer" a partir do motoboy, ou tudo foi feito)
    m.addLayer({
      id: "plano", type: "line", source: "plano",
      layout: { "line-cap": "round", "line-join": "round" },
      paint: { "line-color": corOuro(), "line-width": 3, "line-dasharray": [1.5, 2], "line-opacity": 0.35 },
    });
    // a fazer: tracejado claro com contorno escuro (aparece no mapa claro e no escuro)
    m.addLayer({
      id: "rota-contorno", type: "line", source: "rota",
      layout: { "line-cap": "round", "line-join": "round" },
      paint: { "line-color": "#0a0a0a", "line-width": 7, "line-opacity": 0.55 },
    });
    m.addLayer({
      id: "rota", type: "line", source: "rota",
      layout: { "line-cap": "butt", "line-join": "round" },
      paint: { "line-color": "#f5f5f4", "line-width": 3.5, "line-dasharray": [2, 1.6] },
    });
    m.addLayer({
      id: "trilha-contorno", type: "line", source: "trilha",
      layout: { "line-cap": "round", "line-join": "round" },
      paint: { "line-color": "#0a0a0a", "line-width": 7, "line-opacity": 0.5 },
    });
    m.addLayer({
      id: "trilha", type: "line", source: "trilha",
      layout: { "line-cap": "round", "line-join": "round" },
      paint: { "line-color": corOuro(), "line-width": 4 },
    });
    // logo depois de puxar a linha, o clique do mesmo gesto não conta (não cria ponto em dobro)
    const onClick = (e: maplibregl.MapMouseEvent) => { if (Date.now() - arrastouEm.current > 400) cliqueRef.current?.(e.lngLat.lat, e.lngLat.lng); };
    m.on("click", onClick);
    return () => {
      m.off("click", onClick);
    };
  }, [mapa, pronto]);

  useEffect(() => {
    const el = mapa.current?.getCanvas();
    if (el) el.style.cursor = modoEscolha ? "crosshair" : "";
  }, [mapa, pronto, modoEscolha]);

  useEffect(() => {
    if (!pronto) return;
    const feicoes = (lista: string[]) => ({ type: "FeatureCollection" as const, features: lista.map((r) => decodificarPolyline(r)).filter((c) => c.length >= 2)
      .map((c) => ({ type: "Feature" as const, properties: {}, geometry: { type: "LineString" as const, coordinates: c } })) });
    (mapa.current?.getSource("rota") as maplibregl.GeoJSONSource | undefined)?.setData(feicoes(aFazer));
    (mapa.current?.getSource("plano") as maplibregl.GeoJSONSource | undefined)?.setData(feicoes(fundo));
  }, [mapa, pronto, aFazer.join("|"), fundo.join("|")]); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    if (!pronto) return;
    (mapa.current?.getSource("trilha") as maplibregl.GeoJSONSource | undefined)?.setData(linha(trilha));
  }, [mapa, pronto, trilha]);

  // pinos de paradas e motoboys
  useEffect(() => {
    const m = mapa.current;
    if (!m || !pronto) return;
    const vistos = new Set<string>();

    for (const p of paradas) {
      const id = `p-${p.chave}`;
      vistos.add(id);
      let pino = pinos.current[id];
      if (!pino) {
        const el = document.createElement("div");
        el.className = "pino-parada";
        el.appendChild(document.createElement("span"));
        pino = new maplibregl.Marker({ element: el, anchor: "bottom", offset: [0, -7] }).setLngLat([p.lng, p.lat]).addTo(m);
        pinos.current[id] = pino;
      }
      // classList (nunca className): o MapLibre usa classes próprias no mesmo elemento para posicioná-lo
      const el = pino.getElement();
      el.classList.toggle("coleta", p.tipo === "coleta");
      el.classList.toggle("entrega", p.tipo === "entrega");
      el.classList.toggle("concluida", Boolean(p.concluida));
      el.classList.toggle("largo", p.rotulo.length > 2);
      el.firstElementChild!.textContent = p.rotulo;
      pino.setLngLat([p.lng, p.lat]);
    }

    for (const mb of motoboys) {
      const id = `m-${mb.id}`;
      vistos.add(id);
      let pino = pinos.current[id];
      if (!pino) {
        const el = document.createElement("div");
        el.className = "marcador";
        pino = new maplibregl.Marker({ element: el }).setLngLat([mb.lng, mb.lat]).addTo(m);
        pinos.current[id] = pino;
      }
      const el = pino.getElement();
      el.dataset.status = mb.status;
      el.style.setProperty("--cor", COR_STATUS[mb.status]);
      el.textContent = mb.foto ? "" : mb.nome.trim().charAt(0).toUpperCase();
      el.style.backgroundImage = mb.foto ? `url("${mb.foto}")` : "";
      el.classList.toggle("com-foto", Boolean(mb.foto));
      el.style.zIndex = mb.status === "offline" ? "1" : mb.status === "disponivel" || mb.status === "em_corrida" ? "4" : "2";
      el.title = mb.nome;
      pino.setLngLat([mb.lng, mb.lat]);
    }

    for (const id of Object.keys(pinos.current)) {
      if (!vistos.has(id)) {
        pinos.current[id].remove();
        delete pinos.current[id];
      }
    }
  }, [mapa, pronto, paradas, motoboys]);

  // enquadrar
  useEffect(() => {
    const m = mapa.current;
    if (!m || !pronto || enquadrar === undefined) return;
    const b = new maplibregl.LngLatBounds();
    paradas.forEach((p) => b.extend([p.lng, p.lat]));
    motoboys.forEach((x) => b.extend([x.lng, x.lat]));
    trilha.forEach((c) => b.extend(c));
    if (!b.isEmpty()) m.fitBounds(b, { padding: 90, maxZoom: 15, duration: 600 });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [mapa, pronto, enquadrar]);

  // foco num ponto da lista
  useEffect(() => {
    const m = mapa.current;
    if (!m || !pronto || !foco) return;
    container.current?.scrollIntoView({ behavior: "smooth", block: "nearest" });
    m.flyTo({ center: [foco.lng, foco.lat], zoom: Math.max(m.getZoom(), 15.5), duration: 700 });
  }, [mapa, pronto, foco]);

  // pontos de passagem arrastáveis (editar percurso)
  const viasRef = useRef<maplibregl.Marker[]>([]);
  const moverRef = useRef(onMoverVia); moverRef.current = onMoverVia;
  const tirarRef = useRef(onTirarVia); tirarRef.current = onTirarVia;
  useEffect(() => {
    const m = mapa.current;
    if (!m || !pronto) return;
    viasRef.current.forEach((x) => x.remove());
    viasRef.current = (vias ?? []).map((v, i) => {
      const el = document.createElement("button");
      el.type = "button";
      el.className = "via-pino";
      el.title = "Arraste para mudar · duplo clique tira";
      el.textContent = String(i + 1);
      el.addEventListener("dblclick", (e) => { e.stopPropagation(); tirarRef.current?.(i); });
      const mk = new maplibregl.Marker({ element: el, draggable: Boolean(onMoverVia) }).setLngLat([v.lng, v.lat]).addTo(m);
      mk.on("dragend", () => { const p = mk.getLngLat(); moverRef.current?.(i, p.lat, p.lng); });
      return mk;
    });
    return () => { viasRef.current.forEach((x) => x.remove()); viasRef.current = []; };
  }, [mapa, pronto, JSON.stringify(vias ?? [])]); // eslint-disable-line react-hooks/exhaustive-deps

  // puxar a linha: segura em cima do caminho, arrasta e solta → ponto de passagem ali
  const linhaRef = useRef(onArrastarLinha); linhaRef.current = onArrastarLinha;
  useEffect(() => {
    const m = mapa.current;
    if (!m || !pronto || !onArrastarLinha) return;
    let fantasma: maplibregl.Marker | null = null;
    const comecar = (e: maplibregl.MapLayerMouseEvent | maplibregl.MapLayerTouchEvent) => {
      if ("touches" in e.originalEvent && (e.originalEvent as TouchEvent).touches.length > 1) return;
      e.preventDefault();
      m.dragPan.disable();
      const el = document.createElement("div"); el.className = "via-pino fantasma";
      fantasma = new maplibregl.Marker({ element: el }).setLngLat(e.lngLat).addTo(m);
      const mover = (ev: maplibregl.MapMouseEvent | maplibregl.MapTouchEvent) => fantasma?.setLngLat(ev.lngLat);
      const soltar = (ev: maplibregl.MapMouseEvent | maplibregl.MapTouchEvent) => {
        m.off("mousemove", mover); m.off("touchmove", mover);
        m.dragPan.enable();
        fantasma?.remove(); fantasma = null;
        arrastouEm.current = Date.now();
        linhaRef.current?.(ev.lngLat.lat, ev.lngLat.lng);
      };
      m.on("mousemove", mover); m.on("touchmove", mover);
      m.once("mouseup", soltar); m.once("touchend", soltar);
    };
    const cursor = () => { m.getCanvas().style.cursor = "grab"; };
    const semCursor = () => { m.getCanvas().style.cursor = ""; };
    for (const camada of ["rota", "plano"]) {
      m.on("mousedown", camada, comecar); m.on("touchstart", camada, comecar);
      m.on("mouseenter", camada, cursor); m.on("mouseleave", camada, semCursor);
    }
    return () => {
      for (const camada of ["rota", "plano"]) {
        m.off("mousedown", camada, comecar); m.off("touchstart", camada, comecar);
        m.off("mouseenter", camada, cursor); m.off("mouseleave", camada, semCursor);
      }
      m.dragPan.enable(); fantasma?.remove();
    };
  }, [mapa, pronto, Boolean(onArrastarLinha)]); // eslint-disable-line react-hooks/exhaustive-deps

  // tela cheia: o mesmo mapa (cliques, edição e marcadores continuam), por cima de tudo
  useEffect(() => {
    const m = mapa.current;
    if (m) setTimeout(() => m.resize(), 30);
    if (!cheio) return;
    const esc = (e: KeyboardEvent) => { if (e.key === "Escape") { setCheioBase(false); onCheio?.(false); } };
    window.addEventListener("keydown", esc);
    document.body.classList.add("com-mapa-cheio");
    return () => { window.removeEventListener("keydown", esc); document.body.classList.remove("com-mapa-cheio"); };
  }, [cheio, mapa]); // eslint-disable-line react-hooks/exhaustive-deps
  function enquadrarTudo() {
    const m = mapa.current;
    if (!m) return;
    const pts: [number, number][] = [...paradas.map((p) => [p.lng, p.lat] as [number, number]), ...motoboys.map((x) => [x.lng, x.lat] as [number, number]), ...trilha];
    if (!pts.length) return;
    const b = pts.reduce((bb, p) => bb.extend(p), new maplibregl.LngLatBounds(pts[0], pts[0]));
    m.fitBounds(b, { padding: 70, maxZoom: 16, duration: 600 });
  }

  const comFeito = trilha.length >= 2, comAFazer = aFazer.length > 0;
  return (
    <div ref={container} className={`mapa${cheio ? " mapa-cheia" : ""}`}>
      {maximizavel && (
        <div className="mapa-cheia-topo">
          <button type="button" className="mapa-botao" aria-label={cheio ? "Sair da tela cheia" : "Tela cheia"} title={cheio ? "Sair da tela cheia (Esc)" : "Tela cheia"} onClick={() => setCheio(!cheio)}>
            {cheio ? <X size={18} aria-hidden /> : <Maximize2 size={16} aria-hidden />}
          </button>
          {cheio && titulo && <span className="mapa-cheia-titulo">{titulo}</span>}
        </div>
      )}
      {cheio && (
        <div className="mapa-controles">
          <button type="button" className="mapa-botao" aria-label="Aproximar" onClick={() => mapa.current?.zoomIn()}><Plus size={18} aria-hidden /></button>
          <button type="button" className="mapa-botao" aria-label="Afastar" onClick={() => mapa.current?.zoomOut()}><Minus size={18} aria-hidden /></button>
          <button type="button" className="mapa-botao" aria-label="Enquadrar tudo" title="Enquadrar tudo" onClick={enquadrarTudo}><Crosshair size={18} aria-hidden /></button>
        </div>
      )}
      {cheio && painelCheio && <div className="mapa-cheia-painel vidro">{painelCheio}</div>}
      {legenda && comFeito && (
        <div className="mapa-legenda" aria-label="Legenda do mapa">
          <span><i className="feito" /> Feito</span>
          {comAFazer && <span><i className="afazer" /> A fazer</span>}
        </div>
      )}
    </div>
  );
}

"use client";

import { useEffect, useRef, useState, type ReactNode } from "react";
import { CaixaMapa } from "@/features/ui/CaixaMapa";
import type { GeoJSONSource } from "maplibre-gl";
import { Check, Map as IconeMapa, Minus, Pencil, Plus, SlidersHorizontal, X } from "lucide-react";
import { useModoNumero } from "@/features/ui/CampoNumero";
import { useMapa } from "@/lib/mapa/useMapa";
import { corOuro } from "@/lib/mapa/cores";

/** Centro dos exemplos: o último usado (o gestor pode arrastar) ou Florianópolis. */
const CHAVE_CENTRO = "pwex-raio-centro";
function centroInicial(): [number, number] {
  try { const v = JSON.parse(localStorage.getItem(CHAVE_CENTRO) ?? "null"); if (Array.isArray(v) && v.length === 2) return v as [number, number]; } catch { /* sem storage */ }
  return [-48.5482, -27.5954];
}

/** Polígono de um círculo de [raioM] metros em volta de [c] (lng, lat). */
export function circulo(c: [number, number], raioM: number, n = 72): [number, number][] {
  const [lng, lat] = c;
  const r = raioM / 6371000, la = (lat * Math.PI) / 180, lo = (lng * Math.PI) / 180;
  return Array.from({ length: n + 1 }, (_, i) => {
    const a = (i / n) * 2 * Math.PI;
    const la2 = Math.asin(Math.sin(la) * Math.cos(r) + Math.cos(la) * Math.sin(r) * Math.cos(a));
    const lo2 = lo + Math.atan2(Math.sin(a) * Math.sin(r) * Math.cos(la), Math.cos(r) - Math.sin(la) * Math.sin(la2));
    return [(lo2 * 180) / Math.PI, (la2 * 180) / Math.PI];
  });
}
const desloca = ([lng, lat]: [number, number], metros: number): [number, number] => [lng + metros / (111_320 * Math.cos((lat * Math.PI) / 180)), lat];

/**
 * Raio com barra e bolinha (como o "Raio de disponibilidade") e o círculo de verdade no mapa.
 * exemplo: "coleta" = um ponto com o raio; "dupla" = duas entregas, mostrando se os raios se encostam; "endereco" = raio em volta de um endereço.
 */
export function CampoRaio({ valor, unidade, min, max, passo, onMudar, desabilitado, exemplo = "coleta", rotuloZero }: {
  valor: number; unidade: "m" | "km"; min: number; max: number; passo: number; onMudar: (v: number) => void;
  desabilitado?: boolean; exemplo?: "coleta" | "dupla" | "endereco"; rotuloZero?: string;
}) {
  // barra e número mudam o rascunho; salva só no ✓ (ou Enter)
  const [v, setV] = useState(valor);
  const [txt, setTxt] = useState<string | null>(null);
  const [mapaAberto, setMapaAberto] = useState(false);
  useEffect(() => { setV(valor); setTxt(null); }, [valor]);
  const limitar = (n: number) => Math.min(max, Math.max(min, n));
  function mudar(n: number) { setV(n); setTxt(null); }
  function digitar(t: string) {
    setTxt(t);
    const n = Number(t.replace(",", "."));
    if (t.trim() !== "" && !Number.isNaN(n)) setV(limitar(n));
  }
  const mudou = v !== valor;
  function confirmar() { onMudar(limitar(v)); setTxt(null); }
  function desfazer() { setV(valor); setTxt(null); }
  const pct = max > min ? ((v - min) / (max - min)) * 100 : 0;
  // barra ou número: a pessoa escolhe no ícone (vale no site todo)
  const [barra, setBarra] = useModoNumero();
  const controles = (
    <div className="campo-raio-linha">
      {barra && <input type="range" className="barra-raio" min={min} max={max} step={passo} value={v} disabled={desabilitado}
        style={{ ["--pct" as string]: `${pct}%` }} onChange={(e) => mudar(Number(e.target.value))} aria-label="Tamanho do raio" />}
      {!barra && <button type="button" className="icone" disabled={desabilitado || v <= min} onClick={() => mudar(limitar(Math.round((v - passo) * 1000) / 1000))} aria-label="Diminuir"><Minus size={15} /></button>}
      <span className="passo-campo campo-raio-num">
        <input inputMode="decimal" disabled={desabilitado} value={txt ?? String(v).replace(".", ",")} onChange={(e) => digitar(e.target.value)} aria-label="Raio (número)"
          onKeyDown={(e) => { if (e.key === "Enter" && mudou) confirmar(); if (e.key === "Escape") desfazer(); }} />
        <span className="unidade">{unidade}</span>
      </span>
      {!barra && <button type="button" className="icone" disabled={desabilitado || v >= max} onClick={() => mudar(limitar(Math.round((v + passo) * 1000) / 1000))} aria-label="Aumentar"><Plus size={15} /></button>}
      <button type="button" className="icone" onClick={() => setBarra(!barra)} title={barra ? "Digitar o número" : "Usar a barra"} aria-label={barra ? "Digitar o número" : "Usar a barra"}>
        {barra ? <Pencil size={14} aria-hidden /> : <SlidersHorizontal size={14} aria-hidden />}
      </button>
      {mudou ? <>
        <button type="button" className="passo-ok" onClick={confirmar} aria-label="Salvar o raio" title="Salvar (Enter)"><Check size={16} /></button>
        <button type="button" className="passo-desfazer" onClick={desfazer} aria-label="Desfazer" title="Desfazer (Esc)"><X size={15} /></button>
      </> : v === 0 && <span className="dica">{rotuloZero ?? "sem limite"}</span>}
      <button type="button" className={`icone${mapaAberto ? " ativo" : ""}`} title={mapaAberto ? "Esconder o mapa" : "Ver no mapa"} onClick={() => setMapaAberto((x) => !x)}>
        <IconeMapa size={15} aria-hidden />
      </button>
    </div>
  );
  return (
    <div className="campo-raio">
      {controles}
      {mapaAberto && <MapaRaio metros={unidade === "km" ? v * 1000 : v} exemplo={exemplo} painel={controles} />}
    </div>
  );
}

function MapaRaio({ metros, exemplo, painel }: { metros: number; exemplo: "coleta" | "dupla" | "endereco"; painel?: ReactNode }) {
  const caixa = useRef<HTMLDivElement>(null);
  const { mapa, pronto } = useMapa(caixa);
  const [centro, setCentro] = useState<[number, number]>(centroInicial);
  // duas entregas a 1,6× o raio uma da outra (dá para ver se encostam quando o raio muda)
  const [dist] = useState(() => Math.max(metros * 2.4, 400));

  useEffect(() => {
    const m = mapa.current;
    if (!m || !pronto) return;
    if (!m.getSource("raio")) {
      m.addSource("raio", { type: "geojson", data: { type: "FeatureCollection", features: [] } });
      m.addLayer({ id: "raio-fundo", type: "fill", source: "raio", filter: ["==", ["geometry-type"], "Polygon"], paint: { "fill-color": ["coalesce", ["get", "cor"], corOuro()], "fill-opacity": 0.18 } });
      m.addLayer({ id: "raio-borda", type: "line", source: "raio", filter: ["==", ["geometry-type"], "Polygon"], paint: { "line-color": ["coalesce", ["get", "cor"], corOuro()], "line-width": 2.5, "line-dasharray": [2, 1.4] } });
      m.addLayer({ id: "raio-ponto", type: "circle", source: "raio", filter: ["==", ["geometry-type"], "Point"],
        paint: { "circle-radius": 7, "circle-color": ["coalesce", ["get", "cor"], corOuro()], "circle-stroke-color": "#0a0a0a", "circle-stroke-width": 2 } });
      m.on("click", (e) => { const c: [number, number] = [e.lngLat.lng, e.lngLat.lat]; setCentro(c); try { localStorage.setItem(CHAVE_CENTRO, JSON.stringify(c)); } catch { /* sem storage */ } });
    }
  }, [mapa, pronto]);

  useEffect(() => {
    const m = mapa.current;
    if (!m || !pronto || !m.getSource("raio")) return;
    const pts: { c: [number, number]; cor?: string }[] = exemplo === "dupla" ? [{ c: desloca(centro, -dist / 2) }, { c: desloca(centro, dist / 2), cor: "#38bdf8" }] : [{ c: centro }];
    (m.getSource("raio") as GeoJSONSource).setData({
      type: "FeatureCollection",
      features: pts.flatMap(({ c, cor }) => [
        { type: "Feature" as const, properties: { cor }, geometry: { type: "Polygon" as const, coordinates: [circulo(c, Math.max(metros, 1))] } },
        { type: "Feature" as const, properties: { cor }, geometry: { type: "Point" as const, coordinates: c } },
      ]),
    });
    const alcance = (exemplo === "dupla" ? dist / 2 : 0) + Math.max(metros, 50);
    const sw = desloca([centro[0], centro[1] - alcance / 111_320], -alcance), ne = desloca([centro[0], centro[1] + alcance / 111_320], alcance);
    m.fitBounds([sw, ne], { padding: 24, duration: 300 });
  }, [mapa, pronto, metros, centro, exemplo, dist]);

  const encostam = exemplo === "dupla" ? dist <= 2 * metros : null;
  return (
    <div className="campo-raio-mapa">
      <CaixaMapa refMapa={caixa} mapa={mapa} className="campo-raio-mapa-caixa" titulo="Raio" painelCheio={painel} />
      <p className="dica" style={{ margin: 0 }}>
        {exemplo === "dupla" ? <>Duas entregas a {(dist / 1000).toLocaleString("pt-BR", { maximumFractionDigits: 1 })} km: {encostam ? <strong style={{ color: "var(--verde)" }}>os raios se encostam (mesma zona)</strong> : <strong>os raios não se encostam</strong>}. </> : null}
        Toque no mapa para mudar o centro do exemplo.
      </p>
    </div>
  );
}

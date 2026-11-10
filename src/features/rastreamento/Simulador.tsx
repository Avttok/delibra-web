"use client";

import { useEffect, useRef, useState, type MutableRefObject } from "react";
import { MousePointerClick, Navigation, Pause, Play, Route } from "lucide-react";
import type { Map as Mapa, MapMouseEvent } from "maplibre-gl";
import { supabase } from "@/lib/supabase/client";
import { decodificarPolyline } from "@/lib/geo/polyline";
import { toast } from "@/features/ui/toast";

type P = { lat: number; lng: number };
const R = 6371000, rad = Math.PI / 180;
function metros(a: P, b: P) {
  const dLat = (b.lat - a.lat) * rad, dLng = (b.lng - a.lng) * rad;
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(a.lat * rad) * Math.cos(b.lat * rad) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(h));
}
function rumo(a: P, b: P) {
  const y = Math.sin((b.lng - a.lng) * rad) * Math.cos(b.lat * rad);
  const x = Math.cos(a.lat * rad) * Math.sin(b.lat * rad) - Math.sin(a.lat * rad) * Math.cos(b.lat * rad) * Math.cos((b.lng - a.lng) * rad);
  return ((Math.atan2(y, x) / rad) + 360) % 360;
}
/** Anda `d` metros pelo caminho a partir do índice/fração atual. */
function andar(caminho: P[], i: number, f: number, d: number): { i: number; f: number; p: P; fim: boolean } {
  let resto = d;
  while (i < caminho.length - 1) {
    const seg = metros(caminho[i], caminho[i + 1]);
    const falta = seg * (1 - f);
    if (resto < falta && seg > 0) {
      f += resto / seg;
      const a = caminho[i], b = caminho[i + 1];
      return { i, f, p: { lat: a.lat + (b.lat - a.lat) * f, lng: a.lng + (b.lng - a.lng) * f }, fim: false };
    }
    resto -= falta; i++; f = 0;
  }
  return { i: caminho.length - 1, f: 0, p: caminho[caminho.length - 1], fim: true };
}

/**
 * Simulador de GPS (só motoboys em modo teste): mover tocando no mapa ou andar pela rota da corrida,
 * gravando pings de verdade no servidor, para ver o rastreamento sem precisar sair de moto.
 */
export function SimuladorGps({ motoboyId, posicao, mapa, velocidadePadrao = 35 }: {
  motoboyId: string; posicao: P | null; mapa: MutableRefObject<Mapa | null>; velocidadePadrao?: number;
}) {
  const [modo, setModo] = useState<"parado" | "tocar" | "andando">("parado");
  const [kmh, setKmh] = useState(velocidadePadrao);
  const [info, setInfo] = useState<string | null>(null);
  const estado = useRef<{ caminho: P[]; i: number; f: number } | null>(null);
  const atual = useRef<P | null>(posicao);
  atual.current = atual.current ?? posicao;

  async function enviar(p: P, dir?: number) {
    const { error } = await supabase().rpc("simular_posicao", { p_motoboy: motoboyId, p_lat: p.lat, p_lng: p.lng, p_velocidade_ms: kmh / 3.6, p_direcao: dir ?? null });
    if (error) {
      toast(error.message.includes("so_em_modo_teste") ? "Só dá para simular motoboy em modo teste." : error.message.includes("simulador_desligado") ? "O simulador está desligado nas configurações." : error.message, "erro");
      setModo("parado");
      return false;
    }
    atual.current = p;
    return true;
  }

  // tocar no mapa move o motoboy
  useEffect(() => {
    const m = mapa.current;
    if (!m || modo !== "tocar") return;
    const canvas = m.getCanvas();
    canvas.style.cursor = "crosshair";
    const clique = (e: MapMouseEvent) => {
      const de = atual.current, para = { lat: e.lngLat.lat, lng: e.lngLat.lng };
      void enviar(para, de ? rumo(de, para) : undefined);
    };
    m.on("click", clique);
    return () => { m.off("click", clique); canvas.style.cursor = ""; };
  }, [mapa, modo]); // eslint-disable-line react-hooks/exhaustive-deps

  // andar pela rota: um ping a cada 3 s
  useEffect(() => {
    if (modo !== "andando") return;
    const t = setInterval(async () => {
      const s = estado.current;
      if (!s) return;
      const prox = andar(s.caminho, s.i, s.f, (kmh / 3.6) * 3);
      const de = atual.current;
      estado.current = { ...s, i: prox.i, f: prox.f };
      const ok = await enviar(prox.p, de ? rumo(de, prox.p) : undefined);
      if (!ok) return;
      if (prox.fim) { setModo("parado"); setInfo("Chegou ao fim da rota."); }
    }, 3000);
    return () => clearInterval(t);
  }, [modo, kmh]); // eslint-disable-line react-hooks/exhaustive-deps

  async function andarPelaRota() {
    const { data } = await supabase().from("corridas").select("id,rota_planejada,paradas(lat,lng,ordem,status)")
      .eq("motoboy_id", motoboyId).in("status", ["aceita", "em_andamento"]).order("aceita_em", { ascending: false }).limit(1);
    const c = (data ?? [])[0] as { rota_planejada: string | null; paradas: { lat: number; lng: number; ordem: number; status: string }[] } | undefined;
    if (!c) return toast("Esse motoboy não está em corrida. Use “Tocar no mapa” ou aceite uma corrida de teste.", "aviso");
    const pendentes = [...c.paradas].sort((a, b) => a.ordem - b.ordem).filter((p) => p.status !== "concluida");
    let caminho: P[] = c.rota_planejada ? decodificarPolyline(c.rota_planejada).map(([lng, lat]) => ({ lat, lng })) : pendentes.map((p) => ({ lat: p.lat, lng: p.lng }));
    const ini = atual.current ?? posicao;
    if (ini) {
      // começa do ponto do caminho mais perto de onde o motoboy está
      let melhor = 0, dist = Infinity;
      caminho.forEach((p, k) => { const d = metros(ini, p); if (d < dist) { dist = d; melhor = k; } });
      caminho = [ini, ...caminho.slice(melhor)];
    }
    if (caminho.length < 2) return toast("A rota não tem caminho para seguir.", "aviso");
    estado.current = { caminho, i: 0, f: 0 };
    setInfo(`Andando ${Math.round(caminho.slice(1).reduce((s, p, k) => s + metros(caminho[k], p), 0) / 100) / 10} km pela rota.`);
    setModo("andando");
  }

  return (
    <div className="simulador">
      <span className="rotulo"><Navigation size={12} aria-hidden /> Simulador de GPS (teste)</span>
      <div className="linha-botoes">
        <button className={`botao-texto ${modo === "tocar" ? "ativo" : ""}`} onClick={() => setModo(modo === "tocar" ? "parado" : "tocar")}>
          <MousePointerClick size={14} aria-hidden /> {modo === "tocar" ? "Tocando no mapa…" : "Tocar no mapa"}</button>
        {modo === "andando"
          ? <button className="botao-texto ativo" onClick={() => setModo("parado")}><Pause size={14} aria-hidden /> Pausar</button>
          : <button className="botao-texto" onClick={andarPelaRota}><Route size={14} aria-hidden /> Andar pela rota</button>}
        {modo === "parado" && estado.current && <button className="botao-texto" onClick={() => setModo("andando")}><Play size={14} aria-hidden /> Continuar</button>}
      </div>
      <label className="campo-linha"><span>Velocidade</span>
        <input type="range" min={5} max={90} step={5} value={kmh} onChange={(e) => setKmh(Number(e.target.value))} /><strong>{kmh} km/h</strong></label>
      {info && <span className="dica">{info}</span>}
      <span className="dica">Os pings são gravados como de teste e o mapa, a corrida e o cliente veem o movimento como se fosse o celular.</span>
    </div>
  );
}

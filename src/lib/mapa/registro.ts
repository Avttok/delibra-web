"use client";

import type { Map as Mapa, GeoJSONFeature } from "maplibre-gl";

/** Mapas abertos na página (para consultas que não dependem de serviço externo). */
const abertos = new Set<Mapa>();
export function registrarMapa(m: Mapa) { abertos.add(m); return () => { abertos.delete(m); }; }

export interface PoiMapa { nome: string; lat: number; lng: number; classe: string }
export interface ViaMapa { nome: string; pontos: { lat: number; lng: number }[] }

function metros(a: { lat: number; lng: number }, b: { lat: number; lng: number }) {
  const r = 6371000, rad = Math.PI / 180;
  const dLat = (b.lat - a.lat) * rad, dLng = (b.lng - a.lng) * rad;
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(a.lat * rad) * Math.cos(b.lat * rad) * Math.sin(dLng / 2) ** 2;
  return 2 * r * Math.asin(Math.sqrt(h));
}

function linhas(f: GeoJSONFeature): { lat: number; lng: number }[][] {
  const g = f.geometry;
  if (g.type === "LineString") return [g.coordinates.map(([lng, lat]) => ({ lat, lng }))];
  if (g.type === "MultiLineString") return g.coordinates.map((l) => l.map(([lng, lat]) => ({ lat, lng })));
  return [];
}

/**
 * Estabelecimentos e ruas perto do ponto, lidos dos próprios blocos do mapa já carregados.
 * Serve de reserva quando o Overpass está fora do ar ou lento (o que é comum).
 */
export function poisDoMapa(lat: number, lng: number, raioM: number): { pois: PoiMapa[]; vias: ViaMapa[] } {
  const pois = new Map<string, PoiMapa>();
  const vias: ViaMapa[] = [];
  for (const m of abertos) {
    if (!m.getSource("openmaptiles")) continue;
    try {
      for (const f of m.querySourceFeatures("openmaptiles", { sourceLayer: "poi" })) {
        if (f.geometry.type !== "Point") continue;
        const nome = (f.properties["name:pt"] ?? f.properties.name) as string | undefined;
        if (!nome) continue;
        const [plng, plat] = f.geometry.coordinates;
        if (metros({ lat, lng }, { lat: plat, lng: plng }) > raioM) continue;
        const chave = nome.toLowerCase();
        if (!pois.has(chave)) pois.set(chave, { nome, lat: plat, lng: plng, classe: String(f.properties.subclass ?? f.properties.class ?? "") });
      }
      for (const fonte of ["transportation_name", "transportation"]) {
        for (const f of m.querySourceFeatures("openmaptiles", { sourceLayer: fonte })) {
          const nome = f.properties.name as string | undefined;
          if (!nome) continue;
          for (const l of linhas(f)) if (l.some((p) => metros({ lat, lng }, p) < 250)) vias.push({ nome, pontos: l });
        }
        if (vias.length) break;
      }
    } catch { /* mapa sem estilo carregado */ }
  }
  return { pois: [...pois.values()], vias };
}

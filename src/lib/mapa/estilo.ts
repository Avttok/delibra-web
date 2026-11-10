"use client";

import type { Map as Mapa } from "maplibre-gl";
import { resolverCor } from "./cores";
import { estabelecimentosVisiveis, modoRuas, type ModoRuas } from "./estabelecimentos";


/** Categoria do estabelecimento (classe do OpenMapTiles) → ícone. O resto usa o padrão. */
export const ICONE_POI: Record<string, string> = {
  grocery: "mercado", supermarket: "mercado", convenience: "mercado", alcohol_shop: "mercado",
  hospital: "hospital", doctor: "hospital", doctors: "hospital", dentist: "hospital", clinic: "hospital",
  pharmacy: "farmacia", chemist: "farmacia",
  park: "praca", garden: "praca", playground: "praca", pitch: "praca",
  school: "escola", college: "escola", kindergarten: "escola", university: "escola",
  restaurant: "restaurante", fast_food: "restaurante", food_court: "restaurante", bar: "restaurante", pub: "restaurante",
  cafe: "cafe", bakery: "cafe", ice_cream: "cafe",
  fuel: "posto", bank: "banco", atm: "banco", place_of_worship: "igreja", lodging: "hotel",
  police: "policia", post: "correio", car: "carro", car_repair: "carro",
};
const ICONES = [...new Set([...Object.values(ICONE_POI), "padrao"])];
export const CAMADAS_POI = ["pwex-poi"];
/** Classes/subclasses que não entram no mapa: paradas de ônibus/trem trazem o nome da rua e poluíam as cidades grandes. */
export const POI_FORA = ["bus", "bus_stop", "bus_station", "railway", "platform", "stop_position", "tram_stop", "subway", "subway_entrance",
  "halt", "station", "aerialway", "ferry_terminal", "taxi", "bicycle_rental", "parking", "parking_entrance", "bicycle_parking", "motorcycle_parking"];

/** Cores dos rótulos: cidade (cor da marca), bairro (azul) e rua (neutra), no claro e no noturno. */
function cores(escuro: boolean) {
  return {
    cidade: resolverCor(escuro ? "var(--ouro-claro)" : "var(--ouro-escuro)"),
    bairro: escuro ? "#7dd3fc" : "#0369a1",
    vila: escuro ? "#c4b5fd" : "#6d28d9",
    rua: escuro ? "#e7e5e4" : "#44403c",
    halo: escuro ? "#0b0b0d" : "#ffffff",
  };
}

async function carregarIcones(m: Mapa) {
  await Promise.all(ICONES.map((n) => `poi_${n}`).map(async (id) => {
    if (m.hasImage(id)) return;
    try {
      const img = await m.loadImage(`/mapa/${id}.png`);
      if (!m.hasImage(id)) m.addImage(id, img.data, { sdf: true, pixelRatio: 2 });
    } catch { /* sem ícone, fica só o texto */ }
  }));
}

/** Estabelecimentos com ícone por tipo (na cor do tema) e o nome embaixo. */
function adicionarPoi(m: Mapa, escuro: boolean) {
  if (!m.getSource("openmaptiles") || m.getLayer("pwex-poi")) return;
  const match: unknown[] = ["match", ["coalesce", ["get", "subclass"], ["get", "class"]]];
  for (const [classe, icone] of Object.entries(ICONE_POI)) match.push(classe, `poi_${icone}`);
  match.push(["match", ["get", "class"], ...Object.entries(ICONE_POI).flatMap(([k, v]) => [k, `poi_${v}`]), "poi_padrao"]);
  m.addLayer({
    id: "pwex-poi", type: "symbol", source: "openmaptiles", "source-layer": "poi", minzoom: 15,
    filter: ["all", ["has", "name"], ["!", ["in", ["get", "class"], ["literal", POI_FORA]]],
      ["!", ["in", ["coalesce", ["get", "subclass"], ""], ["literal", POI_FORA]]]] as never,
    layout: {
      visibility: estabelecimentosVisiveis() ? "visible" : "none",
      "icon-image": match as never, "icon-size": 0.9, "icon-allow-overlap": false,
      "text-field": ["coalesce", ["get", "name:pt"], ["get", "name"]], "text-font": ["Noto Sans Regular"], "text-size": 11.5,
      "text-anchor": "top", "text-offset": [0, 1.1], "text-max-width": 9, "text-optional": true,
    },
    paint: {
      "icon-color": resolverCor(escuro ? "var(--ouro-claro)" : "var(--ouro-escuro)"),
      "icon-halo-color": escuro ? "#0b0b0d" : "#ffffff", "icon-halo-width": 2,
      "text-color": resolverCor(escuro ? "var(--ouro-claro)" : "var(--ouro-escuro)"),
      "text-halo-color": escuro ? "#0b0b0d" : "#ffffff", "text-halo-width": 1.4,
    },
  });
}

/** Rótulos de lugares coloridos por tipo e nomes de rua no modo escolhido. */
function aplicarRotulos(m: Mapa, escuro: boolean) {
  const c = cores(escuro);
  for (const camada of m.getStyle().layers ?? []) {
    if (camada.type !== "symbol" || camada.id.startsWith("pwex")) continue;
    const fonte = (camada as { "source-layer"?: string })["source-layer"];
    if (fonte === "place") {
      m.setPaintProperty(camada.id, "text-color", ["match", ["get", "class"],
        ["city", "town", "state", "country"], c.cidade,
        ["suburb", "neighbourhood", "quarter"], c.bairro,
        ["village", "hamlet", "isolated_dwelling"], c.vila, c.rua]);
      m.setPaintProperty(camada.id, "text-halo-color", c.halo);
    }
    if (fonte === "transportation_name") {
      m.setPaintProperty(camada.id, "text-color", c.rua);
      m.setPaintProperty(camada.id, "text-halo-color", c.halo);
    }
  }
  aplicarModoRuas(m, modoRuas());
}

/** Camadas de nome de rua do estilo base (só elas: lugares e estabelecimentos ficam de fora). */
function camadasDeRua(m: Mapa): string[] {
  return (m.getStyle().layers ?? [])
    .filter((c) => c.type === "symbol" && (c as { "source-layer"?: string })["source-layer"] === "transportation_name")
    .map((c) => c.id);
}

/** Nomes de rua escritos na rua (como o estilo desenha) ou ocultos. Só mexe na visibilidade. */
export function aplicarModoRuas(m: Mapa, modo: ModoRuas) {
  const v = modo === "oculta" ? "none" : "visible";
  for (const id of camadasDeRua(m)) {
    try { m.setLayoutProperty(id, "visibility", v); } catch { /* camada sumiu com troca de estilo */ }
  }
}

/** Tudo do estilo Delibra (chamar no "load" do mapa). */
export async function aplicarEstiloPw(m: Mapa, escuro: boolean) {
  await carregarIcones(m);
  adicionarPoi(m, escuro);
  try { aplicarRotulos(m, escuro); } catch { /* estilo diferente: segue sem mexer */ }
}

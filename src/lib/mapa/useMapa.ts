"use client";

import { useEffect, useRef, useState, type RefObject } from "react";
import { maplibregl } from "./maplibre";
import { useTema } from "@/features/tema/tema";
import { useModoTeste } from "@/features/teste/modoTeste";

import { useConta } from "@/features/conta/conta";
import { aoMudarEstabelecimentos, aoMudarRuas, estabelecimentosVisiveis, modoRuas } from "./estabelecimentos";
import { CAMADAS_POI, aplicarEstiloPw, aplicarModoRuas } from "./estilo";
import { registrarMapa } from "./registro";

export const ESTILOS_MAPA = {
  claro: "https://tiles.openfreemap.org/styles/positron",
  escuro: "https://tiles.openfreemap.org/styles/dark",
} as const;

/**
 * Cria um mapa MapLibre no elemento e avisa quando está pronto para receber camadas.
 * Ao trocar o tema o mapa é recriado; quem usa deve recriar camadas e pinos quando `pronto` voltar a true.
 */
export function useMapa(container: RefObject<HTMLDivElement | null>) {
  const mapa = useRef<maplibregl.Map | null>(null);
  const [pronto, setPronto] = useState(false);
  const { tema } = useTema();
  const { teste } = useModoTeste(); // violeta no modo teste: o mapa é refeito com a cor nova
  const { corTema } = useConta(); // vermelho do Dev, idem

  useEffect(() => {
    if (!container.current) return;
    const m = new maplibregl.Map({
      container: container.current,
      style: ESTILOS_MAPA[tema],
      center: [-49.5, -27.2],
      zoom: 7,
      attributionControl: { compact: true },
    });
    m.addControl(new maplibregl.NavigationControl({ showCompass: false }), "bottom-right");
    m.on("load", () => {
      void aplicarEstiloPw(m, tema === "escuro");
      // créditos do mapa começam recolhidos (continuam no botão "i")
      container.current?.querySelector(".maplibregl-compact-show")?.classList.remove("maplibregl-compact-show");
      setPronto(true);
    });
    mapa.current = m;
    const desregistrar = registrarMapa(m);
    // botão "Mostrar/Ocultar estabelecimentos" (fica junto do "Mostrar lista")
    const desligar = aoMudarEstabelecimentos(() => {
      const v = estabelecimentosVisiveis() ? "visible" : "none";
      for (const id of CAMADAS_POI) if (m.getLayer(id)) m.setLayoutProperty(id, "visibility", v);
    });
    const desligarRuas = aoMudarRuas(() => { try { aplicarModoRuas(m, modoRuas()); } catch {} });
    return () => {
      desregistrar();
      desligarRuas();
      desligar();
      m.remove();
      mapa.current = null;
      setPronto(false);
    };
  }, [container, tema, teste, corTema]);

  return { mapa, pronto };
}

const poiVisivel = estabelecimentosVisiveis;
void poiVisivel;

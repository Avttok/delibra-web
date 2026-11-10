import * as maplibregl from "maplibre-gl";

// O MapLibre v6 desenha o mapa num "worker" carregado de um arquivo separado.
// O arquivo é copiado para /public por scripts/copiar-worker-mapa.mjs.
if (typeof window !== "undefined" && !maplibregl.getWorkerUrl()) {
  maplibregl.setWorkerUrl("/maplibre-gl-worker.mjs");
}

export { maplibregl };

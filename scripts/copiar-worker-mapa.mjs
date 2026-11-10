// Copia o "worker" do MapLibre para /public, para o navegador conseguir carregá-lo.
// Roda sozinho após o npm install e antes do build.
import { copyFileSync, mkdirSync } from "node:fs";

mkdirSync("public", { recursive: true });
copyFileSync("node_modules/maplibre-gl/dist/maplibre-gl-worker.mjs", "public/maplibre-gl-worker.mjs");
console.log("worker do mapa copiado para public/");

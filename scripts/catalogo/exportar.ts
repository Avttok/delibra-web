// Exporta o catálogo de ajustes do site (definicoes.ts) em JSON. Usado por gerar-app.py.
import { AREAS, GRUPOS, PARAMETROS } from "../../src/features/configuracoes/definicoes";
console.log(JSON.stringify({ AREAS, GRUPOS, PARAMETROS }));

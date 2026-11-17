// Regra matriz: tudo que o código usa precisa existir no painel do Dev.
// · cada módulo usado no site (modulo("x")) existe na tabela public.modulos (migrações)
// · cada ajuste lido no site (useFlag("x")) e cada permissão especial do banco existe no catálogo de Ajustes (definicoes.ts)
// · cada chave do tipo Modulo (conta.tsx) existe nas migrações
// Uso: node scripts/checar-controle-dev.mjs  (sai com erro e lista o que falta)
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";

const raiz = new URL("..", import.meta.url).pathname;
const ler = (p) => readFileSync(join(raiz, p), "utf8");
function arquivos(dir, ext, saida = []) {
  for (const n of readdirSync(join(raiz, dir))) {
    const p = join(dir, n);
    if (statSync(join(raiz, p)).isDirectory()) arquivos(p, ext, saida);
    else if (ext.some((e) => n.endsWith(e))) saida.push(p);
  }
  return saida;
}

const migracoes = arquivos("supabase/migrations", [".sql"]).sort().map(ler).join("\n");
const modulos = new Set();
for (const bloco of migracoes.matchAll(/insert into public\.modulos[^;]*?values([\s\S]*?)on conflict/g))
  for (const m of bloco[1].matchAll(/\(\s*'([a-z_]+)'\s*,/g)) modulos.add(m[1]);

const defs = ler("src/features/configuracoes/definicoes.ts");
const parametros = new Set([...defs.matchAll(/chave: "([a-z0-9_]+)"/g)].map((m) => m[1]));

const site = arquivos("src", [".ts", ".tsx"]).map((p) => [p, ler(p)]);
const faltas = [];
for (const [p, s] of site) {
  for (const m of s.matchAll(/\bmodulo\("([a-z_]+)"\)/g)) if (!modulos.has(m[1])) faltas.push(`${p}: módulo "${m[1]}" não existe na tabela modulos`);
  for (const m of s.matchAll(/useFlag\("([a-z0-9_]+)"/g)) if (!parametros.has(m[1])) faltas.push(`${p}: ajuste "${m[1]}" não está em definicoes.ts`);
}
const tipo = ler("src/features/conta/conta.tsx").match(/export type Modulo =([\s\S]*?);/)?.[1] ?? "";
for (const m of tipo.matchAll(/"([a-z_]+)"/g)) if (!modulos.has(m[1])) faltas.push(`conta.tsx: módulo "${m[1]}" sem linha em public.modulos`);
for (const m of migracoes.matchAll(/privado\.especial\('([a-z0-9_]+)'/g)) if (!parametros.has(m[1])) faltas.push(`migrações: permissão especial "${m[1]}" não está em definicoes.ts`);

if (faltas.length) {
  console.error([...new Set(faltas)].map((f) => `::error::${f}`).join("\n"));
  console.error(`\n${new Set(faltas).size} item(ns) sem controle no painel do Dev.`);
  process.exit(1);
}
console.log(`Controle do Dev ok: ${modulos.size} módulos, ${parametros.size} ajustes conferidos.`);

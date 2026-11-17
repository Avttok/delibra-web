// Teste das telas: abre as páginas públicas do site já compilado (next start) num navegador de verdade
// e confere se cada uma carrega, mostra o texto esperado e não dá erro de JavaScript.
// Uso: npx next start -p 3100 & node scripts/testes/telas.mjs http://localhost:3100
import { chromium } from "playwright";

const base = process.argv[2] ?? "http://localhost:3100";
const PAGINAS = [
  { url: "/", texto: /entrega|motoboy|pedido/i },
  { url: "/entrar", texto: /entrar|e-mail|senha/i },
  { url: "/termos", texto: /termos/i },
  { url: "/privacidade", texto: /privacidade|dados/i },
  { url: "/desenvolvedores", texto: /api|chave/i },
  { url: "/suporte", texto: /suporte|ajuda|contato/i },
  { url: "/app", texto: /app|android|baixar/i },
  { url: "/r/token-que-nao-existe", texto: /./ },
  // área logada sem sessão: tem que mandar para o login, não quebrar
  { url: "/gestor", texto: /./ },
  { url: "/gestor/pedidos", texto: /./ },
  { url: "/gestor/dev/regras", texto: /./ },
  { url: "/dev", texto: /./ },
  { url: "/ajuda", texto: /./ },
];
// avisos de rede/sessão sem banco no teste não contam como erro da tela
const IGNORAR = /supabase|fetch|Failed to load resource|NetworkError|ERR_|401|403|AuthSession|tiles?|maplibre|WebGL/i;

const navegador = await chromium.launch(process.env.CHROME ? { executablePath: process.env.CHROME } : {});
let falhas = 0;
for (const larg of [390, 1280]) {
  const ctx = await navegador.newContext({ viewport: { width: larg, height: 860 } });
  for (const p of PAGINAS) {
    const pag = await ctx.newPage();
    const erros = [];
    pag.on("pageerror", (e) => { if (!IGNORAR.test(String(e))) erros.push(String(e).slice(0, 200)); });
    let status = 0;
    try {
      const r = await pag.goto(base + p.url, { waitUntil: "load", timeout: 30_000 });
      status = r?.status() ?? 0;
      await pag.waitForTimeout(1200);
      const corpo = (await pag.locator("body").innerText()).trim();
      if (status >= 500 || status === 0) erros.push(`respondeu ${status}`);
      if (!p.texto.test(corpo)) erros.push(`não achei o texto esperado (${p.texto})`);
      if (/Application error|Unhandled Runtime Error|This page could not be found/i.test(corpo) && !p.url.startsWith("/r/")) erros.push("a página mostrou erro");
    } catch (e) { erros.push(String(e).slice(0, 200)); }
    if (erros.length) { falhas++; console.log(`::error::${p.url} (${larg}px): ${erros.join(" | ")}`); }
    else console.log(`OK ${p.url} (${larg}px, ${status})`);
    await pag.close();
  }
  await ctx.close();
}
await navegador.close();
if (falhas) { console.log(`${falhas} tela(s) com problema.`); process.exit(1); }
console.log("Todas as telas abriram.");

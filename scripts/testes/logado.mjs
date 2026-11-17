// Telas do gestor "logado" sem banco: o Supabase é simulado. Uso: PAPEIS=dev,gestor TAMS=390x844m,1280x800d node scripts/testes/logado.mjs /gestor/inicio,/gestor/mapa
// Mostra a largura da página e o que sai da tela; salva fotos em /tmp/l-*.png.
import { chromium } from "playwright";
const URLSB = "https://ydenimtlyetwsmjvuqxq.supabase.co";
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
const uid = "00000000-0000-0000-0000-0000000000a1";
const exp = Math.floor(Date.now() / 1000) + 36000;
const jwt = `${b64({ alg: "HS256", typ: "JWT" })}.${b64({ sub: uid, exp, role: "authenticated", aud: "authenticated", email: "g@x" })}.x`;
const user = { id: uid, email: "g@x", aud: "authenticated", role: "authenticated", app_metadata: {}, user_metadata: {}, created_at: new Date().toISOString() };
const sessao = { access_token: jwt, refresh_token: "r", expires_in: 36000, expires_at: exp, token_type: "bearer", user };
const papeis = (process.env.PAPEIS ?? "gestor").split(",");
const perfil = { id: uid, nome: "Gestor Teste", papeis, gestor: true, dev: papeis.includes("dev"), modulos: {}, configuracoes: {}, organizacao: { id: "o1", nome: "PW Express", status: "ativa" }, cor_tema: "ouro" };
const b = await chromium.launch({ executablePath: "/usr/bin/google-chrome" });
const rotas = (process.argv[2] ?? "/gestor/inicio").split(",");
for (const [w, h, n] of (process.env.TAMS ?? "390x844m,1280x800d").split(",").map((t) => { const m = t.match(/(\d+)x(\d+)(\w+)/); return [+m[1], +m[2], m[3]]; })) {
  const ctx = await b.newContext({ viewport: { width: w, height: h } });
  await ctx.addInitScript(([k, v]) => { localStorage.setItem(k, v); localStorage.setItem("pwex-tour-gestor", "1"); }, ["sb-ydenimtlyetwsmjvuqxq-auth-token", JSON.stringify(sessao)]);
  await ctx.route(URLSB + "/**", (r) => {
    const u = r.request().url();
    const json = (x) => r.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify(x) });
    if (u.includes("/auth/v1/user")) return json(user);
    if (u.includes("/auth/v1/")) return json({});
    if (u.includes("rpc/is_gestor")) return json(true);
    if (u.includes("rpc/meu_perfil")) return json(perfil);
    if (u.includes("rpc/minhas_permissoes")) return json({ dev: perfil.dev, ajustes: {}, acoes: {} });
    if (u.includes("rpc/dev_matriz")) return json([{ id: "p1", nome: "Ana Gestora", papeis: ["gestor"], cargo: null, cliente: null, valores: Object.fromEntries(JSON.parse(r.request().postData() ?? "{}").p_chaves.map((k, i) => [k, { valor: i % 3 === 0 ? true : i % 3 === 1 ? false : 30, fonte: i === 1 ? "regra" : "padrao", motivo: i === 1 ? "Regra do Dev (só esta pessoa)" : "Liberado (padrão)" }])) }]);
    if (u.includes("rpc/dev_regras")) return json([]);
    if (u.includes("/rest/v1/organizacoes")) return json([{ id: "o1", nome: "PW Express" }]);
    if (u.includes("/rpc/")) return json(null);
    return json([]);
  });
  const p = await ctx.newPage();
  const erros = [];
  p.on("pageerror", (e) => erros.push(e.message));
  for (const rota of rotas) {
    await p.goto("http://localhost:3100" + rota, { waitUntil: "networkidle" }).catch(() => {});
    await p.waitForTimeout(1500);
    if (process.env.ACAO) { await eval(process.env.ACAO); await p.waitForTimeout(1200); }
    const info = await p.evaluate(() => {
      const W = window.innerWidth;
      const fora = [...document.querySelectorAll("body *")].filter((e) => { const r = e.getBoundingClientRect(); return r.width > 0 && (r.right > W + 2 || r.left < -2); }).slice(0, 8)
        .map((e) => `${e.tagName.toLowerCase()}.${[...e.classList].join(".")} ${Math.round(e.getBoundingClientRect().left)}→${Math.round(e.getBoundingClientRect().right)}`);
      return { sw: document.documentElement.scrollWidth, fora };
    });
    const nome = `/tmp/l-${n}-${rota.replace(/\//g, "_")}.png`;
    await p.screenshot({ path: nome });
    console.log(n, rota, "largura", info.sw, "de", w, info.fora.join(" | "));
  }
  if (erros.length) console.log("erros:", erros.slice(0, 3).join(" || "));
  await ctx.close();
}
await b.close();

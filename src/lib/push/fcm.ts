import { importPKCS8, SignJWT } from "jose";

interface ContaServico {
  project_id: string;
  client_email: string;
  private_key: string;
}

let conta: ContaServico | null = null;
let tokenCache: { valor: string; expira: number } | null = null;

/** Aceita o JSON colado direto, entre aspas (texto com JSON dentro) ou em base64. */
function interpretar(bruto: string): unknown {
  let v: unknown = bruto.trim();
  for (let i = 0; i < 3 && typeof v === "string"; i++) {
    const t = (v as string).trim();
    if (t.startsWith("{") || t.startsWith("\"")) v = JSON.parse(t);
    else v = Buffer.from(t, "base64").toString("utf8");
  }
  return v;
}

/** Texto quebrado (aspas a mais, quebras de linha reais na chave): tira só os três campos. */
function resgatar(bruto: string): Record<string, string> | null {
  const t = bruto.replace(/\\"/g, '"');
  const campo = (k: string) => t.match(new RegExp(`"${k}"\\s*:\\s*"([^"]+)"`))?.[1];
  const chave = t.match(/-----BEGIN PRIVATE KEY-----[\s\S]*?-----END PRIVATE KEY-----/)?.[0];
  const project_id = campo("project_id");
  const client_email = campo("client_email");
  if (!project_id || !client_email || !chave) return null;
  const corpo = chave.replace(/-----(BEGIN|END) PRIVATE KEY-----/g, "").replace(/\\[nr]|\\|\s/g, "");
  return { type: "service_account", project_id, client_email, private_key: `-----BEGIN PRIVATE KEY-----\n${corpo.match(/.{1,64}/g)?.join("\n")}\n-----END PRIVATE KEY-----\n` };
}

/** Explica, sem revelar valores, o que tem na variável. */
export function estadoConta(): { ok: boolean; motivo?: string; project_id?: string } {
  try {
    const c = lerConta();
    return { ok: true, project_id: c.project_id };
  } catch (e) {
    return { ok: false, motivo: e instanceof Error ? e.message : String(e) };
  }
}

export function lerConta(): ContaServico {
  if (conta) return conta;
  const bruto = process.env.FIREBASE_SERVICE_ACCOUNT;
  if (!bruto) throw new Error("FIREBASE_SERVICE_ACCOUNT não configurada na Vercel");
  let v: unknown;
  try {
    v = interpretar(bruto);
  } catch {
    v = null;
  }
  if (!v || typeof v !== "object") v = resgatar(bruto);
  if (!v) throw new Error("FIREBASE_SERVICE_ACCOUNT não é um JSON válido (cole o arquivo .json inteiro, do { ao })");
  const o = v as Record<string, unknown>;
  if ("project_info" in o || "client" in o)
    throw new Error("FIREBASE_SERVICE_ACCOUNT tem o google-services.json do app; precisa da chave da conta de serviço (Firebase → Configurações do projeto → Contas de serviço → Gerar nova chave privada)");
  if (o.type && o.type !== "service_account")
    throw new Error(`FIREBASE_SERVICE_ACCOUNT é do tipo "${String(o.type)}"; precisa ser "service_account"`);
  const faltam = ["project_id", "client_email", "private_key"].filter((k) => typeof o[k] !== "string" || !o[k]);
  if (faltam.length) throw new Error(`FIREBASE_SERVICE_ACCOUNT sem os campos: ${faltam.join(", ")}`);
  const json = { project_id: o.project_id as string, client_email: o.client_email as string, private_key: (o.private_key as string).replace(/\\n/g, "\n") };
  conta = json;
  return json;
}

/** Token OAuth do Google para a API do FCM (válido ~1 h, guardado em cache). */
async function tokenGoogle(): Promise<string> {
  if (tokenCache && tokenCache.expira > Date.now() + 60_000) return tokenCache.valor;
  const c = lerConta();
  const chave = await importPKCS8(c.private_key, "RS256");
  const agora = Math.floor(Date.now() / 1000);
  const assertion = await new SignJWT({ scope: "https://www.googleapis.com/auth/firebase.messaging" })
    .setProtectedHeader({ alg: "RS256", typ: "JWT" })
    .setIssuer(c.client_email)
    .setAudience("https://oauth2.googleapis.com/token")
    .setIssuedAt(agora)
    .setExpirationTime(agora + 3600)
    .sign(chave);

  const r = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion }),
  });
  if (!r.ok) throw new Error(`Google OAuth ${r.status}: ${await r.text()}`);
  const j = (await r.json()) as { access_token: string; expires_in: number };
  tokenCache = { valor: j.access_token, expira: Date.now() + j.expires_in * 1000 };
  return j.access_token;
}

/** Envia uma mensagem "data" de alta prioridade (acorda o app mesmo fechado). */
export async function enviarFcm(token: string, dados: Record<string, string>) {
  const c = lerConta();
  const r = await fetch(`https://fcm.googleapis.com/v1/projects/${c.project_id}/messages:send`, {
    method: "POST",
    headers: { Authorization: `Bearer ${await tokenGoogle()}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      // oferta vale poucos segundos; o resto (cancelamento, planejadas) precisa chegar mesmo se o celular estiver sem sinal um tempo
      message: { token, data: dados, android: { priority: "HIGH", ttl: dados.tipo === "oferta" ? "40s" : "3600s" } },
    }),
  });
  return { ok: r.ok, status: r.status, corpo: r.ok ? undefined : await r.text() };
}

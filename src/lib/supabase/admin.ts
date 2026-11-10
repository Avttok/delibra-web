import "server-only";
import { createClient, type SupabaseClient } from "@supabase/supabase-js";

const url = process.env.NEXT_PUBLIC_SUPABASE_URL ?? "";
const publica = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY ?? "";

/**
 * Chave secreta do Supabase (Project Settings → API Keys → Secret key).
 * Fica SÓ nas variáveis de ambiente da Vercel, nunca no navegador nem no GitHub.
 */
const secreta = () => process.env.SUPABASE_SECRET_KEY ?? process.env.SUPABASE_SERVICE_ROLE_KEY ?? "";

export const adminConfigurado = () => Boolean(url && secreta());

export function supabaseAdmin(): SupabaseClient {
  return createClient(url, secreta(), { auth: { persistSession: false, autoRefreshToken: false } });
}

/** Cliente do Supabase agindo como quem chamou (respeita as regras do banco). */
export function clienteDoUsuario(req: Request): SupabaseClient | null {
  const token = req.headers.get("authorization")?.replace(/^Bearer\s+/i, "");
  if (!token || !url || !publica) return null;
  return createClient(url, publica, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { Authorization: `Bearer ${token}` } },
  });
}

/** Confere se quem chamou (pelo token da sessão) é gestor. Devolve o id ou null. */
export async function gestorDaRequisicao(req: Request): Promise<string | null> {
  const sb = clienteDoUsuario(req);
  const token = req.headers.get("authorization")?.replace(/^Bearer\s+/i, "");
  if (!sb || !token) return null;
  const { data: u } = await sb.auth.getUser(token);
  if (!u.user) return null;
  const { data } = await sb.rpc("is_gestor");
  return data === true ? u.user.id : null;
}

export const uuidValido = (v: unknown): v is string => typeof v === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v);

/** Quem chamou pode mexer na conta `alvo`? (Dev: todas; gestor: todas menos as Dev.) */
export async function podeGerenciar(req: Request, alvo: string): Promise<boolean> {
  const sb = clienteDoUsuario(req);
  if (!sb) return false;
  const { data } = await sb.rpc("pode_gerenciar", { p_alvo: alvo });
  return data === true;
}

/** Quem chamou é Dev? */
export async function ehDev(req: Request): Promise<boolean> {
  const sb = clienteDoUsuario(req);
  if (!sb) return false;
  const { data } = await sb.rpc("is_dev");
  return data === true;
}

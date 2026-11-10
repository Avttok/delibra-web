import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { armazenamentoSessao, contas } from "./contas";

const url = process.env.NEXT_PUBLIC_SUPABASE_URL ?? "";
const chave = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY ?? "";

let cliente: SupabaseClient | null = null;

/**
 * Cliente Supabase do navegador. A sessão vai para o localStorage ("permanecer conectado")
 * ou para o sessionStorage (termina ao fechar o navegador).
 */
export function supabase(): SupabaseClient {
  if (!cliente) {
    if (!url || !chave) throw new Error("Supabase não configurado: veja o arquivo .env");
    cliente = createClient(url, chave, {
      auth: { persistSession: true, autoRefreshToken: true, storage: armazenamentoSessao },
    });
    // mantém o token da conta salva sempre válido
    cliente.auth.onAuthStateChange((evento, s) => {
      const email = s?.user.email;
      if (!email || !s?.refresh_token) return;
      if (evento === "SIGNED_IN") contas.lembrar(email, s.refresh_token);
      else if (evento === "TOKEN_REFRESHED") contas.atualizarToken(email, s.refresh_token);
    });
  }
  return cliente;
}

/** Sai só deste navegador (não invalida o "entrar com um toque" das contas salvas). */
export function sair() {
  return supabase().auth.signOut({ scope: "local" });
}

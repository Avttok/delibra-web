"use client";

import { useCallback, useEffect, useState } from "react";
import { CircleCheck, CreditCard, Link2, PlugZap, QrCode, Unplug } from "lucide-react";
import { supabase } from "@/lib/supabase/client";
import { toast } from "@/features/ui/toast";

export type ContaMp = { conectada: boolean; final: string | null; teste: boolean; nome: string | null; atualizado_em: string | null; destino: "plataforma" | "empresa"; plataforma_conectada: boolean };

async function comSessao(url: string, corpo: unknown) {
  const sb = supabase();
  const { data } = await sb.auth.getSession();
  const r = await fetch(url, { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${data.session?.access_token ?? ""}` }, body: JSON.stringify(corpo) });
  return (await r.json().catch(() => ({}))) as Record<string, unknown>;
}
export { comSessao };

/** Ligar o Mercado Pago da empresa: o dinheiro dos clientes (PIX e cartão) cai direto nesta conta. */
export function RecebimentosEmpresa() {
  const [conta, setConta] = useState<ContaMp | null | undefined>(undefined);
  const [token, setToken] = useState("");
  const [ocupado, setOcupado] = useState(false);
  const [teste, setTeste] = useState<string | null>(null);

  const carregar = useCallback(async () => {
    const { data } = await supabase().rpc("pag_minha_conta");
    setConta((data as ContaMp | null) ?? null);
  }, []);
  useEffect(() => { void carregar(); }, [carregar]);

  async function salvar(t: string) {
    setOcupado(true);
    const { data, error } = await supabase().rpc("pag_salvar_conta", { p_token: t, p_public_key: null, p_nome: null });
    setOcupado(false);
    if (error) return toast(error.message.includes("token_invalido") ? "Isso não parece um Access Token do Mercado Pago (começa com APP_USR- ou TEST-)." : error.message.includes("apenas_gestor") ? "Só o dono da empresa liga a conta." : error.message, "erro");
    setConta(data as ContaMp); setToken("");
    if (t) { toast("Conta salva. Testando…", "ok"); await testar(); } else toast("Conta desligada.", "ok");
  }
  async function testar() {
    setOcupado(true);
    const r = await comSessao("/api/pagamentos/testar", {});
    setOcupado(false);
    setTeste(r.ok ? `Conectada: ${String(r.nome)}` : String(r.erro ?? "Não deu para testar."));
    void carregar();
  }

  if (conta === undefined) return null;
  if (conta === null) return null; // só gestor vê
  return (
    <section className="bloco recebimentos">
      <h3 className="titulo-bloco"><CreditCard size={16} aria-hidden /> Receber dos clientes (PIX e cartão)</h3>
      <p className="dica" style={{ margin: 0 }}>
        {conta.destino === "plataforma"
          ? <>Pela escolha da plataforma, os pagamentos dos seus clientes caem na <strong>conta da plataforma</strong>{conta.plataforma_conectada ? "" : " (ainda não ligada)"}, que repassa a você. Ligar a sua conta abaixo fica guardado para quando isso mudar.</>
          : <>Os pagamentos dos seus clientes caem <strong>direto na sua conta</strong> do Mercado Pago. O cliente paga por PIX (QR na hora) ou cartão (página segura do Mercado Pago) e o pedido segue sozinho quando o pagamento é aprovado.</>}
      </p>
      <div className="recebimentos-estado">
        {conta.conectada
          ? <span className="selo" style={{ color: "#22c55e" }}><CircleCheck size={13} aria-hidden /> Conta ligada · token …{conta.final}{conta.teste ? " · modo teste" : ""}</span>
          : <span className="selo"><Unplug size={13} aria-hidden /> Nenhuma conta ligada</span>}
        {conta.nome && <span className="dica">{conta.nome}</span>}
      </div>
      <label className="campo"><span>Access Token de produção do Mercado Pago</span>
        <input type="password" autoComplete="off" spellCheck={false} placeholder={conta.conectada ? "Cole um novo para trocar" : "APP_USR-…"} value={token} onChange={(e) => setToken(e.target.value.trim())} />
        <small className="dica">No Mercado Pago: Seu negócio → Configurações → Credenciais (ou developers.mercadopago.com → Suas integrações). O token fica guardado só no servidor; ninguém consegue vê-lo de volta.</small>
      </label>
      <div className="linha-botoes">
        <button type="button" className="botao-ouro" disabled={ocupado || !token} onClick={() => void salvar(token)}><PlugZap size={15} aria-hidden /> Ligar conta</button>
        {conta.conectada && <button type="button" className="botao-texto" disabled={ocupado} onClick={() => void testar()}><Link2 size={15} aria-hidden /> Testar</button>}
        {conta.conectada && <button type="button" className="botao-texto" disabled={ocupado} onClick={() => void salvar("")}><Unplug size={15} aria-hidden /> Desligar</button>}
      </div>
      {teste && <p className="dica" style={{ margin: 0 }}><QrCode size={12} aria-hidden /> {teste}</p>}
      <p className="dica" style={{ margin: 0 }}>Para o cliente pagar antes, ligue “Pagamento antecipado” no cadastro dele (ou em Ajustes → Clientes).</p>
    </section>
  );
}

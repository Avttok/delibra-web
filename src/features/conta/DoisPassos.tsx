"use client";

import { useEffect, useState } from "react";
import { KeyRound, ShieldCheck, Trash2, X } from "lucide-react";
import { supabase } from "@/lib/supabase/client";
import { toast } from "@/features/ui/toast";

type Fator = { id: string; friendly_name?: string; status: string; factor_type: string };

/** Ligar/desligar a verificação em dois passos (código do app autenticador). Só aparece se o Dev liberou. */
export function DoisPassosModal({ onFechar }: { onFechar: () => void }) {
  const [fatores, setFatores] = useState<Fator[] | null>(null);
  const [novo, setNovo] = useState<{ id: string; qr: string; segredo: string } | null>(null);
  const [codigo, setCodigo] = useState("");
  const [ocupado, setOcupado] = useState(false);
  const carregar = async () => {
    const { data } = await supabase().auth.mfa.listFactors();
    setFatores(((data?.totp ?? []) as Fator[]).filter((f) => f.status === "verified"));
  };
  useEffect(() => { void carregar(); }, []);

  async function comecar() {
    setOcupado(true);
    // tira cadastros que ficaram pela metade
    const { data: l } = await supabase().auth.mfa.listFactors();
    for (const f of (l?.all ?? []) as Fator[]) if (f.status !== "verified") await supabase().auth.mfa.unenroll({ factorId: f.id });
    const { data, error } = await supabase().auth.mfa.enroll({ factorType: "totp", friendlyName: `Delibra ${new Date().toLocaleDateString("pt-BR")}` });
    setOcupado(false);
    if (error || !data) return toast("Não deu para começar agora. Peça ao Dev para ativar no projeto.", "erro");
    setNovo({ id: data.id, qr: data.totp.qr_code, segredo: data.totp.secret });
  }
  async function confirmar() {
    if (!novo) return;
    setOcupado(true);
    const { error } = await supabase().auth.mfa.challengeAndVerify({ factorId: novo.id, code: codigo.trim() });
    setOcupado(false);
    if (error) return toast("Código errado. Confira no app autenticador.", "erro");
    toast("Verificação em dois passos ligada.", "ok"); setNovo(null); setCodigo(""); void carregar();
  }
  async function remover(f: Fator) {
    if (!confirm("Desligar a verificação em dois passos?")) return;
    const { error } = await supabase().auth.mfa.unenroll({ factorId: f.id });
    if (error) return toast("Para desligar, entre de novo com o código e tente outra vez.", "erro");
    toast("Desligada.", "ok"); void carregar();
  }
  return (
    <div className="modal-fundo" onMouseDown={(e) => e.target === e.currentTarget && onFechar()}>
      <div className="modal vidro entrar" role="dialog" aria-label="Verificação em dois passos" style={{ width: "min(440px, 94vw)", display: "grid", gap: 12 }}>
        <div style={{ display: "flex", alignItems: "center", gap: 8 }}><ShieldCheck size={18} aria-hidden /><strong style={{ flex: 1 }}>Verificação em dois passos</strong>
          <button type="button" className="icone" aria-label="Fechar" onClick={onFechar}><X size={16} /></button></div>
        <p className="dica" style={{ margin: 0 }}>Ao entrar no site, além da senha você digita um código de 6 números do app autenticador (Google Authenticator, Authy, 1Password…).</p>
        {fatores?.length ? (
          fatores.map((f) => (
            <div key={f.id} className="integracao"><div><strong>Ligada</strong><span className="dica">{f.friendly_name ?? "App autenticador"}</span></div>
              <button type="button" className="botao-perigo" onClick={() => remover(f)}><Trash2 size={14} aria-hidden /> Desligar</button></div>
          ))
        ) : novo ? (
          <>
            <p style={{ margin: 0 }}>1. No app autenticador, leia o código abaixo (ou digite a chave).</p>
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <img src={novo.qr} alt="Código QR para o app autenticador" width={180} height={180} style={{ background: "#fff", borderRadius: 12, padding: 8, justifySelf: "center" }} />
            <code style={{ overflowWrap: "anywhere", fontSize: 12 }}>{novo.segredo}</code>
            <label className="campo"><span>2. Digite o código de 6 números</span>
              <input inputMode="numeric" autoComplete="one-time-code" maxLength={6} value={codigo} onChange={(e) => setCodigo(e.target.value.replace(/\D/g, ""))} /></label>
            <button type="button" className="botao-ouro" disabled={ocupado || codigo.length !== 6} onClick={confirmar}><KeyRound size={15} aria-hidden /> Ligar</button>
          </>
        ) : fatores ? (
          <button type="button" className="botao-ouro" disabled={ocupado} onClick={comecar}><ShieldCheck size={15} aria-hidden /> Ligar a verificação</button>
        ) : <p className="dica">Carregando…</p>}
      </div>
    </div>
  );
}

/** Quem ligou os dois passos: depois da senha, pede o código antes de mostrar o painel. */
export function ExigirDoisPassos() {
  const [precisa, setPrecisa] = useState<string | null>(null);
  const [codigo, setCodigo] = useState("");
  const [ocupado, setOcupado] = useState(false);
  useEffect(() => {
    const ver = async () => {
      const sb = supabase();
      const { data } = await sb.auth.mfa.getAuthenticatorAssuranceLevel();
      if (data?.currentLevel === "aal1" && data.nextLevel === "aal2") {
        const { data: f } = await sb.auth.mfa.listFactors();
        setPrecisa(f?.totp?.find((x) => x.status === "verified")?.id ?? null);
      } else setPrecisa(null);
    };
    void ver();
    const { data: sub } = supabase().auth.onAuthStateChange(() => { void ver(); });
    return () => sub.subscription.unsubscribe();
  }, []);
  if (!precisa) return null;
  async function entrar() {
    setOcupado(true);
    const { error } = await supabase().auth.mfa.challengeAndVerify({ factorId: precisa!, code: codigo.trim() });
    setOcupado(false);
    if (error) return toast("Código errado. Confira no app autenticador.", "erro");
    setPrecisa(null);
  }
  return (
    <div className="modal-fundo" style={{ zIndex: 9999 }}>
      <form className="modal vidro entrar" role="dialog" aria-label="Código de verificação" style={{ width: "min(380px, 94vw)", display: "grid", gap: 12 }}
        onSubmit={(e) => { e.preventDefault(); void entrar(); }}>
        <strong><ShieldCheck size={16} aria-hidden /> Código de verificação</strong>
        <p className="dica" style={{ margin: 0 }}>Abra o app autenticador e digite o código de 6 números.</p>
        <input autoFocus inputMode="numeric" autoComplete="one-time-code" maxLength={6} value={codigo} onChange={(e) => setCodigo(e.target.value.replace(/\D/g, ""))} aria-label="Código" />
        <button type="submit" className="botao-ouro" disabled={ocupado || codigo.length !== 6}>Entrar</button>
        <button type="button" className="botao-texto" onClick={() => void supabase().auth.signOut().then(() => window.location.assign("/"))}>Sair</button>
      </form>
    </div>
  );
}

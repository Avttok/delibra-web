"use client";

import { useEffect, useState } from "react";
import { FileCheck2 } from "lucide-react";
import { supabase } from "@/lib/supabase/client";

/**
 * Pede o aceite dos termos de uso e da política de privacidade quando a pessoa ainda não aceitou a versão em vigor
 * (o Dev muda a versão em Ajustes → Plataforma). Fica por cima de tudo até aceitar.
 */
export function AceiteTermos({ origem }: { origem: "gestor" | "cliente" }) {
  const [versao, setVersao] = useState<string | null>(null);
  const [marcado, setMarcado] = useState(false);
  const [enviando, setEnviando] = useState(false);
  const [erro, setErro] = useState<string | null>(null);

  useEffect(() => {
    let ativo = true;
    void supabase().rpc("termos_situacao").then(({ data, error }) => {
      if (!ativo || error || !data) return; // banco sem a função ainda: não trava ninguém
      const d = data as { versao: string; aceito: boolean };
      if (!d.aceito) setVersao(d.versao);
    });
    return () => { ativo = false; };
  }, []);

  if (!versao) return null;

  async function aceitar() {
    setEnviando(true); setErro(null);
    const { data, error } = await supabase().rpc("aceitar_termos", { p_versao: versao, p_origem: origem });
    setEnviando(false);
    if (error) {
      if (/versao_mudou/.test(error.message)) { location.reload(); return; }
      setErro("Não deu agora. Tente de novo.");
      return;
    }
    if ((data as { aceito?: boolean })?.aceito) setVersao(null);
  }

  return (
    <div className="aceite-fundo" role="dialog" aria-modal="true" aria-labelledby="aceite-titulo">
      <div className="aceite-janela vidro">
        <span className="aceite-icone"><FileCheck2 size={22} aria-hidden /></span>
        <h2 id="aceite-titulo">Termos de uso e privacidade</h2>
        <p>Para continuar, leia e aceite os <a href="/termos" target="_blank" rel="noreferrer">termos de uso</a> e a <a href="/privacidade" target="_blank" rel="noreferrer">política de privacidade</a> da Delibra.</p>
        <label className="aceite-marca">
          <input type="checkbox" checked={marcado} onChange={(e) => setMarcado(e.target.checked)} />
          <span>Li e aceito os termos de uso e a política de privacidade.</span>
        </label>
        {erro && <p className="aceite-erro">{erro}</p>}
        <button type="button" className="botao-ouro" disabled={!marcado || enviando} onClick={aceitar}>{enviando ? "Salvando…" : "Aceitar e continuar"}</button>
      </div>
    </div>
  );
}

/** Logo depois de criar a conta (a pessoa marcou o aceite no formulário): grava o aceite da versão em vigor. */
export async function aceitarAoCriar(origem: string) {
  try {
    const { data } = await supabase().rpc("termos_situacao");
    const v = (data as { versao?: string } | null)?.versao;
    if (v) await supabase().rpc("aceitar_termos", { p_versao: v, p_origem: origem });
  } catch { /* a janela de aceite pede de novo ao entrar */ }
}

/** Caixa de aceite dos formulários de cadastro. */
export function MarcaTermos({ marcado, onMudar }: { marcado: boolean; onMudar: (v: boolean) => void }) {
  return (
    <label className="aceite-marca">
      <input type="checkbox" required checked={marcado} onChange={(e) => onMudar(e.target.checked)} />
      <span>Li e aceito os <a href="/termos" target="_blank" rel="noreferrer">termos de uso</a> e a <a href="/privacidade" target="_blank" rel="noreferrer">política de privacidade</a>.</span>
    </label>
  );
}

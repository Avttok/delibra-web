"use client";

import { useEffect, useState } from "react";
import { Check, Minus, Pencil, Plus, SlidersHorizontal, X } from "lucide-react";

const CHAVE = "pwex_numero_barra";
const EVENTO = "pwex-numero-modo";

/** Como a pessoa prefere mudar números (barra ou digitando). Vale no site todo e fica lembrado. */
export function useModoNumero(): [boolean, (barra: boolean) => void] {
  const [barra, setBarra] = useState(true);
  useEffect(() => {
    try { setBarra(localStorage.getItem(CHAVE) !== "0"); } catch { /* sem armazenamento */ }
    const ouvir = (e: Event) => setBarra((e as CustomEvent<boolean>).detail);
    window.addEventListener(EVENTO, ouvir);
    return () => window.removeEventListener(EVENTO, ouvir);
  }, []);
  const definir = (v: boolean) => {
    setBarra(v);
    try { localStorage.setItem(CHAVE, v ? "1" : "0"); } catch { /* sem armazenamento */ }
    window.dispatchEvent(new CustomEvent(EVENTO, { detail: v }));
    window.dispatchEvent(new Event("pwex-tema-mudou"));
  };
  return [barra, definir];
}

/**
 * Número com rascunho: barra ou digitando (− e +), à escolha da pessoa no ícone ao lado.
 * Só salva no ✓ (ou Enter); ✗ (ou Esc) desfaz.
 */
export function CampoNumero({ valor, onSalvar, min = 0, max = 1e9, passo = 1, unidade, desabilitado }: {
  valor: number; onSalvar: (v: number) => void; min?: number; max?: number; passo?: number; unidade?: string; desabilitado?: boolean;
}) {
  const [barraPref, setBarra] = useModoNumero();
  const [texto, setTexto] = useState(String(valor).replace(".", ","));
  useEffect(() => { setTexto(String(valor).replace(".", ",")); }, [valor]);
  const cabeBarra = max < 1e8 && max > min && (max - min) / Math.max(passo, 1e-6) <= 400;
  const barra = barraPref && cabeBarra;
  const n = Number(texto.replace(/\./g, "").replace(",", "."));
  const ok = Number.isFinite(n) && texto.trim() !== "";
  const limpo = ok ? Math.min(max, Math.max(min, Math.round(n * 1000) / 1000)) : valor;
  const mudou = ok && limpo !== valor;
  const mudar = (v: number) => setTexto(String(Math.min(max, Math.max(min, Math.round(v * 1000) / 1000))).replace(".", ","));
  const salvar = () => { if (mudou) onSalvar(limpo); };
  const desfazer = () => setTexto(String(valor).replace(".", ","));
  return (
    <div className={`campo-numero${mudou ? " mudou" : ""}`}>
      {barra ? (
        <div className="campo-numero-barra">
          <strong>{limpo.toLocaleString("pt-BR")}{unidade ? ` ${unidade}` : ""}</strong>
          <input type="range" min={min} max={max} step={passo} value={limpo} disabled={desabilitado} onChange={(e) => mudar(Number(e.target.value))}
            aria-label="Valor" onKeyDown={(e) => { if (e.key === "Enter") salvar(); if (e.key === "Escape") desfazer(); }} />
        </div>
      ) : (
        <div className="campo-numero-passo">
          <button type="button" className="botao-icone" disabled={desabilitado || limpo <= min} onClick={() => mudar(limpo - passo)} aria-label="Diminuir"><Minus size={15} /></button>
          <input inputMode="decimal" value={texto} disabled={desabilitado} onChange={(e) => setTexto(e.target.value.replace(/[^\d,.-]/g, "").slice(0, 12))}
            onKeyDown={(e) => { if (e.key === "Enter") salvar(); if (e.key === "Escape") desfazer(); }} aria-label="Valor" />
          {unidade && <span className="campo-numero-unidade">{unidade}</span>}
          <button type="button" className="botao-icone" disabled={desabilitado || limpo >= max} onClick={() => mudar(limpo + passo)} aria-label="Aumentar"><Plus size={15} /></button>
        </div>
      )}
      {cabeBarra && (
        <button type="button" className="botao-icone campo-numero-modo" onClick={() => setBarra(!barra)} title={barra ? "Digitar o número" : "Usar a barra"} aria-label={barra ? "Digitar o número" : "Usar a barra"}>
          {barra ? <Pencil size={14} /> : <SlidersHorizontal size={14} />}
        </button>
      )}
      {mudou && <>
        <button type="button" className="passo-ok" onClick={salvar} title="Salvar" aria-label="Salvar"><Check size={15} /></button>
        <button type="button" className="passo-desfazer" onClick={desfazer} title="Desfazer" aria-label="Desfazer"><X size={15} /></button>
      </>}
    </div>
  );
}

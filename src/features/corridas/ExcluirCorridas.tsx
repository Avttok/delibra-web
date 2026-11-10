"use client";

import { useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { Lock, Trash2, TriangleAlert, X } from "lucide-react";
import { supabase } from "@/lib/supabase/client";
import { moeda } from "@/features/precos/estrategias";
import { ROTULO_CORRIDA, numeroCorrida, type Corrida } from "./tipos";

const ERROS: Record<string, string> = {
  senha_incorreta: "Senha incorreta.",
  muitas_tentativas: "Muitas senhas erradas. Por segurança, a exclusão ficou bloqueada por 15 minutos.",
  cancele_as_corridas_em_andamento: "Há corrida aceita ou em andamento na seleção. Cancele antes de apagar.",
  apenas_gestor: "Apenas gestores podem apagar corridas.",
};

/** Janela de exclusão definitiva: exige marcar a confirmação e digitar a senha (conferida no banco). */
export function ExcluirCorridas({ corridas, onFechar, onExcluidas }: {
  corridas: Corrida[];
  onFechar: () => void;
  onExcluidas: (ids: string[]) => void;
}) {
  const [senha, setSenha] = useState("");
  const [entendi, setEntendi] = useState(false);
  const [motivo, setMotivo] = useState("");
  const [enviando, setEnviando] = useState(false);
  const [erro, setErro] = useState<string | null>(null);
  const campoSenha = useRef<HTMLInputElement>(null);

  const ativas = corridas.filter((c) => c.status === "aceita" || c.status === "em_andamento" || c.status === "reservada");
  const comprovantes = corridas.reduce((n, c) => n + c.paradas.filter((p) => p.foto_path || p.assinatura_path).length, 0);
  const total = corridas.reduce((s, c) => s + (c.teste ? 0 : Number(c.valor ?? 0)), 0);
  const titulo = corridas.length === 1 ? `Apagar a corrida ${numeroCorrida(corridas[0])}?` : `Apagar ${corridas.length} corridas?`;

  useEffect(() => {
    const esc = (e: KeyboardEvent) => e.key === "Escape" && !enviando && onFechar();
    window.addEventListener("keydown", esc);
    return () => window.removeEventListener("keydown", esc);
  }, [enviando, onFechar]);

  async function excluir() {
    setErro(null);
    setEnviando(true);
    const sb = supabase();
    const { data, error } = await sb.rpc("excluir_corridas", {
      p_corridas: corridas.map((c) => c.id),
      p_senha: senha,
      p_motivo: motivo || null,
    });
    if (error) {
      setEnviando(false);
      return setErro(ERROS[error.message] ?? error.message);
    }
    const r = data as { erro?: string; restantes?: number; excluidas?: number; arquivos?: string[] };
    if (r.erro) {
      setEnviando(false);
      setSenha("");
      campoSenha.current?.focus();
      return setErro(
        (ERROS[r.erro] ?? r.erro) +
          (r.erro === "senha_incorreta" && typeof r.restantes === "number" ? ` Restam ${r.restantes} tentativa${r.restantes === 1 ? "" : "s"}.` : ""),
      );
    }
    if (r.arquivos?.length) await sb.storage.from("comprovantes").remove(r.arquivos);
    onExcluidas(corridas.map((c) => c.id));
  }

  const pode = entendi && senha.length > 0 && ativas.length === 0 && !enviando;

  // portal: o painel de vidro (backdrop-filter) prenderia uma janela "fixed" dentro dele
  return createPortal(
    <div className="modal-fundo" onMouseDown={(e) => e.target === e.currentTarget && !enviando && onFechar()}>
      <div className="modal modal-perigo vidro entrar" role="alertdialog" aria-labelledby="titulo-excluir">
        <button className="botao-icone modal-fechar" onClick={onFechar} disabled={enviando} aria-label="Fechar"><X size={17} /></button>

        <div className="perigo-icone"><TriangleAlert size={30} aria-hidden /></div>
        <h2 id="titulo-excluir" className="display">{titulo}</h2>
        <p className="perigo-texto">Esta ação é <strong>definitiva e não pode ser desfeita.</strong> Serão apagados para sempre:</p>
        <ul className="perigo-lista">
          <li>{corridas.length === 1 ? "A corrida" : `${corridas.length} corridas`} com todas as paradas e a linha do tempo</li>
          <li>A trilha GPS percorrida</li>
          {comprovantes > 0 && <li>{comprovantes} comprovante{comprovantes === 1 ? "" : "s"} (fotos e assinaturas)</li>}
          {total > 0 && <li>Registros financeiros somando {moeda(total)}</li>}
        </ul>

        {corridas.length > 1 && (
          <div className="perigo-resumo">
            {corridas.slice(0, 8).map((c) => (
              <span key={c.id} className="selo">{numeroCorrida(c)} · {ROTULO_CORRIDA[c.status]}</span>
            ))}
            {corridas.length > 8 && <span className="selo">+{corridas.length - 8}</span>}
          </div>
        )}

        {ativas.length > 0 ? (
          <p className="erro">
            {ativas.length === 1 ? `A corrida ${numeroCorrida(ativas[0])} está` : `${ativas.length} corridas estão`} em andamento ou reservada. Cancele antes de apagar.
          </p>
        ) : (
          <>
            <label className="opcao perigo-check">
              <span>Entendo que os dados não poderão ser recuperados.</span>
              <input type="checkbox" checked={entendi} onChange={(e) => setEntendi(e.target.checked)} />
            </label>
            <label className="campo">
              <span>Motivo (opcional, fica no registro de exclusões)</span>
              <input value={motivo} onChange={(e) => setMotivo(e.target.value)} placeholder="Ex.: lançada em duplicidade" />
            </label>
            <label className="campo">
              <span><Lock size={13} aria-hidden style={{ verticalAlign: -2 }} /> Digite sua senha para confirmar</span>
              <input
                ref={campoSenha}
                type="password"
                autoComplete="current-password"
                value={senha}
                onChange={(e) => setSenha(e.target.value)}
                onKeyDown={(e) => e.key === "Enter" && pode && excluir()}
                disabled={!entendi}
              />
            </label>
          </>
        )}

        {erro && <p className="erro">{erro}</p>}

        <div className="linha-botoes" style={{ justifyContent: "flex-end" }}>
          <button className="botao-texto" onClick={onFechar} disabled={enviando}>Manter</button>
          <button className="botao-excluir" onClick={excluir} disabled={!pode}>
            <Trash2 size={16} aria-hidden /> {enviando ? "Apagando…" : "Apagar definitivamente"}
          </button>
        </div>
      </div>
    </div>,
    document.body,
  );
}

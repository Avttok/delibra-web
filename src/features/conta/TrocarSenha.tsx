"use client";

import { useState } from "react";
import { createPortal } from "react-dom";
import { KeyRound, Lock, X } from "lucide-react";
import { supabase } from "@/lib/supabase/client";
import { toast } from "@/features/ui/toast";

/** Trocar a própria senha (confere a atual antes). Ajustes → usuario_troca_senha. */
export function TrocarSenhaModal({ email, onFechar }: { email: string; onFechar: () => void }) {
  const [atual, setAtual] = useState("");
  const [nova, setNova] = useState("");
  const [conf, setConf] = useState("");
  const [salvando, setSalvando] = useState(false);
  const forca = nova.length < 6 ? 0 : nova.length >= 10 && /\d/.test(nova) && /[a-z]/i.test(nova) && /[^a-z0-9]/i.test(nova) ? 3 : /\d/.test(nova) && /[a-z]/i.test(nova) ? 2 : 1;
  const erro = nova && nova.length < 6 ? "A senha precisa ter pelo menos 6 caracteres." : conf && conf !== nova ? "As senhas não são iguais." : nova && nova === atual ? "A senha nova é igual à atual." : null;
  async function salvar() {
    if (erro || !nova || !atual) return;
    setSalvando(true);
    const sb = supabase();
    const conferir = await sb.auth.signInWithPassword({ email, password: atual });
    if (conferir.error) { setSalvando(false); return toast("A senha atual não confere.", "erro"); }
    const { error } = await sb.auth.updateUser({ password: nova });
    setSalvando(false);
    if (error) return toast(/same|different/i.test(error.message) ? "A senha nova precisa ser diferente da atual." : /weak|short/i.test(error.message) ? "Senha fraca demais. Use letras e números." : error.message, "erro");
    toast("Senha trocada. Você continua conectado.", "ok", { titulo: "Pronto" });
    onFechar();
  }
  return createPortal(
    <div className="modal-fundo" onMouseDown={(e) => e.target === e.currentTarget && !salvando && onFechar()}>
      <div className="modal vidro entrar" role="dialog" aria-labelledby="titulo-senha" style={{ width: "min(420px, 94vw)", display: "grid", gap: 12 }}>
        <button className="botao-icone modal-fechar" onClick={onFechar} disabled={salvando} aria-label="Fechar"><X size={17} /></button>
        <h3 id="titulo-senha" className="display" style={{ margin: 0 }}><KeyRound size={18} aria-hidden /> Trocar senha</h3>
        <label className="campo"><span>Senha atual</span><input type="password" autoComplete="current-password" value={atual} onChange={(e) => setAtual(e.target.value)} /></label>
        <label className="campo"><span>Senha nova</span><input type="password" autoComplete="new-password" value={nova} onChange={(e) => setNova(e.target.value)} /></label>
        <div className="forca-senha" aria-label={["Curta", "Fraca", "Boa", "Forte"][forca]}>
          {[1, 2, 3].map((n) => <i key={n} className={forca >= n ? `f${forca}` : ""} />)}<small>{["Curta", "Fraca", "Boa", "Forte"][forca]}</small>
        </div>
        <label className="campo"><span>Repita a senha nova</span><input type="password" autoComplete="new-password" value={conf} onChange={(e) => setConf(e.target.value)}
          onKeyDown={(e) => e.key === "Enter" && void salvar()} /></label>
        {erro && <p className="erro" style={{ margin: 0 }}>{erro}</p>}
        <button className="botao-ouro" disabled={!atual || !nova || !conf || Boolean(erro) || salvando} onClick={salvar}>
          <Lock size={15} aria-hidden /> {salvando ? "Trocando…" : "Trocar senha"}
        </button>
      </div>
    </div>, document.body);
}

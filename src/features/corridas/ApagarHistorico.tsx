"use client";

import { useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { History, Lock, Trash2, X } from "lucide-react";
import { supabase } from "@/lib/supabase/client";
import { toast } from "@/features/ui/toast";
import type { MembroEquipe } from "./dados";

const ERROS: Record<string, string> = {
  senha_incorreta: "Senha incorreta.",
  muitas_tentativas: "Muitas senhas erradas. Por segurança, ficou bloqueado por 15 minutos.",
  apenas_gestor: "Apenas gestores podem apagar o histórico.",
  sem_permissao: "Você não pode mexer no histórico dessa conta.",
  nada_para_excluir: "Escolha o que apagar.",
};
const PERIODOS: [string, number | null][] = [["Tudo", null], ["Mais de 7 dias", 7], ["Mais de 30 dias", 30], ["Mais de 90 dias", 90]];

/**
 * Limpeza do histórico de todos (gestor e Dev): corridas finalizadas e/ou percursos GPS,
 * só do modo atual (teste ou real), de todos ou de um motoboy. Corridas ativas, agendadas
 * e reservadas nunca entram. Exige a senha (conferida no banco) e guarda cópia das corridas.
 */
export function ApagarHistorico({ teste, equipe, onFechar }: { teste: boolean; equipe: MembroEquipe[]; onFechar: () => void }) {
  const [corridas, setCorridas] = useState(true);
  const [percursos, setPercursos] = useState(true);
  const [motoboy, setMotoboy] = useState("");
  const [periodo, setPeriodo] = useState(0);
  const [senha, setSenha] = useState("");
  const [entendi, setEntendi] = useState(false);
  const [previa, setPrevia] = useState<{ corridas: number; pings: number } | null>(null);
  const [enviando, setEnviando] = useState(false);
  const [erro, setErro] = useState<string | null>(null);
  const campoSenha = useRef<HTMLInputElement>(null);
  const dias = PERIODOS[periodo][1];
  // o "até" é calculado uma vez por escolha, para a prévia e a exclusão baterem
  const [ate, setAte] = useState<string | null>(null);
  useEffect(() => { setAte(dias == null ? null : new Date(Date.now() - dias * 86400_000).toISOString()); }, [dias]);

  useEffect(() => {
    setPrevia(null);
    supabase().rpc("previa_historico", { p_teste: teste, p_motoboy: motoboy || null, p_ate: ate })
      .then(({ data, error }) => { if (!error) setPrevia(data as { corridas: number; pings: number }); });
  }, [teste, motoboy, ate]);

  useEffect(() => {
    const esc = (e: KeyboardEvent) => e.key === "Escape" && !enviando && onFechar();
    window.addEventListener("keydown", esc);
    return () => window.removeEventListener("keydown", esc);
  }, [enviando, onFechar]);

  async function apagar() {
    setErro(null); setEnviando(true);
    const sb = supabase();
    const { data, error } = await sb.rpc("apagar_historico", {
      p_senha: senha, p_teste: teste, p_corridas: corridas, p_percursos: percursos,
      p_motoboy: motoboy || null, p_ate: ate, p_motivo: "Limpeza de histórico pelo site",
    });
    if (error) { setEnviando(false); return setErro(ERROS[error.message] ?? error.message); }
    const r = data as { erro?: string; restantes?: number; corridas?: number; pings?: number; arquivos?: string[] };
    if (r.erro) {
      setEnviando(false); setSenha(""); campoSenha.current?.focus();
      return setErro((ERROS[r.erro] ?? r.erro) + (r.erro === "senha_incorreta" && typeof r.restantes === "number" ? ` Restam ${r.restantes} tentativa${r.restantes === 1 ? "" : "s"}.` : ""));
    }
    if (r.arquivos?.length) await sb.storage.from("comprovantes").remove(r.arquivos);
    toast(`${r.corridas ?? 0} corrida${r.corridas === 1 ? "" : "s"} e ${(r.pings ?? 0).toLocaleString("pt-BR")} pontos de percurso apagados.`, "ok", { titulo: "Histórico limpo" });
    onFechar();
  }

  const partes = previa ? [corridas && `${previa.corridas} corrida${previa.corridas === 1 ? "" : "s"}`, percursos && `${previa.pings.toLocaleString("pt-BR")} ponto${previa.pings === 1 ? "" : "s"} de percurso`].filter(Boolean) : [];
  const pode = entendi && senha.length > 0 && (corridas || percursos) && !enviando;

  return createPortal(
    <div className="modal-fundo" onMouseDown={(e) => e.target === e.currentTarget && !enviando && onFechar()}>
      <div className="modal modal-perigo vidro entrar" role="alertdialog" aria-labelledby="titulo-historico">
        <button className="botao-icone modal-fechar" onClick={onFechar} disabled={enviando} aria-label="Fechar"><X size={17} /></button>
        <div className="perigo-icone"><History size={30} aria-hidden /></div>
        <h2 id="titulo-historico" className="display">{teste ? "Apagar histórico de teste" : "Apagar histórico"}</h2>
        <p className="perigo-texto">Vale só para o modo <strong>{teste ? "teste" : "real"}</strong>. Corridas em andamento, agendadas ou reservadas não entram. Fica uma cópia no registro de exclusões.</p>

        <label className="opcao"><span><strong>Corridas finalizadas</strong><br /><small className="dica">Concluídas, canceladas e sem motoboy, com comprovantes e trajeto</small></span>
          <input type="checkbox" checked={corridas} onChange={(e) => setCorridas(e.target.checked)} /></label>
        <label className="opcao"><span><strong>Percursos (GPS)</strong><br /><small className="dica">Pontos de quando estavam procurando corrida</small></span>
          <input type="checkbox" checked={percursos} onChange={(e) => setPercursos(e.target.checked)} /></label>
        <label className="campo"><span>De quem</span>
          <select value={motoboy} onChange={(e) => setMotoboy(e.target.value)}>
            <option value="">Todos</option>
            {[...equipe].sort((a, b) => a.nome.localeCompare(b.nome)).map((m) => <option key={m.id} value={m.id}>{m.nome}</option>)}
          </select></label>
        <div className="filtro">
          {PERIODOS.map(([r], i) => <button key={r} type="button" className={periodo === i ? "ativo" : ""} onClick={() => setPeriodo(i)}>{r}</button>)}
        </div>
        {partes.length > 0 && <p className="erro"><strong>Vai apagar: {partes.join(" e ")}.</strong></p>}

        <label className="opcao perigo-check">
          <span>Entendo que os dados não poderão ser recuperados.</span>
          <input type="checkbox" checked={entendi} onChange={(e) => setEntendi(e.target.checked)} />
        </label>
        <label className="campo">
          <span><Lock size={13} aria-hidden style={{ verticalAlign: -2 }} /> Digite sua senha para confirmar</span>
          <input ref={campoSenha} type="password" autoComplete="current-password" value={senha} disabled={!entendi}
            onChange={(e) => setSenha(e.target.value)} onKeyDown={(e) => e.key === "Enter" && pode && apagar()} />
        </label>
        {erro && <p className="erro">{erro}</p>}
        <div className="linha-botoes" style={{ justifyContent: "flex-end" }}>
          <button className="botao-texto" onClick={onFechar} disabled={enviando}>Manter</button>
          <button className="botao-excluir" onClick={apagar} disabled={!pode}><Trash2 size={16} aria-hidden /> {enviando ? "Apagando…" : "Apagar histórico"}</button>
        </div>
      </div>
    </div>,
    document.body,
  );
}

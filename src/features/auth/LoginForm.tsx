"use client";

import { useRef, useState, type FormEvent, type ReactNode } from "react";
import { LogIn, X } from "lucide-react";
import { supabase } from "@/lib/supabase/client";
import { contas, definirPermanecer, permanecer as lerPermanecer, useContasSalvas, type ContaSalva } from "@/lib/supabase/contas";
import { Logo } from "@/features/marca/Logo";
import { BotaoTema } from "@/features/tema/BotaoTema";

/** `rodape`: conteúdo extra embaixo do formulário (ex.: "Criar conta" no site do cliente). */
export function LoginForm({ rodape }: { rodape?: ReactNode } = {}) {
  const salvas = useContasSalvas();
  const [email, setEmail] = useState("");
  const [senha, setSenha] = useState("");
  const [permanecer, setPermanecer] = useState(lerPermanecer);
  const [carregando, setCarregando] = useState(false);
  const [erro, setErro] = useState<string | null>(null);
  const campoSenha = useRef<HTMLInputElement>(null);

  async function entrar(e: FormEvent) {
    e.preventDefault();
    setCarregando(true);
    setErro(null);
    definirPermanecer(permanecer);
    const { error } = await supabase().auth.signInWithPassword({ email: email.trim(), password: senha });
    if (error) setErro(error.status === 400 ? "E-mail ou senha incorretos." : error.message);
    setCarregando(false);
  }

  async function usarConta(c: ContaSalva) {
    setErro(null);
    if (c.token) {
      setCarregando(true);
      definirPermanecer(true);
      const { error } = await supabase().auth.refreshSession({ refresh_token: c.token });
      setCarregando(false);
      if (!error) return;
      contas.esquecerToken(c.email);
      setErro("Sua sessão expirou. Digite a senha para entrar de novo.");
    }
    setEmail(c.email);
    setSenha("");
    setTimeout(() => campoSenha.current?.focus(), 0);
  }

  return (
    <main className="tela-login">
      <div style={{ position: "fixed", top: 16, right: 16 }}><BotaoTema /></div>
      <form className="caixa-login vidro entrar" onSubmit={entrar}>
        <Logo grande />

        {salvas.length > 0 && (
          <div className="contas-salvas">
            <span className="rotulo">Logar com</span>
            {salvas.slice(0, 5).map((c) => {
              const nome = c.nome || c.email.split("@")[0];
              return (
                <div key={c.email} className="conta-salva">
                  <button type="button" className="conta-usar" onClick={() => usarConta(c)} disabled={carregando}>
                    {c.foto
                      // eslint-disable-next-line @next/next/no-img-element
                      ? <img src={c.foto} alt="" className="avatar avatar-foto" />
                      : <span className="avatar grad">{nome.trim().charAt(0).toUpperCase()}</span>}
                    <span className="conta-texto">
                      <strong>{nome}</strong>
                      <span>{c.email}</span>
                    </span>
                    {c.token && <span className="conta-toque">1 toque</span>}
                  </button>
                  <button type="button" className="conta-remover" onClick={() => contas.remover(c.email)} title="Remover conta" aria-label={`Remover ${c.email}`}>
                    <X size={14} aria-hidden />
                  </button>
                </div>
              );
            })}
          </div>
        )}

        <label>
          E-mail
          <input type="email" autoComplete="email" value={email} onChange={(e) => setEmail(e.target.value)} required />
        </label>
        <label>
          Senha
          <input ref={campoSenha} type="password" autoComplete="current-password" value={senha} onChange={(e) => setSenha(e.target.value)} required />
        </label>

        <label className="permanecer">
          <span className="permanecer-texto">
            <strong>Permanecer conectado</strong>
            <span>{permanecer ? "Fica salvo em “Logar com” para entrar com um toque." : "A sessão termina ao fechar o navegador."}</span>
          </span>
          <input type="checkbox" role="switch" className="interruptor" checked={permanecer} onChange={(e) => setPermanecer(e.target.checked)} />
        </label>

        {erro && <p className="erro">{erro}</p>}
        <button className="botao-ouro" disabled={carregando}>
          <LogIn size={18} aria-hidden /> {carregando ? "Entrando…" : "Entrar"}
        </button>
        {rodape}
      </form>
    </main>
  );
}

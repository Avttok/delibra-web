"use client";

import { useCallback, useEffect, useState } from "react";
import { Ban, Copy, KeyRound, Plus, RefreshCw, Webhook } from "lucide-react";
import { supabase } from "@/lib/supabase/client";
import { toast } from "@/features/ui/toast";

type Chave = { id: string; nome: string; prefixo: string; criada_em: string; ultimo_uso: string | null; usos: number; revogada_em: string | null };
type Gancho = { url: string; segredo: string; eventos: string[]; ativo: boolean; ultimo_envio: string | null; ultimo_status: string | null };
type Dados = { chaves: Chave[]; webhook: Gancho | null; tem_acesso: boolean };

const EVENTOS: [string, string][] = [
  ["recebido", "Recebido"], ["aprovado", "Aprovado"], ["roteirizado", "Em rota montada"], ["em_rota", "Saiu para entrega"],
  ["concluido", "Concluído"], ["cancelado", "Cancelado"], ["recusado", "Recusado"],
];
const ERROS: Record<string, string> = {
  empresa_sem_acesso: "Crie antes uma conta de cliente para esta empresa (os pedidos da API entram por ela).",
  api_desligada: "A API está desligada para a sua empresa. Fale com o suporte.",
  acao_bloqueada: "Você não tem permissão para mexer na API.",
  url_invalida: "O endereço precisa começar com https://",
};
const quando = (s: string | null) => (s ? new Date(s).toLocaleString("pt-BR", { dateStyle: "short", timeStyle: "short" }) : "nunca");
const copiar = (t: string) => { void navigator.clipboard?.writeText(t); toast("Copiado.", "ok"); };

/** Clientes → empresa → API: chaves para a loja criar pedidos sozinha e o webhook que recebe o andamento. */
export function ApiDaLoja({ empresa, nome }: { empresa: string; nome: string }) {
  const [d, setD] = useState<Dados | null>(null);
  const [erro, setErro] = useState<string | null>(null);
  const [nova, setNova] = useState<string | null>(null);
  const [url, setUrl] = useState("");
  const [eventos, setEventos] = useState<string[]>([]);
  const [salvando, setSalvando] = useState(false);

  const traduz = (m: string) => ERROS[Object.keys(ERROS).find((k) => m.includes(k)) ?? ""] ?? "Não deu agora. Tente de novo.";
  const carregar = useCallback(async () => {
    const { data, error } = await supabase().rpc("api_da_empresa", { p_empresa: empresa });
    if (error) { setErro(traduz(error.message)); return; }
    const x = data as Dados;
    setD(x); setErro(null);
    setUrl(x.webhook?.url ?? "");
    setEventos(x.webhook?.eventos ?? ["recebido", "aprovado", "em_rota", "concluido", "cancelado", "recusado"]);
  }, [empresa]);
  useEffect(() => { void carregar(); }, [carregar]);

  async function criar() {
    const { data, error } = await supabase().rpc("api_criar_chave", { p_empresa: empresa, p_nome: nome });
    if (error) return toast(traduz(error.message), "erro");
    setNova((data as { chave: string }).chave);
    void carregar();
  }
  async function revogar(id: string) {
    const { error } = await supabase().rpc("api_revogar_chave", { p_chave: id });
    if (error) return toast(traduz(error.message), "erro");
    toast("Chave cancelada. A loja deixa de acessar com ela na hora.", "ok");
    void carregar();
  }
  async function salvarGancho(novoSegredo = false) {
    setSalvando(true);
    const { error } = await supabase().rpc("api_definir_webhook", { p_empresa: empresa, p_url: url.trim(), p_eventos: eventos, p_ativo: true, p_novo_segredo: novoSegredo });
    setSalvando(false);
    if (error) return toast(traduz(error.message), "erro");
    toast(url.trim() ? "Webhook salvo." : "Webhook removido.", "ok");
    void carregar();
  }

  if (erro) return <p className="dica">{erro}</p>;
  if (!d) return <p className="dica">Carregando…</p>;
  const ativas = d.chaves.filter((k) => !k.revogada_em);
  return (
    <div className="api-loja">
      <p className="dica">A loja cria e acompanha pedidos sozinha, sem passar pelo site. Os pedidos entram como se {nome} tivesse pedido pelo site e seguem as mesmas regras. Como usar: <a href="/desenvolvedores" target="_blank" rel="noreferrer">guia da API</a>.</p>
      {!d.tem_acesso && <p className="aviso">Esta empresa ainda não tem conta de cliente. Crie uma em Acessos antes de gerar a chave.</p>}

      <section className="bloco">
        <div className="api-titulo"><KeyRound size={16} aria-hidden /><strong>Chaves de API</strong>
          <button type="button" className="botao-ouro pequeno" disabled={!d.tem_acesso} onClick={criar}><Plus size={14} aria-hidden /> Nova chave</button></div>
        {nova && (
          <div className="api-nova">
            <p>Copie agora e mande para a loja por um canal seguro. Ela não aparece de novo.</p>
            <code>{nova}</code>
            <div className="api-acoes"><button type="button" className="botao-vidro" onClick={() => copiar(nova)}><Copy size={14} aria-hidden /> Copiar</button>
              <button type="button" className="botao-texto" onClick={() => setNova(null)}>Já copiei</button></div>
          </div>
        )}
        {d.chaves.length === 0 ? <p className="dica">Nenhuma chave ainda.</p> : (
          <ul className="api-lista">
            {d.chaves.map((k) => (
              <li key={k.id} className={k.revogada_em ? "revogada" : undefined}>
                <span><code>{k.prefixo}…</code> · criada {quando(k.criada_em)} · último uso {quando(k.ultimo_uso)} · {k.usos} chamadas{k.revogada_em ? ` · cancelada ${quando(k.revogada_em)}` : ""}</span>
                {!k.revogada_em && <button type="button" className="botao-texto perigo" onClick={() => revogar(k.id)}><Ban size={14} aria-hidden /> Cancelar</button>}
              </li>
            ))}
          </ul>
        )}
        {ativas.length > 1 && <p className="dica">Há {ativas.length} chaves ativas. Cancele as que a loja não usa mais.</p>}
      </section>

      <section className="bloco">
        <div className="api-titulo"><Webhook size={16} aria-hidden /><strong>Webhook (avisos de andamento)</strong></div>
        <p className="dica">A cada mudança de status do pedido, mandamos um POST para este endereço.</p>
        <label className="campo"><span>Endereço (https)</span><input type="url" placeholder="https://loja.com.br/delibra/webhook" value={url} onChange={(e) => setUrl(e.target.value)} /></label>
        <div className="linha-chips">
          {EVENTOS.map(([k, r]) => (
            <button key={k} type="button" className={`chip${eventos.includes(k) ? " ativo" : ""}`} onClick={() => setEventos(eventos.includes(k) ? eventos.filter((x) => x !== k) : [...eventos, k])}>{r}</button>
          ))}
        </div>
        {d.webhook && (
          <p className="dica">Segredo para conferir a assinatura: <code>{d.webhook.segredo}</code>{" "}
            <button type="button" className="botao-texto" onClick={() => copiar(d.webhook!.segredo)}><Copy size={12} aria-hidden /> Copiar</button>
            <br />Último envio: {quando(d.webhook.ultimo_envio)}{d.webhook.ultimo_status ? ` (${d.webhook.ultimo_status})` : ""}</p>
        )}
        <div className="api-acoes">
          <button type="button" className="botao-ouro" disabled={salvando} onClick={() => salvarGancho(false)}>{url.trim() ? "Salvar webhook" : "Remover webhook"}</button>
          {d.webhook && <button type="button" className="botao-vidro" disabled={salvando} onClick={() => salvarGancho(true)}><RefreshCw size={14} aria-hidden /> Trocar o segredo</button>}
        </div>
      </section>
    </div>
  );
}

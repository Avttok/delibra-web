"use client";

import { useEffect, useState } from "react";
import { supabase } from "@/lib/supabase/client";
import { CheckCircle2, Mail, MessageCircle, Plug, Receipt, Wallet } from "lucide-react";
import { comSessao } from "@/features/pagamentos/Recebimentos";

type Modulo = { chave: string; nome: string; area: string; variavel: string; descricao: string; conectado: boolean; extras?: string[] };
const ICONE: Record<string, typeof Wallet> = { Pagamentos: Wallet, "Nota fiscal": Receipt, "E-mail": Mail, WhatsApp: MessageCircle };

/** Dev: módulos prontos e desligados. Conectar = pôr a chave no Vercel e escolher o provedor em Ajustes → Sistema → Integrações. */
type AvisoFila = { id: number; canal: string; para: string | null; assunto: string | null; status: string; erro: string | null; tentativas: number; criado_em: string; empresa: string | null };
const ROT_STATUS: Record<string, string> = { pendente: "Na fila", enviando: "Enviando", enviado: "Enviado", erro: "Erro", sem_conexao: "Sem conexão" };

/** O que os módulos mandaram (ou tentaram mandar): e-mails, WhatsApp e notas. */
function FilaAvisos() {
  const [l, setL] = useState<AvisoFila[] | null>(null);
  useEffect(() => { void supabase().rpc("dev_avisos_externos", { p_limite: 100 }).then(({ data }) => setL((data ?? []) as AvisoFila[])); }, []);
  return (
    <section className="bloco">
      <span className="rotulo"><Mail size={12} aria-hidden /> Fila de envios</span>
      {l === null ? <p className="dica">Carregando…</p> : l.length === 0 ? <p className="dica">Nada saiu ainda. Os envios entram aqui quando um módulo está conectado e ligado em Ajustes.</p> : (
        <div className="dev-rolagem"><table className="dev-tabela"><thead><tr><th>Quando</th><th>Tipo</th><th>Para</th><th>Assunto</th><th>Situação</th></tr></thead>
          <tbody>{l.map((a) => <tr key={a.id} title={a.erro ?? undefined}><td>{new Date(a.criado_em).toLocaleString("pt-BR", { dateStyle: "short", timeStyle: "short" })}</td>
            <td>{a.canal === "email" ? "E-mail" : a.canal === "whatsapp" ? "WhatsApp" : "Nota"}</td><td>{a.para ?? "—"}</td><td>{a.assunto ?? "—"}</td>
            <td className={a.status === "erro" ? "erro" : ""}>{ROT_STATUS[a.status] ?? a.status}{a.tentativas > 1 ? ` (${a.tentativas}×)` : ""}</td></tr>)}</tbody></table></div>
      )}
    </section>
  );
}

export function IntegracoesDev() {
  const [lista, setLista] = useState<Modulo[] | null>(null);
  const [erro, setErro] = useState<string | null>(null);
  useEffect(() => {
    void comSessao("/api/integracoes/status", {}).then((r) => {
      if (Array.isArray(r.modulos)) setLista(r.modulos as Modulo[]); else setErro("Não deu para ver os módulos agora.");
    }).catch(() => setErro("Não deu para ver os módulos agora."));
  }, []);
  const areas = [...new Set((lista ?? []).map((m) => m.area))];
  return (
    <div className="integracoes">
      <p className="dica" style={{ margin: 0 }}>
        Cada módulo já está pronto e fica desligado até você conectar: crie a variável no Vercel (Settings → Environment Variables) com a chave do provedor
        e escolha o provedor em Ajustes → Sistema → Integrações. Não mande chaves no chat nem coloque no GitHub.
      </p>
      {erro && <p className="erro">{erro}</p>}
      {areas.map((a) => {
        const I = ICONE[a] ?? Plug;
        return (
          <section key={a} className="bloco">
            <span className="rotulo"><I size={12} aria-hidden /> {a}</span>
            {(lista ?? []).filter((m) => m.area === a).map((m) => (
              <div key={m.chave} className="integracao">
                <div><strong>{m.nome}</strong><span className="dica">{m.descricao}</span>
                  <span className="dica">Variável no Vercel: <code>{m.variavel}</code>{m.extras?.length ? <> · também: {m.extras.join(" · ")}</> : null}</span></div>
                {m.conectado
                  ? <span className="selo selo-pago"><CheckCircle2 size={11} aria-hidden /> CONECTADO</span>
                  : <span className="selo" title={`Variável no Vercel: ${m.variavel}`}><Plug size={11} aria-hidden /> CONECTAR DEPOIS · {m.variavel}</span>}
              </div>
            ))}
          </section>
        );
      })}
      <FilaAvisos />
    </div>
  );
}

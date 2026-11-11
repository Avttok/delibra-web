"use client";

import { useEffect, useState } from "react";
import { CheckCircle2, Mail, MessageCircle, Plug, Receipt, Wallet } from "lucide-react";
import { comSessao } from "@/features/pagamentos/Recebimentos";

type Modulo = { chave: string; nome: string; area: string; variavel: string; descricao: string; conectado: boolean };
const ICONE: Record<string, typeof Wallet> = { Pagamentos: Wallet, "Nota fiscal": Receipt, "E-mail": Mail, WhatsApp: MessageCircle };

/** Dev: módulos prontos e desligados. Conectar = pôr a chave no Vercel e escolher o provedor em Ajustes → Sistema → Integrações. */
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
                <div><strong>{m.nome}</strong><span className="dica">{m.descricao}</span></div>
                {m.conectado
                  ? <span className="selo selo-pago"><CheckCircle2 size={11} aria-hidden /> CONECTADO</span>
                  : <span className="selo" title={`Variável no Vercel: ${m.variavel}`}><Plug size={11} aria-hidden /> CONECTAR DEPOIS · {m.variavel}</span>}
              </div>
            ))}
          </section>
        );
      })}
    </div>
  );
}

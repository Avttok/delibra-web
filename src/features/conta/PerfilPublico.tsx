"use client";

import { useEffect, useState } from "react";
import { Bike, CalendarDays, Clock, MapPin, MapPinned, Package2, Route, Ruler, X } from "lucide-react";
import { supabase } from "@/lib/supabase/client";
import { CONQUISTAS, ganha, type Stats } from "@/features/equipe/Conquistas";
import { CARGO } from "./Cargos";

interface Perfil {
  id: string; nome: string; foto: string | null; oculto?: boolean; cargo: keyof typeof CARGO; motoboy: boolean; status?: string | null;
  desde?: string; empresa?: string | null; fechado?: boolean; numeros?: Stats; mostra_numeros?: boolean; mostra_conquistas?: boolean;
  veiculo?: { tipo?: string; modelo?: string; cor?: string; ano?: number; placa?: string | null }; regioes?: { bairro: string; paradas: number }[];
  penalidade_pontos?: number; suspenso_ate?: string | null;
}

const STATUS: Record<string, [string, string]> = { disponivel: ["Online", "#22c55e"], em_corrida: ["Em rota", "var(--ouro)"], offline: ["Offline", "var(--texto-3)"] };

/** Perfil completo de alguém da equipe (abre do chat): números, conquistas, veículo e bairros (cada parte segue os ajustes). */
export function PerfilPublico({ id, onFechar }: { id: string; onFechar: () => void }) {
  const [p, setP] = useState<Perfil | null>(null);
  const [erro, setErro] = useState<string | null>(null);
  useEffect(() => {
    void supabase().rpc("perfil_publico", { p_id: id }).then(({ data, error }) => {
      if (error) setErro(error.message.includes("sem_permissao") ? "Você não tem acesso a este perfil." : "Não deu para abrir o perfil.");
      else setP(data as Perfil);
    });
  }, [id]);
  useEffect(() => {
    const esc = (e: KeyboardEvent) => e.key === "Escape" && onFechar();
    window.addEventListener("keydown", esc);
    return () => window.removeEventListener("keydown", esc);
  }, [onFechar]);
  const cargo = p ? CARGO[p.cargo] ?? CARGO.motoboy : null;
  const st = p?.status ? STATUS[p.status] ?? STATUS.offline : null;
  const n = p?.numeros;
  const num = (k: string) => Number((n?.[k] as number | undefined) ?? 0).toLocaleString("pt-BR", { maximumFractionDigits: 0 });
  return (
    <div className="modal-fundo" onMouseDown={(e) => e.target === e.currentTarget && onFechar()}>
      <div className="modal vidro entrar perfil-publico" role="dialog" aria-label={p?.nome ?? "Perfil"}>
        <button className="botao-icone modal-fechar" onClick={onFechar} aria-label="Fechar"><X size={17} /></button>
        {erro && <p className="erro">{erro}</p>}
        {!p && !erro && <p className="dica">Carregando…</p>}
        {p && <>
          <div className="perfil-cabeca">
            <span className="perfil-foto" style={{ backgroundImage: p.foto && !p.oculto ? `url("${p.foto}")` : undefined }}>
              {(!p.foto || p.oculto) && <span>{p.nome.charAt(0)}</span>}
              {st && <i style={{ background: st[1] }} aria-label={st[0]} />}
            </span>
            <strong className="display">{p.nome}</strong>
            <span className="linha-botoes" style={{ justifyContent: "center" }}>
              {cargo && <span className="selo" style={{ color: cargo.cor }}><cargo.icone size={11} aria-hidden /> {cargo.rotulo}</span>}
              {st && <span className="selo" style={{ color: st[1] }}>{st[0]}</span>}
            </span>
            {p.desde && <span className="dica"><CalendarDays size={12} aria-hidden /> Na equipe desde {new Date(p.desde).toLocaleDateString("pt-BR")}{p.empresa ? ` · ${p.empresa}` : ""}</span>}
          </div>
          {p.fechado && <p className="dica">O gestor deixou os perfis fechados: só nome e foto aparecem.</p>}
          {n && p.mostra_numeros && (
            <div className="perfil-numeros">
              <div><Route size={15} aria-hidden /><strong>{num("corridas")}</strong><small>rotas</small></div>
              <div><Package2 size={15} aria-hidden /><strong>{num("entregas")}</strong><small>entregas</small></div>
              <div><Ruler size={15} aria-hidden /><strong>{num("km")}</strong><small>km</small></div>
              <div><Clock size={15} aria-hidden /><strong>{num("horas_online")}</strong><small>horas online</small></div>
            </div>
          )}
          {n && p.mostra_conquistas && (
            <div className="conquistas-grade perfil-medalhas">
              {[...CONQUISTAS.filter((c) => ganha(n, c)), ...CONQUISTAS.filter((c) => !ganha(n, c))].slice(0, 12).map((c) => {
                const ok = ganha(n, c); const I = c.icone;
                return <span key={c.chave} className={`medalha${ok ? " ganha" : ""}`} style={{ ["--cor" as string]: c.cor }} title={c.descricao}>
                  <span className="medalha-disco"><I size={22} aria-hidden /></span><span className="medalha-nome">{c.nome}</span></span>;
              })}
            </div>
          )}
          {p.veiculo && (p.veiculo.modelo || p.veiculo.cor || p.veiculo.placa) && (
            <p className="perfil-linha"><Bike size={15} aria-hidden /> {[p.veiculo.modelo, p.veiculo.cor, p.veiculo.ano].filter(Boolean).join(" · ") || "Veículo"}{p.veiculo.placa ? <strong className="placa-mini">{p.veiculo.placa}</strong> : null}</p>
          )}
          {(p.regioes?.length ?? 0) > 0 && (
            <div className="perfil-linha"><MapPinned size={15} aria-hidden /> Onde mais entrega:
              <span className="linha-botoes">{p.regioes!.map((r) => <span key={r.bairro} className="chip"><MapPin size={12} aria-hidden /> {r.bairro} · {r.paradas}</span>)}</span>
            </div>
          )}
          {Number(p.penalidade_pontos) > 0 && <p className="erro" style={{ margin: 0 }}>{Number(p.penalidade_pontos).toLocaleString("pt-BR")} pts de penalidade na janela{p.suspenso_ate ? " · suspenso" : ""}</p>}
        </>}
      </div>
    </div>
  );
}

"use client";

import { useEffect, useMemo, useState } from "react";
import {
  Ban, BellRing, CalendarCheck, CalendarClock, CalendarX, TriangleAlert, CheckCircle2, CircleX, Clock, FlaskConical, Hand, MapPin, PackageCheck, PackagePlus, Repeat, Route, Trash2, Wallet, type LucideIcon,
} from "lucide-react";
import { supabase } from "@/lib/supabase/client";
import { moeda } from "@/features/precos/estrategias";
import { useModoTeste } from "@/features/teste/modoTeste";

interface Item {
  quando: string;
  tipo: string;
  dados: Record<string, unknown>;
  fez: boolean;
  corrida_id: string | null;
  numero: number | null;
  teste: boolean | null;
  status_corrida: string | null;
  ganho: number | null;
  valor: number | null;
}

interface Resumo {
  criadas: number; criadas_teste: number; concluidas: number; concluidas_teste: number;
  canceladas_com_ele: number; cancelou: number; aceitas: number; recusadas: number; expiradas: number;
  excluiu: number; ganhos: number; ganhos_teste: number; km_rodados: number;
}

type Filtro = "tudo" | "criadas" | "concluidas" | "canceladas" | "ofertas" | "apagadas";
const FILTROS: [Filtro, string][] = [
  ["tudo", "Tudo"], ["criadas", "Criadas"], ["concluidas", "Concluídas"], ["canceladas", "Canceladas"], ["ofertas", "Corridas recebidas"], ["apagadas", "Apagadas"],
];
const GRUPO: Record<string, Filtro> = {
  criada: "criadas", concluida: "concluidas", parada_concluida: "concluidas", chegou: "concluidas", cancelada: "canceladas",
  oferta_enviada: "ofertas", oferta_recusada: "ofertas", oferta_expirada: "ofertas", aceita: "ofertas", redespachada: "ofertas", excluida: "apagadas",
  reservada: "ofertas", reserva_cancelada: "ofertas", reagendada: "criadas", planejada_atrasada: "ofertas",
};

/** Como cada evento aparece na linha do tempo. */
function descrever(i: Item): { icone: LucideIcon; cor: string; texto: string; extra?: string } {
  const n = i.numero != null ? (i.teste ? `T${i.numero}` : `#${i.numero}`) : "";
  const motivo = typeof i.dados?.motivo === "string" && i.dados.motivo ? `Motivo: ${i.dados.motivo}` : undefined;
  const km = typeof i.dados?.distancia_m === "number" ? `${(Number(i.dados.distancia_m) / 1000).toLocaleString("pt-BR", { maximumFractionDigits: 1 })} km até a coleta` : undefined;
  switch (i.tipo) {
    case "criada": return { icone: PackagePlus, cor: "var(--ouro)", texto: `Criou a corrida ${n}`, extra: i.valor != null ? moeda(i.valor) : undefined };
    case "cancelada": return i.fez
      ? { icone: Ban, cor: "var(--vermelho)", texto: `Cancelou a corrida ${n}`, extra: motivo }
      : { icone: Ban, cor: "var(--vermelho)", texto: `A corrida ${n} foi cancelada pelo gestor`, extra: motivo };
    case "redespachada": return { icone: Repeat, cor: "var(--texto-2)", texto: i.fez ? `Relançou a corrida ${n}` : `Recebeu a corrida ${n} direto do gestor` };
    case "oferta_enviada": return { icone: BellRing, cor: "var(--ouro-claro)", texto: `Recebeu a corrida ${n}`, extra: km };
    case "oferta_recusada": return { icone: CircleX, cor: "var(--vermelho)", texto: `Recusou a corrida ${n}` };
    case "oferta_expirada": return { icone: Clock, cor: "var(--texto-3)", texto: `Não respondeu a corrida ${n} a tempo` };
    case "aceita": {
      const fc = Number(i.dados?.fator_coleta ?? 0);
      return { icone: Hand, cor: "var(--ouro)", texto: `Aceitou a corrida ${n}`, extra: [km, fc > 0 ? `acréscimo +${fc.toLocaleString("pt-BR")}×` : ""].filter(Boolean).join(" · ") || undefined };
    }
    case "chegou": return { icone: MapPin, cor: "var(--texto-2)", texto: `Chegou no local (corrida ${n})` };
    case "parada_concluida": return { icone: PackageCheck, cor: "var(--texto-2)", texto: `Concluiu uma parada (corrida ${n})` };
    case "concluida": return { icone: CheckCircle2, cor: "var(--verde)", texto: i.fez ? `Concluiu a corrida ${n}` : `Corrida ${n} concluída`, extra: i.ganho != null ? `Ganhou ${moeda(i.ganho)}` : undefined };
    case "reservada": return i.fez
      ? { icone: CalendarCheck, cor: "#60a5fa", texto: i.dados?.pelo_gestor ? `Reservou a corrida planejada ${n} para um motoboy` : `Reservou a corrida planejada ${n}` }
      : { icone: CalendarCheck, cor: "#60a5fa", texto: `Recebeu a reserva da corrida planejada ${n} (pelo gestor)` };
    case "reserva_cancelada": return i.fez && !i.dados?.pelo_gestor
      ? { icone: CalendarX, cor: "var(--texto-2)", texto: `Desistiu da corrida planejada ${n}`, extra: typeof i.dados?.motivo === "string" ? `Motivo: ${i.dados.motivo}` : undefined }
      : { icone: CalendarX, cor: "var(--texto-2)", texto: i.fez ? `Liberou a reserva da corrida ${n}` : `A reserva da corrida ${n} foi liberada pelo gestor` };
    case "reagendada": return { icone: CalendarClock, cor: "var(--texto-2)", texto: `Mudou o horário da corrida ${n}` };
    case "planejada_atrasada": return { icone: TriangleAlert, cor: "var(--vermelho)", texto: `Não iniciou a corrida planejada ${n} no horário` };
    case "excluida": return { icone: Trash2, cor: "var(--vermelho)", texto: `Apagou a corrida ${n}`, extra: motivo };
    default: return { icone: Route, cor: "var(--texto-3)", texto: `${i.tipo.replaceAll("_", " ")} ${n}` };
  }
}

const dia = (iso: string) => {
  const d = new Date(iso);
  const hoje = new Date(); hoje.setHours(0, 0, 0, 0);
  const ontem = new Date(hoje); ontem.setDate(ontem.getDate() - 1);
  if (d >= hoje) return "Hoje";
  if (d >= ontem) return "Ontem";
  return d.toLocaleDateString("pt-BR", { weekday: "short", day: "2-digit", month: "short", year: d.getFullYear() === hoje.getFullYear() ? undefined : "numeric" });
};
const hora = (iso: string) => new Date(iso).toLocaleTimeString("pt-BR", { hour: "2-digit", minute: "2-digit" });

export function RegistroMembro({ id }: { id: string }) {
  const { teste } = useModoTeste();
  const [dados, setDados] = useState<{ resumo: Resumo; itens: Item[] } | null>(null);
  const [erro, setErro] = useState<string | null>(null);
  const [filtro, setFiltro] = useState<Filtro>("tudo");
  const [incluirTestes, setIncluirTestes] = useState(teste);

  useEffect(() => { setIncluirTestes(teste); }, [teste]);
  useEffect(() => {
    let vivo = true;
    supabase().rpc("registro_membro", { p_usuario: id, p_limite: 500 }).then(({ data, error }) => {
      if (!vivo) return;
      if (error) setErro(error.message.includes("registro_membro") ? "Rode a migração 0006 no Supabase para ver o registro." : error.message);
      else setDados(data as { resumo: Resumo; itens: Item[] });
    });
    return () => { vivo = false; };
  }, [id]);

  const itens = useMemo(
    () => (dados?.itens ?? []).filter((i) => (incluirTestes ? true : !i.teste) && (filtro === "tudo" || GRUPO[i.tipo] === filtro)),
    [dados, filtro, incluirTestes],
  );
  const porDia = useMemo(() => {
    const m = new Map<string, Item[]>();
    for (const i of itens) { const d = dia(i.quando); m.set(d, [...(m.get(d) ?? []), i]); }
    return [...m.entries()];
  }, [itens]);

  if (erro) return <p className="erro">{erro}</p>;
  if (!dados) return <p className="dica">Carregando registro…</p>;
  const r = dados.resumo;

  const numeros: { rotulo: string; valor: string; icone: LucideIcon; destaque?: boolean }[] = [
    { rotulo: teste ? "Ganhos de teste" : "Ganhos", valor: moeda(teste ? r.ganhos_teste : r.ganhos), icone: Wallet, destaque: true },
    { rotulo: "Concluídas", valor: String(teste ? r.concluidas_teste : r.concluidas), icone: CheckCircle2 },
    { rotulo: "Criadas", valor: String(teste ? r.criadas_teste : r.criadas), icone: PackagePlus },
    { rotulo: "Aceitas", valor: String(r.aceitas), icone: Hand },
    { rotulo: "Recusadas", valor: String(r.recusadas), icone: CircleX },
    { rotulo: "Expiradas", valor: String(r.expiradas), icone: Clock },
    { rotulo: "Canceladas", valor: String(r.cancelou + r.canceladas_com_ele), icone: Ban },
    { rotulo: "Apagadas", valor: String(r.excluiu), icone: Trash2 },
    { rotulo: "Km rodados", valor: Number(r.km_rodados).toLocaleString("pt-BR", { maximumFractionDigits: 1 }), icone: Route },
  ];

  return (
    <div className="registro">
      <div className="registro-numeros">
        {numeros.map(({ rotulo, valor, icone: I, destaque }) => (
          <div key={rotulo} className={`registro-numero ${destaque ? "destaque" : ""}`}>
            <span className="rotulo"><I size={12} aria-hidden /> {rotulo}</span>
            <strong className={destaque ? "texto-grad" : ""}>{valor}</strong>
          </div>
        ))}
      </div>

      <div className="registro-filtros">
        <div className="filtro">
          {FILTROS.map(([v, t]) => <button key={v} className={filtro === v ? "ativo" : ""} onClick={() => setFiltro(v)}>{t}</button>)}
        </div>
        <label className="opcao registro-testes">
          <FlaskConical size={14} aria-hidden style={{ color: "#a78bfa" }} />
          <span>Incluir testes</span>
          <input type="checkbox" checked={incluirTestes} onChange={(e) => setIncluirTestes(e.target.checked)} />
        </label>
      </div>

      {porDia.length === 0 && <p className="vazio">Nada por aqui ainda.</p>}
      {porDia.map(([d, lista]) => (
        <section key={d} className="registro-dia">
          <span className="rotulo">{d}</span>
          <ol className="linha-tempo">
            {lista.map((i, k) => {
              const { icone: I, cor, texto, extra } = descrever(i);
              return (
                <li key={`${i.quando}-${k}`}>
                  <span className="linha-tempo-icone" style={{ color: cor }}><I size={15} aria-hidden /></span>
                  <div className="linha-tempo-texto">
                    <span>
                      {texto}
                      {i.teste && <span className="selo" style={{ color: "#a78bfa", marginLeft: 6 }}><FlaskConical size={10} aria-hidden /> teste</span>}
                    </span>
                    {extra && <small>{extra}</small>}
                  </div>
                  <time dateTime={i.quando}>{hora(i.quando)}</time>
                </li>
              );
            })}
          </ol>
        </section>
      ))}
    </div>
  );
}

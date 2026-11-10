"use client";

import { useCallback, useEffect, useState } from "react";
import { Award, BadgeCheck, Bike, Bird, Cake, CalendarCheck, CalendarClock, CalendarDays, Camera, Clock, Coins, Crown, Flag, Flame, Footprints, Gauge, Gem, Globe, Handshake, Heart, Hourglass, Infinity as Infinito, Layers, ListChecks, Map as Mapa, Medal, Milestone, Moon, MoonStar, Mountain, Navigation, Package, PackageCheck, PartyPopper, Power, Rabbit, Radar, Rocket, Route, Shield, ShieldAlert, Signature, Siren, Star, Sun, SunMoon, Sunrise, Swords, Target, Timer, Trophy, Users, Wallet, Zap, Lock, Trophy as TrophyIcon, type LucideIcon } from "lucide-react";
import { supabase } from "@/lib/supabase/client";
import { toast } from "@/features/ui/toast";
import { useConta } from "@/features/conta/conta";

/** Conquistas dos motoboys: o mesmo catálogo do app (core/perfil/Conquistas.kt). */
export interface Conquista { chave: string; nome: string; descricao: string; stat: string; meta: number; icone: LucideIcon; cor: string; unidade: string }

export const CONQUISTAS: Conquista[] = [
  { chave: "corrida_1", nome: "Primeira corrida", descricao: "Concluiu a primeira corrida. O começo de tudo!", stat: "corridas", meta: 1, icone: Flag, cor: "#34D399", unidade: "corrida" },
  { chave: "corrida_10", nome: "Pegando o ritmo", descricao: "Concluiu 10 corridas.", stat: "corridas", meta: 10, icone: Bike, cor: "#2DD4BF", unidade: "corridas" },
  { chave: "corrida_50", nome: "Veterano", descricao: "Concluiu 50 corridas.", stat: "corridas", meta: 50, icone: Medal, cor: "#CD7F32", unidade: "corridas" },
  { chave: "corrida_100", nome: "Centurião", descricao: "Concluiu 100 corridas.", stat: "corridas", meta: 100, icone: Award, cor: "#C0C7D0", unidade: "corridas" },
  { chave: "corrida_250", nome: "Máquina", descricao: "Concluiu 250 corridas.", stat: "corridas", meta: 250, icone: Trophy, cor: "#FACC15", unidade: "corridas" },
  { chave: "corrida_500", nome: "Lenda das ruas", descricao: "Concluiu 500 corridas.", stat: "corridas", meta: 500, icone: Crown, cor: "#A855F7", unidade: "corridas" },
  { chave: "corrida_1000", nome: "Mil e uma", descricao: "Concluiu 1.000 corridas. Poucos chegam aqui.", stat: "corridas", meta: 1000, icone: Gem, cor: "#22D3EE", unidade: "corridas" },
  { chave: "entrega_25", nome: "Entregador", descricao: "Fez 25 entregas.", stat: "entregas", meta: 25, icone: PackageCheck, cor: "#A3E635", unidade: "entregas" },
  { chave: "entrega_100", nome: "Caixa cheia", descricao: "Fez 100 entregas.", stat: "entregas", meta: 100, icone: PackageCheck, cor: "#F59E0B", unidade: "entregas" },
  { chave: "entrega_500", nome: "Carga pesada", descricao: "Fez 500 entregas.", stat: "entregas", meta: 500, icone: Package, cor: "#FB923C", unidade: "entregas" },
  { chave: "entrega_1000", nome: "Foguete postal", descricao: "Fez 1.000 entregas.", stat: "entregas", meta: 1000, icone: Rocket, cor: "#F87171", unidade: "entregas" },
  { chave: "entrega_5000", nome: "Infinito", descricao: "Fez 5.000 entregas.", stat: "entregas", meta: 5000, icone: Infinito, cor: "#A855F7", unidade: "entregas" },
  { chave: "km_10", nome: "Primeiros passos", descricao: "Rodou 10 km em corridas.", stat: "km", meta: 10, icone: Footprints, cor: "#34D399", unidade: "km" },
  { chave: "km_100", nome: "Marco 100", descricao: "Rodou 100 km em corridas.", stat: "km", meta: 100, icone: Milestone, cor: "#60A5FA", unidade: "km" },
  { chave: "km_500", nome: "Serra acima", descricao: "Rodou 500 km em corridas.", stat: "km", meta: 500, icone: Mountain, cor: "#2DD4BF", unidade: "km" },
  { chave: "km_1000", nome: "Mil quilômetros", descricao: "Rodou 1.000 km em corridas.", stat: "km", meta: 1000, icone: Gauge, cor: "#FACC15", unidade: "km" },
  { chave: "km_5000", nome: "Estradeiro", descricao: "Rodou 5.000 km em corridas.", stat: "km", meta: 5000, icone: Route, cor: "#FB923C", unidade: "km" },
  { chave: "km_10000", nome: "Volta ao Brasil", descricao: "Rodou 10.000 km em corridas: quase a costa do Brasil inteira.", stat: "km", meta: 10000, icone: Globe, cor: "#22D3EE", unidade: "km" },
  { chave: "online_1", nome: "Ligado", descricao: "Ficou 1 hora online.", stat: "horas_online", meta: 1, icone: Power, cor: "#34D399", unidade: "h" },
  { chave: "online_10", nome: "De plantão", descricao: "Ficou 10 horas online.", stat: "horas_online", meta: 10, icone: Timer, cor: "#60A5FA", unidade: "h" },
  { chave: "online_50", nome: "Sempre a postos", descricao: "Ficou 50 horas online.", stat: "horas_online", meta: 50, icone: Clock, cor: "#818CF8", unidade: "h" },
  { chave: "online_100", nome: "Radar ligado", descricao: "Ficou 100 horas online.", stat: "horas_online", meta: 100, icone: Radar, cor: "#2DD4BF", unidade: "h" },
  { chave: "online_500", nome: "Incansável", descricao: "Ficou 500 horas online.", stat: "horas_online", meta: 500, icone: Hourglass, cor: "#F59E0B", unidade: "h" },
  { chave: "online_1000", nome: "Energia infinita", descricao: "Ficou 1.000 horas online.", stat: "horas_online", meta: 1000, icone: Zap, cor: "#FACC15", unidade: "h" },
  { chave: "conta_7", nome: "Bem-vindo", descricao: "Uma semana de Delibra.", stat: "dias_conta", meta: 7, icone: CalendarCheck, cor: "#34D399", unidade: "dias" },
  { chave: "conta_30", nome: "Um mês de casa", descricao: "Um mês de Delibra.", stat: "dias_conta", meta: 30, icone: CalendarDays, cor: "#60A5FA", unidade: "dias" },
  { chave: "conta_90", nome: "Da família", descricao: "Três meses de Delibra.", stat: "dias_conta", meta: 90, icone: Heart, cor: "#F472B6", unidade: "dias" },
  { chave: "conta_180", nome: "Meio ano", descricao: "Seis meses de Delibra.", stat: "dias_conta", meta: 180, icone: BadgeCheck, cor: "#818CF8", unidade: "dias" },
  { chave: "conta_365", nome: "Aniversário", descricao: "Um ano de Delibra. Parabéns!", stat: "dias_conta", meta: 365, icone: Cake, cor: "#F472B6", unidade: "dias" },
  { chave: "conta_730", nome: "Raiz", descricao: "Dois anos de Delibra.", stat: "dias_conta", meta: 730, icone: Crown, cor: "#FACC15", unidade: "dias" },
  { chave: "ativos_30", nome: "Presença", descricao: "Trabalhou em 30 dias diferentes.", stat: "dias_ativos", meta: 30, icone: CalendarClock, cor: "#2DD4BF", unidade: "dias" },
  { chave: "ativos_100", nome: "Cem dias de rua", descricao: "Trabalhou em 100 dias diferentes.", stat: "dias_ativos", meta: 100, icone: Star, cor: "#FACC15", unidade: "dias" },
  { chave: "seq_3", nome: "Esquentando", descricao: "Corridas em 3 dias seguidos.", stat: "sequencia", meta: 3, icone: Flame, cor: "#FB923C", unidade: "dias seguidos" },
  { chave: "seq_7", nome: "Semana cheia", descricao: "Corridas em 7 dias seguidos.", stat: "sequencia", meta: 7, icone: Flame, cor: "#F87171", unidade: "dias seguidos" },
  { chave: "seq_15", nome: "Pegando fogo", descricao: "Corridas em 15 dias seguidos.", stat: "sequencia", meta: 15, icone: Flame, cor: "#F472B6", unidade: "dias seguidos" },
  { chave: "seq_30", nome: "Chama eterna", descricao: "Corridas em 30 dias seguidos.", stat: "sequencia", meta: 30, icone: Flame, cor: "#A855F7", unidade: "dias seguidos" },
  { chave: "dia_5", nome: "Coelho", descricao: "5 corridas num dia só.", stat: "melhor_dia", meta: 5, icone: Rabbit, cor: "#A3E635", unidade: "no melhor dia" },
  { chave: "dia_10", nome: "Dia de foguete", descricao: "10 corridas num dia só.", stat: "melhor_dia", meta: 10, icone: Rocket, cor: "#60A5FA", unidade: "no melhor dia" },
  { chave: "dia_20", nome: "Imparável", descricao: "20 corridas num dia só.", stat: "melhor_dia", meta: 20, icone: Swords, cor: "#F87171", unidade: "no melhor dia" },
  { chave: "rota_5", nome: "Multitarefa", descricao: "5 entregas numa rota só.", stat: "maior_rota", meta: 5, icone: ListChecks, cor: "#818CF8", unidade: "entregas numa rota" },
  { chave: "rota_10", nome: "Malabarista", descricao: "10 entregas numa rota só.", stat: "maior_rota", meta: 10, icone: Layers, cor: "#A855F7", unidade: "entregas numa rota" },
  { chave: "longe_20", nome: "Bate e volta", descricao: "Uma corrida de 20 km ou mais.", stat: "maior_km", meta: 20, icone: Navigation, cor: "#60A5FA", unidade: "km na maior" },
  { chave: "longe_50", nome: "Viajante", descricao: "Uma corrida de 50 km ou mais.", stat: "maior_km", meta: 50, icone: Mapa, cor: "#22D3EE", unidade: "km na maior" },
  { chave: "noite_1", nome: "Turno da noite", descricao: "Concluiu uma corrida depois das 22h.", stat: "noturnas", meta: 1, icone: Moon, cor: "#818CF8", unidade: "noturnas" },
  { chave: "noite_25", nome: "Noturno", descricao: "25 corridas depois das 22h.", stat: "noturnas", meta: 25, icone: MoonStar, cor: "#A855F7", unidade: "noturnas" },
  { chave: "noite_100", nome: "Coruja", descricao: "100 corridas depois das 22h.", stat: "noturnas", meta: 100, icone: Bird, cor: "#F59E0B", unidade: "noturnas" },
  { chave: "madrugada_10", nome: "Vigia da madrugada", descricao: "10 corridas entre meia-noite e 5h.", stat: "madrugada", meta: 10, icone: SunMoon, cor: "#818CF8", unidade: "de madrugada" },
  { chave: "cedo_10", nome: "Madrugador", descricao: "10 corridas entre 5h e 8h.", stat: "cedinho", meta: 10, icone: Sunrise, cor: "#FB923C", unidade: "cedinho" },
  { chave: "fds_10", nome: "Fim de semana na rua", descricao: "10 corridas em sábados ou domingos.", stat: "fim_de_semana", meta: 10, icone: PartyPopper, cor: "#F472B6", unidade: "no fim de semana" },
  { chave: "fds_50", nome: "Sem folga", descricao: "50 corridas em sábados ou domingos.", stat: "fim_de_semana", meta: 50, icone: Sun, cor: "#F59E0B", unidade: "no fim de semana" },
  { chave: "urgente_1", nome: "Sirene", descricao: "Concluiu a primeira corrida urgente.", stat: "urgentes", meta: 1, icone: Siren, cor: "#F87171", unidade: "urgentes" },
  { chave: "urgente_10", nome: "Bombeiro", descricao: "10 corridas urgentes.", stat: "urgentes", meta: 10, icone: Flame, cor: "#FB923C", unidade: "urgentes" },
  { chave: "urgente_50", nome: "Relâmpago", descricao: "50 corridas urgentes.", stat: "urgentes", meta: 50, icone: Zap, cor: "#F59E0B", unidade: "urgentes" },
  { chave: "planejada_10", nome: "Agenda em dia", descricao: "10 corridas planejadas concluídas.", stat: "planejadas", meta: 10, icone: CalendarClock, cor: "#60A5FA", unidade: "planejadas" },
  { chave: "planejada_50", nome: "Pontual", descricao: "50 corridas planejadas concluídas.", stat: "planejadas", meta: 50, icone: Target, cor: "#34D399", unidade: "planejadas" },
  { chave: "perigo_1", nome: "Mão firme", descricao: "Levou uma carga perigosa.", stat: "perigosas", meta: 1, icone: ShieldAlert, cor: "#F59E0B", unidade: "com carga perigosa" },
  { chave: "perigo_10", nome: "Escudo", descricao: "10 corridas com carga perigosa.", stat: "perigosas", meta: 10, icone: Shield, cor: "#F87171", unidade: "com carga perigosa" },
  { chave: "clientes_5", nome: "Bem relacionado", descricao: "Atendeu 5 clientes diferentes.", stat: "clientes", meta: 5, icone: Handshake, cor: "#2DD4BF", unidade: "clientes" },
  { chave: "clientes_20", nome: "Conhecido na cidade", descricao: "Atendeu 20 clientes diferentes.", stat: "clientes", meta: 20, icone: Users, cor: "#818CF8", unidade: "clientes" },
  { chave: "prova_50", nome: "Fotógrafo", descricao: "50 entregas com foto ou assinatura.", stat: "comprovantes", meta: 50, icone: Camera, cor: "#22D3EE", unidade: "comprovantes" },
  { chave: "prova_200", nome: "Tudo assinado", descricao: "200 entregas com foto ou assinatura.", stat: "comprovantes", meta: 200, icone: Signature, cor: "#A855F7", unidade: "comprovantes" },
  { chave: "ganho_100", nome: "Primeiro cem", descricao: "Ganhou R$ 100 em corridas.", stat: "ganhos", meta: 100, icone: Coins, cor: "#A3E635", unidade: "reais" },
  { chave: "ganho_1000", nome: "Mil no bolso", descricao: "Ganhou R$ 1.000 em corridas.", stat: "ganhos", meta: 1000, icone: Wallet, cor: "#34D399", unidade: "reais" },
  { chave: "ganho_10000", nome: "Cofre cheio", descricao: "Ganhou R$ 10.000 em corridas.", stat: "ganhos", meta: 10000, icone: Gem, cor: "#FACC15", unidade: "reais" },
];

export type Stats = Record<string, number | boolean | Record<string, boolean>> & { manuais?: Record<string, boolean> };

const valor = (st: Stats | null, k: string) => Number((st?.[k] as number | undefined) ?? 0);
export const ganha = (st: Stats | null, c: Conquista) => st?.manuais?.[c.chave] ?? valor(st, c.stat) >= c.meta;
const num = (v: number) => v.toLocaleString("pt-BR", { maximumFractionDigits: 1 });

/** Grade de medalhas de um motoboy. O Dev dá, bloqueia ou volta ao automático. */
export function ConquistasMembro({ id }: { id: string }) {
  const conta = useConta();
  const [st, setSt] = useState<Stats | null>(null);
  const [erro, setErro] = useState<string | null>(null);
  const [editando, setEditando] = useState<Conquista | null>(null);
  const carregar = useCallback(async () => {
    const { data, error } = await supabase().rpc("conquistas", { p_motoboy: id });
    if (error) return setErro(error.message.includes("conquistas") ? "Rode a migração das conquistas no banco." : error.message);
    setSt(data as Stats); setErro(null);
  }, [id]);
  useEffect(() => { void carregar(); }, [carregar]);

  async function definir(estado: "ganha" | "bloqueada" | "auto") {
    if (!editando) return;
    const { error } = await supabase().rpc("definir_conquista", { p_perfil: id, p_chave: editando.chave, p_estado: estado });
    if (error) return toast(error.message.includes("definir_conquista") ? "Rode a migração 20261110000007 no banco." : error.message, "erro");
    toast(estado === "ganha" ? "Medalha liberada." : estado === "bloqueada" ? "Medalha bloqueada." : "Volta a valer a estatística.", "ok", { titulo: editando.nome });
    setEditando(null); void carregar();
  }

  if (erro) return <p className="erro">{erro}</p>;
  if (!st) return <p className="dica">Carregando…</p>;
  const lista = [...CONQUISTAS.filter((c) => ganha(st, c)), ...CONQUISTAS.filter((c) => !ganha(st, c))];
  const n = CONQUISTAS.filter((c) => ganha(st, c)).length;
  return (
    <div className="conquistas">
      <div className="conquistas-topo">
        <strong><Trophy size={16} aria-hidden /> Conquistas</strong><span className="espaco" /><span className="texto-grad">{n} de {CONQUISTAS.length}</span>
      </div>
      <p className="dica" style={{ margin: 0, color: conta.dev ? "var(--dev, #f87171)" : undefined }}>
        {conta.dev ? "Dev: clique numa medalha para dar, bloquear ou voltar ao automático." : "Clique numa medalha para ver o que ela significa."}
      </p>
      <div className="conquistas-grade">
        {lista.map((c) => {
          const ok = ganha(st, c); const I = c.icone;
          return (
            <button key={c.chave} type="button" className={`medalha${ok ? " ganha" : ""}`} style={{ ["--cor" as string]: c.cor }}
              onClick={() => conta.dev ? setEditando(c) : toast(ok ? c.descricao : `${c.descricao} Progresso: ${num(valor(st, c.stat))} de ${num(c.meta)} ${c.unidade}.`, ok ? "ok" : "info", { titulo: `${ok ? "🏆" : "🔒"} ${c.nome}` })}>
              <span className="medalha-disco"><I size={24} aria-hidden />{!ok && <span className="medalha-cadeado"><Lock size={11} aria-hidden /></span>}</span>
              <span className="medalha-nome">{c.nome}</span>
            </button>
          );
        })}
      </div>
      {editando && (
        <div className="medalha-editor vidro">
          <strong>{editando.nome}</strong>
          <p className="dica" style={{ margin: 0 }}>{editando.descricao}</p>
          <p className="dica" style={{ margin: 0 }}>Pela estatística: {valor(st, editando.stat) >= editando.meta ? "ganha" : "ainda não"} · agora: {st.manuais?.[editando.chave] === true ? "dada pelo Dev" : st.manuais?.[editando.chave] === false ? "bloqueada pelo Dev" : "automática"}</p>
          <div className="linha-botoes">
            <button className="botao-ouro" onClick={() => definir("ganha")}><Trophy size={15} aria-hidden /> Dar</button>
            <button className="botao-texto" onClick={() => definir("bloqueada")}><Lock size={15} aria-hidden /> Bloquear</button>
            <button className="botao-texto" onClick={() => definir("auto")}>Automático</button>
            <span className="espaco" /><button className="botao-texto" onClick={() => setEditando(null)}>Fechar</button>
          </div>
        </div>
      )}
    </div>
  );
}

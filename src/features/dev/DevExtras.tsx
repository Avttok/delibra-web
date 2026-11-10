"use client";

import { useMemo, useState } from "react";
import { BatteryCharging, BatteryMedium, Bell, BellOff, Bike, Check, ChevronDown, CircleAlert, CirclePlay, Cpu, FlaskConical, MapPin, Pause, Play, Search, ShieldCheck, Signal, Smartphone, Timer, UserRound, Wifi, X } from "lucide-react";
import { supabase } from "@/lib/supabase/client";
import { toast } from "@/features/ui/toast";
import type { Papel } from "@/features/conta/conta";

// ------------------------------------------------------------------ módulos

export interface ModuloLinha { chave: string; nome: string; descricao: string | null; grupo: string; ligado: boolean; papeis: Papel[] | null; ordem: number }
const PAPEIS: { p: Papel; rotulo: string; icone: typeof Bike }[] = [
  { p: "gestor", rotulo: "Gestores", icone: ShieldCheck }, { p: "motoboy", rotulo: "Motoboys", icone: Bike }, { p: "cliente", rotulo: "Clientes", icone: UserRound },
];
const quem = (m: ModuloLinha) => !m.ligado ? "Desligado para todos (você, Dev, continua vendo)" : !m.papeis?.length ? "Ligado para todos" : `Ligado só para ${m.papeis.map((p) => PAPEIS.find((x) => x.p === p)?.rotulo.toLowerCase()).join(" e ")}`;

/** Módulos: cada parte do sistema que dá para desligar, e para quem ela aparece. */
export function ModulosDev({ modulos, onSalvar }: { modulos: ModuloLinha[]; onSalvar: (m: ModuloLinha, ligado: boolean, papeis: Papel[] | null) => void }) {
  const [busca, setBusca] = useState("");
  const [filtro, setFiltro] = useState<"todos" | "ligados" | "desligados" | "limitados">("todos");
  const t = busca.trim().toLowerCase();
  const lista = modulos.filter((m) => (!t || `${m.nome} ${m.descricao ?? ""} ${m.grupo}`.toLowerCase().includes(t))
    && (filtro === "todos" || (filtro === "ligados" && m.ligado) || (filtro === "desligados" && !m.ligado) || (filtro === "limitados" && m.ligado && (m.papeis?.length ?? 0) > 0)));
  const grupos = [...new Set(lista.map((m) => m.grupo))];
  const n = { ligados: modulos.filter((m) => m.ligado).length, desligados: modulos.filter((m) => !m.ligado).length, limitados: modulos.filter((m) => m.ligado && (m.papeis?.length ?? 0) > 0).length };
  return (
    <div className="modulos-dev">
      <div className="modulos-explica">
        <strong>O que é um módulo?</strong> Uma parte do sistema (chat, carteira, pedidos, conquistas…). Desligado, ela some do site e do app para todo mundo — menos para você.
        Ligado, você pode deixar só para alguns cargos (ex.: carteira só para gestores).
      </div>
      <div className="modulos-barra">
        <label className="busca-mini"><Search size={14} aria-hidden /><input placeholder="Buscar módulo" value={busca} onChange={(e) => setBusca(e.target.value)} /></label>
        <div className="filtro">
          {([["todos", `Todos (${modulos.length})`], ["ligados", `Ligados (${n.ligados})`], ["desligados", `Desligados (${n.desligados})`], ["limitados", `Só alguns cargos (${n.limitados})`]] as const).map(([k, r]) => (
            <button key={k} className={filtro === k ? "ativo" : ""} onClick={() => setFiltro(k)}>{r}</button>
          ))}
        </div>
      </div>
      {grupos.map((g) => (
        <section key={g} className="modulos-grupo">
          <span className="rotulo">{g}</span>
          {lista.filter((m) => m.grupo === g).map((m) => {
            const modo = !m.ligado ? "off" : m.papeis?.length ? "alguns" : "todos";
            return (
              <div key={m.chave} className={`modulo-cartao ${modo}`}>
                <div className="modulo-texto">
                  <strong>{m.nome}</strong>
                  {m.descricao && <span className="dica">{m.descricao}</span>}
                  <span className={`modulo-status ${modo}`}>{modo === "off" ? <X size={12} aria-hidden /> : <Check size={12} aria-hidden />} {quem(m)}</span>
                </div>
                <div className="modulo-controles">
                  <div className="segmentado" style={{ gridTemplateColumns: "repeat(3, 1fr)" }} role="radiogroup" aria-label={`Quem vê ${m.nome}`}>
                    <button className={modo === "off" ? "ativo" : ""} onClick={() => onSalvar(m, false, m.papeis)}>Desligado</button>
                    <button className={modo === "todos" ? "ativo" : ""} onClick={() => onSalvar(m, true, null)}>Todos</button>
                    <button className={modo === "alguns" ? "ativo" : ""} onClick={() => onSalvar(m, true, m.papeis?.length ? m.papeis : ["gestor"])}>Só alguns</button>
                  </div>
                  {modo === "alguns" && (
                    <div className="modulo-papeis">
                      {PAPEIS.map(({ p, rotulo, icone: I }) => {
                        const on = Boolean(m.papeis?.includes(p));
                        return (
                          <label key={p} className={`chip${on ? " ativo" : ""}`}>
                            <input type="checkbox" checked={on} onChange={() => {
                              const atual = m.papeis ?? [];
                              const novo = on ? atual.filter((x) => x !== p) : [...atual, p];
                              onSalvar(m, true, novo.length ? novo : null);
                            }} /> <I size={12} aria-hidden /> {rotulo}
                          </label>
                        );
                      })}
                    </div>
                  )}
                </div>
              </div>
            );
          })}
        </section>
      ))}
      {lista.length === 0 && <p className="vazio">Nenhum módulo com esse filtro.</p>}
    </div>
  );
}

// ------------------------------------------------------------------ tarefas (pg_cron)

export interface Tarefa { nome: string; quando: string; ativa: boolean; comando?: string; ultima?: { inicio: string; fim: string | null; status: string; mensagem: string | null } | null; falhas_24h?: number }

const DIAS = ["domingo", "segunda", "terça", "quarta", "quinta", "sexta", "sábado"];
/** "*\/5 * * * *" → "a cada 5 minutos" (o pg_cron usa o horário UTC: o texto já mostra no horário de Brasília). */
export function cronParaTexto(c: string): string {
  const s = c.trim();
  const seg = s.match(/^(\d+)\s+seconds?$/); if (seg) return `a cada ${seg[1]} segundos`;
  const p = s.split(/\s+/);
  if (p.length !== 5) return s;
  const [mi, h, dm, me, ds] = p;
  const brt = (hh: number) => (hh + 21) % 24; // UTC → Brasília (UTC−3)
  const hora = (hh: string, mm: string) => `${String(brt(Number(hh))).padStart(2, "0")}:${mm.padStart(2, "0")}`;
  if (s === "* * * * *") return "a cada minuto";
  let m = mi.match(/^\*\/(\d+)$/);
  if (m && h === "*" && dm === "*" && me === "*" && ds === "*") return `a cada ${m[1]} minutos`;
  m = h.match(/^\*\/(\d+)$/);
  if (m && /^\d+$/.test(mi) && dm === "*" && me === "*" && ds === "*") return `a cada ${m[1]} horas (no minuto ${mi})`;
  if (/^\d+$/.test(mi) && h === "*" && dm === "*" && me === "*" && ds === "*") return `toda hora, no minuto ${mi}`;
  if (/^\d+$/.test(mi) && /^\d+$/.test(h) && me === "*") {
    if (dm === "*" && ds === "*") return `todo dia às ${hora(h, mi)}`;
    if (dm === "*" && /^\d$/.test(ds)) return `${Number(ds) === 0 || Number(ds) === 6 ? "todo" : "toda"} ${DIAS[Number(ds)]} às ${hora(h, mi)}`;
    if (dm === "*" && /^\d-\d$/.test(ds)) return `de ${DIAS[Number(ds[0])]} a ${DIAS[Number(ds[2])]} às ${hora(h, mi)}`;
    if (/^\d+$/.test(dm) && ds === "*") return `todo dia ${dm} do mês às ${hora(h, mi)}`;
  }
  return `${s} (expressão cron, horário UTC)`;
}
const PRESETS: [string, string][] = [["* * * * *", "A cada minuto"], ["*/5 * * * *", "A cada 5 min"], ["*/15 * * * *", "A cada 15 min"], ["0 * * * *", "Toda hora"], ["0 */6 * * *", "A cada 6 h"]];
const paraUtc = (hhmm: string) => { const [h, m] = hhmm.split(":").map(Number); return `${m} ${(h + 3) % 24}`; };

export function TarefasDev({ tarefas, onMudou }: { tarefas: Tarefa[]; onMudou: () => void }) {
  const [aberta, setAberta] = useState<string | null>(null);
  const [cron, setCron] = useState("");
  const [hora, setHora] = useState("03:00");
  const [ocupado, setOcupado] = useState(false);
  async function acao(nome: string, a: "ligar" | "desligar" | "horario" | "rodar", v?: string) {
    if (a === "rodar" && !confirm(`Rodar “${nome}” agora?`)) return;
    setOcupado(true);
    const { error } = await supabase().rpc("dev_tarefa", { p_nome: nome, p_acao: a, p_valor: v ?? null });
    setOcupado(false);
    if (error) return toast(error.message.includes("horario_invalido") ? "Horário inválido: use uma expressão cron de 5 partes (ex.: */5 * * * *)." : error.message.includes("dev_tarefa") ? "Rode a migração 20261110000019." : error.message, "erro");
    toast(a === "rodar" ? "Rodou." : a === "horario" ? "Horário mudado." : a === "ligar" ? "Tarefa ligada." : "Tarefa parada.", "ok");
    onMudou();
  }
  if (!tarefas.length) return <p className="vazio">Nenhuma tarefa automática encontrada (o pg_cron não está ligado neste banco).</p>;
  return (
    <div className="tarefas-dev">
      <p className="dica">Tarefas que o banco roda sozinho (montar rotas, abrir planejadas, faturas…). Os horários aparecem no horário de Brasília.</p>
      {tarefas.map((t) => {
        const ok = t.ultima?.status === "succeeded";
        const ab = aberta === t.nome;
        return (
          <div key={t.nome} className={`tarefa ${t.ativa ? "" : "parada"}`}>
            <div className="tarefa-topo">
              <Timer size={18} aria-hidden />
              <div className="tarefa-texto">
                <strong>{t.nome}</strong>
                <span>{t.ativa ? "Roda " : "Parada · rodaria "}<b>{cronParaTexto(t.quando)}</b></span>
                <span className="dica">
                  {t.ultima ? <>Última vez: {new Date(t.ultima.inicio).toLocaleString("pt-BR")} · {ok ? <span style={{ color: "var(--verde)" }}>deu certo</span> : <span style={{ color: "var(--vermelho)" }}>{t.ultima.status === "failed" ? "falhou" : t.ultima.status}</span>}</> : "Ainda não rodou"}
                  {Number(t.falhas_24h) > 0 && <span style={{ color: "var(--vermelho)" }}> · {t.falhas_24h} falha{Number(t.falhas_24h) > 1 ? "s" : ""} em 24 h</span>}
                </span>
              </div>
              <input type="checkbox" role="switch" checked={t.ativa} disabled={ocupado} onChange={(e) => acao(t.nome, e.target.checked ? "ligar" : "desligar")} aria-label={t.ativa ? "Parar" : "Ligar"} />
              <button className="icone" onClick={() => { setAberta(ab ? null : t.nome); setCron(t.quando); }} aria-label="Mais"><ChevronDown size={16} style={{ transform: ab ? "rotate(180deg)" : undefined }} /></button>
            </div>
            {ab && (
              <div className="tarefa-corpo">
                <span className="rotulo">Mudar quando roda</span>
                <div className="linha-chips">{PRESETS.map(([c, r]) => <button key={c} className={`chip${t.quando === c ? " ativo" : ""}`} disabled={ocupado} onClick={() => acao(t.nome, "horario", c)}>{r}</button>)}</div>
                <div className="linha-botoes">
                  <label className="campo"><span>Todo dia às (Brasília)</span><input type="time" value={hora} onChange={(e) => setHora(e.target.value)} /></label>
                  <button className="botao-texto" disabled={ocupado} onClick={() => acao(t.nome, "horario", `${paraUtc(hora)} * * *`)}>Usar este horário</button>
                </div>
                <div className="linha-botoes">
                  <label className="campo" style={{ flex: 1 }}><span>Expressão cron (UTC) · {cronParaTexto(cron)}</span><input value={cron} onChange={(e) => setCron(e.target.value)} placeholder="*/5 * * * *" /></label>
                  <button className="botao-texto" disabled={ocupado || cron.trim() === t.quando} onClick={() => acao(t.nome, "horario", cron.trim())}>Salvar</button>
                </div>
                <div className="linha-botoes">
                  <button className="botao-ouro" disabled={ocupado} onClick={() => acao(t.nome, "rodar")}><CirclePlay size={15} aria-hidden /> Rodar agora</button>
                  {t.ativa ? <button className="botao-texto" disabled={ocupado} onClick={() => acao(t.nome, "desligar")}><Pause size={14} aria-hidden /> Parar</button>
                    : <button className="botao-texto" disabled={ocupado} onClick={() => acao(t.nome, "ligar")}><Play size={14} aria-hidden /> Ligar</button>}
                </div>
                {t.ultima?.mensagem && <p className="dica" style={{ margin: 0 }}><CircleAlert size={12} aria-hidden /> Resposta da última vez: {t.ultima.mensagem}</p>}
                {t.comando && <details><summary className="dica">O que ela roda</summary><pre className="tarefa-cmd">{t.comando}</pre></details>}
              </div>
            )}
          </div>
        );
      })}
    </div>
  );
}

// ------------------------------------------------------------------ aparelhos

export interface Aparelho {
  id: string; nome: string; email?: string | null; versao_app: string | null; status: string; posicao_em: string | null; status_em?: string | null;
  bateria: number | null; precisao_m: number | null; modo_economia: boolean; modo_teste: boolean; pings_24h?: number; pings_1h?: number; push?: boolean; push_tokens?: number;
  raio_km?: number | null; papeis?: string[]; corrida?: { id: string; numero: number; status: string } | null;
  ultima_posicao?: { lat: number; lng: number; quando: string; velocidade: number | null; precisao: number | null } | null;
  aparelho?: Record<string, unknown> | null; aparelho_em?: string | null;
}
const STATUS: Record<string, string> = { disponivel: "Disponível", em_corrida: "Em corrida", offline: "Offline" };
function ha(iso: string | null | undefined) {
  if (!iso) return "—";
  const s = Math.max(0, Math.round((Date.now() - new Date(iso).getTime()) / 1000));
  return s < 60 ? "agora" : s < 3600 ? `há ${Math.floor(s / 60)} min` : s < 86400 ? `há ${Math.floor(s / 3600)} h` : `há ${Math.floor(s / 86400)} d`;
}
const sim = (v: unknown) => (v === true ? "sim" : v === false ? "não" : "—");

export function AparelhosDev({ aparelhos }: { aparelhos: Aparelho[] }) {
  const [busca, setBusca] = useState("");
  const [aberto, setAberto] = useState<string | null>(null);
  const lista = useMemo(() => aparelhos.filter((a) => !busca || `${a.nome} ${a.email ?? ""} ${String(a.aparelho?.modelo ?? "")}`.toLowerCase().includes(busca.toLowerCase())), [aparelhos, busca]);
  if (!aparelhos.length) return <p className="vazio">Nenhum aparelho registrado ainda.</p>;
  return (
    <div className="aparelhos-dev">
      <label className="busca-mini"><Search size={14} aria-hidden /><input placeholder="Buscar motoboy ou aparelho" value={busca} onChange={(e) => setBusca(e.target.value)} /></label>
      {lista.map((a) => {
        const d = (a.aparelho ?? {}) as Record<string, unknown>;
        const ab = aberto === a.id;
        const alertas = [d.localizacao_fundo === false && "sem localização em segundo plano", d.notificacoes === false && "notificações bloqueadas",
          d.otimizacao_bateria === true && "o Android pode pausar o app (economia de bateria)", !a.push && "sem push", d.gps_ligado === false && "GPS desligado"].filter(Boolean) as string[];
        return (
          <div key={a.id} className="aparelho">
            <button type="button" className="aparelho-topo" onClick={() => setAberto(ab ? null : a.id)}>
              <Smartphone size={18} aria-hidden />
              <span className="aparelho-texto">
                <strong>{a.nome}</strong>
                <span className="dica">{[d.fabricante && d.modelo ? `${d.fabricante} ${d.modelo}` : null, d.android ? `Android ${d.android}` : null, a.versao_app ? `app ${a.versao_app}` : null].filter(Boolean).join(" · ") || "Aparelho ainda não mandou os dados (abre o app atualizado)"}</span>
              </span>
              <span className={`selo ${a.status}`}>{STATUS[a.status] ?? a.status}</span>
              {alertas.length > 0 && <span className="selo" style={{ color: "var(--vermelho)" }} title={alertas.join("\n")}><CircleAlert size={12} aria-hidden /> {alertas.length}</span>}
              <ChevronDown size={16} style={{ transform: ab ? "rotate(180deg)" : undefined }} aria-hidden />
            </button>
            <div className="aparelho-resumo">
              <span><Signal size={12} aria-hidden /> {ha(a.posicao_em)}</span>
              <span>{d.carregando ? <BatteryCharging size={12} aria-hidden /> : <BatteryMedium size={12} aria-hidden />} {a.bateria != null ? `${a.bateria}%` : "—"}</span>
              <span>± {a.precisao_m != null ? Math.round(a.precisao_m) : "—"} m</span>
              <span>{(a.pings_1h ?? 0).toLocaleString("pt-BR")} pings/h · {(a.pings_24h ?? 0).toLocaleString("pt-BR")} em 24 h</span>
              <span>{a.push ? <Bell size={12} aria-hidden /> : <BellOff size={12} aria-hidden />} {a.push ? "push" : "sem push"}</span>
              {a.modo_teste && <span><FlaskConical size={12} aria-hidden /> teste</span>}
              {a.modo_economia && <span>economia</span>}
            </div>
            {ab && (
              <dl className="aparelho-detalhe">
                {alertas.length > 0 && <div className="largo"><dt>Atenção</dt><dd style={{ color: "var(--vermelho)" }}>{alertas.join(" · ")}</dd></div>}
                <div><dt>E-mail</dt><dd>{a.email ?? "—"}</dd></div>
                <div><dt>Cargos</dt><dd>{(a.papeis ?? []).join(", ") || "—"}</dd></div>
                <div><dt>Status desde</dt><dd>{ha(a.status_em)}</dd></div>
                <div><dt>Corrida agora</dt><dd>{a.corrida ? `#${a.corrida.numero} (${a.corrida.status})` : "nenhuma"}</dd></div>
                <div><dt>Raio escolhido</dt><dd>{a.raio_km != null ? `${a.raio_km} km` : "—"}</dd></div>
                <div><dt>Aparelho</dt><dd><Cpu size={12} aria-hidden /> {String(d.fabricante ?? "—")} {String(d.modelo ?? "")}</dd></div>
                <div><dt>Android</dt><dd>{String(d.android ?? "—")}{d.sdk ? ` (API ${d.sdk})` : ""}</dd></div>
                <div><dt>App</dt><dd>{a.versao_app ?? "—"}{d.build ? ` · build ${d.build}` : ""}</dd></div>
                <div><dt>Localização precisa</dt><dd>{sim(d.localizacao_precisa)}</dd></div>
                <div><dt>Em segundo plano</dt><dd>{sim(d.localizacao_fundo)}</dd></div>
                <div><dt>GPS ligado</dt><dd>{sim(d.gps_ligado)}</dd></div>
                <div><dt>Notificações</dt><dd>{sim(d.notificacoes)}</dd></div>
                <div><dt>Economia de bateria do Android</dt><dd>{d.otimizacao_bateria === true ? "pode pausar o app" : d.otimizacao_bateria === false ? "liberado" : "—"}</dd></div>
                <div><dt>Carregando</dt><dd>{sim(d.carregando)}</dd></div>
                <div><dt>Rede</dt><dd><Wifi size={12} aria-hidden /> {String(d.rede ?? "—")}</dd></div>
                <div><dt>Tela</dt><dd>{String(d.tela ?? "—")}</dd></div>
                <div><dt>Memória livre</dt><dd>{d.memoria_livre_mb ? `${d.memoria_livre_mb} MB` : "—"}</dd></div>
                <div><dt>Idioma / fuso</dt><dd>{String(d.idioma ?? "—")} · {String(d.fuso ?? "—")}</dd></div>
                <div><dt>Tokens de push</dt><dd>{a.push_tokens ?? 0}</dd></div>
                <div><dt>Última posição</dt><dd>{a.ultima_posicao ? <a href={`https://www.openstreetmap.org/?mlat=${a.ultima_posicao.lat}&mlon=${a.ultima_posicao.lng}#map=17/${a.ultima_posicao.lat}/${a.ultima_posicao.lng}`} target="_blank" rel="noopener"><MapPin size={12} aria-hidden /> {ha(a.ultima_posicao.quando)}{a.ultima_posicao.velocidade != null ? ` · ${Math.round(a.ultima_posicao.velocidade * 3.6)} km/h` : ""}</a> : "—"}</dd></div>
                <div><dt>Dados do aparelho</dt><dd>{ha(a.aparelho_em)}</dd></div>
              </dl>
            )}
          </div>
        );
      })}
    </div>
  );
}

"use client";

import { useCallback, useEffect, useState } from "react";
import { Ban, BatteryMedium, Bike, Megaphone, PlugZap, Power, RefreshCw, Snowflake, Sun, TriangleAlert, X } from "lucide-react";
import { supabase } from "@/lib/supabase/client";
import { toast } from "@/features/ui/toast";
import { BuscaPessoa, erroDev, useAlvos } from "./Fantasma";

interface Empresa { id: string; nome: string; status: string; online: number; em_corrida: number; rotas_ativas: number; pedidos_hoje: number; para_revisar: number; emergencias: number }
interface Comando {
  agora: string; empresas: Empresa[]; regras_ativas: number; modulos_desligados: string[];
  motoboys: { id: string; nome: string; empresa: string | null; status: string; posicao_em: string | null; bateria: number | null; versao: string | null }[];
  avisos: { id: string; texto: string; nivel: string; ate: string | null; empresa: string | null }[];
  ultimas: { tipo: string; texto: string; em: string }[];
}
const ha = (iso: string | null) => {
  if (!iso) return "—";
  const s = Math.max(0, Math.round((Date.now() - new Date(iso).getTime()) / 1000));
  return s < 60 ? "agora" : s < 3600 ? `há ${Math.floor(s / 60)} min` : s < 86400 ? `há ${Math.floor(s / 3600)} h` : `há ${Math.floor(s / 86400)} d`;
};

/** Comando ao vivo: cada empresa neste instante, quem está na rua, o que acabou de acontecer — e os botões de emergência. */
export function ComandoDev() {
  const [c, setC] = useState<Comando | null>(null);
  const [pausado, setPausado] = useState(false);
  const ler = useCallback(async () => {
    const { data, error } = await supabase().rpc("dev_comando");
    if (error) return toast(erroDev(error.message), "erro");
    setC(data as Comando);
  }, []);
  useEffect(() => {
    void ler();
    if (pausado) return;
    const t = setInterval(() => void ler(), 15_000);
    return () => clearInterval(t);
  }, [ler, pausado]);
  if (!c) return <p className="dica">Ligando o radar…</p>;
  const tot = c.empresas.reduce((a, e) => ({ online: a.online + e.online, rotas: a.rotas + e.rotas_ativas, pedidos: a.pedidos + e.pedidos_hoje, emerg: a.emerg + e.emergencias }), { online: 0, rotas: 0, pedidos: 0, emerg: 0 });
  return (
    <div className="comando">
      <div className="comando-pulso">
        <div className="dev-num"><strong>{tot.online}</strong><span>Motoboys online</span></div>
        <div className="dev-num"><strong>{tot.rotas}</strong><span>Rotas ativas</span></div>
        <div className="dev-num"><strong>{tot.pedidos}</strong><span>Pedidos 24 h</span></div>
        <div className={`dev-num${tot.emerg ? " alerta" : ""}`}><strong>{tot.emerg}</strong><span>Emergências</span></div>
        <div className="dev-num"><strong>{c.regras_ativas}</strong><span>Regras ativas</span></div>
        <div className={`dev-num${c.modulos_desligados.length ? " alerta" : ""}`}><strong>{c.modulos_desligados.length}</strong><span>Módulos desligados</span></div>
        <button className="botao-texto" onClick={() => setPausado(!pausado)}><RefreshCw size={14} aria-hidden /> {pausado ? "Atualização pausada" : "Atualiza a cada 15 s"}</button>
      </div>
      <section>
        <span className="rotulo">Empresas agora</span>
        <table className="dev-tabela">
          <thead><tr><th>Empresa</th><th>Online</th><th>Em corrida</th><th>Rotas</th><th>Pedidos 24 h</th><th>Para revisar</th><th>Emergências</th></tr></thead>
          <tbody>{c.empresas.map((e) => (
            <tr key={e.id} className={e.status !== "ativa" && e.status !== "teste" ? "congelada" : ""}>
              <td><strong>{e.nome}</strong> {e.status !== "ativa" && <span className="chip">{e.status}</span>}</td>
              <td>{e.online}</td><td>{e.em_corrida}</td><td>{e.rotas_ativas}</td><td>{e.pedidos_hoje}</td><td>{e.para_revisar}</td>
              <td className={e.emergencias ? "erro" : ""}>{e.emergencias}</td>
            </tr>
          ))}</tbody>
        </table>
      </section>
      <div className="comando-duplo">
        <section>
          <span className="rotulo">Na rua</span>
          {!c.motoboys.length ? <p className="vazio">Ninguém online.</p> : (
            <ul className="comando-lista">{c.motoboys.map((m) => (
              <li key={m.id}><Bike size={14} aria-hidden /> <strong>{m.nome}</strong> <span className="dica">{m.empresa ?? "—"} · {m.status.replace("_", " ")} · {ha(m.posicao_em)}</span>
                {m.bateria != null && <span className="dica"><BatteryMedium size={12} aria-hidden /> {m.bateria}%</span>}{m.versao && <span className="dica">v{m.versao}</span>}</li>
            ))}</ul>
          )}
        </section>
        <section>
          <span className="rotulo">Acabou de acontecer</span>
          <ul className="comando-lista">{c.ultimas.map((u, i) => <li key={i}><span className={`chip ${u.tipo}`}>{u.tipo === "dev" ? "Dev" : "Pedido"}</span> {u.texto} <span className="dica">{ha(u.em)}</span></li>)}</ul>
        </section>
      </div>
      <EmergenciaDev comando={c} onMudou={() => void ler()} />
    </div>
  );
}

/** Botões de emergência: aviso para todos, desligar uma parte do sistema, congelar empresa, derrubar sessões, forçar update. */
function EmergenciaDev({ comando, onMudou }: { comando: Comando; onMudou: () => void }) {
  const { empresas } = useAlvos();
  const [aviso, setAviso] = useState({ texto: "", nivel: "info", papeis: [] as string[], organizacao_id: "", horas: "" });
  const [modulos, setModulos] = useState<{ chave: string; nome: string; ligado: boolean }[]>([]);
  const [modulo, setModulo] = useState("");
  const [orgCongelar, setOrgCongelar] = useState("");
  const [motivo, setMotivo] = useState("");
  const [pessoa, setPessoa] = useState<{ id: string; nome: string } | null>(null);
  useEffect(() => { void supabase().from("modulos").select("chave,nome,ligado").order("nome").then(({ data }) => setModulos((data ?? []) as typeof modulos)); }, [comando.modulos_desligados.length]);

  async function avisar() {
    const ate = aviso.horas ? new Date(Date.now() + Number(aviso.horas) * 3600_000).toISOString() : null;
    const { error } = await supabase().rpc("dev_avisar", { p: { texto: aviso.texto, nivel: aviso.nivel, papeis: aviso.papeis, organizacao_id: aviso.organizacao_id || null, ate } });
    if (error) return toast(erroDev(error.message), "erro");
    toast("Aviso no ar.", "ok", { titulo: "Avisos" }); setAviso({ ...aviso, texto: "" }); onMudou();
  }
  async function encerrar(id: string) {
    const { error } = await supabase().rpc("dev_encerrar_aviso", { p_id: id });
    if (error) return toast(erroDev(error.message), "erro");
    onMudou();
  }
  async function alternarModulo() {
    const m = modulos.find((x) => x.chave === modulo);
    if (!m) return;
    if (m.ligado && !window.confirm(`Desligar “${m.nome}” para todo mundo agora? (Você continua vendo.)`)) return;
    const { error } = await supabase().rpc("definir_modulo", { p_chave: m.chave, p_ligado: !m.ligado, p_papeis: null });
    if (error) return toast(erroDev(error.message), "erro");
    toast(`${m.nome}: ${m.ligado ? "desligado para todos" : "ligado de novo"}.`, m.ligado ? "aviso" : "ok"); onMudou();
  }
  async function congelar(sim: boolean) {
    const e = empresas.find((x) => x.id === orgCongelar);
    if (!e) return;
    if (sim && !window.confirm(`Congelar ${e.nome}? Equipe e clientes ficam sem acesso até você descongelar.`)) return;
    const { error } = await supabase().rpc("dev_congelar_empresa", { p_org: e.id, p_congelar: sim, p_motivo: motivo || null });
    if (error) return toast(erroDev(error.message), "erro");
    toast(sim ? `${e.nome} congelada.` : `${e.nome} de volta.`, sim ? "aviso" : "ok"); onMudou();
  }
  async function derrubar(alvo: "pessoa" | "empresa") {
    const p = alvo === "pessoa" ? { p_pessoa: pessoa?.id, p_org: null } : { p_pessoa: null, p_org: orgCongelar };
    if (!window.confirm(alvo === "pessoa" ? `Desconectar ${pessoa?.nome} de todos os aparelhos?` : "Desconectar todo mundo desta empresa? Cada um vai precisar entrar de novo.")) return;
    const { data, error } = await supabase().rpc("dev_derrubar_sessoes", p);
    if (error) return toast(erroDev(error.message), "erro");
    toast(`${data ?? 0} conta(s) desconectada(s).`, "ok");
  }
  const mod = modulos.find((x) => x.chave === modulo);
  return (
    <section className="zona-perigo emergencia-dev">
      <span className="rotulo"><TriangleAlert size={14} aria-hidden /> Emergência</span>

      <div className="perigo-item">
        <strong><Megaphone size={15} aria-hidden /> Avisar</strong>
        <textarea rows={2} placeholder="Ex.: Instabilidade no mapa, já estamos resolvendo." value={aviso.texto} onChange={(e) => setAviso({ ...aviso, texto: e.target.value })} />
        <div className="regra-linha">
          <select value={aviso.nivel} onChange={(e) => setAviso({ ...aviso, nivel: e.target.value })} aria-label="Nível"><option value="info">Informação</option><option value="aviso">Atenção</option><option value="urgente">Urgente (não fecha)</option></select>
          <select value={aviso.organizacao_id} onChange={(e) => setAviso({ ...aviso, organizacao_id: e.target.value })} aria-label="Empresa"><option value="">Todas as empresas</option>{empresas.map((o) => <option key={o.id} value={o.id}>{o.nome}</option>)}</select>
          <select value={aviso.horas} onChange={(e) => setAviso({ ...aviso, horas: e.target.value })} aria-label="Duração"><option value="">Até eu encerrar</option><option value="1">1 hora</option><option value="4">4 horas</option><option value="24">1 dia</option><option value="168">1 semana</option></select>
        </div>
        <div className="regra-dias">{(["motoboy", "gestor", "supervisor", "cliente"] as const).map((p) => {
          const on = aviso.papeis.includes(p);
          return <label key={p} className={`chip${on ? " ativo" : ""}`}><input type="checkbox" checked={on} onChange={() => setAviso({ ...aviso, papeis: on ? aviso.papeis.filter((x) => x !== p) : [...aviso.papeis, p] })} /> {p}</label>;
        })}<span className="dica">{aviso.papeis.length ? "Só para estes cargos" : "Para todos os cargos"}</span></div>
        <button className="botao-ouro" disabled={!aviso.texto.trim()} onClick={() => void avisar()}>Mandar aviso</button>
        {comando.avisos.map((a) => <div key={a.id} className={`aviso-dev ${a.nivel}`}><span>{a.texto} <span className="dica">{a.empresa ?? "todas"}{a.ate ? ` · até ${new Date(a.ate).toLocaleString("pt-BR")}` : ""}</span></span><button className="botao-icone" aria-label="Encerrar" onClick={() => void encerrar(a.id)}><X size={14} aria-hidden /></button></div>)}
      </div>

      <div className="perigo-item">
        <strong><Power size={15} aria-hidden /> Desligar uma parte do sistema</strong>
        <div className="regra-linha">
          <select value={modulo} onChange={(e) => setModulo(e.target.value)} aria-label="Módulo"><option value="">Escolha o módulo</option>{modulos.map((m) => <option key={m.chave} value={m.chave}>{m.ligado ? "" : "⛔ "}{m.nome}</option>)}</select>
          <button className={mod?.ligado === false ? "botao-ouro" : "botao-perigo"} disabled={!mod} onClick={() => void alternarModulo()}>{mod?.ligado === false ? "Religar" : "Desligar para todos"}</button>
        </div>
      </div>

      <div className="perigo-item">
        <strong><Snowflake size={15} aria-hidden /> Congelar empresa</strong>
        <div className="regra-linha">
          <select value={orgCongelar} onChange={(e) => setOrgCongelar(e.target.value)} aria-label="Empresa"><option value="">Escolha a empresa</option>{empresas.map((o) => <option key={o.id} value={o.id}>{o.nome}</option>)}</select>
          <input placeholder="Motivo (a equipe vê)" value={motivo} onChange={(e) => setMotivo(e.target.value)} />
        </div>
        <div className="regra-linha">
          <button className="botao-perigo" disabled={!orgCongelar} onClick={() => void congelar(true)}><Snowflake size={14} aria-hidden /> Congelar</button>
          <button className="botao-texto" disabled={!orgCongelar} onClick={() => void congelar(false)}><Sun size={14} aria-hidden /> Descongelar</button>
          <button className="botao-texto" disabled={!orgCongelar} onClick={() => void derrubar("empresa")}><PlugZap size={14} aria-hidden /> Desconectar todos dela</button>
        </div>
      </div>

      <div className="perigo-item">
        <strong><Ban size={15} aria-hidden /> Desconectar uma pessoa</strong>
        <div className="regra-linha">
          <BuscaPessoa valor={pessoa?.id ?? null} nome={pessoa?.nome} onEscolher={(id, nome) => setPessoa({ id, nome })} />
          <button className="botao-perigo" disabled={!pessoa} onClick={() => void derrubar("pessoa")}>Desconectar</button>
        </div>
        <p className="dica">Para obrigar todos a atualizar o app, use Ajustes da plataforma → Versão do app.</p>
      </div>
    </section>
  );
}

"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { CheckCircle2, Download, Lock, RefreshCw, Rocket, ShieldAlert, Smartphone } from "lucide-react";
import { supabase } from "@/lib/supabase/client";
import { toast } from "@/features/ui/toast";

interface Release { build: number; nome: string; notas: string; publicada: string; url: string | null }
interface EmUso { id: string; nome: string; versao: number | null; em: string | null; teste: boolean }

const REPO_PADRAO = "Avttok/delibra-app";
const data = (iso: string | null) => (iso ? new Date(iso).toLocaleString("pt-BR", { dateStyle: "short", timeStyle: "short" }) : "—");

/**
 * Versão do app que deve rodar. O Dev escolhe uma build (ou "sempre a mais nova") e, com "forçar" ligado,
 * qualquer outra fica travada na tela de atualização e o servidor recusa as chamadas dela.
 */
export function VersaoApp() {
  const [cfg, setCfg] = useState<{ exigida: number; forcar: boolean; devLivre: boolean; repo: string } | null>(null);
  const [releases, setReleases] = useState<Release[] | null>(null);
  const [erroGh, setErroGh] = useState<string | null>(null);
  const [emUso, setEmUso] = useState<EmUso[]>([]);
  const [salvando, setSalvando] = useState(false);
  const [digitada, setDigitada] = useState("");

  const carregar = useCallback(async () => {
    const sb = supabase();
    const { data: linhas } = await sb.from("configuracoes").select("chave,valor").in("chave", ["app_versao_exigida", "app_forcar_versao", "app_dev_livre", "app_repo"]);
    const v = (k: string) => (linhas ?? []).find((l) => l.chave === k)?.valor;
    const repo = typeof v("app_repo") === "string" ? (v("app_repo") as string) : REPO_PADRAO;
    setCfg({ exigida: Number(v("app_versao_exigida") ?? 0), forcar: v("app_forcar_versao") !== false, devLivre: v("app_dev_livre") !== false, repo });
    const u = await sb.rpc("versoes_em_uso");
    if (!u.error) setEmUso((u.data ?? []) as EmUso[]);
    try {
      const r = await fetch(`https://api.github.com/repos/${repo}/releases?per_page=40`, { headers: { Accept: "application/vnd.github+json" } });
      if (!r.ok) throw new Error(r.status === 403 ? "limite de consultas do GitHub atingido nesta rede (tente em 1 h)" : `GitHub respondeu ${r.status}`);
      const j = (await r.json()) as { tag_name: string; name: string; body: string | null; published_at: string; assets: { name: string; browser_download_url: string }[] }[];
      setReleases(j.flatMap((x) => {
        const b = Number(x.tag_name.replace("build-", ""));
        if (!x.tag_name.startsWith("build-") || !b) return [];
        return [{ build: b, nome: x.name || `build ${b}`, notas: (x.body ?? "").split("\n").filter((l) => !l.startsWith("Commit:")).join("\n").trim(),
          publicada: x.published_at, url: x.assets.find((a) => a.name.endsWith(".apk"))?.browser_download_url ?? null }];
      }).sort((a, b) => b.build - a.build));
      setErroGh(null);
    } catch (e) { setErroGh(e instanceof Error ? e.message : "falha"); setReleases([]); }
  }, []);
  useEffect(() => { void carregar(); }, [carregar]);

  async function salvar(novo: Partial<{ exigida: number; forcar: boolean; devLivre: boolean }>) {
    if (!cfg) return;
    const prox = { ...cfg, ...novo };
    setSalvando(true);
    // update por chave (a tabela não aceita insert pelo site; as linhas vêm da migração)
    const sb = supabase();
    const pares: [string, unknown][] = [["app_versao_exigida", prox.exigida], ["app_forcar_versao", prox.forcar], ["app_dev_livre", prox.devLivre]];
    let error: { message: string } | null = null;
    for (const [chave, valor] of pares) {
      const r = await sb.from("configuracoes").update({ valor }).eq("chave", chave).select("chave");
      if (r.error) { error = r.error; break; }
      if (!r.data?.length) { error = { message: `A configuração "${chave}" não existe no banco — rode a migração 20261110000001_refinamento.sql.` }; break; }
    }
    setSalvando(false);
    if (error) return toast(error.message.includes("apenas_dev") ? "Só o Dev muda a versão do app." : error.message, "erro");
    setCfg(prox);
    toast(prox.exigida ? `Build ${prox.exigida} é a versão do app${prox.forcar ? ": as outras travam até atualizar." : "."}` : `Sempre a mais nova${prox.forcar ? ", obrigatória." : "."}`, "ok");
  }

  const maisNova = releases?.[0]?.build ?? null;
  const alvo = cfg?.exigida || maisNova;
  const fora = useMemo(() => emUso.filter((m) => alvo != null && m.versao !== alvo), [emUso, alvo]);
  if (!cfg) return <p className="dica">Carregando…</p>;

  return (
    <div className="versao-app">
      <section className="bloco destaque-bloco">
        <span className="rotulo"><Rocket size={12} aria-hidden /> Versão que deve rodar</span>
        <strong className="figura texto-grad" style={{ fontSize: 26 }}>{cfg.exigida ? `Build ${cfg.exigida}` : `Sempre a mais nova${maisNova ? ` (build ${maisNova})` : ""}`}</strong>
        <label className="opcao"><span><Lock size={14} aria-hidden /> Forçar: outras versões ficam travadas</span>
          <input type="checkbox" role="switch" checked={cfg.forcar} disabled={salvando} onChange={(e) => salvar({ forcar: e.target.checked })} /></label>
        <label className="opcao"><span><ShieldAlert size={14} aria-hidden /> Contas Dev podem testar qualquer versão</span>
          <input type="checkbox" role="switch" checked={cfg.devLivre} disabled={salvando} onChange={(e) => salvar({ devLivre: e.target.checked })} /></label>
        <p className="dica" style={{ margin: 0 }}>
          Com “forçar”, o app numa versão diferente mostra a tela de atualização obrigatória e o servidor recusa localização, rotas e etapas dele.
          Escolher uma build mais antiga exige reinstalar o app nos celulares que já estão numa mais nova (o Android não volta versão sozinho).
        </p>
      </section>

      <section className="bloco">
        <div className="titulo-linha"><span className="rotulo"><Download size={12} aria-hidden /> Versões publicadas</span>
          <button className="botao-texto" onClick={() => carregar()}><RefreshCw size={14} aria-hidden /> Atualizar</button></div>
        {erroGh && <p className="erro">Não consegui listar as versões: {erroGh}</p>}
        <button type="button" className={`versao-linha ${cfg.exigida === 0 ? "ativa" : ""}`} disabled={salvando} onClick={() => salvar({ exigida: 0 })}>
          <span className="versao-num">∞</span>
          <span className="versao-info"><strong>Sempre a mais nova</strong><small>O app segue cada build publicada na main.</small></span>
          {cfg.exigida === 0 && <CheckCircle2 size={18} aria-label="escolhida" />}
        </button>
        {releases === null && <p className="dica">Buscando no GitHub…</p>}
        <div className="linha-botoes">
          <input inputMode="numeric" placeholder="Ou digite o número da build" value={digitada} onChange={(e) => setDigitada(e.target.value.replace(/\D/g, ""))} style={{ flex: 1, minWidth: 0 }} />
          <button className="botao-texto" disabled={!digitada || salvando} onClick={() => { void salvar({ exigida: Number(digitada) }); setDigitada(""); }}><Lock size={14} aria-hidden /> Usar esta build</button>
        </div>
        {releases?.map((r) => (
          <button key={r.build} type="button" className={`versao-linha ${cfg.exigida === r.build ? "ativa" : ""}`} disabled={salvando || !r.url} onClick={() => salvar({ exigida: r.build })}>
            <span className="versao-num">{r.build}</span>
            <span className="versao-info"><strong>{r.nome}{r.build === maisNova ? " · mais nova" : ""}</strong>
              <small>{data(r.publicada)}{r.notas ? ` · ${r.notas.split("\n")[0].replace(/^•\s*/, "")}` : ""}</small></span>
            {cfg.exigida === r.build && <CheckCircle2 size={18} aria-label="escolhida" />}
          </button>
        ))}
      </section>

      <section className="bloco">
        <span className="rotulo"><Smartphone size={12} aria-hidden /> Celulares{alvo ? ` · ${fora.length} fora da build ${alvo}` : ""}</span>
        {emUso.length === 0 ? <p className="dica">Nenhum app informou a versão ainda (as versões novas informam ao enviar a localização).</p> : (
          <div className="dev-rolagem"><table className="dev-tabela"><thead><tr><th>Motoboy</th><th>Build</th><th>Visto</th></tr></thead>
            <tbody>{emUso.map((m) => (
              <tr key={m.id} className={alvo != null && m.versao !== alvo ? "fora-versao" : ""}><td>{m.nome}{m.teste ? " · teste" : ""}</td><td>{m.versao ?? "antiga"}</td><td>{data(m.em)}</td></tr>
            ))}</tbody></table></div>
        )}
      </section>
    </div>
  );
}

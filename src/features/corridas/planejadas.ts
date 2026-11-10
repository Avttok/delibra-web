/** Utilidades das corridas planejadas (com hora marcada). */

const DIA = ["dom", "seg", "ter", "qua", "qui", "sex", "sáb"];
export const DIAS_SEMANA = ["D", "S", "T", "Q", "Q", "S", "S"];

/** "sex, 07/11 às 14:00" (e o ano, se não for o atual). */
export function formatarQuando(iso: string | null | undefined): string {
  if (!iso) return "—";
  const d = new Date(iso);
  const ano = d.getFullYear() !== new Date().getFullYear() ? `/${d.getFullYear()}` : "";
  return `${DIA[d.getDay()]}, ${String(d.getDate()).padStart(2, "0")}/${String(d.getMonth() + 1).padStart(2, "0")}${ano} às ${d.toLocaleTimeString("pt-BR", { hour: "2-digit", minute: "2-digit" })}`;
}

/** "em 2 d 3 h", "em 40 min", "há 5 min". */
export function relativo(iso: string | null | undefined, agora = Date.now()): string {
  if (!iso) return "";
  const min = Math.round((new Date(iso).getTime() - agora) / 60000);
  const abs = Math.abs(min);
  const t = abs < 60 ? `${abs} min` : abs < 60 * 24 ? `${Math.floor(abs / 60)} h${abs % 60 ? ` ${abs % 60} min` : ""}` : `${Math.floor(abs / 1440)} d${Math.floor((abs % 1440) / 60) ? ` ${Math.floor((abs % 1440) / 60)} h` : ""}`;
  return min >= 0 ? `em ${t}` : `há ${t}`;
}

/** Valor para <input type="datetime-local"> no fuso do navegador. */
export function paraCampo(d: Date): string {
  const z = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${z(d.getMonth() + 1)}-${z(d.getDate())}T${z(d.getHours())}:${z(d.getMinutes())}`;
}

/** Próxima hora cheia depois de `minutos` a partir de agora. */
export function sugestaoHorario(minutos = 60): Date {
  const d = new Date(Date.now() + minutos * 60000);
  d.setMinutes(0, 0, 0);
  d.setHours(d.getHours() + 1);
  return d;
}

export type Repeticao = "nao" | "diario" | "semanal";

/** Datas da série: a primeira é o próprio início. Em "semanal", só os dias marcados (0 = domingo). */
export function gerarDatas(inicio: Date, repetir: Repeticao, dias: number[], vezes: number): Date[] {
  if (repetir === "nao" || vezes <= 1) return [inicio];
  const out: Date[] = [];
  const d = new Date(inicio);
  const usar = repetir === "diario" ? [0, 1, 2, 3, 4, 5, 6] : dias.length ? dias : [inicio.getDay()];
  for (let i = 0; out.length < vezes && i < 400; i++) {
    if (usar.includes(d.getDay())) out.push(new Date(d));
    d.setDate(d.getDate() + 1);
  }
  return out;
}

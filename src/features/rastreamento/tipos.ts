export type StatusMotoboy = "offline" | "disponivel" | "em_corrida";

export interface Motoboy {
  id: string;
  status: StatusMotoboy;
  modo_economia: boolean;
  lat: number | null;
  lng: number | null;
  precisao_m: number | null;
  bateria: number | null;
  posicao_em: string | null;
  status_em: string;
  versao_app: string | null;
  modo_teste?: boolean;
}

export interface Ponto {
  id: number;
  motoboy_id: string;
  sessao_id: string | null;
  corrida_id?: string | null;
  status: StatusMotoboy;
  lat: number;
  lng: number;
  precisao_m: number | null;
  velocidade_ms: number | null;
  bateria: number | null;
  registrado_em: string;
}

export const ROTULO_STATUS: Record<StatusMotoboy, string> = {
  offline: "Offline",
  disponivel: "Disponível",
  em_corrida: "Em corrida",
};

export const COR_STATUS: Record<StatusMotoboy, string> = {
  offline: "#8a8a8a",
  disponivel: "#2ecc71",
  em_corrida: "var(--ouro)",
};

/**
 * Contrato dos serviços de mapa. A implementação atual usa OpenStreetMap (grátis, para testes).
 * Para trocar pelo Google, crie outro arquivo com estas funções e mude o export em ./index.ts.
 */
export interface Endereco {
  descricao: string;
  lat: number;
  lng: number;
}

export interface Rota {
  distanciaM: number;
  duracaoS: number;
  polyline: string; // precisão 5
}

/** Ponto de referência perto de uma parada (loja, posto, praça…). */
export interface Referencia {
  nome: string;
  lat?: number | null;
  lng?: number | null;
  distancia_m?: number | null;
  tipo?: string | null;
  /** Posição em relação ao destino, só quando há confiança ("Do outro lado da rua de…", "À esquerda de…"). */
  relacao?: string | null;
}

export interface ProvedorGeo {
  /** Estabelecimentos com nome perto do ponto, do mais perto ao mais longe. */
  pontosProximos(lat: number, lng: number, raioM?: number): Promise<Referencia[]>;
  buscarEnderecos(texto: string): Promise<Endereco[]>;
  enderecoDoPonto(lat: number, lng: number): Promise<string>;
  calcularRota(pontos: { lat: number; lng: number }[]): Promise<Rota | null>;
}

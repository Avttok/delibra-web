import { provedorOsm } from "./osm";

export type { Endereco, Referencia, Rota, ProvedorGeo } from "./provedor";

/** Provedor ativo. Trocar aqui para usar outro serviço (ex.: Google). */
export const geo = provedorOsm;
export { definirPreferenciaRota, distanciasColetaEntrega, codificarPolyline } from "./osm";

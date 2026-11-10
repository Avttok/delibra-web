/** Decodifica polyline do Google (precisão 5) em [lng, lat][] (ordem do GeoJSON). */
export function decodificarPolyline(texto: string, precisao = 5): [number, number][] {
  const fator = 10 ** precisao;
  const pontos: [number, number][] = [];
  let i = 0, lat = 0, lng = 0;
  while (i < texto.length) {
    for (const eixo of [0, 1]) {
      let resultado = 0, deslocamento = 0, b: number;
      do {
        b = texto.charCodeAt(i++) - 63;
        resultado |= (b & 0x1f) << deslocamento;
        deslocamento += 5;
      } while (b >= 0x20);
      const delta = resultado & 1 ? ~(resultado >> 1) : resultado >> 1;
      if (eixo === 0) lat += delta; else lng += delta;
    }
    pontos.push([lng / fator, lat / fator]);
  }
  return pontos;
}

/**
 * Editor do ícone da empresa (mesma lógica do app): recorte em quadrado com zoom e posição,
 * margem, e "tirar o fundo" — a cor das bordas some (vira transparente), com borda suave.
 * Quem já manda PNG transparente só ajusta zoom/posição.
 */
export type AjusteIcone = { zoom: number; dx: number; dy: number; margem: number; tirarFundo: boolean; tolerancia: number };
export const AJUSTE_PADRAO: AjusteIcone = { zoom: 1, dx: 0, dy: 0, margem: 0.08, tirarFundo: false, tolerancia: 40 };

export async function carregarImagem(arquivo: File): Promise<HTMLImageElement> {
  const url = URL.createObjectURL(arquivo);
  return new Promise((ok, erro) => { const i = new Image(); i.onload = () => ok(i); i.onerror = erro; i.src = url; });
}

/** A imagem tem pixels transparentes? (aí "tirar o fundo" já vem desligado) */
export function temTransparencia(img: HTMLImageElement): boolean {
  const c = document.createElement("canvas"); const l = 64; c.width = l; c.height = l;
  const g = c.getContext("2d")!; g.drawImage(img, 0, 0, l, l);
  const d = g.getImageData(0, 0, l, l).data;
  for (let i = 3; i < d.length; i += 4) if (d[i] < 250) return true;
  return false;
}

/** Fundo das bordas vira transparente: preenche a partir das bordas o que é parecido com a cor delas. */
export function tirarFundo(dados: ImageData, tolerancia: number) {
  const { width: w, height: h, data: d } = dados;
  // cor de referência: média dos 4 cantos
  const cantos = [0, w - 1, (h - 1) * w, h * w - 1];
  const ref = [0, 0, 0];
  for (const p of cantos) for (let k = 0; k < 3; k++) ref[k] += d[p * 4 + k] / 4;
  const dist = (p: number) => Math.hypot(d[p * 4] - ref[0], d[p * 4 + 1] - ref[1], d[p * 4 + 2] - ref[2]);
  const t = tolerancia, suave = tolerancia * 1.6;
  const visto = new Uint8Array(w * h);
  const fila: number[] = [];
  for (let x = 0; x < w; x++) { fila.push(x, (h - 1) * w + x); }
  for (let y = 0; y < h; y++) { fila.push(y * w, y * w + w - 1); }
  while (fila.length) {
    const p = fila.pop()!;
    if (visto[p]) continue;
    visto[p] = 1;
    if (d[p * 4 + 3] === 0) { /* já transparente: segue */ }
    else {
      const e = dist(p);
      if (e > suave) continue;
      // borda suave: entre a tolerância e 1,6× ela, some aos poucos
      d[p * 4 + 3] = e <= t ? 0 : Math.round(d[p * 4 + 3] * ((e - t) / (suave - t)));
      if (e > t) continue;
    }
    const x = p % w, y = (p / w) | 0;
    if (x > 0) fila.push(p - 1); if (x < w - 1) fila.push(p + 1);
    if (y > 0) fila.push(p - w); if (y < h - 1) fila.push(p + w);
  }
}

/** Desenha o ícone final (quadrado, transparente onde não há imagem). */
export function desenharIcone(img: HTMLImageElement, a: AjusteIcone, lado = 512): HTMLCanvasElement {
  // primeiro tira o fundo na imagem inteira (até 1024 px), depois recorta
  const maior = Math.max(img.naturalWidth, img.naturalHeight);
  const esc = Math.min(1, 1024 / maior);
  const fonte = document.createElement("canvas");
  fonte.width = Math.round(img.naturalWidth * esc); fonte.height = Math.round(img.naturalHeight * esc);
  const gf = fonte.getContext("2d", { willReadFrequently: true })!;
  gf.drawImage(img, 0, 0, fonte.width, fonte.height);
  if (a.tirarFundo) { const dd = gf.getImageData(0, 0, fonte.width, fonte.height); tirarFundo(dd, a.tolerancia); gf.putImageData(dd, 0, 0); }
  const c = document.createElement("canvas"); c.width = lado; c.height = lado;
  const g = c.getContext("2d")!;
  g.imageSmoothingQuality = "high";
  const area = lado * (1 - a.margem * 2);
  // cabe inteira na área (contain), depois o zoom e o deslocamento
  const base = Math.min(area / fonte.width, area / fonte.height) * a.zoom;
  const lw = fonte.width * base, lh = fonte.height * base;
  g.drawImage(fonte, (lado - lw) / 2 + a.dx * lado, (lado - lh) / 2 + a.dy * lado, lw, lh);
  return c;
}

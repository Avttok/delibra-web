import type { Metadata } from "next";
import { Rastreio } from "@/features/avaliacoes/Rastreio";

export const metadata: Metadata = { title: "Acompanhe sua entrega", robots: { index: false, follow: false } };

export default async function PaginaRastreio({ params }: { params: Promise<{ token: string }> }) {
  const { token } = await params;
  return <Rastreio token={token} />;
}

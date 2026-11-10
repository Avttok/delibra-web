import type { Metadata } from "next";
import { DownloadApp } from "@/features/site/Download";

export const metadata: Metadata = { title: "App do motoboy · Delibra", description: "Baixe e instale o app do motoboy da Delibra para Android." };
export default function Pagina() { return <DownloadApp />; }

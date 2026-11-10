"use client";

import { useState } from "react";
import {
  Apple, Baby, BadgeCheck, Banknote, BatteryCharging, Beef, Bike, Book, Box, Briefcase, BriefcaseMedical, Building, Building2, Bus, Cake, Camera, Car, Church,
  CircleDollarSign, Clock, Coffee, Cog, Cookie, Cpu, Croissant, Crown, Dog, Droplet, Dumbbell, Factory, FileBox, FileText, Fish, FlaskConical, Flame,
  Flower2, Folder, Fuel, Gamepad2, Gem, Gift, Glasses, Hamburger, Hammer, Headphones, Heart, Hospital, Hotel, House, IceCreamCone, KeyRound, Landmark,
  Laptop, Leaf, Mail, MapPin, Milk, Moon, Music, Newspaper, Package, Package2, Palette, PawPrint, Pill, Pizza, Plug, Printer, Receipt, Rocket, Ruler,
  Sandwich, School, Scissors, Shield, ShieldCheck, Shirt, ShoppingBag, ShoppingCart, Smartphone, Snowflake, Sofa, Sparkles, Star, Stethoscope, Store,
  Sun, Syringe, Tablet, Tag, Tags, Thermometer, Truck, Tv, UserRound, Users, Utensils, Warehouse, Watch, Wine, Wrench, X, Zap, type LucideIcon,
} from "lucide-react";

/** Ícones que o gestor pode escolher (nome guardado no banco = nome do Lucide). O app usa os mesmos nomes. */
export const GRUPOS_ICONES: { nome: string; icones: Record<string, LucideIcon> }[] = [
  { nome: "Pacotes", icones: { package: Package, "package-2": Package2, box: Box, "file-box": FileBox, "file-text": FileText, folder: Folder, mail: Mail, newspaper: Newspaper, gift: Gift, tag: Tag, tags: Tags, receipt: Receipt } },
  { nome: "Comércio", icones: { store: Store, "shopping-bag": ShoppingBag, "shopping-cart": ShoppingCart, "building-2": Building2, building: Building, warehouse: Warehouse, factory: Factory, briefcase: Briefcase, landmark: Landmark, banknote: Banknote, "circle-dollar-sign": CircleDollarSign, hotel: Hotel, house: House, school: School, church: Church, hospital: Hospital } },
  { nome: "Comida", icones: { utensils: Utensils, pizza: Pizza, hamburger: Hamburger, sandwich: Sandwich, coffee: Coffee, croissant: Croissant, cake: Cake, cookie: Cookie, "ice-cream-cone": IceCreamCone, apple: Apple, beef: Beef, fish: Fish, milk: Milk, wine: Wine, snowflake: Snowflake } },
  { nome: "Saúde", icones: { pill: Pill, syringe: Syringe, stethoscope: Stethoscope, "briefcase-medical": BriefcaseMedical, thermometer: Thermometer, heart: Heart, baby: Baby, "paw-print": PawPrint, dog: Dog } },
  { nome: "Tecnologia", icones: { smartphone: Smartphone, laptop: Laptop, tablet: Tablet, tv: Tv, cpu: Cpu, headphones: Headphones, camera: Camera, watch: Watch, printer: Printer, plug: Plug, "battery-charging": BatteryCharging, "gamepad-2": Gamepad2 } },
  { nome: "Cuidado", icones: { "flask-conical": FlaskConical, flame: Flame, droplet: Droplet, fuel: Fuel, gem: Gem, glasses: Glasses, shield: Shield, "shield-check": ShieldCheck } },
  { nome: "Outros", icones: { shirt: Shirt, sofa: Sofa, "flower-2": Flower2, leaf: Leaf, book: Book, palette: Palette, music: Music, dumbbell: Dumbbell, scissors: Scissors, hammer: Hammer, wrench: Wrench, cog: Cog, ruler: Ruler, "key-round": KeyRound, truck: Truck, car: Car, bike: Bike, bus: Bus, "map-pin": MapPin, clock: Clock, sun: Sun, moon: Moon, zap: Zap, star: Star, crown: Crown, rocket: Rocket, sparkles: Sparkles, "badge-check": BadgeCheck, "user-round": UserRound, users: Users } },
];
const TODOS: Record<string, LucideIcon> = Object.assign({}, ...GRUPOS_ICONES.map((g) => g.icones));

/** Desenha o ícone pelo nome guardado (cai no `padrao` se o nome não existir). */
export function Icone({ nome, padrao = Package, size = 16, className, style }: { nome?: string | null; padrao?: LucideIcon; size?: number; className?: string; style?: React.CSSProperties }) {
  const I = (nome && TODOS[nome]) || padrao;
  return <I size={size} className={className} style={style} aria-hidden />;
}

/** Botão que abre a grade de ícones para escolher. */
export function SeletorIcone({ valor, onMudar, padrao = Package, rotulo = "Ícone" }: { valor?: string | null; onMudar: (nome: string | null) => void; padrao?: LucideIcon; rotulo?: string }) {
  const [aberto, setAberto] = useState(false);
  const [busca, setBusca] = useState("");
  const termo = busca.trim().toLowerCase();
  return (
    <div className="seletor-icone">
      <button type="button" className="seletor-icone-botao" onClick={() => setAberto(!aberto)} title={rotulo} aria-label={`${rotulo}: ${valor ?? "padrão"}`} aria-expanded={aberto}>
        <Icone nome={valor} padrao={padrao} size={18} />
      </button>
      {aberto && (
        <div className="seletor-icone-caixa vidro" role="dialog" aria-label={rotulo}>
          <div className="seletor-icone-topo">
            <input autoFocus placeholder="Buscar ícone (em inglês: pizza, car…)" value={busca} onChange={(e) => setBusca(e.target.value)} />
            <button type="button" className="icone" onClick={() => setAberto(false)} aria-label="Fechar"><X size={14} /></button>
          </div>
          {valor && <button type="button" className="botao-texto" onClick={() => { onMudar(null); setAberto(false); }}>Voltar ao padrão</button>}
          {GRUPOS_ICONES.map((g) => {
            const nomes = Object.keys(g.icones).filter((n) => !termo || n.includes(termo) || g.nome.toLowerCase().includes(termo));
            if (!nomes.length) return null;
            return (
              <div key={g.nome}>
                <span className="rotulo">{g.nome}</span>
                <div className="seletor-icone-grade">
                  {nomes.map((n) => {
                    const I = g.icones[n];
                    return <button key={n} type="button" className={valor === n ? "ativo" : ""} title={n} onClick={() => { onMudar(n); setAberto(false); }}><I size={18} aria-hidden /></button>;
                  })}
                </div>
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}

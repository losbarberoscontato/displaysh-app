"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { CalendarDays, CalendarPlus2, CreditCard, House, MapPin, UserRound } from "lucide-react";

const clientNavigation = [
  { href: "/cliente/inicio", label: "Home", icon: House },
  { href: "/cliente/agendar", label: "Agendar", icon: CalendarPlus2 },
  { href: "/cliente/reservas", label: "Reservas", icon: CalendarDays },
  { href: "/cliente/assinaturas", label: "Assinaturas", icon: CreditCard },
  { href: "/cliente/perfil", label: "Perfil", icon: UserRound },
];

export function ClientShell({ children, demoMode = false }: { children: React.ReactNode; demoMode?: boolean }) {
  const pathname = usePathname() ?? "";

  return (
    <div className="client-shell">
      <header className="client-topbar">
        <div className="client-topbar__inner">
          <div className="client-header-ad-slot" data-ad-slot="client-header" />
          <nav aria-label="Navegação do cliente">
            {clientNavigation.map((item) => {
              const Icon = item.icon;
              const active = item.href === "/cliente/agendar"
                ? pathname === "/cliente" || pathname.startsWith(item.href)
                : pathname.startsWith(item.href);
              return (
                <Link key={item.href} href={item.href} className={active ? "is-active" : ""}>
                  <Icon size={17} />
                  {item.label}
                </Link>
              );
            })}
          </nav>
        </div>
      </header>
      <div className="client-location-strip">
        <MapPin size={15} />
        <span>{demoMode ? "Vila Madalena · Rua Harmonia, 214" : "Unidade selecionada no contexto da reserva"}</span>
        {demoMode && <span className="client-location-strip__status">Aberto agora</span>}
      </div>
      <main className="client-main">{children}</main>
      <nav className="client-bottom-nav" aria-label="Navegação do cliente">
        {clientNavigation.map((item) => {
          const Icon = item.icon;
          const active = item.href === "/cliente/agendar"
            ? pathname === "/cliente" || pathname.startsWith(item.href)
            : pathname.startsWith(item.href);
          return (
            <Link key={item.href} href={item.href} className={active ? "is-active" : ""}>
              <Icon size={21} />
              <span>{item.label}</span>
            </Link>
          );
        })}
      </nav>
    </div>
  );
}

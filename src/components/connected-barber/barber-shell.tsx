"use client";

import Link from "next/link";
import { usePathname, useRouter } from "next/navigation";
import { useState } from "react";
import {
  Banknote,
  Bell,
  CalendarDays,
  FolderKanban,
  ChevronDown,
  LogOut,
  Menu,
  UserRound,
  X,
} from "lucide-react";
import { Avatar } from "@/components/ui";
import { getSupabaseBrowserClient } from "@/lib/supabase/browser";
import { productIdentityStyle } from "@/lib/product-identity";
import type { BarberAppContext } from "./types";

type BarberNavigationItem = { href: string; label: string; icon: typeof CalendarDays; disabled?: boolean };

function initials(name: string) {
  return name.split(/\s+/).filter(Boolean).slice(0, 2).map((part) => part[0]).join("").toUpperCase() || "BB";
}

function BarberNavigation({ navigation, profile, pathname, suffix, professionalName, onNavigate }: { navigation: BarberNavigationItem[]; profile: BarberNavigationItem; pathname: string; suffix: string; professionalName: string; onNavigate?: () => void }) {
  const isActive = (href: string) => pathname.startsWith(href);
  const link = (href: string) => `${href}${suffix}`;
  return <nav className="manager-nav" aria-label={`Navegação do ${professionalName}`}>
    {navigation.map((item) => {
      const Icon = item.icon;
      const active = isActive(item.href);
      if (item.disabled) return <button type="button" key={item.href} disabled aria-disabled="true"><Icon size={19} strokeWidth={1.8} /><span>{item.label}</span></button>;
      return <Link href={link(item.href)} key={item.href} className={active ? "is-active" : ""} aria-current={active ? "page" : undefined} onClick={onNavigate}><Icon size={19} strokeWidth={1.8} /><span>{item.label}</span></Link>;
    })}
    <p className="manager-nav__label manager-nav__label--second">Sistema</p>
    <Link href={link(profile.href)} className={isActive(profile.href) ? "is-active" : ""} aria-current={isActive(profile.href) ? "page" : undefined} onClick={onNavigate}><UserRound size={19} strokeWidth={1.8} /><span>Meu perfil</span></Link>
  </nav>;
}

export function BarberShell({ context, children }: { context: BarberAppContext; children: React.ReactNode }) {
  const pathname = usePathname() ?? "";
  const router = useRouter();
  const [menuOpen, setMenuOpen] = useState(false);
  const [signingOut, setSigningOut] = useState(false);
  const suffix = `?barbearia=${encodeURIComponent(context.organization_slug)}`;
  const identity = context.product_identity;
  const professionalName = identity?.vocabulary.professional ?? "barbeiro";
  const organizationPlural = identity?.vocabulary.organizationPicker ?? "Trocar barbearia";
  const navigation: BarberNavigationItem[] = [
    { href: "/barbeiro/agenda", label: "Agenda", icon: CalendarDays },
    ...(context.kanban_access_enabled ? [{ href: "/barbeiro/kanban", label: "Kanban", icon: FolderKanban }] : []),
    { href: "/barbeiro/caixa", label: "Caixa", icon: Banknote, disabled: !context.cash_access_enabled },
    ...(context.cash_access_enabled ? [{ href: "/barbeiro/financeiro", label: "Financeiro", icon: Banknote }] : []),
  ];
  const profile = { href: "/barbeiro/perfil", label: "Meu perfil", icon: UserRound };
  const currentInitials = initials(context.barber_name);

  async function signOut() {
    if (signingOut) return;
    setSigningOut(true);
    const supabase = getSupabaseBrowserClient();
    await supabase?.auth.signOut({ scope: "local" });
    router.replace(`/barbeiro/entrar?barbearia=${encodeURIComponent(context.organization_slug)}`);
    router.refresh();
  }

  function link(href: string) {
    return `${href}${suffix}`;
  }

  const organizationSwitcher = <Link className="organization-switcher barber-organization-switcher" href="/barbeiro" aria-label={organizationPlural}>
    <span className={`organization-switcher__mark${context.organization_logo_url ? " organization-switcher__mark--logo" : ""}`} role={context.organization_logo_url ? "img" : undefined} aria-label={context.organization_logo_url ? `Logo de ${context.organization_name}` : undefined} style={context.organization_logo_url ? { backgroundImage: `url("${context.organization_logo_url}")` } : undefined}>{!context.organization_logo_url && initials(context.organization_name)}</span>
    <span><strong>{context.organization_name}</strong></span><ChevronDown size={16} />
  </Link>;
  const topbarOrganization = <Link className="barber-topbar-org" href="/barbeiro" aria-label={organizationPlural} title={organizationPlural}>
    <span className={`barber-topbar-org__logo${context.organization_logo_url ? " has-logo" : ""}`} role={context.organization_logo_url ? "img" : undefined} aria-label={context.organization_logo_url ? `Logo de ${context.organization_name}` : undefined} style={context.organization_logo_url ? { backgroundImage: `url("${context.organization_logo_url}")` } : undefined}>{!context.organization_logo_url && initials(context.organization_name)}</span>
    <strong>{context.organization_name}</strong>
  </Link>;

  const accountFooter = <div className="manager-profile">
    <Link className="manager-profile__identity" href={link(profile.href)}><Avatar initials={currentInitials} tone="amber" /><span><strong>{context.barber_name}</strong><small>{professionalName[0]?.toLocaleUpperCase("pt-BR")}{professionalName.slice(1)}</small></span></Link>
    <button type="button" className="manager-profile__signout" onClick={() => void signOut()} disabled={signingOut} aria-label="Sair da conta" aria-busy={signingOut} title="Sair da conta"><LogOut size={17} aria-hidden="true" /></button>
  </div>;

  return <div className="manager-shell barber-manager-shell" style={productIdentityStyle(identity)}>
    <aside className="manager-sidebar">
      {organizationSwitcher}
      <BarberNavigation navigation={navigation} profile={profile} pathname={pathname} suffix={suffix} professionalName={professionalName} />
      <div className="manager-sidebar__footer">{accountFooter}</div>
    </aside>

    {menuOpen && <button className="mobile-overlay" type="button" aria-label="Fechar menu" onClick={() => setMenuOpen(false)} />}
    <aside className={`manager-drawer ${menuOpen ? "is-open" : ""}`} aria-hidden={!menuOpen} inert={!menuOpen}>
      <div className="manager-drawer__head"><strong>Menu</strong><button type="button" className="icon-button icon-button--dark" onClick={() => setMenuOpen(false)} aria-label="Fechar menu"><X size={20} /></button></div>
      {organizationSwitcher}
      <BarberNavigation navigation={navigation} profile={profile} pathname={pathname} suffix={suffix} professionalName={professionalName} onNavigate={() => setMenuOpen(false)} />
      <div className="manager-sidebar__footer">{accountFooter}</div>
    </aside>

    <div className="manager-workspace">
      <header className="manager-topbar">
        <button className="icon-button manager-topbar__menu" type="button" onClick={() => setMenuOpen(true)} aria-label="Abrir menu"><Menu size={21} /></button>
        {topbarOrganization}
        <div className="manager-topbar__actions"><button type="button" className="icon-button notification-button" aria-label="Notificações"><Bell size={19} /></button></div>
      </header>
      <main className={`manager-main${pathname.startsWith("/barbeiro/agenda") ? " barber-agenda-main" : ""}`}>{children}</main>
    </div>

    <div className="client-ad-footer-slot barber-ad-footer-slot" data-ad-slot="barber-footer" aria-label="Publicidade" />
  </div>;
}

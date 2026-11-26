"use client";

import Link from "next/link";
import { usePathname, useRouter } from "next/navigation";
import { CalendarDays, CalendarPlus2, ChevronRight, CreditCard, House, MapPin, Menu, UserRound, X } from "lucide-react";
import { useEffect, useMemo, useState } from "react";
import { ConnectedClientProvider, useConnectedClient } from "@/components/connected-client/context";
import { locationAddressLine } from "@/components/connected-client/format";
import styles from "@/components/connected-client/connected-client.module.css";
import { getSupabaseBrowserClient } from "@/lib/supabase/browser";
import { productIdentityStyle } from "@/lib/product-identity";
import { useNavigationAccess } from "./use-navigation-access";

const navigation = [
  { href: "/cliente/inicio", label: "Home", icon: House },
  { href: "/cliente/agendar", label: "Agendar", icon: CalendarPlus2 },
  { href: "/cliente/reservas", label: "Reservas", icon: CalendarDays },
  { href: "/cliente/assinaturas", label: "Assinaturas", icon: CreditCard },
  { href: "/cliente/perfil", label: "Perfil", icon: UserRound },
];

function ShellContent({ children }: { children: React.ReactNode }) {
  const pathname = usePathname() ?? "";
  const router = useRouter();
  const { context, customer, organizations, user, slug, entry, identity, switchTenant } = useConnectedClient();
  const [switcherOpen, setSwitcherOpen] = useState(false);
  const [targetSlug, setTargetSlug] = useState<string | null>(null);
  const suffix = slug ? `?barbearia=${encodeURIComponent(slug)}` : "";
  const target = targetSlug
    ? organizations.find((item) => item.organization_slug === targetSlug) ?? null
    : null;
  const supabase = useMemo(() => getSupabaseBrowserClient(), []);
  const { subscriptionAccess, commercialOfferUnread } = useNavigationAccess(
    supabase, context, customer, user,
  );
  useEffect(() => {
    if (pathname.startsWith("/cliente/assinaturas") && subscriptionAccess === false) {
      router.replace(`/cliente/reservas${suffix}`);
    }
  }, [pathname, router, subscriptionAccess, suffix]);
  const visibleNavigation = navigation;
  const logoPath = context?.organization.logo_path ?? entry?.logo_path;
  const logoUrl = logoPath && supabase
    ? supabase.storage.from("organization-logos").getPublicUrl(logoPath).data.publicUrl
    : null;
  const productLabel = (key: string | null | undefined) => ({
    "los-barberos": "Los Barberos", "le-gras": "Le Gras", "pro-stetic": "ProStetic", "music-pro": "MusicPro", "ateliepro": "AteliePro",
  })[key ?? ""] ?? "Produto indisponível";
  const isAccessPage = pathname === "/cliente/entrar" || pathname === "/cliente/redefinir-senha";
  const hasEstablishmentContext = Boolean(context || entry);
  const standaloneAccessPage = pathname === "/cliente/entrar" && !hasEstablishmentContext;
  const identityStyle = productIdentityStyle(identity);
  const themed = Boolean(identityStyle && entry?.product_key !== "los-barberos");

  return (
    <div className={`${styles.shell} ${themed ? styles.productTheme : ""} ${isAccessPage && themed ? styles.productAccess : ""}`} style={identityStyle}>
      <header className={styles.topbar}>
        <div className={styles.topbarInner}>
          <div className="client-header-ad-slot" data-ad-slot="client-header" />
          <nav className={styles.desktopNav} aria-label="Navegação do cliente">
            {visibleNavigation.map((item) => {
              const Icon = item.icon;
              const active = item.href === "/cliente/agendar"
                ? pathname === "/cliente" || pathname.startsWith(item.href)
                : pathname.startsWith(item.href);
              return (
                <Link key={item.href} href={`${item.href}${suffix}`} aria-current={active ? "page" : undefined} className={`${active ? styles.active : ""} ${item.href === "/cliente/assinaturas" && commercialOfferUnread ? styles.offerPulse : ""}`}>
                  <Icon size={17} aria-hidden="true" />
                  {item.label}
                </Link>
              );
            })}
          </nav>
        </div>
      </header>
      {hasEstablishmentContext && <div className={styles.locationStrip}>
        <div className={styles.locationDetails}>
          {logoUrl && <img className={styles.locationLogo} src={logoUrl} alt="" />}
          <span className={styles.locationText}>
            <strong>{context?.organization.name ?? "Selecione um estabelecimento"}</strong>
            <small><MapPin size={14} aria-hidden="true" />{locationAddressLine(context?.location?.address)}</small>
          </span>
        </div>
        {user && (
          <button type="button" className={styles.tenantMenuButton} onClick={() => setSwitcherOpen((open) => !open)} aria-label="Estabelecimentos" title="Estabelecimentos" aria-expanded={switcherOpen} aria-controls="client-tenant-menu">
            {switcherOpen ? <X size={19} aria-hidden="true" /> : <Menu size={19} aria-hidden="true" />}
          </button>
        )}
      </div>}
      <main className={`${styles.main} ${standaloneAccessPage ? styles.standaloneAccessMain : ""}`}>{children}</main>
      {switcherOpen && (
        <section id="client-tenant-menu" className={styles.tenantMenu} aria-label="Trocar de estabelecimento">
          <div className={styles.tenantMenuHeader}>
            <strong>Meus estabelecimentos</strong>
            <span className="brand__mark" aria-hidden="true"><span>D</span></span>
          </div>
          {organizations.filter((item) => item.organization_slug !== slug).map((item) => (
            <button key={item.organization_id} type="button" onClick={() => setTargetSlug(item.organization_slug)}>
              <span>{item.organization_name} · {productLabel(item.product_key)}</span><ChevronRight size={16} aria-hidden="true" />
            </button>
          ))}
          {organizations.length <= 1 && <p>Você não tem outros estabelecimentos disponíveis.</p>}
        </section>
      )}
      {target && (
        <section className={styles.switchConfirm} role="dialog" aria-modal="true" aria-labelledby="shell-switch-title">
          <p>Trocar de estabelecimento</p>
          <h2 id="shell-switch-title">Abrir {target.organization_name}?</h2>
          <span>Agenda e histórico exibidos passarão a pertencer ao novo estabelecimento.</span>
          <div>
            <button type="button" className={styles.secondaryButton} onClick={() => setTargetSlug(null)}>Cancelar</button>
            <button type="button" className={styles.primaryButton} onClick={() => {
              switchTenant(target.organization_slug);
              setTargetSlug(null);
              setSwitcherOpen(false);
            }}>Confirmar troca</button>
          </div>
        </section>
      )}
      <nav className={styles.bottomNav} aria-label="Navegação do cliente">
        {visibleNavigation.map((item) => {
          const Icon = item.icon;
          const active = item.href === "/cliente/agendar"
            ? pathname === "/cliente" || pathname.startsWith(item.href)
            : pathname.startsWith(item.href);
          return (
            <Link key={item.href} href={`${item.href}${suffix}`} aria-current={active ? "page" : undefined} className={`${active ? styles.active : ""} ${item.href === "/cliente/assinaturas" && commercialOfferUnread ? styles.offerPulse : ""}`}>
              <Icon size={21} aria-hidden="true" />
              <span>{item.label}</span>
            </Link>
          );
        })}
      </nav>
    </div>
  );
}

export function ConnectedClientShell({
  children,
  initialSlug = null,
}: {
  children: React.ReactNode;
  initialSlug?: string | null;
}) {
  return (
    <ConnectedClientProvider initialSlug={initialSlug}>
      <ShellContent>{children}</ShellContent>
    </ConnectedClientProvider>
  );
}

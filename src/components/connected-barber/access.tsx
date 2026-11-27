import Image from "next/image";
import Link from "next/link";
import { ArrowRight, Building2, ShieldCheck } from "lucide-react";
import { Brand } from "@/components/brand";
import { BarberAccountProfileForm } from "./account-profile";
import type { BarberAccountProfile, BarberAppContext } from "./types";
import styles from "./access.module.css";

function initials(value: string) {
  return value.split(/\s+/u).filter(Boolean).slice(0, 2).map((part) => part[0]).join("").toUpperCase();
}

export function BarberConnectionScreen({ organizations, mode = "choose" }: { organizations: BarberAppContext[]; mode?: "choose" | "switch" }) {
  const switching = mode === "switch";
  return (
    <main className={`${styles.page} ${switching ? styles.organizationSwitcherPage : ""}`}>
      <header className={`${styles.header} ${switching ? styles.organizationSwitcherHeader : ""}`}>
        {switching
          ? <Brand href="/cliente" name="Display" tagline="App" mark="D" />
          : <Brand light name="Display SH" tagline="Sua equipe, conectada" mark="DS" />}
      </header>
      <section className={`${styles.panel} ${switching ? styles.organizationSwitcherPanel : ""}`} aria-labelledby="barber-connection-title">
        <div className={styles.panelHeading}>
          <span className={styles.headingIcon}><Building2 size={24} /></span>
          <div>
            <h1 id="barber-connection-title">{switching ? "Alterar Equipe" : "Escolha um estabelecimento"}</h1>
            {!switching && <p>Você está conectado a {organizations.length} estabelecimentos. Escolha qual deseja acessar.</p>}
          </div>
        </div>
        <ul className={styles.organizationList} aria-label="Estabelecimentos conectados">
          {organizations.map((organization) => (
            <li className={styles.organizationItem} key={organization.organization_id}>
              {organization.organization_logo_url ? (
                <Image className={styles.organizationLogo} src={organization.organization_logo_url} alt={`Logo da ${organization.organization_name}`} width={76} height={76} sizes="76px" />
              ) : (
                <span className={styles.organizationFallback} aria-hidden="true">{initials(organization.organization_name)}</span>
              )}
              <strong>{organization.organization_name}</strong>
              <Link className={styles.enterButton} href={`/barbeiro/agenda?barbearia=${encodeURIComponent(organization.organization_slug)}`}>
                {switching ? "Alterar" : "Entrar"} <ArrowRight size={18} />
              </Link>
            </li>
          ))}
        </ul>
      </section>
    </main>
  );
}

export function BarberDisconnectedScreen({ profile, email }: { profile: BarberAccountProfile; email: string | null }) {
  return (
    <main className={styles.page}>
      <header className={styles.header}><Brand light name="Display SH" tagline="Sua equipe, conectada" mark="DS" /></header>
      <section className={`${styles.panel} ${styles.disconnectedPanel}`} aria-labelledby="barber-disconnected-title">
        <div className={styles.panelHeading}>
          <span className={styles.headingIcon}><ShieldCheck size={24} /></span>
          <div>
            <h1 id="barber-disconnected-title">Você não está conectado a nenhum estabelecimento.</h1>
            <p>Quando um gestor liberar seu acesso, o estabelecimento aparecerá aqui.</p>
          </div>
        </div>
        <BarberAccountProfileForm profile={profile} email={email} />
      </section>
    </main>
  );
}

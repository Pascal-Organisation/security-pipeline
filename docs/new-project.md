# Neues Projekt an die Pipeline anbinden

Ein neues Repo braucht nur wenige Zeilen: Es ruft die Workflows hier auf und trägt sich in
`fleet/repos.json` ein. Tools und Regeln bleiben in diesem Repo.

## 1. Profil wählen

| Das Projekt ist … | Profil | Workflows | Vorlage |
|---|---|---|---|
| nur Code oder Skripte, öffentlich oder privat | `ci-only` | `ci` | `homelab`, `anmeldungunihandball` |
| Container, öffentlich | `container-pull` | `ci`, `build-container`; Host holt selbst | `solar` |
| Container, privat | `container-push` | `ci`, `build-container`, `deploy-container` | `tickets` (noch nicht im Betrieb erprobt) |
| statische Seite, privat, eigener Host | `static-ssh` | `ci`, `deploy-static`, `dast` | `pascalhaag-website` |
| statische Seite oder PHP, privat, Shared Hosting | `static-ftps` | `ci`, `deploy-static`, `dast` | `websiteghana` |

Sichtbarkeit legt die Pipeline selbst fest:

| | öffentlich | privat |
|---|---|---|
| Runner | GitHub-hosted, immer | self-hosted, Label `ci` |
| SAST | CodeQL (`sast-languages`) | Semgrep, dazu Bandit bei `python-paths` |
| Signatur | keyless | Org-Key, kein öffentlicher Eintrag |

`deploy-static` und `deploy-container` laufen nur in privaten Repos, weil sie einen
self-hosted Runner brauchen. Für eine **öffentliche statische Seite** gibt es noch kein Profil.

## 2. Repo anlegen

- In der Org anlegen, Standard-Branch `main`.
- `renovate.json`:

  ```json
  {
    "$schema": "https://docs.renovatebot.com/renovate-schema.json",
    "extends": ["local>Pascal-Organisation/security-pipeline//renovate/default"]
  }
  ```

- Dependabot **nicht** zusätzlich einrichten (`.github/dependabot.yml` weglassen).
- `templates/pre-commit-config.yaml` als `.pre-commit-config.yaml` übernehmen.
- Öffentliches Repo: `SECURITY.md` anlegen.

## 3. CI-Gate einbinden

Den aktuellen Commit des neuesten Releases holen:

```bash
gh api repos/Pascal-Organisation/security-pipeline/commits/$(cat VERSION) --jq .sha
```

`.github/workflows/ci.yml`, passend für jedes Profil:

```yaml
name: CI

on:
  pull_request:
  push:
    branches: [main]
  schedule:
    - cron: "41 4 * * 1" # wöchentlich: ganze Historie auf Secrets, frische CVE-Daten
  workflow_dispatch:

permissions: {}

concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true

jobs:
  security:
    name: Security # Pflicht: ergibt den Check "Security / security-gate"
    uses: Pascal-Organisation/security-pipeline/.github/workflows/ci.yml@<sha> # vX.Y.Z
    permissions:
      contents: read
      actions: read
      security-events: write
    with:
      private-runner: '["self-hosted","ci"]' # öffentliche Repos ignorieren das
      sast-languages: python,actions         # nur öffentlich wirksam
      python-paths: src                      # nur privat wirksam
      dockerfile: Dockerfile                 # weglassen, wenn es keins gibt
```

Die `permissions` sind eine Obergrenze und müssen auch für übersprungene Jobs reichen. Der
Pin mit Versions-Kommentar ist wichtig: Daran erkennt Renovate die Version.

Die Trivy-Prüfung sieht Abhängigkeiten **nur über Lockfiles oder Requirements-Dateien**. Ohne
eine solche Datei bleibt sie blind, auch wenn das Gate grün ist.

## 4. Profil-Teil ergänzen

Am besten von der Vorlage aus der Tabelle kopieren.

### Container, öffentlich (`container-pull`)

`release.yml` wie in `solar`: `ci`, dann `build-container`, Permissions `contents: read`,
`packages: write`, `id-token: write`. Auf dem Host:

```bash
tools/fleet-hosts.sh --upgrade <tag>   # erst Eintrag mit ct und deployer: app-deploy anlegen
# /etc/app-deploy/<app>.conf nach deployer/app.conf.example, gehört root
# systemd-Timer ruft /usr/local/sbin/app-deploy <app> auf
```

**Nach dem ersten Release das Paket öffentlich stellen**
(`https://github.com/orgs/Pascal-Organisation/packages/container/<repo>/settings`). Neue
Pakete sind privat, der Host zieht ohne Login und bekommt sonst `unauthorized`, während die
Release-Pipeline grün bleibt.

### Container, privat (`container-push`)

- Secrets `COSIGN_PRIVATE_KEY` und `COSIGN_PASSWORD` freigeben; an `build-container` als
  `signing-key` und `signing-password` übergeben.
- Deploy-Runner auf VM 111 mit dem Label `<repo>-deploy` registrieren.
- Auf dem Host `cosign.pub` ablegen und im `authorized_keys` den Key festnageln:
  `restrict,from="<IP VM 111>",command="/usr/local/sbin/app-deploy <app>" ssh-ed25519 …`

### Statische Seite (`static-ssh`, `static-ftps`)

- Eigener Build-Job lädt das Artefakt `site` mit der Datei `site.tgz` hoch.
- CI-Runner: privat reicht das Org-Label `ci`; die bestehenden Seiten haben eigene Runner.
- Deploy-Runner auf VM 111 mit dem Label `<repo>-deploy` registrieren.
- `static-ssh`: Secrets `DEPLOY_SSH_KEY`, `DEPLOY_KNOWN_HOSTS`, Receive-Skript auf dem Ziel.
- `static-ftps`: Secrets `FTP_HOST`, `FTP_USER`, `FTP_PASS`; es wird nie gelöscht.
- `dast.yml` nach dem Deploy aufrufen (oder vorher gegen Staging), nur gegen eigene Seiten.

## Regel: Kein Deploy ohne grünes Gate

Das gilt für **jedes** deployende Repo, auch privat. Der GitHub-Free-Plan kann in privaten
Repos keinen Merge blockieren, ein Workflow kann aber den Deploy verweigern:

```yaml
deploy:
  needs: [security, build] # bzw. build mit needs: ci
  if: github.ref == 'refs/heads/main' && github.event_name != 'pull_request'
```

Ohne `if: always()`, sonst läuft der Job trotz rotem Gate. Eine Release per Tag prüft stattdessen
den Check `Security / security-gate` für genau diesen Commit (`websiteghana`, Job `verify`).

Grenze: Wer Schreibrechte hat, kann den Workflow selbst ändern und das `needs` entfernen. In
privaten Repos ohne Schutz von `main` lässt sich das nicht ausschließen. Das Ziel muss deshalb
selbst prüfen, wo es geht: `app-deploy` nimmt nur Images mit gültiger Signatur und Provenance.
Statische Artefakte sind noch unsigniert (siehe Roadmap).

## 5. In die Flotte eintragen

`fleet/repos.json` per PR ergänzen:

```json
{ "name": "mein-projekt", "profile": "ci-only", "ring": "stable", "gate_check": "Security / security-gate" }
```

Container zusätzlich mit `"ct": 132, "deployer": "app-deploy"`, Abweichungen vom Standard
mit `"note"`. `canary` bleibt den beiden Repos in `renovate/default.json` vorbehalten.

## 6. Prüfen und scharf schalten

1. PR im neuen Repo: `Security / security-gate` muss grün sein.
2. Prüfen, dass der Deploy per `needs` am Gate hängt (siehe Regel oben).
3. `tools/fleet-status.sh` zeigt das Repo mit aktuellem Pin.
4. Öffentliches Repo: `tools/fleet-rulesets.sh`, Ausgabe lesen, dann `--apply`. Private Repos
   lassen sich im GitHub-Free-Plan nicht schützen; das Gate meldet dort nur.
5. Container: Ersten Deploy auf dem Host ansehen (`SSH_ORIGINAL_COMMAND=status
   /usr/local/sbin/app-deploy <app>`). Grün in GitHub heißt noch nicht, dass er angekommen ist.

## Stolperfallen

- **Repo umbenennen oder verschieben** ändert Image-Pfad und Signatur-Identität. Der Host muss
  mit umziehen, sonst bleibt er ohne Fehlermeldung auf der alten Version.
- **Der Aufrufer-Job muss `Security` heißen**, sonst stimmt der Pflicht-Check nicht.
- **Keine Tool-Namen voraussetzen:** weder im Workflow noch in Rulesets, sondern nur
  `security-gate`. Sonst bricht der nächste Tool-Tausch das Repo
  ([switching-tools.md](switching-tools.md)).
- **Ausnahmen** nur über `.security/exceptions.json`, immer mit Begründung und Ablaufdatum.
- **Eigene Tests** gehören als eigene Jobs ins Repo, die Sicherheits-Gates nicht.

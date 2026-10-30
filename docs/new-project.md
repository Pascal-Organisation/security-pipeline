# Neues Projekt an die Pipeline anbinden

Ein neues Repo braucht nur wenige Zeilen: Es ruft die Workflows hier auf und trägt sich in
`fleet/repos.json` ein. Tools und Regeln bleiben in diesem Repo.

## 1. Profil wählen

| Das Projekt ist … | Profil | Workflows | Vorlage |
|---|---|---|---|
| nur Code oder Skripte | `ci-only` | `ci` | `homelab`, `anmeldungunihandball` |
| läuft auf einem eigenen Host, auch als statische Seite | `container-pull` | `ci`, `build-container` | `solar`, `bahnbot` |
| Shared Hosting ohne eigene Prüfung, privat | `static-ftps` | `ci`, `deploy-static`, `dast` | `websiteghana` |

Sichtbarkeit legt die Pipeline selbst fest:

| | öffentlich | privat |
|---|---|---|
| Runner | GitHub-hosted, immer | self-hosted, Label `ci` |
| SAST | CodeQL (`sast-languages`) | Semgrep, dazu Bandit bei `python-paths` |
| Signatur | keyless | keyless; der Repo-Name steht im öffentlichen Rekor-Log |

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

### Container (`container-pull`)

`release.yml` wie in `solar`: bei Push auf `main` `build-container` aufrufen. Permissions: `contents:
read`, `actions: read`, `security-events: write`, `pull-requests: read`, `packages: write`, `id-token:
write`. Das Gate läuft darin, es muss nicht extra aufgerufen werden. Auf dem Host:

```bash
# Eintrag mit ct, app und deployer: app-deploy in fleet/repos.json anlegen, dann:
tools/fleet-hosts.sh --upgrade <tag>
# /etc/app-deploy/<app>.conf nach deployer/app.conf.example, gehört root
# systemd-Timer ruft /usr/local/sbin/app-deploy <app> auf
```

Compose und Konfiguration gehören ins Image (`BUNDLE_FROM_IMAGE`), Secrets bleiben auf dem Host.
Der Host braucht Lesezugriff auf das Image: **öffentliche Repos** stellen das Paket nach dem ersten
Release öffentlich (`https://github.com/orgs/Pascal-Organisation/packages/container/<repo>/settings`),
**private Repos** nutzen den Lese-Login aus der README. Sonst meldet der Host `unauthorized`, während
die Release-Pipeline grün bleibt.

### Shared Hosting (`static-ftps`)

- Eigener Build-Job lädt das Artefakt `site` mit der Datei `site.tgz` hoch.
- Secrets `FTP_HOST`, `FTP_USER`, `FTP_PASS`; es wird nie gelöscht.
- `dast.yml` nach dem Deploy aufrufen (oder vorher gegen Staging), nur gegen eigene Seiten.

## Regel: Kein Deploy ohne grünes Gate

Das gilt für jedes deployende Repo, auch privat. Der GitHub-Free-Plan kann in privaten Repos keinen
Merge blockieren, die Pipeline aber das Release:

- **`container-pull`:** Das Gate läuft in `build-container.yml`, und der Host akzeptiert nur dessen
  Signatur. Ein Repo kann das nicht umgehen, auch nicht durch Ändern seines eigenen Workflows.
- **`static-ftps`:** `deploy-static.yml` prüft vor dem Upload selbst Gate und `main`. Das Ziel prüft
  nichts, deshalb hilft hier nur diese Prüfung. Wer den Workflow im Repo ändert, kommt daran vorbei.

## 5. In die Flotte eintragen

`fleet/repos.json` per PR ergänzen:

```json
{ "name": "mein-projekt", "profile": "ci-only", "ring": "stable", "gate_check": "Security / security-gate" }
```

Container zusätzlich mit `"ct": 132, "app": "solar", "deployer": "app-deploy"`, Abweichungen vom
Standard mit `"note"`. `canary` bleibt den beiden Repos in `renovate/default.json` vorbehalten.

## 6. Prüfen und scharf schalten

1. PR im neuen Repo: `Security / security-gate` muss grün sein.
2. Ersten Release abwarten: Policy, Gate, Build und Signatur müssen grün sein.
3. `tools/fleet-status.sh` zeigt das Repo mit aktuellem Pin.
4. Öffentliches Repo: `tools/fleet-rulesets.sh`, Ausgabe lesen, dann `--apply`. Private Repos
   lassen sich im GitHub-Free-Plan nicht schützen; das Gate meldet dort nur.
5. Container: `tools/fleet-hosts.sh`. Grün in GitHub heißt noch nicht, dass er angekommen ist.

## Stolperfallen

- **Repo umbenennen oder verschieben** ändert Image-Pfad und Signatur-Identität. Der Host muss
  mit umziehen, sonst bleibt er ohne Fehlermeldung auf der alten Version.
- **Der Aufrufer-Job muss `Security` heißen**, sonst stimmt der Pflicht-Check nicht.
- **Keine Tool-Namen voraussetzen:** weder im Workflow noch in Rulesets, sondern nur
  `security-gate`. Sonst bricht der nächste Tool-Tausch das Repo
  ([switching-tools.md](switching-tools.md)).
- **Ausnahmen** nur über `.security/exceptions.json`, immer mit Begründung und Ablaufdatum.
- **Eigene Tests** gehören als eigene Jobs ins Repo, die Sicherheits-Gates nicht.

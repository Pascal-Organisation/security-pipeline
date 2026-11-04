# Tools austauschen

Ziel: Ein Scanner, ein Signier-Verfahren oder eine Regel wird **hier** getauscht. Die Repos
merken davon nichts, außer einem Pin-Update durch Renovate.

## Der Vertrag (was Repos von der Pipeline kennen)

Nur das hier darf ein Repo voraussetzen. Eine Änderung daran ist ein **Major-Release**.

| Vertrag | Wert |
|---|---|
| Pflicht-Check | `Security / security-gate` (Aufrufer-Job heißt `Security`) |
| `ci.yml`-Inputs | `sast-languages`, `python-paths`, `dockerfile`, `scan-skip-dirs` (`private-runner`: veraltet, wird ignoriert) |
| `build-container.yml` | Inputs `context`, `dockerfile`, `target`, `submodules`, `sast-languages`, `python-paths`, `scan-skip-dirs` (`private-runner`: veraltet, wird ignoriert); Workflow-Pfad = Signatur-Identität |
| Ausnahmen | `.security/exceptions.json` |

Jobnamen wie `SAST (private)` nennen Fähigkeiten, nicht Tools. Niemand sollte sie als Check
voraussetzen; es zählt nur `security-gate`.

## Ablauf: ein Tool ersetzen

Beispiel: Trivy durch etwas anderes ersetzen. Seit v3 steckt jedes Tool im Image `ci-toolbox`
(`toolbox/Dockerfile`): Ein neues Tool kommt zuerst dort hinein (per Digest gepinnt aus seinem offiziellen
Image), `toolbox.yml` baut und signiert die neue Toolbox, danach wird der Digest in `TOOLBOX`
(`ci.yml` und `build-container.yml`) angehoben. Aufgerufen wird es in den Workflows über `tb <tool>`.

1. **Testen:** Neuer Job in `ci.yml`, der nur berichtet und immer grün endet, **nicht** in den
   `needs` von `security-gate`. Kein `continue-on-error`: Der rote Check würde Renovates
   Automerge aufhalten. Release als Minor. Die Ringe rollen es aus, nichts blockiert.
2. **Vergleichen:** Ein bis zwei Releases lang Funde beider Tools ansehen,
   `tools/fleet-status.sh` zeigt den Stand.
3. **Umschalten:** Neuen Job in `needs` aufnehmen, Fund als Fehler werten, alten Job
   löschen. Ausnahmen im selben Commit auf den neuen Scanner übersetzen. Release als Minor,
   solange der Vertrag gleich bleibt.

Kein Aufrufer ändert sich. Bricht der Vertrag doch (neuer Input, neues Secret), ist es ein
Major: Renovate merged das nicht selbst.

## Ablauf: Signieren oder Verifizieren ändern

Hier hängt zusätzlich die Admission im Cluster dran, deshalb mit Überlappung:

1. In den `ClusterImagePolicy`-Objekten beide Identitäten erlauben (je ein `authorities`-Eintrag mit
   `identities`, `issuer` GitHub-OIDC und `subjectRegExp` auf `…/alt.yml@<sha>` bzw. `…/neu.yml@<sha>`),
   beide auf Release-Commits gepinnt.
2. Pipeline umstellen, releasen, einen Deploy abwarten.
3. Die alte Identität aus den Policies entfernen.

`build-container.yml` nicht umbenennen oder verschieben, ohne Schritt 1: Die Policies erlauben genau
diesen Pfad.

Neue Pipeline-Releases muss der Cluster kennen, bevor ein Aufrufer sie nutzt: erst Tag, dann dessen SHA
in die `ClusterImagePolicy`-Objekte, dann die Aufrufer (Renovate) anheben. Ein Release aus einem Commit,
der nicht auf `main` liegt, landet nie in den Policies. (Hosts mit dem Legacy-Agent `app-deploy`:
`tools/fleet-hosts.sh --upgrade <tag>`.)

## Rollout-Ringe

| Ring | Repos | Wann |
|---|---|---|
| `canary` | `workingrepo` (privat), `anmeldungunihandball` (öffentlich) | sofort |
| `stable` | alle anderen | 3 Tage nach dem Release |

Festgelegt in `renovate/default.json`, gespiegelt in `fleet/repos.json`. Minor und Patch
merged Renovate selbst, sobald alles grün ist. Majors immer von Hand. Commit-SHA-Pins bleiben.
Automerge ist nur vertretbar, solange `main` und die Tags hier per Ruleset geschützt sind
(`tools/fleet-rulesets.sh`).

## Release

1. `VERSION`, `PIPELINE_VERSION` in `build-container.yml` und `APP_DEPLOY_VERSION` in
   `deployer/app-deploy` gleich setzen. `self-check` prüft das, auch gegen den Tag.
2. Toolbox-Digest: `toolbox.yml` auf `main` bauen lassen, den Digest in `TOOLBOX` in `ci.yml` und
   `build-container.yml` eintragen (Renovate tut das nach dem ersten Mal selbst).
3. Tag und GitHub-Release anlegen.
4. SHA des Release-Commits in die `ClusterImagePolicy`-Objekte des App-Clusters aufnehmen, danach erst
   die Aufrufer anheben. Hosts mit dem Legacy-Agent: `tools/fleet-hosts.sh --upgrade <tag>`.

## Ausnahmen

`.security/exceptions.json` im jeweiligen Repo, die Pipeline übersetzt sie für den Scanner:

```json
{
  "exceptions": [
    {
      "id": "CVE-2026-12345",
      "kind": "vulnerability",
      "reason": "Betroffene Funktion wird nicht aufgerufen",
      "expires": "2027-01-31"
    }
  ]
}
```

`kind` ist `vulnerability` (Standard), `misconfiguration`, `secret` oder `license`.
`reason` und `expires` sind Pflicht; nach Ablauf blockiert der Fund wieder.

## Laufende Tests

| Job | Zweck | Status |
|---|---|---|
| `Shell lint (trial)` | shellcheck über alle `.sh`-Dateien | berichtet nur, Bestandsfunde zuerst ansehen |
| `Runtime images (trial)` | Trivy über die in Compose-Dateien genannten Images | berichtet nur |

Beide stehen in der Job-Summary. Ins Gate kommen sie erst, wenn die Funde abgearbeitet sind.

## Überblick und Betrieb

| Befehl | Zweck |
|---|---|
| `tools/fleet-status.sh` | Pin, offene PRs, letzter Lauf, Pflicht-Check pro Repo |
| `tools/fleet-rulesets.sh [--apply]` | `security-gate` als Pflicht-Check setzen |
| `tools/fleet-hosts.sh [--upgrade <tag>]` | Legacy: `app-deploy`-Version auf Hosts, die noch keinen Cluster nutzen (über `ssh proxmox`) |

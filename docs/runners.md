# Self-hosted Runner

Private Repos der Organisation bauen auf eigener Hardware (Proxmox). Öffentliche Repos nutzen diese
Runner nie (siehe unten). Dieses Dokument beschreibt, wie die Runner voneinander getrennt sind, was
mit Kubernetes versucht wurde und warum das (noch) nicht produktiv läuft.

## Stand

| Was | Wie | Status |
|---|---|---|
| **Eine Runner-VM pro Vertrauensbereich** | jedes Repo, das etwas ausliefert (Image, Website), hat eine eigene VM mit eigenem Docker-Daemon; die reinen CI-Repos teilen sich eine weitere | **produktiv** |
| ARC auf k3s, **eine Kata-microVM pro Job** | [Actions Runner Controller](https://github.com/actions/actions-runner-controller) + [Kata Containers](https://katacontainers.io/); jeder Job in einer frischen microVM, danach gelöscht | gebaut, **nur als Versuch** (Label `arc-trial`) |

Konfiguration des Kubernetes-Aufbaus als Beispiel in [`runners/arc/`](../runners/arc/) – ohne
Geheimnisse und ohne Interna des Homelabs.

## Warum überhaupt

Anfangs liefen alle Self-hosted Runner persistent auf **einer** VM, als **ein** Linux-User, an
**einem** rootful Docker-Daemon. Zugriff auf den Docker-Socket ist faktisch root. Ein Job eines
beliebigen privaten Repos – etwa über eine kompromittierte Abhängigkeit in einem Renovate-PR – hätte:

- das Image eines anderen Repos zwischen Trivy-Scan und Push austauschen können. Die Signatur wäre
  trotzdem gültig gewesen: Sie beweist, dass `build-container.yml` lief, nicht was der Runner gebaut hat;
- die Registrierungsdaten der anderen Runner lesen und deren Jobs (samt `GITHUB_TOKEN` mit
  `packages: write`) abgreifen können.

## Produktiv: eine VM pro Vertrauensbereich

- Jedes ausliefernde Repo hat seinen **eigenen** Runner auf einer **eigenen** VM (Repo-Runner, nicht
  Org-Runner). Ein Job von Repo A erreicht weder Daemon, Images, Arbeitsverzeichnis noch
  Registrierung von Repo B.
- Die Repos ohne Auslieferung (nur CI) teilen sich einen Org-Runner auf einer weiteren VM.
- Jede VM: Proxmox-Firewall default deny, eingehend nur SSH vom Hypervisor, ausgehend nur DNS
  (Router), 80/443, NTP – kein LAN.
- Gleiche Runner-Namen und Labels wie zuvor; kein Caller musste sich ändern.

**Offen benannt:** Innerhalb eines Repos bleibt der Runner persistent. Ein PR-Job kann also Reste für
den nächsten Release **desselben** Repos hinterlassen. In der Praxis öffnen nur der Owner und Renovate
PRs, und eine bösartige Abhängigkeit, die Renovate mergt, würde ohnehin ausgeliefert. Die VMs lassen
sich per Skript in Minuten neu aufsetzen, wenn man diesen Rest begrenzen will.

## Versuch: ARC auf k3s, eine Kata-microVM pro Job

Das Ziel: nichts überlebt einen Job, und die Trennung hängt nicht mehr davon ab, welches Repo
welchen Runner bekommt.

```
GitHub ◄──── nur ausgehend (443) ────────────────────────────────────┐
                                                                     │
k3s-Knoten (VM, Proxmox-Firewall: default deny, kein LAN)            │
├─ arc-systems/  Controller + Listener  ── GitHub-App-Token ─────────┘
└─ arc-runners/  ein Pod pro Job, runtimeClass kata-qemu
     └─ Kata-microVM (eigener Kernel, 2 vCPU / 3,5 GB)
          ├─ runner   actions-runner, Docker-Client, kein Service-Account-Token
          └─ dind     docker:dind, privileged – aber nur in dieser microVM
                └─ /var/lib/docker = ext4 auf Loop-Device mit Direct-I/O
```

| Angriff aus einem Job | Ergebnis |
|---|---|
| Container-Ausbruch aus Scanner oder Build | landet im `dind`-Container – in derselben microVM |
| root im privilegierten `dind` | root in der microVM; deren Kernel ist nicht der des Knotens |
| Spuren für spätere Jobs | Pod, microVM und Docker-Disk werden nach dem Job gelöscht |
| Kubernetes-API | Runner-Pods ohne Service-Account-Token, Service-Account ohne Rechte |
| Ins LAN | Firewall am Knoten wie oben |

Zugang zu GitHub: eine eigene, private GitHub App mit **genau einer** Berechtigung –
*Organization → Self-hosted runners: Read and write*. Keine Repo-Rechte, keine Webhooks. Der Schlüssel
liegt nur als Kubernetes-Secret auf dem Knoten (k3s mit `secrets-encryption`); Runner-Pods sehen ihn
nie, sie bekommen nur eine Just-in-time-Registrierung für genau einen Job. Grenze: Ein Ausbruch aus
Kata/QEMU wäre root auf dem Knoten – und mit dem App-Schlüssel ließen sich Runner registrieren, die
Jobs privater Repos abgreifen. Der Knoten wäre damit die Vertrauensbasis für alle privaten Builds.

### Warum nur Versuch

Der Knoten ist selbst eine VM. Die Job-microVMs laufen also **verschachtelt** (nested
virtualization) auf einem kleinen 4-Kern-Host. Leichte Jobs (Linter, Semgrep, Bandit, TruffleHog,
Trivy auf Dateien) laufen. Unter mehr I/O – Images ziehen, `docker build`, `docker save` und Trivy auf
das Tar, also genau das, was `build-container.yml` bei jedem Release tut – friert der Gast so lange ein,
dass Kata den Agenten für tot erklärt (`CheckRequest timed out`, `Dead agent`) und die microVM
abräumt; in einem Test 16-mal in 25 Minuten normaler CI.

Ein Security-Gate, das zufällig scheitert, ist schlechter als ein langsameres: Releases blieben
hängen, und Renovate merged nur bei grünen Checks. Deshalb tragen die produktiven Runner die Jobs,
und das Scale Set hat nur das Label `arc-trial` (`runs-on: [self-hosted, arc-trial]` zum Ausprobieren).

Auf einem Knoten **ohne** Verschachtelung (Bare Metal) ist das Problem nicht zu erwarten. Umstellen
heißt dann: die echten Labels ins Scale Set, Scale Set neu anlegen, VM-Runner abmelden.

### Stolpersteine beim Aufbau

Für alle, die das nachbauen – jeder davon hat Jobs scheitern lassen:

1. **overlayfs auf virtio-fs geht nicht.** Kata reicht `emptyDir`-Volumes per virtio-fs in die
   microVM; Docker kann darauf keine Layer stapeln (`invalid argument`). Lösung: sparse Datei, als
   ext4 formatiert, per Loop-Device nach `/var/lib/docker`.
2. **Loop-Device nur mit Direct-I/O.** Gepuffert liegt jeder Schreibzugriff in zwei Page-Caches
   des Gasts (ext4 und die Datei auf virtio-fs). Große Pulls füllten den RAM schneller, als virtio-fs
   ihn leerte. `losetup --direct-io=on` (util-linux; BusyBox in `docker:dind` kann das nicht) in einem
   privilegierten Init-Container – Loop-Devices gehören dem Gast-Kernel, `dind` mountet dasselbe Gerät.
3. **Unix-Sockets über virtio-fs gehen nicht** – nicht einmal zwischen zwei Containern derselben
   microVM. Das Socket-Volume ist `emptyDir` mit `medium: Memory`; Kata macht daraus ein tmpfs im Gast.
4. **`docker:dind` deklariert `VOLUME /var/lib/docker`.** Dort ist immer schon etwas gemountet;
   „ist ein Mountpoint" reicht als Prüfung nicht. Geprüft wird auf die eigene ext4-Disk.
5. **Keine Pod-Limits.** Kata steckt für Limits vCPUs und RAM im laufenden Betrieb an; angesteckte vCPUs
   blieben in der verschachtelten VM hängen (`rcu_sched self-detected stall`). Die microVM bekommt
   ihre Größe stattdessen per Kata-Drop-in beim Start; die Pods setzen nur Requests, damit der
   Scheduler den echten Platzbedarf kennt. Kubernetes verlangt dabei Request ≤ Limit pro Container.
6. **virtiofsd mit einem Thread** (Kata-Vorgabe) serialisiert alle Datei-Zugriffe des Gasts; jetzt 8.
7. **ARC setzt die Labels nur beim Anlegen des Scale Sets.** Ein `helm upgrade` mit neuen Labels
   ändert auf GitHub nichts – Jobs bleiben ungezuordnet. Labels ändern = `helm uninstall` + `install`.
8. **Nicht das Pod-Template ändern, während Runner Jobs haben.** ARC ersetzt dann Runner, denen GitHub
   schon Jobs zugeteilt hat; die Jobs hängen, bis man den Run abbricht.
9. **`mkfs.ext4`** fehlt in `docker:dind` und in `debian:trixie-slim`; das Runner-Image hat es.

### Versionen

Alles gepinnt; Images per Digest (siehe `runners/arc/`).

| Komponente | Version |
|---|---|
| k3s | v1.36.5+k3s1 (Binary gegen `sha256sum-amd64.txt` geprüft) |
| Helm | v4.3.1 (gegen die veröffentlichte SHA-256 geprüft) |
| Kata Containers (kata-deploy) | 4.3.1, nur QEMU-Shim |
| ARC (Controller + Scale Set) | 0.15.1 |
| Runner-Image | `ghcr.io/actions/actions-runner:2.338.2` |
| Docker-in-Docker | `docker:29.9.2-dind` |

## Öffentliche Repos

Die Org-Runner-Gruppe lässt öffentliche Repos nicht zu, und `ci.yml` liest die Sichtbarkeit aus der
API und schickt öffentliche Repos immer auf GitHub-hosted Runner. Ein Fork-PR erreicht die eigenen
Runner also auf zwei unabhängigen Wegen nicht. Signiert wird in jedem Fall GitHub-hosted.

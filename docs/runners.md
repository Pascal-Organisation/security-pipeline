# Self-hosted Runner

Private Repos der Organisation bauen auf eigener Hardware (Proxmox), in einem Kubernetes-Cluster mit
einem frischen Pod pro Job. Öffentliche Repos nutzen diese Runner nie (siehe unten). Dieses Dokument
beschreibt, wie ein Job vom Knoten und von anderen Jobs getrennt ist, was früher galt und was bei
einem Nachbau schiefgeht.

## Stand

| Was | Wie | Status |
|---|---|---|
| **CI-Cluster**: ARC auf k3s, **ein Pod pro Job** in eigenem User-Namespace | [Actions Runner Controller](https://github.com/actions/actions-runner-controller); Pod = `ci-toolbox`-Image, kein Docker-Daemon, Images baut rootless BuildKit im Pod; danach wird der Pod gelöscht | v3, Scale Set `arc-ci` |
| Eine Runner-VM pro Vertrauensbereich | je Repo eine VM mit eigenem rootful Docker-Daemon (Label `ci` bzw. Repo-Runner) | **abgelöst** (v2) |
| ARC mit **Kata-microVM** pro Job | gebaut, lief verschachtelt auf kleiner Hardware nicht stabil | **verworfen** (Label `arc-trial`) |

Konfiguration des Clusters als Beispiel in [`runners/arc/`](../runners/arc/) – ohne Geheimnisse und
ohne Interna des Homelabs.

## Warum überhaupt

Anfangs liefen alle Self-hosted Runner persistent auf **einer** VM, als **ein** Linux-User, an
**einem** rootful Docker-Daemon. Zugriff auf den Docker-Socket ist faktisch root. Ein Job eines
beliebigen privaten Repos – etwa über eine kompromittierte Abhängigkeit in einem Renovate-PR – hätte:

- das Image eines anderen Repos zwischen Trivy-Scan und Push austauschen können. Die Signatur wäre
  trotzdem gültig gewesen: Sie beweist, dass `build-container.yml` lief, nicht was der Runner gebaut hat;
- die Registrierungsdaten der anderen Runner lesen und deren Jobs (samt `GITHUB_TOKEN` mit
  `packages: write`) abgreifen können.

v2 trennte das mit einer VM pro Vertrauensbereich. v3 geht weiter: Ein Job bekommt weder Docker-Daemon
noch Docker-Socket, und nichts überlebt ihn.

## v3: ein Pod pro Job, User-Namespace, rootless BuildKit

```
GitHub ◄──── nur ausgehend (443) ────────────────────────────────────┐
                                                                     │
k3s-Knoten (VM, Proxmox-Firewall: default deny, kein LAN)            │
├─ arc-systems/  Controller + Listener  ── GitHub-App-Token ─────────┘
└─ arc-runners/  ein Pod pro Job, runc, hostUsers: false
     └─ runner = ci-toolbox (digest-gepinnt, cosign-signiert)
          ├─ alle Werkzeuge nativ (actionlint, zizmor, Trivy, Semgrep, …)
          └─ rootless BuildKit (buildctl-daemonless) → OCI-Tar → crane push
```

- **Ein Image für alles.** Das `ci-toolbox` (`toolbox/Dockerfile`, gebaut und signiert von `toolbox.yml`)
  enthält Runner und alle Werkzeuge. Im Cluster *ist* der Pod die Toolbox (`TOOLBOX_NATIVE=1`), auf
  GitHub-hosted Runnern startet der Wrapper `tb` dasselbe Image mit `docker run`. Gleiche Schritte,
  gleiche Versionen.
- **User-Namespace statt microVM.** `hostUsers: false`: Jeder Pod bekommt einen eigenen Linux-User-
  Namespace; „root" im Pod ist auf dem Knoten ein unprivilegierter, nicht abgebildeter User. Der Pod ist
  nicht privileged und hat nur die Capabilities `SETUID`/`SETGID` (für `newuidmap`/`newgidmap`).
- **Kein Docker.** Images baut rootless BuildKit im Pod (`--output type=oci`); gepusht wird das
  *gescannte* Tar mit `crane`. Es gibt keinen Daemon, den ein Job austauschen könnte.

| Angriff aus einem Job | Ergebnis |
|---|---|
| Container-Ausbruch aus Scanner oder Build | landet im Pod, im eigenen User-Namespace, ohne Rechte auf dem Knoten |
| root im Pod | auf dem Knoten ein unprivilegierter, unmappter User |
| Spuren für spätere Jobs | Pod und alle Volumes (`emptyDir`) werden nach dem Job gelöscht; Base-Images immer frisch aus der Registry |
| Kubernetes-API | Runner-Pods ohne Service-Account-Token, Service-Account ohne Rechte |
| Ins LAN | Firewall am Knoten: nur DNS, 80/443, NTP |

Zugang zu GitHub: eine eigene, private GitHub App mit **genau einer** Berechtigung –
*Organization → Self-hosted runners: Read and write*. Keine Repo-Rechte, keine Webhooks. Der Schlüssel
liegt nur als Kubernetes-Secret auf dem Knoten (k3s mit `secrets-encryption`); Runner-Pods sehen ihn
nie, sie bekommen nur eine Just-in-time-Registrierung für genau einen Job.

**Grenzen, offen benannt:**
- Rootless BuildKit braucht ein gelockertes Seccomp- und AppArmor-Profil (`Unconfined`),
  `procMount: Unmasked` und `allowPrivilegeEscalation: true`. Das ist vertretbar, weil der Pod im eigenen
  User-Namespace ohne Capabilities im *Host*-Namespace läuft – aber es ist **schwächer als eine MicroVM**:
  Ein Kernel-Fehler (User-Namespaces, Mounts) wäre ein Weg auf den Knoten. Der Knoten ist damit die
  Vertrauensbasis für alle privaten Builds, und mit dem App-Schlüssel ließen sich Runner registrieren,
  die Jobs privater Repos abgreifen.
- Der Namespace der Runner darf kein Pod-Security-`enforce=baseline/restricted` tragen.
- Im Build sind IDs über 64999 (z. B. 65534 `nobody`) nicht abgebildet; ein `chown` darauf scheitert.
- Das Toolbox-Image ist selbst Teil der Lieferkette und wird mit Docker auf einem GitHub-hosted Runner
  gebaut (es kann sich nicht selbst bauen). Das Registry-Paket ist privat, die Pods brauchen ein
  `imagePullSecret` mit `read:packages`.
- Der Pfad auf GitHub-hosted Runnern (`docker run` mit `seccomp`/`apparmor=unconfined` für
  BuildKit) betrifft nur öffentliche Repos und Signieren/Re-Scan; dort ist der Runner ohnehin
  eine Wegwerf-VM von GitHub.

### Label des Scale Sets

Private Repos laufen auf dem Scale Set `arc-ci` (`runs-on` = Name des Scale Sets). `ci.yml` und
`build-container.yml` haben dafür den Input `runner` (Standard `arc-ci`); wer ein anderes Scale Set
ausprobiert (z. B. `k8s-ci-trial`), setzt ihn im Aufrufer. Öffentliche Repos ignorieren ihn und laufen
immer auf GitHub-hosted Runnern.

### Stolpersteine beim Aufbau

Für alle, die das nachbauen – jeder davon hat Jobs scheitern lassen:

1. **Seccomp `RuntimeDefault` blockiert rootlesskit.** `clone`/`unshare(CLONE_NEWUSER)` schlägt mit
   `fork/exec /proc/self/exe: operation not permitted` fehl. Profil `Unconfined`.
2. **AppArmor `RuntimeDefault` verbietet rootlesskits Mounts** (`failed to share mount point: /:
   permission denied`). Profil `Unconfined`.
3. **`procMount: Unmasked`** (nur zusammen mit `hostUsers: false` erlaubt): runc mountet für jeden
   `RUN`-Schritt ein frisches `/proc`; mit dem maskierten `/proc` scheitert das (`error mounting "proc"`).
   Alternative: `BUILDKITD_FLAGS=--oci-worker-no-process-sandbox` (RUN-Schritte teilen dann den
   PID-Namespace mit `buildkitd`).
4. **`allowPrivilegeEscalation: true`.** Mit `no_new_privs` kann das setuid-`newuidmap` die Sub-IDs
   nicht abbilden.
5. **Sub-IDs müssen im Namespace des Pods liegen.** Der Pod kennt nur die IDs 0–65535; ein Eintrag wie
   `runner:100000:65536` in `/etc/subuid` liegt außerhalb, `newuidmap` scheitert. Die Toolbox trägt
   deshalb `runner:2000:63000`.
6. **Der Runner-User ist uid 1001.** Der Wrapper `tb` auf GitHub-hosted Runnern setzt darauf, dass der
   Toolbox-User dieselbe uid wie der `runner`-User des Hosts hat, sonst gehören Dateien im Workspace
   einem fremden Besitzer.
7. **`XDG_RUNTIME_DIR` fehlt.** Das Image hat kein `/run/user/1001`; BuildKit-Socket und -State
   liegen auf beschreibbaren `emptyDir`-Volumes.
8. **`emptyDir` auf Platte, nicht `medium: Memory`.** Layer-Speicher eines Builds dürfen nicht als RAM zählen.
9. **ARC setzt die Labels nur beim Anlegen des Scale Sets.** Ein `helm upgrade` mit neuen Labels
   ändert auf GitHub nichts – Jobs bleiben ungezuordnet. Labels ändern = `helm uninstall` + `install`.
10. **Nicht das Pod-Template ändern, während Runner Jobs haben.** ARC ersetzt dann Runner, denen GitHub
    schon Jobs zugeteilt hat; die Jobs hängen, bis man den Run abbricht.
11. **Privates Registry-Paket braucht ein `imagePullSecret`.** Ohne `ErrImagePull` und ein Job, der
    ewig auf einen Runner wartet.

### Warum nicht Kata

Der erste Ansatz war eine Kata-microVM pro Job (eigener Gast-Kernel, `docker:dind` darin privilegiert).
Die Isolation ist stärker, aber der Knoten ist selbst eine VM: Die microVMs laufen **verschachtelt** auf
einem kleinen 4-Kern-Host. Leichte Jobs liefen; unter Image-Builds (Pull, `docker build`, `docker save`,
Trivy auf das Tar) fror der Gast so lange ein, dass Kata den Agenten für tot erklärte (`CheckRequest
timed out`, `Dead agent`) – 16-mal in 25 Minuten normaler CI. Ein Security-Gate, das zufällig scheitert,
ist schlechter als ein schwächer isoliertes. User-Namespaces haben keinen Gast-Kernel, kein virtio-fs und
kein verschachteltes KVM; derselbe schwere Build lief ohne Hänger. Auf Bare Metal wäre Kata weiterhin
die stärkere Wahl.

### Versionen

Alles gepinnt; Images per Digest (siehe `runners/arc/`).

| Komponente | Version |
|---|---|
| k3s | v1.36.5+k3s1 (Binary gegen `sha256sum-amd64.txt` geprüft) |
| Helm | v4.3.1 (gegen die veröffentlichte SHA-256 geprüft) |
| ARC (Controller + Scale Set) | 0.15.1 |
| Runner/Toolbox | `ci-toolbox` (Basis `ghcr.io/actions/actions-runner:2.338.2`), per Digest in `ci.yml`/`build-container.yml` |
| BuildKit | `moby/buildkit:v0.34.2-rootless` (in der Toolbox) |

## Öffentliche Repos

Die Org-Runner-Gruppe lässt öffentliche Repos nicht zu, und `ci.yml` liest die Sichtbarkeit aus der
API und schickt öffentliche Repos immer auf GitHub-hosted Runner. Ein Fork-PR erreicht die eigenen
Runner also auf zwei unabhängigen Wegen nicht. Signiert wird in jedem Fall GitHub-hosted.

# Vral Altos Console

The operator's web front door to Vral Altos (Flutter web, Firebase Hosting
site `va-console` in `vral-altos`): **https://va-console.web.app**.

- **Overview** — live activity and approvals, KPIs (turns today, chat cost,
  GCP spend), hosts' CPU/memory/disk, active tasks, usage, Claude limits,
  month-to-date spend, Devstations.
- **Chat** — Claude-style conversations with the agents. Messages go into the
  mailbox; the Mac worker (or the cloud runner, or a director's Devstation)
  answers, streaming its progress; Stop ends a turn and keeps what it wrote.
- **Projects** — Devstations (GCE dev VMs with Claude Code) and the Factory.
- **Logs** — Logs Explorer, Monitoring and Activity over every service's
  telemetry (`docs/architecture.md`, Telemetry) and your own audit trail.
- **System** — approvals, hosts, agent sessions, usage by host/account, syncs,
  appearance.

Shortcuts: Ctrl/⌘+K new chat, Ctrl/⌘+1…5 pages; Enter sends, Shift+Enter
breaks the line.

Only the operator's verified Google account (siddharth.chitikela@) gets in (`lib/data/firebase.dart`
and `firestore.rules`, which must list the same accounts).

## Develop

```sh
flutter pub get && dart run build_runner build -d
flutter analyze && flutter test
cd rules_tests && npm install && npm test   # needs the Firestore emulator on :8086
```

Debug builds talk to the local emulators only (Auth :9099, Firestore :8080;
override with `--dart-define=FIRESTORE_EMULATOR_PORT=…`).

## End-to-end test (emulators, real agents)

`e2e/console_e2e.py` drives the Console in headless Chromium (Playwright)
against the Auth and Firestore emulators, with a real Mac worker answering:

```sh
java -jar ~/.cache/firebase/emulators/cloud-firestore-emulator-*.jar --port 8087 --rules firestore.rules &
npx firebase-tools emulators:start --only auth --project vral-altos &
flutter build web --release --dart-define-from-file=.env --dart-define=USE_EMULATORS=true \
  --dart-define=FIRESTORE_EMULATOR_PORT=8087 -o build/e2e
(cd build/e2e && python3 -m http.server 5055 --bind 127.0.0.1) &
VA_MESH_PROJECT=vral-altos VA_MESH_EMULATOR=127.0.0.1:8087 VA_MESH_HOME=/tmp/va-e2e \
  ../../meshes/agent_mesh/build/va_agent worker &
python3 e2e/console_e2e.py /tmp/va-e2e-shots
```

Closing a test conversation writes a journal entry into the real agent's
`state/journal.md`; remove those entries afterwards.

## Deploy

```sh
flutter build web --release --dart-define-from-file=.env   # .env: Firebase web config (not committed)
npx firebase-tools deploy --only firestore,hosting --project vral-altos
```

`firestore.rules` governs the **platform** database only; Financier's rules
govern `(default)`.

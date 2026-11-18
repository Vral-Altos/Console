# Vral Altos Console

The operator's web front door to Vral Altos (Flutter web, Firebase Hosting
site `va-console` in `vral-altos`): **https://console.vraltos.dev** (also https://va-console.web.app).

- **Overview** — live activity and approvals, KPIs (turns today, chat cost,
  GCP spend), hosts' CPU/memory/disk, active tasks, usage, Claude limits,
  month-to-date spend, Devstations.
- **Chat** — Claude-style conversations with the agents. Messages go into the
  mailbox; the Mac worker (or the cloud runner, or a director's Devstation)
  answers, streaming its progress; Stop ends a turn and keeps what it wrote.
  Files can be attached from the paperclip, by pasting or by dropping them;
  they upload to the attachments bucket under `storage.rules`. `@` mentions a
  conversation, project or agent, and the agent gets its context.
- **Projects** — Devstations (GCE dev VMs with Claude Code) and the Factory.
- **Billing** — what every GCP project on the billing account costs, from
  the Cloud Billing BigQuery export (`billing/breakdown`, kept by the cloud
  runner): this and last invoice month, pace against the target, daily cost
  by project, projects → services and SKUs, net of credits. Until the export
  is switched on (Cloud Console → Billing → Billing export → Standard usage
  cost → `vral-altos` / `va_billing`) it shows how, and the budget's total.
- **Topology** — everything Vral Altos and your other projects are made of,
  on one interactive isometric map: every GCP project you can see (Cloud
  Asset Inventory: services, databases, buckets, secrets, queues, jobs, VMs,
  identities; public IAM bindings; Cloud Run and Scheduler health; Hosting
  sites), the Mac and its launchd services, the High Counsel, Devstations,
  the repos on the Mac (owner from the git remote) and the third parties they
  reach. Districts by project, boundary or owner; fences inside them are the
  security boundaries (public edge, cloud internal, private network, agent
  sandboxes, your premises, third parties). Hover for a readout (health,
  security, owner, facts, links); click to pin, double-click to zoom; search +
  Enter flies to an entity; Q/E or the buttons rotate, scroll/pinch zooms.
  Data: `topology/current`, kept by the Mac worker every 15 min with your own
  Google login (`va_agent topology` runs it once), plus live host status.
- **Logs** — Logs Explorer, Monitoring and Activity over every service's
  telemetry (`docs/architecture.md`, Telemetry) and your own audit trail.
- **System** — approvals, hosts, agent sessions, usage by host/account, syncs,
  appearance.

Shortcuts: Ctrl/⌘+K new chat, Ctrl/⌘+1…5 pages, Ctrl/⌘+Shift+S shows or
hides the conversations; in the message box Enter sends, Shift+Enter breaks
the line, Esc stops the running turn and ↑ (in an empty box) edits the last
message.

Chat filing and usage: every conversation is named
`[PROJECT] (TOTAL COST) DD/MM: TOPIC` (`lib/ui/chat/chat_naming.dart`), from the
thread's project, the workers' running cost, its start day (UTC+8) and its
topic. After the first reply the worker's `ChatNamer` (agent_mesh) asks Haiku
for the project (from `chat_projects`), purpose and topic; the operator can
pick the project when starting (Auto / a project / General) and refile, set
the purpose or rename the topic from the conversation menu, which the namer
then leaves alone. The sidebar groups by Project (default), Purpose or Recent;
each group folds and shows its count and cost. The folder button keeps the
projects (add, rename — refiles — and delete → General). The header shows the
last reply's model, its account's live 5-hour and 7-day quota and the chat's
total; each reply shows its model, context and output tokens, cost and the
quota after it. `e2e/filing_e2e.py` (same setup as below, an empty Firestore
emulator) drives it with a real worker.

Chat details: replies stream with a caret (an open code fence renders as code
while it arrives); the tools a turn used fold into one line that opens to the
list; fenced code is syntax-coloured (`lib/ui/chat/code_highlight.dart`, a
bundled subset of `highlight` grammars); new messages rise in, the streamed
answer becomes the finished reply in place, and a "New messages" pill appears
when you have scrolled up. One dark theme, the VA design system (`meshes/ui_mesh`).

Only the operator's verified Google account (siddharth.chitikela@) gets in (`lib/data/firebase.dart`
and `firestore.rules`, which must list the same accounts).

## Develop

```sh
flutter pub get && dart run build_runner build -d
flutter analyze && flutter test
cd rules_tests && npm install && npm test   # needs the Firestore emulator on :8086
npm run test:storage   # needs the Storage emulator on :9199 (firebase-tools on Java 21):
#   JAVA_HOME=/opt/homebrew/opt/openjdk@21 npx firebase-tools emulators:start --only storage --project demo-va-console
```

Debug builds talk to the local emulators only (Auth :9099, Firestore :8080;
override with `--dart-define=FIRESTORE_EMULATOR_PORT=…`).

## End-to-end test (emulators, real agents)

`e2e/console_e2e.py` drives the Console in headless Chromium (Playwright)
against the Auth and Firestore emulators, with a real Mac worker answering:

```sh
java -jar ~/.cache/firebase/emulators/cloud-firestore-emulator-*.jar --port 8087 --rules firestore.rules &
JAVA_HOME=/opt/homebrew/opt/openjdk@21 npx firebase-tools emulators:start --only auth,storage --project vral-altos &
flutter build web --release --dart-define-from-file=.env --dart-define=USE_EMULATORS=true \
  --dart-define=FIRESTORE_EMULATOR_PORT=8087 -o build/e2e
(cd build/e2e && python3 -m http.server 5055 --bind 127.0.0.1) &
VA_MESH_PROJECT=vral-altos VA_MESH_EMULATOR=127.0.0.1:8087 VA_STORAGE_EMULATOR=127.0.0.1:9199 VA_MESH_HOME=/tmp/va-e2e \
  ../../meshes/agent_mesh/build/va_agent worker &
python3 e2e/console_e2e.py /tmp/va-e2e-shots
```

Closing a test conversation writes a journal entry into the real agent's
`state/journal.md`; remove those entries afterwards.

## Deploy

```sh
flutter clean && flutter pub get && dart run build_runner build -d   # after adding plugins: a cached build can miss them
flutter build web --release --dart-define-from-file=.env   # .env: Firebase web config (not committed)
npx firebase-tools deploy --only firestore,storage,hosting --project vral-altos   # storage: Java 21
```

`firestore.rules` governs the **platform** database only; Financier's rules
govern `(default)`.

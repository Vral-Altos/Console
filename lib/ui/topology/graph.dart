import 'package:freezed_annotation/freezed_annotation.dart';

import '../../data/models.dart';

part 'graph.freezed.dart';

/// What an entity is; decides its shape.
enum EntityKind {
  host, // a physical computer
  device, // a phone
  vm,
  service, // Cloud Run, a local daemon
  site, // Firebase Hosting
  database,
  bucket,
  secret,
  queue, // Pub/Sub
  trigger, // Eventarc
  job, // Cloud Scheduler
  registry,
  network,
  identity, // a service account
  agent,
  repo,
  external,
}

/// The security boundary an entity sits behind (the fences).
enum Boundary {
  public('Public edge', 'Reachable from the internet'),
  cloud('Cloud internal', 'Inside a GCP project; IAM-guarded'),
  devnet('Private network', 'VPC networks and VMs'),
  counsel('High Counsel', 'Agent sandboxes (Claude Code sessions)'),
  local('Operator premises', 'Physical devices and what runs on them'),
  external('Third party', 'Services outside your control');

  const Boundary(this.label, this.blurb);
  final String label;
  final String blurb;
}

enum Health { ok, warn, bad, idle, unknown }

/// View filters.
enum TopoFilter {
  all('All entities'),
  vaCore('Vral Altos core'),
  counsel('High Counsel'),
  devstations('Devstations'),
  public('Public surface'),
  local('Operator premises'),
  repos('Code');

  const TopoFilter(this.label);
  final String label;
}

/// How the map is laid out: the outer districts.
enum GroupBy {
  project('Project'),
  boundary('Boundary'),
  owner('Owner');

  const GroupBy(this.label);
  final String label;
}

@freezed
abstract class TopoEntity with _$TopoEntity {
  const factory TopoEntity({
    required String id,
    required String label,
    required EntityKind kind,
    required Boundary boundary,

    /// Project family key (e.g. `va`, `cortado`) and its display name.
    required String project,
    required String projectName,

    /// Owner key (a GitHub owner, `you`, `shared`, `third-party`).
    required String owner,
    required String ownerName,
    @Default(Health.unknown) Health health,
    String? healthDetail,
    @Default(false) bool physical,
    @Default(false) bool public,

    /// Short type line, e.g. "Cloud Run service".
    required String type,
    @Default(<TopoFilter>{}) Set<TopoFilter> filters,

    /// Facts for the overlay, in order.
    @Default(<(String, String)>[]) List<(String, String)> facts,
    String? url,
  }) = _TopoEntity;
}

@freezed
abstract class TopoLink with _$TopoLink {
  const factory TopoLink({required String from, required String to, required String label}) = _TopoLink;
}

@freezed
abstract class TopoGraph with _$TopoGraph {
  const factory TopoGraph({
    @Default(<TopoEntity>[]) List<TopoEntity> entities,
    @Default(<TopoLink>[]) List<TopoLink> links,
    DateTime? collectedAt,
    @Default(<String>[]) List<String> errors,
  }) = _TopoGraph;
}

/// Words that do not tell projects apart.
const _noise = {
  'project', 'the', 'server', 'backend', 'infra', 'site', 'app', 'old', 'v', 'test', 'ide', 'dashboard',
  'platform', 'language', 'editor', 'core', 'tooling', 'code', 'modules', 'pages', 'axis', 'web', 'gcp',
};

/// A project family from a repo or GCP project name: `CortadoBackend`,
/// `cortado-ide` and `Cortado_Server` are all `cortado`.
String familyKey(String name) {
  final words = name
      .replaceAllMapped(RegExp(r'([a-z])([A-Z])'), (m) => '${m[1]} ${m[2]}')
      .replaceAllMapped(RegExp(r'([A-Za-z])(\d)'), (m) => '${m[1]} ${m[2]}')
      .split(RegExp(r'[^A-Za-z0-9]+'))
      .map((w) => w.toLowerCase())
      .where((w) => w.isNotEmpty && !RegExp(r'^\d+$').hasMatch(w) && !_noise.contains(w))
      .toList();
  return words.isEmpty ? name.toLowerCase() : words.first;
}

String _title(String key) => key.isEmpty ? key : key[0].toUpperCase() + key.substring(1);

/// The operator's own GitHub account (repos with no other owner are theirs).
const personalOwner = 'ObsidianXVI';
const vaOwner = 'Vral-Altos';

/// Names that belong to Vral Altos wherever they are checked out.
const _vaNames = {'financier', 'autobench', 'tucson', 'skyhorse', 'spaceman', 'newsfrontier', 'eos', 'rhog', 'vral'};

String ownerName(String owner) => switch (owner) {
  personalOwner => 'You · $personalOwner',
  'you' => 'You',
  'local' => 'You · local only',
  'shared' => 'Shared with you',
  'third-party' => 'Third party',
  _ => owner,
};

const _typeNames = {
  'run.service': 'Cloud Run service',
  'firestore.database': 'Firestore database',
  'storage.bucket': 'Cloud Storage bucket',
  'secret': 'Secret Manager secret',
  'pubsub.topic': 'Pub/Sub topic',
  'eventarc.trigger': 'Eventarc trigger',
  'scheduler.job': 'Cloud Scheduler job',
  'artifact.repository': 'Artifact Registry',
  'compute.instance': 'Compute Engine VM',
  'compute.network': 'VPC network',
  'service-account': 'Service account',
  'hosting.site': 'Firebase Hosting site',
};

EntityKind _kindOf(String type) => switch (type) {
  'run.service' => EntityKind.service,
  'firestore.database' => EntityKind.database,
  'storage.bucket' => EntityKind.bucket,
  'secret' => EntityKind.secret,
  'pubsub.topic' => EntityKind.queue,
  'eventarc.trigger' => EntityKind.trigger,
  'scheduler.job' => EntityKind.job,
  'artifact.repository' => EntityKind.registry,
  'compute.instance' => EntityKind.vm,
  'compute.network' => EntityKind.network,
  'service-account' => EntityKind.identity,
  'hosting.site' => EntityKind.site,
  _ => EntityKind.service,
};

Health _health(String? h) => switch (h) {
  'ok' => Health.ok,
  'warn' => Health.warn,
  'bad' => Health.bad,
  'idle' => Health.idle,
  _ => Health.unknown,
};

String _ago(DateTime t, DateTime now) {
  final d = now.difference(t);
  if (d.inMinutes < 1) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes} min ago';
  if (d.inDays < 1) return '${d.inHours} h ago';
  if (d.inDays < 60) return '${d.inDays} d ago';
  return '${(d.inDays / 30).round()} months ago';
}

String _pct(num? v) => v == null ? '—' : '${(v * 100).round()}%';

/// Everything on the map, from live sources only: the inventory the Mac
/// worker collects, the hosts' status documents and the Devstations.
TopoGraph buildTopology({
  TopologyInventory? inventory,
  Map<String, HostStatus> hosts = const {},
  List<Devstation> devstations = const [],
  required DateTime now,
}) {
  final entities = <String, TopoEntity>{};
  final links = <TopoLink>[];
  void add(TopoEntity e) => entities[e.id] = e;
  void link(String a, String b, String label) {
    if (a != b) links.add(TopoLink(from: a, to: b, label: label));
  }

  final inv = inventory ?? const TopologyInventory();
  final agentNames = {for (final h in hosts.values) ...h.agents};
  bool isVa(String key) => key == 'va' || _vaNames.contains(key) || agentNames.contains(key);
  String fam(String name) {
    final k = familyKey(name);
    return isVa(k) ? 'va' : k;
  }

  // Families, their owners and display names, from the repos and projects.
  final famOwners = <String, Map<String, int>>{};
  final famNames = <String, String>{'va': 'Vral Altos'};
  for (final r in inv.repos) {
    final f = r.path.startsWith('Vral_Altos/') || r.owner == vaOwner ? 'va' : fam(r.name);
    final o = r.owner ?? 'local';
    (famOwners[f] ??= {})[o] = (famOwners[f]![o] ?? 0) + 1;
    famNames.putIfAbsent(f, () => _title(f));
  }
  String famOwner(String f) {
    if (f == 'va') return vaOwner;
    final counts = {...?famOwners[f]}..remove('local');
    if (counts.isEmpty) return famOwners[f] == null ? personalOwner : 'local';
    return (counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).first.key;
  }

  final projects = {for (final p in inv.projects) p.id: p};
  String projFam(String gcp) => gcp == 'vral-altos' ? 'va' : fam(projects[gcp]?.name ?? gcp);

  // ── Cloud resources ────────────────────────────────────────────────
  final dbsByProject = <String, List<String>>{};
  final runByProject = <String, List<String>>{};
  final triggersByProject = <String, List<String>>{};
  for (final r in inv.resources) {
    final f = projFam(r.project);
    famNames.putIfAbsent(f, () => _title(f));
    final limited = projects[r.project]?.access == 'limited';
    final owner = limited ? 'shared' : famOwner(f);
    final kind = _kindOf(r.type);
    final boundary = r.public
        ? Boundary.public
        : kind == EntityKind.vm || kind == EntityKind.network
        ? Boundary.devnet
        : Boundary.cloud;
    final devstation = r.labels['devstation'] ?? (kind == EntityKind.vm && r.name.startsWith('devstation-') ? r.name.substring(11) : null);
    final component = r.labels['component'];
    add(TopoEntity(
      id: r.id,
      label: r.name,
      kind: kind,
      boundary: boundary,
      project: f,
      projectName: famNames[f]!,
      owner: owner,
      ownerName: ownerName(owner),
      health: _health(r.health),
      healthDetail: r.detail,
      public: r.public,
      type: _typeNames[r.type] ?? r.type,
      url: r.url,
      filters: {
        TopoFilter.all,
        if (f == 'va') TopoFilter.vaCore,
        if (r.public) TopoFilter.public,
        if (devstation != null || (f == 'va' && kind == EntityKind.vm)) TopoFilter.devstations,
      },
      facts: [
        ('GCP project', r.project),
        if (r.location != null) ('Location', r.location!),
        if (r.state != null) ('State', r.state!),
        if (r.public) ('Exposure', 'Public · ${r.publicRoles.join(', ')}') else ('Exposure', 'IAM only'),
        if (r.ingress != null) ('Ingress', r.ingress!.replaceFirst('INGRESS_TRAFFIC_', '').toLowerCase()),
        if (r.url != null) ('URL', r.url!),
        if (r.schedule != null) ('Schedule', r.schedule!),
        if (r.lastRun != null) ('Last run', _ago(r.lastRun!, now)),
        if (component != null) ('Component', component),
        if (r.labels['managed-by'] != null) ('Managed by', r.labels['managed-by']!),
      ],
    ));
    if (kind == EntityKind.database) (dbsByProject[r.project] ??= []).add(r.id);
    if (kind == EntityKind.service) (runByProject[r.project] ??= []).add(r.id);
    if (kind == EntityKind.trigger) (triggersByProject[r.project] ??= []).add(r.id);
  }
  // Wiring Google does not report but the architecture implies: services
  // and sites use their project's databases; triggers and jobs wake its
  // services; topics feed its triggers.
  for (final r in inv.resources) {
    final kind = _kindOf(r.type);
    final dbs = dbsByProject[r.project] ?? const [];
    final runs = runByProject[r.project] ?? const [];
    if (kind == EntityKind.service || kind == EntityKind.site) {
      for (final d in dbs.take(2)) {
        link(r.id, d, 'reads/writes');
      }
    }
    if (kind == EntityKind.trigger || kind == EntityKind.job) {
      for (final s in runs) {
        link(r.id, s, kind == EntityKind.job ? 'schedules' : 'delivers events');
      }
    }
    if (kind == EntityKind.queue) {
      for (final t in triggersByProject[r.project] ?? const <String>[]) {
        link(r.id, t, 'publishes');
      }
    }
  }

  // ── The operator's premises ────────────────────────────────────────
  final mac = hosts['mac'];
  const fresh = Duration(minutes: 3);
  String? platformDb = (dbsByProject['vral-altos'] ?? const <String>[])
      .where((d) => d.endsWith('/platform'))
      .firstOrNull;
  if (mac != null) {
    final live = mac.lastSeen != null && now.difference(mac.lastSeen!) < fresh;
    final m = mac.metrics;
    add(TopoEntity(
      id: 'mac',
      label: mac.host?.replaceAll('.local', '') ?? 'Mac',
      kind: EntityKind.host,
      boundary: Boundary.local,
      project: 'va',
      projectName: 'Vral Altos',
      owner: 'you',
      ownerName: ownerName('you'),
      physical: true,
      type: 'Operator\'s Mac',
      health: live ? Health.ok : Health.bad,
      healthDetail: live ? 'Worker serving' : 'Not seen ${mac.lastSeen == null ? 'yet' : _ago(mac.lastSeen!, now)}',
      filters: {TopoFilter.all, TopoFilter.vaCore, TopoFilter.local},
      facts: [
        if (mac.lastSeen != null) ('Last seen', _ago(mac.lastSeen!, now)),
        if (m != null) ...[
          ('CPU', _pct(m.cpu)),
          if ((m.memTotal ?? 0) > 0) ('Memory', _pct((m.memUsed ?? 0) / m.memTotal!)),
          if ((m.diskTotal ?? 0) > 0) ('Disk', _pct((m.diskUsed ?? 0) / m.diskTotal!)),
          if (m.cores > 0) ('Cores', '${m.cores}'),
        ],
        if (mac.claudeVersion != null) ('Claude Code', mac.claudeVersion!),
        ('Agents', '${mac.agents.length}'),
      ],
    ));
    if (platformDb != null) link('mac', platformDb, 'mailbox');
    for (final s in mac.localServices) {
      final name = s.label.replaceFirst('com.vralaltos.', '');
      final bridge = name.startsWith('skyhorse.') ? name.substring(9) : null;
      final id = 'local:${s.label}';
      add(TopoEntity(
        id: id,
        label: bridge == null ? name : 'Skyhorse · ${_title(bridge)}',
        kind: EntityKind.service,
        boundary: Boundary.local,
        project: 'va',
        projectName: 'Vral Altos',
        owner: 'you',
        ownerName: ownerName('you'),
        type: 'launchd service on the Mac',
        health: !s.running
            ? Health.bad
            : s.connected == false
            ? Health.warn
            : Health.ok,
        healthDetail: !s.running
            ? 'Not running${s.lastExit == null ? '' : ' (exit ${s.lastExit})'}'
            : s.connected == false
            ? (s.detail ?? 'Not connected')
            : s.connected == true
            ? 'Running · connected'
            : 'Running',
        filters: {TopoFilter.all, TopoFilter.vaCore, TopoFilter.local},
        facts: [('launchd label', s.label), ('Transport', bridge != null ? 'Unix socket (owner-only)' : 'local')],
      ));
      link('mac', id, 'runs');
      if (bridge != null) {
        final ext = 'ext:$bridge';
        add(_external(ext, _title(bridge), 'Messaging network', s.connected == true ? Health.ok : Health.warn));
        link(id, ext, 'bridges');
        if (bridge == 'whatsapp' && s.connected == true) {
          add(TopoEntity(
            id: 'phone',
            label: 'Phone',
            kind: EntityKind.device,
            boundary: Boundary.local,
            project: 'va',
            projectName: 'Vral Altos',
            owner: 'you',
            ownerName: ownerName('you'),
            physical: true,
            type: 'WhatsApp primary device',
            health: Health.ok,
            healthDetail: 'Linked to the Mac\'s bridge',
            filters: {TopoFilter.all, TopoFilter.local},
            facts: const [('Role', 'Holds the WhatsApp account the bridge mirrors')],
          ));
          link('phone', ext, 'primary device');
        }
      }
    }
  }

  // ── The High Counsel ───────────────────────────────────────────────
  final cloud = hosts['cloud'];
  final runner = entities.values.where((e) => e.id.endsWith('/services/va-agent-runner')).firstOrNull;
  final infos = <String, String>{for (final h in hosts.values) ...h.agentInfo};
  if (agentNames.isNotEmpty) {
    add(_external('ext:anthropic', 'Anthropic', 'Claude (via Claude Code)', Health.unknown));
  }
  for (final a in agentNames.toList()..sort()) {
    final onMac = mac?.agents.contains(a) ?? false;
    final onCloud = cloud?.agents.contains(a) ?? false;
    final id = 'agent:$a';
    add(TopoEntity(
      id: id,
      label: a.startsWith('director-') ? 'Director ${a.substring(9)}' : _title(a),
      kind: EntityKind.agent,
      boundary: Boundary.counsel,
      project: 'va',
      projectName: 'Vral Altos',
      owner: vaOwner,
      ownerName: ownerName(vaOwner),
      type: a == 'genie' ? 'Personal assistant' : 'High Counsel agent',
      health: onMac || onCloud ? Health.ok : Health.idle,
      healthDetail: [if (onMac) 'Mac', if (onCloud) 'cloud runner'].join(' · ').isEmpty
          ? 'No host serves it'
          : 'Served on ${[if (onMac) 'the Mac', if (onCloud) 'the cloud runner'].join(' and ')}',
      filters: {TopoFilter.all, TopoFilter.vaCore, TopoFilter.counsel},
      facts: [if (infos[a] != null) ('Role', infos[a]!), ('Runs on', [if (onMac) 'Mac', if (onCloud) 'Cloud'].join(', '))],
    ));
    if (onMac) link('mac', id, 'hosts');
    if (onCloud && runner != null) link(runner.id, id, 'hosts');
    link(id, 'ext:anthropic', 'model');
  }
  if (runner != null && cloud != null) {
    entities[runner.id] = runner.copyWith(
      filters: {...runner.filters, TopoFilter.counsel},
      facts: [
        ...runner.facts,
        if (cloud.lastRunAt != null) ('Last woke', _ago(cloud.lastRunAt!, now)),
        if (cloud.lastResult != null) ('Last result', cloud.lastResult!),
      ],
    );
  }
  // Agents live in the counsel's view with their hosts and models.
  for (final id in ['mac', 'ext:anthropic']) {
    final e = entities[id];
    if (e != null) entities[id] = e.copyWith(filters: {...e.filters, TopoFilter.counsel});
  }

  // ── Devstations ────────────────────────────────────────────────────
  for (final d in devstations) {
    final st = hosts['devstation-${d.id}'];
    final vm = entities.values.where((e) => e.kind == EntityKind.vm && (e.label == d.instance || e.label == 'devstation-${d.id}')).firstOrNull;
    final serving = st?.lastSeen != null && now.difference(st!.lastSeen!) < fresh;
    final facts = <(String, String)>[
      ('Project', d.project),
      ('State', d.state),
      if (d.machineType != null) ('Machine', d.machineType!),
      if (d.zone != null) ('Zone', d.zone!),
      if (d.repoUrl != null) ('Repository', d.repoUrl!),
      if (st?.lastSeen != null) ('Worker seen', _ago(st!.lastSeen!, now)),
    ];
    final health = d.error != null
        ? Health.bad
        : serving
        ? Health.ok
        : d.state == 'running'
        ? Health.warn
        : Health.idle;
    if (vm != null) {
      entities[vm.id] = vm.copyWith(
        label: 'Devstation ${d.id}',
        health: health,
        healthDetail: d.error ?? (serving ? 'Director serving' : d.state),
        filters: {...vm.filters, TopoFilter.devstations},
        facts: [...facts, ...vm.facts],
      );
      if (platformDb != null) link(vm.id, platformDb, 'mailbox');
      link(vm.id, 'agent:director-${d.id}', 'hosts');
    } else {
      final id = 'devstation:${d.id}';
      add(TopoEntity(
        id: id,
        label: 'Devstation ${d.id}',
        kind: EntityKind.vm,
        boundary: Boundary.devnet,
        project: 'va',
        projectName: 'Vral Altos',
        owner: vaOwner,
        ownerName: ownerName(vaOwner),
        type: 'Devstation (Spot VM)',
        health: health,
        healthDetail: d.error ?? d.state,
        filters: {TopoFilter.all, TopoFilter.vaCore, TopoFilter.devstations},
        facts: facts,
      ));
      if (platformDb != null) link(id, platformDb, 'mailbox');
    }
  }

  // ── Code ───────────────────────────────────────────────────────────
  final orgs = <String>{};
  for (final r in inv.repos) {
    final f = r.path.startsWith('Vral_Altos/') || r.owner == vaOwner ? 'va' : fam(r.name);
    final owner = r.owner ?? 'local';
    final id = 'repo:${r.path}';
    add(TopoEntity(
      id: id,
      label: r.name,
      kind: EntityKind.repo,
      boundary: Boundary.local,
      project: f,
      projectName: famNames[f]!,
      owner: owner,
      ownerName: ownerName(owner),
      type: 'Repository${r.stack.isEmpty ? '' : ' · ${r.stack.join(', ')}'}',
      health: Health.unknown,
      healthDetail: r.dirty ? 'Uncommitted changes' : null,
      filters: {TopoFilter.all, TopoFilter.repos, TopoFilter.local, if (f == 'va') TopoFilter.vaCore},
      url: r.host == null ? null : 'https://${r.host}/${r.owner}/${r.repo}',
      facts: [
        ('Path', r.path),
        ('Remote', r.host == null ? 'none (local only)' : '${r.host}/${r.owner}/${r.repo}'),
        if (r.branch != null) ('Branch', r.branch!),
        if (r.lastCommit != null) ('Last commit', _ago(r.lastCommit!, now)),
        ('Working tree', r.dirty ? 'uncommitted changes' : 'clean'),
      ],
    ));
    if (r.host == 'github.com') {
      orgs.add(r.owner!);
      link(id, 'ext:github', 'pushes to');
    }
  }
  if (orgs.isNotEmpty) {
    add(_external('ext:github', 'GitHub', 'Code hosting', Health.unknown,
        facts: [('Owners', (orgs.toList()..sort()).join(', '))], filters: {TopoFilter.repos}));
  }

  // Credentials in Secret Manager name the third parties they reach.
  for (final e in entities.values.toList()) {
    if (e.kind != EntityKind.secret || e.project != 'va') continue;
    final reach = switch (e.label) {
      'tucson-credentials' => [('ext:calendar', 'Google Calendar'), ('ext:notion', 'Notion')],
      'skyhorse-credentials' => [('ext:gmail', 'Gmail')],
      _ => const <(String, String)>[],
    };
    for (final (id, name) in reach) {
      entities.putIfAbsent(id, () => _external(id, name, 'Connected with your consent', Health.unknown));
      link(e.id, id, 'grants access');
    }
  }

  final ids = entities.keys.toSet();
  return TopoGraph(
    entities: entities.values.toList(),
    links: [for (final l in links) if (ids.contains(l.from) && ids.contains(l.to)) l],
    collectedAt: inv.at,
    errors: inv.errors,
  );
}

TopoEntity _external(String id, String label, String type, Health health,
        {List<(String, String)> facts = const [], Set<TopoFilter> filters = const {}}) =>
    TopoEntity(
      id: id,
      label: label,
      kind: EntityKind.external,
      boundary: Boundary.external,
      project: 'external',
      projectName: 'Third parties',
      owner: 'third-party',
      ownerName: ownerName('third-party'),
      type: type,
      health: health,
      filters: {TopoFilter.all, TopoFilter.counsel, ...filters},
      facts: facts,
    );

# Golem model discovery repair
Golem Settings queries the legacy local Codex host, absent from its installed bundle, and labels unloaded models not verified. Fetch the catalogue from chatterboxd automatically without changing provider/model choices, auth, tools, approvals or worker defaults.

Flow: Golem Settings → read-only providerModels RPC → chatterboxd Codex bridge → model/list → picker.

Success: daemon returns actual model IDs; Golem auto-loads on open/reconnect and exposes retry/error; both Mac builds pass and Golem is installed. Service activation must wait until existing replies finish; no provider turns or paid speech tests.
Deliverables: uncommitted Golem UI and Chatterbox daemon source, tested builds, backed-up installed app; service activation tracked separately if busy.
Execution: linear, existing session workflow/model-effort waiver reused. No delegation.
Tasks: T1 daemon read-only catalogue; T2 automatic picker loading and retry; T3 builds and read-only runtime test; T4 backup/install with safe service restart only if idle.
Rollback: restore backed-up app/service binary. No stored data migrations.
Work preparation: local plan; readiness pass, R3 flow shown above; no blocking questions. Existing UI tool unavailable, live visual acceptance pending.

Validation: both Golem Mac xcodebuild and Chatterbox daemon swiftc build passed. Isolated daemon with signed-role test allowance returned 32 actual Codex models including gpt-6.1-sol; no turn/speech requests. Endpoint restricted to signed ui/golem-ui roles. Installer staged signed daemon and signed Golem build with backups; waits for all running replies to finish before service restart, verifies health and model catalogue from a signed Golem-identity helper, rolls back daemon on failed verification, then installs/relaunches UI. Activation log: work/model-discovery-activation/activation.log. UI screenshot verification blocked by native pipe failure. Nothing committed/pushed.

Model-discovery activation completed: installed live service returned 10 models including gpt-6.1-sol; Golem installed/relaunched and signatures verified. Backup model-discovery-20261006-031742.
Follow-up: Golem toolbar removes Project/Remote/Terminal; new messages persist timestamp and message hover displays local date/time (old rows remain unknown). Mac and daemon builds passed; real DisplayItem declaration compatibility/roundtrip check passed. Timestamp service activation queued after current reply completes. Shared timestamp-only delivery branch preserves Chatterbox Core baseline and other sessions' work.
